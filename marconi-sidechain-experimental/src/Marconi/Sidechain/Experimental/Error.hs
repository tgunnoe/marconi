{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}

module Marconi.Sidechain.Experimental.Error (
  HasExit (toExit),
  Exit (TimedOut, Errored, Killed, Terminated, Interrupted),
  withSignalHandling,
  toExitCode,
) where

import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Monad (void)
import Data.Foldable (traverse_)
import Marconi.ChainIndex.Error (IndexerError (Timeout))
import Marconi.Core qualified as Core
import System.Posix (Handler (CatchOnce), Signal, installHandler, sigINT, sigTERM)

-- * Mapping of exceptions to exit codes

-- | Represents a subset of exit codes
data Exit
  = -- | 142
    TimedOut
  | -- | 1
    Errored
  | -- | 137
    Killed
  | -- | 143
    Terminated
  | -- | 130
    Interrupted

-- | Maps a domain concept to a subset of exit codes
class HasExit e where
  toExit :: e -> Exit

instance HasExit (IndexerError a) where
  toExit err =
    case err of
      Timeout _ -> TimedOut
      _ -> Errored

instance HasExit Core.IndexerError where
  toExit _ = Errored

instance HasExit Signal where
  toExit signal
    | signal == sigINT = Interrupted
    | signal == sigTERM = Terminated
    | otherwise = Killed

-- | Maps anything that satisfies 'HasExit' to an 'Int', to be used as an exit code
toExitCode :: (HasExit a) => a -> Int
toExitCode = exitToInt . toExit
  where
    exitToInt :: Exit -> Int
    exitToInt ex = case ex of
      TimedOut -> 142 -- 128 + SIGALRM (14) = 142
      Errored -> 1
      Killed -> 137
      Terminated -> 143
      Interrupted -> 130

-- * Signal handling

{- | Takes an action and runs it while waiting for either a `SIGINT` or a `SIGTERM` to be thrown.
	If one is thrown, it's swallowed, but the value is returned to be interpreted by the caller of
	this function.
-}
withSignalHandling :: IO a -> IO (Either Signal a)
withSignalHandling action = do
  termVar <- newEmptyMVar
  let terminate terminationType = void $ tryPutMVar termVar terminationType
      waitForTermination = takeMVar termVar
      signals = [sigINT, sigTERM]
  traverse_ (\signal -> installHandler signal (CatchOnce (terminate signal)) Nothing) signals
  race
    waitForTermination
    action
