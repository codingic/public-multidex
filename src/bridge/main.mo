// Bridge canister — DUMMY / STUB.
//
// This is a DEV STUB so the frontend Deposit page and the DEX↔Bridge integration
// contract can be built and demoed end-to-end. The REAL custody logic — threshold-
// derived per-user addresses, the Chain-Key System, confirmation tracking, sweeps,
// withdrawals — is NOT implemented here; that is a separate team's job, on a
// separate branch. See docs/bridge-and-cks-design.md for the full design.
//
// What IS real here:
//   • the public interface the frontend talks to (createDepositAddress /
//     getMyDeposits / claim),
//   • the DEX integration: claim → DEX.creditAndRegister (an INTER-CANISTER call,
//     which bypasses the DEX's caller-only `inspect`, so the user is registered
//     off-ingress — exactly as the inspect gate assumes),
//   • the two-ledger accounting shape (credit axis: cumulative confirmed inflow vs
//     claimed; the location axis is out of scope for the stub).
//
// What is FAKE here:
//   • addresses are deterministic faux strings, not real chain addresses,
//   • dev-only devSimulateDeposit / devConfirmDeposits stand in for real external-
//     chain deposits + confirmations. The real Bridge has no such methods.

import Map "mo:core/Map";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Runtime "mo:core/Runtime";
import Error "mo:core/Error";
import Cycles "mo:core/Cycles";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Char "mo:core/Char";
import Blob "mo:core/Blob";

