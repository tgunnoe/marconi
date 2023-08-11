{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Spec.Marconi.ChainIndex.Experimental.Indexers.Utxo (
  tests,
  getTimedUtxosEvents,
  genUtxo,
) where

import Cardano.Api qualified as C
import Control.Lens ((^.), (^..))
import Control.Monad (join, void)
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (mapMaybe)

import Marconi.ChainIndex.Experimental.Indexers.Utxo qualified as Utxo
import Marconi.Core.Experiment qualified as Core

import Control.Concurrent qualified as Concurrent
import Control.Lens qualified as Lens
import Control.Monad.Trans.Class (MonadTrans (lift))
import Data.List ((\\))
import Gen.Marconi.ChainIndex.Mockchain qualified as Gen
import Hedgehog ((===))
import Hedgehog qualified
import Hedgehog.Gen qualified
import Hedgehog.Gen qualified as Hedgehog
import Hedgehog.Range qualified
import Marconi.ChainIndex.Experimental.Extract.WithDistance (WithDistance (WithDistance))
import Marconi.ChainIndex.Types (TxIndexInBlock (TxIndexInBlock))
import Test.Gen.Cardano.Api.Typed qualified as CGen
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testPropertyNamed)

tests :: TestTree
tests =
  testGroup
    "Spec.Marconi.ChainIndex.Experimental.Indexers.Utxo"
    [ testGroup
        "Indexer"
        [ testPropertyNamed
            "EventAt query works for utxos"
            "propRoundTripAtSlotUtxo"
            propRoundTripAtSlotUtxo
        , testPropertyNamed
            "UtxoIndexer can retrieve all the utxos it stores"
            "propRoundTripUtxo"
            propRoundTripUtxo
        , testPropertyNamed
            "EventAt query works as a list indexer"
            "propActLikeListIndexerOnEventAt"
            propActLikeListIndexerOnEventAt
        ]
    , testGroup
        "Runner"
        [ testPropertyNamed
            "Retrieve an event at a tracked address"
            "propRunnerTracksSelectedAddress"
            propRunnerTracksSelectedAddress
        , testPropertyNamed
            "Don't find anything at untrack address"
            "propRunnerDoesntTrackUnselectedAddress"
            propRunnerDoesntTrackUnselectedAddress
        ]
    , testPropertyNamed
        "JSON event tripping test"
        "propTrippingUtxoJSON"
        propTrippingUtxoJSON
    ]

-- | We can retrieve the event at a given slot
propRoundTripAtSlotUtxo :: Hedgehog.Property
propRoundTripAtSlotUtxo = Hedgehog.property $ do
  events <- Hedgehog.forAll $ getTimedUtxosEvents <$> Gen.genMockchain
  event <- Hedgehog.forAll $ Hedgehog.Gen.element events
  emptyIndexer <- Hedgehog.evalExceptT $ Utxo.mkUtxoIndexer ":memory:"
  indexer <- Hedgehog.evalExceptT $ Core.indexAll events emptyIndexer
  retrievedEvents <-
    Hedgehog.evalExceptT $ Core.query (event ^. Core.point) Core.EventAtQuery indexer
  event ^. Core.event === retrievedEvents

-- | We can retrieve all the events
propRoundTripUtxo :: Hedgehog.Property
propRoundTripUtxo = Hedgehog.property $ do
  events <- Hedgehog.forAll $ getTimedUtxosEvents <$> Gen.genMockchain
  let filterNonEmpty (Core.Timed _ Nothing) = Nothing
      filterNonEmpty (Core.Timed p (Just utxos)) = Just $ Core.Timed p utxos
      nonEmptyEvents = mapMaybe filterNonEmpty events
  emptyIndexer <- Hedgehog.evalExceptT $ Utxo.mkUtxoIndexer ":memory:"
  indexer <- Hedgehog.evalExceptT $ Core.indexAll events emptyIndexer
  retrievedEvents <- Hedgehog.evalExceptT $ Core.queryLatest Core.allEvents indexer
  nonEmptyEvents === retrievedEvents

