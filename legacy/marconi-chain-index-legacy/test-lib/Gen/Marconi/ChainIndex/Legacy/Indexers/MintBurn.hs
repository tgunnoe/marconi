{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:target-version=1.0.0 #-}

module Gen.Marconi.ChainIndex.Legacy.Indexers.MintBurn (
  genIndexerWithEvents,
  genTxMintValueRange,
  genMintEvents,
  genTxWithMint,
  genTxWithAsset,
  genTxMintValue,
  genAssetName,
  commonMintingPolicyId,
  getValue,
  mintsToPolicyAssets,
) where

import Cardano.Api qualified as C
import Cardano.Api.Shelley qualified as C
import Control.Lens ((^.))
import Control.Monad (foldM, forM, replicateM)
import Control.Monad.IO.Class (liftIO)
import Data.Bifunctor (first)
import Data.Coerce (coerce)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.String (fromString)
import Hedgehog (Gen, forAll, (===))
import Hedgehog qualified as H
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Marconi.ChainIndex.Legacy.Error (raiseException)
import Marconi.ChainIndex.Legacy.Indexers.MintBurn qualified as MintBurn
import Marconi.ChainIndex.Legacy.Logging ()
import Marconi.ChainIndex.Legacy.Types (SecurityParam)
import Marconi.Core.Storable qualified as Storable
import PlutusLedgerApi.V1 qualified as PlutusV1
import PlutusLedgerApi.V2 qualified as PlutusV2
import PlutusTx qualified
import Test.Gen.Cardano.Api.Typed qualified as CGen

genIndexerWithEvents
  :: FilePath
  -> H.PropertyT IO (MintBurn.MintBurnIndexer, [MintBurn.TxMintEvent], (SecurityParam, Int))
genIndexerWithEvents dbPath = do
  (events, (bufferSize, nTx)) <- forAll genMintEvents
  -- Report buffer overflow:
  let overflow = fromIntegral bufferSize < length events
  H.classify "No events created at all" $ null events
  H.classify "Buffer doesn't overflow" $ not (null events) && not overflow
  H.classify "Buffer overflows" $ not (null events) && overflow
  indexer <- liftIO $ do
    let storeEvent event = raiseException . Storable.insert (MintBurn.MintBurnEvent event)
    indexer <- raiseException $ MintBurn.open dbPath bufferSize
    foldM (flip storeEvent) indexer events
  pure (indexer, events, (bufferSize, nTx))

{- | Generate transactions which have mints inside, then extract
 TxMintEvent's from these, then return them with buffer size and
 number of transactions.
-}
genMintEvents :: Gen ([MintBurn.TxMintEvent], (SecurityParam, Int))
genMintEvents = do
  bufferSize <- Gen.integral (Range.constant 1 10)
  nTx <-
    Gen.choice -- Number of events:
      [ Gen.constant 0 --  1. no events generated
      , Gen.integral $ Range.constant 0 bufferSize --  2. buffer not filled
      , Gen.integral $ Range.constant (bufferSize + 1) (bufferSize * 2) --  3. guaranteed buffer overflow
      ]
  -- Generate transactions
  txAll' <- forM [0 .. (nTx - 1)] $ \slotNoInt -> do
    tx <- genTxWithMint =<< genTxMintValueRange (-100) 100
    pure (tx, fromIntegral slotNoInt :: C.SlotNo)
  -- Filter out Left C.TxBodyError
  txAll <- forM txAll' $ \case
    (Right tx, slotNo) -> pure (tx, slotNo)
    (Left txBodyError, _) ->
      fail $
        "Failed to create a transaction! This shouldn't happen, the generator should be fixed. TxBodyError: "
          <> show txBodyError
  let buildEvent ix (tx, slotNo) =
        MintBurn.TxMintEvent slotNo dummyBlockHeaderHash dummyBlockNo . pure
          <$> MintBurn.txMints Nothing ix tx
      events = mapMaybe (uncurry buildEvent) $ zip [0 ..] txAll
  pure (events, (fromIntegral bufferSize, nTx))

genTxWithMint
  :: C.TxMintValue C.BuildTx C.BabbageEra
  -> Gen (Either C.TxBodyError (C.Tx C.BabbageEra))
genTxWithMint txMintValue = do
  txbc <- CGen.genTxBodyContent C.BabbageEra
  txIn <- CGen.genTxIn
  initialPP <- CGen.genProtocolParameters C.BabbageEra
  let updatedPP =
        initialPP
          { C.protocolParamUTxOCostPerByte = Just 1
          , C.protocolParamPrices = Just $ C.ExecutionUnitPrices 1 1
          , C.protocolParamMaxTxExUnits = Just $ C.ExecutionUnits 1 1
          , C.protocolParamMaxBlockExUnits = Just $ C.ExecutionUnits 1 1
          , C.protocolParamMaxValueSize = Just 1
          , C.protocolParamCollateralPercent = Just 1
          , C.protocolParamMaxCollateralInputs = Just 1
          }
  pure $ do
    ledgerPP <-
      first C.TxBodyProtocolParamsConversionError $
        C.convertToLedgerProtocolParameters C.ShelleyBasedEraBabbage updatedPP
    let txbc' =
          txbc
            { C.txMintValue = txMintValue
            , C.txInsCollateral = C.TxInsCollateral C.CollateralInBabbageEra [txIn]
            , C.txProtocolParams = C.BuildTxWith $ Just ledgerPP
            }
    txb <- C.createAndValidateTransactionBody txbc'
    pure $ C.signShelleyTransaction txb []

-- | Helper to create tx with @commonMintingPolicy@, @assetName@ and @quantity@
genTxWithAsset :: C.AssetName -> C.Quantity -> Gen (Either C.TxBodyError (C.Tx C.BabbageEra))
genTxWithAsset assetName quantity =
  genTxWithMint $
    C.TxMintValue
      C.MultiAssetInBabbageEra
      mintedValues
      (C.BuildTxWith $ Map.singleton policyId policyWitness)
  where
    (policyId, policyWitness, mintedValues) = mkMintValue commonMintingPolicy [(assetName, quantity)]

genTxMintValue :: Gen (C.TxMintValue C.BuildTx C.BabbageEra)
genTxMintValue = genTxMintValueRange 1 100

genTxMintValueRange :: Integer -> Integer -> Gen (C.TxMintValue C.BuildTx C.BabbageEra)
genTxMintValueRange min' max' = do
  n :: Int <- Gen.integral (Range.constant 1 5)
  -- n :: Int <- Gen.integral (Range.constant 0 5)
  -- TODO: fix bug RewindableIndex.Storable.rewind and change range to start from 0.
  policyAssets <- replicateM n genAsset
  let (policyId, policyWitness, mintedValues) = mkMintValue commonMintingPolicy policyAssets
      buildInfo = C.BuildTxWith $ Map.singleton policyId policyWitness
  pure $ C.TxMintValue C.MultiAssetInBabbageEra mintedValues buildInfo
  where
    genAsset :: Gen (C.AssetName, C.Quantity)
    genAsset = (,) <$> genAssetName <*> genQuantity
    genQuantity = coerce @Integer @C.Quantity <$> Gen.integral (Range.constant min' max')

genAssetName :: Gen C.AssetName
genAssetName = coerce @_ @C.AssetName <$> Gen.bytes (Range.constant 1 5)

-- * Helpers

-- | Remove events that remained in buffer.
onlyPersisted :: Int -> [a] -> [a]
onlyPersisted bufferSize events = take (eventsPersisted bufferSize $ length events) events

eventsPersisted :: Int -> Int -> Int
eventsPersisted bufferSize nEvents =
  let
    -- Number of buffer flushes
    bufferFlushesN =
      let (n, m) = nEvents `divMod` bufferSize
       in if m == 0 then n - 1 else n
    -- Number of events persisted
    numberOfEventsPersisted = bufferFlushesN * bufferSize
   in
    numberOfEventsPersisted

type MintingPolicy = PlutusTx.CompiledCode (PlutusTx.BuiltinData -> PlutusTx.BuiltinData -> ())

mkMintValue
  :: MintingPolicy
  -> [(C.AssetName, C.Quantity)]
  -> (C.PolicyId, C.ScriptWitness C.WitCtxMint C.BabbageEra, C.Value)
mkMintValue policy policyAssets = (policyId, policyWitness, mintedValues)
  where
    serialisedPolicyScript :: C.PlutusScript C.PlutusScriptV1
    serialisedPolicyScript = C.PlutusScriptSerialised $ PlutusV2.serialiseCompiledCode policy

    policyId :: C.PolicyId
    policyId = C.scriptPolicyId $ C.PlutusScript C.PlutusScriptV1 serialisedPolicyScript :: C.PolicyId

    executionUnits :: C.ExecutionUnits
    executionUnits = C.ExecutionUnits{C.executionSteps = 300000, C.executionMemory = 1000}
    redeemer :: C.ScriptRedeemer
    redeemer = C.unsafeHashableScriptData $ C.fromPlutusData $ PlutusV1.toData ()
    policyWitness :: C.ScriptWitness C.WitCtxMint C.BabbageEra
    policyWitness =
      C.PlutusScriptWitness
        C.PlutusScriptV1InBabbage
        C.PlutusScriptV1
        (C.PScript serialisedPolicyScript)
        C.NoScriptDatumForMint
        redeemer
        executionUnits

    mintedValues :: C.Value
    mintedValues = C.valueFromList $ map (first (C.AssetId policyId)) policyAssets

commonMintingPolicy :: MintingPolicy
commonMintingPolicy = $$(PlutusTx.compile [||\_ _ -> ()||])

commonMintingPolicyId :: C.PolicyId
commonMintingPolicyId =
  let serialisedPolicyScript =
        C.PlutusScriptSerialised $ PlutusV2.serialiseCompiledCode commonMintingPolicy
   in C.scriptPolicyId $ C.PlutusScript C.PlutusScriptV1 serialisedPolicyScript :: C.PolicyId

{- | Recreate an indexe, useful because the sql connection to a
 :memory: database can be reused.
-}
mkNewIndexerBasedOnOldDb
  :: Storable.State MintBurn.MintBurnHandle -> IO (Storable.State MintBurn.MintBurnHandle)
mkNewIndexerBasedOnOldDb indexer =
  let MintBurn.MintBurnHandle sqlCon k = indexer ^. Storable.handle
   in raiseException $ Storable.emptyState (fromIntegral k) (MintBurn.MintBurnHandle sqlCon k)

dummyBlockHeaderHash :: C.Hash C.BlockHeader
dummyBlockHeaderHash =
  fromString "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    :: C.Hash C.BlockHeader

dummyBlockNo :: C.BlockNo
dummyBlockNo = 12

equalSet :: (H.MonadTest m, Show a, Ord a) => [a] -> [a] -> m ()
equalSet a b = Set.fromList a === Set.fromList b

getPolicyAssets :: C.TxMintValue C.BuildTx C.BabbageEra -> [(C.PolicyId, C.AssetName, C.Quantity)]
getPolicyAssets = \case
  (C.TxMintValue C.MultiAssetInBabbageEra mintedValues (C.BuildTxWith _policyIdToWitnessMap)) ->
    let extractAssetId (assetId, quantity) = case assetId of
          C.AssetId policyId assetName -> Just (policyId, assetName, quantity)
          C.AdaAssetId -> Nothing
     in mapMaybe extractAssetId $ C.valueToList mintedValues
  _ -> []

getValue :: C.TxMintValue C.BuildTx C.BabbageEra -> Maybe C.Value
getValue = \case
  C.TxMintValue C.MultiAssetInBabbageEra value (C.BuildTxWith _policyIdToWitnessMap) -> Just value
  _ -> Nothing

mintsToPolicyAssets :: [MintBurn.MintAsset] -> [(C.PolicyId, C.AssetName, C.Quantity)]
mintsToPolicyAssets =
  map
    ( \mint ->
        ( MintBurn.mintAssetPolicyId mint
        , MintBurn.mintAssetAssetName mint
        , MintBurn.mintAssetQuantity mint
        )
    )
