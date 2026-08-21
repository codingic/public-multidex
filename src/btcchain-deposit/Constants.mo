// Tunables and environment overrides for the Bitcoin (BTC) deposit detector.

import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import BtcRpcTypes "BtcRpcTypes";

// dfinity bitcoin canister — mainnet principal (the IC's native BTC integration,
// on the NNS/fiduciary subnet). https://internetcomputer.org/docs/current/references/bitcoin
func btcCanisterMainnet() : Principal { Principal.fromText("mgi-tqaaaa-aaaar-qaqoa-cai") };

// every bitcoin call routes through this single mainnet selector
let BTC_NETWORK : BtcRpcTypes.BitcoinNetwork = #mainnet;

let ASSET : Text = "BTC";

let CONFIRMED_CONFIRMATIONS : Nat = 6;  // standard BTC finality depth (~1h)

// ── block-by-block scanning ──
// Stop this many blocks behind the tip. The IC bitcoin canister only serves
// well-confirmed (stable) blocks, so reorg risk at the tip is minimal; this is
// a small extra safety margin.
let DELAY_BLOCKS : Nat = 1;
// Cap how many blocks we decode per scan cycle (bounds RPC + cycle cost). In
// steady state each ~15s scan adds ~0–1 new block; this only matters after a
// long downtime catch-up.
let MAX_BLOCKS_PER_SCAN : Nat = 10;

// Cycles attached to each bitcoin canister call. get_block returns a full block
// (up to several MB) and is the expensive one; the fee is refunded for any
// unused amount. Tune against the live IC bitcoin fee schedule if calls fail.
let BTC_RPC_CYCLES : Nat = 100_000_000_000;

let SCAN_INTERVAL_SEC : Nat = 15;       // poll cadence (BTC ~10min blocks)

func parseCanisterEnv<system>(name : Text) : ?Principal {
  switch (Runtime.envVar<system>(name)) {
    case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
    case null { null };
  };
};

func btcCanisterEnv<system>() : ?Principal { parseCanisterEnv<system>("PUBLIC_CANISTER_ID:bitcoin") };
