{-# LANGUAGE DataKinds #-}

module Marconi.Sidechain.Experimental.Api.JsonRpc.Endpoint.Echo where

import Marconi.ChainIndex.Api.JsonRpc.Endpoint.Echo qualified as ChainIndex.Echo
import Marconi.Core.JsonRpc (ReaderHandler)
import Marconi.Sidechain.Experimental.Api.Types (SidechainHttpServerConfig, withChainIndexHandler)
import Network.JsonRpc.Types (JsonRpc, JsonRpcErr)

{- METHOD -}

type RpcEchoMethod = JsonRpc "echo" String String String

{- HANDLER -}

-- | Echoes message back as a JSON-RPC response. Used for testing the server.
echo
  :: String
  -> ReaderHandler SidechainHttpServerConfig (Either (JsonRpcErr String) String)
echo = withChainIndexHandler . ChainIndex.Echo.echo
