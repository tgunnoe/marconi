{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

{- | Module for indexing the stakepool delegation per epoch in the Cardano blockchain.

 This module will create the SQL tables:

 + table: epoch_sdd

 @
    |---------+--------+----------+--------+-----------------+---------|
    | epochNo | poolId | lovelace | slotNo | blockHeaderHash | blockNo |
    |---------+--------+----------+--------+-----------------+---------|
 @

 + table: epoch_nonce

 @
    |---------+-------+--------+-----------------+---------|
    | epochNo | nonce | slotNo | blockHeaderHash | blockNo |
    |---------+-------+--------+-----------------+---------|
 @

 To create those tables, we need to compute the `ExtLedgerState` from `ouroboros-network`
 (combination of `LedgerState, called `NewEpochState` in `cardano-ledger`, and the `HeaderState`)
 at each 'Rollforward' chain sync event. Using the `ExtLegderState`, we can easily compute the
 epoch nonce as well as the stake pool delegation for that epoch.

 The main issue with this indexer is that building the ExtLedgerState and saving it on disk for being
 able to resume is VERY resource intensive. Syncing time for this indexer is over 20h and uses
 about ~16GB of RAM (which will keep increasing as the blockchain continues to grow).

 Here is a synopsis of what this indexer does.

 We assume that the construction of 'LedgerState' is done outside of this indexer (this module).

   * the 'Storable.insert' function is called with the *first* event of an epoch (therefore, the
   first 'LedgerState' when starting a new epoch). We do that because we only care about the SDD
   (Stake Pool Delegation Distribution) of the snapshot of the previous epoch.

 Once the 'Storable.StorableEvent' is stored on disk, we perform various steps:

   1. we save the SDD for the current epoch in the `epoch_sdd` table
   2. we save the Nonce for the current epoch in the `epoch_nonce` table
   3. we save the 'LedgerState's in the filesystem as binary files (the ledger state file path has
   the format: `ledgerState_<SLOT_NO>_<BLOCK_HEADER_HASH>_<BLOCK_NO>.bin`). We only store a
   'LedgerState' if it's rollbackable or if the last one of a given epoch. This step is necessary
   for resuming the indexer.
   4. we delete immutable 'LedgerState' binary files expect latest one (this step is necessary for
   keeping the disk usage as low as possible).

 The indexer provides the following queries:

   * C.EpochNo -> Nonce
   * C.EpochNo -> SDD
   * C.ChainPoint -> LedgerState (query that is necessary for resuming)
-}
module Marconi.ChainIndex.Legacy.Indexers.EpochState (
  -- * EpochStateIndex
  EpochStateIndex,
  EpochStateHandle,
  EpochSDDRow (..),
  EpochNonceRow (..),
  StorableEvent (..),
  StorableQuery (..),
  StorableResult (..),
  toStorableEvent,
  open,
  getEpochNo,
) where

import Cardano.Api qualified as C
import Cardano.Api.Shelley qualified as C
import Cardano.Ledger.Compactible qualified as Ledger
import Cardano.Ledger.Era qualified as Ledger
import Cardano.Ledger.Shelley.API qualified as Ledger
import Cardano.Protocol.TPraos.API qualified as Shelley
import Cardano.Protocol.TPraos.Rules.Tickn qualified as Shelley
import Cardano.Slotting.Slot (EpochNo)

import Codec.CBOR.Read qualified as CBOR
import Codec.CBOR.Write qualified as CBOR
import Control.Monad (filterM, forM_, when)
import Control.Monad.Except (ExceptT)
import Control.Monad.Trans (MonadTrans (lift))

import Data.Aeson (FromJSON, ToJSON, Value (Object), object, (.:), (.:?), (.=))
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BS
import Data.Coerce (coerce)
import Data.Data (Proxy (Proxy))
import Data.Foldable (toList)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, listToMaybe, mapMaybe)
import Data.Ord (Down (Down))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Tuple (swap)
import Data.VMap qualified as VMap
import Database.SQLite.Simple qualified as SQL
import Database.SQLite.Simple.QQ (sql)

import GHC.Generics (Generic)

import Data.Aeson.Types (FromJSON (parseJSON), ToJSON (toJSON))
import Data.Void (Void)
import Marconi.ChainIndex.Legacy.Error (
  IndexerError (CantInsertEvent, CantQueryIndexer, CantRollback, CantStartIndexer),
  liftSQLError,
 )
import Marconi.ChainIndex.Legacy.Orphans ()
import Marconi.ChainIndex.Legacy.Types (SecurityParam)
import Marconi.ChainIndex.Legacy.Utils (
  chainPointOrGenesis,
  getBlockNoFromChainTip,
  isBlockRollbackable,
 )
import Marconi.ChainIndex.Legacy.Utils qualified as Util
import Marconi.Core.Storable (
  Buffered (persistToStorage),
  HasPoint (getPoint),
  Queryable (queryStorage),
  Resumable,
  Rewindable (rewindStorage),
  State,
  StorableEvent,
  StorableMonad,
  StorablePoint,
  StorableQuery,
  StorableResult,
  emptyState,
 )
import Marconi.Core.Storable qualified as Storable
import Ouroboros.Consensus.Cardano.Block qualified as O
import Ouroboros.Consensus.Config qualified as O
import Ouroboros.Consensus.HeaderValidation qualified as O
import Ouroboros.Consensus.Ledger.Extended qualified as O
import Ouroboros.Consensus.Protocol.Praos qualified as O
import Ouroboros.Consensus.Protocol.TPraos qualified as O
import Ouroboros.Consensus.Shelley.Ledger qualified as O
import Ouroboros.Consensus.Storage.Serialisation qualified as O
import System.Directory (listDirectory, removeFile)
import System.FilePath (dropExtension, (</>))
import Text.Read (readMaybe)

data EpochStateHandle = EpochStateHandle
  { _epochStateHandleTopLevelCfg :: !(O.TopLevelConfig (O.CardanoBlock O.StandardCrypto))
  , _epochStateHandleConnection :: !SQL.Connection
  , _epochStateHandleLedgerStateDirPath :: !FilePath
  , _epochStateHandleSecurityParam :: !SecurityParam
  , _epochStateHandleCurrentNodeBlockNoAtStartup :: !C.BlockNo
  -- ^ ONLY USED for removing LedgerState files that have become immutable (not rollbackable) when
  -- resuming.
  }

type instance StorableMonad EpochStateHandle = ExceptT (IndexerError Void) IO

data instance StorableEvent EpochStateHandle = EpochStateEvent
  { epochStateEventLedgerState
      :: Maybe (O.ExtLedgerState (O.HardForkBlock (O.CardanoEras O.StandardCrypto)))
  , epochStateEventEpochNo :: Maybe C.EpochNo
  , epochStateEventNonce :: Ledger.Nonce
  , epochStateEventSDD :: Map C.PoolId C.Lovelace
  , epochStateEventChainPoint :: C.ChainPoint
  , epochStateEventBlockNo :: C.BlockNo
  , epochStateEventChainTip :: C.ChainTip
  -- ^ Actual tip of the chain
  , epochStateEventIsFirstEventOfEpoch :: Bool
  }
  deriving stock (Eq, Show)

type instance StorablePoint EpochStateHandle = C.ChainPoint

instance HasPoint (StorableEvent EpochStateHandle) C.ChainPoint where
  getPoint (EpochStateEvent _ _ _ _ chainPoint _ _ _) = chainPoint

data instance StorableQuery EpochStateHandle
  = -- See Note [Active stake pool delegation query]
    ActiveSDDByEpochNoQuery C.EpochNo
  | NonceByEpochNoQuery C.EpochNo
  | LedgerStateAtPointQuery C.ChainPoint

data instance StorableResult EpochStateHandle
  = ActiveSDDByEpochNoResult [EpochSDDRow]
  | NonceByEpochNoResult (Maybe EpochNonceRow)
  | LedgerStateAtPointResult (Maybe (O.ExtLedgerState (O.CardanoBlock O.StandardCrypto)))
  deriving stock (Eq, Show)

type EpochStateIndex = State EpochStateHandle

toStorableEvent
  :: O.ExtLedgerState (O.HardForkBlock (O.CardanoEras O.StandardCrypto))
  -> C.SlotNo
  -> C.Hash C.BlockHeader
  -> C.BlockNo
  -> C.ChainTip
  -> SecurityParam
  -> Bool
  -- ^ Is the first event of the current epoch
  -> StorableEvent EpochStateHandle
toStorableEvent extLedgerState slotNo bhh bn chainTip securityParam isFirstEventOfEpoch = do
  let chainPoint = C.ChainPoint slotNo bhh
      doesStoreLedgerState =
        isBlockRollbackable securityParam bn (getBlockNoFromChainTip chainTip)
          || isBlockRollbackable securityParam (bn + 1) (getBlockNoFromChainTip chainTip)
          || isFirstEventOfEpoch
  EpochStateEvent
    (if doesStoreLedgerState then Just extLedgerState else Nothing)
    (getEpochNo extLedgerState)
    (getEpochNonce extLedgerState)
    (getStakeMap extLedgerState)
    chainPoint
    bn
    chainTip
    isFirstEventOfEpoch

{- | From LedgerState, get epoch stake pool delegation: a mapping of pool ID to amount staked in
 lovelace. We do this by getting the 'ssStakeMark stake snapshot and then use 'ssDelegations' and
 'ssStake' to resolve it into the desired mapping.
-}
getStakeMap
  :: O.ExtLedgerState (O.CardanoBlock O.StandardCrypto)
  -> Map C.PoolId C.Lovelace
getStakeMap extLedgerState = case O.ledgerState extLedgerState of
  O.LedgerStateByron _ -> mempty
  O.LedgerStateShelley st -> getStakeMapFromShelleyBlock st
  O.LedgerStateAllegra st -> getStakeMapFromShelleyBlock st
  O.LedgerStateMary st -> getStakeMapFromShelleyBlock st
  O.LedgerStateAlonzo st -> getStakeMapFromShelleyBlock st
  O.LedgerStateBabbage st -> getStakeMapFromShelleyBlock st
  O.LedgerStateConway st -> getStakeMapFromShelleyBlock st
  where
    getStakeMapFromShelleyBlock
      :: forall proto era c
       . (c ~ Ledger.EraCrypto era, c ~ O.StandardCrypto)
      => O.LedgerState (O.ShelleyBlock proto era)
      -> Map C.PoolId C.Lovelace
    getStakeMapFromShelleyBlock st = sdd
      where
        nes = O.shelleyLedgerState st :: Ledger.NewEpochState era

        stakeSnapshot = Ledger.ssStakeMark . Ledger.esSnapshots . Ledger.nesEs $ nes :: Ledger.SnapShot c

        stakes =
          Ledger.unStake $
            Ledger.ssStake stakeSnapshot

        delegations
          :: VMap.VMap VMap.VB VMap.VB (Ledger.Credential 'Ledger.Staking c) (Ledger.KeyHash 'Ledger.StakePool c)
        delegations = Ledger.ssDelegations stakeSnapshot

        sdd :: Map C.PoolId C.Lovelace
        sdd =
          Map.fromListWith (+) $
            map swap $
              catMaybes $
                VMap.elems $
                  VMap.mapWithKey
                    ( \cred spkHash ->
                        ( \c ->
                            ( C.Lovelace $ coerce $ Ledger.fromCompact c
                            , C.StakePoolKeyHash spkHash
                            )
                        )
                          <$> VMap.lookup cred stakes
                    )
                    delegations

getEpochNo
  :: O.ExtLedgerState (O.CardanoBlock O.StandardCrypto)
  -> Maybe EpochNo
getEpochNo extLedgerState = case O.ledgerState extLedgerState of
  O.LedgerStateByron _st -> Nothing
  O.LedgerStateShelley st -> getEpochNoFromShelleyBlock st
  O.LedgerStateAllegra st -> getEpochNoFromShelleyBlock st
  O.LedgerStateMary st -> getEpochNoFromShelleyBlock st
  O.LedgerStateAlonzo st -> getEpochNoFromShelleyBlock st
  O.LedgerStateBabbage st -> getEpochNoFromShelleyBlock st
  O.LedgerStateConway st -> getEpochNoFromShelleyBlock st
  where
    getEpochNoFromShelleyBlock = Just . Ledger.nesEL . O.shelleyLedgerState

data EpochSDDRow = EpochSDDRow
  { epochSDDRowEpochNo :: !C.EpochNo
  , epochSDDRowPoolId :: !C.PoolId
  , epochSDDRowLovelace :: !C.Lovelace
  , epochSDDRowSlotNo :: !(Maybe C.SlotNo)
  , epochSDDRowBlockHeaderHash :: !(Maybe (C.Hash C.BlockHeader))
  , epochSDDRowBlockNo :: !C.BlockNo
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (SQL.FromRow, SQL.ToRow)

instance FromJSON EpochSDDRow where
  parseJSON (Object v) =
    EpochSDDRow
      <$> (C.EpochNo <$> v .: "epochNo")
      <*> v
        .: "poolId"
      <*> v
        .: "lovelace"
      <*> (fmap C.SlotNo <$> v .:? "slotNo")
      <*> v
        .: "blockHeaderHash"
      <*> (C.BlockNo <$> v .: "blockNo")
  parseJSON _ = mempty

instance ToJSON EpochSDDRow where
  toJSON
    ( EpochSDDRow
        (C.EpochNo epochNo)
        poolId
        lovelace
        slotNo
        blockHeaderHash
        (C.BlockNo blockNo)
      ) =
      object
        [ "epochNo" .= epochNo
        , "poolId" .= poolId
        , "lovelace" .= lovelace
        , "slotNo" .= fmap C.unSlotNo slotNo
        , "blockHeaderHash" .= blockHeaderHash
        , "blockNo" .= blockNo
        ]

{- | Get Nonce per epoch given an extended ledger state. The Nonce is only available starting at
 Shelley era. Byron era has the neutral nonce.
-}
getEpochNonce :: O.ExtLedgerState (O.CardanoBlock O.StandardCrypto) -> Ledger.Nonce
getEpochNonce extLedgerState =
  case O.headerStateChainDep (O.headerState extLedgerState) of
    O.ChainDepStateByron _ -> Ledger.NeutralNonce
    O.ChainDepStateShelley st -> extractNonce st
    O.ChainDepStateAllegra st -> extractNonce st
    O.ChainDepStateMary st -> extractNonce st
    O.ChainDepStateAlonzo st -> extractNonce st
    O.ChainDepStateBabbage st -> extractNoncePraos st
    O.ChainDepStateConway st -> extractNoncePraos st
  where
    extractNonce :: O.TPraosState c -> Ledger.Nonce
    extractNonce =
      Shelley.ticknStateEpochNonce . Shelley.csTickn . O.tpraosStateChainDepState

    extractNoncePraos :: O.PraosState c -> Ledger.Nonce
    extractNoncePraos = O.praosStateEpochNonce

data EpochNonceRow = EpochNonceRow
  { epochNonceRowEpochNo :: !C.EpochNo
  , epochNonceRowNonce :: !Ledger.Nonce
  , epochNonceRowSlotNo :: !(Maybe C.SlotNo)
  , epochNonceRowBlockHeaderHash :: !(Maybe (C.Hash C.BlockHeader))
  , epochNonceRowBlockNo :: !C.BlockNo
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (SQL.FromRow, SQL.ToRow)

instance FromJSON EpochNonceRow where
  parseJSON (Object v) =
    EpochNonceRow
      <$> (C.EpochNo <$> v .: "epochNo")
      <*> (Ledger.Nonce <$> v .: "nonce")
      <*> (fmap C.SlotNo <$> v .:? "slotNo")
      <*> v
        .: "blockHeaderHash"
      <*> (C.BlockNo <$> v .: "blockNo")
  parseJSON _ = mempty

instance ToJSON EpochNonceRow where
  toJSON
    ( EpochNonceRow
        (C.EpochNo epochNo)
        nonce
        slotNo
        blockHeaderHash
        (C.BlockNo blockNo)
      ) =
      let nonceValue = case nonce of
            Ledger.NeutralNonce -> Nothing
            Ledger.Nonce n -> Just n
       in object
            [ "epochNo" .= epochNo
            , "nonce" .= nonceValue
            , "slotNo" .= fmap C.unSlotNo slotNo
            , "blockHeaderHash" .= blockHeaderHash
            , "blockNo" .= blockNo
            ]

data LedgerStateFileMetadata = LedgerStateFileMetadata
  { lsfMetaSlotNo :: !C.SlotNo
  , lsfMetaBlockHeaderHash :: !(C.Hash C.BlockHeader)
  , lsfMetaBlockNo :: !C.BlockNo
  }
  deriving stock (Show)

instance Buffered EpochStateHandle where
  -- We should only store on disk SDD from the last slot of each epoch.
  persistToStorage
    :: (Foldable f)
    => f (StorableEvent EpochStateHandle)
    -> EpochStateHandle
    -> StorableMonad EpochStateHandle EpochStateHandle
  persistToStorage events h@(EpochStateHandle topLevelConfig c ledgerStateDirPath securityParam _) =
    liftSQLError CantInsertEvent $ do
      let eventsList = toList events

      SQL.withTransaction c $ do
        forM_ (concatMap eventToEpochSDDRows $ filter epochStateEventIsFirstEventOfEpoch eventsList) $ \row ->
          SQL.execute
            c
            [sql|INSERT INTO epoch_sdd
                    ( epochNo
                    , poolId
                    , lovelace
                    , slotNo
                    , blockHeaderHash
                    , blockNo
                    ) VALUES (?, ?, ?, ?, ?, ?)|]
            row

        forM_ (mapMaybe eventToEpochNonceRow $ filter epochStateEventIsFirstEventOfEpoch eventsList) $ \row ->
          SQL.execute
            c
            [sql|INSERT INTO epoch_nonce
                    ( epochNo
                    , nonce
                    , slotNo
                    , blockHeaderHash
                    , blockNo
                    ) VALUES (?, ?, ?, ?, ?)|]
            row

      -- We store the LedgerState if one of following conditions hold:
      --   * the LedgerState cannot be rollbacked and is the last of an epoch
      --   * the LedgerState can be rollbacked
      let writeLedgerState ledgerState (C.SlotNo slotNo) blockHeaderHash (C.BlockNo blockNo) = do
            let fname =
                  ledgerStateDirPath
                    </> "ledgerState_"
                      <> show slotNo
                      <> "_"
                      <> Text.unpack (C.serialiseToRawBytesHexText blockHeaderHash)
                      <> "_"
                      <> show blockNo
                      <> ".bin"
            -- TODO We should delete the file is the write operation was interrumpted by the
            -- user. Tried using something like `onException`, but it doesn't run the cleanup
            -- function. Not sure how to do the cleanup here without restoring doing it outside
            -- the thread where this indexer is running.
            let codecConfig = O.configCodec topLevelConfig
            BS.writeFile fname $
              CBOR.toLazyByteString $
                O.encodeExtLedgerState
                  (O.encodeDisk codecConfig)
                  (O.encodeDisk codecConfig)
                  (O.encodeDisk codecConfig)
                  ledgerState
      forM_ eventsList $
        \( EpochStateEvent
            maybeLedgerState
            maybeEpochNo
            _
            _
            chainPoint
            blockNo
            chainTip
            isFirstEventOfEpoch
          ) -> do
            case (maybeEpochNo, maybeLedgerState) of
              (Just _, Just ledgerState) -> do
                let isRollbackable =
                      isBlockRollbackable securityParam blockNo (getBlockNoFromChainTip chainTip)
                    isLastImmutableBeforeRollbackable =
                      isBlockRollbackable securityParam (blockNo + 1) (getBlockNoFromChainTip chainTip)
                when (isRollbackable || isLastImmutableBeforeRollbackable || isFirstEventOfEpoch) $ do
                  -- The conditions above make it impossible for the ChainPoint to be at genesis,
                  -- so we should be able to extract the slot and the hash safely.
                  let (slotNo, blockHeaderHash) = Util.extractSlotNoAndHash chainPoint
                  writeLedgerState
                    ledgerState
                    slotNo
                    blockHeaderHash
                    blockNo
              -- We don't store any 'LedgerState' if the era doesn't have epochs (Byron era) or if
              -- we don't have access to the 'LedgerState'.
              _noLedgerStateOrEpochNo -> pure ()

      -- Remove all immutable LedgerStates from the filesystem expect the most recent immutable
      -- one which is from the first slot of latest epoch.
      -- A 'LedgerState' is considered immutable if its 'blockNo' is '< latestBlockNo - securityParam'.
      case NE.nonEmpty eventsList of
        Nothing -> pure ()
        Just nonEmptyEvents -> do
          let chainTip =
                NE.head
                  $ NE.sortWith
                    ( \case
                        C.ChainTipAtGenesis -> Down Nothing
                        C.ChainTip _ _ bn -> Down (Just bn)
                    )
                  $ fmap epochStateEventChainTip nonEmptyEvents

          ledgerStateFilePaths <-
            mapMaybe (\fp -> fmap (fp,) $ readLedgerStateFileMetadata fp)
              <$> listDirectory ledgerStateDirPath

          -- Delete all immutable LedgerStates expect the latest one
          let immutableLedgerStateFilePaths =
                filter
                  ( \(_, lsfm) ->
                      not $
                        isBlockRollbackable
                          securityParam
                          (lsfMetaBlockNo lsfm)
                          (getBlockNoFromChainTip chainTip)
                  )
                  ledgerStateFilePaths
          case NE.nonEmpty immutableLedgerStateFilePaths of
            Nothing -> pure ()
            Just nonEmptyLedgerStateFilePaths -> do
              let annotatedLedgerStateFilePaths =
                    fmap
                      ( \(fp, lsfm@LedgerStateFileMetadata{lsfMetaBlockNo}) ->
                          ( fp
                          , lsfm
                          , not $ isBlockRollbackable securityParam lsfMetaBlockNo (getBlockNoFromChainTip chainTip)
                          )
                      )
                      nonEmptyLedgerStateFilePaths
                  oldImmutableLedgerStateFilePaths =
                    fmap (\(fp, _, _) -> fp) $
                      filter (\(_, _, isImmutableBlock) -> isImmutableBlock) $
                        NE.tail $
                          NE.sortWith
                            ( \(_, lsfm, isImmutableBlock) ->
                                Down (lsfMetaBlockNo lsfm, isImmutableBlock)
                            )
                            annotatedLedgerStateFilePaths
              forM_ oldImmutableLedgerStateFilePaths $
                \fp -> removeFile $ ledgerStateDirPath </> fp

      pure h

  -- \| Buffering is not in use in this indexer and we don't need to retrieve stored events in our
  -- implementation. Therefore, this function returns an empty list.
  getStoredEvents
    :: EpochStateHandle
    -> StorableMonad EpochStateHandle [StorableEvent EpochStateHandle]
  getStoredEvents EpochStateHandle{} = liftSQLError CantQueryIndexer $ pure []

eventToEpochSDDRows
  :: StorableEvent EpochStateHandle
  -> [EpochSDDRow]
eventToEpochSDDRows (EpochStateEvent _ maybeEpochNo _ m chainPoint blockNo _ _) =
  let (slotNo, blockHeaderHash) = Util.chainPointToMaybes chainPoint
   in mapMaybe
        ( \(keyHash, lovelace) ->
            fmap
              ( \epochNo ->
                  EpochSDDRow
                    epochNo
                    keyHash
                    lovelace
                    slotNo
                    blockHeaderHash
                    blockNo
              )
              maybeEpochNo
        )
        $ Map.toList m

eventToEpochNonceRow
  :: StorableEvent EpochStateHandle
  -> Maybe EpochNonceRow
eventToEpochNonceRow (EpochStateEvent _ maybeEpochNo nonce _ chainPoint blockNo _ _) =
  let (slotNo, blockHeaderHash) = Util.chainPointToMaybes chainPoint
   in fmap
        ( \epochNo ->
            EpochNonceRow
              epochNo
              nonce
              slotNo
              blockHeaderHash
              blockNo
        )
        maybeEpochNo

instance Queryable EpochStateHandle where
  queryStorage
    :: (Foldable f)
    => f (StorableEvent EpochStateHandle)
    -> EpochStateHandle
    -> StorableQuery EpochStateHandle
    -> StorableMonad EpochStateHandle (StorableResult EpochStateHandle)
  queryStorage events (EpochStateHandle{_epochStateHandleConnection = c}) (ActiveSDDByEpochNoQuery epochNo) =
    liftSQLError CantQueryIndexer $ do
      -- See Note [Active stake pool delegation query] for why we do 'epochNo - 2' for the query.
      case List.find (\e -> epochStateEventEpochNo e == Just (epochNo - 2)) (toList events) of
        Just e ->
          pure $ ActiveSDDByEpochNoResult $ eventToEpochSDDRows e
        Nothing -> do
          res :: [EpochSDDRow] <-
            SQL.query
              c
              [sql|SELECT epochNo, poolId, lovelace, slotNo, blockHeaderHash, blockNo
                     FROM epoch_sdd
                     WHERE epochNo = ?
                  |]
              (SQL.Only $ epochNo - 2)
          pure $ ActiveSDDByEpochNoResult res
  queryStorage events (EpochStateHandle{_epochStateHandleConnection = c}) (NonceByEpochNoQuery epochNo) =
    liftSQLError CantQueryIndexer $ do
      case List.find (\e -> epochStateEventEpochNo e == Just epochNo) (toList events) of
        Just e ->
          pure $ NonceByEpochNoResult $ eventToEpochNonceRow e
        Nothing -> do
          res :: [EpochNonceRow] <-
            SQL.query
              c
              [sql|SELECT epochNo, nonce, slotNo, blockHeaderHash, blockNo
                     FROM epoch_nonce
                     WHERE epochNo = ?
                  |]
              (SQL.Only epochNo)
          pure $ NonceByEpochNoResult $ listToMaybe res
  queryStorage _ EpochStateHandle{} (LedgerStateAtPointQuery C.ChainPointAtGenesis) =
    liftSQLError CantQueryIndexer $ pure $ LedgerStateAtPointResult Nothing
  queryStorage
    events
    (EpochStateHandle{_epochStateHandleTopLevelCfg, _epochStateHandleLedgerStateDirPath})
    (LedgerStateAtPointQuery (C.ChainPoint slotNo _)) =
      liftSQLError CantQueryIndexer $ do
        let extractSlotNo = fst . Util.extractSlotNoAndHash . epochStateEventChainPoint
        case List.find (\e -> extractSlotNo e == slotNo) (toList events) of
          Nothing -> do
            ledgerStateFilePaths <- listDirectory _epochStateHandleLedgerStateDirPath
            let ledgerStateFilePath =
                  List.find
                    ( \fp -> fmap lsfMetaSlotNo (readLedgerStateFileMetadata fp) == Just slotNo
                    )
                    ledgerStateFilePaths
            case ledgerStateFilePath of
              Nothing -> pure $ LedgerStateAtPointResult Nothing
              Just fp -> do
                ledgerState <-
                  readLedgerStateFromDisk (_epochStateHandleLedgerStateDirPath </> fp) _epochStateHandleTopLevelCfg
                pure $ LedgerStateAtPointResult ledgerState
          Just event -> pure $ LedgerStateAtPointResult $ epochStateEventLedgerState event

instance Rewindable EpochStateHandle where
  rewindStorage
    :: C.ChainPoint
    -> EpochStateHandle
    -> StorableMonad EpochStateHandle EpochStateHandle
  rewindStorage
    C.ChainPointAtGenesis
    h@( EpochStateHandle
          { _epochStateHandleConnection = c
          , _epochStateHandleLedgerStateDirPath = ledgerStateDirPath
          }
        ) =
      liftSQLError CantRollback $ do
        SQL.execute_ c "DELETE FROM epoch_sdd"
        SQL.execute_ c "DELETE FROM epoch_nonce"

        ledgerStateFilePaths <- listDirectory ledgerStateDirPath
        forM_ ledgerStateFilePaths (\f -> removeFile $ ledgerStateDirPath </> f)
        pure h
  rewindStorage
    (C.ChainPoint sn _)
    h@( EpochStateHandle
          { _epochStateHandleConnection = c
          , _epochStateHandleLedgerStateDirPath = ledgerStateDirPath
          }
        ) =
      liftSQLError CantRollback $ do
        SQL.execute c "DELETE FROM epoch_sdd WHERE slotNo > ?" (SQL.Only sn)
        SQL.execute c "DELETE FROM epoch_nonce WHERE slotNo > ?" (SQL.Only sn)

        ledgerStateFilePaths <- listDirectory ledgerStateDirPath
        forM_ ledgerStateFilePaths $ \fp -> do
          case readLedgerStateFileMetadata fp of
            Nothing -> pure ()
            Just lsm | lsfMetaSlotNo lsm > sn -> removeFile $ ledgerStateDirPath </> fp
            Just _ -> pure ()

        pure h

instance Resumable EpochStateHandle where
  resumeFromStorage
    :: EpochStateHandle
    -> StorableMonad EpochStateHandle C.ChainPoint
  resumeFromStorage (EpochStateHandle topLevelConfig _ ledgerStateDirPath securityParam currentNodeBlockNoAtStartup) =
    liftSQLError CantQueryIndexer $ do
      -- We only want (and support) resuming from immutable LedgerStates.
      -- After identifying immutable LedgerStates, we try to deserialise them to ensure that
      -- we correctly serialised it in a previous application run. If the file is not
      -- deserialisable, we delete it.
      ledgerStateFilepaths <- listDirectory ledgerStateDirPath
      let immutableLedgerStateFilePathsWithMetadata =
            filter (not . isLedgerStateFileRollbackable securityParam currentNodeBlockNoAtStartup . snd) $
              mapMaybe (\fp -> fmap (fp,) $ readLedgerStateFileMetadata fp) ledgerStateFilepaths
      readableLedgerStateFilePaths <- flip filterM immutableLedgerStateFilePathsWithMetadata $ \(ledgerStateFilePath, _) -> do
        let ledgerStateFullPath = ledgerStateDirPath </> ledgerStateFilePath
        lsM <- readLedgerStateFromDisk ledgerStateFullPath topLevelConfig
        case lsM of
          Nothing -> do
            removeFile ledgerStateFullPath
            pure False
          Just _ ->
            pure True
      let ledgerStateChainPoints =
            fmap
              ( \(_, LedgerStateFileMetadata{lsfMetaSlotNo, lsfMetaBlockHeaderHash}) ->
                  (lsfMetaSlotNo, lsfMetaBlockHeaderHash)
              )
              readableLedgerStateFilePaths

      -- We return the latest resumable chain point.
      let resumablePoints =
            List.sortOn Down $
              fmap (uncurry C.ChainPoint) ledgerStateChainPoints
      pure $ chainPointOrGenesis resumablePoints

isLedgerStateFileRollbackable :: SecurityParam -> C.BlockNo -> LedgerStateFileMetadata -> Bool
isLedgerStateFileRollbackable
  securityParam
  currentNodeBlockNoAtStartup
  LedgerStateFileMetadata{lsfMetaBlockNo} =
    isBlockRollbackable securityParam lsfMetaBlockNo currentNodeBlockNoAtStartup

readLedgerStateFileMetadata :: FilePath -> Maybe LedgerStateFileMetadata
readLedgerStateFileMetadata ledgerStateFilepath =
  case Text.splitOn "_" (Text.pack $ dropExtension ledgerStateFilepath) of
    [_, slotNoStr, bhhStr, blockNoStr] -> do
      LedgerStateFileMetadata
        <$> parseSlotNo slotNoStr
        <*> parseBlockHeaderHash bhhStr
        <*> parseBlockNo blockNoStr
    _anyOtherFailure -> Nothing
  where
    parseSlotNo slotNoStr = C.SlotNo <$> readMaybe (Text.unpack slotNoStr)
    parseBlockHeaderHash bhhStr = do
      bhhBs <- either (const Nothing) Just $ Base16.decode $ Text.encodeUtf8 bhhStr
      either (const Nothing) Just $ C.deserialiseFromRawBytes (C.proxyToAsType Proxy) bhhBs
    parseBlockNo blockNoStr = C.BlockNo <$> readMaybe (Text.unpack blockNoStr)

open
  :: O.TopLevelConfig (O.CardanoBlock O.StandardCrypto)
  -> FilePath
  -- ^ SQLite database file path
  -> FilePath
  -- ^ Directory from which we will save the various 'LedgerState' as different points in time.
  -> SecurityParam
  -> C.BlockNo
  -> StorableMonad EpochStateHandle (State EpochStateHandle)
open topLevelConfig dbPath ledgerStateDirPath securityParam currentNodeBlockNoAtStartup = do
  c <- liftSQLError CantStartIndexer $ SQL.open dbPath
  lift $ SQL.execute_ c "PRAGMA journal_mode=WAL"
  lift $
    SQL.execute_
      c
      [sql|CREATE TABLE IF NOT EXISTS epoch_sdd
            ( epochNo INT NOT NULL
            , poolId BLOB NOT NULL
            , lovelace INT NOT NULL
            , slotNo INT NOT NULL
            , blockHeaderHash BLOB NOT NULL
            , blockNo INT NOT NULL
            )|]
  lift $
    SQL.execute_
      c
      [sql|CREATE TABLE IF NOT EXISTS epoch_nonce
            ( epochNo INT NOT NULL
            , nonce BLOB NOT NULL
            , slotNo INT NOT NULL
            , blockHeaderHash BLOB NOT NULL
            , blockNo INT NOT NULL
            )|]

  emptyState
    1
    (EpochStateHandle topLevelConfig c ledgerStateDirPath securityParam currentNodeBlockNoAtStartup)

readLedgerStateFromDisk
  :: FilePath
  -> O.TopLevelConfig (O.CardanoBlock O.StandardCrypto)
  -> IO (Maybe (O.ExtLedgerState (O.CardanoBlock O.StandardCrypto)))
readLedgerStateFromDisk fp topLevelConfig = do
  ledgerStateBs <- BS.readFile fp
  let codecConfig = O.configCodec topLevelConfig
  pure
    $ either
      (const Nothing)
      (Just . snd)
    $ CBOR.deserialiseFromBytes
      ( O.decodeExtLedgerState
          (O.decodeDisk codecConfig)
          (O.decodeDisk codecConfig)
          (O.decodeDisk codecConfig)
      )
      ledgerStateBs

{- Note [Active stake pool delegation query]
When processing the events, this indexer extracts and stores the 'mark' stake snapshot at the beginning of epoch 'n'.
That 'mark' snapshot corresponds to the stake distribution of epoch 'n - 1'.
Given current ledger rules, that snapshot (available at the beginning of epoch 'n') becomes *active* for computing the stake pool rewards at epoch 'n + 2'.

In the 'ActiveSDDByEpochNoQuery', we are interested in the active stake pool delegation for a given epoch.
Because we only store the 'mark' snapshot (not the active stake snapshot) of epoch 'n', we need to subtract '2' to the epoch provided as input.
-}
