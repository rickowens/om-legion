
{- | This module contains the user settings. -}
module OM.Legion.Settings (
  RuntimeSettings(..),
) where


import OM.Socket (Endpoint)


{- | Settings used when starting up the legion framework runtime.  -}
data RuntimeSettings = RuntimeSettings {
    peerBindAddr :: Endpoint,
                    {- ^
                      The address on which the legion framework will
                      listen for rebalancing and cluster management
                      commands.
                    -}
    joinBindAddr :: Endpoint
                    {- ^
                      The address on which the legion framework will
                      listen for cluster join requests.
                    -}
  }


