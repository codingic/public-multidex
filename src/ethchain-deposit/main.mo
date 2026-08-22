// ETH deposit detector: scan Ethereum blocks, parse inbound ETH/ERC-20
// transfers, store them in `deposits`, and archive deeply-confirmed ones into
// the `depositsConfirmed` Map (keyed by dedup key). No crediting — the DEX reads the archive.

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
import Types "Types";
import EvmRpcTypes "EvmRpcTypes";
import Constants "Constants";
import Hex "Hex";

persistent actor EthDepositDetector {

  func evmRpc() : Principal {
    switch (_evmRpcCache) { case (?p) { p }; case null { Constants.evmRpcMainnet() } };
  };
  transient var _evmRpcCache : ?Principal = Constants.evmRpcEnv<system>();

  // key = canonical lowercased 0x-prefixed deposit address (see normalizeAddress);
  // value = owning principal. A user-address check is an exact match against the
  // inbound transfer's normalized `to` / recipient.
  let watchedAddresses = Map.empty<Text, Principal>();
  // lowercased 0x-prefixed contract -> same address (membership set of watched
  // ERC-20 tokens). Both the key (watch / unwatch) and the log's `log.address`
  // (match) go through normalizeAddress, so membership is an exact,
  // case-insensitive check.
  let watchedTokens = Map.empty<Text, Text>();

  // Canonical ETH address key: lowercase + 0x-prefixed. This is the single
  // normalization point used by BOTH the watchedAddresses key (on register /
  // unregister) AND the inbound transfer's `to` / recipient (on match), so a
  // user-address check is an exact, case-insensitive match no matter whether a
  // caller or the chain supplies a bare / checksummed address.
  func normalizeAddress(addr : Text) : Text {
    let a = Hex.lowerHex(addr);
    if (Text.startsWith(a, #text "0x")) { a } else { "0x" # a };
  };

  // last fully-read block height; advanced every scan
  var blockHeight : Nat = 0;
  // consecutive failed scans of the current block; once it hits MAX_SCAN_FAILS
  // the block is skipped so a permanently-broken block can't wedge the cursor
  var scanFailStreak : Nat = 0;

  // pending deposits, deduped by (txHash, kind). Native ETH has kind "native";
  // ERC-20 uses txHash#logIndex.
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of deposits that reached CONFIRMED_BLOCKS, keyed by the
  // same dedup key (txHash#kind / txHash#logIndex) used in `deposits`. Because
  // it's keyed, re-archiving a transfer is a no-op and the archive doubles as
  // the "already settled" membership check used by recordDeposit — so no
  // separate `confirmedKeys` set is needed (and can't drift out of sync).
  // TODO: still unbounded — at millions of users this Map grows forever and
  // inflates canister memory; needs bucketing / backend-consumption-then-prune.
  let depositsConfirmed = Map.empty<Text, Types.Deposit>();

  let scanning = Map.empty<Text, Bool>();

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  public query func getDeployMode() : async Text { "production" };
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  public shared (msg) func watchToken(contract : Text) : async () {
    requireController(msg.caller);
    let c = normalizeAddress(contract);
    Map.add(watchedTokens, Text.compare, c, c);
  };
  public shared (msg) func unwatchToken(contract : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedTokens, Text.compare, normalizeAddress(contract));
  };
  public query func getWatchedTokens() : async [Text] {
    Iter.toArray(Map.keys(watchedTokens));
  };

  // register a user's deposit address (controller-only) so its inbound ERC-20
  // transfers are detected; `owner` is the principal the address belongs to
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    // store under the canonical lowercased 0x-prefixed key (see normalizeAddress)
    Map.add(watchedAddresses, Text.compare, normalizeAddress(addr), owner);
  };
  public shared (msg) func unregisterDepositAddress(addr : Text) : async () {
    requireController(msg.caller);
    // normalize the same way as register; a bare / checksummed input would
    // otherwise miss the stored key and leave the address silently watched
    ignore Map.delete(watchedAddresses, Text.compare, normalizeAddress(addr));
  };
  public query func getDepositAddresses() : async [Text] {
    Iter.toArray(Map.keys(watchedAddresses));
  };

  public query func getConfirmedDeposits() : async [Types.Deposit] {
    Iter.toArray(Map.values(depositsConfirmed));
  };

  // raw JSON-RPC via multi_request (multi-provider consensus); null on error
  func multiRequestText(json : Text, cfg : ?EvmRpcTypes.RpcConfig) : async ?Text {
    let rpc : EvmRpcTypes.EvmRpc = actor (Principal.toText(evmRpc()));
    try {
      let r = await (with cycles = Constants.EVM_RPC_CYCLES) rpc.multi_request(Constants.ETH_CHAIN, cfg, json);
      switch r {
        case (#Consistent x) { switch x { case (#Ok t) { ?t }; case (#Err _) { null } } };
        case (#Inconsistent _) { null };
      };
    } catch (_) { null };
  };

  func latestHeight() : async Nat {
    let rpc : EvmRpcTypes.EvmRpc = actor (Principal.toText(evmRpc()));
    try {
      let r = await (with cycles = Constants.EVM_RPC_CYCLES) rpc.eth_getBlockByNumber(Constants.ETH_CHAIN, null, #Finalized);
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
    let t = await multiRequestText(json, null);
    switch t {
      case null { null };
      case (?s) {
        switch (Json.parse(s)) {
          case (#err _) { null };
          case (#ok j) {
            let to = switch (Json.getAsText(j, "result.to")) {
              case (#ok v) { normalizeAddress(v) }; case (#err _) { "" };
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
              kind = "native";
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

  // fetch a block's transaction hashes via eth_getBlockByNumber (standard
  // method); null on error. The caller resolves each hash via evmGetTx and
  // matches `to` against watchedAddresses.
  func getBlock(h : Nat) : async ?[Text] {
    let rpc : EvmRpcTypes.EvmRpc = actor (Principal.toText(evmRpc()));
    try {
      let r = await (with cycles = Constants.EVM_RPC_CYCLES) rpc.eth_getBlockByNumber(Constants.ETH_CHAIN, null, #Number h);
      switch r {
        case (#Consistent x) { switch x { case (#Ok b) { ?b.transactions }; case (#Err _) { null } } };
        case (#Inconsistent _) { null };
      };
    } catch (_) { null };
  };

  // pull all Transfer logs for a block (no on-chain address filter); the
  // watched-contract check and the recipient check both happen locally in
  // extractLogEntry
  func ethGetLogs(h : Nat) : async ?[EvmRpcTypes.LogEntry] {
    let rpc : EvmRpcTypes.EvmRpc = actor (Principal.toText(evmRpc()));
    let args : EvmRpcTypes.GetLogsArgs = {
      fromBlock = ?#Number h;
      toBlock = ?#Number h;
      addresses = [];   // empty = no address filter: pull the block's Transfer logs whole
      topics = ?[ [Constants.TRANSFER_SIG] ];   // Transfer(address,address,uint256)
    };
    try {
      let r = await (with cycles = Constants.EVM_RPC_CYCLES) rpc.eth_getLogs(Constants.ETH_CHAIN, null, args);
      switch r {
        case (#Consistent x) { switch x { case (#Ok logs) { ?logs }; case (#Err _) { null } } };
        case (#Inconsistent _) { null };
      };
    } catch (_) { null };
  };

  // record only Transfer logs from a watched token to a watched deposit address
  func extractLogEntry(h : Nat, log : EvmRpcTypes.LogEntry) {
    // a log reverted by a chain reorg carries removed=true — never a real deposit
    if (log.removed) { return };
    if (log.topics.size() < 3) { return };
    if (log.topics[0] != Constants.TRANSFER_SIG) { return };
    if (log.logIndex == null) { return };   // no log index → can't build a safe dedup key
    let contract = normalizeAddress(log.address);
    if (Map.get(watchedTokens, Text.compare, contract) == null) { return };
    let recipient = normalizeAddress(Hex.topicToAddress(log.topics[2]));
    if (recipient == "" or Map.get(watchedAddresses, Text.compare, recipient) == null) { return };
    let from = Hex.lowerHex(Hex.topicToAddress(log.topics[1]));
    let amountRaw = Hex.hexToNat(log.data);
    let logIndex = switch (log.logIndex) { case (?n) { n }; case null { 0 } };
    // hash for the dedup key: tx hash, falling back to block hash if the RPC omits it
    let txHash = switch (log.transactionHash) {
      case (?t) { t };
      case null { switch (log.blockHash) { case (?b) { b }; case null { "" } } };
    };
    recordDeposit(h, {
      txHash = txHash;
      logIndex = logIndex;
      kind = "log";
      asset = contract;
      token = ?contract;
      from = from;
      to = recipient;
      amountRaw = amountRaw;
    });
  };

  func recordDeposit(h : Nat, t : Types.Transfer) {
    if (t.amountRaw == 0) { return }; // skip zero-value transfers
    // ERC-20 key = `hash#logIndex`; native ETH key = `hash#kind` (no log index)
    let dk = if (t.token == null) { t.txHash # "#" # t.kind }
             else { t.txHash # "#" # Nat.toText(t.logIndex) };
    if (Map.get(deposits, Text.compare, dk) == null and Map.get(depositsConfirmed, Text.compare, dk) == null) {
      Map.add(deposits, Text.compare, dk, {
        txHash = t.txHash;
        logIndex = t.logIndex;
        kind = t.kind;
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

  func scanBlockProd(h : Nat) : async Bool {
    var ok = true;
    // ETH native deposits: fetch the block's tx hashes, resolve each via
    // eth_getTransactionByHash, and record those whose `to` is a watched address
    switch (await getBlock(h)) {
      case null { ok := false };
      case (?txHashes) {
        for (hash in txHashes.vals()) {
          switch (await evmGetTx(hash)) {
            case (?tx) {
              if (tx.amountRaw > 0 and Map.get(watchedAddresses, Text.compare, tx.to) != null) {
                recordDeposit(h, tx);
              };
            };
            // a single tx lookup failing is transient (network/provider) — mark
            // the block failed so scanBlocks retries it rather than skipping the tx
            case null { ok := false };
          };
        };
      };
    };
    // ERC-20 Transfer logs: pull the block's Transfer logs whole, then match
    // the watched contract and the watched recipient locally in extractLogEntry
    if (Map.size(watchedTokens) > 0) {
      switch (await ethGetLogs(h)) {
        case null { ok := false };
        case (?logs) { for (log in logs.vals()) { extractLogEntry(h, log) } };
      };
    };
    ok;
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
      let ok = await scanBlockProd(h);
      if (not ok) {
        scanFailStreak += 1;
        if (scanFailStreak >= Constants.MAX_SCAN_FAILS) {
          // skip a permanently-broken block so the cursor doesn't wedge
          blockHeight := h;
          scanFailStreak := 0;
          h += 1;
        } else {
          // transient failure → retry this block next cycle
          confirmDeposits(safeTip);
          ignore Map.delete(scanning, Text.compare, "scan");
          return;
        };
      } else {
        scanFailStreak := 0;
        h += 1;
      };
    };
    blockHeight := batchEnd;

    confirmDeposits(safeTip);

    ignore Map.delete(scanning, Text.compare, "scan");
  };

  // Archive deposits that reached CONFIRMED_BLOCKS into depositsConfirmed
  // (keyed by dk, so re-archiving is a no-op). Refresh confirmations for the rest;
  // the deletes/additions happen in a second pass (mutating `deposits` mid-iteration is unsafe).
  func confirmDeposits(tip : Nat) {
    let moved = List.empty<(Text, Types.Deposit)>();
    let toRefresh = List.empty<(Text, Types.Deposit)>();
    for ((dk, d) in Map.entries(deposits)) {
      let confirmations = if (tip > d.blockHeight) { tip - d.blockHeight } else { 0 };
      if (confirmations >= Constants.CONFIRMED_BLOCKS) {
        moved.add((dk, { d with confirmations }));
      } else if (confirmations != d.confirmations) {
        toRefresh.add((dk, { d with confirmations }));
      };
    };
    for ((dk, d) in List.toArray(moved).vals()) {
      Map.add(depositsConfirmed, Text.compare, dk, d);
      ignore Map.delete(deposits, Text.compare, dk);
    };
    for ((dk, d) in List.toArray(toRefresh).vals()) {
      Map.add(deposits, Text.compare, dk, d);
    };
  };

  public shared func scanAll() : async () {
    await scanBlocks();
  };

  // transient so the timer re-arms on upgrade (a plain `let` would be STABLE
  // and silently stop scanning after an upgrade)
  transient let _scanTimer = Timer.recurringTimer(#seconds(Constants.SCAN_INTERVAL_SEC), scanBlocks);

  system func postupgrade() {
    Map.clear(scanning);
    // depositsConfirmed is the authoritative settled archive (a Map keyed by
    // dk); recordDeposit consults it directly, so there is no separate key set
    // to rebuild after an upgrade.
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
