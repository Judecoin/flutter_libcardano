// Copyright 2021 Richard Easterling
// SPDX-License-Identifier: Apache-2.0

import 'package:blockfrost/blockfrost.dart';
import 'package:built_value/json_object.dart';
import 'package:dio/dio.dart';
import 'dart:typed_data';
import 'package:built_collection/built_collection.dart';
import 'package:logging/logging.dart';
import 'package:oxidized/oxidized.dart';
import '../../address/shelley_address.dart';
import '../../network/network_id.dart';
import '../../stake/stake_account.dart';
import '../../stake/stake_pool.dart';
import '../../stake/stake_pool_metadata.dart';
import '../../transaction/model/bc_protocol_parameters.dart';
import '../../transaction/model/bc_scripts.dart';
import '../../transaction/transaction.dart';
import '../../util/ada_time.dart';
import '../../asset/asset.dart';
import '../../util/ada_types.dart';
import '../../wallet/impl/wallet_update.dart';
import '../blockchain_adapter.dart';
import './dio_call.dart';

///
/// Loads BlockFrost data into this wallet model
///
/// Caches transactions, blocks, acount data and assets.
///
class BlockfrostBlockchainAdapter implements BlockchainAdapter {
  // static const mainnetUrl = 'https://cardano-mainnet.blockfrost.io/api/v0';
  static const mainnetUrl = 'http://apimir.judecoin.com/cardano';
  static const testnetUrl = 'https://cardano-testnet.blockfrost.io/api/v0';

  static const txContentType = 'application/cbor';

  static const projectIdKey =
      'project_id'; //hack: only needed by submitTransaction

  /// return base URL for blockfrost service given the network type.
  static String urlFromNetwork(Networks network) =>
      network == Networks.mainnet ? mainnetUrl : testnetUrl;

  final logger = Logger('BlockfrostBlockchainAdapter');

  @override
  final Networks network;
  //final CardanoNetwork cardanoNetwork;
  final Blockfrost blockfrost;
  final String projectId; //hack: only needed by submitTransaction
  final Map<String, RawTransaction> _transactionCache = {};
  final Map<String, Block> _blockCache = {};
  final Map<String, AccountContent> _accountContentCache = {};
  final Map<String, CurrencyAsset> _assetCache = {
    lovelaceAssetId: lovelacePseudoAsset
  };

  BlockfrostBlockchainAdapter(
      {required this.network,
      required this.blockfrost,
      required this.projectId});

  @override
  CancelAction cancelActionInstance() => DioCancelAction();

  // @override
  // Future<Result<LinearFee, String>> latestEpochParameters(
  //     {int epochNumber = 0, CancelAction? cancelAction}) async {
  //   if (epochNumber == 0) {
  //     final blockResult = await latestBlock(cancelAction: cancelAction);
  //     if (blockResult.isErr()) return Err(blockResult.unwrapErr());
  //     epochNumber = blockResult.unwrap().epoch;
  //   }
  //   final cancelToken = (cancelAction as DioCancelAction?)?.cancelToken;
  //   final paramResult = await dioCall<EpochParamContent>(
  //     request: () => blockfrost.getCardanoEpochsApi().epochsNumberParametersGet(
  //         number: epochNumber, cancelToken: cancelToken),
  //     onSuccess: (data) => logger.info(
  //         "blockfrost.getCardanoEpochsApi().epochsNumberParametersGet(number:$epochNumber) -> ${serializers.toJson(EpochParamContent.serializer, data)}"),
  //     errorSubject: 'latest EpochParamContent',
  //   );
  //   if (paramResult.isErr()) return Err(paramResult.unwrapErr());
  //   final epochParams = paramResult.unwrap();
  //   final linearFee = LinearFee(
  //     constant: epochParams.minFeeA,
  //     coefficient: epochParams.minFeeB,
  //   );
  //   return Ok(linearFee);
  // }

