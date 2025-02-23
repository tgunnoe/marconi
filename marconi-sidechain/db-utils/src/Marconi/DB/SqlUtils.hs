{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

{- | This module extracts Shelley addresses from a utxo SQLite database.
   Addresses are:
      store in shelleyaddresses table
      stored in `Text` Bech32 format, Shelly addresses
      ranked on their corresponding number of utxos

 to get a sample of the data :
  sqlite3 ./.marconidb/2/utxo-db "select * from shelleyaddresses limit 10;" ".exit"
-}
module Marconi.DB.SqlUtils where

import Cardano.Api qualified as C
import Control.Concurrent.Async (forConcurrently_)
import Control.Exception (bracket_)
import Control.Monad (void)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Database.SQLite.Simple (Connection, execute, execute_, open, query_)
import Database.SQLite.Simple.FromField (
  FromField,
  ResultError (ConversionFailed),
  fromField,
  returnError,
 )
import Database.SQLite.Simple.FromRow (FromRow (fromRow), field)
import Database.SQLite.Simple.ToField (ToField)
import Database.SQLite.Simple.ToRow (ToRow (toRow))
import GHC.Generics (Generic)
import Text.RawString.QQ (r)

newtype DBEnv = DBEnv {unConn :: Connection}

bootstrap :: FilePath -> IO DBEnv
bootstrap = fmap DBEnv . open

data ShelleyFrequencyTable a = ShelleyFrequencyTable
  { _sAddress :: !a
  , _sFrequency :: Int
  }
  deriving (Generic)

instance (FromField a) => FromRow (ShelleyFrequencyTable a) where
  fromRow = ShelleyFrequencyTable <$> field <*> field
instance (ToField a) => ToRow (ShelleyFrequencyTable a) where
  toRow (ShelleyFrequencyTable ad f) = toRow (ad, f)

instance FromField C.AddressAny where
  fromField f =
    fromField f
      >>= either
        (const $ returnError ConversionFailed f "Cannot deserialise address.")
        pure
        . C.deserialiseFromRawBytes C.AsAddressAny

{- | create a small SQL pipeline:
 first create a table of addresses and their coresponding utxo counts.
 Next, create the shelleyaddresses table
-}
freqUtxoTable :: DBEnv -> IO ()
freqUtxoTable env =
  void $
    withQueryAction
      env
      ( \conn ->
          execute_ conn "drop table if exists frequtxos"
            >> execute_ conn "drop table if exists shelleyaddresses"
            >> execute_
              conn
              [r|CREATE TABLE frequtxos AS
                               SELECT address, count (address)
                               AS frequency FROM unspent_transactions
                               WHERE inlineScript IS NOT NULL
                               GROUP BY address
                               ORDER BY frequency DESC|]
            >> execute_ conn "delete from frequtxos where frequency < 50" -- we only want `intersing` data
            >> execute_
              conn
              [r|CREATE TABLE shelleyaddresses
                              (address TEXT NOT NULL, frequency INT NOT NULL)|]
      )

withQueryAction :: DBEnv -> (Connection -> IO a) -> IO a
withQueryAction env action =
  let f = do
        now <- getCurrentTime
        putStrLn $ "queryAction started at: " <> show now
      g = do
        now <- getCurrentTime
        putStrLn $ "queryAction completed at: " <> show now
   in bracket_ f g (action (unConn env))

{- | populate the shelleyFrequency table
 first create a table of addresses and their coresponding utxo counts.
 Next, create the shelleyaddresses table
-}
freqShelleyTable :: DBEnv -> IO [Text]
freqShelleyTable env = do
  addressFreq <-
    withQueryAction
      env
      ( \conn ->
          query_
            conn
            "SELECT address, frequency FROM frequtxos"
            :: IO [ShelleyFrequencyTable C.AddressAny]
      )
  let addresses = mapMaybe toShelley addressFreq

  withQueryAction
    env
    ( \conn ->
        ( execute_ conn "BEGIN TRANSACTION"
            >> forConcurrently_
              addresses
              ( \(ShelleyFrequencyTable a f) ->
                  execute
                    conn
                    "insert into shelleyaddresses (address, frequency) values (?, ?)"
                    (a, f)
              )
        )
          >> execute_ conn "COMMIT"
    )
  pure . fmap _sAddress $ addresses

{- | we want to store addresses as Text.
 first conver to cardano address, then seriase to text
-}
toShelley :: ShelleyFrequencyTable C.AddressAny -> Maybe (ShelleyFrequencyTable Text)
toShelley (ShelleyFrequencyTable (C.AddressShelley a) f) =
  let addrTxt = C.serialiseAddress a
   in Just (ShelleyFrequencyTable addrTxt f)
toShelley _ = Nothing