-- | On EventAt, the 'UtxoIndexer' behaves like a 'ListIndexer'
propActLikeListIndexerOnEventAt :: Hedgehog.Property
propActLikeListIndexerOnEventAt = Hedgehog.property $ do
  events <- Hedgehog.forAll $ getTimedUtxosEvents <$> Gen.genMockchain
  testedEmptyIndexer <- Hedgehog.evalExceptT $ Utxo.mkUtxoIndexer ":memory:"
  indexer <- Hedgehog.evalExceptT $ Core.indexAll events testedEmptyIndexer
  referenceIndexer <- Core.indexAll events Core.mkListIndexer
  event <- Hedgehog.forAll $ Hedgehog.Gen.element events
  (testedResult :: Maybe (NonEmpty Utxo.Utxo)) <-
    Hedgehog.evalExceptT $ Core.query (event ^. Core.point) Core.EventAtQuery indexer
  refResult <-
    Hedgehog.evalExceptT $ Core.query (event ^. Core.point) Core.EventAtQuery referenceIndexer
  refResult === testedResult

-- | Check that an 'utxoWorker' tracks the given address
propRunnerTracksSelectedAddress :: Hedgehog.Property
propRunnerTracksSelectedAddress = Hedgehog.property $ do
  events <- Hedgehog.forAll Gen.genMockchain
  let utxoEvents = getTimedUtxosEvents events
      timedEvents = fmap (\evt -> Core.Timed (extractChainPoint evt) evt) events
      chainAddresses = utxoEvents ^.. traverse . Core.event . traverse . traverse . Utxo.address
      attachDistance dist = Just . WithDistance dist
      eventsWithDistance
        :: [Core.Timed C.ChainPoint (Maybe (WithDistance (Gen.MockBlock C.BabbageEra)))]
      eventsWithDistance = zipWith (fmap . attachDistance) [0 ..] $ reverse timedEvents
      resultAtAddress addr = NonEmpty.nonEmpty . NonEmpty.filter ((== addr) . Lens.view Utxo.address)
      eventAtAddress
        :: C.AddressAny
        -> [Core.Timed C.ChainPoint (Maybe (NonEmpty Utxo.Utxo))]
        -> [Core.Timed C.ChainPoint (NonEmpty Utxo.Utxo)]
      eventAtAddress addr =
        mapMaybe (traverse $ resultAtAddress addr)
          . mapMaybe sequence
  -- we take a subsett of the chain addresses to track them
  followedAddresses <-
    Hedgehog.forAll $
      Hedgehog.filter (not . null) $
        Hedgehog.subsequence chainAddresses
  -- if addresses are tracked, we choose one of them, otherwise we pick any address of the chain
  addr <-
    Hedgehog.forAll $
      Hedgehog.element $
        if null followedAddresses then chainAddresses else followedAddresses
  (ix, w) <-
    Hedgehog.evalExceptT $
      Utxo.utxoWorker
        "test"
        (Core.CatchupConfig 4 2)
        (Utxo.UtxoIndexerConfig followedAddresses True)
        getBlockUtxosEvent
        ":memory:"
  -- we create a coordinator to perform indexing through the worker
  coordinator <- lift $ Core.mkCoordinator [w]
  void $ Hedgehog.evalExceptT $ Core.indexAllDescending eventsWithDistance coordinator
  -- and we read through the indexer reference in the mvar
  indexer <- lift $ Concurrent.readMVar ix
  res <-
    Hedgehog.evalExceptT $
      Core.queryLatest (Core.EventsMatchingQuery $ resultAtAddress addr) indexer
  eventAtAddress addr utxoEvents === res