  @override
  Future<Result<ProtocolParameters, String>> latestEpochParameters(
      {int epochNumber = 0, CancelAction? cancelAction}) async {
    if (epochNumber == 0) {
      final blockResult = await latestBlock(cancelAction: cancelAction);
      if (blockResult.isErr()) return Err(blockResult.unwrapErr());
      epochNumber = blockResult.unwrap().epoch;
    }
    final cancelToken = (cancelAction as DioCancelAction?)?.cancelToken;
    final paramResult = await dioCall<EpochParamContent>(
      request: () => blockfrost.getCardanoEpochsApi().epochsNumberParametersGet(
          number: epochNumber, cancelToken: cancelToken),
      onSuccess: (data) => logger.info(
          "blockfrost.getCardanoEpochsApi().epochsNumberParametersGet(number:$epochNumber) -> ${serializers.toJson(EpochParamContent.serializer, data)}"),
      errorSubject: 'latest EpochParamContent',
    );
    if (paramResult.isErr()) return Err(paramResult.unwrapErr());
    final p = paramResult.unwrap();
    final params = ProtocolParameters(
        p.epoch,
        p.minFeeA,
        p.minFeeB,
        p.maxBlockSize,
        p.maxTxSize,
        p.maxBlockHeaderSize,
        BigInt.parse(p.keyDeposit),
        BigInt.parse(p.poolDeposit),
        p.eMax,
        p.nOpt,
        p.a0,
        p.rho,
        p.tau,
        p.decentralisationParam,
        p.extraEntropy,
        p.protocolMajorVer,
        p.protocolMinorVer,
        BigInt.parse(p.minUtxo),
        BigInt.parse(p.minPoolCost),
        p.nonce,
        _buildCostModels(p.costModels),
        p.priceMem,
        p.priceStep,
        _bigIntOrNull(p.maxTxExMem),
        _bigIntOrNull(p.maxTxExSteps),
        _bigIntOrNull(p.maxBlockExMem),
        _bigIntOrNull(p.maxBlockExSteps),
        _bigIntOrNull(p.maxValSize),
        p.collateralPercent,
        p.maxCollateralInputs,
        _bigIntOrNull(p.coinsPerUtxoSize),
        _bigIntOrNull(p.coinsPerUtxoWord));
    return Ok(params);
  }

  @override
  Future<Result<Block, String>> latestBlock(
      {CancelAction? cancelAction}) async {
    final cancelToken = (cancelAction as DioCancelAction?)?.cancelToken;
    final blockResult = await dioCall<BlockContent>(
      request: () => blockfrost
          .getCardanoBlocksApi()
          .blocksLatestGet(cancelToken: cancelToken),
      onSuccess: (data) => logger.info(
          "blockfrost.getCardanoBlocksApi().blocksLatestGet() -> ${serializers.toJson(BlockContent.serializer, data)}"),
      errorSubject: 'latest block',
    );
    if (blockResult.isErr()) return Err(blockResult.unwrapErr());
    final b = blockResult.unwrap();
    var dateTime =
        DateTime.fromMillisecondsSinceEpoch(b.time * 1000, isUtc: true);
    final block = Block(
        time: dateTime,
        hash: b.hash,
        slot: b.slot ?? 0,
        epoch: b.epoch ?? 0,
        epochSlot: b.epochSlot ?? 0);
    return Ok(block);
  }

  @override
  Future<Result<String, String>> submitTransaction(
      {required Uint8List cborTransaction, CancelAction? cancelAction}) async {
    final Map<String, dynamic> headers = {projectIdKey: projectId};
    final cancelToken = (cancelAction as DioCancelAction?)?.cancelToken;
    final result = await dioCall<String>(
      request: () => blockfrost.getCardanoTransactionsApi().txSubmitPost(
            contentType: txContentType,
            headers: headers,
            data: cborTransaction,
            cancelToken: cancelToken,
          ),
      onSuccess: (data) => logger.info(
          "blockfrost.getCardanoTransactionsApi().txSubmitPost(contentType: 'application/cbor'); -> $data"),
      errorSubject: 'submit cbor transaction: ',
    );
    if (result.isErr()) return Err(result.unwrapErr());
    return Ok(result.unwrap());
  }

