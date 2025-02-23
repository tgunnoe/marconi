module Marconi.Sidechain.Api.Query.Indexers.EpochState (
  updateEnvState,
  queryActiveSDDByEpochNo,
  queryNonceByEpochNo,
) where

import Cardano.Api qualified as C
import Control.Concurrent.STM.TMVar (TMVar, readTMVar)
import Control.Lens ((^.))
import Control.Monad.Except (runExceptT)
import Control.Monad.STM (STM, atomically)
import Data.Functor ((<&>))
import Data.Word (Word64)
import Marconi.ChainIndex.Legacy.Error (IndexerError (InvalidIndexer))
import Marconi.ChainIndex.Legacy.Indexers.EpochState (
  EpochStateHandle,
  StorableQuery (ActiveSDDByEpochNoQuery, NonceByEpochNoQuery),
  StorableResult (ActiveSDDByEpochNoResult, NonceByEpochNoResult),
 )
import Marconi.ChainIndex.Legacy.Indexers.EpochState qualified as EpochState
import Marconi.Core.Storable (State)
import Marconi.Core.Storable qualified as Storable
import Marconi.Sidechain.Api.Routes (
  ActiveSDDResult (ActiveSDDResult),
  GetEpochActiveStakePoolDelegationResult (GetEpochActiveStakePoolDelegationResult),
  GetEpochNonceResult (GetEpochNonceResult),
  NonceResult (NonceResult),
 )
import Marconi.Sidechain.Env (
  SidechainEnv,
  epochStateIndexerEnvIndexer,
  sidechainEpochStateIndexer,
  sidechainIndexersEnv,
 )
import Marconi.Sidechain.Error (QueryExceptions (IndexerInternalError, QueryError))
import Marconi.Sidechain.Utils (writeTMVar)

updateEnvState :: TMVar (State EpochStateHandle) -> State EpochStateHandle -> STM ()
updateEnvState = writeTMVar

{- | Retrieve SDD (stakepool delegation distribution) associated at the given 'EpochNo'.
 We return an empty list if the 'EpochNo' is not found.
-}
queryActiveSDDByEpochNo
  :: SidechainEnv
  -- ^ Query run time environment
  -> Word64
  -- ^ Epoch number
  -> IO (Either QueryExceptions GetEpochActiveStakePoolDelegationResult)
queryActiveSDDByEpochNo env epochNo = do
  -- We must stop the indexer inserts before doing the query.
  epochStateIndexer <-
    atomically $
      readTMVar $
        env ^. sidechainIndexersEnv . sidechainEpochStateIndexer . epochStateIndexerEnvIndexer
  query epochStateIndexer
  where
    query indexer = do
      res <-
        runExceptT $
          Storable.query indexer (ActiveSDDByEpochNoQuery $ C.EpochNo epochNo)
      case res of
        Right (ActiveSDDByEpochNoResult rows) ->
          pure $
            Right $
              GetEpochActiveStakePoolDelegationResult $
                rows <&> \row ->
                  ActiveSDDResult
                    (EpochState.epochSDDRowPoolId row)
                    (EpochState.epochSDDRowLovelace row)
                    (EpochState.epochSDDRowSlotNo row)
                    (EpochState.epochSDDRowBlockHeaderHash row)
                    (EpochState.epochSDDRowBlockNo row)
        _other -> pure $ Left $ QueryError "Query failed"

{- | Retrieve the nonce associated at the given 'EpochNo'
 We return an empty list if the 'EpochNo' is not found.
-}
queryNonceByEpochNo
  :: SidechainEnv
  -- ^ Query run time environment
  -> Word64
  -- ^ Epoch number
  -> IO (Either QueryExceptions GetEpochNonceResult)
queryNonceByEpochNo env epochNo = do
  -- We must stop the indexer inserts before doing the query.
  epochStateIndexer <-
    atomically $
      readTMVar $
        env ^. sidechainIndexersEnv . sidechainEpochStateIndexer . epochStateIndexerEnvIndexer
  query epochStateIndexer
  where
    query indexer = do
      res <-
        runExceptT $
          Storable.query indexer (NonceByEpochNoQuery $ C.EpochNo epochNo)
      case res of
        Right (NonceByEpochNoResult rowM) ->
          case rowM of
            Nothing -> pure $ Right $ GetEpochNonceResult Nothing
            Just row ->
              pure $
                Right $
                  GetEpochNonceResult $
                    Just $
                      NonceResult
                        (EpochState.epochNonceRowNonce row)
                        (EpochState.epochNonceRowSlotNo row)
                        (EpochState.epochNonceRowBlockHeaderHash row)
                        (EpochState.epochNonceRowBlockNo row)
        Left (InvalidIndexer err) -> pure $ Left $ IndexerInternalError err
        _other -> pure $ Left $ QueryError "Query failed"