-- | Check that an 'utxoWorker' doesn't track other addresses
propRunnerDoesntTrackUnselectedAddress :: Hedgehog.Property
propRunnerDoesntTrackUnselectedAddress = Hedgehog.property $ do
  events <- Hedgehog.forAll Gen.genMockchain
  let utxoEvents = getTimedUtxosEvents events
      timedEvents = fmap (\evt -> Core.Timed (extractChainPoint evt) evt) events
      chainAddresses = utxoEvents ^.. traverse . Core.event . traverse . traverse . Utxo.address
      attachDistance dist = Just . WithDistance dist
      eventsWithDistance
        :: [Core.Timed C.ChainPoint (Maybe (WithDistance (Gen.MockBlock C.BabbageEra)))]
      eventsWithDistance = zipWith (fmap . attachDistance) [0 ..] $ reverse timedEvents
      resultAtAddress addr = NonEmpty.nonEmpty . NonEmpty.filter ((== addr) . Lens.view Utxo.address)
  -- we take a subsett of the chain addresses to track them,
  -- at least one address must be untracked
  let notAllAddresses xs = all ($ xs) [not . null, (/= chainAddresses)]
  followedAddresses <-
    Hedgehog.forAll $
      Hedgehog.filter notAllAddresses $
        Hedgehog.subsequence chainAddresses
  -- we choose one of the untracked
  let untrackedAddresses = chainAddresses \\ followedAddresses
  addr <-
    Hedgehog.forAll $ Hedgehog.element untrackedAddresses
  (ix, w) <-
    Hedgehog.evalExceptT $
      Utxo.utxoWorker
        "test"
        (Core.CatchupConfig 4 2)
        (Utxo.UtxoIndexerConfig followedAddresses True)
        getBlockUtxosEvent
        ":memory:"
  -- we create a coordinator to perform indexing through the worker
  coordinator <- lift $ Core.mkCoordinator [w]
  void $ Hedgehog.evalExceptT $ Core.indexAllDescending eventsWithDistance coordinator
  -- and we read through the indexer reference in the mvar
  indexer <- lift $ Concurrent.readMVar ix
  res <-
    Hedgehog.evalExceptT $
      Core.queryLatest (Core.EventsMatchingQuery $ resultAtAddress addr) indexer
  [] === res

-- | Standard tripping property for JSON
propTrippingUtxoJSON :: Hedgehog.Property
propTrippingUtxoJSON = Hedgehog.property $ do
  event <- Hedgehog.forAll genUtxo
  Hedgehog.tripping event Aeson.encode Aeson.eitherDecode

-- | Generate a list of @Utxo@ event from a mock chain
getTimedUtxosEvents
  :: (C.IsCardanoEra era)
  => Gen.Mockchain era
  -> [Core.Timed C.ChainPoint (Maybe (NonEmpty Utxo.Utxo))]
getTimedUtxosEvents =
  let getBlockTimedUtxosEvent block = Core.Timed (extractChainPoint block) $ getBlockUtxosEvent block
   in fmap getBlockTimedUtxosEvent

getBlockUtxosEvent :: (C.IsCardanoEra era) => Gen.MockBlock era -> Maybe (NonEmpty Utxo.Utxo)
getBlockUtxosEvent = NonEmpty.nonEmpty . join . zipWith Utxo.getUtxosFromTx [0 ..] . Gen.mockBlockTxs

extractChainPoint :: Gen.MockBlock era -> C.ChainPoint
extractChainPoint =
  let getChainPoint :: Gen.BlockHeader -> C.ChainPoint
      getChainPoint (Gen.BlockHeader slotNo blockHeaderHash _blockNo) =
        C.ChainPoint slotNo blockHeaderHash
   in getChainPoint . Gen.mockBlockChainPoint

-- Generate a random 'Utxo'
genUtxo :: Hedgehog.Gen Utxo.Utxo
genUtxo = do
  script <- CGen.genScriptInAnyLang
  let genAddressAny :: Hedgehog.Gen C.AddressAny
      genAddressAny = do
        (C.AddressInEra _ addr) <- CGen.genAddressInEra C.BabbageEra
        pure $ C.toAddressAny addr
      hashScriptInAnyLang :: C.ScriptInAnyLang -> C.ScriptHash
      hashScriptInAnyLang (C.ScriptInAnyLang _ s) = C.hashScript s
      scriptHash :: C.ScriptHash
      scriptHash = hashScriptInAnyLang script
  Utxo.Utxo
    <$> genAddressAny -- address
    <*> (TxIndexInBlock <$> Hedgehog.Gen.integral_ (Hedgehog.Range.constant 0 100)) -- txIndex
    <*> CGen.genTxIn -- txIn
    <*> Hedgehog.Gen.maybe CGen.genHashScriptData -- datumHash
    <*> CGen.genValue CGen.genAssetId (CGen.genQuantity $ Hedgehog.Range.constant 0 100) -- value
    <*> Hedgehog.Gen.maybe (pure script) -- inlineScript
    <*> Hedgehog.Gen.maybe (pure scriptHash) -- inlineScriptHash
