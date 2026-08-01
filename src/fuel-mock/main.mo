// fuel-mock — a DEV-ONLY stand-in for the ICP ledger + cycles-minting canister.
//
// Purpose (see the Stage-2 fuel block in src/backend/main.mo): the DEX's
// treasury→cycles loop ends in two mainnet canisters — the ICP ledger
// (icrc1_transfer) and the CMC (notify_top_up). This mock plays BOTH roles so
// the ENTIRE loop runs for real locally: cold_start wires setFuelRoute at this
// canister, the DEX transfers "ICP" here, notifies, and the mock actually
// deposit_cycles the DEX — so a test can assert a genuine cycle-balance rise.
//
// Fidelity notes:
//   • icrc1_transfer returns a monotonically increasing block index and
//     records (amount, to.subaccount) — like a ledger, minus balance checks
//     (the DEX's internal debit is the accounting under test, not ours);
//   • notify_top_up verifies the block exists, pays cycles ONCE per block
//     (a second notify → #Err, mirroring the real CMC's already-processed
//     refusal), and mints at a fixed RATE (1 ICP = 1T cycles — the right
//     order of magnitude; the real rate floats with the ICP/XDR price);
//   • unknown block → #Err(#InvalidTransaction).
// NEVER deploy to a value-bearing target: transfer is open and mints cycles.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";

actor {
  public type Icrc1TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };
  public type NotifyError = {
    #Refunded : { reason : Text; block_index : ?Nat64 };
    #InvalidTransaction : Text;
    #TransactionTooOld : Nat64;
    #Processing;
    #Other : { error_code : Nat64; error_message : Text };
  };

  transient let CYCLES_PER_E8S : Nat = 10_000;   // 1 ICP (1e8 e8s) → 1T cycles
  transient let ic00 = actor "aaaaa-aa" : actor {
    deposit_cycles : shared { canister_id : Principal } -> async ();
  };

  var nextBlock : Nat = 1;
  // block → (e8s received, consumed-by-notify)
  let blocks = Map.empty<Nat, { e8s : Nat; var consumed : Bool }>();

  public shared func icrc1_transfer(arg : {
    from_subaccount : ?Blob;
    to : { owner : Principal; subaccount : ?Blob };
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  }) : async { #Ok : Nat; #Err : Icrc1TransferError } {
    let block = nextBlock;
    nextBlock += 1;
    Map.add(blocks, Nat.compare, block, { e8s = arg.amount; var consumed = false });
    #Ok(block);
  };

  public shared func notify_top_up(arg : { block_index : Nat64; canister_id : Principal }) : async {
    #Ok : Nat; #Err : NotifyError;
  } {
    switch (Map.get(blocks, Nat.compare, Nat64.toNat(arg.block_index))) {
      case null { #Err(#InvalidTransaction("no such block")) };
      case (?b) {
        if (b.consumed) { return #Err(#InvalidTransaction("block already processed")) };
        b.consumed := true;
        let cycles = b.e8s * CYCLES_PER_E8S;
        await (with cycles = cycles) ic00.deposit_cycles({ canister_id = arg.canister_id });
        #Ok(cycles);
      };
    };
  };
}
