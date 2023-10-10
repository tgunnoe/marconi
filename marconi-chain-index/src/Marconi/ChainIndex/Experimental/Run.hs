{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Marconi.ChainIndex.Experimental.Run where

import Cardano.Api qualified as C
import Cardano.BM.Trace (logError, logInfo)

import Control.Monad.Except (runExceptT)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as Text (toStrict)
import Data.Void (Void)
import Marconi.ChainIndex.CLI qualified as Cli
import Marconi.ChainIndex.Experimental.Indexers (buildIndexers)
import Marconi.ChainIndex.Experimental.Indexers.EpochState qualified as EpochState
import Marconi.ChainIndex.Experimental.Indexers.MintTokenEvent qualified as MintTokenEvent
import Marconi.ChainIndex.Experimental.Indexers.Utxo qualified as Utxo
import Marconi.ChainIndex.Experimental.Logger (defaultStdOutLogger)
import Marconi.ChainIndex.Experimental.Runner qualified as Runner
import Marconi.ChainIndex.Node.Client.Retry (withNodeConnectRetry)
import Marconi.ChainIndex.Types (RunIndexerConfig (RunIndexerConfig))
import Marconi.ChainIndex.Utils qualified as Utils
import Marconi.Core qualified as Core
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import Text.Pretty.Simple (pShowDarkBg)

-- See note 4e8b9e02-fae4-448b-8b32-1eee50dd95ab

#ifndef mingw32_HOST_OS
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (
  newEmptyMVar,
  takeMVar,
  tryPutMVar,
 )
import Data.Functor (void)
import System.Posix.Signals (
  Handler (CatchOnce),
  installHandler,
  sigTERM,
 )
#endif

run :: Text -> IO ()
run appName = withGracefulTermination_ $ do
  trace <- defaultStdOutLogger appName

  logInfo trace $ appName <> "-" <> Text.pack Cli.getVersion

  o <- Cli.parseOptions

  logInfo trace . Text.toStrict $ pShowDarkBg o

  createDirectoryIfMissing True (Cli.optionsDbPath o)

  let batchSize = 5000
      stopCatchupDistance = 100
      volatileEpochStateSnapshotInterval = 100
      filteredAddresses = []
      -- TODO: PLT-7885 This was an existing bug to be fixed shortly in PLT-7793.
      filteredAssetIds = Nothing
      includeScript = True
      socketPath = Cli.optionsSocketPath $ Cli.commonOptions o
      networkId = Cli.optionsNetworkId $ Cli.commonOptions o
      retryConfig = Cli.optionsRetryConfig $ Cli.commonOptions o
      preferredStartingPoint = Cli.optionsChainPoint $ Cli.commonOptions o

  nodeConfigPath <- case Cli.optionsNodeConfigPath o of
    Just cfg -> pure cfg
    Nothing -> error "No node config path provided"

  securityParam <- withNodeConnectRetry trace retryConfig socketPath $ do
    Utils.toException $ Utils.querySecurityParam @Void networkId socketPath

  mindexers <-
    runExceptT $
      buildIndexers
        securityParam
        (Core.mkCatchupConfig batchSize stopCatchupDistance)
        (Utxo.UtxoIndexerConfig filteredAddresses includeScript)
        (MintTokenEvent.MintTokenEventConfig filteredAssetIds)
        ( EpochState.EpochStateWorkerConfig
            (EpochState.NodeConfig nodeConfigPath)
            volatileEpochStateSnapshotInterval
        )
        trace
        (Cli.optionsDbPath o)
  (indexerLastStablePoint, _utxoQueryIndexer, indexers) <-
    ( case mindexers of
        Left err -> do
          logError trace $ Text.pack $ show err
          exitFailure
        Right result -> pure result
      )

  let startingPoint = getStartingPoint preferredStartingPoint indexerLastStablePoint

  Runner.runIndexer
    ( RunIndexerConfig
        trace
        retryConfig
        securityParam
        networkId
        startingPoint
        socketPath
    )
    indexers

getStartingPoint :: C.ChainPoint -> C.ChainPoint -> C.ChainPoint
getStartingPoint preferredStartingPoint indexerLastSyncPoint =
  case preferredStartingPoint of
    C.ChainPointAtGenesis -> indexerLastSyncPoint
    nonGenesisPreferedChainPoint -> nonGenesisPreferedChainPoint

{- Note 4e8b9e02-fae4-448b-8b32-1eee50dd95ab:

  In order to ensure we can gracefully exit on a SIGTERM, we need the below functions. However,
  this code is not necessary on Windows, and the `unix` package (which it depends upon) is not
  supported by Windows. As such, in order to be able to cross-compile, the following `if` is
  unfortunately required. -}
#ifndef mingw32_HOST_OS
{- | Ensure that @SIGTERM@ is handled gracefully, because it's how containers are stopped.

 @action@ will receive an 'AsyncCancelled' exception if @SIGTERM@ is received by the process.

 Typical use:

 > main :: IO ()
 > main = withGracefulTermination_ $ do

 Note that although the Haskell runtime handles @SIGINT@ it doesn't do anything with @SIGTERM@.
 Therefore, when running as PID 1 in a container, @SIGTERM@ will be ignored unless a handler is
 installed for it.
-}
withGracefulTermination :: IO a -> IO (Maybe a)
withGracefulTermination action = do
  var <- newEmptyMVar
  let terminate = void $ tryPutMVar var ()
      waitForTermination = takeMVar var
  void $ installHandler sigTERM (CatchOnce terminate) Nothing
  either (const Nothing) Just <$> race waitForTermination action

-- | Like 'withGracefulTermination' but ignoring the return value
withGracefulTermination_ :: IO a -> IO ()
withGracefulTermination_ = void . withGracefulTermination
#else
withGracefulTermination_ :: a -> a
withGracefulTermination_ = id
#endif
