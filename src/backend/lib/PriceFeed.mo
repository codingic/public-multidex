import Array "mo:core/Array";
import Text "mo:core/Text";
import Float "mo:core/Float";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Option "mo:core/Option";

// PriceFeed.mo — multi-source external price aggregation.
//
// Architecture:
//   main.mo configures a set of `Source`s per asset (BTC, ETH, SOL, ICP),
//   issues parallel non-replicated HTTPS outcalls to each, and hands
//   the responses to `extractFromBody` here. A fleet of `Reading`s is
//   then fed through `aggregate` to produce a robust price estimate
//   (median with 2σ outlier rejection). The resulting `Aggregate` is
//   written into the AMM pool's refPrice.
//
// Why non-replicated outcalls matter for this module:
//   - Each call runs on one replica, not all 13/34, so response bodies
//     don't have to be deterministic across replicas. That lets us use
//     sources whose bodies include timestamps, nonces, or request IDs
//     (Coinpaprika, Pyth Hermes).
//   - Cost is currently the same as replicated per-call but the plan
//     of record is that non-replicated will become ~N× cheaper.
//   - Latency is currently 2-10× worse on non-replicated (a known
//     beta artifact being fixed); on par after the fix.
//
// This module is all pure functions — no outcalls, no state. main.mo
// does the I/O; we do the math.