  @override
  Future<Result<WalletUpdate, String>> updateWallet({
    required ShelleyAddress stakeAddress,
    CancelAction? cancelAction,
    TemperalSortOrder sortOrder = TemperalSortOrder.descending,
  }) async {
    final cancelToken = (cancelAction as DioCancelAction?)?.cancelToken;
    final content = await _loadAccountContent(
        stakeAddress: stakeAddress.toBech32(), cancelToken: cancelToken);
    if (content.isErr()) {
      return Err(content.unwrapErr());
    }
    final account = content.unwrap();
    final controlledAmount = content.isOk()
        ? BigInt.tryParse(account.controlledAmount) ?? BigInt.zero
        : BigInt.zero;
    if (controlledAmount == coinZero && account.active == false) {
      //likely new wallet with no transactions, bail out
      return Ok(WalletUpdate(
        balance: controlledAmount,
        transactions: [],
        addresses: [],
        assets: {},
        // utxos: [],
        stakeAccounts: [],
      ));
    }
    final addressesResult = await _addresses(
        stakeAddress: stakeAddress.toBech32(), cancelToken: cancelToken);
    if (addressesResult.isErr()) {
      return Err(addressesResult.unwrapErr());
    }
    final addresses = addressesResult.unwrap();
    List<StakeAccount> stakeAccounts =
        []; //TODO should be a list, just show current staked pool for now
    if (account.poolId != null && account.active) {
      final stakeAccountResponse = await _stakeAccount(
          poolId: account.poolId!,
          stakeAddres: stakeAddress.toBech32(),
          cancelToken: cancelToken);
      if (stakeAccountResponse.isErr()) {
        return Err(stakeAccountResponse.unwrapErr());
      }
      stakeAccounts = stakeAccountResponse.unwrap();
    }
    List<RawTransactionImpl> transactionList = [];
    Set<String> duplicateTxHashes = {}; //track and skip duplicates
    //final Set<String> addressSet = addresses.map((a) => a.toBech32()).toSet();
    for (var address in addresses) {
      final trans = await _transactions(
          address: address.toString(),
          duplicateTxHashes: duplicateTxHashes,
          cancelToken: cancelToken);
      if (trans.isErr()) {
        return Err(trans.unwrapErr());
      }
      trans.unwrap().forEach((tx) {
        transactionList.add(tx as RawTransactionImpl);
      });
    }
    //set transaction status
    transactionList = markSpentTransactions(
        transactions: transactionList, ownedAddresses: addresses.toSet());
    //collect UTxOs
    // final utxos = collectUTxOs(
    //     transactions: transactionList, ownedAddresses: addresses.toSet());
    //sort
    transactionList.sort((d1, d2) => sortOrder == TemperalSortOrder.descending
        ? d2.time.compareTo(d1.time)
        : d1.time.compareTo(d2.time));
    Set<String> allAssetIds = transactionList
        .map((t) => t.assetIds)
        .fold(<String>{}, (result, entry) => result..addAll(entry));
    //logger.info("policyIDs: ${policyIDs.join(',')}");
    Map<String, CurrencyAsset> assets = {};
    for (var assetId in allAssetIds) {
      final asset =
          await _loadAsset(assetId: assetId, cancelToken: cancelToken);
      if (asset.isOk()) {
        assets[assetId] = asset.unwrap();
      }
      if (asset.isErr()) {
        return Err(asset.unwrapErr());
      }
    }
    logger.info(
        "WalletUpdate($controlledAmount, tx:${transactionList.length}, addr:${addresses.length}, assets:${assets.length}, stake:${stakeAccounts.length})");
    return Ok(WalletUpdate(
        balance: controlledAmount,
        transactions: transactionList,
        addresses: addresses,
        assets: assets,
        // utxos: utxos,
        stakeAccounts: stakeAccounts));
  }

  List<RawTransactionImpl> markSpentTransactions(
      {required List<RawTransactionImpl> transactions,
      required Set<AbstractAddress> ownedAddresses}) {
    final Set<String> txIdSet = transactions.map((tx) => tx.txId).toSet();
    Set<String> spentTransactinos = {};
    for (final tx in transactions) {
      for (final input in tx.inputs) {
        if (txIdSet.contains(input.txHash) &&
            ownedAddresses.contains(input.address)) {
          spentTransactinos.add(input.txHash);
        }
      }
    }
    return transactions
        .map((tx) => spentTransactinos.contains(tx.txId)
            ? tx.toStatus(TransactionStatus.spent)
            : tx)
        .toList();
  }

  // List<UTxO> collectUTxOs(
  //     {required List<RawTransactionImpl> transactions,
  //     required Set<AbstractAddress> ownedAddresses}) {
  //   List<UTxO> results = [];
  //   for (final tx in transactions) {
  //     if (tx.status != TransactionStatus.unspent) {
  //       logger.info("SHOULDN'T SEE TransactionStatus.unspent HERE: ${tx.txId}");
  //     }
  //     for (int index = 0; index < tx.outputs.length; index++) {
  //       final output = tx.outputs[index];
  //       final contains = ownedAddresses.contains(output.address);
  //       // logger.info(
  //       //     "contains:$contains, tx=${tx.txId.substring(0, 20)} index[$index]=${output.amounts.first.quantity}");
  //       if (contains) {
  //         final utxo =
  //             UTxO(output: output, transactionId: tx.txId, index: index);
  //         results.add(utxo);
  //       }
  //     }
  //   }
  //   return results;
  // }

