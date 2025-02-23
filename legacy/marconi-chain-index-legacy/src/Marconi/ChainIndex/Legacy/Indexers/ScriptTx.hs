{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Marconi.ChainIndex.Legacy.Indexers.ScriptTx where

import Data.ByteString qualified as BS
import Data.Foldable (foldl', toList)
import Data.Maybe (catMaybes)
import Database.SQLite.Simple qualified as SQL
import Database.SQLite.Simple.FromField qualified as SQL
import Database.SQLite.Simple.ToField qualified as SQL
import GHC.Generics (Generic)

import Cardano.Api (BlockHeader, ChainPoint (ChainPoint, ChainPointAtGenesis), Hash, SlotNo)
import Cardano.Api qualified as C
import Cardano.Api.Shelley qualified as Shelley
import Control.Monad.Trans (MonadTrans (lift))
import Control.Monad.Trans.Except (ExceptT)
import Data.Void (Void)
import Marconi.ChainIndex.Legacy.Error (
  IndexerError (CantInsertEvent, CantQueryIndexer, CantRollback, CantStartIndexer),
  liftSQLError,
 )
import Marconi.ChainIndex.Legacy.Indexers.LastSync (
  createLastSyncTable,
  insertLastSyncPoints,
  queryLastSyncPoint,
  rollbackLastSyncPoints,
 )
import Marconi.ChainIndex.Legacy.Orphans ()
import Marconi.ChainIndex.Legacy.Types ()
import Marconi.Core.Storable (
  Buffered (getStoredEvents, persistToStorage),
  HasPoint (getPoint),
  Queryable (queryStorage),
  Resumable (resumeFromStorage),
  Rewindable (rewindStorage),
  StorableEvent,
  StorableMonad,
  StorablePoint,
  StorableQuery,
  StorableResult,
  emptyState,
 )
import Marconi.Core.Storable qualified as Storable

{- The first thing that we need to define for a new indexer is the `handler` data
   type, meant as a wrapper for the connection type (in this case the SQLite
   connection).

   However this is a very good place to add some more configurations
   that the indexer may require (for example performance tuning settings). In our
   case we add the number of events that we want to return from the on-disk buffer -}

data ScriptTxHandle = ScriptTxHandle
  { hdlConnection :: SQL.Connection
  , hdlDepth :: Int
  }

{- The next step is to define the data types that make up the indexer. There are
   5 of these and they depend on the handle that we previously defined. We make use
   of this semantic dependency by using type and data families that connect these
   types to the `handle` that was previously defined.

   If you want to consider semantics, you can think of the `handle` type as identifying
   both the database connection type and the database structure. Thinking of it this
   way makes the reason for the dependency clearer.

   The first type we introduce is the monad in which the database (and by extension,
   the indexer) runs. -}

type instance StorableMonad ScriptTxHandle = ExceptT (IndexerError Void) IO

{- The next type we introduce is the type of events. Events are the data atoms that
   the indexer consumes. They depend on the `handle` because they need to eventually
   be persisted in the database, so the database has to be able to accomodate them.

   The original implementation used two spearate data structures for storing data
   in memory vs. on-disk. It has the advantage of a better usage of memory and the
   disadvantage of complicating the implementation quite a bit. I am leaving it as-is
   for now, as this is more of a tutorial implementation and complicating things
   may have some educational value. -}

data instance StorableEvent ScriptTxHandle = ScriptTxEvent
  { txScripts :: [(TxCbor, [StorableQuery ScriptTxHandle])]
  , chainPoint :: !ChainPoint
  }
  deriving (Show)

{- The resume and query functionality requires a way to specify points on the chain
   from which we want to resume, or points up to which we want to query. Next we
   define the types of these points. -}

type instance StorablePoint ScriptTxHandle = ChainPoint

-- We also need to know at which slot number an event was produced.

instance HasPoint (StorableEvent ScriptTxHandle) ChainPoint where
  getPoint (ScriptTxEvent _ cp) = cp

{- Next we begin to defined the types required for running queries. Both request and
   response types will depend naturally on the structure of the database, which is
   identified by our `handle`. First, lets define the type for queries (or requests). -}

newtype instance StorableQuery ScriptTxHandle = ScriptTxAddress Shelley.ScriptHash
  deriving (Show, Eq)

-- Now, we need one more type for the query results.

newtype instance StorableResult ScriptTxHandle = ScriptTxResult [TxCbor]

-- Next, we define types required for the interaction with SQLite and the cardano
-- blocks.

newtype Depth = Depth Int

newtype TxCbor = TxCbor BS.ByteString
  deriving (Eq, Show)
  deriving newtype (SQL.ToField, SQL.FromField)

type ScriptTxIndexer = Storable.State ScriptTxHandle

-- * SQLite
data ScriptTxRow = ScriptTxRow
  { scriptAddress :: !(StorableQuery ScriptTxHandle)
  , txCbor :: !TxCbor
  , txSlot :: !SlotNo
  , blockHash :: !(Hash BlockHeader)
  }
  deriving (Generic)

instance SQL.ToField (StorableQuery ScriptTxHandle) where
  toField (ScriptTxAddress hash) = SQL.SQLBlob . Shelley.serialiseToRawBytes $ hash
instance SQL.FromField (StorableQuery ScriptTxHandle) where
  fromField f =
    SQL.fromField f
      >>= \b ->
        either (const cantDeserialise) (return . ScriptTxAddress) $
          Shelley.deserialiseFromRawBytes Shelley.AsScriptHash b
    where
      cantDeserialise = SQL.returnError SQL.ConversionFailed f "Cannot deserialise address."

instance SQL.ToRow ScriptTxRow where
  toRow o =
    [ SQL.toField $ scriptAddress o
    , SQL.toField $ txCbor o
    , SQL.toField $ txSlot o
    , SQL.toField $ blockHash o
    ]

deriving instance SQL.FromRow ScriptTxRow

-- * Indexer

type Query = StorableQuery ScriptTxHandle
type Result = StorableResult ScriptTxHandle

toUpdate
  :: forall era
   . (C.IsCardanoEra era)
  => [C.Tx era]
  -> ChainPoint
  -> StorableEvent ScriptTxHandle
toUpdate txs = ScriptTxEvent txScripts'
  where
    txScripts' = map (\tx -> (TxCbor $ C.serialiseToCBOR tx, getTxScripts tx)) txs

getTxBodyScripts :: forall era. C.TxBody era -> [StorableQuery ScriptTxHandle]
getTxBodyScripts body =
  let hashesMaybe :: [Maybe C.ScriptHash]
      hashesMaybe = case body of
        Shelley.ShelleyTxBody shelleyBasedEra _ scripts _ _ _ ->
          flip map scripts $ \script ->
            case Shelley.fromShelleyBasedScript shelleyBasedEra script of
              Shelley.ScriptInEra _ script' -> Just $ C.hashScript script'
        _ -> [] -- Byron transactions have no scripts
      hashes = catMaybes hashesMaybe :: [Shelley.ScriptHash]
   in map ScriptTxAddress hashes

getTxScripts :: forall era. C.Tx era -> [StorableQuery ScriptTxHandle]
getTxScripts (C.Tx txBody _ws) = getTxBodyScripts txBody

{- Now that all connected data types have been defined, we go on to implement some
   of the type classes required for information storage and retrieval. -}

instance Buffered ScriptTxHandle where
  {- The data is buffered in memory. When the memory buffer is filled, we need to store
     it on disk. -}
  persistToStorage
    :: (Foldable f)
    => f (StorableEvent ScriptTxHandle)
    -> ScriptTxHandle
    -> StorableMonad ScriptTxHandle ScriptTxHandle
  persistToStorage es h =
    liftSQLError CantInsertEvent $ do
      let rows = foldl' (\ea e -> ea ++ flatten e) [] es
          c = hdlConnection h

      SQL.withTransaction c $ do
        SQL.executeMany
          c
          "INSERT INTO script_transactions (scriptAddress, txCbor, slotNo, blockHash) VALUES (?, ?, ?, ?)"
          rows
        let chainPoints = chainPoint <$> toList es
        insertLastSyncPoints c chainPoints

      pure h
    where
      flatten :: StorableEvent ScriptTxHandle -> [ScriptTxRow]
      flatten (ScriptTxEvent txs (ChainPoint sn hsh)) = do
        (tx, scriptAddrs) <- txs
        addr <- scriptAddrs
        pure $
          ScriptTxRow
            { scriptAddress = addr
            , txCbor = tx
            , txSlot = sn
            , blockHash = hsh
            }
      flatten _ = error "There should be no scripts in the genesis block."

  {- We want to potentially store data in two formats. The first one is similar (if
     not identical) to the format of data stored in memory; it should contain information
     that allows knowing at which point the data was generated.

     We use this first format to support rollbacks for disk data. The second format,
     which is not always necessary and does not have any predetermined structure,
     should be thought of as an aggregate of the previously produced events.

     For this indexer we don't really need an aggregate, so our "aggregate" has almost the same
     structure as the in-memory data. We pretend that there is an aggregate by
     segregating the data into two sections, by using the `hdlDiskStore` parameter. We
     take this approach because we don't want to return the entire database when this
     function is called, and we know that there is a point after which we will not
     see any rollbacks. -}

  getStoredEvents
    :: ScriptTxHandle
    -> StorableMonad ScriptTxHandle [StorableEvent ScriptTxHandle]
  getStoredEvents (ScriptTxHandle c sz) = liftSQLError CantInsertEvent $ do
    sns :: [[Integer]] <-
      SQL.query
        c
        "SELECT slotNo FROM script_transactions GROUP BY slotNo ORDER BY slotNo DESC LIMIT ?"
        (SQL.Only sz)
    -- Take the slot number of the sz'th slot
    let sn =
          if null sns
            then 0
            else head . last $ take sz sns
    es <-
      SQL.query
        c
        "SELECT scriptAddress, txCbor, slotNo, blockHash FROM script_transactions WHERE slotNo >= ? ORDER BY slotNo DESC, txCbor, scriptAddress"
        (SQL.Only (sn :: Integer))
    pure $ asEvents es

-- This function recomposes the in-memory format from the database records. This
-- function expectes it's first argument to be ordered by slotNo and txCbor for the
-- proper grouping of records.
--
-- TODO: There should be an easier lensy way of doing this.
asEvents
  :: [ScriptTxRow]
  -> [StorableEvent ScriptTxHandle]
asEvents [] = []
asEvents rs@(ScriptTxRow _ _ sn hsh : _) =
  let (xs, ys) = span (\(ScriptTxRow _ _ sn' hsh') -> sn == sn' && hsh == hsh') rs
   in mkEvent xs : asEvents ys
  where
    mkEvent :: [ScriptTxRow] -> StorableEvent ScriptTxHandle
    mkEvent rs'@(ScriptTxRow _ _ sn' hsh' : _) =
      ScriptTxEvent
        { chainPoint = ChainPoint sn' hsh'
        , txScripts = agScripts rs'
        }
    mkEvent _ = error "We should always be called with a non-empty list"
    agScripts :: [ScriptTxRow] -> [(TxCbor, [StorableQuery ScriptTxHandle])]
    agScripts [] = []
    agScripts rs'@(ScriptTxRow _ tx _ _ : _) =
      let (xs, ys) = span (\(ScriptTxRow _ tx' _ _) -> tx == tx') rs'
       in (tx, map scriptAddress xs) : agScripts ys

instance Queryable ScriptTxHandle where
  queryStorage
    :: (Foldable f)
    => f (StorableEvent ScriptTxHandle)
    -> ScriptTxHandle
    -> StorableQuery ScriptTxHandle
    -> StorableMonad ScriptTxHandle (StorableResult ScriptTxHandle)
  queryStorage es (ScriptTxHandle c _) q =
    liftSQLError CantQueryIndexer $ do
      persisted :: [ScriptTxRow] <-
        SQL.query
          c
          "SELECT scriptAddress, txCbor, slotNo, blockHash FROM script_transactions WHERE scriptAddress = ? ORDER BY slotNo ASC, txCbor, scriptAddress"
          (SQL.Only q)
      -- Note that ordering is quite important here, as the `filterWithQueryInterval`
      -- function assumes events are ordered from oldest (the head) to most recent.
      let updates = asEvents persisted ++ toList es
      pure . ScriptTxResult $ filterByScriptAddress q updates
    where
      filterByScriptAddress :: StorableQuery ScriptTxHandle -> [StorableEvent ScriptTxHandle] -> [TxCbor]
      filterByScriptAddress addr updates = do
        ScriptTxEvent update _slotNo <- updates
        map fst $ filter (\(_, addrs) -> addr `elem` addrs) update

instance Rewindable ScriptTxHandle where
  rewindStorage
    :: ChainPoint
    -> ScriptTxHandle
    -> StorableMonad ScriptTxHandle ScriptTxHandle
  rewindStorage cp@(ChainPoint sn _) h@(ScriptTxHandle c _) = liftSQLError CantRollback $ do
    SQL.execute c "DELETE FROM script_transactions WHERE slotNo > ?" (SQL.Only sn)
    rollbackLastSyncPoints c cp
    pure h
  rewindStorage ChainPointAtGenesis h@(ScriptTxHandle c _) = liftSQLError CantRollback $ do
    SQL.execute_ c "DELETE FROM script_transactions"
    rollbackLastSyncPoints c ChainPointAtGenesis
    pure h

-- For resuming we need to provide a list of points where we can resume from.

instance Resumable ScriptTxHandle where
  resumeFromStorage (ScriptTxHandle c _) =
    liftSQLError CantQueryIndexer $ queryLastSyncPoint c

open :: FilePath -> Depth -> StorableMonad ScriptTxHandle ScriptTxIndexer
open dbPath (Depth k) = do
  c <- liftSQLError CantStartIndexer (SQL.open dbPath)
  lift $ SQL.execute_ c "PRAGMA journal_mode=WAL"
  lift $
    SQL.execute_
      c
      "CREATE TABLE IF NOT EXISTS script_transactions (scriptAddress TEXT NOT NULL, txCbor BLOB NOT NULL, slotNo INT NOT NULL, blockHash BLOB NOT NULL)"
  -- Add this index for normal queries.
  lift $
    SQL.execute_ c "CREATE INDEX IF NOT EXISTS script_address ON script_transactions (scriptAddress)"
  -- Add this index for interval queries.
  lift $
    SQL.execute_
      c
      "CREATE INDEX IF NOT EXISTS script_address_slot ON script_transactions (scriptAddress, slotNo)"
  -- This index helps with group by
  lift $ SQL.execute_ c "CREATE INDEX IF NOT EXISTS script_grp ON script_transactions (slotNo)"
  lift $ createLastSyncTable c
  emptyState k (ScriptTxHandle c k)
