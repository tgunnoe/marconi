{-# LANGUAGE DeriveAnyClass #-}

module Marconi.Sidechain.Experimental.CLI (
  CliArgs (..),
  parseCli,
  parseCliArgs,
  Cli.getVersion,
  programParser,
  startFromChainPoint,
) where

import Cardano.Api qualified as C
import Data.Aeson (FromJSON, ToJSON)
import Data.List.NonEmpty (NonEmpty)
import GHC.Generics (Generic)
import Marconi.Cardano.Core.Orphans ()
import Marconi.Cardano.Core.Types (
  RetryConfig,
  TargetAddresses,
 )
import Marconi.ChainIndex.CLI qualified as Cli
import Options.Applicative qualified as Opt

-- | Type represents http port for JSON-RPC
data CliArgs = CliArgs
  { socketFilePath :: !FilePath
  -- ^ POSIX socket file to communicate with cardano node
  , nodeConfigPath :: !FilePath
  -- ^ Path to the node config
  , dbDir :: !FilePath
  -- ^ Directory path containing the SQLite database files
  , httpPort :: !Int
  -- ^ TCP/IP port number for JSON-RPC http server
  , networkId :: !C.NetworkId
  -- ^ cardano network id
  , targetAddresses :: !(Maybe TargetAddresses)
  -- ^ white-space sepparated list of Bech32 Cardano Shelley addresses
  , targetAssets :: !(Maybe (NonEmpty (C.PolicyId, Maybe C.AssetName)))
  -- ^ a list of asset to track
  , optionsRetryConfig :: !RetryConfig
  , optionsChainPoint :: !Cli.StartingPoint
  }
  deriving (Show, Generic, FromJSON, ToJSON)

parseCli :: IO CliArgs
parseCli = Opt.execParser programParser

parseCliArgs :: [String] -> IO CliArgs
parseCliArgs = Opt.handleParseResult . Opt.execParserPure Opt.defaultPrefs programParser

programParser :: Opt.ParserInfo CliArgs
programParser =
  Opt.info
    (Opt.helper <*> Cli.commonVersionOptionParser <*> parserCliArgs)
    (Cli.marconiDescr "marconi-sidechain")

parserCliArgs :: Opt.Parser CliArgs
parserCliArgs =
  CliArgs
    <$> Cli.commonSocketPathParser
    <*> Cli.commonNodeConfigPathParser
    <*> Cli.commonDbDirParser
    <*> Cli.commonPortParser
    <*> Cli.commonNetworkIdParser
    <*> Cli.commonMaybeTargetAddressParser
    <*> Cli.commonMaybeTargetAssetParser
    <*> Cli.commonRetryConfigParser
    <*> Cli.commonStartFromParser

startFromChainPoint :: Cli.StartingPoint -> C.ChainPoint -> C.ChainPoint
startFromChainPoint Cli.StartFromGenesis _ = C.ChainPointAtGenesis
startFromChainPoint Cli.StartFromLastSyncPoint lsp = lsp
startFromChainPoint (Cli.StartFrom cp) _ = cp
