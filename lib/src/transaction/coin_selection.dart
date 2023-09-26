// Copyright 2021 Richard Easterling
// SPDX-License-Identifier: Apache-2.0

import 'package:cardano_wallet_sdk/src/transaction/model/bc_protocol_parameters.dart';
import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:oxidized/oxidized.dart';
import 'package:quiver/core.dart';
import '../address/shelley_address.dart';
import '../util/ada_types.dart';
import '../asset/asset.dart';
import './transaction.dart';
import './model/bc_tx.dart';

///
/// Coin selection is the process of picking UTxO inputs to perticipate in a spending transaction.
/// There is a dedicated Cardano Improvement Proposal that this implementation is attempting to
/// follo in spirit:
///
///   https://cips.cardano.org/cips/cip2
///
/// Implementations details can be found here:
///
///   https://hackage.haskell.org/package/cardano-coin-selection-1.0.1/docs/Cardano-CoinSelection-Algorithm-LargestFirst.html
///   https://hackage.haskell.org/package/cardano-coin-selection-1.0.1/docs/src/Cardano.CoinSelection.Algorithm.LargestFirst.html
///   https://hackage.haskell.org/package/cardano-coin-selection-1.0.1/docs/Cardano-CoinSelection-Algorithm-RandomImprove.html
///   https://hackage.haskell.org/package/cardano-coin-selection-1.0.1/docs/src/Cardano.CoinSelection.Algorithm.RandomImprove.html
///
/// The result of this method will ultimatly be a list of ShelleyTransactionInput
/// which point to an UTXO unspent change entry using a transactionId and index:
///
/// class ShelleyTransactionInput {
///  final String transactionId;
///  final int index;
/// }

/// coin selection function type
typedef CoinSelectionAlgorithm
    = Future<Result<CoinSelection, CoinSelectionError>> Function({
  required List<WalletTransaction> unspentInputsAvailable,
  required FlatMultiAsset spendRequest,
  required Set<AbstractAddress> ownedAddresses,
  int coinSelectionLimit,
});

/// an single asset name and value under a MultiAsset policyId
// class AssetRequest {
//   final String name;
//   final Coin value;

//   AssetRequest({required this.name, required this.value});
// }

final _loggerFMA = Logger('FlatMultiAsset');

class FlatMultiAsset {
  final Map<AssetId, Coin> assets;
  final Coin fee;

  FlatMultiAsset({required this.assets, Coin? fee}) : fee = fee ?? coinZero;
  FlatMultiAsset.outputsRequested(BcValue request, {Coin? fee})
      : this(assets: outputsRequestedToGoal(request), fee: fee);

  FlatMultiAsset add({required AssetId assetId, required Coin quantity}) =>
      FlatMultiAsset(
          assets: assets..[assetId] = (assets[assetId] ?? coinZero) + quantity,
          fee: fee);

  bool assetIdFunded(Iterable<UTxO> candidateUTxOs, AssetId assetId) {
    final calculated = candidateUTxOs.fold(coinZero,
        (sum, utxo) => (sum as BigInt) + utxo.output.quantityAssetId(assetId));
    final required =
      //FIXME 最小找零
        assets[assetId]! + (assetId == lovelaceAssetId ? fee : coinZero) + minUtxoOutput;
    final success = calculated >= required;
    _loggerFMA
        .info("calculated: $calculated >= required: $required -> $success");
    return success;
  }

//  bool assetIdFunded(Iterable<UTxO> candidateUTxOs, AssetId assetId) =>
//       candidateUTxOs.fold(coinZero,
//           (sum, utxo) => (sum as int) + utxo.output.quantityAssetId(assetId)) >=
//       assets[assetId]! + (assetId == lovelaceAssetId ? fee : coinZero);

  bool funded(Iterable<UTxO> candidateUTxOs) =>
      _funded(utxosToMap(candidateUTxOs));

