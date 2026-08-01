// xrc-mock — a DEV-ONLY stand-in for the IC exchange-rate canister (XRC).
//
// Purpose (docs/oracle-xrc-fallback-design.md): the real XRC lives only on
// mainnet, so without a local target the DEX's anchor-fetch path (cycles
// attachment, candid decode including the `class_` ↔ `class` keyword escape,
// decimals → e8 conversion) would first execute on a value-bearing deploy.
// cold_start wires the DEX at this mock via setXrcCanister; tests drive rates
// with setRate and trigger fetches with adminRefreshXrcAnchors.
//
// Fidelity notes (mirrors dfinity/exchange-rate-canister where it matters):
//   • same candid shape as xrc.did (single method, same records/variants);
//   • rejects the anonymous principal (AnonymousPrincipalNotAllowed);
//   • demands the 1B-cycle request fee, accepts only the 20M base fee
//     (the remainder refunds automatically, like a cache hit);
//   • normalizes a missing timestamp to ((now − 30s) / 60) × 60 — XRC's
//     verified freshness rule (utils.rs), so callers see realistic lag;
//   • unknown symbols → CryptoBaseAssetNotFound.
// It does NOT simulate Pending/RateLimited (deterministic tests don't want
// them; the DEX's catch-all tolerates every error variant regardless).

import Map "mo:core/Map";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Time "mo:core/Time";
import Cycles "mo:core/Cycles";
import Int "mo:core/Int";

actor {
  public type AssetClass = { #Cryptocurrency; #FiatCurrency };
  public type Asset = { symbol : Text; class_ : AssetClass };
  public type GetExchangeRateRequest = {
    base_asset : Asset;
    quote_asset : Asset;
    timestamp : ?Nat64;
  };
  public type ExchangeRateMetadata = {
    decimals : Nat32;
    base_asset_num_queried_sources : Nat64;
    base_asset_num_received_rates : Nat64;
    quote_asset_num_queried_sources : Nat64;
    quote_asset_num_received_rates : Nat64;
    standard_deviation : Nat64;
    forex_timestamp : ?Nat64;
  };
  public type ExchangeRate = {
    base_asset : Asset;
    quote_asset : Asset;
    timestamp : Nat64;
    rate : Nat64;
    metadata : ExchangeRateMetadata;
  };
  public type ExchangeRateError = {
    #AnonymousPrincipalNotAllowed;
    #Pending;
    #CryptoBaseAssetNotFound;
    #CryptoQuoteAssetNotFound;
    #StablecoinRateNotFound;
    #StablecoinRateTooFewRates;
    #StablecoinRateZeroRate;
    #ForexInvalidTimestamp;
    #ForexBaseAssetNotFound;
    #ForexQuoteAssetNotFound;
    #ForexAssetsNotFound;
    #RateLimited;
    #NotEnoughCycles;
    #FailedToAcceptCycles;
    #InconsistentRatesReceived;
    #Other : { code : Nat32; description : Text };
  };
  public type GetExchangeRateResult = { #Ok : ExchangeRate; #Err : ExchangeRateError };

  // symbol → rate expressed at DECIMALS (e.g. 9 decimals: $2.97 = 2_970_000_000).
  let rates = Map.empty<Text, Nat>();
  transient let DECIMALS : Nat32 = 9;
  transient let REQUEST_FEE : Nat = 1_000_000_000;
  transient let BASE_FEE : Nat = 20_000_000;

  // Dev control: set/clear the served rate for a symbol.
  public shared func setRate(symbol : Text, rate : ?Nat) : async () {
    switch (rate) {
      case (?r) { Map.add(rates, Text.compare, symbol, r) };
      case null { ignore Map.delete(rates, Text.compare, symbol) };
    };
  };

  public shared (msg) func get_exchange_rate(req : GetExchangeRateRequest) : async GetExchangeRateResult {
    if (Principal.isAnonymous(msg.caller)) { return #Err(#AnonymousPrincipalNotAllowed) };
    if (Cycles.available() < REQUEST_FEE) { return #Err(#NotEnoughCycles) };
    ignore Cycles.accept<system>(BASE_FEE);   // keep the base fee; the rest refunds
    // XRC's verified normalization: no timestamp → (now − 30s) floored to the minute.
    let nowSecs = Int.abs(Time.now()) / 1_000_000_000;
    let normalized : Nat64 = switch (req.timestamp) {
      case (?t) { (t / 60) * 60 };
      case null { Nat64.fromNat((((if (nowSecs >= 30) { nowSecs - 30 } else { 0 }) / 60) * 60)) };
    };
    switch (Map.get(rates, Text.compare, req.base_asset.symbol)) {
      case null { #Err(#CryptoBaseAssetNotFound) };
      case (?r) {
        #Ok({
          base_asset = req.base_asset;
          quote_asset = req.quote_asset;
          timestamp = normalized;
          rate = Nat64.fromNat(r);
          metadata = {
            decimals = DECIMALS;
            base_asset_num_queried_sources = 6;
            base_asset_num_received_rates = 5;
            quote_asset_num_queried_sources = 6;
            quote_asset_num_received_rates = 5;
            standard_deviation = 0;
            forex_timestamp = null;
          };
        });
      };
    };
  };
}
