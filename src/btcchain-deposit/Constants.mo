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
let SCAN_INTERVAL_SEC : Nat = 15;       // poll cadence (BTC ~10min blocks; per-address UTXO scan)
let UTXO_LIMIT : Nat32 = 100;           // cap utxos returned per get_utxos (filter)

func parseCanisterEnv<system>(name : Text) : ?Principal {
  switch (Runtime.envVar<system>(name)) {
    case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
    case null { null };
  };
};

func btcCanisterEnv<system>() : ?Principal { parseCanisterEnv<system>("PUBLIC_CANISTER_ID:bitcoin") };
