// Arbitrage canister — the simulated cross-venue arbitrageur.
//
// WHY THIS EXISTS (docs/amm-vault-design.md §"The missing arbitrageur"):
// MULTI/DEX trades SYNTHETIC assets, so there is no real external venue and no
// real arbitrageur. On Uniswap, when the pool price diverges from the wider
// market, arbitrageurs move assets between venues until it converges — that
// external force is what lets a passive AMM hold quotes at fair value and wait.
// Here, nothing plays that role: bots can push the venue price away from the
// oracle mark and the vault's AMM (which by design never quotes across the
// mark) can only widen and wait. This canister simulates the missing force:
//
//   • venue price RICH  (best bid > mark + band): "import" base from the
//     external world at the mark (extMarketSwap #importBase — the DEX mints
//     the base and burns our ICPUSD at mark + haircut, exactly a bridge
//     deposit's Σ-semantics), then SELL it into the rich bids.
//   • venue price CHEAP (best ask < mark − band): BUY the cheap asks on the
//     venue, then "export" the base at the mark (#exportBase).
//
// Both venue legs go through the ORDINARY taker path — staged, anti-sniped,
// fee-bearing, no matching privileges — as short-TTL limit orders pinned just
// beyond the mark, so this canister can never trade WITH the vault's AMM
// (whose quotes never cross the mark) and never worsens a fair price. Its
// profit comes exclusively from whoever pushed the price off the mark, which
// makes manipulation a taxed activity rather than a free one.
//
// SAFETY: the DEX side enforces the real guarantees (wired-principal-only
// exchange, mark freshness + no pending circuit-breaker jump, per-call and
// hourly caps, external-flow accounting). This side is deliberately dumb —
// bounded sizes, stand down when the mark is stale, flatten inventory every
// tick, and every action is queryable (getStatus) for the ops surface.

import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Runtime "mo:core/Runtime";
import Error "mo:core/Error";
import Cycles "mo:core/Cycles";
import Fixed "../backend/lib/Fixed";