  // bool _isSpent(RawTransaction tx, Map<String, RawTransaction> txIdLookup) =>
  //     tx.inputs.any((input) => txIdLookup.containsKey(input.txHash));

  // bool _isSpent2(RawTransaction tx, Map<String, RawTransaction> txIdLookup) {
  //   for (final input in tx.inputs) {
  //     if (txIdLookup.containsKey(input.txHash)) {
  //       return true;
  //     }
  //   }
  //   return false;
  // }

  BigInt? _bigIntOrNull(String? value) =>
      value == null ? null : BigInt.parse(value);

  Map<BcScriptType, Map<String, int>> _buildCostModels(
      BuiltMap<String, JsonObject?>? jsonMap) {
    Map<BcScriptType, Map<String, int>> result = {};
    for (String key in jsonMap?.keys ?? []) {
      if (key == 'PlutusV1') {
        Map<String, int>? values =
            _buildCostModel(jsonMap!['PlutusV1']?.asMap ?? {});
        result[BcScriptType.plutusV1] = values ?? {};
      } else if (key == 'PlutusV2') {
        Map<String, int>? values =
            _buildCostModel(jsonMap!['PlutusV2']?.asMap ?? {});
        result[BcScriptType.plutusV2] = values ?? {};
      } else {
        logger.warning("unknown key parsing costModels: '$key'");
      }
    }
    return result;
  }

  Map<String, int>? _buildCostModel(Map map) {
    Map<String, int>? results = {};
    for (String key in map.keys) {
      final value = map[key]?.toString();
      final number = value != null ? int.tryParse(value.toString()) : null;
      if (number != null) {
        results[key] = number;
      } else {
        logger.warning(
            "failed to parse costModel value as integer (key:value): '$key':'$value'");
      }
    }
    return results;
  }

  Future<Result<List<StakeAccount>, String>> _stakeAccount({
    required String poolId,
    required String stakeAddres,
    CancelToken? cancelToken,
  }) async {
    final Response<Pool> poolResponse = await blockfrost
        .getCardanoPoolsApi()
        .poolsPoolIdGet(poolId: poolId, cancelToken: cancelToken);
    if (poolResponse.statusCode != 200 || poolResponse.data == null) {
      return poolResponse.statusMessage != null
          ? Err(
              "${poolResponse.statusMessage}, code: ${poolResponse.statusCode}")
          : Err('problem loading stake pool: $poolId');
    }
    final p = poolResponse.data!;
    final stakePool = StakePool(
      activeSize: p.activeSize,
      vrfKey: p.vrfKey,
      blocksMinted: p.blocksMinted,
      declaredPledge: p.declaredPledge,
      liveDelegators: p.liveDelegators,
      livePledge: p.livePledge,
      liveSize: p.liveSize,
      liveSaturation: p.liveSaturation,
      liveStake: p.liveStake,
      rewardAccount: p.rewardAccount,
      fixedCost: p.fixedCost,
      marginCost: p.marginCost,
      activeStake: p.activeStake,
      retirement: p.retirement.map((e) => e).toList(),
      owners: p.owners.map((e) => e).toList(),
      registration: p.registration.map((e) => e).toList(),
    );

    final Response<PoolsPoolIdMetadataGet200Response> metadataResponse =
        await blockfrost.getCardanoPoolsApi().poolsPoolIdMetadataGet(
            poolId: poolId,
            cancelToken: cancelToken); //TODO replace with dioCall
    if (metadataResponse.statusCode != 200 || metadataResponse.data == null) {
      return metadataResponse.statusMessage != null
          ? Err(
              "${metadataResponse.statusMessage}, code: ${metadataResponse.statusCode}")
          : Err('problem loading stake pool metadata: $poolId');
    }

    final m = metadataResponse.data!.anyOf.values.values
        .firstWhere((v) => v is PoolMetadata) as PoolMetadata?;
    if (m == null) {
      Err('no PoolMetadata instance found loading stake pool metadata: $poolId');
    }
    StakePoolMetadata stakePoolMetadata = StakePoolMetadata(
      name: m!.name,
      hash: m.hash,
      url: m.url,
      ticker: m.ticker,
      description: m.description,
      homepage: m.homepage,
    );

    final Response<BuiltList<AccountRewardContentInner>> rewardResponse =
        await blockfrost.getCardanoAccountsApi().accountsStakeAddressRewardsGet(
            stakeAddress: stakeAddres,
            count: 100,
            cancelToken: cancelToken); //TODO replace with dioCall
    if (rewardResponse.statusCode != 200 && rewardResponse.data == null) {
      return rewardResponse.statusMessage != null
          ? Err(
              "${rewardResponse.statusMessage}, code: ${rewardResponse.statusCode}")
          : Err('problem loading staking rewards: $stakeAddres');
    }
    List<StakeReward> rewards = [];
    for (var reward in rewardResponse.data!) {
      rewards.add(StakeReward(
          epoch: reward.epoch,
          amount: BigInt.tryParse(reward.amount) ?? BigInt.zero,
          poolId: reward.poolId));
      logger.info(
          "amount: ${reward.amount}, epoch: ${reward.epoch}, pool_id: ${reward.poolId}");
    }

    final Response<AccountContent> accountResponse = await blockfrost
        .getCardanoAccountsApi()
        .accountsStakeAddressGet(
            stakeAddress: stakeAddres,
            cancelToken: cancelToken); //TODO replace with dioCall
    if (accountResponse.statusCode != 200 || accountResponse.data == null) {
      return accountResponse.statusMessage != null
          ? Err(
              "${accountResponse.statusMessage}, code: ${accountResponse.statusCode}")
          : Err('problem loading staking account: $stakeAddres');
    }
    final a = accountResponse.data!;
    final stakeAccount = StakeAccount(
      active: a.active,
      activeEpoch: a.activeEpoch,
      controlledAmount: BigInt.tryParse(a.controlledAmount) ?? BigInt.zero,
      reservesSum: BigInt.tryParse(a.reservesSum) ?? BigInt.zero,
      withdrawableAmount: BigInt.tryParse(a.withdrawableAmount) ?? BigInt.zero,
      rewardsSum: BigInt.tryParse(a.reservesSum) ?? BigInt.zero,
      treasurySum: BigInt.tryParse(a.treasurySum) ?? BigInt.zero,
      poolId: a.poolId,
      withdrawalsSum: BigInt.tryParse(a.withdrawableAmount) ?? BigInt.zero,
      stakePool: stakePool,
      poolMetadata: stakePoolMetadata,
      rewards: rewards,
    );
    return Ok([stakeAccount]);
  }

