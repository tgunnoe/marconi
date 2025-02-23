{-# LANGUAGE OverloadedStrings #-}

module Spec.Marconi.ChainIndex.Legacy.Orphans (tests) where

import Cardano.Api qualified as C
import Data.Aeson qualified as Aeson
import Database.SQLite.Simple.FromField qualified as SQL
import Database.SQLite.Simple.Internal qualified as SQL
import Database.SQLite.Simple.ToField qualified as SQL
import Gen.Marconi.ChainIndex.Legacy.Types qualified as Gen
import Hedgehog (Property, forAll, property, tripping)
import Hedgehog.Range qualified as Range
import Marconi.ChainIndex.Legacy.Orphans ()
import Test.Gen.Cardano.Api.Typed qualified as CGen
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testPropertyNamed)

tests :: TestTree
tests =
  testGroup
    "Spec.Marconi.ChainIndex.Legacy.Orphans"
    [ testGroup
        "ToField/FromField rountrip"
        [ testPropertyNamed
            "C.Hash C.BlockHeader"
            "propSQLFieldRoundtripBlockHeaderHash"
            propSQLFieldRoundtripBlockHeaderHash
        , testPropertyNamed
            "C.SlotNo"
            "propSQLFieldRoundtripSlotNo"
            propSQLFieldRoundtripSlotNo
        , testPropertyNamed
            "C.BlockNo"
            "propSQLFieldRoundtripBlockNo"
            propSQLFieldRoundtripBlockNo
        , testPropertyNamed
            "C.AddressAny"
            "propSQLFieldRoundtripAddressAny"
            propSQLFieldRoundtripAddressAny
        , testPropertyNamed
            "C.Hash C.ScriptData"
            "propSQLFieldRoundtripScriptDataHash"
            propSQLFieldRoundtripScriptDataHash
        , testPropertyNamed
            "C.ScriptData"
            "propSQLFieldRoundtripScriptData"
            propSQLFieldRoundtripScriptData
        , testPropertyNamed
            "C.TxId"
            "propSQLFieldRoundtripTxId"
            propSQLFieldRoundtripTxId
        , testPropertyNamed
            "C.TxIx"
            "propSQLFieldRoundtripTxIx"
            propSQLFieldRoundtripTxIx
        , testPropertyNamed
            "C.Value"
            "propSQLFieldRoundtripValue"
            propSQLFieldRoundtripValue
        , testPropertyNamed
            "C.ScriptInAnyLang"
            "propSQLFieldRoundtripScriptInAnyLang"
            propSQLFieldRoundtripScriptInAnyLang
        , testPropertyNamed
            "C.ScriptHash"
            "propSQLFieldRoundtripScriptHash"
            propSQLFieldRoundtripScriptHash
        , testPropertyNamed
            "C.PolicyId"
            "propSQLFieldRoundtripPolicyId"
            propSQLFieldRoundtripPolicyId
        , testPropertyNamed
            "C.EpochNo"
            "propSQLFieldRoundtripEpochNo"
            propSQLFieldRoundtripEpochNo
        , testPropertyNamed
            "C.Lovelace"
            "propSQLFieldRoundtripLovelace"
            propSQLFieldRoundtripLovelace
        , testPropertyNamed
            "C.PoolId"
            "propSQLFieldRoundtripPoolId"
            propSQLFieldRoundtripPoolId
            -- TODO Activate once we update to the latest node version
            -- , testPropertyNamed
            --       "Ledger.Nonce"
            --       "propSQLFieldRoundtripNonce"
            --       propSQLFieldRoundtripNonce
        ]
    , testGroup
        "ToJSON/FromJSON rountrip"
        [ testPropertyNamed
            "C.AddressAny"
            "propJsonRoundtripAddressAny"
            propJsonRoundtripAddressAny
        , testPropertyNamed
            "C.ScriptData"
            "propJsonRoundtripScriptData"
            propJsonRoundtripScriptData
        ]
    ]

propSQLFieldRoundtripBlockHeaderHash :: Property
propSQLFieldRoundtripBlockHeaderHash = property $ do
  bh <- forAll Gen.genHashBlockHeader
  tripping bh SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripSlotNo :: Property
propSQLFieldRoundtripSlotNo = property $ do
  slotNo <- forAll Gen.genSlotNo
  tripping slotNo SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripBlockNo :: Property
propSQLFieldRoundtripBlockNo = property $ do
  bn <- forAll Gen.genBlockNo
  tripping bn SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripAddressAny :: Property
propSQLFieldRoundtripAddressAny = property $ do
  (C.AddressInEra _ addr) <- forAll $ Gen.genAddressInEra C.BabbageEra
  tripping (C.toAddressAny addr) SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propJsonRoundtripAddressAny :: Property
propJsonRoundtripAddressAny = property $ do
  (C.AddressInEra _ addr) <- forAll $ Gen.genAddressInEra C.BabbageEra
  tripping (C.toAddressAny addr) Aeson.encode Aeson.eitherDecode

propSQLFieldRoundtripScriptDataHash :: Property
propSQLFieldRoundtripScriptDataHash = property $ do
  dh <- forAll Gen.genHashScriptData
  tripping dh SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripScriptData :: Property
propSQLFieldRoundtripScriptData = property $ do
  dh <- forAll $ C.getScriptData <$> CGen.genHashableScriptData
  tripping dh SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propJsonRoundtripScriptData :: Property
propJsonRoundtripScriptData = property $ do
  d <- forAll $ C.getScriptData <$> CGen.genHashableScriptData
  tripping d Aeson.encode Aeson.eitherDecode

propSQLFieldRoundtripTxId :: Property
propSQLFieldRoundtripTxId = property $ do
  txId <- forAll CGen.genTxId
  tripping txId SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripTxIx :: Property
propSQLFieldRoundtripTxIx = property $ do
  txIx <- forAll Gen.genTxIndex
  tripping txIx SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripValue :: Property
propSQLFieldRoundtripValue = property $ do
  txIx <- forAll $ CGen.genValue Gen.genAssetId (Gen.genQuantity (Range.linear 1 10))
  tripping txIx SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripScriptInAnyLang :: Property
propSQLFieldRoundtripScriptInAnyLang = property $ do
  s <- forAll CGen.genScriptInAnyLang
  tripping s SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripScriptHash :: Property
propSQLFieldRoundtripScriptHash = property $ do
  sh <- forAll CGen.genScriptHash
  tripping sh SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripPolicyId :: Property
propSQLFieldRoundtripPolicyId = property $ do
  p <- forAll Gen.genPolicyId
  tripping p SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripEpochNo :: Property
propSQLFieldRoundtripEpochNo = property $ do
  p <- forAll Gen.genEpochNo
  tripping p SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripLovelace :: Property
propSQLFieldRoundtripLovelace = property $ do
  p <- forAll CGen.genLovelace
  tripping p SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

propSQLFieldRoundtripPoolId :: Property
propSQLFieldRoundtripPoolId = property $ do
  p <- forAll Gen.genPoolId
  tripping p SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)

-- propSQLFieldRoundtripNonce :: Property
-- propSQLFieldRoundtripNonce = property $ do
--     p <- forAll (arbitrary :: Gen Ledger.Nonce)
--     tripping p SQL.toField (\sqlData -> SQL.fromField $ SQL.Field sqlData 0)
