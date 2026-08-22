// ICP deposit detector (lazy-scan model, ICP only, ICRC-3 block log).
//
// Unlike the ETH/BTC/SOL/NEAR detectors this canister does NOT run a background
// timer. When a user opens the deposit page the caller invokes
// scanUserDeposits(subaccount) which walks back 24h of ICP ledger blocks via
// icrc3_get_blocks (paginated), keeps the transfers whose `to` account equals
// (backendOwner, subaccount), and archives them in `depositsConfirmed`. The
// caller then reads that archive to show the user's running deposit balance —
// net of swept funds, so it differs from the on-chain raw balance.
//
// Dedup key: block id (globally unique per ledger), so re-scanning is a no-op.

import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Iter "mo:core/Iter";
import Buffer "mo:core/Buffer";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Time "mo:core/Time";
import Types "Types";
import Constants "Constants";

persistent actor IcpDepositDetector {

  // The DEX backend's principal. Inbound transfers to (this, userSubaccount)
  // are treated as that user's deposit. Set by the controller after deploy.
  var owner : ?Principal = null;

  // Archived deposits, keyed by Nat.toText(blockId). Stable Map persists across upgrades.
  stable var depositsConfirmed : Map.Map<Text, Types.Deposit> = Map.empty(Text.compare);

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  // ── admin wiring ──────────────────────────────────────────────────────
  public shared (msg) func setOwner(p : Principal) : async () {
    requireController(msg.caller);
    owner := ?p;
  };
  public query func getOwner() : async ?Principal { owner };

  // Only expose one user's deposits, never the whole archive.
  public query func getConfirmedDeposits(sub : Blob) : async [Types.Deposit] {
    let out = Buffer.Buffer<Types.Deposit>(0);
    for ((_, d) in Map.entries(depositsConfirmed).vals()) {
      if (Blob.equal(d.toSub, sub)) { out.add(d) };
    };
    Buffer.toArray(out);
  };

  // ── ICP ledger icrc3_get_blocks binding (ICRC-3 block log) ────────────
  // ICRC-3 Value: Map is a vec of (text, Value) tuples, not a record of tagged fields.
  type ICRC3Value = {
    #Blob : Blob;
    #Text : Text;
    #Nat : Nat;
    #Int : Int;
    #Array : [ICRC3Value];
    #Map : [(Text, ICRC3Value)];
  };
  type BlockEntry = { id : Nat; block : ICRC3Value };
  type GetBlocksResult = {
    log_length : Nat;
    blocks : [BlockEntry];
  };
  type Ledger = actor {
    icrc3_get_blocks : ([{ start : Nat; length : Nat }]) -> async GetBlocksResult;
  };

  // ── ICRC-3 Value parsing helpers ──────────────────────────────────────
  func asMap(v : ICRC3Value) : ?[(Text, ICRC3Value)] {
    switch v { case (#Map m) { ?m }; case (_) { null } };
  };
  func field(m : [(Text, ICRC3Value)], k : Text) : ?ICRC3Value {
    for ((key, val) in m.vals()) {
      if (key == k) { return ?val };
    };
    null;
  };
  func asNat(v : ?ICRC3Value) : Nat {
    switch v { case (?#Nat n) { n }; case (_) { 0 } };
  };
  func asBlob(v : ?ICRC3Value) : ?Blob {
    switch v { case (?#Blob b) { ?b }; case (_) { null } };
  };
  // ICRC-3 account = Array [Blob(owner), Blob?(subaccount?)]. Subaccount is
  // omitted when null, so a single-element array is the default account.
  func parseAccount(v : ICRC3Value) : ?{ owner : Principal; subaccount : ?Blob } {
    switch v {
      case (#Array a) {
        switch (a[0]) {
          case (?#Blob ownerBlob) {
            let sub = if (a.size() > 1) { asBlob(a[1]) } else { null };
            ?{ owner = Principal.fromBlob(ownerBlob); subaccount = sub };
          };
          case (_) { null };
        };
      };
      case (_) { null };
    };
  };
  // block timestamp (ns) as Int, for the 24h window comparison.
  // A missing/invalid ts yields null (not 0) so the caller can distinguish
  // "no timestamp" from "a real timestamp", avoiding a spurious early stop.
  func blockTs(blk : ICRC3Value) : ?Int {
    switch (asMap(blk)) {
      case null { null };
      case (?m) { switch (field(m, "ts")) { case (?#Nat n) { ?(n : Int) }; case (_) { null } } };
    };
  };

  // Extract a Deposit from one block entry if it is a transfer to (owner, sub).
  func extractDeposit(blockId : Nat, blk : ICRC3Value) : ?Types.Deposit {
    let m = switch (asMap(blk)) { case (?x) { x }; case null { return null } };
    let txm = switch (field(m, "tx")) {
      case null { return null };
      case (?t) { switch (asMap(t)) { case (?x) { x }; case null { return null } } };
    };
    // only transfers count (btype "1xfer"/"2xfer" or op "xfer")
    let isXfer = switch (field(m, "btype")) {
      case (?#Text t) { t == "1xfer" or t == "2xfer" };
      case (_) { switch (field(txm, "op")) { case (?#Text o) { o == "xfer" }; case (_) { false } } };
    };
    if (not isXfer) { return null };
    let toAcct = switch (field(txm, "to")) {
      case null { return null };
      case (?t) { switch (parseAccount(t)) { case (?x) { x }; case null { return null } } };
    };
    switch owner {
      case null { return null };
      case (?ow) {
        if (not Principal.equal(toAcct.owner, ow)) { return null };
        switch (toAcct.subaccount) {
          case null { return null };
          case (?sub) {
            let amount = asNat(field(txm, "amt"));
            if (amount == 0) { return null };
            // fee lives at block top level, falling back to tx.fee
            let fee = if (asNat(field(m, "fee")) > 0) { asNat(field(m, "fee")) } else { asNat(field(txm, "fee")) };
            let fromAcct = switch (field(txm, "from")) {
              case null { null };
              case (?f) { parseAccount(f) };
            };
            ?{
              blockIndex = blockId;
              from = switch fromAcct { case (?f) { f.owner }; case null { Principal.anonymous() } };
              fromSub = switch fromAcct { case (?f) { f.subaccount }; case null { null } };
              toSub = sub;
              amount = amount;
              fee = fee;
              timestamp = Nat64.fromNat(asNat(field(m, "ts")));
            };
          };
        };
      };
    };
  };

  func recordDeposit(d : Types.Deposit) {
    let dk = Nat.toText(d.blockIndex);
    if (Map.get(depositsConfirmed, Text.compare, dk) == null) {
      Map.add(depositsConfirmed, Text.compare, dk, d);
    };
  };

  // Walk back up to 24h of blocks, paginated, keeping only entries newer than
  // the window. Stops early once a page's oldest block predates the window.
  func fetchRecentBlocks() : async [BlockEntry] {
    let l : Ledger = actor (Principal.toText(Constants.icpLedgerMainnet()));
    let tip = try {
      let r = await l.icrc3_get_blocks([{ start = 0; length = 1 }]);
      r.log_length;
    } catch (_) { 0 : Nat };
    if (tip <= 1) { return [] };
    let windowStart = Time.now() - Constants.SCAN_WINDOW_NS;
    let out = Buffer.Buffer<BlockEntry>(0);
    var cursor = tip;
    var scanned = 0;
    var stop = false;
    while (not stop and cursor > 0 and scanned < Constants.MAX_SCAN_BLOCKS) {
      let length = if (cursor > Constants.PAGE_SIZE) { Constants.PAGE_SIZE } else { cursor };
      let start = cursor - length;
      let r = try {
        await l.icrc3_get_blocks([{ start; length }]);
      } catch (_) { { log_length = tip; blocks = [] } };
      if (r.blocks.size() == 0) { stop := true }
      else {
        for (b in r.blocks.vals()) {
          switch (blockTs(b.block)) {
            case (?(ts)) { if (ts >= windowStart) { out.add(b) } };
            // no timestamp → keep it (can't time-filter; it's still a candidate)
            case null { out.add(b) };
          };
        };
        // oldest block of the page already predates the window → older pages are all
        // stale. A block with no timestamp never triggers this (blockTs = null).
        switch (r.blocks[0]) {
          case null {};
          case (?b0) {
            switch (blockTs(b0.block)) {
              case (?(ts)) { if (ts < windowStart) { stop := true } };
              case null {};
            };
          };
        };
      };
      scanned += length;
      cursor := start;
    };
    Buffer.toArray(out);
  };

  // ── public scan entrypoint (called on user refresh) ───────────────────
  public shared (msg) func scanUserDeposits(userSub : Blob) : async [Types.Deposit] {
    let blocks = await fetchRecentBlocks();
    for (b in blocks.vals()) {
      switch (extractDeposit(b.id, b.block)) {
        case (?d) { if (Blob.equal(d.toSub, userSub)) { recordDeposit(d) } };
        case null {};
      };
    };
    await getConfirmedDeposits(userSub);
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
