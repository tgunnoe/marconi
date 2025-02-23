{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}

module Spec.Marconi.ChainIndex.Legacy.Indexers.AddressDatum.Generators (
  genTxBodyContentWithPlutusScripts,
) where

import Cardano.Api qualified as C
import Cardano.Api.Shelley qualified as C
import Gen.Marconi.ChainIndex.Legacy.Types (
  genProtocolParametersForPlutusScripts,
  genTxOutTxContext,
 )
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Gen.Cardano.Api.Typed qualified as CGen

genTxBodyContentWithPlutusScripts :: Gen (C.TxBodyContent C.BuildTx C.BabbageEra)
genTxBodyContentWithPlutusScripts = do
  txIns <-
    map (,C.BuildTxWith (C.KeyWitness C.KeyWitnessForSpending))
      <$> Gen.list (Range.constant 1 10) CGen.genTxIn
  txInsCollateral <-
    C.TxInsCollateral C.CollateralInBabbageEra <$> Gen.list (Range.linear 1 10) CGen.genTxIn
  let txInsReference = C.TxInsReferenceNone
  txOuts <- Gen.list (Range.constant 1 10) (genTxOutTxContext C.BabbageEra)
  let txTotalCollateral = C.TxTotalCollateralNone
  let txReturnCollateral = C.TxReturnCollateralNone
  txFee <- genTxFee C.BabbageEra
  let txValidityRange = (C.TxValidityNoLowerBound, C.TxValidityNoUpperBound C.ValidityNoUpperBoundInBabbageEra)
  let txMetadata = C.TxMetadataNone
  let txAuxScripts = C.TxAuxScriptsNone
  let txExtraKeyWits = C.TxExtraKeyWitnessesNone
  basicPP <- genProtocolParametersForPlutusScripts
  ledgerPP <-
    either (fail . C.displayError) pure $
      C.convertToLedgerProtocolParameters C.ShelleyBasedEraBabbage basicPP
  let txProtocolParams = C.BuildTxWith $ Just ledgerPP
  let txWithdrawals = C.TxWithdrawalsNone
  let txCertificates = C.TxCertificatesNone
  let txUpdateProposal = C.TxUpdateProposalNone
  let txMintValue = C.TxMintNone
  let txScriptValidity = C.TxScriptValidity C.TxScriptValiditySupportedInBabbageEra C.ScriptValid
  let txProposalProcedures = Nothing
  let txVotingProcedures = Nothing

  pure $
    C.TxBodyContent
      { C.txIns
      , C.txInsCollateral
      , C.txInsReference
      , C.txOuts
      , C.txTotalCollateral
      , C.txReturnCollateral
      , C.txFee
      , C.txValidityRange
      , C.txMetadata
      , C.txAuxScripts
      , C.txExtraKeyWits
      , C.txProtocolParams
      , C.txWithdrawals
      , C.txCertificates
      , C.txUpdateProposal
      , C.txMintValue
      , C.txScriptValidity
      , C.txProposalProcedures
      , C.txVotingProcedures
      }
  where
    -- Copied from cardano-api. Delete when this function is reexported
    genTxFee :: C.CardanoEra era -> Gen (C.TxFee era)
    genTxFee era =
      case C.txFeesExplicitInEra era of
        Left supported -> pure (C.TxFeeImplicit supported)
        Right supported -> C.TxFeeExplicit supported <$> CGen.genLovelace
