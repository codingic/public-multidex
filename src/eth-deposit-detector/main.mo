// ETH deposit detector: scan Ethereum blocks, parse inbound ETH/ERC-20
// transfers, store them in `deposits`, and archive deeply-confirmed ones into
// the `depositsConfirmed` array. No crediting — the DEX reads the archive.

import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Cycles "mo:core/Cycles";
import Timer "mo:core/Timer";
import Json "mo:json";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Types "Types";
import EvmRpcTypes "EvmRpcTypes";
import Constants "Constants";
import Hex "Hex";

// (txHash, recipient) pulled from a block receipt; `to` is null for
// contract-creation txs (no ETH transfer target)
type ReceiptHit = { txHash : Text; to : ?Text };

persistent actor EthDepositDetector {

  func evmRpc() : Principal {
    switch (_evmRpcCache) { case (?p) { p }; case null { Constants.evmRpcMainnet() } };
  };
  transient var _evmRpcCache : ?Principal = Constants.evmRpcEnv<system>();

  // key = lowercased deposit address; value = owning principal
  let watchedAddresses = Map.empty<Text, Principal>();
  // lowercased contract -> same address (membership set of watched ERC-20 tokens)
  let watchedTokens = Map.empty<Text, Text>();

  // last fully-read block height; advanced every scan
  var blockHeight : Nat = 0;

  // pending deposits, deduped by (txHash, kind): native "#native", ERC-20 "#logIndex"
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of deposits that reached CONFIRMED_BLOCKS
  // TODO: unbounded growth — at millions of users this array grows forever and
  // inflates canister memory; needs bucketing / backend-consumption-then-prune.
  var depositsConfirmed : [Types.Deposit] = [];
  // keys already archived, so a re-scanned transfer isn't archived twice
  let confirmedKeys = Map.empty<Text, ()>();

  let scanning = Map.empty<Text, Bool>();

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  public query func getDeployMode() : async Text { "production" };
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  public shared (msg) func watchToken(contract : Text) : async () {
    requireController(msg.caller);
    let c = Hex.lowerHex(contract);
    Map.add(watchedTokens, Text.compare, c, c);
  };
  public shared (msg) func unwatchToken(contract : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedTokens, Text.compare, Hex.lowerHex(contract));
  };
  public query func getWatchedTokens() : async [Text] {
    Iter.toArray(Map.keys(watchedTokens));
  };

  // register a user's deposit address (controller-only) so its inbound ERC-20
  // transfers are detected; `owner` is the principal the address belongs to
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    // normalize to lowercased 0x-prefixed form so it matches the key
    // extractLogEntry derives from a 32-byte topic (always 0x-prefixed)
    let a = Hex.lowerHex(addr);
    let key = if (Text.startsWith(a, #text "0x")) { a } else { "0x" # a };
    Map.add(watchedAddresses, Text.compare, key, owner);
  };
  public shared (msg) func unregisterDepositAddress(addr : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedAddresses, Text.compare, Hex.lowerHex(addr));
  };
  public query func getDepositAddresses() : async [Text] {
    Iter.toArray(Map.keys(watchedAddresses));
  };

  public query func getConfirmedDeposits() : async [Types.Deposit] {
    depositsConfirmed;
  };

  // raw JSON-RPC via multi_request (multi-provider consensus); null on error
  func multiRequestText(json : Text, cfg : ?EvmRpcTypes.RpcConfig, cycles : Nat) : async ?Text {
    let rpc : EvmRpcTypes.EvmRpc = actor (Principal.toText(evmRpc()));
    try {
      let r = await (with cycles = cycles) rpc.multi_request(Constants.ETH_CHAIN, cfg, json);
      switch r {
        case (#Consistent x) { switch x { case (#Ok t) { ?t }; case (#Err _) { null } } };
        case (#Inconsistent _) { null };
      };
    } catch (_) { null };
  };

  func latestHeight() : async Nat {
    let rpc : EvmRpcTypes.EvmRpc = actor (Principal.toText(evmRpc()));
    try {
      let r = await (with cycles = Constants.EVM_RPC_CYCLES) rpc.eth_getBlockByNumber(Constants.ETH_CHAIN, null, #Latest);
      switch r {
        case (#Consistent x) { switch x { case (#Ok b) { b.number }; case (#Err _) { 0 } } };
        case (#Inconsistent _) { 0 };
      };
    } catch (_) { 0 };
  };

  // resolve one tx (eth_getTransactionByHash) into a Transfer; null on miss
  func evmGetTx(hash : Text) : async ?Types.Transfer {
    let json = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionByHash\",\"params\":[\""
      # hash # "\"],\"id\":1}";
    let t = await multiRequestText(json, null, Constants.EVM_RPC_CYCLES);
    switch t {
      case null { null };
      case (?s) {
        switch (Json.parse(s)) {
          case (#err _) { null };
          case (#ok j) {
            let to = switch (Json.getAsText(j, "result.to")) {
              case (#ok v) { Hex.lowerHex(v) }; case (#err _) { "" };
            };
            if (to == "") { return null };
            let valueHex = switch (Json.getAsText(j, "result.value")) {
              case (#ok v) { v }; case (#err _) { "0x0" };
            };
            let from = switch (Json.getAsText(j, "result.from")) {
              case (#ok v) { Hex.lowerHex(v) }; case (#err _) { "" };
            };
            ?{
              txHash = hash;
              logIndex = 0;
              asset = Constants.ASSET;
              token = null;
              from = from;
              to = to;
              amountRaw = Hex.hexToNat(valueHex);
            };
          };
        };
      };
    };
  };

  // One RPC returns the whole block's receipts. We keep (txHash, to) for each
  // and let the caller match `to` against the (potentially million-entry)
  // watchedAddresses, fetching value only for hits. This collapses per-block
  // ETH RPC from ~hundreds of eth_getTransactionByHash calls to one receipt
  // call + a handful of value lookups.
  func ethGetBlockReceipts(h : Nat) : async [ReceiptHit] {
    let json = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockReceipts\",\"params\":[\""
      # Nat.toText(h) # "\"],\"id\":1}";
    let cfg : EvmRpcTypes.RpcConfig = {
      responseSizeEstimate = ?(4_000_000 : Nat64);   // whole-block receipt payload can be MB-sized
      responseConsensus = null;
    };
    let t = await multiRequestText(json, ?cfg, Constants.EVM_RPC_RECEIPTS_CYCLES);
    switch t {
      case null { [] };
      case (?s) {
        switch (Json.parse(s)) {
          case (#err _) { [] };
          case (#ok j) {
            switch (Json.getAsArray(j, "result")) {
              case (#err _) { [] };
              case (#ok receipts) {
                let hits = List.empty<ReceiptHit>();
                for (r in receipts.vals()) {
                  let txHash = switch (Json.getAsText(r, "transactionHash")) {
                    case (#ok v) { v }; case (#err _) { "" };
                  };
                  if (txHash != "") {
                    // `to` is null for contract-creation txs (no ETH target)
                    let to = switch (Json.getAsText(r, "to")) {
                      case (#ok v) { ?v }; case (#err _) { null };
                    };
                    hits.add({ txHash = txHash; to = to });
                  };
                };
                List.toArray(hits);
              };
            };
          };
        };
      };
    };
  };

  // pull Transfer logs for a batch of watched token contracts; the on-chain
  // `addresses` filter keeps the returned log volume small, and the recipient
  // is still matched locally against the (potentially million-entry) watchedAddresses
  func ethGetLogs(h : Nat, contracts : [Text]) : async [EvmRpcTypes.LogEntry] {
    let rpc : EvmRpcTypes.EvmRpc = actor (Principal.toText(evmRpc()));
    let args : EvmRpcTypes.GetLogsArgs = {
      fromBlock = ?#Number h;
      toBlock = ?#Number h;
      addresses = contracts;   // filter by watched token contracts on-chain
      topics = ?[ [Constants.TRANSFER_SIG] ];   // Transfer(address,address,uint256)
    };
    try {
      let r = await (with cycles = Constants.EVM_RPC_CYCLES) rpc.eth_getLogs(Constants.ETH_CHAIN, null, args);
      switch r {
        case (#Consistent x) { switch x { case (#Ok logs) { logs }; case (#Err _) { [] } } };
        case (#Inconsistent _) { [] };
      };
    } catch (_) { [] };
  };

  // record only Transfer logs from a watched token to a watched deposit address
  func extractLogEntry(h : Nat, log : EvmRpcTypes.LogEntry) {
    if (log.topics.size() < 3) { return };
    if (log.topics[0] != Constants.TRANSFER_SIG) { return };
    if (log.logIndex == null) { return };   // no log index → can't build a safe dedup key
    let contract = Hex.lowerHex(log.address);
    if (Map.get(watchedTokens, Text.compare, contract) == null) { return };
    let recipient = Hex.lowerHex(Hex.topicToAddress(log.topics[2]));
    if (recipient == "" or Map.get(watchedAddresses, Text.compare, recipient) == null) { return };
    let from = Hex.lowerHex(Hex.topicToAddress(log.topics[1]));
    let amountRaw = Hex.hexToNat(log.data);
    let logIndex = switch (log.logIndex) { case (?n) { n }; case null { 0 } };
    let txHash = switch (log.transactionHash) { case (?t) { t }; case null { "" } };
    recordDeposit(h, {
      txHash = txHash;
      logIndex = logIndex;
      asset = contract;
      token = ?contract;
      from = from;
      to = recipient;
      amountRaw = amountRaw;
    });
  };

  func recordDeposit(h : Nat, t : Types.Transfer) {
    if (t.amountRaw == 0) { return }; // skip zero-value transfers
    let dk = if (t.token == null) { t.txHash # "#native" }
             else { t.txHash # "#" # Nat.toText(t.logIndex) };
    if (Map.get(deposits, Text.compare, dk) == null and Map.get(confirmedKeys, Text.compare, dk) == null) {
      Map.add(deposits, Text.compare, dk, {
        txHash = t.txHash;
        logIndex = t.logIndex;
        asset = t.asset;
        token = t.token;
        from = t.from;
        to = t.to;
        amountRaw = t.amountRaw;
        blockHeight = h;
        confirmations = 0;
      });
    };
  };

  func scanBlockProd(h : Nat) : async () {
    // ETH native deposits: one receipt call covers the whole block; only
    // receipts whose `to` is a watched address get a value lookup
    for (r in (await ethGetBlockReceipts(h)).vals()) {
      switch (r.to) {
        case null {};
        case (?toAddr) {
          let to = Hex.lowerHex(toAddr);
          if (Map.get(watchedAddresses, Text.compare, to) != null) {
            switch (await evmGetTx(r.txHash)) {
              case (?tx) { if (tx.amountRaw > 0) { recordDeposit(h, tx) } };
              case null {};
            };
          };
        };
      };
    };
    // ERC-20 Transfer logs: filter by watched token contracts on-chain (log
    // volume stays small); split into batches so the addresses array never
    // exceeds provider limits, then match recipients locally
    if (Map.size(watchedTokens) > 0) {
      let contracts = Iter.toArray(Map.keys(watchedTokens));
      var i = 0;
      while (i < contracts.size()) {
        let n = if (contracts.size() - i < Constants.LOG_ADDR_BATCH) {
          contracts.size() - i;
        } else {
          Constants.LOG_ADDR_BATCH;
        };
        let batch = Array.tabulate<Text>(n, func(k : Nat) : Text { contracts[i + k] });
        for (log in (await ethGetLogs(h, batch)).vals()) { extractLogEntry(h, log) };
        i += n;
      };
    };
  };

  func scanBlocks() : async () {
    if (Map.get(scanning, Text.compare, "scan") != null) { return };
    Map.add(scanning, Text.compare, "scan", true);

    let tip = await latestHeight();
    // fresh deploy: jump to the tip instead of replaying from genesis (we'd
    // never catch up on mainnet otherwise)
    if (blockHeight == 0 and tip > 0) {
      blockHeight := if (tip > Constants.DELAY_BLOCKS + Constants.MAX_BLOCKS_PER_SCAN) {
        tip - Constants.DELAY_BLOCKS - Constants.MAX_BLOCKS_PER_SCAN
      } else { 0 };
    };
    let safeTip = if (tip > Constants.DELAY_BLOCKS) { tip - Constants.DELAY_BLOCKS } else { 0 };
    let batchEnd = if (safeTip > blockHeight + Constants.MAX_BLOCKS_PER_SCAN) {
      blockHeight + Constants.MAX_BLOCKS_PER_SCAN;
    } else { safeTip };
    if (batchEnd <= blockHeight) { ignore Map.delete(scanning, Text.compare, "scan"); return };

    var h = blockHeight + 1;
    while (h <= batchEnd) {
      await scanBlockProd(h);
      h += 1;
    };
    blockHeight := batchEnd;

    confirmDeposits(tip);

    ignore Map.delete(scanning, Text.compare, "scan");
  };

  // move deposits that reached CONFIRMED_BLOCKS into depositsConfirmed; refresh
  // confirmations for the rest
  func confirmDeposits(tip : Nat) {
    let moved = List.empty<Types.Deposit>();
    let movedKeys = List.empty<Text>();
    let toRefresh = List.empty<(Text, Types.Deposit)>();
    for ((dk, d) in Map.entries(deposits)) {
      let confirmations = if (tip > d.blockHeight) { tip - d.blockHeight } else { 0 };
      if (confirmations >= Constants.CONFIRMED_BLOCKS) {
        moved.add({
          d with
          confirmations = confirmations;
        });
        movedKeys.add(dk);
      } else if (confirmations != d.confirmations) {
        toRefresh.add((
          dk,
          {
            d with
            confirmations = confirmations;
          },
        ));
      };
    };
    // delete archived entries AFTER the iteration — mutating the map mid-iteration is unsafe
    for (dk in List.toArray(movedKeys).vals()) {
      ignore Map.delete(deposits, Text.compare, dk);
      Map.add(confirmedKeys, Text.compare, dk, ());
    };
    for ((dk, d) in List.toArray(toRefresh).vals()) {
      Map.add(deposits, Text.compare, dk, d);
    };
    let movedArr = List.toArray(moved);
    if (movedArr.size() > 0) {
      let combined = List.fromArray<Types.Deposit>(depositsConfirmed);
      List.append(combined, moved);
      depositsConfirmed := List.toArray(combined);
    };
  };

  public shared func scanAll() : async () {
    await scanBlocks();
  };

  let _scanTimer = Timer.recurringTimer(#seconds(Constants.SCAN_INTERVAL_SEC), scanBlocks);

  system func postupgrade() {
    Map.clear(scanning);
    // backfill the archive-key set from existing confirmed deposits so a
    // re-scanned transfer isn't archived twice right after an upgrade
    for (d in depositsConfirmed.vals()) {
      let dk = if (d.token == null) { d.txHash # "#native" } else { d.txHash # "#" # Nat.toText(d.logIndex) };
      Map.add(confirmedKeys, Text.compare, dk, ());
    };
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
