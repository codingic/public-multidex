// Liquidator.mo — Phase 2B single-position close at health < 1.15.
//
// When a margin user's healthRatio drops below MAINTENANCE_HEALTH_RATIO,
// the engine seizes enough of one collateral token to fully repay
// their LARGEST debt + a 5% penalty that accrues to the AMM vault.
// One pass closes one position; if the user is still underwater after
// (rare — only happens on very mixed liabilities), the next post-fill
// or timer pass closes the next-largest debt.
//
// Supported collateral routes (all settle at the oracle mid):
//   debt_token == collateral_token  → direct repay, no conversion
//   debt_token != collateral_token  → vault absorbs the collateral into
//     inventory and writes the debt off by its USD value (one value
//     conversion; covers X↔ICPUSD and base↔base alike). Needs only an
//     oracle price for both tokens.
//
// Cross-token seizes do NOT route through the order book. Under the sealed
// model the AMM's quotes are non-takeable by the AMM itself, so a vault-side
// market sell of seized collateral can never consume the AMM ladder — in a
// thin book it would either find no fill (collateral un-seizable → bad debt)
// or dump past the ladder into stranded liquidity (a wick + LP loss). Instead
// the vault ABSORBS the collateral into inventory at the oracle mid and writes
// the debt off by its USD value (see seizeOnce). Only an oracle price (via the
// supplied priceLookup) is needed — no swap callback, no engine coupling.

import Principal "mo:core/Principal";
import Types "Types";
import Fixed "Fixed";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Accounts "Accounts";
import MarginEngine "MarginEngine";
import BorrowEngine "BorrowEngine";
import SafeMath "SafeMath";

