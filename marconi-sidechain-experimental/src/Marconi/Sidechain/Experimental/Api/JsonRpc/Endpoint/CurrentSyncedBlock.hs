{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Marconi.Sidechain.Experimental.Api.JsonRpc.Endpoint.CurrentSyncedBlock (
  RpcCurrentSyncedBlockMethod,
  getCurrentSyncedBlockHandler,
  ChainIndex.GetCurrentSyncedBlockResult (..),
  ChainIndex.Tip (..),
) where

import Marconi.Cardano.Core.Orphans ()
import Marconi.ChainIndex.Api.JsonRpc.Endpoint.CurrentSyncedBlock qualified as ChainIndex
import Marconi.ChainIndex.Api.JsonRpc.Endpoint.CurrentSyncedBlock.Tip qualified as ChainIndex
import Marconi.Core.JsonRpc (ReaderHandler)
import Marconi.Sidechain.Experimental.Api.Types (SidechainHttpServerConfig, withChainIndexHandler)
import Network.JsonRpc.Types (JsonRpc, JsonRpcErr, UnusedRequestParams)

{- METHOD -}

type RpcCurrentSyncedBlockMethod =
  JsonRpc
    "getCurrentSyncedBlock"
    UnusedRequestParams
    String
    ChainIndex.GetCurrentSyncedBlockResult

{- HANDLER -}

getCurrentSyncedBlockHandler
  :: UnusedRequestParams
  -- ^ Will be an empty string, empty object, or null, as we are ignoring this param, and returning everything
  -> ReaderHandler
      SidechainHttpServerConfig
      (Either (JsonRpcErr String) ChainIndex.GetCurrentSyncedBlockResult)
getCurrentSyncedBlockHandler = withChainIndexHandler . ChainIndex.getCurrentSyncedBlockHandler
