// Tunables for the ICP deposit detector.

import Principal "mo:core/Principal";

// Blocks fetched per icrc3_get_blocks call. ICP inter-canister responses are
// capped at ~2 MB, so a single page must stay small; we paginate to cover the
// full window instead of requesting it in one shot.
let PAGE_SIZE : Nat = 2_000;

// Deposit window: a refresh scans back 24h of block history (by block
// timestamp), which covers the "just deposited, want to see it" case.
let SCAN_WINDOW_NS : Int = 86_400_000_000_000;

// Hard cap on how many blocks a single refresh may walk, so a pathological
// ledger (or a broken time filter) can't make the call run forever.
let MAX_SCAN_BLOCKS : Nat = 200_000;

// ICP ledger canister id on mainnet.
func icpLedgerMainnet() : Principal { Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai") };
