{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{- |
    A transformer that cache result of some queries

    See "Marconi.Core" for documentation.
-}
module Marconi.Core.Transformer.WithCache (
  WithCache,
  withCache,
  addCacheFor,
  HasCacheConfig (cache),
) where

import Control.Lens (
  At (at),
  Getter,
  Indexable (indexed),
  IndexedTraversal',
  Lens',
  itraverseOf,
  lens,
  makeLenses,
  to,
 )
import Control.Lens.Operators ((%~), (&), (^.))
import Control.Monad.Except (ExceptT, MonadError (throwError), runExceptT)
import Data.Foldable (foldl')
import Data.Map (Map)
import Data.Map qualified as Map

import Marconi.Core.Class (
  Closeable,
  HasGenesis (genesis),
  IsIndex (index, indexAllDescending, rollback, setLastStablePoint),
  IsSync,
  Queryable (query),
  Resetable (reset),
  queryLatest,
 )
import Marconi.Core.Indexer.SQLiteAggregateQuery (HasDatabasePath)
import Marconi.Core.Transformer.Class (
  IndexerMapTrans (unwrapMap),
  IndexerTrans (unwrap),
 )
import Marconi.Core.Transformer.IndexTransformer (
  IndexTransformer (IndexTransformer),
  indexAllDescendingVia,
  indexVia,
  lastSyncPointVia,
  queryVia,
  resetVia,
  rollbackVia,
  setLastStablePointVia,
  wrappedIndexer,
  wrapperConfig,
 )
import Marconi.Core.Type (
  IndexerError (OtherIndexError),
  Point,
  QueryError (AheadOfLastSync),
  Result,
  Timed,
 )

data CacheConfig query event = CacheConfig
  { _configCache :: Map query (Result query)
  , _configOnForward :: Timed (Point event) (Maybe event) -> Result query -> Result query
  }

configCache :: Lens' (CacheConfig query event) (Map query (Result query))
configCache = lens _configCache (\cfg c -> cfg{_configCache = c})

configCacheEntries :: IndexedTraversal' query (CacheConfig query event) (Result query)
configCacheEntries f cfg =
  (\c -> cfg{_configCache = c})
    <$> Map.traverseWithKey (indexed f) (cfg ^. configCache)

configOnForward
  :: Getter
      (CacheConfig query event)
      (Timed (Point event) (Maybe event) -> Result query -> Result query)
configOnForward = to _configOnForward

{- | Setup a cache for some requests.

 The cache is active only for the latest `Point`.
 As a consequence, using `WithCache` is more effective on top of the on-disk
 part of a `MixedIndexer`, or any other part of an indexer that has a relatively
 stable sync point.
-}
newtype WithCache query indexer event = WithCache {_cacheWrapper :: IndexTransformer (CacheConfig query) indexer event}

makeLenses 'WithCache

deriving via
  (IndexTransformer (CacheConfig query) indexer)
  instance
    (HasDatabasePath indexer) => HasDatabasePath (WithCache query indexer)

deriving via
  IndexTransformer (CacheConfig query) indexer
  instance
    (IsSync m event indexer) => IsSync m event (WithCache query indexer)

deriving via
  IndexTransformer (CacheConfig query) indexer
  instance
    (Closeable m indexer) => Closeable m (WithCache query indexer)

{- | A smart constructor for 'WithCache'.
 The cache starts empty, you can populate it with 'addCacheFor'
-}
withCache
  :: (Ord query)
  => (Timed (Point event) (Maybe event) -> Result query -> Result query)
  -- ^ The cache update function
  -> indexer event
  -> WithCache query indexer event
withCache _configOnForward =
  WithCache
    . IndexTransformer
      ( CacheConfig
          { _configCache = mempty
          , _configOnForward
          }
      )

-- | A (indexed-)traversal to all the entries of the cache
cacheEntries :: IndexedTraversal' query (WithCache query indexer event) (Result query)
cacheEntries = cacheWrapper . wrapperConfig . configCacheEntries

class HasCacheConfig query indexer where
  -- | Access to the cache
  cache :: Lens' (indexer event) (Map query (Result query))

instance {-# OVERLAPPING #-} HasCacheConfig query (WithCache query indexer) where
  cache = cacheWrapper . wrapperConfig . configCache

instance
  {-# OVERLAPPABLE #-}
  (IndexerTrans t, HasCacheConfig query indexer)
  => HasCacheConfig query (t indexer)
  where
  cache = unwrap . cache

instance
  {-# OVERLAPPABLE #-}
  (IndexerMapTrans t, HasCacheConfig query indexer)
  => HasCacheConfig query (t indexer output)
  where
  cache = unwrapMap . cache

-- | How do we add event to existing cache
onForward
  :: Getter
      (WithCache query indexer event)
      (Timed (Point event) (Maybe event) -> Result query -> Result query)
onForward = cacheWrapper . wrapperConfig . configOnForward

{- | Add a cache for a specific query.

 When added, the 'WithCache' queries the underlying indexer to populate the cache for this query.

 If you want to add several indexers at the same time, use @traverse@.
-}
addCacheFor
  :: (Queryable (ExceptT (QueryError query) m) event query indexer)
  => (IsSync (ExceptT (QueryError query) m) event indexer)
  => (HasCacheConfig query indexer)
  => (Monad m)
  => (MonadError IndexerError m)
  => (Ord query)
  => (Ord (Point event))
  => query
  -> indexer event
  -> m (indexer event)
addCacheFor q indexer = do
  initialResult <- runExceptT $ queryLatest q indexer
  case initialResult of
    Left _err -> throwError $ OtherIndexError "Can't create cache"
    Right result -> pure $ indexer & cache %~ Map.insert q result

instance IndexerTrans (WithCache query) where
  unwrap = cacheWrapper . wrappedIndexer

rollbackCache
  :: (Applicative f)
  => (Ord (Point event))
  => (Queryable f event query indexer)
  => Point event
  -> WithCache query indexer event
  -> f (WithCache query indexer event)
rollbackCache p indexer =
  itraverseOf
    cacheEntries
    (\q -> const $ queryVia unwrap p q indexer)
    indexer

{- | This instances update all the cached queries with the incoming event
 and then pass this event to the underlying indexer.
-}
instance
  (Applicative m, IsIndex m event index, Queryable m event query index)
  => IsIndex m event (WithCache query index)
  where
  index timedEvent indexer = do
    indexer' <- indexVia unwrap timedEvent indexer
    pure $ indexer' & cacheEntries %~ (indexer' ^. onForward) timedEvent

  indexAllDescending evts indexer = do
    indexer' <- indexAllDescendingVia unwrap evts indexer
    pure $ indexer' & cacheEntries %~ flip (foldl' (flip $ indexer' ^. onForward)) evts

  -- Rollback the underlying indexer, clear the cache,
  -- repopulate it with queries to the underlying indexer.
  rollback p indexer = do
    res <- rollbackVia unwrap p indexer
    rollbackCache p res

  setLastStablePoint = setLastStablePointVia unwrap

{- | Rollback the underlying indexer, clear the cache,
 repopulate it with queries to the underlying indexer.
-}
instance
  ( Monad m
  , Resetable m event index
  , HasGenesis (Point event)
  , Ord (Point event)
  , Queryable m event query index
  )
  => Resetable m event (WithCache query index)
  where
  reset indexer = do
    res <- resetVia unwrap indexer
    rollbackCache genesis res

instance
  ( Ord query
  , Ord (Point event)
  , IsSync m event index
  , MonadError (QueryError query) m
  , Monad m
  , Queryable m event query index
  )
  => Queryable m event query (WithCache query index)
  where
  -- \| On a query, if it miss the cache, query the indexer.
  -- If the cache is fresher than the request point, query the underlying indexer,
  -- if it's the cached point, send the result.
  -- If the cache is behind the requested point, send an 'AheadOfLastSync' error
  -- with the cached content.
  query p q indexer = do
    syncPoint' <- lastSyncPointVia unwrap indexer
    let cached = indexer ^. cache . at q
    let queryWithoutCache = queryVia unwrap p q indexer
    case compare p syncPoint' of
      LT -> queryWithoutCache
      EQ -> maybe queryWithoutCache pure cached
      GT -> maybe queryWithoutCache (throwError . AheadOfLastSync . Just) cached
