{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StrictData #-}

{- |
    A base datatype to alter the behaviour of an indexer.

    See "Marconi.Core" for documentation.
-}
module Marconi.Core.Transformer.IndexTransformer (
  IndexTransformer (IndexTransformer),
  wrapperConfig,
  wrappedIndexer,
  rollbackVia,
  resetVia,
  indexVia,
  indexAllDescendingVia,
  indexAllVia,
  setLastStablePointVia,
  lastSyncPointVia,
  lastStablePointVia,
  closeVia,
  getDatabasePathVia,
  queryVia,
  queryLatestVia,
) where

import Control.Lens (Getter, Lens', makeLenses, view)
import Control.Monad.Except (MonadError)
import Marconi.Core.Class (
  Closeable (close),
  IsIndex (index, indexAllDescending, rollback, setLastStablePoint),
  IsSync (lastStablePoint, lastSyncPoint),
  Queryable (query),
  Resetable (reset),
  indexAll,
  queryLatest,
 )
import Marconi.Core.Indexer.SQLiteAggregateQuery (HasDatabasePath (getDatabasePath))
import Marconi.Core.Transformer.Class (IndexerTrans (unwrap))
import Marconi.Core.Type (Point, QueryError, Result, Timed)

{- | This datatype is meant to be use inside a new type by any indexer transformer.
It wraps an indexer and attach to it a "config" (which may be stateful) used in the logic added
by the transformer
-}
data IndexTransformer config indexer event = IndexTransformer
  { _wrapperConfig :: config event
  , _wrappedIndexer :: indexer event
  }

makeLenses 'IndexTransformer

instance IndexerTrans (IndexTransformer config) where
  unwrap = wrappedIndexer

{- | Helper to implement the @index@ functon of 'IsIndex' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
indexVia
  :: (IsIndex m event indexer, Eq (Point event))
  => Lens' s (indexer event)
  -> Timed (Point event) (Maybe event)
  -> s
  -> m s
indexVia l = l . index

{- | Helper to implement the @index@ functon of 'IsIndex' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
indexAllDescendingVia
  :: (Eq (Point event), IsIndex m event indexer, Traversable f)
  => Lens' s (indexer event)
  -> f (Timed (Point event) (Maybe event))
  -> s
  -> m s
indexAllDescendingVia l = l . indexAllDescending

{- | Helper to implement the @index@ functon of 'IsIndex' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
indexAllVia
  :: (Eq (Point event), IsIndex m event indexer, Traversable f)
  => Lens' s (indexer event)
  -> f (Timed (Point event) (Maybe event))
  -> s
  -> m s
indexAllVia l = l . indexAll

{- | Helper to implement the @index@ functon of 'IsIndex' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
setLastStablePointVia
  :: (Ord (Point event), IsIndex m event indexer)
  => Lens' s (indexer event)
  -> Point event
  -> s
  -> m s
setLastStablePointVia l = l . setLastStablePoint

instance (IsIndex m event indexer) => IsIndex m event (IndexTransformer config indexer) where
  index = indexVia wrappedIndexer
  indexAll = indexAllVia wrappedIndexer
  indexAllDescending = indexAllDescendingVia wrappedIndexer
  rollback = rollbackVia wrappedIndexer
  setLastStablePoint = setLastStablePointVia wrappedIndexer

{- | Helper to implement the @lastSyncPoint@ functon of 'IsSync' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
lastSyncPointVia
  :: (IsSync m event indexer)
  => Getter s (indexer event)
  -> s
  -> m (Point event)
lastSyncPointVia l = lastSyncPoint . view l

{- | Helper to implement the @lastSyncPoint@ functon of 'IsSync' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
lastStablePointVia
  :: (IsSync m event indexer)
  => Getter s (indexer event)
  -> s
  -> m (Point event)
lastStablePointVia l = lastStablePoint . view l

instance
  (IsSync event m index)
  => IsSync event m (IndexTransformer config index)
  where
  lastSyncPoint = lastSyncPointVia wrappedIndexer
  lastStablePoint = lastStablePointVia wrappedIndexer

{- | Helper to implement the @close@ functon of 'Closeable' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
closeVia
  :: (Closeable m indexer)
  => Getter s (indexer event)
  -> s
  -> m ()
closeVia l = close . view l

instance
  (Closeable m index)
  => Closeable m (IndexTransformer config index)
  where
  close = closeVia wrappedIndexer

{- | Helper to implement the @close@ functon of 'Closeable' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
getDatabasePathVia
  :: (HasDatabasePath indexer)
  => Getter s (indexer event)
  -> s
  -> FilePath
getDatabasePathVia l = getDatabasePath . view l

instance
  (HasDatabasePath index)
  => HasDatabasePath (IndexTransformer config index)
  where
  getDatabasePath = getDatabasePathVia wrappedIndexer

{- | Helper to implement the @query@ functon of 'Queryable' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
queryVia
  :: (Queryable m event query indexer, Ord (Point event))
  => Getter s (indexer event)
  -> Point event
  -> query
  -> s
  -> m (Result query)
queryVia l p q = query p q . view l

{- | Helper to implement the @query@ functon of 'Queryable' when we use a wrapper.
 If you don't want to perform any other side logic, use @deriving via@ instead.
-}
queryLatestVia
  :: ( Queryable m event query indexer
     , MonadError (QueryError query) m
     , Ord (Point event)
     , IsSync m event indexer
     )
  => Getter s (indexer event)
  -> query
  -> s
  -> m (Result query)
queryLatestVia l q = queryLatest q . view l

instance
  (Queryable m event query indexer)
  => Queryable m event query (IndexTransformer config indexer)
  where
  query = queryVia wrappedIndexer

{- | Helper to implement the @rollback@ functon of 'rollback' when we use a wrapper.
 Unfortunately, as @m@ must have a functor instance, we can't use @deriving via@ directly.
-}
rollbackVia
  :: (IsIndex m event indexer, Ord (Point event))
  => Lens' s (indexer event)
  -> Point event
  -> s
  -> m s
rollbackVia l = l . rollback

{- | Helper to implement the @reset@ functon of 'Resetable' when we use a wrapper.
 Unfortunately, as @m@ must have a functor instance, we can't use @deriving via@ directly.
-}
resetVia
  :: (Functor m, Resetable m event indexer)
  => Lens' s (indexer event)
  -> s
  -> m s
resetVia l = l reset