  bool _funded(Map<AssetId, Coin> utxosSum) => assets.keys.every((assetId) {
        final utxoQuantity = (utxosSum[assetId] ?? coinZero);
        final targetQuantity =
            (assets[assetId]! + (assetId == lovelaceAssetId ? fee : coinZero));
        final isOk = utxoQuantity >= targetQuantity;
        return isOk;
        // (utxosSum[assetId] ?? coinZero) >=
        // (assets[assetId]! + (assetId == lovelaceAssetId ? fee : coinZero)));
      });

  Map<AssetId, Coin> diff(Iterable<UTxO> candidateUTxOs) =>
      _diff(utxosToMap(candidateUTxOs));

  Map<AssetId, Coin> _diff(Map<AssetId, Coin> utxosSum) => {
        for (MapEntry e in assets.entries)
          e.key: (utxosSum[e.key] ?? coinZero) - e.value
      };

  @override
  String toString() {
    final vals = assets.entries.fold('', (String prefix, MapEntry e) {
      final header = prefix == '' ? '' : "$prefix,";
      return "$header ${e.key == lovelaceAssetId ? 'lovelace' : e.key}:${e.value}";
    });
    return "FlatMultiAsset(fee:$fee, $vals)";
  }

  @override
  int get hashCode => hash2(const MapEquality().hash(assets), fee);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlatMultiAsset &&
          runtimeType == other.runtimeType &&
          const MapEquality().equals(assets, other.assets) &&
          fee == other.fee;

  static Map<AssetId, Coin> outputsRequestedToGoal(BcValue value) {
    Map<AssetId, Coin> result =
        value.coin > coinZero ? {lovelaceHex: value.coin} : {};
    for (final multiAsset in value.multiAssets) {
      for (final asset in multiAsset.assets) {
        final AssetId assetId = multiAsset.policyId + asset.name;
        result[assetId] = (result[assetId] ?? coinZero) + asset.value;
      }
    }
    //make sure there is at least an empty lovelace entry for covered method
    result[lovelaceAssetId] = result[lovelaceAssetId] ?? coinZero;
    return result;
  }

  static Map<AssetId, Coin> utxosToMap(Iterable<UTxO> candidateUTxOs) =>
      candidateUTxOs.fold(
          <TransactionAmount>[],
          (list, utxo) => (list as List<TransactionAmount>)
            ..addAll(utxo.output.amounts)).fold(
          <AssetId, Coin>{},
          (map, amount) => map
            ..[amount.unit] = (map[amount.unit] ?? coinZero) + amount.quantity);
}

/// Native Token multi-asset container.
// class MultiAssetRequest {
//   final String policyId;
//   final List<AssetRequest> assets;
//   MultiAssetRequest({required this.policyId, required this.assets});
//   factory MultiAssetRequest.lovelace(Coin amount) => MultiAssetRequest(
//       policyId: '', assets: [AssetRequest(name: lovelaceHex, value: amount)]);
// }

///
/// Special builder for creating ShelleyValue objects containing multi-asset transactions.
///
class MultiAssetRequestBuilder {
  final List<BcMultiAsset> _multiAssets;

  MultiAssetRequestBuilder({required Coin coin})
      : _multiAssets = [
          BcMultiAsset(
              policyId: '', assets: [BcAsset(name: lovelaceHex, value: coin)])
        ];

  List<BcMultiAsset> build() => _multiAssets;

  MultiAssetRequestBuilder multiAsset(BcMultiAsset multiAssetRequest) {
    _multiAssets.add(multiAssetRequest);
    return this;
  }

  MultiAssetRequestBuilder nativeAsset(
      {required String policyId, String? hexName, required Coin value}) {
    final assetRequest = BcMultiAsset(
        policyId: policyId,
        assets: [BcAsset(name: hexName ?? '', value: value)]);
    return multiAsset(assetRequest);
  }
}

class CoinSelection {
  final List<BcTransactionInput> inputs;
  CoinSelection({required this.inputs});
}

enum CoinSelectionErrorEnum {
  unsupported,
  inputValueInsufficient,
  inputCountInsufficient,
  inputLimitExceeded,
  inputsExhausted,
}

class CoinSelectionError {
  final CoinSelectionErrorEnum reason;
  final String message;
  CoinSelectionError({required this.reason, required this.message});
  @override
  String toString() => "CoinSelectionError(reason: ${reason.name}, $message";
}

