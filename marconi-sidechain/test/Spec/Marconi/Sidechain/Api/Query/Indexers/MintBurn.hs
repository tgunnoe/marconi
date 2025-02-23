{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module Spec.Marconi.Sidechain.Api.Query.Indexers.MintBurn (tests) where

import Cardano.Api (AssetName, PolicyId)
import Control.Concurrent.STM (atomically)
import Control.Lens.Operators ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Traversable (for)
import Gen.Marconi.ChainIndex.Legacy.Indexers.MintBurn (genMintEvents)
import Gen.Marconi.ChainIndex.Legacy.Indexers.MintBurn qualified as Gen
import Gen.Marconi.ChainIndex.Legacy.Types qualified as Gen
import Hedgehog (Property, forAll, property, (===))
import Hedgehog qualified
import Marconi.ChainIndex.Legacy.Indexers.MintBurn (
  MintAsset (mintAssetAssetName, mintAssetPolicyId),
 )
import Marconi.ChainIndex.Legacy.Indexers.MintBurn qualified as MintBurn
import Marconi.Sidechain.Api.Query.Indexers.MintBurn (queryByPolicyAndAssetId)
import Marconi.Sidechain.Api.Query.Indexers.MintBurn qualified as MintBurnIndexer
import Marconi.Sidechain.Api.Query.Indexers.Utxo qualified as Utxo
import Marconi.Sidechain.Api.Routes (
  BurnTokenEventResult,
  GetBurnTokenEventsResult (GetBurnTokenEventsResult),
 )
import Marconi.Sidechain.Env (
  mintBurnIndexerEnvIndexer,
  sidechainMintBurnIndexer,
 )
import Marconi.Sidechain.Env qualified as Env
import Marconi.Sidechain.Error (QueryExceptions (QueryError, UntrackedPolicy))
import Network.JsonRpc.Client.Types ()
import Network.JsonRpc.Types (JsonRpcResponse (Result))
import Spec.Marconi.Sidechain.RpcClientAction (
  RpcClientAction (insertUtxoEventsAction),
  insertMintBurnEventsAction,
  mocMintBurnWorker,
  mocUtxoWorker,
  queryMintBurnAction,
 )
import Test.Gen.Cardano.Api.Typed qualified as CGen
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testPropertyNamed)

tests :: RpcClientAction -> TestTree
tests rpcClientAction =
  testGroup
    "marconi-sidechain-minting-policy query Api Specs"
    [ testPropertyNamed
        "marconi-sidechain-minting-policy"
        "queryMintingPolicyTest"
        queryMintingPolicyTest
    , testPropertyNamed
        "marconi-sidechain-mint-burn invalid TxId"
        "propUnmatchedTxIdIsRejected"
        propUnmatchedTxIdIsRejected
    , testPropertyNamed
        "marconi-sidechain-mint-burn invalid policyId"
        "propUnmatchedPolicyId"
        propUnmatchedPolicyId
    , testPropertyNamed
        "marconi-sidechain-mint-burn invalid assetName"
        "propUnmatchedAssetName"
        propUnmatchedAssetName
    , {- , testPropertyNamed
          "marconi-sidechain-mint-burn invalid interval"
          "propInvalidIntervalError"
          propInvalidInterval
          -}
      testGroup
        "marconi-sidechain-mint-burn JSON-RPC test-group"
        [ testPropertyNamed
            "Stores MintBurnEvents and retrieve them through the RPC server using an RPC client"
            "propMintBurnEventInsertionAndJsonRpcQueryRoundTrip"
            (propMintBurnEventInsertionAndJsonRpcQueryRoundTrip rpcClientAction)
        ]
    ]