module {

  public type PriceLookup = Types.TokenId -> ?Nat;

  func priceOf(token : Types.TokenId, priceLookup : PriceLookup) : Nat {
    if (token == Types.QUOTE_TOKEN) { return Fixed.SCALE };
    switch (priceLookup(token)) { case (?p) { p }; case null { 0 } };
  };

  // Pick the user's debt token with the largest USD value. Tie-breaks
  // by token-name order (deterministic).
  func largestDebt(
    state       : BorrowEngine.LoanState,
    user        : Principal,
    priceLookup : PriceLookup,
  ) : ?Types.DebtEntry {
    let debts = BorrowEngine.getDebt(state, user, priceLookup);
    if (debts.size() == 0) { return null };
    var best = debts[0];
    var i = 1;
    while (i < debts.size()) {
      let cand = debts[i];
      if (cand.debtUsd > best.debtUsd
          or (cand.debtUsd == best.debtUsd and cand.token < best.token)) {
        best := cand;
      };
      i += 1;
    };
    ?best;
  };

  // Pick the collateral token to seize against this debt. Preference:
  //   1. Same token as the debt (direct repay, no conversion).
  //   2. ICPUSD when the debt is a base asset (and vice-versa).
  //   3. any other base asset — e.g. a short owing X but holding only another
  //      base asset, which must be liquidatable rather than accrue bad debt.
  // Cross-token seizes (2 + 3) are absorbed into the vault at the oracle mid
  // by seizeOnce, so no token actually trades; this just chooses the richest
  // seizable token. Returns null only if the user holds NO seizable collateral.
  func pickCollateral(
    margin      : MarginEngine.MarginState,
    accounts    : Accounts.AccountState,
    user        : Principal,
    debtToken   : Types.TokenId,
    priceLookup : PriceLookup,
  ) : ?Types.CollateralValuation {
    // Seize sizing must use SEIZABLE (un-reserved) balance — reserved
    // funds are locked in pending matches and can't be grabbed. So we
    // value with a zero-reserved lookup here (distinct from the health
    // check, which counts reserved).
    let noReserved : MarginEngine.ReservedLookup = func(_, _) { 0 };
    let vals = MarginEngine.valuations(margin, accounts, noReserved, user, priceLookup);
    // First pass: exact-token match (direct repay path).
    var sameTokenHit : ?Types.CollateralValuation = null;
    for (v in vals.vals()) {
      if (v.token == debtToken and v.balance > 0) {
        sameTokenHit := ?v;
      };
    };
    switch (sameTokenHit) {
      case (?v) { return ?v };
      case null { };
    };
    // Second pass: one-leg path (X-ICPUSD market exists for every
    // tradable base token).
    //   debt is ICPUSD → any non-ICPUSD collateral works.
    //   debt is X       → ICPUSD collateral works.
    if (debtToken == Types.QUOTE_TOKEN) {
      // Prefer the highest-$ collateral so we maximise the chance of
      // covering the full debt in one pass.
      var best : ?Types.CollateralValuation = null;
      for (v in vals.vals()) {
        if (v.token != Types.QUOTE_TOKEN and v.balance > 0) {
          switch (best) {
            case null { best := ?v };
            case (?b) { if (v.contribUsd > b.contribUsd) { best := ?v } };
          };
        };
      };
      best
    } else {
      // Debt is a non-ICPUSD asset.
      //   Prefer ICPUSD collateral → single-leg buy (debt_token with ICPUSD).
      //   Fall back to the highest-$ OTHER base asset → two-leg route
      //   (sell it for ICPUSD, then buy debt_token). This is what lets a
      //   short (owes BTC, holds only SOL) be liquidated, rather than
      //   sitting un-recoverable.
      var icpusd   : ?Types.CollateralValuation = null;
      var bestBase : ?Types.CollateralValuation = null;
      for (v in vals.vals()) {
        if (v.token == Types.QUOTE_TOKEN and v.balance > 0) {
          icpusd := ?v;
        } else if (v.token != debtToken and v.balance > 0) {
          switch (bestBase) {
            case null { bestBase := ?v };
            case (?b) { if (v.contribUsd > b.contribUsd) { bestBase := ?v } };
          };
        };
      };
      switch (icpusd) { case (?v) { ?v }; case null { bestBase } };
    };
  };

  // ── Partial-close seize sizing (Phase 3A) ──────────────────────
  // Seize only enough collateral to restore health from < MAINTENANCE
  // (1.15) back up to TARGET (1.25), rather than fully closing the
  // largest debt. Keeps users alive through volatility and avoids
  // over-liquidation. Shared by tryLiquidate (book path) and
  // planLiquidation (netting path) so the two never diverge.
  //
  // Seizing USD value S of collateral: the proceeds are split so a GUARANTEED
  // 5% liquidation penalty is skimmed to the insurance fund and the rest
  // repays debt — i.e. of S, debt repaid R = S / (1 + penalty) and the 5%
  // (S − R) accrues to the buffer (see seizeOnce). So:
  //   new weighted collateral = C − S × ltv_collateral
  //   new debt                = D − S / (1 + penalty)
  // Solve (C − S·ltv)/(D − S/(1+p)) = TARGET for S:
  //   S = (C − TARGET·D) / (ltv − TARGET/(1+p))
  // For a liquidatable position the numerator is negative (C < 1.15·D <
  // TARGET·D) and the denominator is negative (ltv ≤ 1.0 < TARGET/1.05 ≈
  // 1.19), so S > 0. Returns collateral-token UNITS, bounded by holdings;
  // 0.0 on missing oracle price.
  func partialSeizeQty(
    healthBefore : Types.MarginHealth,
    debt         : Types.DebtEntry,
    coll         : Types.CollateralValuation,
  ) : Nat {
    let collPrice = coll.refPrice;
    if (collPrice == 0) { return 0 };
    let C   = healthBefore.collateralUsd;       // Nat USD value
    let D   = healthBefore.debtUsd;             // Nat USD value
    let tgt = Types.TARGET_HEALTH_RATIO;        // 1.25 at 10^8
    let pm  = Fixed.SCALE + Types.LIQUIDATION_PENALTY; // 1.05 at 10^8
    // denom = ltv − tgt/pm (signed; normally negative since ltv ≤ 1.0 < ~1.19).
    // Round DOWN: tgtOverPm sits in the seize DENOMINATOR (tgtOverPm − ltv), so
    // a smaller value enlarges the seize — the solvency-favoring direction
    // ("seize enough to reach target; over-seize is refunded"). (≪ ltv's range,
    // so the tgtOverPm > coll.ltv branch test is unaffected.)
    let tgtOverPm = Fixed.div(tgt, pm, false);  // ~1.1905
    let seizeUsd : Nat =
      if (tgtOverPm > coll.ltv) {
        // Both num and denom negative → S = |C − tgt·D| / |denom|, scaled UP
        // (seize enough to reach target; any over-seize is refunded in seizeOnce).
        let tgtD = Fixed.mul(tgt, D, true);
        if (tgtD > C) { Fixed.div(tgtD - C, tgtOverPm - coll.ltv, true) } else { 0 }
      } else {
        // Defensive (denom ≥ 0): full close sized at debt × (1 + penalty).
        Fixed.mul(debt.debtUsd, pm, true)
      };
    var seizeQty = Fixed.div(seizeUsd, collPrice, true);
    // Never seize more than the user holds of this token.
    if (seizeQty > coll.balance) { seizeQty := coll.balance };
    seizeQty;
  };

  // ── Netting plan (Phase 3B) ────────────────────────────────────
  // Classify a liquidatable user's intended trade WITHOUT executing it,
  // so the batch driver can match opposing flows on the same base asset
  // against each other (at oracle mid) before either touches the book.
  //
  //   #sellBase : long-liq (collateral = base X, debt = ICPUSD) → sells X
  //   #buyBase  : short-liq (collateral = ICPUSD, debt = base X) → buys X
  //   #direct   : same-token (no base trade) — not nettable
  //
  // baseQty is in base-asset units (X). For a seller it's the seized X
  // qty; for a buyer it's the ICPUSD seize converted to X at oracle mid.
  // Returns null when the user is not liquidatable, has no compatible
  // collateral, or the case is an unsupported base↔base pair.
  public type TradeKind = { #direct; #sellBase; #buyBase };
  public type LiquidationPlan = {
    user      : Principal;
    debtToken : Types.TokenId;
    collToken : Types.TokenId;
    collPrice : Nat;
    seizeQty  : Nat;          // collateral-token units
    kind      : TradeKind;
    baseToken : Types.TokenId;  // the X in X-ICPUSD (QUOTE_TOKEN for #direct)
    baseQty   : Nat;          // base-asset units to sell / buy via netting
  };

  public func planLiquidation(
    loans       : BorrowEngine.LoanState,
    margin      : MarginEngine.MarginState,
    accounts    : Accounts.AccountState,
    reserved    : MarginEngine.ReservedLookup,
    user        : Principal,
    priceLookup : PriceLookup,
  ) : ?LiquidationPlan {
    let healthBefore = BorrowEngine.getHealth(loans, margin, accounts, reserved, user, priceLookup);
    if (not healthBefore.isLiquidatable) { return null };
    let debt = switch (largestDebt(loans, user, priceLookup)) {
      case (?d) { d }; case null { return null };
    };
    let coll = switch (pickCollateral(margin, accounts, user, debt.token, priceLookup)) {
      case (?c) { c }; case null { return null };
    };
    let crossToken = debt.token != coll.token;
    // base↔base needs a multi-leg route — not nettable, not supported here.
    if (crossToken and debt.token != Types.QUOTE_TOKEN and coll.token != Types.QUOTE_TOKEN) {
      return null;
    };
    let seizeQty = partialSeizeQty(healthBefore, debt, coll);
    if (seizeQty == 0) { return null };
    if (not crossToken) {
      return ?{
        user; debtToken = debt.token; collToken = coll.token;
        collPrice = coll.refPrice; seizeQty; kind = #direct;
        baseToken = Types.QUOTE_TOKEN; baseQty = 0;
      };
    };
    if (debt.token == Types.QUOTE_TOKEN) {
      // collateral is base X, debt ICPUSD → SELL X. baseQty = seizeQty (X).
      ?{
        user; debtToken = debt.token; collToken = coll.token;
        collPrice = coll.refPrice; seizeQty; kind = #sellBase;
        baseToken = coll.token; baseQty = seizeQty;
      }
    } else {
      // collateral ICPUSD, debt base X → BUY X. seizeQty is in ICPUSD;
      // baseQty = ICPUSD seized / oracle mid.
      let px = priceOf(debt.token, priceLookup);
      let bq = if (px > 0) { Fixed.div(seizeQty, px, false) } else { 0 };
      ?{
        user; debtToken = debt.token; collToken = coll.token;
        collPrice = coll.refPrice; seizeQty; kind = #buyBase;
        baseToken = debt.token; baseQty = bq;
      }
    };
  };

  // Settle `qty` base-X units between a long-liquidatee (seller: holds X,
  // owes ICPUSD) and a short-liquidatee (buyer: holds ICPUSD, owes X) at
  // oracle mid `mid` — INTERNALLY, with no order-book trade. The seller's
  // X covers the buyer's X debt; the buyer's ICPUSD covers the seller's
  // ICPUSD debt; the vault is a flat passthrough. No penalty on the
  // netted portion — netting is the most capital-efficient liquidation
  // path and rewards offsetting flow. Returns the settled slice as
  // { cash = qty × mid; qty } — both zero if nothing could move
  // (bound by balances / debts). qty is clamped to both sides'
  // spendable balance and outstanding debt so neither vault leg leaks.
  public func settleNettedPair(
    loans          : BorrowEngine.LoanState,
    accounts       : Accounts.AccountState,
    seller         : Principal,
    buyer          : Principal,
    baseToken      : Types.TokenId,
    qty            : Nat,
    mid            : Nat,
    vaultPrincipal : Principal,
    now            : Int,
  ) : { cash : Nat; qty : Nat } {
    let zero = { cash = 0; qty = 0 };
    if (qty == 0 or mid == 0) { return zero };
    // Bound by the seller's spendable X, the buyer's spendable ICPUSD,
    // the seller's ICPUSD debt, and the buyer's X debt — so each leg is
    // exact (no vault windfall, no over-write-off). Divisions round DOWN
    // (conservative bounds — never overcommit a leg).
    let sellerX   = Accounts.getBalance(accounts, seller, baseToken);
    let buyerCash = Accounts.getBalance(accounts, buyer, Types.QUOTE_TOKEN);
    let sellerDebtIcp = BorrowEngine.loanOf(loans, seller, Types.QUOTE_TOKEN);
    let buyerDebtX    = BorrowEngine.loanOf(loans, buyer, baseToken);
    var q = qty;
    if (q > sellerX)         { q := sellerX };
    let buyerCashQty = Fixed.div(buyerCash, mid, false);
    if (q > buyerCashQty) { q := buyerCashQty };
    let sellerDebtQty = Fixed.div(sellerDebtIcp, mid, false);
    if (q > sellerDebtQty) { q := sellerDebtQty };
    if (q > buyerDebtX)      { q := buyerDebtX };
    if (q == 0) { return zero };
    let cash = Fixed.mul(q, mid, false);
    // Seller: X → vault, ICPUSD debt written off by `cash`.
    if (not Accounts.subtractBalance(accounts, seller, baseToken, q)) { return zero };
    Accounts.addBalance(accounts, vaultPrincipal, baseToken, q);
    ignore BorrowEngine.writeOffLoan(loans, seller, Types.QUOTE_TOKEN, cash, now);
    // Buyer: ICPUSD → vault, X debt written off by `q`.
    if (not Accounts.subtractBalance(accounts, buyer, Types.QUOTE_TOKEN, cash)) {
      // Roll back the seller leg if the buyer can't pay.
      ignore Accounts.subtractBalance(accounts, vaultPrincipal, baseToken, q);
      Accounts.addBalance(accounts, seller, baseToken, q);
      return zero;
    };
    Accounts.addBalance(accounts, vaultPrincipal, Types.QUOTE_TOKEN, cash);
    ignore BorrowEngine.writeOffLoan(loans, buyer, baseToken, q, now);
    // Return the EXACT settled base qty alongside the cash — the caller books
    // this slice into both pools' position records, and re-deriving qty from
    // cash/mid would re-floor and drift by a base unit.
    { cash; qty = q };
  };

  // ── Liquidation entry point ────────────────────────────────────
  //
  // Sequence:
  //   1. Accrue interest on the user's loans.
  //   2. Health check — if not actually liquidatable, return #healthy
  //      (race-safe; the caller may have an older snapshot).
  //   3. Pick largest debt and a supported collateral source.
  //   4. Compute seize quantity that yields debtUsd × 1.05 of proceeds.
  //   5. Move seized collateral from user balance to vault and
  //      reduce user's committed amount accordingly.
  //   6. Same-token path: directly reduce loan principal by debtPrincipal.
  //      Cross-token path: the vault absorbs the collateral at the oracle
  //      mid and reduces loan principal by min(loan, USD value / 1.05).
  //   7. The 5% penalty stays in vault as a surplus — nothing extra
  //      to transfer.
  //   8. Build LiquidationEvent and return.
  public func tryLiquidate(
    loans          : BorrowEngine.LoanState,
    margin         : MarginEngine.MarginState,
    accounts       : Accounts.AccountState,
    reserved       : MarginEngine.ReservedLookup,
    user           : Principal,
    vaultPrincipal : Principal,
    now            : Int,
    priceLookup    : PriceLookup,
  ) : Types.LiquidationOutcome {
    // Step 1 — accrue interest.
    BorrowEngine.accrueAll(loans, user, now);

    // Step 2 — health snapshot.
    let healthBefore = BorrowEngine.getHealth(loans, margin, accounts, reserved, user, priceLookup);
    if (not healthBefore.isLiquidatable) { return #healthy };

    // Steps 3–6, LOOPED (Phase 3 multi-token close). Entry is gated on
    // MAINTENANCE above; once triggered we seize toward the TARGET ratio,
    // spanning MULTIPLE collateral tokens (and debts) in one pass if the
    // best single token isn't enough to get there. This closes the gap
    // where a partial close that ran out of one token would stop above
    // maintenance but below target.

    // Seize + repay for ONE (debt, collateral) pair, sized toward TARGET
    // from the CURRENT health `h`. Mutates balances + loans in place;
    // rolls back its own seize if the repay/valuation can't complete.
    // Returns what was repaid/seized, or #err.
    func seizeOnce(
      h    : Types.MarginHealth,
      debt : Types.DebtEntry,
      coll : Types.CollateralValuation,
    ) : {
      #ok : {
        debtToken : Types.TokenId; debtRepaid : Nat; debtRepaidUsd : Nat;
        collToken : Types.TokenId; collSeized : Nat; collSeizedUsd : Nat;
        proceedsUsd : Nat;
      };
      #err : Text;
    } {
      let crossToken = debt.token != coll.token;
      let collPrice = coll.refPrice;
      if (collPrice == 0) { return #err("no oracle price for collateral " # coll.token) };
      let seizeQty = partialSeizeQty(h, debt, coll);
      if (seizeQty == 0) { return #err("seize qty rounds to zero") };

      // Transfer the seized collateral to the vault (the balance
      // subtraction IS the collateral reduction in cross-margin).
      if (not Accounts.subtractBalance(accounts, user, coll.token, seizeQty)) {
        return #err("balance subtraction failed for " # coll.token);
      };
      Accounts.addBalance(accounts, vaultPrincipal, coll.token, seizeQty);

      // Guaranteed-penalty split: of the `gross` proceeds (debt-token units)
      // available to apply, repay R = gross/(1+p) and KEEP penalty = p·R in
      // the vault as insurance surplus; refund anything beyond R + penalty
      // to the user. So every liquidation charges exactly the 5% penalty
      // (self-funding the buffer), never more (over-recovery refunded).
      let pm = Fixed.SCALE + Types.LIQUIDATION_PENALTY;  // 1.05 at 10^8
      let dPrice = priceOf(debt.token, priceLookup);
      let (debtRepaidPrincipal, proceedsUsd) = if (not crossToken) {
        // Direct path: seized token IS the debt token; gross = seizeQty.
        let toRepay = Nat.min(debt.principal, Fixed.div(seizeQty, pm, false));
        switch (BorrowEngine.repayFromVault(loans, vaultPrincipal, accounts, user, coll.token, toRepay, now)) {
          case (#ok(_)) { };
          case (#err(e)) { return #err("repay failed: " # e) };
        };
        let penaltyKept = Fixed.mul(toRepay, Types.LIQUIDATION_PENALTY, false);
        let refundable = SafeMath.subOrZero(seizeQty, toRepay + penaltyKept);
        if (refundable > 0) {
          ignore Accounts.subtractBalance(accounts, vaultPrincipal, coll.token, refundable);
          Accounts.addBalance(accounts, user, coll.token, refundable);
        };
        (toRepay, Fixed.mul(toRepay + penaltyKept, collPrice, false))
      } else {
        // ── Cross-token: AMM-vault internal absorb (no order-book swap) ──
        // The seized collateral cannot be SOLD on the book under the sealed
        // model: the AMM's own quotes are non-takeable BY the AMM, and the
        // taker here IS the vault — so a market sell can never consume the
        // AMM ladder. In a thin book that leaves only two outcomes, both bad:
        // nothing fills (collateral un-seizable → the debt rots into bad debt
        // and the user keeps their collateral), or the sell dumps far past the
        // ladder into stranded arb liquidity (a candle wick + real LP loss).
        // Liquidations are MANDATORY and the vault is the natural counterparty,
        // so it instead ABSORBS the collateral into inventory at the oracle mid
        // and writes the debt off by its USD value — exactly how the same-token
        // (#direct) close and the netting path already settle. No book trade is
        // printed (no wick), and solvency holds whenever an oracle price exists.
        // Covers BOTH the one-leg (X↔ICPUSD) and former two-leg (base↔base, e.g.
        // seize SOL to repay BTC) cases: with both sides oracle-priced the route
        // is a single value conversion, no intermediate ICPUSD hop.
        //
        // A self-trade against the AMM's own resting ladder can't substitute for
        // this: taker and maker are the same principal, so every leg nets to
        // zero and nothing converts. Absorbing into inventory is the only
        // conserved path — the vault KEEPS the collateral; nothing is minted.
        if (dPrice == 0) {
          // Can't value the debt token — undo the seize so a later pass retries.
          ignore Accounts.subtractBalance(accounts, vaultPrincipal, coll.token, seizeQty);
          Accounts.addBalance(accounts, user, coll.token, seizeQty);
          return #err("no oracle price for debt token " # debt.token);
        };
        // Seized collateral value, expressed in debt-token units.
        let grossDebtUnits = Fixed.div(Fixed.mul(seizeQty, collPrice, false), dPrice, false);
        let toRepay = Nat.min(debt.principal, Fixed.div(grossDebtUnits, pm, false));
        switch (BorrowEngine.repayFromVault(loans, vaultPrincipal, accounts, user, debt.token, toRepay, now)) {
          case (#ok(_)) { };
          case (#err(e)) {
            ignore Accounts.subtractBalance(accounts, vaultPrincipal, coll.token, seizeQty);
            Accounts.addBalance(accounts, user, coll.token, seizeQty);
            return #err("repay failed: " # e);
          };
        };
        // The vault retains only enough collateral to cover the repaid debt +
        // the 5% penalty (both debt-token units → collateral units); the rest is
        // refunded. Normal partial close: toRepay = grossDebtUnits/pm, so nothing
        // refunds. A refund arises only when toRepay was capped by the
        // outstanding principal (over-recovery), mirroring the #direct path.
        let penaltyKept = Fixed.mul(toRepay, Types.LIQUIDATION_PENALTY, false);
        // Round the vault's RETAINED collateral UP (refund = seizeQty −
        // retainedColl rounds DOWN against the user) so the vault always keeps
        // enough to back the repaid debt + penalty. The safe-subtract below
        // keeps the refund ≥ 0 even if retainedColl rounds up past seizeQty.
        let retainedColl = Fixed.div(Fixed.mul(toRepay + penaltyKept, dPrice, true), collPrice, true);
        let refundableColl = SafeMath.subOrZero(seizeQty, retainedColl);
        if (refundableColl > 0) {
          ignore Accounts.subtractBalance(accounts, vaultPrincipal, coll.token, refundableColl);
          Accounts.addBalance(accounts, user, coll.token, refundableColl);
        };
        (toRepay, Fixed.mul(toRepay + penaltyKept, dPrice, false))
      };

      #ok({
        debtToken     = debt.token;
        debtRepaid    = debtRepaidPrincipal;
        debtRepaidUsd = Fixed.mul(debtRepaidPrincipal, priceOf(debt.token, priceLookup), false);
        collToken     = coll.token;
        collSeized    = seizeQty;
        collSeizedUsd = Fixed.mul(seizeQty, collPrice, false);
        proceedsUsd;
      })
    };

    // The loop. Accumulate USD totals; track the largest single debt-repaid
    // and collateral-seized leg as the event's "primary" tokens.
    var totDebtRepaidUsd : Nat = 0;
    var totProceedsUsd   : Nat = 0;
    var primDebtToken    : Types.TokenId = "";
    var primDebtRepaid   : Nat = 0;
    var primDebtUsd      : Int = -1;   // sentinel: -1 = "no leg yet" (USD ≥ 0 once set)
    var primCollToken    : Types.TokenId = "";
    var primCollSeized   : Nat = 0;
    var primCollUsd      : Int = -1;
    var madeProgress     = false;
    var stopErr         : ?Text = null;
    var iter = 0;
    label L while (iter < 8) {
      iter += 1;
      let h = BorrowEngine.getHealth(loans, margin, accounts, reserved, user, priceLookup);
      if (h.debtUsd == 0) { break L };
      if (h.healthRatio >= Types.TARGET_HEALTH_RATIO) { break L };
      let debt = switch (largestDebt(loans, user, priceLookup)) {
        case (?d) { d }; case null { break L };
      };
      let coll = switch (pickCollateral(margin, accounts, user, debt.token, priceLookup)) {
        case (?c) { c };
        case null { break L }; // no seizable collateral → handled below
      };
      switch (seizeOnce(h, debt, coll)) {
        case (#ok(r)) {
          madeProgress := true;
          totDebtRepaidUsd += r.debtRepaidUsd;
          totProceedsUsd   += r.proceedsUsd;
          if (r.debtRepaidUsd > primDebtUsd) {
            primDebtUsd := r.debtRepaidUsd; primDebtToken := r.debtToken; primDebtRepaid := r.debtRepaid;
          };
          if (r.collSeizedUsd > primCollUsd) {
            primCollUsd := r.collSeizedUsd; primCollToken := r.collToken; primCollSeized := r.collSeized;
          };
        };
        case (#err(e)) {
          // seizeOnce rolled back its own work. Stop here; if we'd
          // already made progress, finalise with what we got.
          if (not madeProgress) { stopErr := ?e };
          break L;
        };
      };
    };

    // Nothing seized at all.
    if (not madeProgress) {
      // A seizeOnce error (e.g. missing oracle price) is transient — surface
      // as #err so the caller retries next tick, no coverage.
      switch (stopErr) { case (?e) { return #err(e) }; case null {} };
      // Otherwise the user is liquidatable and owes debt but has NO seizable
      // collateral — genuinely insolvent. Emit a zero-recovery #insolvent
      // event so the caller's insurance fund (Phase 4) closes the position
      // instead of leaving it to linger as a perpetually-liquidatable zombie.
      let dt = switch (largestDebt(loans, user, priceLookup)) {
        case (?d) { d.token }; case null { "" };
      };
      let zeroEvent : Types.LiquidationEvent = {
        user;
        debtToken        = dt;
        debtRepaid       = 0;
        debtRepaidUsd    = 0;
        collateralToken  = "";
        collateralSeized = 0;
        proceedsUsd      = 0;
        penaltyUsd       = 0;
        healthBefore     = healthBefore.healthRatio;
        healthAfter      = healthBefore.healthRatio;
        timestamp        = now;
      };
      return #insolvent(zeroEvent);
    };

    // Step 7 — build the aggregate event.
    let healthAfter = BorrowEngine.getHealth(loans, margin, accounts, reserved, user, priceLookup);
    let event : Types.LiquidationEvent = {
      user;
      debtToken        = primDebtToken;
      debtRepaid       = primDebtRepaid;
      debtRepaidUsd    = totDebtRepaidUsd;
      collateralToken  = primCollToken;
      collateralSeized = primCollSeized;
      proceedsUsd      = totProceedsUsd;
      penaltyUsd       = if (totProceedsUsd > totDebtRepaidUsd) { totProceedsUsd - totDebtRepaidUsd } else { 0 };
      healthBefore     = healthBefore.healthRatio;
      healthAfter      = healthAfter.healthRatio;
      timestamp        = now;
    };
    // Still liquidatable after exhausting collateral → insolvent (Phase 4
    // insurance-fund socialisation). Otherwise a successful (possibly
    // partial-to-target) close.
    if (healthAfter.isLiquidatable) {
      #insolvent(event)
    } else {
      #liquidated(event)
    };
  };
};