const defaultCoinSelectionLimit = 20;

Future<Result<CoinSelection, CoinSelectionError>> largestFirst({
  required List<WalletTransaction> unspentInputsAvailable,
  // required List<BcMultiAsset> outputsRequested,
  required FlatMultiAsset spendRequest,
  required Set<AbstractAddress> ownedAddresses,
  // required Coin estimatedFee,
  int coinSelectionLimit = defaultCoinSelectionLimit,
}) async {
  final logger = Logger('largestFirst');
  if (spendRequest.assets.isEmpty) {
    return Err(CoinSelectionError(
        reason: CoinSelectionErrorEnum.inputCountInsufficient,
        message: "can't create an empty transaction"));
  }
  //define target coin sums the transactions must cover, including fee
  // final target = FlatMultiAsset.outputsRequested(
  //     BcValue(coin: coinZero, multiAssets: outputsRequested),
  //     fee: estimatedFee);
  // var solution = FlatMultiAsset(assets: {}, fee: coinZero);
  final Set<UTxO> availableUtxos =
      unspentInputsAvailable.fold(<UTxO>{}, (set, tx) => set..addAll(tx.utxos));
  // final isNativeToken = availableUtxos.any((utxo) => utxo.isNativeToken);
  if (logger.isLoggable(Level.FINE)) {
    for (var utxo in availableUtxos) {
      logger.fine("available: $utxo");
    }
  }
  //sort coin types by amount
  final sortedTargetEntryList = spendRequest.assets.entries.toList();
  //Force lovelace to the end because native tokens carry ADA which may be sufficient
  sortedTargetEntryList.sort((e1, e2) =>
      (e2.key == lovelaceHex ? coinZero : e2.value)
          .compareTo(e1.key == lovelaceHex ? coinZero : e1.value));
  Set<UTxO> selectedUTxOs = {};
  for (MapEntry e in sortedTargetEntryList) {
    final assetId = e.key;
    //filter UTxOs coin type, then sort into descending order
    final List<UTxO> sortedCoinUtxos =
        availableUtxos.where((u) => u.output.containsAssetId(assetId)).toList();
    if (sortedCoinUtxos.isEmpty) {
      return Err(CoinSelectionError(
          reason: CoinSelectionErrorEnum.inputValueInsufficient,
          message: "No UTxOs for coin $assetId"));
    }
    sortedCoinUtxos.sort((a, b) => b.output
        .quantityAssetId(assetId)
        .compareTo(a.output.quantityAssetId(assetId)));
    //sort transactions for specific coin type into descending order
    for (UTxO utxo in sortedCoinUtxos) {
      //add transactions until coin type balance is acheived or we run out of UTxOs
      selectedUTxOs.add(utxo);
      if (selectedUTxOs.length > coinSelectionLimit) {
        return Err(CoinSelectionError(
          reason: CoinSelectionErrorEnum.inputsExhausted,
          message:
              "($selectedUTxOs.length) UTxOs selected exceeds allowed coinSelectionLimit ($coinSelectionLimit)",
        ));
      }
      //have we met or exceeded the required balance?
      if (spendRequest.assetIdFunded(selectedUTxOs, assetId)) {
        break;
      }
    }
    if (spendRequest.funded(selectedUTxOs)) {
      break;
    }
  }
  if (spendRequest.funded(selectedUTxOs)) {
    if (logger.isLoggable(Level.FINE)) {
      for (var utxo in selectedUTxOs) {
        logger.fine("selected : $utxo");
      }
    }
    //generate inputs:
    List<BcTransactionInput> inputs = selectedUTxOs
        .map((u) =>
            BcTransactionInput(index: u.index, transactionId: u.transactionId))
        .toList();
    return Ok(CoinSelection(inputs: inputs));
  } else {
    return Err(CoinSelectionError(
      reason: CoinSelectionErrorEnum.inputValueInsufficient,
      message:
          "($selectedUTxOs.length) UTxOs insufficient to fund spend request ($spendRequest)",
    ));
  }
}

