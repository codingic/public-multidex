// Tunables and environment overrides for the NEAR (NEP-141) deposit detector.
//
// NEAR has no IC-native RPC canister (unlike the EVM-RPC canister the ETH
// detector uses), so we reach the chain via IC HTTPS outcalls to a public NEAR
// RPC endpoint. The URL is mainnet by default and overridable via the
// NEAR_RPC_URL env var.

import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";

// Mainnet NEAR RPC. Override with NEAR_RPC_URL for testnet / a private node.
func nearRpcMainnet() : Text { "https://rpc.mainnet.near.org" };

func nearRpcEnv<system>() : ?Text {
  switch (Runtime.envVar<system>("NEAR_RPC_URL")) {
    case (?t) { if (t.size() > 0) { ?t } else { null } };
    case null { null };
  };
};

// Asset label for native NEAR (unused for token deposits, where asset = the
// NEP-141 contract account id, but kept for parity with the ETH detector).
let ASSET : Text = "NEAR";

// Scan cadence / finality tunables. NEAR finalizes quickly (~1s blocks) and
// EXPERIMENTAL_tx_status waits for EXECUTED, so we stay just behind the "final" tip.
let DELAY_BLOCKS : Nat = 2;            // stop this many blocks behind the tip (reorg guard)
// Unlike ETH (one eth_getLogs per block), NEAR needs ONE RPC outcall PER TRANSACTION
// (EXPERIMENTAL_tx_status). Effective per-cycle outcall count ≈ this × tx/block,
// so keep this small on mainnet (blocks commonly carry hundreds of txs).
let MAX_BLOCKS_PER_SCAN : Nat = 10;    // cap per-cycle RPC/outcall cost
// after this many consecutive failed scans of the SAME block (~60s at the 5s
// cadence), skip it instead of wedging the cursor forever (see scanBlocks)
let MAX_SCAN_FAILS : Nat = 12;
let CONFIRMED_BLOCKS : Nat = 20;       // move to depositsConfirmed at this depth
let SCAN_INTERVAL_SEC : Nat = 5;       // poll cadence
// Cycles attached to each HTTPS outcall (NEAR RPC responses are small; the fee
// is refunded for any unused amount). Tune against the live IC HTTPS-outcall
// fee schedule if calls fail.
let NEAR_RPC_CYCLES : Nat = 10_000_000_000;

func parseCanisterEnv<system>(name : Text) : ?Principal {
  switch (Runtime.envVar<system>(name)) {
    case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
    case null { null };
  };
};
