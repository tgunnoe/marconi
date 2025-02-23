{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-overlapping-patterns #-}

module Cardano.Api.Extended.Streaming.ChainSyncEvent where

import Cardano.Api qualified as C
import Cardano.Chain.Genesis qualified
import Cardano.Crypto (
  ProtocolMagicId (unProtocolMagicId),
  RequiresNetworkMagic (RequiresMagic, RequiresNoMagic),
 )
import Control.Concurrent.Async qualified as IO
import Control.Exception qualified as IO
import Data.SOP.Strict (NP ((:*)))
import GHC.Generics (Generic)
import Ouroboros.Consensus.Cardano.CanHardFork qualified as Consensus
import Ouroboros.Consensus.HardFork.Combinator qualified as Consensus
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras qualified as HFC
import Ouroboros.Consensus.HardFork.Combinator.Basics qualified as HFC
import Streaming.Prelude qualified as S

-- * ChainSyncEvent

data ChainSyncEvent a
  = RollForward a C.ChainTip
  | RollBackward C.ChainPoint C.ChainTip
  deriving (Show, Functor, Generic)

data ChainSyncEventException
  = NoIntersectionFound
  deriving (Show)

instance IO.Exception ChainSyncEventException

data RollbackException = RollbackLocationNotFound C.ChainPoint C.ChainTip
  deriving (Eq, Show)
instance IO.Exception RollbackException

-- * Orphans

instance IO.Exception C.FoldBlocksError
deriving instance Show C.FoldBlocksError

-- * IO

linkedAsync :: IO a -> IO ()
linkedAsync action = IO.link =<< IO.async action

-- * LocalNodeConnectInfo

mkLocalNodeConnectInfo :: C.NetworkId -> FilePath -> C.LocalNodeConnectInfo C.CardanoMode
mkLocalNodeConnectInfo networkId socketPath =
  C.LocalNodeConnectInfo
    { C.localConsensusModeParams = C.CardanoModeParams epochSlots
    , C.localNodeNetworkId = networkId
    , C.localNodeSocketPath = C.File socketPath
    }
  where
    -- This a parameter needed only for the Byron era. Since the Byron
    -- era is over and the parameter has never changed it is ok to
    -- hardcode this. See comment on `Cardano.Api.ConsensusModeParams` in
    -- cardano-node.
    epochSlots = C.EpochSlots 21600 -- TODO: is this configurable? see below

-- | Derive LocalNodeConnectInfo from Env.
mkConnectInfo :: C.Env -> FilePath -> C.LocalNodeConnectInfo C.CardanoMode
mkConnectInfo env socketPath =
  C.LocalNodeConnectInfo
    { C.localConsensusModeParams = cardanoModeParams
    , C.localNodeNetworkId = networkId'
    , C.localNodeSocketPath = C.File socketPath
    }
  where
    -- Derive the NetworkId as described in network-magic.md from the
    -- cardano-ledger-specs repo.
    byronConfig =
      (\(Consensus.WrapPartialLedgerConfig (Consensus.ByronPartialLedgerConfig bc _) :* _) -> bc)
        . HFC.getPerEraLedgerConfig
        . HFC.hardForkLedgerConfigPerEra
        $ C.envLedgerConfig env

    networkMagic =
      C.NetworkMagic $
        unProtocolMagicId $
          Cardano.Chain.Genesis.gdProtocolMagicId $
            Cardano.Chain.Genesis.configGenesisData byronConfig

    networkId' = case Cardano.Chain.Genesis.configReqNetMagic byronConfig of
      RequiresNoMagic -> C.Mainnet
      RequiresMagic -> C.Testnet networkMagic

    cardanoModeParams = C.CardanoModeParams . C.EpochSlots $ 10 * C.envSecurityParam env

{- | Ignore rollback events in the chainsync event stream. Useful for
 monitor which blocks has been seen by the node, regardless whether
 they are permanent.
-}
ignoreRollbacks :: (Monad m) => S.Stream (S.Of (ChainSyncEvent a)) m r -> S.Stream (S.Of a) m r
ignoreRollbacks = S.mapMaybe (\case RollForward e _ -> Just e; _ -> Nothing)