// List<BcTransactionInput> toTxInputs({required List<WalletTransaction> selectedUtxos, required Set<AbstractAddress> ownedAddresses,}) {
//   List<BcTransactionInput> results = [];
//   for (int index = 0; index < tx.outputs.length; index++) {
//       final output = tx.outputs[index];
//       //Coin coinAmount = tx.currencyAmount(assetId: hardCodedUnit);
//       final contains = ownedAddresses.contains(output.address);
//       results.add(BcTransactionInput(index: index, transactionId: tx.txId));
//   }
// }

// Future<Result<CoinSelection, CoinSelectionError>> largestFirstOld({
//   required List<WalletTransaction> unspentInputsAvailable,
//   required List<BcMultiAsset> outputsRequested,
//   required Set<AbstractAddress> ownedAddresses,
//   int coinSelectionLimit = defaultCoinSelectionLimit,
// }) async {
//   final logger = Logger();
//   if (outputsRequested.isEmpty) {
//     return Err(CoinSelectionError(
//         reason: CoinSelectionErrorEnum.inputCountInsufficient,
//         message: "can't create an empty transaction"));
//   }
//   const String hardCodedUnit = lovelaceHex;
//   Coin amount = 0;
//   for (final reqest in outputsRequested) {
//     if (reqest.policyId == '') {
//       for (final asset in reqest.assets) {
//         if (asset.name == lovelaceHex) {
//           amount = asset.value;
//         } else {
//           return Err(CoinSelectionError(
//             reason: CoinSelectionErrorEnum.unsupported,
//             message: "only support ADA transactions at this time",
//           ));
//         }
//       }
//     } else {
//       return Err(CoinSelectionError(
//         reason: CoinSelectionErrorEnum.unsupported,
//         message: "only support ADA transactions at this time",
//       ));
//     }
//   }
//   if (amount <= 0) {
//     return Err(CoinSelectionError(
//       reason: CoinSelectionErrorEnum.inputValueInsufficient,
//       message: "transactions must be greater than zero",
//     ));
//   }
//   final List<WalletTransaction> sortedInputs =
//       List.from(unspentInputsAvailable);
//   sortedInputs.sort((a, b) => b.amount.compareTo(a.amount));
//   List<BcTransactionInput> results = [];
//   Coin selectedAmount = 0;
//   int coinsSelected = 0;
//   for (final tx in sortedInputs) {
//     if (tx.status != TransactionStatus.unspent) {
//       logger.info("SHOULDN'T SEE TransactionStatus.unspent HERE: ${tx.txId}");
//     }
//     // int index = 0;
//     for (int index = 0; index < tx.outputs.length; index++) {
//       final output = tx.outputs[index];
//       //Coin coinAmount = tx.currencyAmount(assetId: hardCodedUnit);
//       final contains = ownedAddresses.contains(output.address);
//       logger.info(
//           "contains:$contains, tx=${tx.txId.substring(0, 20)} index[$index]=${output.amounts.first.quantity}");
//       if (contains) {
//         for (final txAmount in output.amounts) {
//           if (txAmount.quantity > 0 && txAmount.unit == hardCodedUnit) {
//             selectedAmount += txAmount.quantity;
//             if (logSelection) {
//               logger.info(
//                   "selectedAmount += quantity: $selectedAmount += ${txAmount.quantity} -> tx: ${tx.txId} index: $index");
//             }
//             if (++coinsSelected > coinSelectionLimit) {
//               return Err(CoinSelectionError(
//                 reason: CoinSelectionErrorEnum.inputsExhausted,
//                 message:
//                     "coinsSelected ($coinsSelected) exceeds allowed coinSelectionLimit ($coinSelectionLimit)",
//               ));
//             }
//             results
//                 .add(BcTransactionInput(index: index, transactionId: tx.txId));
//           }
//         }
//       }
//       //index++;
//     }
//     if (selectedAmount >= amount) {
//       break;
//     }
//   }
//   if (selectedAmount < amount) {
//     return Err(CoinSelectionError(
//       reason: CoinSelectionErrorEnum.inputValueInsufficient,
//       message: "insufficient funds",
//     ));
//   }
//   return Ok(CoinSelection(inputs: results));
// }
