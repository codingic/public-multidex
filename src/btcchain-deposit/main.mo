// Bitcoin (BTC) deposit detector: poll each watched deposit address via the
// dfinity bitcoin canister, resolve inbound UTXOs, store them in `deposits`,
// and archive confirmed ones into `depositsConfirmed`. No crediting — the DEX
// reads the archive.
//
// Model mirrors the ETH/SOL detectors' monitor→detect→confirm→archive flow, but
// adapted to Bitcoin's UTXO model: there is no global Transfer log and no
// per-transaction account abstraction, so we index per watched address with
// get_utxos and treat each new (txid, vout) as a potential inbound deposit.

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
import Types "Types";
import BtcRpcTypes "BtcRpcTypes";
import Constants "Constants";

persistent actor BtcDepositDetector {

  func btcCanister() : Principal {
    switch (_btcCache) { case (?p) { p }; case null { Constants.btcCanisterMainnet() } };
  };
  transient var _btcCache : ?Principal = Constants.btcCanisterEnv<system>();

  // key = deposit (base58 / bech32) address; value = owning principal
  let watchedAddresses = Map.empty<Text, Principal>();

  // latest known chain tip (block height) learned from get_utxos responses
  var btcTip : Nat = 0;

  // pending deposits, deduped by dedupKey (outpoint = txid#vout)
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of deposits that reached CONFIRMED_CONFIRMATIONS
  // TODO: unbounded growth — at millions of users this array grows forever and
  // inflates canister memory; needs bucketing / backend-consumption-then-prune.
  var depositsConfirmed : [Types.Deposit] = [];
  // keys already archived, so a re-scanned UTXO isn't archived twice
  let confirmedKeys = Map.empty<Text, ()>();

  let scanning = Map.empty<Text, Bool>();

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  public query func getDeployMode() : async Text { "production" };
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // register a user's BTC deposit address (controller-only) so its inbound
  // UTXOs are detected; `owner` is the principal the address belongs to
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    if (not isValidBtcAddress(addr)) { Runtime.trap("Invalid Bitcoin address") };
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

  // ── address validation ─────────────────────────────────────
  // Bitcoin base58 alphabet (= the Solana alphabet). Legacy (1…) and P2SH (3…)
  // addresses are base58; native segwit (bc1…) / testnet (tb1…) / regtest
  // (bcrt1…) are bech32. We don't verify the checksum here — get_utxos will
  // reject malformed addresses on-chain.
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

  // blob (txid) → lowercase hex Text, for forming a stable outpoint key
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

  // one address sweep: list its UTXOs and record any not-yet-seen inbound BTC.
  // Returns false if the RPC failed (so the caller can mark the sweep as failed).
  func scanAddress(addr : Text) : async Bool {
    let req : BtcRpcTypes.GetUtxosRequest = {
      address = addr;
      network = Constants.BTC_NETWORK;
      filter = ?(#max_number_of_utxos(Constants.UTXO_LIMIT));
    };
    let btc : BtcRpcTypes.BitcoinApi = actor (Principal.toText(btcCanister()));
    try {
      let resp = await btc.get_utxos(req);
      btcTip := Nat32.toNat(resp.tip_height);
      for (u in resp.utxos.vals()) {
        let outpoint = blobToHex(u.outpoint.txid) # "#" # Nat32.toText(u.outpoint.vout);
        let amount = Nat64.toNat(u.value);
        if (amount > 0) {
          recordDeposit({
            signature = outpoint;
            slot = Nat32.toNat(u.height);
            asset = Constants.ASSET;
            token = null;
            from = ""; // UTXO has no explicit sender in get_utxos
            to = addr;
            amountRaw = amount;
            blockHeight = Nat32.toNat(u.height);
            confirmations = 0;
            dedupKey = outpoint;
          });
        };
      };
      true;
    } catch (_) { false };
  };

  // upsert: insert when unseen; refresh the stored block height when a UTXO
  // transitions from mempool (height 0) to a mined block (height > 0), so the
  // confirmation count in confirmDeposits can accrue. `amount`/`to`/`asset`
  // never change for a fixed outpoint, only the height does.
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
        // a UTXO's height transitions 0 (mempool) → real block height once mined
        if (d.blockHeight > existing.blockHeight) {
          Map.add(deposits, Text.compare, d.dedupKey, { existing with blockHeight = d.blockHeight });
        };
      };
    };
  };

  func scanBlocks() : async () {
    if (Map.get(scanning, Text.compare, "scan") != null) { return };
    Map.add(scanning, Text.compare, "scan", true);

    // sweep every watched address; each sweep refreshes btcTip from its response
    for (addr in Map.keys(watchedAddresses)) {
      ignore await scanAddress(addr);
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
      // height 0 == unconfirmed (mempool); a mined UTXO has tip − height + 1
      // height 0 == unconfirmed (mempool); a mined UTXO has tip − height + 1
      let confirmations = if (d.blockHeight == 0) {
        0;
      } else if (tip >= d.blockHeight) {
        tip - d.blockHeight + 1;
      } else { 0 };
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
    // re-scanned UTXO isn't archived twice right after an upgrade
    for (d in depositsConfirmed.vals()) {
      Map.add(confirmedKeys, Text.compare, d.dedupKey, ());
    };
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
