// Base58 helpers for the Solana (SOL) deposit detector.
// Solana addresses are base58-encoded and case-sensitive, so there is NO
// case-normalization step (unlike hex addresses). We only provide a base58 →
// Nat decoder for parsing token/lamport amounts embedded in jsonParsed results
// (jsonParsed returns amounts as base10 strings, but some base64 fields retain
// base58 — decoded here for completeness) and the alphabet check used to
// validate watched addresses.

import Text "mo:core/Text";
import Iter "mo:core/Iter";
import List "mo:core/List";

// Bitcoin-style base58 alphabet (used by Solana).
let ALPHABET : Text = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

func charValue(c : Char) : ?Nat {
  var i = 0;
  for (a in ALPHABET.chars()) {
    if (a == c) { return ?i };
    i += 1;
  };
  null;
};

// Decode a base58 string to a Nat. Used for the (rare) base58-encoded numeric
// fields; jsonParsed balances come back as base10 and are parsed separately.
func base58ToNat(s : Text) : Nat {
  var acc : Nat = 0;
  for (c in s.chars()) {
    switch (charValue(c)) {
      case (?v) { acc := acc * 58 + v };
      case null { return acc }; // ignore stray chars
    };
  };
  acc;
};

// Validate that a string is a well-formed base58 Solana address (no 0/O/I/l
// characters). Pure structural check — length is not enforced (variants exist).
func isValidBase58(s : Text) : Bool {
  for (c in s.chars()) {
    if (charValue(c) == null) { return false };
  };
  true;
};

// Strict Solana address check: valid base58 AND decodes to exactly 32 bytes
// (a genuine Ed25519 pubkey). A genuine address is 43–44 base58 chars, but the
// only reliable way to accept all of them (including the rare short forms from
// leading-zero bytes) while rejecting every malformed string is to actually
// decode and check the byte length. This guarantees that anything stored in
// `watchedAddresses` is a real address, so the exact-match lookup in the
// detector is meaningful — a short/garbage string would pass the alphabet-only
// check but can never match an on-chain address (silent missed deposits).
func isValidSolanaAddress(s : Text) : Bool {
  // leading '1' characters encode leading zero bytes
  var leadingZeros = 0;
  var started = false;
  var num : Nat = 0;
  for (c in s.chars()) {
    if (not started and c == '1') { leadingZeros += 1; continue };
    started := true;
    switch (charValue(c)) {
      case (?v) { num := num * 58 + v };
      case null { return false };
    };
  };
  var bytes = List.nil<Nat8>();
  if (num > 0) {
    var n = num;
    while (n > 0) {
      bytes := List.push<Nat8>(Nat8.fromNat(n % 256), bytes);
      n := n / 256;
    };
  };
  var i = 0;
  while (i < leadingZeros) {
    bytes := List.push<Nat8>(0, bytes);
    i += 1;
  };
  List.size(bytes) == 32;
};
