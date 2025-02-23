{-# LANGUAGE DataKinds #-}

-- | A sample servant json-rpc client for marconi-sidechain
module Main where

import Data.Either (fromRight)
import Data.Proxy (Proxy (Proxy))
import Marconi.Sidechain.Api.Routes (
  GetUtxosFromAddressParams (GetUtxosFromAddressParams),
  JsonRpcAPI,
  interval,
 )
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.JsonRpc.Client.Types ()
import Network.JsonRpc.Types (
  JsonRpcResponse (Ack, Errors, Result),
  UnusedRequestParams (UnusedRequestParams),
 )
import Servant.API ((:<|>) ((:<|>)))
import Servant.Client (
  BaseUrl (BaseUrl),
  ClientEnv,
  HasClient (Client),
  Scheme (Http),
  client,
  hoistClient,
  mkClientEnv,
  runClientM,
 )

-- | an address to test
bech32Address :: String
bech32Address =
  "addr_test1vryusxht8rgz4g6twrjz4y8gss66w202vtfyk84wahmguzgh5mejc"

-- | We assume the json-rpc server is running on local machine, port 3000
url :: BaseUrl
url = BaseUrl Http "localhost" 3000 ""

{- | start json-rpc client
 Note, we use default port, 3000,  [defaultSettings](https://hackage.haskell.org/package/warp-3.3.23/docs/Network-Wai-Handler-Warp.html#v:defaultSettings)
-}
main :: IO ()
main = do
  putStrLn "Starting servant client "
  manager' <- newManager defaultManagerSettings
  let env = mkClientEnv manager' url
  let (rpcEcho :<|> rpcTargets :<|> _ :<|> rpcUtxos :<|> _ :<|> _ :<|> _) = getClients env
  let boundaries = fromRight (error "the provided interval is correct") (interval Nothing (Just maxBound))
  -- RPC calls
  msg <- rpcEcho "marconi client calling ???" --  return the echo message
  addresses <- rpcTargets UnusedRequestParams --  get the targetAddresss
  --  get utxos for this address
  utxos <- rpcUtxos $ GetUtxosFromAddressParams bech32Address boundaries
  printResults msg
  printResults addresses
  printResults utxos

  putStrLn "servant client has completed its work."

-- | Print results of the RPC call
printResults :: (Show e, Show r) => JsonRpcResponse r e -> IO ()
printResults (Result _ r) = print r
printResults (Ack w) = putStrLn $ "Unexpected `Ack` Received from server: " <> show w
printResults (Errors _ e) = putStrLn $ "Unexpected error: " <> show e

hoistClientApi :: Proxy JsonRpcAPI -- RPC Api end points
hoistClientApi = Proxy

-- hoist to IO monad for running the client
getClients :: ClientEnv -> Client IO JsonRpcAPI
getClients clientEnv =
  hoistClient
    hoistClientApi
    ( fmap (either (error . show) id)
        . flip runClientM clientEnv
    )
    (client hoistClientApi)