  Future<Result<List<AbstractAddress>, String>> _addresses({
    required String stakeAddress,
    CancelToken? cancelToken,
  }) async {
    List<AbstractAddress> addresses = [];
    int page = 1;
    const count = 100;
    do {
      Response<BuiltList<AccountAddressesContentInner>> result =
          await blockfrost
              .getCardanoAccountsApi()
              .accountsStakeAddressAddressesGet(
                  stakeAddress: stakeAddress,
                  page: page,
                  count: count,
                  cancelToken: cancelToken);
      if (result.statusCode != 200 || result.data == null) {
        return Err("${result.statusCode}: ${result.statusMessage}");
      }
      for (var content in result.data!) {
        final address = parseAddress(content.address);
        addresses.add(address);
        logger.info("parseAddress(${content.address}) -> $address");
      }
      if (result.data!.length < count) {
        break;
      }
      page++;
    } while (true);
    return Ok(addresses);
  }

  Future<Result<List<RawTransaction>, String>> _transactions({
    required String address,
    //required Set<String> addressSet,
    required Set<String> duplicateTxHashes,
    CancelToken? cancelToken,
  }) async {
    List<String> txHashes = await _transactionsHashes(address: address);
    List<RawTransaction> transactions = [];
    for (var txHash in txHashes) {
      if (duplicateTxHashes.contains(txHash)) {
        continue;
      } //skip already processed transactions
      final result =
          await _loadTransaction(txHash: txHash, cancelToken: cancelToken);
      duplicateTxHashes.add(txHash);
      if (result.isOk()) {
        transactions.add(result.unwrap());
      } else {
        return Err(result.unwrapErr());
      }
    }
    return Ok(transactions);
  }

  List<TransactionInput> _buildIputs(BuiltList<TxContentUtxoInputsInner> list) {
    List<TransactionInput> results = [];
    for (var input in list) {
      List<TransactionAmount> amounts = [];
      for (var io in input.amount) {
        final quantity = BigInt.tryParse(io.quantity) ?? BigInt.zero;
        final unit = io.unit == 'lovelace'
            ? lovelaceHex
            : io.unit; //translate 'lovelace' to assetId representation
        amounts.add(TransactionAmount(unit: unit, quantity: quantity));
      }
      results.add(TransactionInput(
        address: parseAddress(input.address),
        amounts: amounts,
        txHash: input.txHash,
        outputIndex: input.outputIndex,
      ));
    }
    return results;
  }

