// Bitcoin (BTC) deposit detector: walk finalized blocks via the dfinity
// bitcoin canister, decode each raw block, and record every output that pays a
// watched deposit address. Detected deposits live in `deposits` until they
// reach CONFIRMED_CONFIRMATIONS, then get archived into `depositsConfirmed`.
// No crediting — the DEX reads the archive.
//
// Model mirrors the ETH/SOL detectors' monitor→detect→confirm→archive flow, but
// adapted to Bitcoin's UTXO model: instead of a per-address UTXO poll we scan
// the chain block-by-block (get_block_headers → get_block → decode), turning
// each output's scriptPubKey back into an address and matching it against the
// addresses registered at registerDepositAddress.

import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Cycles "mo:core/Cycles";
import Timer "mo:core/Timer";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
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

  // key = deposit (base58 / bech32) address; value = owning principal.
  // Block scanning converts each output's scriptPubKey back into its canonical
  // address (BtcAddr.scriptToAddress) and looks it up here.
  let watchedAddresses = Map.empty<Text, Principal>();

  // bech32 human-readable prefix for script→address encoding; must match the
  // network we scan (Constants.BTC_NETWORK)
  let bech32Hrp : Text = switch (Constants.BTC_NETWORK) {
    case (#mainnet) { "bc" };
    case (#testnet) { "tb" };
    case (#regtest) { "bcrt" };
  };

  // latest known chain tip (block height) learned from get_current_block_height
  var btcTip : Nat = 0;
  // last fully-read block height; advanced every scan
  var blockHeight : Nat = 0;

  // pending deposits, deduped by dedupKey (blockHash#txIndex#vout)
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of deposits that reached CONFIRMED_CONFIRMATIONS.
  // Keyed by dedupKey (blockHash#txIndex#vout); the presence of a key also
  // marks the output as "already archived", so recordDeposit can skip a
  // re-scanned output without a second map.
  // TODO: unbounded growth — at millions of users this map grows forever and
  // inflates canister memory; needs bucketing / backend-consumption-then-prune.
  let depositsConfirmed = Map.empty<Text, Types.Deposit>();

  let scanning = Map.empty<Text, Bool>();

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  public query func getDeployMode() : async Text { "production" };
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // register a user's BTC deposit address (controller-only). The address is
  // decoded to its scriptPubKey purely for validation (checksum + supported
  // type — a typo'd address is rejected on the spot); the address itself is
  // the match key: block scanning converts each output's scriptPubKey back
  // into an address and looks it up in watchedAddresses with EXACT string
  // equality (no prefix / contains / fuzzy matching). `owner` is the
  // principal the address belongs to.
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    if (not isValidBtcAddress(addr)) { Runtime.trap("Invalid Bitcoin address") };
    // exact-match guarantee: the registered string must equal what the scan
    // side re-encodes. A bech32 address whose HRP doesn't match the network
    // we scan (e.g. tb1… on mainnet) would re-encode with a different prefix
    // and silently never match — reject it loudly here. (Testnet base58 is
    // already rejected inside BtcAddr: only the mainnet P2PKH version 0x00 is
    // accepted; 0x05 (P2SH) is dropped there.)
    let isBech = Text.startsWith(addr, #text("bc1")) or Text.startsWith(addr, #text("tb1")) or Text.startsWith(addr, #text("bcrt1"));
    if (isBech and not Text.startsWith(addr, #text(bech32Hrp # "1"))) {
      Runtime.trap("Address network mismatch: expected " # bech32Hrp # "1…");
    };
    // BIP173 canonical form is lowercase. A mixed/uppercase bech32 passes
    // checksum validation (bech32 decodes case-insensitively) but the scan
    // side always re-encodes to lowercase, so it would silently never match a
    // registered key. Reject it so the stored key is always canonical — this
    // is what README §2.3 promises ("大写 bech32 会在注册校验时被拒").
    if (isBech) {
      for (c in addr.chars()) {
        let code = Char.toNat32(c);
        if (code >= 65 and code <= 90) { Runtime.trap("Bech32 address must be lowercase") };
      };
    };
    switch (BtcAddr.addressToScript(addr)) {
      case null { Runtime.trap("Unsupported or malformed Bitcoin address") };
      case (?_) { Map.add(watchedAddresses, Text.compare, addr, owner) };
    };
  };
  public shared (msg) func unregisterDepositAddress(addr : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedAddresses, Text.compare, addr);
  };
  public query func getDepositAddresses() : async [Text] {
    Iter.toArray(Map.keys(watchedAddresses));
  };

  public query func getConfirmedDeposits() : async [Types.Deposit] {
    Iter.toArray(Map.values(depositsConfirmed));
  };

  // ── address validation ─────────────────────────────────────
  // Bitcoin base58 alphabet (= the Solana alphabet). Legacy P2PKH (1…)
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
  func fetchRawBlock(hash : Blob) : async ?Blob {
    try {
      let r = await (with cycles = Constants.BTC_RPC_CYCLES) btc().get_block({
        network = Constants.BTC_NETWORK;
        block_hash = hash;
      });
      ?r.block;
    } catch (_) { null };
  };

  // Fetch + decode a block at height h into its outputs — the BTC analogue of
  // eth-deposit-detector's `getBlock(h)`, which returns the block's tx hashes.
  // One call site (scanBlockProd) pulls the block; we then iterate its outputs
  // locally (no per-output RPC, unlike ETH's per-tx getTransactionByHash) and
  // convert each output's scriptPubKey back into an address for matching.
  // Returns the block hash too, so callers can build a block-unique dedup key
  // (txIndex+vout alone are only unique within a block). null on any
  // fetch/decode failure.
  func getBlock(h : Nat) : async ?(Blob, [Block.Output]) {
    switch (await getBlockHashAt(Nat32.fromNat(h))) {
      case null { null };
      case (?hash) {
        switch (await fetchRawBlock(hash)) {
          case null { null };
          case (?raw) {
            switch (Block.decodeBlock(raw)) {
              case null { null };
              case (?outs) { ?(hash, outs) };
            };
          };
        };
      };
    };
  };

  // scan one block: pull it via getBlock(h), then record every output paying a
  // watched address. Mirrors eth-deposit-detector's scanBlockProd (getBlock →
  // iterate → match watchedAddresses); each output's scriptPubKey is converted
  // back into its canonical address (BtcAddr.scriptToAddress) and looked up in
  // watchedAddresses, and each output's block-unique dedup key needs the block
  // hash. Returns false if the fetch failed (so scanBlocks stops advancing and
  // retries next cycle — dedup guarantees idempotency).
  func scanBlockProd(h : Nat) : async Bool {
    switch (await getBlock(h)) {
      case null { false };
      case (? (hash, outs)) {
        let blockHex = blobToHex(hash);
        for (o in outs.vals()) {
          // scriptPubKey → address, then compare against watchedAddresses
          switch (BtcAddr.scriptToAddress(Blob.toArray(o.script), bech32Hrp)) {
            case (?addr) {
              if (o.value > 0 and Map.get(watchedAddresses, Text.compare, addr) != null) {
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

  // upsert: insert when unseen; refresh the stored block height when it advances
  // (a reorg could surface a different block at the same height — height only
  // moves forward here). `amount`/`to`/`asset` never change for a fixed key.
  func recordDeposit(d : Types.Deposit) {
    if (d.amountRaw == 0) { return };
    switch (Map.get(deposits, Text.compare, d.dedupKey)) {
      case (null) {
        if (Map.get(depositsConfirmed, Text.compare, d.dedupKey) == null) {
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

  // one scan cycle; caller (scanBlocks) holds the "scan" flag
  func scanCycle() : async () {
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
    // caught up (no new stable blocks this cycle) — nothing to scan
    if (batchEnd <= blockHeight) {
      confirmDeposits(btcTip);
      return;
    };

    // scan only the *unscanned* blocks (h = blockHeight+1 … batchEnd), matching
    // eth-deposit-detector's scanBlocks; a failed block fetch leaves blockHeight
    // where it is so the next cycle retries it (dedup makes replay idempotent).
    var hh = blockHeight + 1;
    while (hh <= batchEnd) {
      if (not (await scanBlockProd(hh))) {
        confirmDeposits(btcTip);
        return;
      };
      hh += 1;
    };
    blockHeight := batchEnd;

    confirmDeposits(btcTip);
  };

  func scanBlocks() : async () {
    if (Map.get(scanning, Text.compare, "scan") != null) { return };
    Map.add(scanning, Text.compare, "scan", true);
    // ALWAYS release the flag, even on trap: a malformed block can make
    // Block.decodeBlock trap on an out-of-bounds read, which rejects this
    // call mid-flight — leaving "scan" set would deadlock every later tick
    // (each returns at the guard) and silently stop detection until the next
    // canister upgrade. Trapped cycles simply retry from the same height.
    try { await scanCycle(); } catch (_) {};
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
    };
    for ((dk, d) in List.toArray(toRefresh).vals()) {
      Map.add(deposits, Text.compare, dk, d);
    };
    // archive the moved deposits into the Map (keyed by dedupKey; the key
    // presence also dedups re-scanned outputs, replacing the old confirmedKeys)
    for (d in List.toArray(moved).vals()) {
      Map.add(depositsConfirmed, Text.compare, d.dedupKey, d);
    };
  };

  public shared func scanAll() : async () {
    await scanBlocks();
  };

  let _scanTimer = Timer.recurringTimer(#seconds(Constants.SCAN_INTERVAL_SEC), scanBlocks);

  system func postupgrade() {
    Map.clear(scanning);
    // depositsConfirmed is the single source of truth for archived deposits
    // (and their dedup keys); it persists across upgrades, so no backfill is
    // needed here.
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