-- | generate some MintBurn events, store and fetch the AssetTxResults, then make sure JSON conversion is idempotent
queryMintingPolicyTest :: Property
queryMintingPolicyTest = property $ do
  (events, (securityParam, _)) <- forAll genMintEvents
  env <-
    liftIO $
      Env.SidechainIndexersEnv
        <$> Env.mkAddressUtxoIndexerEnv Nothing
        <*> Env.mkMintEventIndexerEnv Nothing
        <*> Env.mkEpochStateEnv
  let callback :: MintBurn.MintBurnIndexer -> IO ()
      callback =
        atomically
          . MintBurnIndexer.updateEnvState
            (env ^. sidechainMintBurnIndexer . mintBurnIndexerEnvIndexer)
  liftIO $
    mocUtxoWorker (atomically . Utxo.updateEnvState (env ^. Env.sidechainAddressUtxoIndexer)) []
  liftIO $ mocMintBurnWorker callback $ MintBurn.MintBurnEvent <$> events
  fetchedRows <-
    liftIO
      . fmap (fmap (concatMap pure))
      . traverse
        ( \params ->
            MintBurnIndexer.queryByAssetIdAtSlot
              securityParam
              env
              (mintAssetPolicyId params)
              (Just $ mintAssetAssetName params)
              Nothing
              Nothing
        )
      . Set.toList
      . Set.fromList -- required to remove the potential duplicate assets
      . concatMap (NonEmpty.toList . MintBurn.txMintAsset)
      . foldMap MintBurn.txMintEventTxAssets
      $ events

  let numOfFetched = length fetchedRows
  Hedgehog.classify "Retrieved MintBurnEvents are greater than or Equal to 5" $ numOfFetched >= 5
  Hedgehog.classify "Retrieved MintBurnEvents are greater than 1" $ numOfFetched > 1

  (Set.fromList . mapMaybe (Aeson.decode . Aeson.encode) $ fetchedRows) === Set.fromList fetchedRows

-- | make sure we throw an error if the given txId in the query doesn't exist
propUnmatchedTxIdIsRejected :: Property
propUnmatchedTxIdIsRejected = property $ do
  (events, (securityParam, _)) <- forAll genMintEvents
  env <-
    liftIO $
      Env.SidechainIndexersEnv
        <$> Env.mkAddressUtxoIndexerEnv Nothing
        <*> Env.mkMintEventIndexerEnv Nothing
        <*> Env.mkEpochStateEnv
  let callback :: MintBurn.MintBurnIndexer -> IO ()
      callback =
        atomically
          . MintBurnIndexer.updateEnvState
            (env ^. sidechainMintBurnIndexer . mintBurnIndexerEnvIndexer)
      txIds = events >>= fmap MintBurn.txMintTxId . MintBurn.txMintEventTxAssets
  txId <- forAll CGen.genTxId
  Hedgehog.classify "txId `elem` txIds" $ txId `elem` txIds
  Hedgehog.classify "txId `notElem` txIds" $ txId `notElem` txIds
  pId <- forAll Gen.genPolicyId
  liftIO $
    mocUtxoWorker (atomically . Utxo.updateEnvState (env ^. Env.sidechainAddressUtxoIndexer)) []
  liftIO $ mocMintBurnWorker callback $ MintBurn.MintBurnEvent <$> events
  result <- liftIO $ queryByPolicyAndAssetId securityParam env pId Nothing Nothing (Just txId)
  case result of
    Left (QueryError _) -> Hedgehog.assert $ txId `notElem` txIds
    _other -> do
      Hedgehog.footnote "Invalid txId wasn't caught"
      Hedgehog.assert $ txId `elem` txIds

-- | make sure we throw an error if the given policyId isn't tracked
propUnmatchedPolicyId :: Property
propUnmatchedPolicyId = property $ do
  (events, (securityParam, _)) <- forAll genMintEvents
  pId <- forAll Gen.genPolicyId
  pId2 <- forAll Gen.genPolicyId
  Hedgehog.cover 10 "pId == pId2" $ pId == pId2
  Hedgehog.cover 50 "pId /= pId2" $ pId /= pId2
  env <-
    liftIO $
      Env.SidechainIndexersEnv
        <$> Env.mkAddressUtxoIndexerEnv Nothing
        <*> Env.mkMintEventIndexerEnv (Just $ pure (pId, Nothing))
        <*> Env.mkEpochStateEnv
  let callback :: MintBurn.MintBurnIndexer -> IO ()
      callback =
        atomically
          . MintBurnIndexer.updateEnvState
            (env ^. sidechainMintBurnIndexer . mintBurnIndexerEnvIndexer)
  liftIO $
    mocUtxoWorker (atomically . Utxo.updateEnvState (env ^. Env.sidechainAddressUtxoIndexer)) []
  liftIO $ mocMintBurnWorker callback $ MintBurn.MintBurnEvent <$> events
  result <- liftIO $ queryByPolicyAndAssetId securityParam env pId2 Nothing Nothing Nothing
  case result of
    Left (UntrackedPolicy _ _) -> Hedgehog.assert $ pId /= pId2
    _other -> do
      Hedgehog.footnote "Unmatched policyId wasn't caught"
      Hedgehog.assert $ pId == pId2

