// Tunables and environment overrides for the ETH deposit detector.

import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import EvmRpcTypes "EvmRpcTypes";

func evmRpcMainnet() : Principal { Principal.fromText("7hfb6-caaaa-aaaar-qadga-cai") };

// every EVM-RPC call routes through this single mainnet selector
let ETH_CHAIN : EvmRpcTypes.RpcServices = #EthMainnet(?[#PublicNode]);

let ASSET : Text = "ETH";

// keccak256("Transfer(address,address,uint256)")
let TRANSFER_SIG : Text = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

let DELAY_BLOCKS : Nat = 2;            // stop this many blocks behind the tip (reorg guard)
let MAX_BLOCKS_PER_SCAN : Nat = 5;     // cap per-cycle RPC cost
let CONFIRMED_BLOCKS : Nat = 35;       // move to depositsConfirmed at this depth
let SCAN_INTERVAL_SEC : Nat = 5;       // poll cadence
let EVM_RPC_CYCLES : Nat = 10_000_000_000;

func parseCanisterEnv<system>(name : Text) : ?Principal {
  switch (Runtime.envVar<system>(name)) {
    case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
    case null { null };
  };
};

func evmRpcEnv<system>() : ?Principal { parseCanisterEnv<system>("PUBLIC_CANISTER_ID:evm_rpc") };

func ecdsaKeyName<system>() : Text {
  switch (Runtime.envVar<system>("ECDSA_KEY_NAME")) {
    case (?t) { if (t.size() > 0) { t } else { "secp256k1" } };
    case null { "secp256k1" };
  };
};
