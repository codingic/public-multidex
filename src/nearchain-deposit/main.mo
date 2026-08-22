// NEAR (NEP-141) deposit detector: scan NEAR blocks via IC HTTPS outcalls to
// the NEAR RPC, parse each transaction's receipt outcomes for NEP-141
// ft_transfer events, and record every transfer whose recipient (`new_owner_id`)
// is a watched deposit address. Detected deposits live in `deposits` until they
// reach CONFIRMED_BLOCKS confirmations, then get archived into
// `depositsConfirmed`. No crediting — the DEX reads the archive (same pull
// model as the ETH/SOL/BTC detectors).
//
// Flow mirrors ethchain-deposit's monitor→detect→confirm→archive exactly:
//   latestHeight → scanBlocks (block-by-block, capped per cycle) →
//   scanBlockProd (per block: getBlockTxHashes → per tx getTxReceipts →
//   extractReceipt matches watched token + watched recipient) →
//   confirmDeposits (archive at depth).
//
// SCOPE: token deposits only. NEAR has no IC-native RPC canister (unlike the
// EVM-RPC canister the ETH detector uses), so we reach the chain with the
// management canister `http_request` HTTPS outcall. We intentionally do NOT
// detect native NEAR transfers (action `Transfer`) — only NEP-141 ft_transfer
// events, per "只是 token 的充值".

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
import Constants "Constants";
import NearRpcTypes "NearRpcTypes";
import Hex "Hex";

