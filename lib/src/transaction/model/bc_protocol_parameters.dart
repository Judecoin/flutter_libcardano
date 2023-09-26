// Copyright 2021 Richard Easterling
// SPDX-License-Identifier: Apache-2.0

import 'bc_scripts.dart';

///
/// EpochParamContent
///
///
class ProtocolParameters {
  /// Epoch number
  final int epoch;

  /// The linear factor for the minimum fee calculation for given epoch
  final int minFeeA;

  /// The constant factor for the minimum fee calculation
  final int minFeeB;

  /// Maximum block body size in Bytes
  final int maxBlockSize;

  /// Maximum transaction size
  final int maxTxSize;

  /// Maximum block header size
  final int maxBlockHeaderSize;

  /// The amount of a key registration deposit in Lovelaces
  final BigInt keyDeposit;

  /// The amount of a pool registration deposit in Lovelaces
  final BigInt poolDeposit;

  /// Epoch bound on pool retirement
  final int eMax;

  /// Desired number of pools
  final int nOpt;

  /// Pool pledge influence
  final num a0;

  /// Monetary expansion
  final num rho;

  /// Treasury expansion
  final num tau;

  /// Percentage of blocks produced by federated nodes
  final num decentralisationParam;

  /// Seed for extra entropy
  final String? extraEntropy;

  /// Accepted protocol major version
  final int protocolMajorVer;

  /// Accepted protocol minor version
  final int protocolMinorVer;

  /// Minimum UTXO value
  final BigInt minUtxo;

  /// Minimum stake cost forced on the pool
  final BigInt minPoolCost;

  /// Epoch number only used once
  final String nonce;

  /// Cost models parameters for Plutus Core scripts
  //final BuiltMap<String, JsonObject?>? costModels;
  final Map<BcScriptType, Map<String, int>> costModels;

  /// The per word cost of script memory usage
  final num? priceMem;

  /// The cost of script execution step usage
  final num? priceStep;

  /// The maximum number of execution memory allowed to be used in a single transaction
  final BigInt? maxTxExMem;

  /// The maximum number of execution steps allowed to be used in a single transaction
  final BigInt? maxTxExSteps;

  /// The maximum number of execution memory allowed to be used in a single block
  final BigInt? maxBlockExMem;

  /// The maximum number of execution steps allowed to be used in a single block
  final BigInt? maxBlockExSteps;

  /// The maximum Val size
  final BigInt? maxValSize;

  /// The percentage of the transactions fee which must be provided as collateral when including non-native scripts
  final int? collateralPercent;

  /// The maximum number of collateral inputs allowed in a transaction
  final int? maxCollateralInputs;

  /// Cost per UTxO word for Alonzo. Cost per UTxO byte for Babbage and later.
  final BigInt? coinsPerUtxoSize;

  /// Cost per UTxO word for Alonzo. Cost per UTxO byte for Babbage and later.
  final BigInt? coinsPerUtxoWord;

  ProtocolParameters(
      this.epoch,
      this.minFeeA,
      this.minFeeB,
      this.maxBlockSize,
      this.maxTxSize,
      this.maxBlockHeaderSize,
      this.keyDeposit,
      this.poolDeposit,
      this.eMax,
      this.nOpt,
      this.a0,
      this.rho,
      this.tau,
      this.decentralisationParam,
      this.extraEntropy,
      this.protocolMajorVer,
      this.protocolMinorVer,
      this.minUtxo,
      this.minPoolCost,
      this.nonce,
      this.costModels,
      this.priceMem,
      this.priceStep,
      this.maxTxExMem,
      this.maxTxExSteps,
      this.maxBlockExMem,
      this.maxBlockExSteps,
      this.maxValSize,
      this.collateralPercent,
      this.maxCollateralInputs,
      this.coinsPerUtxoSize,
      this.coinsPerUtxoWord);
}

// const minFeeA = 44;
// const minFeeB = 155381;
// const lenHackAddition = 5;
// const defaultLinearFee = LinearFee(constant: 2, coefficient: 500);
// const defaultLinearFee = LinearFee(coefficient: minFeeA, constant: minFeeB);

/// default fee for simple ADA transaction
final defaultFee = BigInt.from(170000); // 0.2 ADA

final minUtxoOutput = BigInt.from(969750);

/*
EpochParamContent {
  epoch=243,
  minFeeA=44,
  minFeeB=155381,
  maxBlockSize=98304,
  maxTxSize=16384,
  maxBlockHeaderSize=1100,
  keyDeposit=2000000,
  poolDeposit=500000000,
  eMax=18,
  nOpt=500,
  a0=0.3,
  rho=0.003,
  tau=0.2,
  decentralisationParam=0,
  protocolMajorVer=7,
  protocolMinorVer=0,
  minUtxo=4310,
  minPoolCost=340000000,
  nonce=6bcdf8bf1634de2b743f8dbc0d530f4369c5a633926e2d4baf0b5ffde3b60f33,
  costModels={PlutusV1: {addInteger-cpu-arguments-intercept: 205665, ... 
  priceMem=0.0577,
  priceStep=0.0000721,
  maxTxExMem=16000000,
  maxTxExSteps=10000000000,
  maxBlockExMem=80000000,
  maxBlockExSteps=40000000000,
  maxValSize=5000,
  collateralPercent=150,
  maxCollateralInputs=3,
  coinsPerUtxoSize=4310,
  coinsPerUtxoWord=4310,
}
*/

///
/// Example instance can be used for testing
///
final protocolParametersEpoch243 = ProtocolParameters(
  243,
  44,
  155381,
  98304,
  16384,
  1100,
  BigInt.parse('2000000'),
  BigInt.parse('500000000'),
  18,
  500,
  0.3,
  0.003,
  0.2,
  0,
  null, //extraEntropy
  7,
  0,
  BigInt.parse('4310'),
  BigInt.parse('340000000'),
  '6bcdf8bf1634de2b743f8dbc0d530f4369c5a633926e2d4baf0b5ffde3b60f33',
  Map.of(
    {
      BcScriptType.plutusV1: {'addInteger-cpu-arguments-intercept': 205665},
      BcScriptType.plutusV2: {'addInteger-cpu-arguments-intercept': 205665},
    },
  ), //costModels
  0.0577,
  0.0000721,
  BigInt.parse('16000000'),
  BigInt.parse('10000000000'),
  BigInt.parse('80000000'),
  BigInt.parse('40000000000'),
  BigInt.parse('5000'),
  150,
  3,
  BigInt.parse('4310'),
  BigInt.parse('4310'),
);
