{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

{- | The meat of the Legion runtime implementation. -}
module OM.Legion.Runtime (
  -- * Starting the framework runtime.
  forkLegionary,
  Runtime,
  StartupMode(..),

  -- * Runtime Interface
  applyFast,
  applyConsistent,
  readState,
  call,
  cast,
  broadcall,
  broadcast,
  eject,
  getSelf,

  -- * Other types
  ClusterId,
  Peer,
) where


import Control.Concurrent (Chan, newEmptyMVar, putMVar, takeMVar,
   writeChan, newChan)
import Control.Concurrent.STM (TVar, atomically, newTVar, writeTVar,
   readTVar, retry)
import Control.Exception.Safe (MonadCatch, tryAny)
import Control.Monad (void, when, join)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Logger (MonadLoggerIO, logDebug, logInfo, logWarn,
   logError)
import Control.Monad.Morph (hoist)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Control.Monad.Trans.State (runStateT, StateT, get, put, modify)
import Data.Aeson (ToJSON, toJSON, ToJSONKey, toJSONKey,
   ToJSONKeyFunction(ToJSONKeyText))
import Data.Aeson.Encoding (text)
import Data.Binary (Binary, Word64)
import Data.ByteString.Lazy (ByteString)
import Data.Conduit (runConduit, (.|), awaitForever, Source, yield)
import Data.Default.Class (Default)
import Data.Map (Map)
import Data.Monoid ((<>))
import Data.Set (Set, (\\))
import Data.UUID (UUID)
import GHC.Generics (Generic)
import OM.Fork (ForkM, forkC, forkM)
import OM.Legion.Conduit (chanToSource, chanToSink)
import OM.Legion.UUID (getUUID)
import OM.PowerState (PowerState, Event, StateId, projParticipants,
   EventPack, events)
import OM.PowerState.Monad (PropAction(DoNothing, Send), event,
   acknowledge, runPowerStateT, merge, PowerStateT, disassociate,
   participate)
import OM.Show (showt)
import OM.Socket (connectServer, bindAddr,
   AddressDescription(AddressDescription), openEgress, Endpoint(Endpoint),
   openIngress, openServer)
import Web.HttpApiData (FromHttpApiData, parseUrlPiece)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified OM.PowerState as PS


{- | The Legionary runtime state. -}
data RuntimeState e o s = RuntimeState {
            self :: Peer,
    clusterState :: PowerState ClusterId s Peer e o,
     connections :: Map
                      Peer
                      (PeerMessage e -> StateT (RuntimeState e o s) IO ()),
         waiting :: Map (StateId Peer) (Responder o),
           calls :: Map MessageId (Responder ByteString),
      broadcalls :: Map
                      MessageId
                      (
                        Map Peer (Maybe ByteString),
                        Responder (Map Peer ByteString)
                      ),
          nextId :: MessageId,
          notify :: PowerState ClusterId s Peer e o -> IO ()
  }


{- | Fork the Legion runtime system. -}
forkLegionary :: (
      Binary e, Binary o, Binary s, Default s, Eq e, Event e o s, ForkM m,
      MonadCatch m, MonadLoggerIO m, Show e, Show o, Show s
    )
  => Endpoint
     {- ^
       The address on which the legion framework will listen for
       rebalancing and cluster management commands.
     -}
  -> Endpoint
     {- ^
       The address on which the legion framework will listen for cluster
       join requests.
     -}
  -> (ByteString -> IO ByteString)
     {- ^ Handle a user call request.  -}
  -> (ByteString -> IO ())
     {- ^ Handle a user cast message. -}
  -> (PowerState ClusterId s Peer e o -> IO ())
     {- ^ Callback when the cluster-wide powerstate changes. -}
  -> StartupMode
     {- ^
       How to start the runtime, by creating new cluster or joining an
       existing cluster.
     -}
  -> m (Runtime e o s)
forkLegionary
    peerBindAddr
    joinBindAddr
    handleUserCall
    handleUserCast
    notify
    startupMode
  = do
    rts <- makeRuntimeState peerBindAddr notify startupMode
    runtime <- Runtime <$> liftIO newChan <*> pure (self rts)
    forkC "main legion thread" $
      executeRuntime
        peerBindAddr
        joinBindAddr
        handleUserCall
        handleUserCast
        notify
        rts
        runtime
    return runtime


{- | A handle on the Legion runtime. -}
data Runtime e o s = Runtime {
    rChan :: Chan (RuntimeMessage e o s),
    rSelf :: Peer
  }


{- |
  Update the distributed cluster state by applying an event. The event
  output will be returned immediately and may not reflect a totally
  consistent view of the cluster. The state update itself, however,
  is guaranteed to be applied atomically and consistently throughout
  the cluster.
-}
applyFast :: (MonadIO m)
  => Runtime e o s {- ^ The runtime handle. -}
  -> e             {- ^ The event to be applied. -}
  -> m o           {- ^ Returns the possibly inconsistent event output. -}
applyFast runtime e = runtimeCall runtime (ApplyFast e)


{- |
  Update the distributed cluster state by applying an event. Both the
  event output and resulting state will be totally consistent throughout
  the cluster.
-}
applyConsistent :: (MonadIO m)
  => Runtime e o s {- ^ The runtime handle. -}
  -> e             {- ^ The event to be applied. -}
  -> m o           {- ^ Returns the strongly consistent event output. -}
applyConsistent runtime e = runtimeCall runtime (ApplyConsistent e)


{- | Read the current powerstate value. -}
readState :: (MonadIO m)
  => Runtime e o s
  -> m (PowerState ClusterId s Peer e o)
readState runtime = runtimeCall runtime ReadState


{- |
  Send a user message to some other peer, and block until a response
  is received.
-}
call :: (MonadIO m) => Runtime e o s -> Peer -> ByteString -> m ByteString
call runtime target msg = runtimeCall runtime (Call target msg)


{- | Send the result of a call back to the peer that originated it. -}
sendCallResponse :: (MonadIO m)
  => Runtime e o s
  -> Peer
  -> MessageId
  -> ByteString
  -> m ()
sendCallResponse runtime target mid msg =
  runtimeCast runtime (SendCallResponse target mid msg)


{- | Send a user message to some other peer, without waiting on a response. -}
cast :: (MonadIO m) => Runtime e o s -> Peer -> ByteString -> m ()
cast runtime target message = runtimeCast runtime (Cast target message)


{- |
  Send a user message to all peers, and block until a response is received
  from all of them.
-}
broadcall :: (MonadIO m)
  => Runtime e o s
  -> ByteString
  -> m (Map Peer ByteString)
broadcall runtime msg = runtimeCall runtime (Broadcall msg)


{- | Send a user message to all peers, without wating on a response. -}
broadcast :: (MonadIO m) => Runtime e o s -> ByteString -> m ()
broadcast runtime msg = runtimeCast runtime (Broadcast msg)


{- | Eject a peer from the cluster. -}
eject :: (MonadIO m) => Runtime e o s -> Peer -> m ()
eject runtime peer = runtimeCast runtime (Eject peer)


{- | Get the identifier for the local peer. -}
getSelf :: Runtime e o s -> Peer
getSelf = rSelf


{- | The types of messages that can be sent to the runtime. -}
data RuntimeMessage e o s
  = ApplyFast e (Responder o)
  | ApplyConsistent e (Responder o)
  | Eject Peer
  | Merge (EventPack ClusterId Peer e)
  | Join JoinRequest (Responder (JoinResponse e o s))
  | ReadState (Responder (PowerState ClusterId s Peer e o))
  | Call Peer ByteString (Responder ByteString)
  | Cast Peer ByteString
  | Broadcall ByteString (Responder (Map Peer ByteString))
  | Broadcast ByteString
  | SendCallResponse Peer MessageId ByteString
  | HandleCallResponse Peer MessageId ByteString
  deriving (Show)


{- | The types of messages that can be sent from one peer to another. -}
data PeerMessage e
  = PMMerge (EventPack ClusterId Peer e)
    {- ^ Send a powerstate merge. -}
  | PMCall Peer MessageId ByteString
    {- ^ Send a user call message from one peer to another. -}
  | PMCast ByteString
    {- ^ Send a user cast message from one peer to another. -}
  | PMCallResponse Peer MessageId ByteString
    {- ^ Send a response to a user call message. -}

  deriving (Generic)
instance (Binary e) => Binary (PeerMessage e)


{- | An opaque value that identifies a cluster participant. -}
data Peer = Peer {
      peerId :: UUID,
    peerAddy :: AddressDescription
  }
  deriving (Generic, Eq, Ord)
instance Show Peer where
  show peer = show (peerId peer) ++ ":" ++ show (peerAddy peer)
instance ToJSONKey Peer where
  toJSONKey = ToJSONKeyText showt (text . showt)
instance ToJSON Peer where
  toJSON = toJSON . show
instance Binary Peer
instance FromHttpApiData Peer where
  parseUrlPiece str =
    case T.span (/= ':') str of
      (UUID.fromText -> Just uuid, T.span (== ':') -> (_, addr)) ->
        Right (Peer uuid (AddressDescription addr))
      _ -> Left $ "Can't parse peer: " <> showt str


{- | An opaque value that identifies a cluster. -}
newtype ClusterId = ClusterId UUID
  deriving (Binary, Show, Eq, ToJSON)


{- | A way for the runtime to respond to a message. -}
newtype Responder a = Responder {
    unResponder :: a -> IO ()
  }
instance Show (Responder a) where
  show _ = "Responder"


{- | Respond to a message, using the given responder, in 'MonadIO'. -}
respond :: (MonadIO m) => Responder a -> a -> m ()
respond responder = liftIO . unResponder responder


{- | Send a message to the runtime that blocks on a response. -}
runtimeCall :: (MonadIO m)
  => Runtime e o s
  -> (Responder a -> RuntimeMessage e o s)
  -> m a
runtimeCall runtime withResonder = liftIO $ do
  mvar <- newEmptyMVar
  runtimeCast runtime (withResonder (Responder (putMVar mvar)))
  takeMVar mvar


{- | Send a message to the runtime. Do not wait for a result. -}
runtimeCast :: (MonadIO m) => Runtime e o s -> RuntimeMessage e o s -> m ()
runtimeCast runtime = liftIO . writeChan (rChan runtime)


{- |
  Execute the Legion runtime, with the given user definitions, and
  framework settings. This function never returns (except maybe with an
  exception if something goes horribly wrong).
-}
executeRuntime :: (
      Binary e, Binary o, Binary s, Default s, Eq e, Event e o s, ForkM m,
      MonadCatch m, MonadLoggerIO m, Show e, Show o, Show s
    )
  => Endpoint
     {- ^
       The address on which the legion framework will listen for
       rebalancing and cluster management commands.
     -}
  -> Endpoint
     {- ^
       The address on which the legion framework will listen for cluster
       join requests.
     -}
  -> (ByteString -> IO ByteString)
     {- ^ Handle a user call request.  -}
  -> (ByteString -> IO ())
     {- ^ Handle a user cast message. -}
  -> (PowerState ClusterId s Peer e o -> IO ())
     {- ^ Callback when the cluster-wide powerstate changes. -}
  -> RuntimeState e o s
  -> Runtime e o s
    {- ^ A source of requests, together with a way to respond to the requets. -}
  -> m ()
executeRuntime
    peerBindAddr
    joinBindAddr
    handleUserCall
    handleUserCast
    notify
    rts
    runtime
  = do
    {- Start the various messages sources. -}
    startPeerListener
    startJoinListener

    void . (`runStateT` rts) . runConduit $
      chanToSource (rChan runtime)
      .| awaitForever (\msg -> do
          $(logDebug) $ "Receieved: " <> showt msg
          lift $ do
            state <- clusterState <$> get
            handleRuntimeMessage msg
            newState <- clusterState <$> get
            when (state /= newState) (liftIO (notify newState))
        )
  where
    startPeerListener :: (ForkM m, MonadCatch m, MonadLoggerIO m) => m ()
    startPeerListener = forkC "peer listener" $ 
      runConduit (
        openIngress peerBindAddr
        .| awaitForever (\case
             PMMerge ps -> yield (Merge ps)
             PMCall source mid msg -> liftIO . forkM $
               sendCallResponse runtime source mid
               =<< handleUserCall msg
             PMCast msg -> (liftIO . forkM) (handleUserCast msg)
             PMCallResponse source mid msg ->
               yield (HandleCallResponse source mid msg)
           )
        .| chanToSink (rChan runtime)
      )

    startJoinListener :: (ForkM m, MonadCatch m, MonadLoggerIO m) => m ()
    startJoinListener = forkC "join listener" $
      runConduit (
        openServer joinBindAddr
        .| awaitForever (\(req, respond_) -> lift $
            runtimeCall runtime (Join req) >>= respond_
          )
      )


{- | Execute the incoming messages. -}
handleRuntimeMessage :: (
      Binary e, Binary s, Eq e, Event e o s, ForkM m, MonadCatch m,
      MonadLoggerIO m
    )
  => RuntimeMessage e o s
  -> StateT (RuntimeState e o s) m ()

handleRuntimeMessage (ApplyFast e responder) =
  updateCluster $ do
    (o, _sid) <- event e
    respond responder o

handleRuntimeMessage (ApplyConsistent e responder) =
  updateCluster $ do
    (_v, sid) <- event e
    lift (waitOn sid responder)

handleRuntimeMessage (Eject peer) =
  updateClusterAs peer $ disassociate peer

handleRuntimeMessage (Merge other) =
  updateCluster $
    runExceptT (merge other) >>= \case
      Left err -> $(logError) $ "Bad cluster merge: " <> showt err
      Right () -> return ()

handleRuntimeMessage (Join (JoinRequest addr) responder) = do
  peer <- newPeer addr
  updateCluster (participate peer)
  respond responder . JoinOk peer . clusterState =<< get

handleRuntimeMessage (ReadState responder) =
  respond responder . clusterState =<< get

handleRuntimeMessage (Call target msg responder) = do
    mid <- newMessageId
    source <- self <$> get
    setCallResponder mid
    sendPeer (PMCall source mid msg) target
  where
    setCallResponder :: (Monad m)
      => MessageId
      -> StateT (RuntimeState e o s) m ()
    setCallResponder mid = do
      state@RuntimeState {calls} <- get
      put state {
          calls = Map.insert mid responder calls
        }

handleRuntimeMessage (Cast target msg) =
  sendPeer (PMCast msg) target

handleRuntimeMessage (Broadcall msg responder) = do
    mid <- newMessageId
    source <- self <$> get
    setBroadcallResponder mid
    mapM_ (sendPeer (PMCall source mid msg)) =<< getPeers
  where
    setBroadcallResponder :: (Monad m)
      => MessageId
      -> StateT (RuntimeState e o s) m ()
    setBroadcallResponder mid = do
      peers <- getPeers
      state@RuntimeState {broadcalls} <- get
      put state {
          broadcalls =
            Map.insert
              mid
              (
                Map.fromList [(peer, Nothing) | peer <- Set.toList peers],
                responder
              )
              broadcalls
        }

handleRuntimeMessage (Broadcast msg) =
  mapM_ (sendPeer (PMCast msg)) =<< getPeers

handleRuntimeMessage (SendCallResponse target mid msg) = do
  source <- self <$> get
  sendPeer (PMCallResponse source mid msg) target

handleRuntimeMessage (HandleCallResponse source mid msg) = do
  state@RuntimeState {calls, broadcalls} <- get
  case Map.lookup mid calls of
    Nothing ->
      case Map.lookup mid broadcalls of
        Nothing -> return ()
        Just (responses, responder) ->
          let
            responses2 = Map.insert source (Just msg) responses
            response = Map.fromList [
                (peer, r)
                | (peer, Just r) <- Map.toList responses2
              ]
            peers = Map.keysSet responses2
          in
            if Set.null (Map.keysSet response \\ peers)
              then do
                respond responder response
                put state {
                    broadcalls = Map.delete mid broadcalls
                  }
              else
                put state {
                    broadcalls =
                      Map.insert mid (responses2, responder) broadcalls
                  }
    Just responder -> do
      respond responder msg
      put state {calls = Map.delete mid calls}


{- | Get the projected peers. -}
getPeers :: (Monad m) => StateT (RuntimeState e o s) m (Set Peer)
getPeers = projParticipants . clusterState <$> get


{- | Get a new messageId. -}
newMessageId :: (Monad m) => StateT (RuntimeState e o s) m MessageId
newMessageId = do
  state@RuntimeState {nextId} <- get
  put state {nextId = nextMessageId nextId}
  return nextId


{- |
  Like 'runPowerStateT', plus automatically take care of doing necessary
  IO implied by the cluster update.
-}
updateCluster :: (
      Binary e, Binary s, Eq e, Event e o s, ForkM m, MonadCatch m,
      MonadLoggerIO m
    )
  => PowerStateT ClusterId s Peer e o (StateT (RuntimeState e o s) m) a
  -> StateT (RuntimeState e o s) m a
updateCluster action = do
  RuntimeState {self} <- get
  updateClusterAs self action


{- |
  Like 'updateCluster', but perform the operation on behalf of a specified
  peer. This is required for e.g. the peer eject case, when the ejected peer
  may not be able to perform acknowledgements on its own behalf.
-}
updateClusterAs :: (
      Binary e, Binary s, Eq e, Event e o s, ForkM m, MonadCatch m,
      MonadLoggerIO m
    )
  => Peer
  -> PowerStateT ClusterId s Peer e o (StateT (RuntimeState e o s) m) a
  -> StateT (RuntimeState e o s) m a
updateClusterAs asPeer action = do
  state@RuntimeState {clusterState} <- get
  runPowerStateT asPeer clusterState (action <* acknowledge) >>=
    \(v, propAction, newClusterState, infs) -> do
      put state {clusterState = newClusterState}
      respondToWaiting infs
      propagate propAction
      return v


{- | Wait on a consistent response for the given state id. -}
waitOn :: (Monad m)
  => StateId Peer
  -> Responder o
  -> StateT (RuntimeState e o s) m ()
waitOn sid responder =
  modify (\state@RuntimeState {waiting} -> state {
    waiting = Map.insert sid responder waiting
  })


{- | Propagates cluster information if necessary. -}
propagate :: (Binary e, Binary s, ForkM m, MonadCatch m, MonadLoggerIO m)
  => PropAction
  -> StateT (RuntimeState e o s) m ()
propagate DoNothing = return ()
propagate Send = do
    RuntimeState {self, clusterState} <- get
    mapM_ (sendPeer (PMMerge (events clusterState)))
      . Set.delete self
      . PS.allParticipants
      $ clusterState
    disconnectObsolete
  where
    {- |
      Shut down connections to peers that are no longer participating
      in the cluster.
    -}
    disconnectObsolete :: (MonadIO m) => StateT (RuntimeState e o s) m ()
    disconnectObsolete = do
        RuntimeState {clusterState, connections} <- get
        mapM_ disconnect $
          PS.allParticipants clusterState \\ Map.keysSet connections


{- | Send a peer message, creating a new connection if need be. -}
sendPeer :: (Binary e, Binary s, ForkM m, MonadCatch m, MonadLoggerIO m)
  => PeerMessage e
  -> Peer
  -> StateT (RuntimeState e o s) m ()
sendPeer msg peer = do
  state@RuntimeState {connections} <- get
  case Map.lookup peer connections of
    Nothing -> do
      conn <- lift (createConnection peer)
      put state {connections = Map.insert peer conn connections}
      sendPeer msg peer
    Just conn ->
      (hoist liftIO . tryAny) (conn msg) >>= \case
        Left err -> do
          $(logWarn) $ "Failure sending to peer: " <> showt (peer, err)
          disconnect peer
        Right () -> return ()


{- | Disconnect the connection to a peer. -}
disconnect :: (MonadIO m) => Peer -> StateT (RuntimeState e o s) m ()
disconnect peer =
  modify (\state@RuntimeState {connections} -> state {
    connections = Map.delete peer connections
  })


{- | Create a connection to a peer. -}
createConnection :: (
      Binary e, Binary s, ForkM m, MonadCatch m, MonadLoggerIO m
    )
  => Peer
  -> m (PeerMessage e -> StateT (RuntimeState e o s) IO ())
createConnection peer = do
    latest <- liftIO $ atomically (newTVar (Just []))
    forkM $ do
      (tryAny . runConduit) (
          latestSource latest .| openEgress (peerAddy peer)
        ) >>= \case
          Left err -> $(logWarn) $ "Connection crashed: " <> showt (peer, err)
          Right () -> $(logWarn) "Connection closed for no reason."
      liftIO $ atomically (writeTVar latest Nothing)
    return (\msg ->
        join . liftIO . atomically $
          readTVar latest >>= \case
            Nothing ->
              return $ modify (\state -> state {
                  connections = Map.delete peer (connections state)
                })
            Just msgs -> do
              writeTVar latest (
                  Just $ case msg of
                    PMMerge _ ->
                      msg : filter (\case {PMMerge _ -> False; _ -> True}) msgs
                    _ -> msgs ++ [msg] 
                )
              return (return ())
      )
  where
    latestSource :: (MonadIO m)
      => TVar (Maybe [PeerMessage e])
      -> Source m (PeerMessage e)
    latestSource latest =
      (liftIO . atomically) (
        readTVar latest >>= \case
          Nothing -> return Nothing
          Just [] -> retry
          Just messages -> do
            writeTVar latest (Just [])
            return (Just messages)
      ) >>= \case
        Nothing -> return ()
        Just messages -> do
          mapM_ yield messages
          latestSource latest


{- |
  Respond to event applications that are waiting on a consistent result,
  if such a result is available.
-}
respondToWaiting :: (MonadIO m)
  => Map (StateId Peer) o
  -> StateT (RuntimeState e o s) m ()
respondToWaiting available =
    mapM_ respondToOne (Map.toList available)
  where
    respondToOne :: (MonadIO m)
      => (StateId Peer, o)
      -> StateT (RuntimeState e o s) m ()
    respondToOne (sid, o) = do
      state@RuntimeState {waiting} <- get
      case Map.lookup sid waiting of
        Nothing -> return ()
        Just responder -> do
          respond responder o
          put state {waiting = Map.delete sid waiting}


{- | This defines the various ways a node can be spun up. -}
data StartupMode
  = NewCluster
    {- ^ Indicates that we should bootstrap a new cluster at startup. -}
  | JoinCluster AddressDescription
    {- ^ Indicates that the node should try to join an existing cluster. -}
  deriving (Show)


{- | Initialize the runtime state. -}
makeRuntimeState :: (
      Binary e, Binary o, Binary s, Default s, MonadLoggerIO m, Show e,
      Show o, Show s
    )
  => Endpoint
  -> (PowerState ClusterId s Peer e o -> IO ())
     {- ^ Callback when the cluster-wide powerstate changes. -}
  -> StartupMode
  -> m (RuntimeState e o s)

makeRuntimeState
    Endpoint {bindAddr}
    notify
    NewCluster
  = do
    {- Build a brand new node state, for the first node in a cluster. -}
    self <- newPeer bindAddr
    clusterId <- ClusterId <$> getUUID
    nextId <- newSequence
    return RuntimeState {
        self,
        clusterState = PS.new clusterId (Set.singleton self),
        connections = mempty,
        waiting = mempty,
        calls = mempty,
        broadcalls = mempty,
        nextId,
        notify
      }

makeRuntimeState
    peerBindAddr
    notify
    (JoinCluster addr)
  = do
    {- Join a cluster an existing cluster. -}
    $(logInfo) "Trying to join an existing cluster."
    JoinOk self cluster <-
      requestJoin
      . JoinRequest
      . bindAddr
      $ peerBindAddr
    nextId <- newSequence
    return RuntimeState {
        self,
        clusterState = cluster,
        connections = mempty,
        waiting = mempty,
        calls = mempty,
        broadcalls = mempty,
        nextId,
        notify
      }
  where
    requestJoin :: (
          Binary e, Binary o, Binary s, MonadLoggerIO m, Show e, Show o,
          Show s
        )
      => JoinRequest
      -> m (JoinResponse e o s)
    requestJoin joinMsg = ($ joinMsg) =<< connectServer addr


{- | Make a new peer. -}
newPeer :: (MonadIO m) => AddressDescription -> m Peer
newPeer addr = Peer <$> getUUID <*> pure addr


{- | This is the type of a join request message. -}
newtype JoinRequest = JoinRequest AddressDescription
  deriving (Generic, Show)
instance Binary JoinRequest


{- | The response to a JoinRequest message -}
data JoinResponse e o s
  = JoinOk Peer (PowerState ClusterId s Peer e o)
  deriving (Show, Generic)
instance (Binary e, Binary s) => Binary (JoinResponse e o s)


{- | Message Identifier. -}
data MessageId = M UUID Word64 deriving (Generic, Show, Eq, Ord)
instance Binary MessageId


{- |
  Initialize a new sequence of messageIds. It would be perfectly fine to ensure
  unique message ids by generating a unique UUID for each one, but generating
  UUIDs is not free, and we are probably going to be generating a lot of these.
-}
newSequence :: (MonadIO m) => m MessageId
newSequence = do
  sid <- getUUID
  return (M sid 0)


{- |
  Generate the next message id in the sequence. We would normally use
  `succ` for this kind of thing, but making `MessageId` an instance of
  `Enum` really isn't appropriate.
-}
nextMessageId :: MessageId -> MessageId
nextMessageId (M sequenceId ord) = M sequenceId (ord + 1)


