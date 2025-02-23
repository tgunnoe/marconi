{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Marconi.ChainIndex.Legacy.Indexers where

import Cardano.Api (
  Block (Block),
  BlockHeader (BlockHeader),
  BlockInMode (BlockInMode),
  ChainPoint (ChainPoint),
  Hash,
  ScriptData,
  SlotNo,
 )
import Cardano.Api qualified as C
import Cardano.Api.Extended qualified as CE
import Cardano.Api.Extended.Streaming (
  BlockEvent (BlockEvent, blockInMode),
  ChainSyncEvent (RollBackward, RollForward),
  ChainSyncEventException (NoIntersectionFound),
  withChainSyncBlockEventStream,
 )
import Cardano.Api.Shelley qualified as C
import Cardano.BM.Trace (
  logError,
  logInfo,
 )
import Cardano.Ledger.Alonzo.TxWits qualified as Alonzo
import Control.Concurrent (
  MVar,
  forkIO,
  isEmptyMVar,
  modifyMVar,
  newEmptyMVar,
  newMVar,
  readMVar,
  tryPutMVar,
  tryReadMVar,
 )
import Control.Concurrent.QSemN (
  QSemN,
  newQSemN,
  signalQSemN,
  waitQSemN,
 )
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (
  TChan,
  dupTChan,
  newBroadcastTChanIO,
  readTChan,
  writeTChan,
 )
import Control.Exception (
  catch,
  finally,
  onException,
  throwIO,
 )
import Control.Exception.Base (throw)
import Control.Lens (makeLenses, view)
import Control.Lens.Operators (
  (%~),
  (&),
  (+~),
  (.~),
  (^.),
 )
import Control.Monad (
  forM_,
  forever,
  void,
  when,
 )
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Except (
  ExceptT,
  runExceptT,
 )
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text qualified as Text
import Data.Void (Void)
import Data.Word (Word64)
import Marconi.ChainIndex.Legacy.Error (
  IndexerError (CantInsertEvent, CantRollback, CantStartIndexer, Timeout),
  ignoreQueryError,
 )
import Marconi.ChainIndex.Legacy.Indexers.AddressDatum (
  AddressDatumDepth (AddressDatumDepth),
  AddressDatumHandle,
 )
import Marconi.ChainIndex.Legacy.Indexers.AddressDatum qualified as AddressDatum
import Marconi.ChainIndex.Legacy.Indexers.EpochState (EpochStateHandle)
import Marconi.ChainIndex.Legacy.Indexers.EpochState qualified as EpochState
import Marconi.ChainIndex.Legacy.Indexers.MintBurn qualified as MintBurn
import Marconi.ChainIndex.Legacy.Indexers.ScriptTx qualified as ScriptTx
import Marconi.ChainIndex.Legacy.Indexers.Utxo qualified as Utxo
import Marconi.ChainIndex.Legacy.Logging (chainSyncEventStreamLogging)
import Marconi.ChainIndex.Legacy.Node.Client.Retry (withNodeConnectRetry)
import Marconi.ChainIndex.Legacy.Types (
  IndexingDepth (MaxIndexingDepth, MinIndexingDepth),
  RunIndexerConfig (RunIndexerConfig),
  SecurityParam (SecurityParam),
  ShouldFailIfResync (ShouldFailIfResync),
  TargetAddresses,
  UtxoIndexerConfig,
 )
import Marconi.ChainIndex.Legacy.Utils qualified as Utils
import Marconi.Core.Storable qualified as Storable
import Ouroboros.Consensus.Ledger.Extended qualified as O
import Prettyprinter (
  align,
  indent,
  line,
  list,
  nest,
  pretty,
  (<+>),
 )
import Prometheus qualified as P
import Streaming qualified as S
import Streaming.Prelude qualified as S
import System.Directory (createDirectoryIfMissing)
import System.FilePath (
  takeDirectory,
  (</>),
 )
import System.Timeout (timeout)

-- DatumIndexer

scriptDataFromCardanoTxBody :: C.TxBody era -> Map (Hash ScriptData) ScriptData
scriptDataFromCardanoTxBody (C.ShelleyTxBody _ _ _ (C.TxBodyScriptData _ dats _) _ _) =
  extractData dats
  where
    extractData :: Alonzo.TxDats era -> Map (Hash ScriptData) ScriptData
    extractData (Alonzo.TxDats' xs) =
      Map.fromList
        . fmap ((\x -> (C.hashScriptDataBytes x, C.getScriptData x)) . C.fromAlonzoData)
        . Map.elems
        $ xs
scriptDataFromCardanoTxBody _ = mempty

data Buffer a = Buffer
  { _capacity :: !Word64
  , _bufferLength :: !Word64
  , _content :: !(Seq a)
  }

newBuffer :: Word64 -> Buffer a
newBuffer capacity = Buffer capacity 0 Seq.empty

makeLenses 'Buffer

{- | The way we synchronise channel consumption is by waiting on a QSemN for each
     of the spawn indexers to finish processing the current event.

     The channel is used to transmit the next event to the listening indexers. Note
     that even if the channel is unbound it will actually only ever hold one event
     because it will be blocked until the processing of the event finishes on all
     indexers.

     The indexer count is where we save the number of running indexers so we know for
     how many we are waiting.
-}
data Coordinator' a = Coordinator
  { _channel :: !(TChan (ChainSyncEvent a))
  , _errorVar :: !(MVar (IndexerError Void))
  , _barrier :: !QSemN
  , _indexerCount :: !Int
  , _buffer :: !(Buffer a)
  }

makeLenses 'Coordinator

type Coordinator = Coordinator' BlockEvent

initialCoordinator :: Int -> Word64 -> IO (Coordinator' a)
initialCoordinator indexerCount' minIndexingDepth =
  Coordinator
    <$> newBroadcastTChanIO
    <*> newEmptyMVar
    <*> newQSemN 0
    <*> pure indexerCount'
    <*> pure (newBuffer minIndexingDepth)

-- The points should/could provide shared access to the indexers themselves. The result
-- is a list of points (rather than just one) since it offers more resume possibilities
-- to the node (in the unlikely case there were some rollbacks during downtime).
type Worker =
  SecurityParam
  -> C.BlockNo
  -> Coordinator
  -> FilePath
  -> IO (Storable.StorablePoint ScriptTx.ScriptTxHandle)

utxoWorker_
  :: (Utxo.UtxoIndexer -> IO ())
  -- ^ Callback function used in the queryApi thread, needs to be non-blocking
  -> Utxo.Depth
  -> UtxoIndexerConfig
  -- ^ Utxo Indexer Configuration, containing targetAddresses and showReferenceScript flag
  -> Coordinator
  -> TChan (ChainSyncEvent BlockEvent)
  -> FilePath
  -> IO (IO (), C.ChainPoint)
utxoWorker_ callback depth utxoIndexerConfig Coordinator{_barrier, _errorVar} ch path = do
  -- open SQLite with depth=depth and DO NOT perform SQLite vacuum
  ix <- Utils.toException $ Utxo.open path depth False
  -- TODO consider adding a CLI param to allow user to perfomr Vaccum or not.
  mIndexer <- newMVar ix
  let process = \case
        RollForward (BlockEvent (BlockInMode block _) epochNo posixTime) ct ->
          let utxoEvents = Utxo.getUtxoEventsFromBlock utxoIndexerConfig block epochNo posixTime ct
           in void $ updateWith mIndexer _errorVar $ ignoreQueryError . Storable.insert utxoEvents
        RollBackward cp _ct ->
          void $
            updateWith mIndexer _errorVar $
              ignoreQueryError . Storable.rewind cp

      raiseError =
        tryPutMVar _errorVar $ CantInsertEvent "Utxo raised an uncaught exception"
      loop :: IO ()
      loop = forever $ finally (signalQSemN _barrier 1) $ do
        failWhenFull _errorVar
        readMVar mIndexer >>= callback
        event <- atomically . readTChan $ ch
        process event `onException` raiseError
  cp <- Utils.toException $ Storable.resumeFromStorage $ view Storable.handle ix
  pure (loop, cp)

utxoWorker
  :: (Utxo.UtxoIndexer -> IO ())
  -- ^ callback function used in the queryApi thread
  -> UtxoIndexerConfig
  -- ^ Utxo Indexer Configuration, containing targetAddresses and showReferenceScript flag
  -> Worker
utxoWorker callback utxoIndexerConfig securityParam _ coordinator path = do
  workerChannel <- atomically . dupTChan $ _channel coordinator
  (loop, cp) <-
    utxoWorker_
      callback
      (Utxo.Depth $ fromIntegral securityParam)
      utxoIndexerConfig
      coordinator
      workerChannel
      path
  void $ forkIO loop
  return cp

addressDatumWorker
  :: (Storable.StorableEvent AddressDatumHandle -> IO [()])
  -> Maybe TargetAddresses
  -> Worker
addressDatumWorker onInsert targetAddresses securityParam _ coordinator path = do
  workerChannel <- atomically . dupTChan $ _channel coordinator
  (loop, cp) <-
    addressDatumWorker_
      onInsert
      targetAddresses
      (AddressDatumDepth $ fromIntegral securityParam)
      coordinator
      workerChannel
      path
  void $ forkIO loop
  return cp

addressDatumWorker_
  :: (Storable.StorableEvent AddressDatumHandle -> IO [()])
  -> Maybe TargetAddresses
  -- ^ Target addresses to filter for
  -> AddressDatumDepth
  -> Coordinator
  -> TChan (ChainSyncEvent BlockEvent)
  -> FilePath
  -> IO (IO (), C.ChainPoint)
addressDatumWorker_ onInsert targetAddresses depth Coordinator{_barrier, _errorVar} ch path = do
  index <- Utils.toException $ AddressDatum.open path depth
  mIndex <- newMVar index
  let process = \case
        RollForward (BlockEvent (BlockInMode (Block (BlockHeader slotNo bh _) txs) _) _ _) _ -> do
          -- TODO Redo. Inefficient filtering
          let addressDatumIndexEvent =
                AddressDatum.toAddressDatumIndexEvent
                  (Utils.addressesToPredicate targetAddresses)
                  txs
                  (C.ChainPoint slotNo bh)
          void $ updateWith mIndex _errorVar $ Storable.insert addressDatumIndexEvent
          void $ onInsert addressDatumIndexEvent
        RollBackward cp _ct -> do
          void $ updateWith mIndex _errorVar $ Storable.rewind cp
      raiseError =
        tryPutMVar _errorVar $ CantInsertEvent "AddressDatum raised an uncaught exception"
      innerLoop :: IO ()
      innerLoop = forever $ finally (signalQSemN _barrier 1) $ do
        failWhenFull _errorVar
        event <- atomically . readTChan $ ch
        process event `onException` raiseError
  cp <- Utils.toException . Storable.resumeFromStorage . view Storable.handle $ index
  pure (innerLoop, cp)

-- * ScriptTx indexer

scriptTxWorker_
  :: (Storable.StorableEvent ScriptTx.ScriptTxHandle -> IO [()])
  -> ScriptTx.Depth
  -> Coordinator
  -> TChan (ChainSyncEvent BlockEvent)
  -> FilePath
  -> IO (IO (), C.ChainPoint, MVar ScriptTx.ScriptTxIndexer)
scriptTxWorker_ onInsert depth Coordinator{_barrier, _errorVar} ch path = do
  indexer <- Utils.toException $ ScriptTx.open path depth
  mIndexer <- newMVar indexer
  let process = \case
        RollForward (BlockEvent (BlockInMode (Block (BlockHeader slotNo hsh _) txs) _) _ _) _ct -> do
          let u = ScriptTx.toUpdate txs (ChainPoint slotNo hsh)
          void $ updateWith mIndexer _errorVar $ Storable.insert u
          void $ onInsert u
        RollBackward cp _ct -> do
          void $ updateWith mIndexer _errorVar $ Storable.rewind cp
      raiseError =
        tryPutMVar _errorVar $ CantInsertEvent "ScriptTx raised an uncaught exception"
      loop :: IO ()
      loop = forever $ finally (signalQSemN _barrier 1) $ do
        failWhenFull _errorVar
        event <- atomically . readTChan $ ch
        process event `onException` raiseError
  cp <- Utils.toException . Storable.resumeFromStorage . view Storable.handle $ indexer
  pure (loop, cp, mIndexer)

scriptTxWorker
  :: (Storable.StorableEvent ScriptTx.ScriptTxHandle -> IO [()])
  -> Worker
scriptTxWorker onInsert securityParam _ coordinator path = do
  workerChannel <- atomically . dupTChan $ _channel coordinator
  (loop, cp, _indexer) <-
    scriptTxWorker_
      onInsert
      (ScriptTx.Depth $ fromIntegral securityParam)
      coordinator
      workerChannel
      path
  void $ forkIO loop
  return cp

-- * Epoch state indexer

epochStateWorker_
  :: FilePath
  -> (Storable.State EpochStateHandle -> IO ())
  -> SecurityParam
  -> C.BlockNo
  -> Coordinator
  -> TChan (ChainSyncEvent BlockEvent)
  -> FilePath
  -> IO (IO b, C.ChainPoint, MVar (Storable.State EpochStateHandle))
epochStateWorker_
  nodeConfigPath
  callback
  securityParam
  currentNodeBlockNoAtStartup
  Coordinator{_barrier, _errorVar}
  ch
  dbPath = do
    nodeConfigE <- runExceptT $ C.readNodeConfig (C.File nodeConfigPath)
    nodeConfig <- either (throw . CantStartIndexer @Void . Text.pack . show) pure nodeConfigE
    genesisConfigE <- runExceptT $ C.readCardanoGenesisConfig nodeConfig
    genesisConfig <-
      either
        (throw . CantStartIndexer @Void . Text.pack . show . C.renderGenesisConfigError)
        pure
        genesisConfigE

    let extLedgerConfig = CE.mkExtLedgerConfig genesisConfig
        initialExtLedgerState = CE.mkInitExtLedgerState genesisConfig

    let ledgerStateDir = takeDirectory dbPath </> "ledgerStates"
    createDirectoryIfMissing False ledgerStateDir
    indexer <-
      Utils.toException $
        EpochState.open
          (O.getExtLedgerCfg extLedgerConfig)
          dbPath
          ledgerStateDir
          securityParam
          currentNodeBlockNoAtStartup

    cp <- Utils.toException $ Storable.resumeFromStorage $ view Storable.handle indexer
    indexerMVar <- newMVar indexer

    let process currentLedgerState currentEpochNo = \case
          RollForward (BlockEvent bim@(C.BlockInMode (C.Block (C.BlockHeader slotNo bh bn) _) _) _ _) chainTip -> do
            newLedgerState <-
              either
                (throw . CantStartIndexer @Void . Text.pack . show)
                pure
                $ CE.applyBlockExtLedgerState extLedgerConfig C.QuickValidation bim currentLedgerState
            let newEpochNo = EpochState.getEpochNo newLedgerState

            -- If the block is rollbackable, we always store the LedgerState. If the block is
            -- immutable, we only store it right at the beginning of a new epoch.
            let isFirstEventOfEpoch = newEpochNo > currentEpochNo
            let storableEvent =
                  EpochState.toStorableEvent
                    newLedgerState
                    slotNo
                    bh
                    bn
                    chainTip
                    securityParam
                    isFirstEventOfEpoch

            void $ updateWith indexerMVar _errorVar $ ignoreQueryError . Storable.insert storableEvent

            -- Compute new LedgerState given block and old LedgerState
            pure (newLedgerState, newEpochNo)
          RollBackward C.ChainPointAtGenesis _ct -> do
            void $ updateWith indexerMVar _errorVar $ ignoreQueryError . Storable.rewind C.ChainPointAtGenesis
            pure (initialExtLedgerState, Nothing)
          RollBackward cp' _ct -> do
            newIndex <- updateWith indexerMVar _errorVar $ ignoreQueryError . Storable.rewind cp'

            -- We query the LedgerState from disk at the point where we need to rollback to.
            -- For that to work, we need to be sure that any volatile LedgerState are stored
            -- on disk. For immutable LedgerStates, they are only stored on disk at the first
            -- slot of an epoch.
            maybeLedgerState <-
              runExceptT $ ignoreQueryError $ Storable.query newIndex (EpochState.LedgerStateAtPointQuery cp')
            case maybeLedgerState of
              Right (EpochState.LedgerStateAtPointResult (Just ledgerState)) -> pure (ledgerState, EpochState.getEpochNo ledgerState)
              Right (EpochState.LedgerStateAtPointResult Nothing) -> do
                void $
                  tryPutMVar _errorVar $
                    CantRollback
                      "Could not find LedgerState from which to rollback from in EpochState indexer. Should not happen!"
                pure (initialExtLedgerState, Nothing)
              Right _ -> do
                void $
                  tryPutMVar _errorVar $
                    CantRollback
                      "LedgerStateAtPointQuery returned a result mismatch when applying a rollback. Should not happen!"
                pure (initialExtLedgerState, Nothing)
              Left err -> do
                void $ tryPutMVar _errorVar err
                pure (initialExtLedgerState, Nothing)

        raiseError =
          tryPutMVar _errorVar $ CantInsertEvent "EpochState raised an uncaught exception"

        loop currentLedgerState currentEpochNo = forever $ finally (signalQSemN _barrier 1) $ do
          failWhenFull _errorVar
          void $ readMVar indexerMVar >>= callback
          event <- atomically $ readTChan ch
          (newLedgerState, newEpochNo) <-
            process currentLedgerState currentEpochNo event
              `onException` raiseError
          loop newLedgerState newEpochNo

    pure (loop initialExtLedgerState (EpochState.getEpochNo initialExtLedgerState), cp, indexerMVar)

epochStateWorker
  :: FilePath
  -> (Storable.State EpochStateHandle -> IO ())
  -> Worker
epochStateWorker nodeConfigPath callback securityParam currentNodeBlockNo coordinator path = do
  workerChannel <- atomically . dupTChan $ _channel coordinator
  (loop, cp, _indexer) <-
    epochStateWorker_
      nodeConfigPath
      callback
      securityParam
      currentNodeBlockNo
      coordinator
      workerChannel
      path
  void $ forkIO loop
  return cp

-- * Mint/burn indexer

mintBurnWorker_
  :: SecurityParam
  -> (MintBurn.MintBurnIndexer -> IO ())
  -> Maybe (NonEmpty (C.PolicyId, Maybe C.AssetName))
  -- ^ Target assets to filter for
  -> Coordinator
  -> TChan (ChainSyncEvent BlockEvent)
  -> FilePath
  -> IO (IO b, C.ChainPoint)
mintBurnWorker_ securityParam callback mAssets c ch dbPath = do
  indexer <- Utils.toException (MintBurn.open dbPath securityParam)
  indexerMVar <- newMVar indexer
  cp <- Utils.toException $ Storable.resumeFromStorage $ view Storable.handle indexer
  let process = \case
        RollForward (BlockEvent blockInMode _ _) _ct -> do
          let event' = MintBurn.toUpdate mAssets blockInMode
          void $
            updateWith indexerMVar (c ^. errorVar) $
              ignoreQueryError . Storable.insert event'
        RollBackward cp' _ct ->
          void $ updateWith indexerMVar (c ^. errorVar) $ ignoreQueryError . Storable.rewind cp'
      raiseError =
        tryPutMVar (c ^. errorVar) $ CantInsertEvent "MintBurn raised an uncaught exception"
      loop = forever $ finally (signalQSemN (c ^. barrier) 1) $ do
        failWhenFull (c ^. errorVar)
        void $ readMVar indexerMVar >>= callback
        event <- atomically $ readTChan ch
        process event `onException` raiseError
  pure (loop, cp)

mintBurnWorker
  :: (MintBurn.MintBurnIndexer -> IO ())
  -> Maybe (NonEmpty (C.PolicyId, Maybe C.AssetName))
  -- ^ Target assets to filter for
  -> Worker
mintBurnWorker callback mAssets securityParam _ coordinator path = do
  workerChannel <- atomically . dupTChan $ _channel coordinator
  (loop, cp) <- mintBurnWorker_ securityParam callback mAssets coordinator workerChannel path
  void $ forkIO loop
  return cp

-- | Initialize the 'Coordinator' which coordinates a list of indexers to index at the same speeds.
initializeCoordinatorFromIndexers
  :: SecurityParam
  -> IndexingDepth
  -> [(Worker, FilePath)]
  -> IO Coordinator
initializeCoordinatorFromIndexers (SecurityParam sec) indexingDepth indexers = do
  let resolvedDepth = case indexingDepth of
        MinIndexingDepth w -> w
        MaxIndexingDepth -> sec
  when (resolvedDepth > sec) $
    fail "Indexing depth is greater than security param"
  initialCoordinator (length indexers) resolvedDepth

getStartingPointsFromIndexers
  :: SecurityParam
  -> C.BlockNo
  -> [(Worker, FilePath)]
  -> Coordinator
  -> IO [ChainPoint]
getStartingPointsFromIndexers securityParam currentNodeBlockNo indexers coordinator =
  mapM (\(ix, fp) -> ix securityParam currentNodeBlockNo coordinator fp) indexers

mkIndexerStream'
  :: (a -> SlotNo)
  -> Coordinator' a
  -> S.Stream (S.Of (ChainSyncEvent a)) IO r
  -> IO ()
mkIndexerStream' f coordinator =
  S.foldM_ safeStep initial finish
  where
    initial = pure coordinator

    indexersHealthCheck :: Coordinator' a -> IO ()
    indexersHealthCheck c = do
      err <- tryReadMVar (c ^. errorVar)
      forM_ err throw

    blockAfterChainPoint C.ChainPointAtGenesis _bim = True
    blockAfterChainPoint (C.ChainPoint slotNo' _) bim = f bim > slotNo'

    bufferIsFull c = c ^. buffer . bufferLength >= c ^. buffer . capacity

    pushOldestEvent
      :: (Applicative f)
      => Coordinator' a
      -> a
      -> C.ChainTip
      -> f (Coordinator' a, Maybe (ChainSyncEvent a))
    pushOldestEvent c bim ct = case c ^. buffer . content of
      buff Seq.:|> event' -> do
        let c' = c & buffer . content .~ (bim Seq.:<| buff)
        pure (c', Just $ RollForward event' ct)
      Seq.Empty -> do
        pure (c, Just $ RollForward bim ct)

    enqueueEvent
      :: (Applicative f)
      => Coordinator' a
      -> a
      -> f (Coordinator' a, Maybe (ChainSyncEvent a))
    enqueueEvent c bim = do
      let c' =
            c
              & buffer . content %~ (bim Seq.:<|)
              & buffer . bufferLength +~ 1
      pure (c', Nothing)

    coordinatorHandleEvent c (RollForward bim ct)
      | bufferIsFull c = pushOldestEvent c bim ct
      | otherwise = enqueueEvent c bim
    coordinatorHandleEvent c e@(RollBackward cp _) = case c ^. buffer . content of
      buff@(_ Seq.:|> event') ->
        let content' = Seq.dropWhileL (blockAfterChainPoint cp) buff
            c' =
              c
                & buffer . content .~ content'
                & buffer . bufferLength .~ fromIntegral (length content')
         in if blockAfterChainPoint cp event'
              then pure (c', Just e)
              else pure (c', Nothing)
      Seq.Empty -> pure (c, Just e)

    -- process a single execution step
    step c@Coordinator{_barrier, _errorVar, _indexerCount, _channel} event = do
      indexersHealthCheck c
      (c', mevent) <- coordinatorHandleEvent c event
      case mevent of
        Nothing -> signalQSemN _barrier _indexerCount
        Just event' -> atomically $ writeTChan _channel event'
      waitQSemN _barrier _indexerCount
      pure c'

    -- give 30 minutes (1800s) for a step to finish
    safeStep c event = do
      result <- timeout 1_800_000_000 $ step c event
      case result of
        Nothing -> error "At least one indexer is stuck, closing marconi"
        Just res -> pure res

    finish _ = pure ()

mkIndexerStream
  :: Coordinator
  -> S.Stream (S.Of (ChainSyncEvent BlockEvent)) IO r
  -> IO ()
mkIndexerStream = mkIndexerStream' (CE.bimSlotNo . blockInMode)

runIndexers
  :: RunIndexerConfig
  -> IndexingDepth
  -> ShouldFailIfResync
  -> [(Worker, Maybe FilePath)]
  -> IO ()
runIndexers
  ( RunIndexerConfig
      stdoutTrace
      retryConfig
      securityParam
      networkId
      cliChainPoint
      socketPath
    )
  indexingDepth
  (ShouldFailIfResync shouldFailIfResync)
  indexerList = do
    withNodeConnectRetry stdoutTrace retryConfig socketPath $ do
      currentNodeBlockNo <- Utils.toException $ Utils.queryCurrentNodeBlockNo @Void networkId socketPath
      let indexers = mapMaybe sequenceA indexerList
      coordinator <- initializeCoordinatorFromIndexers securityParam indexingDepth indexers
      let indexerDepth =
            let SecurityParam s = securityParam
             in case indexingDepth of
                  MinIndexingDepth d -> SecurityParam $ s - d + 1
                  MaxIndexingDepth -> SecurityParam 1
      resumablePoints <-
        getStartingPointsFromIndexers indexerDepth currentNodeBlockNo indexers coordinator
      let oldestCommonChainPoint = minimum resumablePoints
          resumePoint = case cliChainPoint of
            C.ChainPointAtGenesis -> oldestCommonChainPoint -- User didn't specify a chain point, use oldest common chain point,
            cliCp -> cliCp -- otherwise use what was provided on CLI.
      logInfo stdoutTrace $
        "Resumable points for each indexer:"
          <> line
          <> indent 4 (align (list (fmap pretty resumablePoints)))

      -- Possible runtime failure if an indexer with a non-genesis resumable point will resume from
      -- genesis.
      if shouldFailIfResync
        && elem C.ChainPointAtGenesis resumablePoints
        && any (\case ChainPoint{} -> True; _ -> False) resumablePoints
        then do
          logError stdoutTrace $
            nest
              4
              ( "At least one indexer has a non-genesis resumable point, while the oldest common resumable point between indexers is genesis."
                  <> line
                  <> "Are you sure you want to restart syncing that indexer from genesis?"
                  <> line
                  <> "If so, remove the '--fail-if-resyncing-from-genesis' flag."
              )
        else do
          let stream =
                mkIndexerStream coordinator
                  . chainSyncEventStreamLogging stdoutTrace
                  . updateProcessedBlocksMetric
              runChainSyncStream = withChainSyncBlockEventStream socketPath networkId [resumePoint] stream
              whenNoIntersectionFound NoIntersectionFound = do
                logError stdoutTrace $
                  "No intersection found when looking for the chain point"
                    <+> pretty resumePoint
                    <> "."
                    <+> "Please check the slot number and the block hash do belong to the chain."
                signalQSemN (coordinator ^. barrier) (coordinator ^. indexerCount)
           in finally
                (runChainSyncStream `catch` whenNoIntersectionFound)
                (waitForIndexersToFinishProcessingLastEvent coordinator)
    where
      waitForIndexersToFinishProcessingLastEvent :: Coordinator' a -> IO ()
      waitForIndexersToFinishProcessingLastEvent coordinator = do
        let secondsBeforeTimeout = 180
        logInfo stdoutTrace $
          "Stopping indexing. Waiting for indexers to finish their work (timeout after "
            <> pretty secondsBeforeTimeout
            <> "s) ..."
        res <-
          timeout (secondsBeforeTimeout * 1_000_000) $
            waitQSemN (coordinator ^. barrier) (coordinator ^. indexerCount)
        case res of
          Just _ -> logInfo stdoutTrace "Done!"
          -- TODO: When it's possible, let's put some useful information in this exception
          Nothing -> throwIO (Timeout @Void "Timed out.")

updateProcessedBlocksMetric
  :: S.Stream (S.Of (ChainSyncEvent BlockEvent)) IO r
  -> S.Stream (S.Of (ChainSyncEvent BlockEvent)) IO r
updateProcessedBlocksMetric s = S.effect $ do
  processedBlocksCounter <-
    liftIO $
      P.register $
        P.counter (P.Info "processed_blocks_counter" "Number of processed blocks")
  processedRollbacksCounter <-
    liftIO $
      P.register $
        P.counter (P.Info "processed_rollbacks_counter" "Number of processed rollbacks")
  pure $ S.chain (updateMetrics processedBlocksCounter processedRollbacksCounter) s
  where
    updateMetrics
      :: P.Counter -> P.Counter -> ChainSyncEvent BlockEvent -> IO ()
    updateMetrics processedBlocksCounter _ RollForward{} =
      P.incCounter processedBlocksCounter
    updateMetrics _ processedRollbacksCounter RollBackward{} =
      P.incCounter processedRollbacksCounter

updateWith
  :: MVar a
  -> MVar err
  -> (a -> ExceptT err IO a)
  -> IO a
updateWith xBox errBox f = modifyMVar xBox $ \x -> do
  res <- runExceptT $ f x
  case res of
    Left err -> do
      tryPutMVar errBox err $> (x, x)
    Right x' -> pure (x', x')

failWhenFull :: (Show a) => (MonadIO m) => MVar a -> m ()
failWhenFull x = do
  isEmpty <- liftIO $ isEmptyMVar x
  if isEmpty
    then pure ()
    else do
      err <- liftIO $ readMVar x
      error $ "an indexer raised an error: " <> show err
