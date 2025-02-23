{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Spec.Marconi.Sidechain.Api.Query.Indexers.Utxo (tests) where

import Cardano.Api qualified as C
import Cardano.Slotting.Slot (WithOrigin (At, Origin))
import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson qualified as Aeson
import Data.List qualified as List
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (unpack)
import Data.Traversable (for)
import Gen.Marconi.ChainIndex.Legacy.Indexers.Utxo (genShelleyEraUtxoEvents)
import Hedgehog (Property, assert, forAll, property, (===))
import Hedgehog qualified
import Helpers (addressAnyToShelley)
import Marconi.ChainIndex.Legacy.Indexers.Utxo (BlockInfo (BlockInfo, _blockInfoSlotNo))
import Marconi.ChainIndex.Legacy.Indexers.Utxo qualified as Utxo
import Marconi.Sidechain.Api.Query.Indexers.Utxo qualified as AddressUtxoIndexer
import Marconi.Sidechain.Api.Routes (
  AddressUtxoResult,
  GetCurrentSyncedBlockResult (GetCurrentSyncedBlockResult),
  GetUtxosFromAddressResult (GetUtxosFromAddressResult, unAddressUtxosResult),
 )
import Marconi.Sidechain.Api.Routes qualified as Routes
import Marconi.Sidechain.Env qualified as Env
import Network.JsonRpc.Client.Types ()
import Network.JsonRpc.Types (JsonRpcResponse (Result))
import Spec.Marconi.Sidechain.RpcClientAction (
  RpcClientAction (insertUtxoEventsAction, queryAddressUtxosAction, querySyncedBlockAction),
  mocUtxoWorker,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testPropertyNamed)

tests :: RpcClientAction -> TestTree
tests rpcClientAction =
  testGroup
    "marconi-sidechain-utxo query Api Specs"
    [ testPropertyNamed
        "marconi-sidechain-utxo, Insert events and query for utxo's with address in the generated ShelleyEra targetAddresses"
        "queryTargetAddressTest"
        queryTargetAddressTest
    , testGroup
        "marconi-sidechain-utxo JSON-RPC test-group"
        [ testPropertyNamed
            "Stores UtxoEvents and retrieve them through the RPC server using an RPC client"
            "propUtxoEventInsertionAndJsonRpcQueryRoundTrip"
            (propUtxoEventInsertionAndJsonRpcQueryRoundTrip rpcClientAction)
        , testPropertyNamed
            "stores UtxoEvents, and get the current sync slot"
            "propUtxoEventInsertionAndJsonRpcCurrentSlotQuery"
            (propUtxoEventInsertionAndJsonRpcCurrentSlotQuery rpcClientAction)
        ]
    ]

-- | generate some Utxo events, store and fetch the Utxos, then make sure JSON conversion is idempotent
queryTargetAddressTest :: Property
queryTargetAddressTest = property $ do
  events <- forAll genShelleyEraUtxoEvents
  env <- liftIO $ Env.mkAddressUtxoIndexerEnv Nothing
  let callback :: Utxo.UtxoIndexer -> IO ()
      callback = atomically . AddressUtxoIndexer.updateEnvState env
  liftIO $ mocUtxoWorker callback events
  fetchedRows <-
    liftIO
      . fmap (fmap concat)
      . traverse
        ( \addr ->
            fmap unAddressUtxosResult
              <$> AddressUtxoIndexer.findByAddress
                env
                (Utxo.QueryUtxoByAddress addr (Utxo.lessThanOrEqual $ C.SlotNo maxBound))
        )
      . Set.toList
      . Set.fromList -- remove the potential duplicate addresses
      . fmap Utxo._address
      . concatMap Utxo.ueUtxos
      $ events

  let numOfFetched = length fetchedRows
      expected = List.sortOn (fmap Routes.utxoResultTxIn) fetchedRows

      retrieved =
        List.sortOn (fmap Routes.utxoResultTxIn)
          . mapMaybe (Aeson.decode . Aeson.encode)
          $ fetchedRows

  Hedgehog.classify "Retrieved Utxos are greater than or Equal to 5" $ numOfFetched >= 5
  Hedgehog.classify "Retrieved Utxos are greater than 1" $ numOfFetched > 1

  Hedgehog.assert (not . null $ fetchedRows)
  expected === retrieved

{- | Test roundtrip Utxos thruough JSON-RPC http server.
 We compare a represenation of the generated UtxoEvents
 with those fetched from the JSON-RPC  server. The purpose of this is:
   + RPC server routes the request to the correct handler
   + Events are serialized/deserialized thru the RPC layer and it various wrappers correctly
-}
propUtxoEventInsertionAndJsonRpcQueryRoundTrip
  :: RpcClientAction
  -> Property
propUtxoEventInsertionAndJsonRpcQueryRoundTrip action = property $ do
  events <- forAll genShelleyEraUtxoEvents
  liftIO $ insertUtxoEventsAction action events
  let (qAddresses :: [String]) =
        Set.toList
          . Set.fromList
          . fmap (unpack . C.serialiseAddress)
          . mapMaybe (addressAnyToShelley . Utxo._address)
          . foldMap Utxo.ueUtxos
          $ events
  rpcResponses <- liftIO $ for qAddresses (queryAddressUtxosAction action)
  let fetchedUtxoRows = foldMap fromQueryResult rpcResponses
      expected =
        Map.fromList
          . fmap (\x -> (Routes.utxoResultTxIn x, x))
          $ fetchedUtxoRows

      retrieved =
        Map.fromList
          . fmap (\x -> (Routes.utxoResultTxIn x, x))
          . mapMaybe (Aeson.decode . Aeson.encode)
          $ fetchedUtxoRows

  Hedgehog.assert (not . null $ fetchedUtxoRows)
  retrieved === expected

fromQueryResult :: JsonRpcResponse e GetUtxosFromAddressResult -> [AddressUtxoResult]
fromQueryResult (Result _ (GetUtxosFromAddressResult rows)) = rows
fromQueryResult _otherResponses = []

{- | Test inserting events and querying the current sync point
 We check that the response is the last sync point of the inserted events.
 The purpose of this is:
   + RPC server routes the request to the correct handler
   + Events are serialized/deserialized thru the RPC layer and it various wrappers correctly
-}
propUtxoEventInsertionAndJsonRpcCurrentSlotQuery
  :: RpcClientAction
  -> Property
propUtxoEventInsertionAndJsonRpcCurrentSlotQuery action = property $ do
  events <- forAll genShelleyEraUtxoEvents
  let chainPoints =
        Utxo.getChainPoint
          . Utxo.blockInfoToChainPointRow
          . Utxo.ueBlockInfo
          <$> events
  Hedgehog.cover 90 "Non empty events" $ not $ null events

  -- Now, we are storing the events in the index
  liftIO $ insertUtxoEventsAction action events

  Result _ (GetCurrentSyncedBlockResult resp _tip) <- liftIO $ querySyncedBlockAction action
  Hedgehog.cover 40 "Should have some significant non genesis chainpoints results" $
    resp /= Origin && fmap _blockInfoSlotNo resp > At (C.SlotNo 0)
  assert $ getBlockInfoChainPoint resp `elem` chainPoints
  where
    getBlockInfoChainPoint Origin = C.ChainPointAtGenesis
    getBlockInfoChainPoint (At (BlockInfo sn bhh _ _ _)) = C.ChainPoint sn bhh