  List<TransactionOutput> _buildOutputs(
      BuiltList<TxContentUtxoOutputsInner> list) {
    List<TransactionOutput> results = [];
    for (var input in list) {
      List<TransactionAmount> amounts = [];
      for (var io in input.amount) {
        final quantity = BigInt.tryParse(io.quantity) ?? BigInt.zero;
        final unit = io.unit == 'lovelace'
            ? lovelaceHex
            : io.unit; //translate 'lovelace' to assetId representation
        amounts.add(TransactionAmount(unit: unit, quantity: quantity));
      }
      results.add(TransactionOutput(
        address: parseAddress(input.address),
        amounts: amounts,
      ));
    }
    return results;
  }

  Future<List<String>> _transactionsHashes(
      {required String address, CancelToken? cancelToken}) async {
    int page = 1;
    const count = 100;
    List<String> list = [];
    do {
      Response<BuiltList<AddressTransactionsContentInner>> result =
          await blockfrost
              .getCardanoAddressesApi()
              .addressesAddressTransactionsGet(
                  address: address,
                  count: count,
                  page: page,
                  cancelToken: cancelToken); //TODO replace with dioCall
      if (result.statusCode != 200 || result.data == null) {
        break;
      }
      for (final tx in result.data!) {
        list.add(tx.txHash);
      }
      if (result.data!.length < count) {
        break;
      }
      page++;
    } while (true);

    logger.info(
        "blockfrost.getCardanoAddressesApi().addressesAddressTxsGet(address:$address) -> ${list.join(',')}");
    return list;
  }

  Future<Result<RawTransaction, String>> _loadTransaction(
      {required String txHash, CancelToken? cancelToken}) async {
    final cachedTx = _transactionCache[txHash];
    if (cachedTx != null) {
      return Ok(cachedTx);
    }
    final txContentResult = await dioCall<TxContent>(
      request: () => blockfrost
          .getCardanoTransactionsApi()
          .txsHashGet(hash: txHash, cancelToken: cancelToken),
      onSuccess: (data) => logger.info(
          "blockfrost.getCardanoTransactionsApi().txsHashGet(hash:$txHash) -> ${serializers.toJson(TxContent.serializer, data)}"),
      errorSubject: 'transaction content',
      onError: (
              {Response? response, DioError? dioError, Exception? exception}) =>
          logger.severe(
              "txsHashGet(hash:$txHash) -> dioError: ${dioError.toString()}, exception: ${exception.toString()}"),
    );
    if (txContentResult.isErr()) return Err(txContentResult.unwrapErr());
    final txContent = txContentResult.unwrap();
    // Response<TxContent> txContent = await blockfrost.getCardanoTransactionsApi().txsHashGet(hash: txHash);
    // if (txContent.statusCode != 200 || txContent.data == null) {
    //   return Err("${txContent.statusCode}: ${txContent.statusMessage}");
    // }
    // logger.info(
    //     "blockfrost.getCardanoTransactionsApi().txsHashGet(hash:$txHash) -> ${serializers.toJson(TxContent.serializer, txContent.data!)}");
    final block = await _loadBlock(hashOrNumber: txContent.block);
    if (block.isErr()) {
      return Err(block.unwrapErr());
    }
    final txContentUtxoResult = await dioCall<TxContentUtxo>(
      request: () => blockfrost
          .getCardanoTransactionsApi()
          .txsHashUtxosGet(hash: txHash, cancelToken: cancelToken),
      onSuccess: (data) => logger.info(
          "blockfrost.getCardanoTransactionsApi().txsHashUtxosGet(hash:$txHash) -> ${serializers.toJson(TxContentUtxo.serializer, data)}"),
      errorSubject: 'UTXO',
    );
    if (txContentUtxoResult.isErr()) {
      return Err(txContentUtxoResult.unwrapErr());
    }

    // Response<TxContentUtxo> txUtxo = await blockfrost.getCardanoTransactionsApi().txsHashUtxosGet(hash: txHash);
    // if (txUtxo.statusCode != 200 || txUtxo.data == null) {
    //   return Err("${txUtxo.statusCode}: ${txUtxo.statusMessage}");
    // }
    // logger.info(
    //     "blockfrost.getCardanoTransactionsApi().txsHashUtxosGet(hash:$txHash) -> ${serializers.toJson(TxContentUtxo.serializer, txUtxo.data!)}");
    final time = block.unwrap().time;
    //final deposit = int.tryParse(txContent.data?.deposit ?? '0') ?? 0;
    // final fees = int.tryParse(txContentResult.unwrap().fees) ?? 0;
    final fees = BigInt.tryParse(txContentResult.unwrap().fees) ?? BigInt.zero;
    //final withdrawalCount = txContent.data!.withdrawalCount;
    final addrInputs = txContentUtxoResult.unwrap().inputs;
    List<TransactionInput> inputs = _buildIputs(addrInputs);
    final addrOutputs = txContentUtxoResult.unwrap().outputs;
    List<TransactionOutput> outputs = _buildOutputs(addrOutputs);
    //logger.info("deposit: $deposit, fees: $fees, withdrawalCount: $withdrawalCount inputs: ${inputs.length}, outputs: ${outputs.length}");
    //BuiltList<TxContentOutputAmount> amounts = txContent.data!.outputAmount;
    //Map<String, int> currencies = _currencyNets(inputs: inputs, outputs: outputs, addressSet: addressSet);
    //int lovelace = currencies[lovelaceHex] ?? 0;
    final trans = RawTransactionImpl(
      txId: txHash,
      blockHash: txContent.block,
      blockIndex: txContent.index,
      status: TransactionStatus.unspent,
      //type: lovelace >= 0 ? TransactionType.deposit : TransactionType.withdrawal,
      fees: fees,
      inputs: inputs,
      outputs: outputs,
      //currencies: currencies,
      time: time,
    );
    _transactionCache[txHash] = trans;
    logger.info("add $trans");
    return Ok(trans);
  }