persistent actor Bridge {

  // Depositable assets = the DEX's token ids. ICPUSD stands in for a USD
  // stablecoin (e.g. USDC). transient: a tunable constant, reset on upgrade.
  transient let ASSETS : [Text] = ["BTC", "ETH", "SOL", "ICP", "ICPUSD"];

  // Per-(user, asset) deposit ledger — the CREDIT axis. `confirmed` is cumulative
  // confirmed inflow (monotonic); `pending` is simulated-but-unconfirmed; `claimed`
  // is the high-water mark so claims are idempotent.
  type Ledger = { var confirmed : Nat; var pending : Nat; var claimed : Nat };
  let ledgers = Map.empty<Text, Ledger>();          // key = principal # "#" # asset

  let onboarded = Map.empty<Text, Bool>();          // users who created their addresses

  // IN-FLIGHT GUARD — cleared by postupgrade, see the note there.
  let claiming  = Map.empty<Text, Bool>();          // reentrancy guard per (user, asset)

  // Play-allowance admission bookkeeping (see devSimulateDeposit): cumulative
  // units the DEX has admitted per (user, asset) — the admission seq — plus a
  // per-(user, asset) guard so two concurrent simulates can't race the seq
  // read across the await (identical seqs would make the DEX no-op the
  // second debit while both deposits get created).
  let admittedUnits = Map.empty<Text, Nat>();
  let admitting     = Map.empty<Text, Bool>();      // in-flight guard — cleared by postupgrade

  // The DEX we credit into, set by a controller after deploy (setDex).
  var dexPrincipal : ?Principal = null;

  // Default wiring: read the DEX's id from our own canister settings —
  // `icp deploy` injects PUBLIC_CANISTER_ID:backend into every project
  // canister, correct per environment (icp-cli pitfall 22). setDex stays as
  // a break-glass override and wins when set (tests wire mock DEXes); the
  // env fallback means a fresh install or reinstall comes up wired with no
  // deploy-script leg.
  func envDex<system>() : ?Principal {
    switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:backend")) {
      case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
      case null { null };
    };
  };
  // Queries lack the `system` capability envVar needs — they read this cache.
  // The initializer runs in the actor INIT context (which has the capability)
  // and re-runs on every install and upgrade, so it is warm from the first
  // block; update-path effectiveDex() calls also refresh it live.
  transient var _envDexCache : ?Principal = envDex<system>();

  func effectiveDex<system>() : ?Principal {
    switch (dexPrincipal) {
      case (?p) { ?p };
      case null { _envDexCache := envDex<system>(); _envDexCache };
    };
  };

  // Only the DEX methods we call. Must match the DEX's signatures exactly.
  type DexActor = actor {
    // seq = this claim's post-credit cumulative `claimed` (monotonic per
    // user+asset); the DEX no-ops any seq it has already applied, so a
    // lost-reply retry of this call can never double-credit.
    creditAndRegister : (Principal, Text, Nat, Nat) -> async { #ok; #err : Text };
    // seq = this admission's post-admit cumulative admitted units (monotonic
    // per user+asset, same discipline as the claim seq); the DEX no-ops any
    // seq it has already applied, so a lost-reply retry can never double-
    // consume the play allowance.
    playDepositReserve : (Principal, Text, Nat, Nat) -> async { #ok; #err : Text };
  };

  func key(user : Principal, asset : Text) : Text { Principal.toText(user) # "#" # asset };

  func requireAuth(caller : Principal) {
    if (Principal.isAnonymous(caller)) { Runtime.trap("Authentication required") };
  };
  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  func ledgerOf(user : Principal, asset : Text) : Ledger {
    let k = key(user, asset);
    switch (Map.get(ledgers, Text.compare, k)) {
      case (?l) { l };
      case null { let l : Ledger = { var confirmed = 0; var pending = 0; var claimed = 0 }; Map.add(ledgers, Text.compare, k, l); l };
    };
  };

  // STUB address derivation. The real Bridge derives these under threshold ECDSA
  // (BTC/EVM) / Schnorr–Ed25519 (SOL) with the principal as the derivation path
  // (docs/bridge-and-cks-design.md §5). Here we instead synthesise a FORMAT-CORRECT
  // but FAKE address per chain: deterministic from the principal (stable across
  // calls) and shaped like the real thing (right prefix, charset, length) — but
  // with no valid checksum and no key behind it. Never send real funds to these.
  transient let HEX    : [Char] = ['0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'];
  transient let BECH32 : [Char] = ['q','p','z','r','y','9','x','8','g','f','2','t','v','d','w','0','s','3','j','n','5','4','k','h','c','e','6','m','u','a','7','l'];
  transient let BASE58 : [Char] = ['1','2','3','4','5','6','7','8','9','A','B','C','D','E','F','G','H','J','K','L','M','N','P','Q','R','S','T','U','V','W','X','Y','Z','a','b','c','d','e','f','g','h','i','j','k','m','n','o','p','q','r','s','t','u','v','w','x','y','z'];

  // `n` deterministic chars from `alphabet`, seeded by the principal + a per-asset
  // salt (so each chain gets a distinct address). FNV-1a fold → xorshift64 stream.
  // NOT cryptographic — a dev stub only.
  func faux(p : Principal, salt : Nat64, alphabet : [Char], n : Nat) : Text {
    let base = Nat64.fromNat(alphabet.size());
    var h : Nat64 = 0xcbf29ce484222325 +% salt;
    for (b in Blob.toArray(Principal.toBlob(p)).vals()) {
      h := (h ^ Nat64.fromNat(Nat8.toNat(b))) *% 0x100000001b3;
    };
    var out = "";
    var i = 0;
    while (i < n) {
      h := h ^ (h << 13);
      h := h ^ (h >> 7);
      h := h ^ (h << 17);
      out #= Char.toText(alphabet[Nat64.toNat(h % base)]);
      i += 1;
    };
    out;
  };

  func fauxAddress(asset : Text, p : Principal) : Text {
    switch (asset) {
      case ("BTC")    { "bc1q" # faux(p, 1, BECH32, 38) };  // native SegWit (P2WPKH), 42 chars
      case ("ETH")    { "0x" # faux(p, 2, HEX, 40) };       // 20-byte EVM address
      case ("SOL")    { faux(p, 3, BASE58, 44) };           // base58 Ed25519 pubkey
      case ("ICP")    { faux(p, 4, HEX, 64) };              // ICP ledger AccountIdentifier (hex — NOT a principal)
      case ("ICPUSD") { "0x" # faux(p, 5, HEX, 40) };       // USDC (ERC-20 on Ethereum)
      case (_)        { faux(p, 9, HEX, 40) };
    };
  };

  // ── Admin wiring ────────────────────────────────────────────
  func cachedDex() : ?Principal {
    switch (dexPrincipal) { case (?p) { ?p }; case null { _envDexCache } };
  };
  public shared (msg) func setDex(p : Principal) : async () {
    requireController(msg.caller);
    dexPrincipal := ?p;
  };
  public query func getDex() : async ?Principal { cachedDex() };
  public query func getSupportedAssets() : async [Text] { ASSETS };

  // ── Addresses ───────────────────────────────────────────────
  public type ChainAddress = { chain : Text; asset : Text; address : Text };

  func addressesFor(p : Principal) : [ChainAddress] {
    [
      { chain = "Bitcoin";  asset = "BTC";    address = fauxAddress("BTC", p) },
      { chain = "Ethereum"; asset = "ETH";    address = fauxAddress("ETH", p) },
      { chain = "Solana";   asset = "SOL";    address = fauxAddress("SOL", p) },
      { chain = "ICP";      asset = "ICP";    address = fauxAddress("ICP", p) },
      { chain = "Ethereum"; asset = "ICPUSD"; address = fauxAddress("ICPUSD", p) },
    ];
  };

  // "Create deposit address" — really register/reveal (addresses are deterministic).
  public shared (msg) func createDepositAddress() : async [ChainAddress] {
    requireAuth(msg.caller);
    Map.add(onboarded, Text.compare, Principal.toText(msg.caller), true);
    addressesFor(msg.caller);
  };

  public query (msg) func getMyDepositAddresses() : async ?[ChainAddress] {
    if (Map.get(onboarded, Text.compare, Principal.toText(msg.caller)) == null) { return null };
    ?addressesFor(msg.caller);
  };

  // Self-reported cycle balance so the DEX's in-canister fuel watermark can
  // keep the Bridge alive WITHOUT controlling it (deposit_cycles needs no
  // controllership; canister_status does). The DEX calls this, and tops up
  // via deposit_cycles when it's low — see tickBridgeFuel in the backend.
  // Any real Bridge implementation should expose the same method to opt into
  // DEX-side fuelling; without it the DEX feeder no-ops and the operator
  // top-up script is the fuel source.
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // ── Deposit views ───────────────────────────────────────────
  public type DepositView = {
    asset : Text; chain : Text; address : Text;
    confirmed : Nat; pending : Nat; claimed : Nat; claimable : Nat;
  };

  public query (msg) func getMyDeposits() : async [DepositView] {
    let addrs = addressesFor(msg.caller);
    Iter.toArray(Iter.map<ChainAddress, DepositView>(addrs.vals(), func(a) {
      let l = switch (Map.get(ledgers, Text.compare, key(msg.caller, a.asset))) {
        case (?x) { x }; case null { { var confirmed = 0; var pending = 0; var claimed = 0 } };
      };
      let claimable = if (l.confirmed > l.claimed) { l.confirmed - l.claimed } else { 0 };
      { asset = a.asset; chain = a.chain; address = a.address;
        confirmed = l.confirmed; pending = l.pending; claimed = l.claimed; claimable };
    }));
  };

  // ── Claim ───────────────────────────────────────────────────
  // Credit the confirmed-but-unclaimed amount into the user's DEX virtual wallet.
  // Idempotent (advances the `claimed` high-water mark only on success) and guarded
  // against concurrent re-entry (two in-flight claims could otherwise double-credit
  // across the await — the real Bridge needs the same saga discipline).
  public shared (msg) func claim(asset : Text) : async { #ok : Nat; #err : Text } {
    requireAuth(msg.caller);
    let dexP = switch (effectiveDex<system>()) { case (?p) { p }; case null { return #err("Bridge is not wired to a DEX yet") } };
    let k = key(msg.caller, asset);
    if (Map.get(claiming, Text.compare, k) != null) { return #err("A claim for " # asset # " is already in progress") };

    let l = ledgerOf(msg.caller, asset);
    let claimable = if (l.confirmed > l.claimed) { l.confirmed - l.claimed } else { 0 };
    if (claimable == 0) { return #err("Nothing to claim for " # asset) };

    Map.add(claiming, Text.compare, k, true);
    let dex : DexActor = actor (Principal.toText(dexP));
    try {
      // Pass the post-claim high-water (l.claimed + claimable) as the DEX-side
      // idempotency key: on success we advance l.claimed to exactly this value,
      // so a retry after a lost #ok recomputes the SAME key and the DEX no-ops.
      let r = await dex.creditAndRegister(msg.caller, asset, claimable, l.claimed + claimable);
      ignore Map.delete(claiming, Text.compare, k);
      switch (r) {
        case (#ok) { l.claimed += claimable; #ok(claimable) };
        case (#err(e)) { #err("DEX credit failed: " # e) };
      };
    } catch (e) {
      ignore Map.delete(claiming, Text.compare, k);
      #err("DEX call failed: " # Error.message(e));
    };
  };

  // ── DEV ONLY (the real Bridge has NO such methods) ──────────
  // Stand in for real external-chain deposits + confirmations.
  //
  // Simulation is where the PLAY ALLOWANCE is exercised: before crediting the
  // pending amount we ask the DEX to ADMIT this deposit (playDepositReserve) —
  // the DEX values it at press-time marks, consumes that much of the user's
  // lifetime allowance up front, and reserves the units so the eventual claim
  // settles against the reservation with no re-valuation and can NEVER be
  // refused by the cap. A refused deposit is never created, so nothing
  // unclaimable ever accumulates here. The admission seq (post-admit
  // cumulative admitted units) makes the call idempotent: if the DEX reserved
  // but our reply was lost, the user's retry recomputes the SAME seq and the
  // DEX no-ops instead of double-debiting the allowance.
  public shared (msg) func devSimulateDeposit(asset : Text, amount : Nat) : async { #ok; #err : Text } {
    requireAuth(msg.caller);
    if (amount == 0) { return #err("Amount must be positive") };
    switch (effectiveDex<system>()) {
      case (?dexP) {
        let k = key(msg.caller, asset);
        if (Map.get(admitting, Text.compare, k) != null) { return #err("A deposit for " # asset # " is already in progress") };
        let admitted = Option.get(Map.get(admittedUnits, Text.compare, k), 0);
        Map.add(admitting, Text.compare, k, true);
        let dex : DexActor = actor (Principal.toText(dexP));
        try {
          switch (await dex.playDepositReserve(msg.caller, asset, amount, admitted + amount)) {
            case (#err(e)) { ignore Map.delete(admitting, Text.compare, k); return #err(e) };
            case (#ok) {};
          };
        } catch (e) {
          ignore Map.delete(admitting, Text.compare, k);
          return #err("Deposit admission check failed: " # Error.message(e));
        };
        ignore Map.delete(admitting, Text.compare, k);
        Map.add(admittedUnits, Text.compare, k, admitted + amount);
      };
      case null {};   // unwired stub → pure dev sandbox, no allowance to enforce
    };
    let l = ledgerOf(msg.caller, asset);
    l.pending += amount;
    #ok;
  };
  public shared (msg) func devConfirmDeposits() : async () {
    requireAuth(msg.caller);
    for (asset in ASSETS.vals()) {
      let l = ledgerOf(msg.caller, asset);
      if (l.pending > 0) { l.confirmed += l.pending; l.pending := 0 };
    };
  };

  // ── Admission control ───────────────────────────────────────
  // The Bridge is the ONBOARDING surface, so it must accept unregistered users
  // (claiming a first deposit is how they register on the DEX). Caller-only:
  // controllers (admin) and any authenticated principal pass; anonymous is shed.
  // ── Upgrade: release the in-flight guards ───────────────────
  //
  // `claiming` and `admitting` are each set BEFORE an `await` and cleared only
  // in the continuation. In a `persistent actor` a plain `let` is implicitly
  // STABLE, so the flag survived an upgrade while the continuation that clears
  // it did not: an upgrade landing between a call and its reply left the flag
  // `true` FOREVER, and that (user, asset) could never claim or deposit again.
  // The cause was the routine act of deploying, and there was no cure short of
  // a code change.
  //
  // Clearing them here is exactly right rather than merely convenient: no
  // continuation survives an upgrade, so after one there is by definition
  // nothing left to guard against — a surviving flag can only be a lie.
  //
  // Why not mark them `transient`, which expresses the same idea? Because
  // dropping a stable variable is a one-way door: `moc --stable-compatible`
  // rejects it with M0169 ("cannot be implicitly discarded"), so the change
  // would need an explicit migration function and would block the upgrade on
  // any already-deployed Bridge. This achieves the same semantics with no
  // change to the stable signature at all — and it also makes an upgrade the
  // RECOVERY for a flag stranded any other way, instead of the thing that
  // strands it. (`admittedUnits` is untouched: that is the admission seq the
  // DEX de-dups against, real bookkeeping rather than a latch.)
  system func postupgrade() {
    Map.clear(claiming);
    Map.clear(admitting);
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