module {

  public type Asset = Text; // "BTC", "ETH", "SOL", "ICP"

  // Per-source response shape. Keep this enum small and extend it as
  // we add providers; each variant maps to a concrete extractor below.
  public type SourceKind = {
    #coinbase;        // {"data":{"amount":"X.XX","base":"BTC","currency":"USD"}}
    #coingecko;       // {"bitcoin":{"usd":XXXXX}}
    #coinpaprika;     // {"quotes":{"USD":{"price":X.XX, ...}}}
    #krakenLike;      // Kraken — {"result":{"XBTUSDT":{"c":["X.XX", ...]}}}
    #okx;             // {"code":"0","data":[{"instId":"ICP-USDT","last":"X.XX", ...}]}
    #kucoin;          // {"code":"200000","data":{"price":"X.XX", ...}}
    #cryptocompare;   // {"USD":X.XX}
    #htx;             // HTX (Huobi) — {"status":"ok","tick":{...,"close":X.XX, ...}}
    #cryptocom;       // Crypto.com — {"result":{"data":[{"i":"BTC_USDT","a" : "X.XX", ...}]}}
    #binance;         // {"symbol":"BTCUSDT","price":"X.XX"}
  };

  // A named price-source configuration. urlTemplate has a `{asset}`
  // placeholder that `buildUrl` substitutes with the per-source symbol
  // (so we can map our internal "BTC" to Coingecko's "bitcoin", etc.).
  public type Source = {
    id               : Text;
    urlTemplate      : Text;
    kind             : SourceKind;
    maxResponseBytes : Nat64;
  };

  // One fetched sample from one source. Written by main.mo after a
  // successful outcall (or a failed one with ok=false).
  public type Reading = {
    sourceId    : Text;
    asset       : Asset;
    price       : Float;
    fetchedAtNs : Int;
    ok          : Bool;
    errMessage  : ?Text;
  };

  // Result of aggregating many readings for a single asset. `stddevBps`
  // is relative to the final price and lets callers refuse to update
  // the AMM when the sources disagree wildly.
  public type Aggregate = {
    asset       : Asset;
    price       : Float;
    sourceCount : Nat;   // number of readings that survived filtering
    stddevBps   : Float;
    timestamp   : Int;
    readings    : [Reading];
  };

  // Textual tag for a SourceKind. The public API exposes THIS instead of the
  // raw variant: a variant in a public return type makes every added provider
  // a breaking interface change (the upgrade's Candid gate rejects a grown
  // variant — old clients can't decode new tags). Text grows freely.
  public func kindText(kind : SourceKind) : Text {
    switch (kind) {
      case (#coinbase)      { "coinbase" };
      case (#coingecko)     { "coingecko" };
      case (#coinpaprika)   { "coinpaprika" };
      case (#krakenLike)    { "kraken" };
      case (#okx)           { "okx" };
      case (#kucoin)        { "kucoin" };
      case (#cryptocompare) { "cryptocompare" };
      case (#htx)           { "htx" };
      case (#cryptocom)     { "cryptocom" };
      case (#binance)       { "binance" };
    };
  };

  // ── URL construction ──────────────────────────────────────────────

  public func assetSymbol(kind : SourceKind, asset : Asset) : Text {
    switch (kind) {
      case (#coingecko) {
        switch (asset) {
          case ("BTC") { "bitcoin" };
          case ("ETH") { "ethereum" };
          case ("SOL") { "solana" };
          case ("ICP") { "internet-computer" };
          case (a)     { a };
        };
      };
      case (#coinpaprika) {
        switch (asset) {
          case ("BTC") { "btc-bitcoin" };
          case ("ETH") { "eth-ethereum" };
          case ("SOL") { "sol-solana" };
          case ("ICP") { "icp-internet-computer" };
          case (a)     { a };
        };
      };
      case (#krakenLike) {
        // Kraken USD spot pairs. BTC is "XBT"; the result key may carry
        // legacy X/Z prefixes (e.g. XXBTZUSD) but the extractor scans for
        // the "c" array, so the pair param just has to be accepted.
        switch (asset) {
          case ("BTC") { "XBTUSD" };
          case (a)     { a # "USD" };  // ETHUSD, SOLUSD, ICPUSD
        };
      };
      case (#htx) {
        // HTX symbols are lowercase concatenated USDT pairs.
        switch (asset) {
          case ("BTC") { "btcusdt" };
          case ("ETH") { "ethusdt" };
          case ("SOL") { "solusdt" };
          case ("ICP") { "icpusdt" };
          case (a)     { a };
        };
      };
      case (#cryptocom) { asset # "_USDT" }; // BTC_USDT, ETH_USDT, SOL_USDT, ICP_USDT
      case (#binance)   { asset # "USDT" };  // BTCUSDT, ETHUSDT, SOLUSDT, ICPUSDT
      case (_) { asset }; // uppercase ticker works for Coinbase / OKX / KuCoin / CryptoCompare
    };
  };

  public func buildUrl(src : Source, asset : Asset) : Text {
    Text.replace(src.urlTemplate, #text "{asset}", assetSymbol(src.kind, asset));
  };

  // ── Aggregation ───────────────────────────────────────────────────

  func appendFloat(xs : [Float], x : Float) : [Float] {
    let n = xs.size();
    Array.tabulate<Float>(n + 1, func(i) { if (i < n) { xs[i] } else { x } });
  };

  public func median(xs : [Float]) : ?Float {
    let n = xs.size();
    if (n == 0) { return null };
    let sorted = Array.sort<Float>(xs, Float.compare);
    if (n % 2 == 1) { ?sorted[n / 2] }
    else { ?((sorted[n / 2 - 1] + sorted[n / 2]) / 2.0) };
  };

  public func mean(xs : [Float]) : ?Float {
    let n = xs.size();
    if (n == 0) { return null };
    var sum : Float = 0.0;
    for (x in xs.vals()) { sum += x };
    ?(sum / Float.fromInt(n));
  };

  // Sample stddev (Bessel-corrected). null if < 2 samples.
  public func stddev(xs : [Float]) : ?Float {
    let n = xs.size();
    if (n < 2) { return null };
    switch (mean(xs)) {
      case null { null };
      case (?m) {
        var s : Float = 0.0;
        for (x in xs.vals()) {
          let d = x - m;
          s += d * d;
        };
        ?Float.sqrt(s / Float.fromInt(n - 1));
      };
    };
  };

  // The samples robustMedian keeps: everything within ±sigmaTrim·stddev of
  // the initial median. Under 3 samples (or a degenerate stddev) there's
  // nothing to trim against — the full set comes back; a trim that would
  // discard EVERYTHING also returns the full set (all-outliers means "no
  // agreement", and the caller's quality floor should judge that on the
  // honest, untrimmed dispersion rather than an empty set).
  public func trimOutliers(xs : [Float], sigmaTrim : Float) : [Float] {
    let n = xs.size();
    if (n < 3) { return xs };
    let m = switch (median(xs)) { case null { return xs }; case (?v) { v } };
    let sd = switch (stddev(xs)) { case null { return xs }; case (?v) { v } };
    if (sd < 0.0000001) { return xs };
    let lo = m - sigmaTrim * sd;
    let hi = m + sigmaTrim * sd;
    var kept : [Float] = [];
    for (x in xs.vals()) {
      if (x >= lo and x <= hi) { kept := appendFloat(kept, x) };
    };
    if (kept.size() == 0) { return xs };
    kept;
  };

  // Robust median: drop samples more than `sigmaTrim * stddev` from the
  // initial median, then take the median of what's left. Falls back to
  // the simple median when there aren't enough samples (<3) to trust
  // the stddev computation.
  public func robustMedian(xs : [Float], sigmaTrim : Float) : ?Float {
    median(trimOutliers(xs, sigmaTrim));
  };

  // Aggregate a fleet of readings into a price + quality signal. BOTH the
  // price and the dispersion are computed over the OUTLIER-TRIMMED sample
  // set (±2σ of the initial median). They must share the sample set: one
  // venue printing an off-cluster price (thin market, stale cache) used to
  // blow `stddevBps` past the caller's quality gate and veto the aggregate
  // WHOLESALE — while the robust median being vetoed had already excluded
  // that very venue. (Live incident: 7 ICP sources, six at $2.27–2.279 and
  // one at $2.31 → untrimmed stddev 58bps > the 50bps gate → refPrice frozen
  // for hours on a perfectly priceable market.) `sourceCount` now matches
  // its declared contract — readings that SURVIVED filtering — so the
  // ≥minSources floor judges the trimmed set too. The full raw fleet stays
  // in `readings` for observability.
  public func aggregate(asset : Asset, readings : [Reading], now : Int) : Aggregate {
    var okPrices : [Float] = [];
    for (r in readings.vals()) {
      // Finite-magnitude gate. A rogue source printing a ~400-digit number
      // parses to Float `inf`, and `inf > 0.0` is true — so it would slip into
      // the sample, drive trimOutliers' mean/stddev to inf/NaN, widen the trim
      // band to ±inf (the outlier is then KEPT, defeating the very trim meant to
      // drop it), and blow stddevBps to inf/NaN so the caller's quality gate
      // vetoes every tick. `< 1e15` rejects inf AND NaN (both comparisons are
      // false) while sitting far above any real asset price. Fixes the
      // one-rogue-source feed-freeze.
      if (r.ok and r.price > 0.0 and r.price < 1.0e15) { okPrices := appendFloat(okPrices, r.price) };
    };
    let kept = trimOutliers(okPrices, 2.0);
    let finalPrice = Option.get(median(kept), 0.0);
    let sd = Option.get(stddev(kept), 0.0);
    let stddevBps = if (finalPrice > 0.0) { sd / finalPrice * 10000.0 } else { 0.0 };
    {
      asset;
      price       = finalPrice;
      sourceCount = kept.size();
      stddevBps;
      timestamp   = now;
      readings;
    };
  };

  // ── Body parsing ──────────────────────────────────────────────────
  // Every source response is a JSON-ish body where we only care about
  // a single number. Rather than pull in a full JSON parser we look
  // for a known key prefix (e.g. `"amount":"`) and read the leading
  // numeric token that follows. Brittle against upstream schema
  // changes but trivially auditable per-source.

  // Parse a leading signed decimal from `t`, skipping leading whitespace.
  // Stops at the first non-numeric character. Returns null if no digits.
  public func parseLeadingFloat(t : Text) : ?Float {
    var intPart  : Nat = 0;
    var fracPart : Nat = 0;
    var fracLen  : Nat = 0;
    var sawDot   = false;
    var sawDigit = false;
    var negative = false;
    var sawNonWs = false;
    label lp for (c in t.chars()) {
      if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
        if (sawNonWs) { break lp };
      } else {
        sawNonWs := true;
        if (c == '-' and not sawDigit and not sawDot) {
          negative := true;
        } else if (Char.isDigit(c)) {
          let code : Nat = Nat32.toNat(Char.toNat32(c) - 48);
          if (sawDot) {
            fracPart := fracPart * 10 + code;
            fracLen += 1;
          } else {
            intPart := intPart * 10 + code;
          };
          sawDigit := true;
        } else if (c == '.' and not sawDot and sawDigit) {
          sawDot := true;
        } else {
          break lp;
        };
      };
    };
    if (not sawDigit) { return null };
    var result : Float = Float.fromInt(intPart);
    if (fracLen > 0) {
      var denom : Float = 1.0;
      var i : Nat = 0;
      while (i < fracLen) { denom *= 10.0; i += 1 };
      result += Float.fromInt(fracPart) / denom;
    };
    if (negative) { result := -result };
    ?result;
  };

  // First occurrence of `needle` in `haystack`; returns the substring
  // after it, or null if not found.
  public func findAfter(haystack : Text, needle : Text) : ?Text {
    let parts = Text.split(haystack, #text needle);
    ignore parts.next();
    parts.next();
  };

  // Numeric value following `key` in a JSON-ish body, tolerant of the
  // punctuation between key and value: arbitrary whitespace around the
  // colon and an optionally-quoted value. Handles both the compact
  // (`"close":64046.03`, `"a":"2.29"`) and pretty-printed (`"a" : "2.29"`)
  // bodies providers emit — Crypto.com's gateway pretty-prints, and a
  // fixed `"key":"` needle would silently stop matching if a provider
  // flipped formatting.
  public func numberAfterKey(haystack : Text, key : Text) : ?Float {
    switch (findAfter(haystack, key)) {
      case null { null };
      case (?rest) {
        let value = Text.trimStart(rest, #predicate (func(c : Char) : Bool {
          c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ':' or c == '\"'
        }));
        parseLeadingFloat(value);
      };
    };
  };

  public func extractFromBody(kind : SourceKind, body : Blob, asset : Asset) : ?Float {
    let _ = asset; // reserved for per-asset dispatch in future extractors
    let text = switch (Text.decodeUtf8(body)) {
      case null { return null };
      case (?t) { t };
    };
    switch (kind) {
      case (#coinbase) {
        switch (findAfter(text, "\"amount\":\"")) {
          case null { null };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#coingecko) {
        switch (findAfter(text, "\"usd\":")) {
          case null { null };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#coinpaprika) {
        switch (findAfter(text, "\"USD\":{\"price\":")) {
          case null {
            switch (findAfter(text, "\"price\":")) {
              case null { null };
              case (?rest) { parseLeadingFloat(rest) };
            };
          };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#krakenLike) {
        // {"result":{"PAIRUSD":{"c":["X.XX","VOL"], ...}}}
        switch (findAfter(text, "\"c\":[\"")) {
          case null { null };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#okx) {
        // {"code":"0","data":[{"instId":"ICP-USDT","last":"2.779", ...}]}
        switch (findAfter(text, "\"last\":\"")) {
          case null { null };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#kucoin) {
        // {"code":"200000","data":{"time":..,"price":"2.777", ...}} — first
        // "price" is the last-trade price (before bestBid/bestAsk).
        switch (findAfter(text, "\"price\":\"")) {
          case null { null };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#cryptocompare) {
        // {"USD":2.774} — value is a bare number, not a quoted string.
        switch (findAfter(text, "\"USD\":")) {
          case null { null };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#htx) {
        // {"status":"ok","tick":{"open":63167.0,"close":64046.03, ...}} —
        // "close" is the last trade price, a bare number, and appears once
        // (only inside tick). Error bodies have no "close" → null → ok=false.
        numberAfterKey(text, "\"close\"");
      };
      case (#cryptocom) {
        // {"result":{"data":[{"i":"BTC_USDT","h":"…","l":"…","a":"64084.20",…}]}}
        // — "a" is the latest trade price. The gateway pretty-prints
        // (`"a" : "64084.20"`), which numberAfterKey absorbs. No other key or
        // value in the body contains the 3-char sequence `"a"`, so the first
        // hit is the price.
        numberAfterKey(text, "\"a\"");
      };
      case (#binance) {
        // {"symbol":"BTCUSDT","price":"64158.01000000"} — the only "price".
        numberAfterKey(text, "\"price\"");
      };
    };
  };
};
