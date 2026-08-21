// Bitcoin (BTC) deposit detector: walk finalized blocks via the dfinity
// bitcoin canister, decode each raw block, and record every output that pays a
// watched deposit address. Detected deposits live in `deposits` until they
// reach CONFIRMED_CONFIRMATIONS, then get archived into `depositsConfirmed`.
// No crediting — the DEX reads the archive.
//
// Model mirrors the ETH/SOL detectors' monitor→detect→confirm→archive flow, but
// adapted to Bitcoin's UTXO model: instead of a per-address UTXO poll we scan
// the chain block-by-block (get_block_headers → get_block → decode), matching
// each output's scriptPubKey against the set registered at registerDepositAddress.

import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Cycles "mo:core/Cycles";
import Timer "mo:core/Timer";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Char "mo:core/Char";
import Blob "mo:core/Blob";
import Types "Types";
import BtcRpcTypes "BtcRpcTypes";
import Constants "Constants";
import BtcAddr "BtcAddr";
import Block "Block";

persistent actor BtcDepositDetector {

  func btcCanister() : Principal {
    switch (_btcCache) { case (?p) { p }; case null { Constants.btcCanisterMainnet() } };
  };
  transient var _btcCache : ?Principal = Constants.btcCanisterEnv<system>();

  // key = deposit (base58 / bech32) address; value = owning principal
  let watchedAddresses = Map.empty<Text, Principal>();
  // key = hex(scriptPubKey) of a watched address; value = that address.
  // Built at registration from the address; matched against raw output scripts
  // during block scanning. Lets the hot path avoid parsing scripts.
  let watchedScripts = Map.empty<Text, Text>();

  // latest known chain tip (block height) learned from get_current_block_height
  var btcTip : Nat = 0;
  // last fully-read block height; advanced every scan
  var blockHeight : Nat = 0;

  // pending deposits, deduped by dedupKey (blockHash#txIndex#vout)
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of deposits that reached CONFIRMED_CONFIRMATIONS
  // TODO: unbounded growth — at millions of users this array grows forever and
  // inflates canister memory; needs bucketing / backend-consumption-then-prune.
  var depositsConfirmed : [Types.Deposit] = [];
  // keys already archived, so a re-scanned output isn't archived twice
  let confirmedKeys = Map.empty<Text, ()>();

  let scanning = Map.empty<Text, Bool>();

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  public query func getDeployMode() : async Text { "production" };
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // register a user's BTC deposit address (controller-only). We decode it to its
  // scriptPubKey and store the script as the match key, so block scanning can
  // find inbound outputs without re-parsing the address. `owner` is the
  // principal the address belongs to.
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    if (not isValidBtcAddress(addr)) { Runtime.trap("Invalid Bitcoin address") };
    switch (BtcAddr.addressToScript(addr)) {
      case null { Runtime.trap("Unsupported or malformed Bitcoin address") };
      case (?script) {
        Map.add(watchedAddresses, Text.compare, addr, owner);
        Map.add(watchedScripts, Text.compare, blobToHex(Blob.fromArray(script)), addr);
      };
    };
  };
  public shared (msg) func unregisterDepositAddress(addr : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedAddresses, Text.compare, addr);
    switch (BtcAddr.addressToScript(addr)) {
      case (?script) { ignore Map.delete(watchedScripts, Text.compare, blobToHex(Blob.fromArray(script))) };
      case null {};
    };
  };
  public query func getDepositAddresses() : async [Text] {
    Iter.toArray(Map.keys(watchedAddresses));
  };

  public query func getConfirmedDeposits() : async [Types.Deposit] {
    depositsConfirmed;
  };

  // ── address validation ─────────────────────────────────────
  // Bitcoin base58 alphabet (= the Solana alphabet). Legacy (1…) and P2SH (3…)
  // addresses are base58; native segwit (bc1…) / testnet (tb1…) / regtest
  // (bcrt1…) are bech32. We don't verify the checksum here (BtcAddr does that
  // at registration) — this only gates the alphabet / prefix.
  func isBase58Char(c : Char) : Bool {
    for (a in "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".chars()) {
      if (a == c) { return true };
    };
    false;
  };
  func isValidBtcAddress(addr : Text) : Bool {
    if (addr.size() < 1) { return false };
    let isBech = Text.startsWith(addr, #text("bc1")) or Text.startsWith(addr, #text("tb1")) or Text.startsWith(addr, #text("bcrt1"));
    if (isBech) { return true };
    for (c in addr.chars()) { if (not isBase58Char(c)) { return false } };
    true;
  };

  // blob → lowercase hex Text, for stable keys (outpoint, script, block hash)
  func nibbleToHex(n : Nat8) : Char {
    if (n < 10) { Char.fromNat32(Nat32.fromNat(Nat8.toNat(n)) + 48) }
    else { Char.fromNat32(Nat32.fromNat(Nat8.toNat(n)) + 87) };
  };
  func blobToHex(b : Blob) : Text {
    var acc = "";
    for (byte in b.vals()) {
      acc := acc # Text.fromChar(nibbleToHex(byte / 16)) # Text.fromChar(nibbleToHex(byte % 16));
    };
    acc;
  };

  // ── bitcoin canister calls ─────────────────────────────────
  func btc() : BtcRpcTypes.BitcoinApi { actor (Principal.toText(btcCanister())) };

  // current chain height
  func getCurrentHeight() : async Nat {
    try {
      let r = await (with cycles = Constants.BTC_RPC_CYCLES) btc().get_current_block_height({ network = Constants.BTC_NETWORK });
      Nat32.toNat(r.height);
    } catch (_) { 0 };
  };

  // block hash at a given height (via a 1-height header window)
  func getBlockHashAt(h : Nat32) : async ?Blob {
    try {
      let r = await (with cycles = Constants.BTC_RPC_CYCLES) btc().get_block_headers({
        network = Constants.BTC_NETWORK;
        start_height = h;
        end_height = ?h;
      });
      if (r.headers.size() == 0) { return null };
      ?r.headers[0].block_hash;
    } catch (_) { null };
  };

  // raw block bytes for a hash
  func getBlock(hash : Blob) : async ?Blob {
    try {
      let r = await (with cycles = Constants.BTC_RPC_CYCLES) btc().get_block({
        network = Constants.BTC_NETWORK;
        block_hash = hash;
      });
      ?r.block;
    } catch (_) { null };
  };

  // scan one block: fetch it, decode it, record every output paying a watched
  // script. Returns false if any fetch failed (so scanBlocks stops advancing
  // and retries next cycle — the dedup layer guarantees idempotency).
  func scanBlockProd(h : Nat) : async Bool {
    switch (await getBlockHashAt(Nat32.fromNat(h))) {
      case null { false };
      case (?hash) {
        switch (await getBlock(hash)) {
          case null { false };
          case (?raw) {
            switch (Block.decodeBlock(raw)) {
              case null { false };
              case (?outs) {
                let blockHex = blobToHex(hash);
                for (o in outs.vals()) {
                  let scriptHex = blobToHex(o.script);
                  switch (Map.get(watchedScripts, Text.compare, scriptHex)) {
                    case (?addr) {
                      if (o.value > 0) {
                        let outpoint = blockHex # "#" # Nat.toText(o.txIndex) # "#" # Nat.toText(o.vout);
                        recordDeposit({
                          signature = outpoint;
                          slot = h;
                          asset = Constants.ASSET;
                          token = null;
                          from = ""; // BTC outputs have no explicit sender in raw blocks
                          to = addr;
                          amountRaw = Nat64.toNat(o.value);
                          blockHeight = h;
                          confirmations = 0;
                          dedupKey = outpoint;
                        });
                      };
                    };
                    case null {};
                  };
                };
                true;
              };
            };
          };
        };
      };
    };
  };

  // upsert: insert when unseen; refresh the stored block height when it advances
  // (a reorg could surface a different block at the same height — height only
  // moves forward here). `amount`/`to`/`asset` never change for a fixed key.
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
            blockHeight = d.blockHeight;
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

  func scanBlocks() : async () {
    if (Map.get(scanning, Text.compare, "scan") != null) { return };
    Map.add(scanning, Text.compare, "scan", true);

    let tip = await getCurrentHeight();
    btcTip := tip;

    // first sweep: jump to a safe starting height so we don't replay full history
    if (blockHeight == 0 and tip > 0) {
      blockHeight := if (tip > Constants.DELAY_BLOCKS + Constants.MAX_BLOCKS_PER_SCAN) {
        tip - Constants.DELAY_BLOCKS - Constants.MAX_BLOCKS_PER_SCAN;
      } else { 0 };
    };
    let safeTip = if (tip > Constants.DELAY_BLOCKS) { tip - Constants.DELAY_BLOCKS } else { 0 };
    let batchEnd = Nat.min(safeTip, blockHeight + Constants.MAX_BLOCKS_PER_SCAN);

    label scan loop {
      if (blockHeight > batchEnd) { break scan };
      // a failed block fetch leaves blockHeight where it is; the next cycle
      // retries from the same block, and the dedup layer makes replay idempotent
      if (not (await scanBlockProd(blockHeight))) { break scan };
      blockHeight += 1;
    };

    confirmDeposits(btcTip);

    ignore Map.delete(scanning, Text.compare, "scan");
  };

  // move deposits that reached CONFIRMED_CONFIRMATIONS into depositsConfirmed;
  // refresh confirmations for the rest
  func confirmDeposits(tip : Nat) {
    let moved = List.empty<Types.Deposit>();
    let movedKeys = List.empty<Text>();
    let toRefresh = List.empty<(Text, Types.Deposit)>();
    for ((dk, d) in Map.entries(deposits)) {
      // a mined output at height h has tip − h + 1 confirmations
      let confirmations = if (tip >= d.blockHeight) { tip - d.blockHeight + 1 } else { 0 };
      if (confirmations >= Constants.CONFIRMED_CONFIRMATIONS) {
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
    // re-scanned output isn't archived twice right after an upgrade
    for (d in depositsConfirmed.vals()) {
      Map.add(confirmedKeys, Text.compare, d.dedupKey, ());
    };
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