persistent actor Arb {

  // ── Tunables (transient: re-read from source on every upgrade) ──────
  transient let TICK_NS       : Int = 5_000_000_000;   // decision cadence
  transient let FRESH_MAX_NS  : Int = 45_000_000_000;  // stand down past this mark age
  transient let BAND_BPS      : Nat = 50;   // act only when |venue − mark| exceeds this
  transient let EDGE_BPS      : Nat = 20;   // rest our limit this far beyond the mark
  // Scaled with the vault: a $5.125M AMM is 5.125x the old $1M, so a 50bps
  // deviation is 5.125x the value to absorb. Holding the clip at $2k would
  // leave the arb permanently behind the mark on a production-scale venue.
  transient let TRADE_CAP_USD : Nat = 1_025_000_000_000; // $10.25k per market per tick
  transient let DUST_USD      : Nat = 500_000_000;     // ignore base positions under $5
  transient let ORDER_TTL_SEC : Nat = 8;    // venue remnants self-expire

  // ── Wiring & state ──────────────────────────────────────────────────
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
  var enabled : Bool = false;
  var lastTickNs : Int = 0;
  transient var _inFlight : Bool = false;
  // Rolling action journal for ops (getStatus) — newest first, capped.
  var actions : [Text] = [];
  transient let ACTIONS_CAP : Nat = 40;

  func note(t : Text) {
    let stamped = Int.toText(Time.now() / 1_000_000_000) # "s " # t;
    let n = actions.size();
    let keep = if (n + 1 > ACTIONS_CAP) { ACTIONS_CAP - 1 : Nat } else { n };
    actions := Iter.toArray(Iter.concat<Text>(
      [stamped].vals(),
      Iter.take(actions.vals(), keep)));
  };

  // Narrow views of the DEX's types: Candid decodes a wider record into these
  // (record subtyping), so the backend can evolve without breaking us.
  type PoolView = {
    marketId : Text;
    baseToken : Text;
    refPrice : Nat;
    refPriceUpdatedNs : Int;
    enabled : Bool;
  };
  type Level = { price : Nat; quantity : Nat };
  type Depth = { asks : [Level]; bids : [Level] };
  type Dex = actor {
    getAmmPools : query () -> async [PoolView];
    getOrderBookDepth : query (Text, ?Nat) -> async Depth;
    getBalance : query (Text) -> async Nat;
    getMyAvailableBalance : query (Text) -> async Nat;
    placeLimitOrderExp : (Text, { #buy; #sell }, Nat, Nat, ?Nat) -> async { #ok : {}; #err : Text };
    extMarketSwap : (Text, { #importBase; #exportBase }, Nat) -> async { #ok : Nat; #err : Text };
  };

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  // ── Admin wiring ────────────────────────────────────────────────────
  func cachedDex() : ?Principal {
    switch (dexPrincipal) { case (?p) { ?p }; case null { _envDexCache } };
  };
  public shared (msg) func setDex(p : Principal) : async () {
    requireController(msg.caller);
    dexPrincipal := ?p;
  };
  public query func getDex() : async ?Principal { cachedDex() };

  public shared (msg) func setEnabled(on : Bool) : async () {
    requireController(msg.caller);
    enabled := on;
    note(if on "enabled" else "disabled");
  };

  public query func getStatus() : async {
    enabled : Bool;
    dex : ?Principal;
    lastTickNs : Int;
    bandBps : Nat;
    edgeBps : Nat;
    tradeCapUsd : Nat;
    recentActions : [Text];
  } {
    {
      enabled; dex = cachedDex(); lastTickNs;
      bandBps = BAND_BPS; edgeBps = EDGE_BPS; tradeCapUsd = TRADE_CAP_USD;
      recentActions = actions;
    };
  };

  // DEX-side fuel watermark support (same opt-in as the Bridge).
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // ── The tick ────────────────────────────────────────────────────────
  system func heartbeat() : async () {
    if (not enabled or _inFlight) { return };
    let now = Time.now();
    if (now - lastTickNs < TICK_NS) { return };
    lastTickNs := now;
    _inFlight := true;
    try { ignore await runTick() } catch (_) {};
    _inFlight := false;
  };

  // Manual, controller-driven tick — the deterministic path integration tests
  // use (they pause nothing here; they simply call this instead of waiting).
  public shared (msg) func tickOnce() : async Text {
    requireController(msg.caller);
    if (_inFlight) { return "busy" };
    _inFlight := true;
    let r = try { await runTick() } catch (e) { "tick failed: " # Error.message(e) };
    _inFlight := false;
    r;
  };

  func bpsUp(x : Nat, bps : Nat) : Nat { Fixed.mulDiv(x, 10_000 + bps, 10_000, true) };
  func bpsDn(x : Nat, bps : Nat) : Nat { Fixed.mulDiv(x, 10_000 - bps, 10_000, false) };

  func runTick() : async Text {
    let dexP = switch (effectiveDex<system>()) { case (?p) { p }; case null { return "unwired" } };
    let dex : Dex = actor (Principal.toText(dexP));
    let now = Time.now();
    var summary = "";
    let pools = await dex.getAmmPools();
    for (pool in pools.vals()) {
      if (pool.enabled and pool.refPrice > 0) {
        let mark = pool.refPrice;
        let ageNs = now - pool.refPriceUpdatedNs;
        if (pool.refPriceUpdatedNs > 0 and ageNs <= FRESH_MAX_NS) {
          let token = pool.baseToken;

          // 1. FLATTEN — export any base sitting in our account (last tick's
          // cheap-side buys, or a rich-side import whose sell didn't fill).
          // Realizing through the external market is where cheap-side profit
          // lands; leftovers cost the haircut, bounded by the per-tick cap.
          let availBase = await dex.getMyAvailableBalance(token);
          if (Fixed.mul(availBase, mark, false) > DUST_USD) {
            let capBase = Fixed.mulDiv(TRADE_CAP_USD, Fixed.SCALE, mark, false);
            let q = Nat.min(availBase, capBase);
            switch (await dex.extMarketSwap(token, #exportBase, q)) {
              case (#ok(proceeds)) { note("export " # Nat.toText(q) # " " # token # " → " # Nat.toText(proceeds) # " USD"); summary #= token # ":export "; };
              case (#err(e)) { note("export " # token # " refused: " # e) };
            };
          };

          // 2. Read the top of book and act on a deviation beyond the band.
          let depth = await dex.getOrderBookDepth(pool.marketId, ?1);
          let richFloor  = bpsUp(mark, BAND_BPS);   // bids above this are rich
          let cheapCeil  = bpsDn(mark, BAND_BPS);   // asks below this are cheap
          let capBase = Fixed.mulDiv(TRADE_CAP_USD, Fixed.SCALE, mark, false);

          if (depth.bids.size() > 0 and depth.bids[0].price >= richFloor) {
            // RICH: import at the mark, sell into the rich bids. The sell is
            // pinned at mark + EDGE — beyond the mark (so it can never touch
            // the AMM's bid at mark − spread) but under the rich bids (so it
            // sweeps everything above it). Remnant self-expires.
            let q = Nat.min(depth.bids[0].quantity, capBase);
            if (q > 0) {
              switch (await dex.extMarketSwap(token, #importBase, q)) {
                case (#ok(_)) {
                  switch (await dex.placeLimitOrderExp(pool.marketId, #sell, bpsUp(mark, EDGE_BPS), q, ?ORDER_TTL_SEC)) {
                    case (#ok(_)) { note("rich: imported+selling " # Nat.toText(q) # " " # token # " (bid " # Nat.toText(depth.bids[0].price) # " > mark " # Nat.toText(mark) # ")"); summary #= token # ":rich "; };
                    case (#err(e)) { note("rich sell refused (" # token # "): " # e) };
                  };
                };
                case (#err(e)) { note("import refused (" # token # "): " # e) };
              };
            };
          } else if (depth.asks.size() > 0 and depth.asks[0].price <= cheapCeil) {
            // CHEAP: buy the cheap asks (pinned at mark − EDGE, so we never
            // lift the AMM's ask at mark + spread); the flatten step of the
            // NEXT tick exports the fill at the mark.
            let affordable = await dex.getMyAvailableBalance("ICPUSD");
            let limitPx = bpsDn(mark, EDGE_BPS);
            // Reserve headroom: cost rounds up + taker fee ≤ 10 bp.
            let maxByCash = Fixed.mulDiv(bpsDn(affordable, 20), Fixed.SCALE, limitPx, false);
            let q = Nat.min(Nat.min(depth.asks[0].quantity, capBase), maxByCash);
            if (q > 0) {
              switch (await dex.placeLimitOrderExp(pool.marketId, #buy, limitPx, q, ?ORDER_TTL_SEC)) {
                case (#ok(_)) { note("cheap: buying " # Nat.toText(q) # " " # token # " (ask " # Nat.toText(depth.asks[0].price) # " < mark " # Nat.toText(mark) # ")"); summary #= token # ":cheap "; };
                case (#err(e)) { note("cheap buy refused (" # token # "): " # e) };
              };
            };
          };
        };
      };
    };
    if (summary == "") { "idle" } else { summary };
  };

  // Caller-only spam gate (same posture as the Bridge): controllers and any
  // non-anonymous principal may reach the queries; updates self-enforce.
  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
