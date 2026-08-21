// SOL (Solana) deposit detector: poll each watched deposit address via the
// dfinity sol-rpc canister, resolve new inbound signatures, parse native SOL
// and SPL-token transfers, store them in `deposits`, and archive
// deeply-confirmed ones into `depositsConfirmed`. No crediting — the DEX reads
// the archive.
//
// Model mirrors the ETH detector's monitor→detect→confirm→archive flow: it
// walks finalized slots via getBlock and inspects every transaction in each
// block, matching recipient addresses against watchedAddresses / watchedTokens.

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
import SolRpcTypes "SolRpcTypes";
import Constants "Constants";
import Base58 "Base58";

persistent actor SolDepositDetector {

  func solRpc() : Principal {
    switch (_solRpcCache) { case (?p) { p }; case null { Constants.solRpcMainnet() } };
  };
  transient var _solRpcCache : ?Principal = Constants.solRpcEnv<system>();

  // key = base58 deposit (owner) address; value = owning principal
  let watchedAddresses = Map.empty<Text, Principal>();
  // base58 mint -> same mint (membership set of watched SPL tokens)
  let watchedTokens = Map.empty<Text, Text>();

  // last fully-read slot; advanced every scan
  var slotHeight : Nat = 0;

  // pending deposits, deduped by dedupKey (tx signature + direction + index)
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of deposits that reached CONFIRMED_SLOTS
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

  public shared (msg) func watchToken(mint : Text) : async () {
    requireController(msg.caller);
    Map.add(watchedTokens, Text.compare, mint, mint);
  };
  public shared (msg) func unwatchToken(mint : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedTokens, Text.compare, mint);
  };
  public query func getWatchedTokens() : async [Text] {
    Iter.toArray(Map.keys(watchedTokens));
  };

  // register a user's SOL deposit address (controller-only) so its inbound
  // transfers are detected; `owner` is the principal the address belongs to
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    // base58 is case-sensitive, so no lowercasing — just validate the alphabet
    if (not Base58.isValidBase58(addr)) { Runtime.trap("Invalid base58 address") };
    Map.add(watchedAddresses, Text.compare, addr, owner);
  };
  public shared (msg) func unregisterDepositAddress(addr : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedAddresses, Text.compare, addr);
  };
  public query func getDepositAddresses() : async [Text] {
    Iter.toArray(Map.keys(watchedAddresses));
  };

  public query func getConfirmedDeposits() : async [Types.Deposit] {
    depositsConfirmed;
  };

  // raw JSON-RPC via sol-rpc's jsonRequest (multi-provider consensus);
  // null on error
  func jsonRequest(payload : Text) : async ?Text {
    let rpc : SolRpcTypes.SolRpc = actor (Principal.toText(solRpc()));
    try {
      let r = await (with cycles = Constants.SOL_RPC_CYCLES) rpc.jsonRequest(Constants.SOL_CHAIN, null, payload);
      switch r {
        case (#Consistent x) { switch x { case (#Ok t) { ?t }; case (#Err _) { null } } };
        case (#Inconsistent _) { null };
      };
    } catch (_) { null };
  };

  // parse a JSON-RPC response envelope; returns the `result` Json, or null if
  // the envelope is malformed or carries a JSON-RPC error
  func resultOf(s : Text) : ?Json.Json {
    switch (Json.parse(s)) {
      case (#err _) { null };
      case (#ok j) {
        // JSON-RPC error object → treat as failure
        switch (Json.getAsObject(j, "error")) {
          case (#ok _) { null };
          case (#err _) {
            switch (Json.get(j, "result")) {
              case (?r) { ?r };
              case null { null };
            };
          };
        };
      };
    };
  };

  // base10 text -> Nat (jsonParsed returns amounts as base10 strings)
  func decToNat(s : Text) : Nat {
    var acc : Nat = 0;
    for (c in s.chars()) {
      let d = switch (c) {
        case ('0') { 0 }; case ('1') { 1 }; case ('2') { 2 }; case ('3') { 3 };
        case ('4') { 4 }; case ('5') { 5 }; case ('6') { 6 }; case ('7') { 7 };
        case ('8') { 8 }; case ('9') { 9 };
        case (_) { 0 }; // ignore stray chars
      };
      acc := acc * 10 + d;
    };
    acc;
  };

  // latest finalized slot
  func latestSlot() : async Nat {
    let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\",\"params\":[{\"commitment\":\"finalized\"}]}";
    switch (await jsonRequest(payload)) {
      case null { 0 };
      case (?s) {
        switch (resultOf(s)) {
          case null { 0 };
          case (?r) {
            switch (Json.getAsNat(r, "")) {
              case (#ok n) { n };
              case (#err _) { 0 };
            };
          };
        };
      };
    };
  };

  // one finalized slot's transactions (jsonParsed); null on error
  func getBlock(h : Nat) : async ?[Json.Json] {
    let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBlock\",\"params\":["
      # Nat.toText(h)
      # ",{\"commitment\":\"finalized\",\"encoding\":\"jsonParsed\",\"transactionDetails\":\"jsonParsed\",\"maxSupportedTransactionVersion\":0,\"rewards\":false}]}";
    switch (await jsonRequest(payload)) {
      case null { null };
      case (?s) {
        switch (resultOf(s)) {
          case null { null };
          case (?r) {
            switch (Json.getAsArray(r, "transactions")) {
              case (#ok arr) { ?arr };
              case (#err _) { null };
            };
          };
        };
      };
    };
  };

  // scan one slot: fetch the block and record every inbound transfer to a
  // watched address. Returns false if the block fetch failed (so scanBlocks can
  // stop advancing and retry next cycle — the dedup layer guarantees idempotency).
  func scanBlockProd(h : Nat) : async Bool {
    switch (await getBlock(h)) {
      case null { false };
      case (?txs) {
        for (tx in txs.vals()) {
          // skip failed txs (meta.err is a non-null object); such txs make no
          // balance change, so crediting them would be wrong anyway
          switch (Json.getAsObject(tx, "meta.err")) {
            case (#err _) { for (t in extractTransfers(tx, h).vals()) { recordDeposit(transferToDeposit(t)) } };
            case (#ok _) { /* failed tx — skip */ };
          };
        };
        true;
      };
    };
  };

  // extract all inbound transfers to watched addresses from one parsed tx.
  // `slot` is supplied by the caller (the block we scanned, since getBlock's
  // per-tx objects don't carry the slot).
  func extractTransfers(tx : Json.Json, slot : Nat) : [Types.Transfer] {
    let out = List.empty<Types.Transfer>();
    let signature = switch (Json.getAsText(tx, "transaction.signatures[0]")) {
      case (#ok v) { v }; case (#err _) { "" };
    };
    if (signature == "") { return List.toArray(out) };

    // ── native SOL: walk instructions + inner instructions for system transfers
    let solHits = findSolTransfers(tx, signature, slot);
    for (t in solHits.vals()) { out.add(t) };

    // ── SPL tokens: walk postTokenBalances for watched-owner + watched-mint
    // increases (robust to inner instructions / ATA creation)
    let splHits = findSplTransfers(tx, signature, slot);
    for (t in splHits.vals()) { out.add(t) };

    List.toArray(out);
  };

  // system-program transfer instructions crediting a watched address
  func findSolTransfers(tx : Json.Json, signature : Text, slot : Nat) : [Types.Transfer] {
    let out = List.empty<Types.Transfer>();
    let instructions = allInstructions(tx);
    var idx = 0;
    for (ins in instructions.vals()) {
      let program = switch (Json.getAsText(ins, "program")) {
        case (#ok v) { v }; case (#err _) { "" };
      };
      let itype = switch (Json.getAsText(ins, "parsed.type")) {
        case (#ok v) { v }; case (#err _) { "" };
      };
      if (program == "system" and itype == "transfer") {
        let dest = switch (Json.getAsText(ins, "parsed.info.destination")) {
          case (#ok v) { v }; case (#err _) { "" };
        };
        let lamports = switch (Json.getAsText(ins, "parsed.info.lamports")) {
          case (#ok v) { v }; case (#err _) { "0" };
        };
        let amount = decToNat(lamports);
        if (amount > 0 and Map.get(watchedAddresses, Text.compare, dest) != null) {
          let from = switch (Json.getAsText(ins, "parsed.info.source")) {
            case (#ok v) { v }; case (#err _) { "" };
          };
          out.add({
            signature = signature;
            slot = slot;
            asset = Constants.ASSET;
            token = null;
            from = from;
            to = dest;
            amountRaw = amount;
            dedupKey = signature # "#sol#" # Nat.toText(idx);
          });
        };
      };
      idx += 1;
    };
    List.toArray(out);
  };

  // SPL token increases for a watched owner + watched mint, derived from
  // postTokenBalances (pre/post diff), independent of instruction layout
  func findSplTransfers(tx : Json.Json, signature : Text, slot : Nat) : [Types.Transfer] {
    let out = List.empty<Types.Transfer>();
    let pre = switch (Json.getAsArray(tx, "meta.preTokenBalances")) {
      case (#ok a) { a }; case (#err _) { [] };
    };
    let post = switch (Json.getAsArray(tx, "meta.postTokenBalances")) {
      case (#ok a) { a }; case (#err _) { [] };
    };
    if (post.size() == 0) { return [] };
    // index pre-balances by (accountIndex -> amount)
    let preMap = Map.empty<Nat, Nat>();
    for (b in pre.vals()) {
      let ai = switch (Json.getAsNat(b, "accountIndex")) { case (#ok n) { n }; case (#err _) { 0 } };
      let amt = switch (Json.getAsText(b, "uiTokenAmount.amount")) {
        case (#ok v) { v }; case (#err _) { "0" };
      };
      Map.add(preMap, Nat.compare, ai, decToNat(amt));
    };
    for (b in post.vals()) {
      let ai = switch (Json.getAsNat(b, "accountIndex")) { case (#ok n) { n }; case (#err _) { 0 } };
      let mint = switch (Json.getAsText(b, "mint")) { case (#ok v) { v }; case (#err _) { "" } };
      let owner = switch (Json.getAsText(b, "owner")) { case (#ok v) { v }; case (#err _) { "" } };
      let amt = switch (Json.getAsText(b, "uiTokenAmount.amount")) {
        case (#ok v) { v }; case (#err _) { "0" };
      };
      let postAmt = decToNat(amt);
      let preAmt = switch (Map.get(preMap, Nat.compare, ai)) { case (?n) { n }; case null { 0 } };
      let delta = if (postAmt > preAmt) { postAmt - preAmt } else { 0 };
      if (delta > 0 and Map.get(watchedTokens, Text.compare, mint) != null
          and Map.get(watchedAddresses, Text.compare, owner) != null) {
        out.add({
          signature = signature;
          slot = slot;
          asset = mint;
          token = ?mint;
          from = ""; // SPL source account is not surfaced by postTokenBalances
          to = owner;
          amountRaw = delta;
          dedupKey = signature # "#spl#" # Nat.toText(ai);
        });
      };
    };
    List.toArray(out);
  };

  // flatten top-level instructions + inner instructions into one array
  func allInstructions(tx : Json.Json) : [Json.Json] {
    let out = List.empty<Json.Json>();
    switch (Json.getAsArray(tx, "transaction.transaction.message.instructions")) {
      case (#ok arr) { for (i in arr.vals()) { out.add(i) } };
      case (#err _) {};
    };
    switch (Json.getAsArray(tx, "meta.innerInstructions")) {
      case (#ok groups) {
        for (g in groups.vals()) {
          switch (Json.getAsArray(g, "instructions")) {
            case (#ok arr) { for (i in arr.vals()) { out.add(i) } };
            case (#err _) {};
          };
        };
      };
      case (#err _) {};
    };
    List.toArray(out);
  };

  // upsert: insert when unseen; refresh the stored block height / slot when it
  // advances, so confirmation counting stays correct. `amount`/`to`/`asset`
  // never change for a fixed dedup key, only the height does.
  func recordDeposit(d : Types.Deposit) {
    if (d.amountRaw == 0) { return };
    switch (Map.get(deposits, Text.compare, d.dedupKey)) {
      case (null) {
        if (Map.get(confirmedKeys, Text.compare, d.dedupKey) == null) {
          Map.add(deposits, Text.compare, d.dedupKey, {
            signature = d.signature;
            slot = d.slot;
            asset = d.asset;
            token = d.token;
            from = d.from;
            to = d.to;
            amountRaw = d.amountRaw;
            blockHeight = d.slot;
            confirmations = 0;
            dedupKey = d.dedupKey;
          });
        };
      };
      case (?existing) {
        if (d.blockHeight > existing.blockHeight) {
          Map.add(deposits, Text.compare, d.dedupKey, { existing with blockHeight = d.blockHeight });
        };
      };
    };
  };

  func transferToDeposit(t : Types.Transfer) : Types.Deposit {
    {
      signature = t.signature;
      slot = t.slot;
      asset = t.asset;
      token = t.token;
      from = t.from;
      to = t.to;
      amountRaw = t.amountRaw;
      blockHeight = t.slot;
      confirmations = 0;
      dedupKey = t.dedupKey;
    };
  };

  func scanBlocks() : async () {
    if (Map.get(scanning, Text.compare, "scan") != null) { return };
    Map.add(scanning, Text.compare, "scan", true);

    let tip = await latestSlot();
    // first sweep: jump to a safe starting slot so we don't replay full history
    if (slotHeight == 0 and tip > 0) {
      slotHeight := if (tip > Constants.DELAY_SLOTS + Constants.MAX_SLOTS_PER_SCAN) {
        tip - Constants.DELAY_SLOTS - Constants.MAX_SLOTS_PER_SCAN;
      } else { 0 };
    };
    let safeTip = if (tip > Constants.DELAY_SLOTS) { tip - Constants.DELAY_SLOTS } else { 0 };
    let batchEnd = Nat.min(safeTip, slotHeight + Constants.MAX_SLOTS_PER_SCAN);

    label scan loop {
      if (slotHeight > batchEnd) { break scan };
      // a failed block fetch leaves slotHeight where it is; the next cycle retries
      // from the same slot, and the dedup layer makes replay idempotent
      if (not (await scanBlockProd(slotHeight))) { break scan };
      slotHeight += 1;
    };

    confirmDeposits(tip);

    ignore Map.delete(scanning, Text.compare, "scan");
  };

  // move deposits that reached CONFIRMED_SLOTS into depositsConfirmed; refresh
  // confirmations for the rest
  func confirmDeposits(tip : Nat) {
    let moved = List.empty<Types.Deposit>();
    let movedKeys = List.empty<Text>();
    let toRefresh = List.empty<(Text, Types.Deposit)>();
    for ((dk, d) in Map.entries(deposits)) {
      let confirmations = if (tip > d.blockHeight) { tip - d.blockHeight + 1 } else { 0 };
      if (confirmations >= Constants.CONFIRMED_SLOTS) {
        moved.add({ d with confirmations = confirmations });
        movedKeys.add(dk);
      } else if (confirmations != d.confirmations) {
        toRefresh.add((dk, { d with confirmations = confirmations }));
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
      Map.add(confirmedKeys, Text.compare, d.dedupKey, ());
    };
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