  Future<Result<CurrencyAsset, String>> _loadAsset(
      {required String assetId, CancelToken? cancelToken}) async {
    final cachedAsset = _assetCache[assetId];
    if (cachedAsset != null) {
      return Ok(cachedAsset);
    }
    try {
      final result = await blockfrost.getCardanoAssetsApi().assetsAssetGet(
          asset: assetId, cancelToken: cancelToken); //TODO replace with dioCall
      if (result.statusCode != 200 || result.data == null) {
        return Err("${result.statusCode}: ${result.statusMessage}");
      }
      final Asset a = result.data!;
      logger.info(
          "blockfrost.getCardanoAssetsApi().assetsAssetGet(asset: $assetId) -> ${serializers.toJson(Asset.serializer, a)}");
      final AssetMetadata? m = a.metadata;
      final metadata = m == null
          ? null
          : CurrencyAssetMetadata(
              name: m.name,
              description: m.description,
              ticker: m.ticker,
              url: m.url,
              logo: m.logo,
              decimals: m.decimals ?? 0);
      final asset = CurrencyAsset(
          policyId: a.policyId,
          assetName: a.assetName ?? '',
          fingerprint: a.fingerprint,
          quantity: a.quantity,
          initialMintTxHash: a.initialMintTxHash,
          metadata: metadata);
      _assetCache[assetId] = asset;
      return Ok(asset);
    } catch (e) {
      logger.info("assetsAssetGet(asset:$assetId) -> ${e.toString()}");
      return Err(e.toString());
    }
  }

  // Future<Result<AccountContent, String>> _loadAccountContent({required String stakeAddress}) async {
  //   final cachedAccountContent = _accountContentCache[stakeAddress];
  //   if (cachedAccountContent != null) {
  //     return Ok(cachedAccountContent);
  //   }
  //   try {
  //     final result = await blockfrost.getCardanoAccountsApi().accountsStakeAddressGet(stakeAddress: stakeAddress);
  //     if (result.statusCode != 200 || result.data == null) {
  //       return Err("${result.statusCode}: ${result.statusMessage}");
  //     }
  //     _accountContentCache[stakeAddress] = result.data!;
  //     logger.info(
  //         "blockfrost.getCardanoAccountsApi().accountsStakeAddressGet(stakeAddress:) -> ${serializers.toJson(AccountContent.serializer, result.data!)}");
  //     return Ok(result.data!);
  //   } on DioError catch (dioError) {
  //     return Err(translateErrorMessage(dioError: dioError, subject: 'address'));
  //   } catch (e) {
  //     return Err("error loading wallet: '${e.toString}'");
  //   }
  // }

