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

// SPL Token program (legacy). Token transfers are SplToken instructions.
let TOKEN_PROGRAM_ID : Text = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
// SPL Token-2022 program (newer mints — uses a DIFFERENT ATA; pick per mint).
let TOKEN_2022_PROGRAM_ID : Text = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";

// per-address signature fetching (getSignaturesForAddress / getTransaction)
let SIG_LIMIT : Nat = 25;        // signatures pulled per getSignaturesForAddress page
let MAX_SIG_PAGES : Nat = 4;     // page cap per refresh — bounds RPC cost (~100 sigs/refresh)
let CONFIRMED_SLOTS : Nat = 32;  // move to depositsConfirmed at this slot depth
let SOL_RPC_CYCLES : Nat = 10_000_000_000;

// consensus on aggregated sol-rpc responses — Equality matches all providers
func parseCanisterEnv<system>(name : Text) : ?Principal {
  switch (Runtime.envVar<system>(name)) {
    case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
    case null { null };
  };
};

func solRpcEnv<system>() : ?Principal { parseCanisterEnv<system>("PUBLIC_CANISTER_ID:sol_rpc") };
