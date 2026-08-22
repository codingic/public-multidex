// Domain types for the ICP deposit detector.

// A detected deposit: an ICP ledger transfer that landed in the watched
// (backendOwner, userSubaccount) account.
type Deposit = {
  blockIndex : Nat;      // ledger block index — unique dedup key
  from : Principal;      // sender's owner
  fromSub : ?Blob;       // sender's subaccount (usually null)
  toSub : Blob;          // the watched user subaccount
  amount : Nat;          // e8s
  fee : Nat;             // ledger fee (e8s)
  timestamp : Nat64;     // block timestamp (ns)
};
