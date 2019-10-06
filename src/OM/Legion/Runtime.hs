{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-deprecations #-}

{- | The meat of the Legion runtime implementation. -}
module OM.Legion.Runtime (
  -- * Starting the framework runtime.
  forkLegionary,
  Runtime,
  StartupMode(..),

  -- * Runtime Interface.
  applyFast,
  applyConsistent,
  readState,
  call,
  cast,
  broadcall,
  broadcast,
  eject,
  getSelf,

  -- * Other Exports.
  Peer(..),
  getClusterName,
  joinMessagePort,
) where


import Control.Arrow ((&&&))
import Control.Concurrent (Chan, writeChan, newChan, threadDelay,
  readChan)
import Control.Concurrent.Async (Async, async, race_)
import Control.Concurrent.STM (TVar, atomically, newTVar, writeTVar,
  readTVar, retry)
import Control.Exception.Safe (MonadCatch, tryAny, finally)
import Control.Monad (void, join, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Logger (MonadLoggerIO, logDebug, logInfo, logWarn,
  logError, askLoggerIO, runLoggingT, LoggingT, LogStr)
import Control.Monad.Morph (hoist)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Control.Monad.Trans.State (evalStateT, StateT, get, put, modify)
import Data.Aeson (ToJSON, ToJSONKey, FromJSONKey)
import Data.Binary (Binary, Word64)
import Data.ByteString.Lazy (ByteString)
import Data.Conduit (runConduit, (.|), awaitForever, Source, yield)
import Data.Default.Class (Default)
import Data.Int (Int64)
import Data.Map (Map)
import Data.Monoid ((<>))
import Data.Set (Set, (\\))
import Data.String (IsString)
import Data.Time (UTCTime, getCurrentTime, diffUTCTime, DiffTime)
import Data.UUID (UUID)
import Data.Void (Void)
import GHC.Generics (Generic)
import Network.Socket (PortNumber)
import OM.Deploy.Types (NodeName(NodeName), unNodeName, ClusterName)
import OM.Fork (Actor, actorChan, Msg, Responder, Background)
import OM.Legion.Conduit (chanToSink)
import OM.Legion.UUID (getUUID)
import OM.Logging (withPrefix)
import OM.PowerState (PowerState, Event, StateId, projParticipants,
  EventPack, events, Output, State, infimumId)
import OM.PowerState.Monad (event, acknowledge, runPowerStateT, merge,
  PowerStateT, disassociate, participate, acknowledgeAs, fullMerge)
import OM.Show (showt)
import OM.Socket (connectServer, AddressDescription(AddressDescription),
  openEgress, Endpoint(Endpoint), openIngress, openServer)
import System.Clock (TimeSpec)
import System.Random.Shuffle (shuffleM)
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified OM.Fork as Fork
import qualified OM.PowerState as PS
import qualified System.Clock as Clock


{- | The Legionary runtime state. -}
data RuntimeState e = RuntimeState {
              rsSelf :: Peer,
      rsClusterState :: PowerState ClusterName Peer e,
       rsConnections :: Map
                        Peer
                        (PeerMessage e -> StateT (RuntimeState e) IO ()),
           rsWaiting :: Map (StateId Peer) (Responder (Output e)),
             rsCalls :: Map MessageId (Responder ByteString),
        rsBroadcalls :: Map
                        MessageId
                        (
                          Map Peer (Maybe ByteString),
                          Responder (Map Peer (Maybe ByteString)),
                          TimeSpec
                        ),
            rsNextId :: MessageId,
            rsNotify :: PowerState ClusterName Peer e -> IO (),
             rsJoins :: Map
                        (StateId Peer)
                        (Responder (JoinResponse e)),
                        {- ^
                          The infimum of the powerstate we send to
                          a new participant must have moved past the
                          participation event itself. In other words,
                          the join must be totally consistent across the
                          cluster. The reason is that we can't make the
                          new participant responsible for applying events
                          that occur before it joined the cluster, because
                          it has no way to ensure that it can collect all
                          such events.  Therefore, this field tracks the
                          outstanding joins until they become consistent.
                        -}
     rsCheckpointSid :: StateId Peer,
    rsCheckpointTime :: UTCTime

  }


{- | Fork the Legion runtime system. -}
forkLegionary :: (
      Binary (State e), Binary e, Default (State e), Eq e, Event e,
      MonadCatch m, MonadLoggerIO m, Show e, ToJSON (State e), ToJSON e,
      Show (Output e), Eq (Output e), ToJSON (Output e), Binary (Output e)
    )
  => Peer {- ^ The peer being launched. -}
  -> (ByteString -> IO ByteString) {- ^ Handle a user call request. -}
  -> (ByteString -> IO ()) {- ^ Handle a user cast message. -}
  -> (Peer -> PowerState ClusterName Peer e -> IO ())
     {- ^ Callback when the cluster-wide powerstate changes. -}
  -> StartupMode e
     {- ^
       How to start the runtime, by creating new cluster or joining an
       existing cluster.
     -}
  -> m (Runtime e)
forkLegionary
    self
    handleUserCall
    handleUserCast
    notify
    startupMode
  = do
    rts <- makeRuntimeState self notify startupMode
    runtimeChan <- RChan <$> liftIO newChan
    logging <- withPrefix (logPrefix (rsSelf rts)) <$> askLoggerIO
    asyncHandle <- liftIO . async . (`runLoggingT` logging) $
      executeRuntime
        handleUserCall
        handleUserCast
        rts
        runtimeChan
    let
      clusterId :: ClusterName
      clusterId = PS.origin (rsClusterState rts)
    return Runtime {
             rChan = runtimeChan,
             rSelf = rsSelf rts,
            rAsync = asyncHandle,
        rClusterId = clusterId
      }
  where
    logPrefix :: Peer -> LogStr
    logPrefix self_ = "[" <> showt self_ <> "] "


{- | A handle on the Legion runtime. -}
data Runtime e = Runtime {
         rChan :: RChan e,
         rSelf :: Peer,
        rAsync :: Async Void,
    rClusterId :: ClusterName
  }
instance Actor (Runtime e) where
  type Msg (Runtime e) = RuntimeMessage e
  actorChan = actorChan . rChan


{- | The type of the runtime message channel. -}
newtype RChan e = RChan {
    unRChan :: Chan (RuntimeMessage e)
  }
instance Actor (RChan e) where
  type Msg (RChan e) = RuntimeMessage e
  actorChan = writeChan . unRChan


{- |
  Update the distributed cluster state by applying an event. The event
  output will be returned immediately and may not reflect a totally
  consistent view of the cluster. The state update itself, however,
  is guaranteed to be applied atomically and consistently throughout
  the cluster.
-}
applyFast :: (MonadIO m)
  => Runtime e     {- ^ The runtime handle. -}
  -> e             {- ^ The event to be applied. -}
  -> m (Output e)  {- ^ Returns the possibly inconsistent event output. -}
applyFast runtime e = Fork.call runtime (ApplyFast e)


{- |
  Update the distributed cluster state by applying an event. Both the
  event output and resulting state will be totally consistent throughout
  the cluster.
-}
applyConsistent :: (MonadIO m)
  => Runtime e     {- ^ The runtime handle. -}
  -> e             {- ^ The event to be applied. -}
  -> m (Output e)  {- ^ Returns the strongly consistent event output. -}
applyConsistent runtime e = Fork.call runtime (ApplyConsistent e)


{- | Read the current powerstate value. -}
readState :: (MonadIO m)
  => Runtime e
  -> m (PowerState ClusterName Peer e)
readState runtime = Fork.call runtime ReadState


{- |
  Send a user message to some other peer, and block until a response
  is received.
-}
call :: (MonadIO m) => Runtime e -> Peer -> ByteString -> m ByteString
call runtime target msg = Fork.call runtime (Call target msg)


{- | Send the result of a call back to the peer that originated it. -}
sendCallResponse :: (MonadIO m)
  => RChan e
  -> Peer
  -> MessageId
  -> ByteString
  -> m ()
sendCallResponse runtimeChan target mid msg =
  Fork.cast runtimeChan (SendCallResponse target mid msg)


{- | Send a user message to some other peer, without waiting on a response. -}
cast :: (MonadIO m) => Runtime e -> Peer -> ByteString -> m ()
cast runtime target message = Fork.cast runtime (Cast target message)


{- |
  Send a user message to all peers, and block until a response is received
  from all of them.
-}
broadcall :: (MonadIO m)
  => Runtime e
  -> DiffTime {- ^ The timeout. -}
  -> ByteString
  -> m (Map Peer (Maybe ByteString))
broadcall runtime timeout msg = Fork.call runtime (Broadcall timeout msg)


{- | Send a user message to all peers, without wating on a response. -}
broadcast :: (MonadIO m) => Runtime e -> ByteString -> m ()
broadcast runtime msg = Fork.cast runtime (Broadcast msg)


{- | Eject a peer from the cluster. -}
eject :: (MonadIO m) => Runtime e -> Peer -> m ()
eject runtime peer = Fork.cast runtime (Eject peer)


{- | Get the identifier for the local peer. -}
getSelf :: Runtime e -> Peer
getSelf = rSelf


{- |
  Get the async handle on the background legion thread, in case you want
  to wait for it to complete (which should never happen except in the
  case of an error).
-}
instance Background (Runtime e) where
  getAsync = rAsync


{- | The types of messages that can be sent to the runtime. -}
data RuntimeMessage e
  = ApplyFast e (Responder (Output e))
  | ApplyConsistent e (Responder (Output e))
  | Eject Peer
  | Merge (EventPack ClusterName Peer e)
  | FullMerge (PowerState ClusterName Peer e)
  | Join JoinRequest (Responder (JoinResponse e))
  | ReadState (Responder (PowerState ClusterName Peer e))
  | Call Peer ByteString (Responder ByteString)
  | Cast Peer ByteString
  | Broadcall
      DiffTime
      ByteString
      (Responder (Map Peer (Maybe ByteString)))
  | Broadcast ByteString
  | SendCallResponse Peer MessageId ByteString
  | HandleCallResponse Peer MessageId ByteString
  | Resend (Responder ())
deriving instance (
    Show e,
    Show (Output e),
    ToJSON e,
    ToJSON (State e),
    ToJSON (Output e)
  )
  => Show (RuntimeMessage e)


{- | The types of messages that can be sent from one peer to another. -}
data PeerMessage e
  = PMMerge (EventPack ClusterName Peer e)
    {- ^ Send a powerstate merge. -}
  | PMFullMerge (PowerState ClusterName Peer e)
    {- ^ Send a full merge. -}
  | PMCall Peer MessageId ByteString
    {- ^ Send a user call message from one peer to another. -}
  | PMCast ByteString
    {- ^ Send a user cast message from one peer to another. -}
  | PMCallResponse Peer MessageId ByteString
    {- ^ Send a response to a user call message. -}
  deriving (Generic)
deriving instance (
    Show e, Show (Output e), ToJSON e, ToJSON (State e), ToJSON (Output e)
  )
  => Show (PeerMessage e)
instance (Binary e, Binary (Output e), Binary (State e)) => Binary (PeerMessage e)


{- | An opaque value that identifies a cluster participant. -}
newtype Peer = Peer {
    unPeer :: NodeName
  }
  deriving newtype (
    Eq, Ord, Show, ToJSONKey, ToJSON, Binary, IsString, FromJSONKey,
    ToHttpApiData, FromHttpApiData
  )


{- |
  Execute the Legion runtime, with the given user definitions, and
  framework settings. This function never returns (except maybe with an
  exception if something goes horribly wrong).
-}
executeRuntime :: (
      Constraints e, MonadCatch m, MonadLoggerIO m
    )
  => (ByteString -> IO ByteString)
     {- ^ Handle a user call request.  -}
  -> (ByteString -> IO ())
     {- ^ Handle a user cast message. -}
  -> RuntimeState e
  -> RChan e
    {- ^ A source of requests, together with a way to respond to the requets. -}
  -> m Void
executeRuntime
    handleUserCall
    handleUserCast
    rts
    runtimeChan
  = do
    {- Start the various messages sources. -}
    runPeerListener
      `raceLog_` runJoinListener
      `raceLog_` runPeriodicResent
      `raceLog_`
        (
          (`evalStateT` rts) $
            let
              -- handleMessages :: StateT (RuntimeState e3) m Void
              handleMessages = do
                msg <- liftIO $ readChan (unRChan runtimeChan)
                RuntimeState {rsClusterState = cluster1} <- get
                $(logDebug) $ "Handling: " <> showt msg
                handleRuntimeMessage msg
                RuntimeState {rsClusterState = cluster2} <- get
                when (cluster1 /= cluster2)
                  ($(logDebug) $ "New Cluster State: " <> showt cluster2)
                handleBroadcallTimeouts
                handleOutstandingJoins
                handleMessages
            in
              handleMessages
        )
    fail "Legion runtime stopped."
  where
    {- | Like 'race_', but with logging. -}
    raceLog_ :: (MonadLoggerIO m) => LoggingT IO a -> LoggingT IO b -> m ()
    raceLog_ a b = do
      logging <- askLoggerIO
      liftIO $ race_ (runLoggingT a logging) (runLoggingT b logging)

    runPeerListener :: (MonadLoggerIO m) => m ()
    runPeerListener =
      let
        addy :: AddressDescription
        addy =
          AddressDescription
            (unNodeName (unPeer (rsSelf rts)) <> ":" <> showt peerMessagePort)
      in
        runConduit (
          openIngress (Endpoint addy Nothing)
          .| awaitForever (\ (msgSource, msg) -> do
              $(logDebug) $ "Handling: " <> showt (msgSource :: Peer, msg)
              case msg of
                PMFullMerge ps -> yield (FullMerge ps)
                PMMerge ps -> yield (Merge ps)
                PMCall source mid callMsg ->
                  (liftIO . tryAny) (handleUserCall callMsg) >>= \case
                    Left err ->
                      $(logError)
                        $ "User call handling failed with: " <> showt err
                    Right v -> sendCallResponse runtimeChan source mid v
                PMCast castMsg -> liftIO (handleUserCast castMsg)
                PMCallResponse source mid responseMsg ->
                  yield (HandleCallResponse source mid responseMsg)
             )
          .| chanToSink (unRChan runtimeChan)
        )

    runJoinListener :: (MonadLoggerIO m) => m ()
    runJoinListener =
      let
        addy :: AddressDescription
        addy =
          AddressDescription
            (unNodeName (unPeer (rsSelf rts)) <> ":" <> showt joinMessagePort)
      in
        runConduit (
          openServer (Endpoint addy Nothing)
          .| awaitForever (\(req, respond_) -> lift $
               Fork.call runtimeChan (Join req) >>= respond_
             )
        )

    runPeriodicResent :: (MonadIO m) => m ()
    runPeriodicResent =
      let
        periodicResend :: (MonadIO m) => m ()
        periodicResend = do
          liftIO $ threadDelay 100000
          Fork.call runtimeChan Resend
          periodicResend
      in
        periodicResend


{- | Handle any outstanding joins. -}
handleOutstandingJoins :: (MonadIO m) => StateT (RuntimeState e) m ()
handleOutstandingJoins = do
  state@RuntimeState {rsJoins, rsClusterState} <- get
  let
    (consistent, pending) =
      Map.partitionWithKey
        (\k _ -> k <= infimumId rsClusterState)
        rsJoins
  put state {rsJoins = pending}
  sequence_ [
      respond responder (JoinOk rsClusterState)
      | (_, responder) <- Map.toList consistent
    ]


{- | Handle any broadcall timeouts. -}
handleBroadcallTimeouts :: (MonadIO m) => StateT (RuntimeState e) m ()
handleBroadcallTimeouts = do
  broadcalls <- rsBroadcalls <$> get
  now <- getTime
  sequence_ [
      do
        respond responder responses
        modify (\rs -> rs {
            rsBroadcalls = Map.delete messageId (rsBroadcalls rs)
          })
      | (messageId, (responses, responder, expiry)) <- Map.toList broadcalls
      , now >= expiry
    ]


{- | Execute the incoming messages. -}
handleRuntimeMessage :: (
      Constraints e, MonadCatch m, MonadLoggerIO m
    )
  => RuntimeMessage e
  -> StateT (RuntimeState e) m ()

handleRuntimeMessage (ApplyFast e responder) =
  updateCluster $ do
    (o, _sid) <- event e
    respond responder o

handleRuntimeMessage (ApplyConsistent e responder) = do
  updateCluster $ do
    (_v, sid) <- event e
    lift (waitOn sid responder)
  rs <- get
  $(logDebug) $ "Waiting: " <> showt (rsWaiting rs)

handleRuntimeMessage (Eject peer) =
  updateClusterAs peer $ disassociate peer

handleRuntimeMessage (Merge other) =
  updateCluster $
    runExceptT (merge other) >>= \case
      Left err -> $(logError) $ "Bad cluster merge: " <> showt err
      Right () -> return ()

handleRuntimeMessage (FullMerge other) =
  updateCluster $
    runExceptT (fullMerge other) >>= \case
      Left err -> $(logError) $ "Bad cluster merge: " <> showt err
      Right () -> return ()

handleRuntimeMessage (Join (JoinRequest peer) responder) = do
  $(logInfo) $ "Handling join from peer: " <> showt peer
  sid <- updateCluster (do
      disassociate peer
      acknowledgeAs peer
      participate peer
    )
  RuntimeState {rsClusterState} <- get
  if sid <= infimumId rsClusterState
    then do
      $(logInfo) $ "Join immediately with: " <> showt rsClusterState
      respond responder (JoinOk rsClusterState)
    else do
      $(logInfo) "Join delayed."
      modify (\s -> s {rsJoins = Map.insert sid responder (rsJoins s)})

handleRuntimeMessage (ReadState responder) =
  respond responder . rsClusterState =<< get

handleRuntimeMessage (Call target msg responder) = do
    mid <- newMessageId
    source <- rsSelf <$> get
    setCallResponder mid
    sendPeer (PMCall source mid msg) target
  where
    setCallResponder :: (Monad m)
      => MessageId
      -> StateT (RuntimeState e) m ()
    setCallResponder mid = do
      state@RuntimeState {rsCalls} <- get
      put state {
          rsCalls = Map.insert mid responder rsCalls
        }

handleRuntimeMessage (Cast target msg) =
  sendPeer (PMCast msg) target

handleRuntimeMessage (Broadcall timeout msg responder) = do
    expiry <- addTime timeout <$> getTime
    mid <- newMessageId
    source <- rsSelf <$> get
    setBroadcallResponder expiry mid
    mapM_ (sendPeer (PMCall source mid msg)) =<< getPeers
  where
    setBroadcallResponder :: (Monad m)
      => TimeSpec
      -> MessageId
      -> StateT (RuntimeState e) m ()
    setBroadcallResponder expiry mid = do
      peers <- getPeers
      state@RuntimeState {rsBroadcalls} <- get
      put state {
          rsBroadcalls =
            Map.insert
              mid
              (
                Map.fromList [(peer, Nothing) | peer <- Set.toList peers],
                responder,
                expiry
              )
              rsBroadcalls
        }

handleRuntimeMessage (Broadcast msg) =
  mapM_ (sendPeer (PMCast msg)) =<< getPeers

handleRuntimeMessage (SendCallResponse target mid msg) = do
  source <- rsSelf <$> get
  sendPeer (PMCallResponse source mid msg) target

handleRuntimeMessage (HandleCallResponse source mid msg) = do
  state@RuntimeState {rsCalls, rsBroadcalls} <- get
  case Map.lookup mid rsCalls of
    Nothing ->
      case Map.lookup mid rsBroadcalls of
        Nothing -> return ()
        Just (responses, responder, expiry) ->
          let
            responses2 = Map.insert source (Just msg) responses
            response = Map.fromList [
                (peer, r)
                | (peer, Just r) <- Map.toList responses2
              ]
            peers = Map.keysSet responses2
          in
            if Set.null (peers \\ Map.keysSet response)
              then do
                respond responder (Just <$> response)
                put state {
                    rsBroadcalls = Map.delete mid rsBroadcalls
                  }
              else
                put state {
                    rsBroadcalls =
                      Map.insert
                        mid
                        (responses2, responder, expiry)
                        rsBroadcalls
                  }
    Just responder -> do
      respond responder msg
      put state {rsCalls = Map.delete mid rsCalls}

handleRuntimeMessage (Resend responder) =
  propagate >>= respond responder


{- | Get the projected peers. -}
getPeers :: (Monad m) => StateT (RuntimeState e) m (Set Peer)
getPeers = projParticipants . rsClusterState <$> get


{- | Get a new messageId. -}
newMessageId :: (Monad m) => StateT (RuntimeState e) m MessageId
newMessageId = do
  state@RuntimeState {rsNextId} <- get
  put state {rsNextId = nextMessageId rsNextId}
  return rsNextId


{- |
  Like 'runPowerStateT', plus automatically take care of doing necessary
  IO implied by the cluster update.
-}
updateCluster :: (
      Constraints e, MonadCatch m, MonadLoggerIO m
    )
  => PowerStateT ClusterName Peer e (StateT (RuntimeState e) m) a
  -> StateT (RuntimeState e) m a
updateCluster action = do
  RuntimeState {rsSelf} <- get
  updateClusterAs rsSelf action


{- |
  Like 'updateCluster', but perform the operation on behalf of a specified
  peer. This is required for e.g. the peer eject case, when the ejected peer
  may not be able to perform acknowledgements on its own behalf.
-}
updateClusterAs :: (
      Constraints e, MonadCatch m, MonadLoggerIO m
    )
  => Peer
  -> PowerStateT ClusterName Peer e (StateT (RuntimeState e) m) a
  -> StateT (RuntimeState e) m a
updateClusterAs asPeer action = do
  RuntimeState {rsClusterState} <- get
  (v, _propAction, newClusterState, infs) <-
    runPowerStateT asPeer rsClusterState (action <* acknowledge)
  liftIO . ($ newClusterState) . rsNotify =<< get
  modify (\state -> state {rsClusterState = newClusterState})
  respondToWaiting infs
  return v


{- | Wait on a consistent response for the given state id. -}
waitOn :: (Monad m)
  => StateId Peer
  -> Responder (Output e)
  -> StateT (RuntimeState e) m ()
waitOn sid responder =
  modify (\state@RuntimeState {rsWaiting} -> state {
    rsWaiting = Map.insert sid responder rsWaiting
  })


{- | Propagates cluster information if necessary. -}
propagate :: (Constraints e, MonadCatch m, MonadLoggerIO m)
  => StateT (RuntimeState e) m ()
propagate = do
    (self, (cluster, (checkSid, checkTime))) <-
      (
        rsSelf
        &&& rsClusterState
        &&& rsCheckpointSid
        &&& rsCheckpointTime
      ) <$> get
    let
      targets = Set.delete self $
        PS.allParticipants cluster

    now <- liftIO getCurrentTime
    liftIO (shuffleM (Set.toList targets)) >>= \case
      [] -> return ()
      target:_ ->
        {-
          If it has been more than 10 seconds since progress on the
          infimum was made, try sending out a full merge instead of just
          the event pack.
        -}
        if infimumId cluster == checkSid && diffUTCTime now checkTime > 10
          then do
            $(logWarn)
              $ "Sending full merge because no progress has been "
              <> "made on the cluster state."
            sendPeer (PMFullMerge cluster) target
            modify (\rs -> rs {rsCheckpointTime = now})
          else sendPeer (PMMerge (events target cluster)) target
    modify (\rs -> rs {
        rsCheckpointSid = infimumId cluster,
        rsCheckpointTime =
          {-
            Don't advance the checkpoint time unless the infimum has
            also advanced.
          -}
          if infimumId cluster == checkSid
            then rsCheckpointTime rs
            else now
      })
    disconnectObsolete
  where
    {- |
      Shut down connections to peers that are no longer participating
      in the cluster.
    -}
    disconnectObsolete :: (MonadIO m) => StateT (RuntimeState e) m ()
    disconnectObsolete = do
        RuntimeState {rsClusterState, rsConnections} <- get
        mapM_ disconnect $
          PS.allParticipants rsClusterState \\ Map.keysSet rsConnections


{- | Send a peer message, creating a new connection if need be. -}
sendPeer :: (Constraints e, MonadCatch m, MonadLoggerIO m)
  => PeerMessage e
  -> Peer
  -> StateT (RuntimeState e) m ()
sendPeer msg peer = do
  state@RuntimeState {rsConnections} <- get
  case Map.lookup peer rsConnections of
    Nothing -> do
      conn <- createConnection peer
      put state {rsConnections = Map.insert peer conn rsConnections}
      sendPeer msg peer
    Just conn ->
      (hoist liftIO . tryAny) (conn msg) >>= \case
        Left err -> do
          $(logWarn) $ "Failure sending to peer: " <> showt (peer, err)
          disconnect peer
        Right () -> do
          $(logDebug) $ "Sent message to peer: " <> showt (peer, msg)
          return ()


{- | Disconnect the connection to a peer. -}
disconnect :: (MonadIO m) => Peer -> StateT (RuntimeState e) m ()
disconnect peer =
  modify (\state@RuntimeState {rsConnections} -> state {
    rsConnections = Map.delete peer rsConnections
  })


{- | Create a connection to a peer. -}
createConnection :: (Constraints e, MonadCatch m, MonadLoggerIO m)
  => Peer
  -> StateT (RuntimeState e) m (PeerMessage e -> StateT (RuntimeState e) IO ())
createConnection peer = do
    RuntimeState {rsSelf} <- get
    latest <- liftIO $ atomically (newTVar (Just []))
    logging <- askLoggerIO
    liftIO . void . async . (`runLoggingT` logging) $
      let
        addy :: AddressDescription
        addy =
          AddressDescription
            (unNodeName (unPeer peer) <> ":" <> showt peerMessagePort)
      in
        finally 
          (
            (tryAny . runConduit) (
              latestSource rsSelf latest .| openEgress addy
            )
          )
          (liftIO $ atomically (writeTVar latest Nothing))
      
    return (\msg ->
        join . liftIO . atomically $
          readTVar latest >>= \case
            Nothing ->
              return $ modify (\state -> state {
                  rsConnections = Map.delete peer (rsConnections state)
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
      => Peer
      -> TVar (Maybe [PeerMessage e])
      -> Source m (Peer, PeerMessage e)
    latestSource self_ latest =
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
          mapM_ (yield . (self_,)) messages
          latestSource self_ latest


{- |
  Respond to event applications that are waiting on a consistent result,
  if such a result is available.
-}
respondToWaiting :: (MonadLoggerIO m, Show (Output e))
  => Map (StateId Peer) (Output e)
  -> StateT (RuntimeState e) m ()
respondToWaiting available = do
    rs <- get
    $(logDebug)
      $ "Responding to: " <> showt (available, Map.keysSet (rsWaiting rs))
    mapM_ respondToOne (Map.toList available)
  where
    respondToOne :: (MonadIO m)
      => (StateId Peer, Output e)
      -> StateT (RuntimeState e) m ()
    respondToOne (sid, o) = do
      state@RuntimeState {rsWaiting} <- get
      case Map.lookup sid rsWaiting of
        Nothing -> return ()
        Just responder -> do
          respond responder o
          put state {rsWaiting = Map.delete sid rsWaiting}


{- | This defines the various ways a node can be spun up. -}
data StartupMode e
  = NewCluster ClusterName
    {- ^ Indicates that we should bootstrap a new cluster at startup. -}
  | JoinCluster AddressDescription
    {- ^ Indicates that the node should try to join an existing cluster. -}
  | Recover (PowerState ClusterName Peer e)
deriving instance
    (ToJSON e, ToJSON (State e), ToJSON (Output e))
  =>
    Show (StartupMode e)


{- | Initialize the runtime state. -}
makeRuntimeState :: (Constraints e, MonadLoggerIO m)
  => Peer
  -> (Peer -> PowerState ClusterName Peer e -> IO ())
     {- ^ Callback when the cluster-wide powerstate changes. -}
  -> StartupMode e
  -> m (RuntimeState e)

makeRuntimeState
    self
    notify
    (NewCluster clusterId)
  =
    {- Build a brand new node state, for the first node in a cluster. -}
    makeRuntimeState
      self
      notify
      (Recover (PS.new clusterId (Set.singleton self)))

makeRuntimeState
    self
    notify
    (JoinCluster addr)
  = do
    {- Join a cluster an existing cluster. -}
    $(logInfo) $ "Trying to join an existing cluster on " <> showt addr
    JoinOk cluster <-
      requestJoin
      . JoinRequest
      $ self
    $(logInfo) $ "Join response with cluster: " <> showt cluster
    makeRuntimeState self notify (Recover cluster)
  where
    requestJoin :: (Constraints e, MonadLoggerIO m)
      => JoinRequest
      -> m (JoinResponse e)
    requestJoin joinMsg = ($ joinMsg) =<< connectServer addr

makeRuntimeState
    self
    notify
    (Recover clusterState)
  = do
    now <- liftIO getCurrentTime
    rsNextId <- newSequence
    return RuntimeState {
        rsSelf = self,
        rsClusterState = clusterState,
        rsConnections = mempty,
        rsWaiting = mempty,
        rsCalls = mempty,
        rsBroadcalls = mempty,
        rsNextId,
        rsNotify = notify self,
        rsJoins = mempty,
        rsCheckpointTime = now,
        rsCheckpointSid = infimumId clusterState
      }


{- | This is the type of a join request message. -}
newtype JoinRequest = JoinRequest Peer
  deriving (Generic, Show)
instance Binary JoinRequest


{- | The response to a JoinRequest message -}
newtype JoinResponse e
  = JoinOk (PowerState ClusterName Peer e)
  deriving (Generic)
deriving instance (Constraints e) => Show (JoinResponse e)
instance (Constraints e) => Binary (JoinResponse e)


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


type Constraints e = (
    Binary (State e), Binary e, Default (State e), Eq e, Event e, Show e,
    ToJSON (State e), ToJSON e, Show (Output e), Eq (Output e), ToJSON
    (Output e), Binary (Output e)
  )


{- | Obtain the 'ClusterName'. -}
getClusterName :: Runtime e -> ClusterName
getClusterName = rClusterId


{- | The peer message port. -}
peerMessagePort :: PortNumber
peerMessagePort = 5288


{- | The join message port  -}
joinMessagePort :: PortNumber
joinMessagePort = 5289


{- | Like 'Fork.respond', but returns '()'. -}
respond :: (MonadIO m) => Responder a -> a -> m ()
respond responder = void . Fork.respond responder


{- | Add a 'DiffTime' to a 'TimeSpec'. -}
addTime :: DiffTime -> TimeSpec -> TimeSpec
addTime diff time =
  let
    rat = toRational diff

    secDiff :: Int64
    secDiff = truncate rat

    nsecDiff :: Int64
    nsecDiff = truncate ((toRational diff - toRational secDiff) * 1000000000)
  in
    Clock.TimeSpec {
      Clock.sec = Clock.sec time + secDiff,
      Clock.nsec = Clock.nsec time + nsecDiff
    }


{- | Specialized 'Clock.getTime'. -}
getTime :: (MonadIO m) => m TimeSpec
getTime = liftIO $ Clock.getTime Clock.Monotonic


