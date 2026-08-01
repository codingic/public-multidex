// Pure-function tests for PriceFeed. Exercises the body parsers
// (the bit that's fragile to upstream JSON changes) and the
// statistical aggregation (median, robustMedian) that drives oracle
// pricing decisions.

import PriceFeed "../src/backend/lib/PriceFeed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Float "mo:core/Float";
import Text "mo:core/Text";

func close(name : Text, actual : Float, expected : Float, tol : Float) {
  if (Float.abs(actual - expected) > tol) {
    Runtime.trap("FAIL: " # name # " — expected " # debug_show expected # " got " # debug_show actual);
  };
  Debug.print("  ✓ " # name);
};

func optClose(name : Text, actual : ?Float, expected : Float, tol : Float) {
  switch (actual) {
    case null { Runtime.trap("FAIL: " # name # " — got null") };
    case (?v) { close(name, v, expected, tol) };
  };
};

func optNull(name : Text, actual : ?Float) {
  switch (actual) {
    case null { Debug.print("  ✓ " # name) };
    case (?v) { Runtime.trap("FAIL: " # name # " — expected null, got " # debug_show v) };
  };
};

Debug.print("── PriceFeed.test ──");

// ── parseLeadingFloat ────────────────────────────────────────────
// Takes a Text and parses the first decimal number. Skips leading
// whitespace, accepts optional `-`, integer + fractional parts.

optClose("parses simple int",       PriceFeed.parseLeadingFloat("75000"),       75000.0, 0.0001);
optClose("parses with decimal",     PriceFeed.parseLeadingFloat("75000.5"),     75000.5, 0.0001);
optClose("parses negative",         PriceFeed.parseLeadingFloat("-3.14"),       -3.14,   0.0001);
optClose("parses with leading WS",  PriceFeed.parseLeadingFloat("   75000"),    75000.0, 0.0001);
optClose("stops at non-digit",      PriceFeed.parseLeadingFloat("75000.5xyz"),  75000.5, 0.0001);
optClose("stops at comma",          PriceFeed.parseLeadingFloat("123,456"),     123.0,   0.0001);
optClose("zero",                    PriceFeed.parseLeadingFloat("0.0"),         0.0,     0.0001);

// Failure modes
optNull("rejects empty",            PriceFeed.parseLeadingFloat(""));
optNull("rejects all whitespace",   PriceFeed.parseLeadingFloat("    "));
optNull("rejects letters only",     PriceFeed.parseLeadingFloat("abc"));

// ── findAfter ────────────────────────────────────────────────────
// Returns the substring after the first occurrence of `needle`.
// Used by extractors to locate JSON-field-value boundaries.

func optEq(name : Text, actual : ?Text, expected : Text) {
  switch (actual) {
    case null { Runtime.trap("FAIL: " # name # " — got null") };
    case (?v) {
      if (v != expected) {
        Runtime.trap("FAIL: " # name # " — expected '" # expected # "' got '" # v # "'");
      };
      Debug.print("  ✓ " # name);
    };
  };
};

optEq("findAfter basic",
      PriceFeed.findAfter("{\"price\":75000}", "\"price\":"),
      "75000}");

optEq("findAfter at start",
      PriceFeed.findAfter("hello world", "hello "),
      "world");

switch (PriceFeed.findAfter("no match here", "needle")) {
  case null { Debug.print("  ✓ findAfter returns null when needle absent") };
  case (?_) { Runtime.trap("FAIL: should not have matched") };
};

// ── median / mean / stddev ───────────────────────────────────────

optClose("median of odd-length sorted",   PriceFeed.median([1.0, 2.0, 3.0]),         2.0, 0.0001);
optClose("median of even-length sorted",  PriceFeed.median([1.0, 2.0, 3.0, 4.0]),    2.5, 0.0001);
optClose("median of unsorted",            PriceFeed.median([5.0, 1.0, 3.0]),         3.0, 0.0001);
optClose("median single value",           PriceFeed.median([42.0]),                  42.0, 0.0001);
optNull("median of empty array",          PriceFeed.median([]));

optClose("mean basic",                    PriceFeed.mean([1.0, 2.0, 3.0]),           2.0, 0.0001);
optNull("mean of empty array",            PriceFeed.mean([]));

// stddev: sample stddev (Bessel-corrected). For [2,4,4,4,5,5,7,9],
// expected sample stddev ≈ 2.138 (compared to population 2.000).
optClose("stddev basic",
         PriceFeed.stddev([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]),
         2.13809, 0.001);
optNull("stddev of single value",         PriceFeed.stddev([42.0]));
optNull("stddev of empty",                PriceFeed.stddev([]));

// ── robustMedian ─────────────────────────────────────────────────
// Drops samples outside ±sigmaTrim*stddev from initial median, then
// re-medians. Used for oracle aggregation to reject outlier feeds.

// 5 values clustered around 100 with one outlier at 200 — outlier
// should be removed before computing the final median.
optClose("robustMedian rejects outlier",
         PriceFeed.robustMedian([99.0, 100.0, 101.0, 100.5, 200.0], 2.0),
         100.0, 0.5);

// Falls back to plain median for short series (<3 samples).
optClose("robustMedian small sample falls through",
         PriceFeed.robustMedian([100.0, 102.0], 2.0),
         101.0, 0.0001);

optNull("robustMedian of empty",          PriceFeed.robustMedian([], 2.0));

// ── extractFromBody ──────────────────────────────────────────────
// Format-specific extraction. These bodies are real shapes the
// providers return; if a provider changes their JSON shape, these
// tests fail and we know to update the parser.

let coinbaseBody = Text.encodeUtf8("{\"data\":{\"amount\":\"75517.39\",\"base\":\"BTC\",\"currency\":\"USD\"}}");
optClose("coinbase body extract",
         PriceFeed.extractFromBody(#coinbase, coinbaseBody, "BTC"),
         75517.39, 0.001);

let coingeckoBody = Text.encodeUtf8("{\"bitcoin\":{\"usd\":75490}}");
optClose("coingecko body extract",
         PriceFeed.extractFromBody(#coingecko, coingeckoBody, "BTC"),
         75490.0, 0.001);

let coinpaprikaBody = Text.encodeUtf8(
  "{\"id\":\"btc-bitcoin\",\"quotes\":{\"USD\":{\"price\":75501.123,\"volume_24h\":1.0}}}"
);
optClose("coinpaprika body extract",
         PriceFeed.extractFromBody(#coinpaprika, coinpaprikaBody, "BTC"),
         75501.123, 0.001);

// Kraken (#krakenLike): last trade is c[0]. The result key carries legacy
// X/Z prefixes for BTC/ETH, but the extractor scans for the "c" array so the
// key name is irrelevant — verify both a plain and a prefixed key.
let krakenIcp = Text.encodeUtf8(
  "{\"error\":[],\"result\":{\"ICPUSD\":{\"a\":[\"2.77600\",\"1\",\"1.0\"],\"b\":[\"2.77400\",\"2\",\"2.0\"],\"c\":[\"2.77500\",\"0.5\"],\"v\":[\"1\",\"2\"]}}}"
);
optClose("kraken ICP body extract",
         PriceFeed.extractFromBody(#krakenLike, krakenIcp, "ICP"),
         2.775, 0.0001);
let krakenBtc = Text.encodeUtf8(
  "{\"error\":[],\"result\":{\"XXBTZUSD\":{\"a\":[\"63100.0\",\"1\"],\"c\":[\"63108.62\",\"0.1\"]}}}"
);
optClose("kraken BTC body extract (legacy XXBTZUSD key)",
         PriceFeed.extractFromBody(#krakenLike, krakenBtc, "BTC"),
         63108.62, 0.001);

// OKX: data[0].last
let okxBody = Text.encodeUtf8(
  "{\"code\":\"0\",\"msg\":\"\",\"data\":[{\"instType\":\"SPOT\",\"instId\":\"ICP-USDT\",\"last\":\"2.779\",\"lastSz\":\"0.15\",\"askPx\":\"2.779\"}]}"
);
optClose("okx body extract", PriceFeed.extractFromBody(#okx, okxBody, "ICP"), 2.779, 0.0001);

// KuCoin: data.price (the first "price" field, ahead of bestBid/bestAsk)
let kucoinBody = Text.encodeUtf8(
  "{\"code\":\"200000\",\"data\":{\"time\":1780597674154,\"sequence\":\"33734\",\"price\":\"2.777\",\"size\":\"0.35\",\"bestBid\":\"2.777\",\"bestAsk\":\"2.779\"}}"
);
optClose("kucoin body extract", PriceFeed.extractFromBody(#kucoin, kucoinBody, "ICP"), 2.777, 0.0001);

// CryptoCompare: {"USD":x} — bare number
let ccBody = Text.encodeUtf8("{\"USD\":2.774}");
optClose("cryptocompare body extract", PriceFeed.extractFromBody(#cryptocompare, ccBody, "ICP"), 2.774, 0.0001);

// HTX (Huobi): tick.close is the last trade, a bare number. Body shape
// captured live 2026-07-11 from /market/detail/merged?symbol=icpusdt.
let htxBody = Text.encodeUtf8(
  "{\"ch\":\"market.icpusdt.detail.merged\",\"status\":\"ok\",\"ts\":1783725182735,\"tick\":{\"id\":8185240693,\"version\":8185240693,\"open\":2.33,\"close\":2.29,\"low\":2.27,\"high\":2.38,\"amount\":154427.70414743637,\"vol\":359209.31292931,\"count\":4114}}"
);
optClose("htx body extract", PriceFeed.extractFromBody(#htx, htxBody, "ICP"), 2.29, 0.0001);
// HTX error body has no "close" → parse must fail, not return garbage.
let htxErr = Text.encodeUtf8("{\"status\":\"error\",\"err-code\":\"invalid-parameter\",\"err-msg\":\"invalid symbol\"}");
optNull("htx error body → null", PriceFeed.extractFromBody(#htx, htxErr, "ICP"));

// Crypto.com: result.data[0].a is the latest trade. Their gateway
// PRETTY-PRINTS (`"a" : "2.2965"`) — captured live 2026-07-11 — and the
// extractor must also survive a compact rendering if they change it.
let cryptocomPretty = Text.encodeUtf8(
  "{\n  \"id\" : -1,\n  \"method\" : \"public/get-tickers\",\n  \"code\" : 0,\n  \"result\" : {\n    \"data\" : [ {\n      \"i\" : \"ICP_USDT\",\n      \"h\" : \"2.3780\",\n      \"l\" : \"2.2782\",\n      \"a\" : \"2.2965\",\n      \"v\" : \"4821.00\",\n      \"vv\" : \"11151.16\",\n      \"c\" : \"-0.0211\"\n    } ]\n  }\n}"
);
optClose("crypto.com pretty-printed body extract",
         PriceFeed.extractFromBody(#cryptocom, cryptocomPretty, "ICP"),
         2.2965, 0.0001);
let cryptocomCompact = Text.encodeUtf8(
  "{\"id\":-1,\"method\":\"public/get-tickers\",\"code\":0,\"result\":{\"data\":[{\"i\":\"BTC_USDT\",\"h\":\"64697.99\",\"l\":\"62918.51\",\"a\":\"64084.20\",\"v\":\"1788.9712\"}]}}"
);
optClose("crypto.com compact body extract",
         PriceFeed.extractFromBody(#cryptocom, cryptocomCompact, "BTC"),
         64084.20, 0.0001);

// Binance: flat {"symbol","price"} pair — captured live 2026-07-11.
let binanceBody = Text.encodeUtf8("{\"symbol\":\"BTCUSDT\",\"price\":\"64158.01000000\"}");
optClose("binance body extract",
         PriceFeed.extractFromBody(#binance, binanceBody, "BTC"),
         64158.01, 0.0001);

// numberAfterKey: the punctuation-tolerant extractor behind the two above.
optClose("numberAfterKey compact bare",   PriceFeed.numberAfterKey("{\"close\":64046.03}", "\"close\""), 64046.03, 0.0001);
optClose("numberAfterKey pretty quoted",  PriceFeed.numberAfterKey("{\"a\" : \"2.29\"}", "\"a\""),        2.29,     0.0001);
optNull("numberAfterKey missing key", PriceFeed.numberAfterKey("{\"b\":1}", "\"a\""));
optNull("numberAfterKey non-numeric value", PriceFeed.numberAfterKey("{\"a\":\"ok\"}", "\"a\""));

// kindText: the candid-stable tag the public API exposes instead of the
// SourceKind variant. Spot-check the mapping, including the one rename
// (#krakenLike → "kraken").
func eqText(name : Text, actual : Text, expected : Text) {
  if (actual != expected) {
    Runtime.trap("FAIL: " # name # " — expected '" # expected # "' got '" # actual # "'");
  };
  Debug.print("  ✓ " # name);
};
eqText("kindText binance",    PriceFeed.kindText(#binance),    "binance");
eqText("kindText krakenLike", PriceFeed.kindText(#krakenLike), "kraken");
eqText("kindText htx",        PriceFeed.kindText(#htx),        "htx");
eqText("kindText cryptocom",  PriceFeed.kindText(#cryptocom),  "cryptocom");

// Garbage body returns null cleanly.
let garbage = Text.encodeUtf8("not json at all");
switch (PriceFeed.extractFromBody(#coinbase, garbage, "BTC")) {
  case null { Debug.print("  ✓ extractFromBody handles garbage gracefully") };
  case (?v) { Runtime.trap("FAIL: garbage body returned " # debug_show v) };
};

// ── aggregate ────────────────────────────────────────────────────
// Builds an Aggregate from a vec of Reading. Mixes ok/!ok readings.

let readings : [PriceFeed.Reading] = [
  { sourceId = "a"; asset = "BTC"; price = 75000.0; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "b"; asset = "BTC"; price = 75100.0; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "c"; asset = "BTC"; price = 0.0;     fetchedAtNs = 0; ok = false; errMessage = ?"timeout" },
  { sourceId = "d"; asset = "BTC"; price = 75050.0; fetchedAtNs = 0; ok = true;  errMessage = null },
];
let agg = PriceFeed.aggregate("BTC", readings, 1_000_000_000_000);
close("aggregate price ≈ median of OK readings", agg.price, 75050.0, 1.0);

if (agg.sourceCount != 3) {
  Runtime.trap("FAIL: agg.sourceCount expected 3, got " # debug_show agg.sourceCount);
};
Debug.print("  ✓ aggregate.sourceCount = 3 (the !ok one excluded)");

if (agg.stddevBps <= 0.0) {
  Runtime.trap("FAIL: expected non-zero stddevBps for varied readings");
};
Debug.print("  ✓ aggregate.stddevBps > 0 with varied readings");

// ── One-outlier veto regression (live incident, 2026-07-12) ───────
// Seven ICP sources: six clustered $2.27–2.279 and crypto.com printing
// $2.3104 (~1.5% high on a thin market). The UNTRIMMED stddev was
// 58bps — over main.mo's 50bps quality gate — so the aggregate was
// vetoed wholesale every tick and the refPrice froze for hours, even
// though the robust median being vetoed had already excluded the
// outlier. Price AND dispersion must be judged on the SAME trimmed set:
// one bad venue must cost a source, never the whole aggregate.
let icpIncident : [PriceFeed.Reading] = [
  { sourceId = "coinbase";  asset = "ICP"; price = 2.2765; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "okx";       asset = "ICP"; price = 2.277;  fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "kucoin";    asset = "ICP"; price = 2.278;  fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "coingecko"; asset = "ICP"; price = 0.0;    fetchedAtNs = 0; ok = false; errMessage = ?"http 429" },
  { sourceId = "htx";       asset = "ICP"; price = 2.27;   fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "cryptocom"; asset = "ICP"; price = 2.3104; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "binance";   asset = "ICP"; price = 2.279;  fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "kraken";    asset = "ICP"; price = 2.277;  fetchedAtNs = 0; ok = true;  errMessage = null },
];
let icpAgg = PriceFeed.aggregate("ICP", icpIncident, 1_000_000_000_000);
close("incident: price is the robust median", icpAgg.price, 2.277, 0.001);
if (icpAgg.sourceCount != 6) {
  Runtime.trap("FAIL: incident sourceCount expected 6 (7 ok − 1 trimmed outlier), got " # debug_show icpAgg.sourceCount);
};
Debug.print("  ✓ incident: sourceCount counts SURVIVORS (6 — outlier trimmed, 429 excluded)");
if (icpAgg.stddevBps > 50.0) {
  Runtime.trap("FAIL: incident stddevBps must clear the 50bps gate after trimming, got " # debug_show icpAgg.stddevBps);
};
Debug.print("  ✓ incident: trimmed stddevBps clears the 50bps quality gate (≈14bps)");

// trimOutliers edge cases: short sets and all-agreeing sets pass through;
// a trim that would discard everything falls back to the full set so the
// caller's floor judges honest dispersion, not an empty sample.
let trimmed = PriceFeed.trimOutliers([99.0, 100.0, 101.0, 100.5, 200.0], 2.0);
if (trimmed.size() != 4) {
  Runtime.trap("FAIL: trimOutliers expected to keep 4 of 5, got " # debug_show trimmed.size());
};
Debug.print("  ✓ trimOutliers keeps the 4-sample cluster, drops the 200.0 outlier");
if (PriceFeed.trimOutliers([100.0, 102.0], 2.0).size() != 2) {
  Runtime.trap("FAIL: trimOutliers must pass short sets through untouched");
};
Debug.print("  ✓ trimOutliers passes <3-sample sets through");
if (PriceFeed.trimOutliers([], 2.0).size() != 0) {
  Runtime.trap("FAIL: trimOutliers of empty must be empty");
};
Debug.print("  ✓ trimOutliers of empty is empty");

// Two sources far apart (untrimmable, n<3): dispersion must stay HONEST —
// big stddev survives so the quality floor correctly refuses to price.
let splitAgg = PriceFeed.aggregate("X", [
  { sourceId = "a"; asset = "X"; price = 100.0; fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "b"; asset = "X"; price = 110.0; fetchedAtNs = 0; ok = true; errMessage = null },
], 0);
if (splitAgg.stddevBps < 500.0) {
  Runtime.trap("FAIL: 2-way disagreement must keep its honest (large) stddev, got " # debug_show splitAgg.stddevBps);
};
Debug.print("  ✓ 2-source disagreement keeps honest dispersion (floor still refuses)");

Debug.print("── PriceFeed.test PASS ──");
