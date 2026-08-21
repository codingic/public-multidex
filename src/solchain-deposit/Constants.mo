// Tunables and environment overrides for the Solana (SOL) deposit detector.

import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import SolRpcTypes "SolRpcTypes";

// dfinity sol-rpc canister — mainnet principal (fiduciary subnet, NNS-controlled).
// https://github.com/dfinity/sol-rpc-canister
func solRpcMainnet() : Principal { Principal.fromText("tghme-zyaaa-aaaar-qarca-cai") };

// every sol-rpc call routes through this single mainnet selector
let SOL_CHAIN : SolRpcTypes.RpcSources = #Default (#Mainnet);

let ASSET : Text = "SOL";

// SOL native transfer program (System Program). A native SOL transfer shows up
// as a SystemProgram instruction (programId == this) crediting the recipient.
let SYSTEM_PROGRAM : Text = "11111111111111111111111111111111";
// SPL Token program (legacy). Token transfers are SplToken instructions.
let SPL_TOKEN_PROGRAM : Text = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
// SPL Token-2022 program (newer mints).
let SPL_TOKEN_2022_PROGRAM : Text = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";

let DELAY_SLOTS : Nat = 32;           // stop this many slots behind the tip (reorg guard)
let MAX_SLOTS_PER_SCAN : Nat = 150;   // cap per-cycle RPC cost (one address sweep each)
let BLOCKS_PER_BATCH : Nat = 5;       // slots fetched concurrently per scan batch (Solana is fast)
let CONFIRMED_SLOTS : Nat = 32;       // move to depositsConfirmed at this depth
let SCAN_INTERVAL_SEC : Nat = 8;      // poll cadence (Solana slots ~400ms; sweep is per-address)
let SOL_RPC_CYCLES : Nat = 10_000_000_000;

// per-block scanning — no per-address signature limit

// consensus on aggregated sol-rpc responses — Equality matches all providers
func parseCanisterEnv<system>(name : Text) : ?Principal {
  switch (Runtime.envVar<system>(name)) {
    case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
    case null { null };
  };
};

func solRpcEnv<system>() : ?Principal { parseCanisterEnv<system>("PUBLIC_CANISTER_ID:sol_rpc") };