  Future<Result<AccountContent, String>> _loadAccountContent(
      {required String stakeAddress, CancelToken? cancelToken}) async {
    final cachedAccountContent = _accountContentCache[stakeAddress];
    // if (cachedAccountContent != null) {
    //   return Ok(cachedAccountContent);
    // }
    bool notFound404 = false;
    final result = await dioCall<AccountContent>(
      request: () => blockfrost.getCardanoAccountsApi().accountsStakeAddressGet(
          stakeAddress: stakeAddress, cancelToken: cancelToken),
      onSuccess: (data) {
        _accountContentCache[stakeAddress] = data;
        logger.info(
            "blockfrost.getCardanoAccountsApi().accountsStakeAddressGet(stakeAddress:) -> ${serializers.toJson(AccountContent.serializer, data)}");
      },
      errorSubject: 'address',
      onError: (
          {Response? response, DioError? dioError, Exception? exception}) {
        notFound404 = dioError?.response?.statusCode == 404 || dioError?.response?.statusCode == 502;
        logger.severe(
            'notFound404: $notFound404, message: ${exception.toString()}');
      },
    );
    if (notFound404) {
      return Ok(_emptyAccountContent(stakeAddress));
    }
    return result;
  }

  AccountContent _emptyAccountContent(stakeAddress) => AccountContent((b) => b
    ..stakeAddress = stakeAddress
    ..active = false
    ..controlledAmount = '0'
    ..rewardsSum = '0'
    ..withdrawalsSum = '0'
    ..reservesSum = '0'
    ..treasurySum = '0'
    ..withdrawableAmount = '0');

  Future<Result<Block, String>> _loadBlock(
      {required String hashOrNumber, CancelToken? cancelToken}) async {
    final cachedBlock = _blockCache[hashOrNumber];
    if (cachedBlock != null) {
      return Ok(cachedBlock);
    }
    Response<BlockContent> result = await blockfrost
        .getCardanoBlocksApi()
        .blocksHashOrNumberGet(
            hashOrNumber: hashOrNumber,
            cancelToken: cancelToken); //TODO replace with dioCall
    final isData = result.statusCode == 200 && result.data != null;
    if (isData) {
      final b = result.data!;
      logger.info(
          "blockfrost.getCardanoBlocksApi().blocksHashOrNumberGet(hashOrNumber: $hashOrNumber) -> ${serializers.toJson(BlockContent.serializer, b)}");
      final block = Block(
          hash: b.hash,
          height: b.height,
          time: adaDateTime.encode(b.time),
          slot: b.slot ?? 0,
          epoch: b.epoch ?? 0,
          epochSlot: b.epochSlot ?? 0);
      _blockCache[hashOrNumber] = block;
      return Ok(block);
    }
    return Err("${result.statusCode}: ${result.statusMessage}");
  }

  void clearCaches() {
    _transactionCache.clear();
    _blockCache.clear();
    _accountContentCache.clear();
  }

  ///BlockchainCache
  @override
  AccountContent? cachedAccountContent(Bech32Address stakeAddress) =>
      _accountContentCache[stakeAddress];

  ///BlockchainCache
  @override
  Block? cachedBlock(BlockHashHex blockId) => _blockCache[blockId];

  ///BlockchainCache
  @override
  CurrencyAsset? cachedCurrencyAsset(String assetId) => _assetCache[assetId];

  ///BlockchainCache
  @override
  RawTransaction? cachedTransaction(TxIdHex txId) => _transactionCache[txId];
}

///
/// wrapper around Dio CancelToken instance.
///
class DioCancelAction extends CancelAction {
  final cancelToken = CancelToken();

  /// Cancel the request
  @override
  void cancel([reason]) => cancelToken.cancel(reason);

  /// If request have been canceled, save the cancel Error.
  @override
  Exception? get cancelError => cancelToken.cancelError;

  /// When cancelled, this future will be resolved.
  @override
  Future<Exception> get whenCancel => cancelToken.whenCancel;
}

// void main() async {
//   final wallet1 = 'stake_test1uqnf58xmqyqvxf93d3d92kav53d0zgyc6zlt927zpqy2v9cyvwl7a';
//   final walletFactory = ShelleyWalletFactory(networkId: NetworkId.testnet, authInterceptor: MyApiKeyAuthInterceptor());
//   final testnetWallet = await walletFactory.create(stakeAddress: wallet1);
//   for (var addr in testnetWallet.addresses()) {
//     logger.info(addr.toBech32());
//   }
// }