-- | make sure we throw an error if the given policyId+assetname isn't tracked
propUnmatchedAssetName :: Property
propUnmatchedAssetName = property $ do
  (events, (securityParam, _)) <- forAll genMintEvents
  pId <- forAll Gen.genPolicyId
  assetName <- forAll Gen.genAssetName
  assetName2 <- forAll Gen.genAssetName
  Hedgehog.classify "assetName == assetName2" $ assetName == assetName2
  Hedgehog.classify "assetName /= assetName2" $ assetName /= assetName2
  env <-
    liftIO $
      Env.SidechainIndexersEnv
        <$> Env.mkAddressUtxoIndexerEnv Nothing
        <*> Env.mkMintEventIndexerEnv (Just $ pure (pId, Just assetName))
        <*> Env.mkEpochStateEnv
  let callback :: MintBurn.MintBurnIndexer -> IO ()
      callback =
        atomically
          . MintBurnIndexer.updateEnvState
            (env ^. sidechainMintBurnIndexer . mintBurnIndexerEnvIndexer)
  liftIO $
    mocUtxoWorker (atomically . Utxo.updateEnvState (env ^. Env.sidechainAddressUtxoIndexer)) []
  liftIO $ mocMintBurnWorker callback $ MintBurn.MintBurnEvent <$> events
  result <- liftIO $ queryByPolicyAndAssetId securityParam env pId (Just assetName2) Nothing Nothing
  case result of
    Left (UntrackedPolicy _ _) -> Hedgehog.assert $ assetName /= assetName2
    _other -> do
      Hedgehog.footnote "Unmatched assetName wasn't caught"
      Hedgehog.assert $ assetName == assetName2

{- Commented at the moment because the generator doesn't file enough mint/burn events

-- | make sure we throw an error if the given txId in the query doesn't exist
propInvalidInterval :: Property
propInvalidInterval = property $ do
  (events, _) <- forAll genMintEvents
  env <- liftIO $ initializeSidechainEnv Nothing Nothing Nothing
  let callback :: MintBurn.MintBurnIndexer -> IO ()
      txIds = events >>= fmap MintBurn.txMintTxId . MintBurn.txMintEventTxAssets
      callback =
        atomically
          . MintBurnIndexer.updateEnvState
            (env ^. sidechainEnvIndexers . sidechainMintBurnIndexer . mintBurnIndexerEnvIndexer)
  txId <- forAll $ Hedgehog.Gen.element txIds
  liftIO $ mocUtxoWorker (atomically . Utxo.updateEnvState (env ^. Env.sidechainAddressUtxoIndexer)) []
  liftIO $ mocMintBurnWorker callback $ MintBurn.MintBurnEvent <$> events
  pId <- forAll Gen.genPolicyId
  result <- liftIO $ queryByPolicyAndAssetId env pId Nothing (Just 0) (Just txId)
  case result of
    Left (QueryError _) -> Hedgehog.success
    _other -> fail "Invalid txId wasn't caught"
    -}

{- | Test roundtrip MintBurnEvents thruough JSON-RPC http server.
 We compare a represenation of the generated MintBurnEvents
 with those fetched from the JSON-RPC  server. The purpose of this is:
   + RPC server routes the request to the correct handler
   + Events are serialized/deserialized thru the RPC layer and it various wrappers correctly
-}
propMintBurnEventInsertionAndJsonRpcQueryRoundTrip
  :: RpcClientAction
  -> Property
propMintBurnEventInsertionAndJsonRpcQueryRoundTrip action = property $ do
  (events, _) <- forAll genMintEvents
  liftIO $ insertMintBurnEventsAction action $ MintBurn.MintBurnEvent <$> events
  liftIO $ insertUtxoEventsAction action []
  let (qParams :: [(PolicyId, Maybe AssetName)]) =
        Set.toList $
          Set.fromList $
            fmap (\mps -> (mintAssetPolicyId mps, Just $ mintAssetAssetName mps)) $
              concatMap (NonEmpty.toList . MintBurn.txMintAsset) $
                foldMap MintBurn.txMintEventTxAssets events
  rpcResponses <- liftIO $ for qParams (queryMintBurnAction action)
  let fetchedBurnEventRows = concatMap fromQueryResult rpcResponses

  (Set.fromList $ mapMaybe (Aeson.decode . Aeson.encode) fetchedBurnEventRows)
    === Set.fromList fetchedBurnEventRows

fromQueryResult :: JsonRpcResponse e GetBurnTokenEventsResult -> [BurnTokenEventResult]
fromQueryResult (Result _ (GetBurnTokenEventsResult rows)) = rows
fromQueryResult _otherResponses = []
