// MarginEngine.mo — cross-margin account state and collateral valuation.
// All money is integer base units at 10^8 (see lib/Fixed.mo). Weighted
// collateral = Σ_t (balance_t × refPrice_t × LTV_t), each product via Fixed.mul
// rounding DOWN — undervaluing collateral can only make a liquidation MORE
// likely, never less, so it's the protocol-safe direction.

import Map "mo:core/Map";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Types "Types";
import Accounts "Accounts";
import Fixed "Fixed";

module {

  public type MarginState = Map.Map<Text, Types.MarginAccount>;

  // Price oracle callback: integer price at 10^8, null when unknown (treated as
  // 0 collateral — safer than blocking).
  public type PriceLookup = Types.TokenId -> ?Nat;

  public func emptyState() : MarginState {
    Map.empty<Text, Types.MarginAccount>();
  };

  public func get(state : MarginState, user : Principal) : ?Types.MarginAccount {
    Map.get(state, Text.compare, Principal.toText(user));
  };

  public func hasAccount(state : MarginState, user : Principal) : Bool {
    switch (get(state, user)) { case (?_) { true }; case null { false } };
  };

  // ICPUSD is the quote and trades at 1.0 (= SCALE). Everything else defers to
  // the caller's priceLookup; unknown → 0.
  public func priceOf(token : Types.TokenId, priceLookup : PriceLookup) : Nat {
    if (token == Types.QUOTE_TOKEN) { return Fixed.SCALE };
    switch (priceLookup(token)) {
      case (?p) { p };
      case null { 0 };
    };
  };

  // Reserved-balance callback: funds moved balance→reserved for in-flight
  // pending matches. Still the user's collateral mid-settlement, so counted.
  public type ReservedLookup = (Principal, Types.TokenId) -> Nat;

  // Per-token cross-margin collateral valuation across the user's WHOLE holdings
  // (balance + reserved). Returns [] for users with no margin account.
  public func valuations(
    state       : MarginState,
    accounts    : Accounts.AccountState,
    reserved    : ReservedLookup,
    user        : Principal,
    priceLookup : PriceLookup,
  ) : [Types.CollateralValuation] {
    switch (get(state, user)) { case (?_) { }; case null { return [] } };
    let out = List.empty<Types.CollateralValuation>();
    for (token in Types.MARGIN_COLLATERAL_TOKENS.vals()) {
      let bal = Accounts.getBalance(accounts, user, token) + reserved(user, token);
      if (bal > 0) {
        let px  = priceOf(token, priceLookup);
        let ltv = switch (Types.marginLTV(token)) { case (?x) { x }; case null { 0 } };
        // bal × px × ltv, all 10^8-scaled; round DOWN (conservative).
        let contribUsd = Fixed.mul(Fixed.mul(bal, px, false), ltv, false);
        List.add(out, { token; balance = bal; refPrice = px; ltv; contribUsd });
      };
    };
    Iter.toArray(List.values(out));
  };

  // Sum of contribUsd — the LTV-weighted collateral backing the user's debt.
  public func collateralValueUsd(vals : [Types.CollateralValuation]) : Nat {
    var sum : Nat = 0;
    for (v in vals.vals()) { sum += v.contribUsd };
    sum;
  };

  public func weightedCollateralUsd(
    state       : MarginState,
    accounts    : Accounts.AccountState,
    reserved    : ReservedLookup,
    user        : Principal,
    priceLookup : PriceLookup,
  ) : Nat {
    collateralValueUsd(valuations(state, accounts, reserved, user, priceLookup));
  };

  // ── Cross-market bid cap = availableCash × CROSS_MARKET_BID_FACTOR ──
  // Round DOWN → a tighter cap (against the user).
  public func computeBidCap(availableCash : Nat) : Nat {
    Fixed.mul(availableCash, Types.CROSS_MARKET_BID_FACTOR, false)
  };

  public func bidCapFor(
    state            : MarginState,
    accounts         : Accounts.AccountState,
    availableBalance : (Principal, Types.TokenId) -> Nat,
    user             : Principal,
    priceLookup      : PriceLookup,
  ) : Nat {
    let _ = state; let _ = accounts; let _ = priceLookup;
    computeBidCap(availableBalance(user, Types.QUOTE_TOKEN));
  };

  // ── Open / close ───────────────────────────────────────────────
  public func open(
    state : MarginState,
    user  : Principal,
    now   : Int,
  ) : { #ok : Types.MarginAccount; #err : Text } {
    let key = Principal.toText(user);
    switch (Map.get(state, Text.compare, key)) {
      case (?_) { #err("Margin account already open") };
      case null {
        let m : Types.MarginAccount = { openedAt = now };
        Map.add(state, Text.compare, key, m);
        #ok(m)
      };
    };
  };

  // Close requires zero outstanding debt (else releasing the account would
  // un-collateralise the loan). The caller supplies current total debt in USD.
  public func close(
    state   : MarginState,
    user    : Principal,
    debtUsd : Nat,
  ) : { #ok; #err : Text } {
    let key = Principal.toText(user);
    switch (Map.get(state, Text.compare, key)) {
      case null { #err("No margin account open") };
      case (?_) {
        if (debtUsd > 0) {
          return #err(
            "Repay your outstanding loans before closing — you still owe " #
            Nat.toText(debtUsd) # " base-unit USD of debt."
          );
        };
        ignore Map.delete(state, Text.compare, key);
        #ok
      };
    };
  };
};