persistent actor NearDepositDetector {

  // ── NEAR RPC endpoint (HTTPS outcall target) ──
  func nearRpc() : NearRpcTypes.Management { actor ("aaaaa-aa") };

  func nearRpcUrlEnv<system>() : Text {
    switch (Constants.nearRpcEnv<system>()) {
      case (?u) { u };
      case null { Constants.nearRpcMainnet() };
    };
  };
  // Resolved once at init (env override requires the system capability).
  transient var _nearRpcUrlCache : Text = nearRpcUrlEnv<system>();
  func nearRpcUrl() : Text { _nearRpcUrlCache };

  // key = canonical lowercased NEAR account id (see Hex.lowerText); value =
  // owning principal. A user-account check is an exact match against the
  // inbound ft_transfer event's `new_owner_id`.
  let watchedAddresses = Map.empty<Text, Principal>();
  // lowercased NEP-141 token contract account → same account (membership set
  // of watched tokens). Both the key (watch / unwatch) and the receipt's
  // `executor_id` (match) go through Hex.lowerText, so membership is an exact,
  // case-insensitive check. An EMPTY set means "watch every NEP-141 token"
  // (mirrors ethchain-deposit's watchedTokens behavior).
  let watchedTokens = Map.empty<Text, Text>();

  // last fully-read block height; advanced every scan
  var blockHeight : Nat = 0;
  // consecutive failed scans of the current block; skip it once it hits MAX_SCAN_FAILS
  var scanFailStreak : Nat = 0;

  // pending deposits, deduped by (txHash, logIndex)
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of deposits that reached CONFIRMED_BLOCKS, keyed by
  // dedupKey; the key's presence IS the "already settled" test (no confirmedKeys set).
  // TODO: unbounded growth — at millions of users this map grows forever and
  // inflates canister memory; needs bucketing / backend-consumption-then-prune.
  var depositsConfirmed : Map.Map<Text, Types.Deposit> = Map.empty();

  let scanning = Map.empty<Text, Bool>();

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  public query func getDeployMode() : async Text { "production" };
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // ── token + address watch management (controller-only) ──
  public shared (msg) func watchToken(contract : Text) : async () {
    requireController(msg.caller);
    let c = Hex.lowerText(contract);
    Map.add(watchedTokens, Text.compare, c, c);
  };
  public shared (msg) func unwatchToken(contract : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedTokens, Text.compare, Hex.lowerText(contract));
  };
  public query func getWatchedTokens() : async [Text] {
    Iter.toArray(Map.keys(watchedTokens));
  };

  // register a user's NEAR deposit account (controller-only) so its inbound
  // NEP-141 transfers are detected; `owner` is the principal the account maps to.
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    if (not Hex.isValidNearAccount(addr)) { Runtime.trap("Invalid NEAR account id") };
    Map.add(watchedAddresses, Text.compare, Hex.lowerText(addr), owner);
  };
  public shared (msg) func unregisterDepositAddress(addr : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedAddresses, Text.compare, Hex.lowerText(addr));
  };
  public query func getDepositAddresses() : async [Text] {
    Iter.toArray(Map.keys(watchedAddresses));
  };

  public query func getConfirmedDeposits() : async [Types.Deposit] {
    Iter.toArray(Map.values(depositsConfirmed));
  };

  // ── NEAR RPC over IC HTTPS outcall ──
  // POST a JSON-RPC request to the NEAR RPC endpoint; returns the raw response
  // body text, or null on transport error / non-200 / RPC-level error.
  func nearJsonRpc(method : Text, params : Text) : async ?Text {
    let body = "{\"jsonrpc\":\"2.0\",\"id\":\"dontcare\",\"method\":\"" # method # "\",\"params\":" # params # "}";
    let args : NearRpcTypes.HttpRequestArgs = {
      url = nearRpcUrl();
      max_response_bytes = ?2_000_000;
      method = #post;
      headers = [{ name = "Content-Type"; value = "application/json" }];
      body = ?Text.encodeUtf8(body);
      transform = null;
    };
    try {
      let res = await (with cycles = Constants.NEAR_RPC_CYCLES) nearRpc().http_request(args);
      if (res.status != 200) { return null };
      switch (Text.decodeUtf8(res.body)) {
        case null { null };
        case (?s) {
          // RPC-level error (bad method/params) → no usable data; caller treats
          // this as a failed block and retries next cycle rather than parsing a
          // partial/error payload.
          switch (Json.parse(s)) {
            case (#err _) { null };
            case (#ok j) {
              switch (Json.getAsObject(j, "error")) {
                case (#ok _) { null };
                case (#err _) { ?s };
              };
            };
          };
        };
      };
    } catch (_) { null };
  };

  // current chain height via the "final" block
  func latestHeight() : async Nat {
    let params = "{\"block_id\":\"final\"}";
    switch (await nearJsonRpc("block", params)) {
      case null { 0 };
      case (?s) {
        switch (Json.parse(s)) {
          case (#err _) { 0 };
          case (#ok j) {
            switch (Json.getAsNat(j, "result.header.height")) {
              case (#ok h) { h };
              case (#err _) { 0 };
            };
          };
        };
      };
    };
  };

  // (txHash, signerId) pairs in a block (NEAR `block` →
  // result.transactions[].{hash, signer_id}). BOTH are needed downstream:
  // EXPERIMENTAL_tx_status requires the SENDER (signer) account id alongside the
  // tx hash — a hash alone is rejected by the RPC with UNKNOWN_TRANSACTION.
  func getBlockTxHashes(h : Nat) : async ?[(Text, Text)] {
    let params = "{\"block_id\":" # Nat.toText(h) # "}";
    switch (await nearJsonRpc("block", params)) {
      case null { null };
      case (?s) {
        switch (Json.parse(s)) {
          case (#err _) { null };
          case (#ok j) {
            switch (Json.getAsArray(j, "result.transactions")) {
              case (#err _) { null };
              case (#ok txs) {
                let out = List.empty<(Text, Text)>();
                for (t in txs.vals()) {
                  let hsh = switch (Json.getAsText(t, "hash")) { case (#ok v) { v }; case (#err _) { "" } };
                  // skip malformed entries (no hash) rather than trapping the
                  // whole block — a single bad tx shouldn't drop the others
                  if (hsh != "") {
                    let signer = switch (Json.getAsText(t, "signer_id")) { case (#ok v) { v }; case (#err _) { "" } };
                    out.add((hsh, signer));
                  };
                };
                ?List.toArray(out);
              };
            };
          };
        };
      };
    };
  };

  // receipt outcomes for a transaction (EXPERIMENTAL_tx_status →
  // result.receipts_outcome). The method REQUIRES both `tx_hash` and
  // `sender_account_id` (the signer) as an OBJECT (not the legacy array form),
  // so we thread the signer fetched alongside the hash in getBlockTxHashes.
  // RPCs that return the newer `tx` shape put the outcomes under
  // `result.receipts`; we fall back to that field so the detector works against
  // either response shape. Both fields carry `outcome.executor_id` /
  // `outcome.logs`, which extractReceipt reads.
  func getTxReceipts(hash : Text, signer : Text) : async ?[Json.Json] {
    let params = "{\"tx_hash\":\"" # hash # "\",\"sender_account_id\":\"" # signer
      # "\",\"wait_until\":\"EXECUTED\"}";
    switch (await nearJsonRpc("EXPERIMENTAL_tx_status", params)) {
      case null { null };
      case (?s) {
        switch (Json.parse(s)) {
          case (#err _) { null };
          case (#ok j) {
            switch (Json.getAsArray(j, "result.receipts_outcome")) {
              case (#ok r) { ?r };
              case (#err _) {
                switch (Json.getAsArray(j, "result.receipts")) {
                  case (#ok r) { ?r };
                  case (#err _) { null };
                };
              };
            };
          };
        };
      };
    };
  };

  // inspect one receipt outcome for NEP-141 ft_transfer events paying a watched
  // deposit account; record each match. `rIdx` is the receipt's index within the
  // tx (used to build a unique dedup key).
  func extractReceipt(h : Nat, txHash : Text, rIdx : Nat, receipt : Json.Json) {
    let executor = switch (Json.getAsText(receipt, "outcome.executor_id")) {
      case (#ok e) { Hex.lowerText(e) };
      case (#err _) { "" };
    };
    if (executor == "") { return };
    // token filter: when watchedTokens is non-empty, only accept this token's events
    if (Map.size(watchedTokens) > 0 and Map.get(watchedTokens, Text.compare, executor) == null) { return };

    // Record one parsed ft_transfer `data` entry (NEP-297) whose recipient is a
    // watched deposit account. `logIndex` is the fully-composed dedup index
    // (receiptIdx * 100000 + logIdx * 100 + dataIdx) so batched events
    // (data-as-array) each get a DISTINCT key instead of clobbering each other.
    func tryRecord(entries : [(Text, Json.Json)], logIndex : Nat) {
      var from = "";
      var to = "";
      var amount = "0";
      for ((k, v) in entries.vals()) {
        switch (v) {
          case (#string s) {
            if (k == "old_owner_id") { from := Hex.lowerText(s) };
            if (k == "new_owner_id") { to := Hex.lowerText(s) };
            if (k == "amount") { amount := s };
          };
          case (_) {};
        };
      };
      if (to != "" and Map.get(watchedAddresses, Text.compare, to) != null) {
        let amountRaw = Hex.decimalToNat(amount);
        if (amountRaw > 0) {
          recordDeposit(h, {
            txHash = txHash;
            logIndex = logIndex;
            kind = "log";
            asset = executor;
            token = ?executor;
            from = from;
            to = to;
            amountRaw = amountRaw;
          });
        };
      };
    };

    let logs = switch (Json.getAsArray(receipt, "outcome.logs")) {
      case (#ok l) { l };
      case (#err _) { [] };
    };
    var logIdx = 0;
    for (log in logs.vals()) {
      switch (log) {
        case (#string line) {
          if (Text.startsWith(line, #text "EVENT_JSON:")) {
            let ev = Hex.eventJson(line);
            switch (Json.parse(ev)) {
              case (#err _) {};
              case (#ok ej) {
                let std = switch (Json.getAsText(ej, "standard")) { case (#ok v) { v }; case (#err _) { "" } };
                let evName = switch (Json.getAsText(ej, "event")) { case (#ok v) { v }; case (#err _) { "" } };
                if (std == "nep141" and evName == "ft_transfer") {
                  // NEP-297 `data` is normally a single object; the standard also
                  // allows an ARRAY of objects (a batch of ft_transfers in one log
                  // line). Handle both, otherwise a batched transfer is silently dropped.
                  switch (Json.getAsArray(ej, "data")) {
                    case (#ok arr) {
                      var dataIdx = 0;
                      for (d in arr.vals()) {
                        switch (d) {
                          case (#object_(entries)) {
                            tryRecord(entries, rIdx * 100000 + logIdx * 100 + dataIdx);
                            dataIdx += 1;
                          };
                          case (_) {};
                        };
                      };
                    };
                    case (#err _) {
                      switch (Json.getAsObject(ej, "data")) {
                        case (#ok entries) { tryRecord(entries, rIdx * 100000 + logIdx * 100) };
                        case (#err _) {};
                      };
                    };
                  };
                };
              };
            };
          };
        };
        case (_) {};
      };
      logIdx += 1;
    };
  };

  // record only NEP-141 transfers to a watched deposit account
  func recordDeposit(h : Nat, t : Types.Transfer) {
    if (t.amountRaw == 0) { return }; // skip zero-value transfers
    // dedup key includes logIndex so one tx with multiple ft_transfer logs to
    // the same watched account don't clobber each other
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
    // NEAR: get the block's (txHash, signer) pairs, resolve each via
    // EXPERIMENTAL_tx_status, and record the ft_transfer events whose recipient
    // is a watched address.
    switch (await getBlockTxHashes(h)) {
      case null { ok := false };
      case (?txs) {
        for ((hash, signer) in txs.vals()) {
          switch (await getTxReceipts(hash, signer)) {
            case null { ok := false };
            case (?receipts) {
              var rIdx = 0;
              for (rcpt in receipts.vals()) {
                extractReceipt(h, hash, rIdx, rcpt);
                rIdx += 1;
              };
            };
          };
        };
      };
    };
    ok;
  };

  func scanBlocks() : async () {
    if (Map.get(scanning, Text.compare, "scan") != null) { return };
    Map.add(scanning, Text.compare, "scan", true);

    let tip = await latestHeight();
    // fresh deploy: jump to the tip instead of replaying from genesis
    if (blockHeight == 0 and tip > 0) {
      blockHeight := if (tip > Constants.DELAY_BLOCKS + Constants.MAX_BLOCKS_PER_SCAN) {
        tip - Constants.DELAY_BLOCKS - Constants.MAX_BLOCKS_PER_SCAN;
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

  // move deposits that reached CONFIRMED_BLOCKS into depositsConfirmed; refresh
  // confirmations for the rest
  func confirmDeposits(tip : Nat) {
    let moved = List.empty<Types.Deposit>();
    let movedKeys = List.empty<Text>();
    let toRefresh = List.empty<(Text, Types.Deposit)>();
    for ((dk, d) in Map.entries(deposits)) {
      let confirmations = if (tip > d.blockHeight) { tip - d.blockHeight } else { 0 };
      if (confirmations >= Constants.CONFIRMED_BLOCKS) {
        moved.add({ d with confirmations = confirmations });
        movedKeys.add(dk);
      } else if (confirmations != d.confirmations) {
        toRefresh.add((dk, { d with confirmations = confirmations }));
      };
    };
    // delete archived entries AFTER the iteration — mutating the map mid-iteration is unsafe
    for (dk in List.toArray(movedKeys).vals()) {
      ignore Map.delete(deposits, Text.compare, dk);
    };
    for ((dk, d) in List.toArray(toRefresh).vals()) {
      Map.add(deposits, Text.compare, dk, d);
    };
    // append the newly-archived deposits to the confirmed map (keyed by dedupKey;
    // idempotent because a deposit is removed from `deposits` first)
    for (d in List.toArray(moved).vals()) {
      let dk = d.txHash # "#" # Nat.toText(d.logIndex);
      Map.add(depositsConfirmed, Text.compare, dk, d);
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
    // depositsConfirmed persists across upgrades — no backfill needed
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
