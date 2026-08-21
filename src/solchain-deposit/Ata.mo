// Associated Token Account (ATA) derivation for Solana SPL / Token-2022,
// implemented in-canister so the deposit detector only needs to store SOL owner
// addresses — every (owner, mint) ATA is derived on demand.
//
// ATA = findProgramAddress([owner, mint, token_program_id], ata_program_id)
//   hash input = SHA-256(owner ‖ mint ‖ token_program ‖ [bump] ‖
//                         ata_program ‖ "ProgramDerivedAddress")
//   the bump byte sits between the user seeds and the program-id/suffix;
//   return the first 32-byte hash that is NOT a valid Ed25519 curve point,
//   trying bump = 255, 254, … , 0. (ATA bump is always 255 in practice.)
//
// Reference: solana-program-library/token/program/src/associated_token_account.rs
//            and @solana/spl-token's getAssociatedTokenAddressSync.

import Base58 "Base58";
import Sha256 "mo:sha2/Sha256";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";

let ATA_PROGRAM_ID : Text = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";

// Ed25519 field prime p = 2^255 - 19
let P : Nat = 57896044618658097711785492504343953926634992332820282019728792003956564819949;
// Ed25519 curve coefficient d = -121665/121666 mod p
let D : Nat = 37095705934669439343138083508754565189542113879843219016388785533085940283555;

// "ProgramDerivedAddress" suffix (21 ASCII bytes)
let SUFFIX : [Nat8] = [80,114,111,103,114,97,109,68,101,114,105,118,101,100,65,100,100,114,101,115,115];

// modular exponentiation: base^exp mod m  (m > 0)
func powMod(base : Nat, exp : Nat, m : Nat) : Nat {
  var result : Nat = 1;
  var b = base % m;
  var e = exp;
  while (e > 0) {
    if (e % 2 == 1) { result := (result * b) % m };
    e := e / 2;
    b := (b * b) % m;
  };
  result;
};

func concat(a : [Nat8], b : [Nat8]) : [Nat8] {
  Array.concat<Nat8>(a, b);
};

func sha256(data : [Nat8]) : [Nat8] {
  Blob.toArray(Sha256.fromArray(#sha256, data));
};

// Is the 32-byte buffer a VALID Ed25519 curve point (→ must be REJECTED as a
// PDA)? Mirrors Solana's Pubkey::bytes_are_curve_point, which is RFC 8032
// CompressedEdwardsY::decompress().is_some():
//   - interpret the 32 bytes as a LITTLE-ENDIAN integer, mask the sign bit
//     (bit 255, byte[31] 0x80), and reject non-canonical values >= P;
//   - a point exists iff x^2 = (y^2 - 1)/(d*y^2 + 1) mod P has a square root
//     (Euler criterion). Endianness is the subtle part: the bytes are LE.
func isOnCurve(bytes : [Nat8]) : Bool {
  // Little-endian reconstruction. We accumulate from the most-significant byte
  // (byte[31]) down to byte[0]; clearing the sign bit of byte[31] (bit 255)
  // as we go yields the 255-bit value directly, with no separate masking step.
  var v : Nat = 0;
  var i = 31;
  while (i >= 0) {
    var b = Nat8.toNat(bytes[i]);
    if (i == 31 and b >= 128) { b := b - 128 };   // clear sign bit
    v := v * 256 + b;
    i := i - 1;
  };
  let y = v;                       // 0 <= y < 2^255, sign bit already 0
  if (y >= P) { return false };    // reject non-canonical encoding
  let y2 = (y * y) % P;
  let u = if (y2 == 0) { P - 1 } else { (y2 - 1) % P };   // y^2 - 1 (mod P)
  let vv = (D * y2 + 1) % P;                                 // d*y^2 + 1 (mod P)
  if (vv == 0) { return false };            // denominator 0 -> no x
  let x2 = (u * powMod(vv, P - 2, P)) % P;  // x^2 = (y^2 - 1)/(d*y^2 + 1)
  if (x2 == 0) { return true };             // y = +/-1 -> x = 0 (valid point)
  powMod(x2, (P - 1) / 2, P) == 1;          // Euler quadratic-residue test
};

// raw 32-byte ATA pubkey bytes for (owner, mint, tokenProgram) under the ATA
// program. Mirrors Solana's create_program_address: the bump byte is appended
// to the USER seeds (owner ‖ mint ‖ token_program), THEN the ATA program id and
// the "ProgramDerivedAddress" suffix are hashed after it:
//   hash = SHA-256(owner ‖ mint ‖ token_program ‖ [bump] ‖ ata_program ‖ suffix)
// Return the first hash that is NOT a valid Ed25519 curve point (bump 255→0).
func deriveRaw(owner : [Nat8], mint : [Nat8], tokenProgram : [Nat8], ataProgram : [Nat8]) : [Nat8] {
  let userSeeds = concat(owner, concat(mint, tokenProgram));
  var bump : Nat = 255;
  loop {
    let withBump = concat(concat(userSeeds, [Nat8.fromNat(bump)]), concat(ataProgram, SUFFIX));
    let hash = sha256(withBump);
    if (not isOnCurve(hash)) { return hash };
    if (bump == 0) { return hash };
    bump := bump - 1;
  };
};

// Derive the ATA base58 address for an owner wallet + mint + token program.
// Returns null if any input fails to decode as a 32-byte pubkey.
func ataAddress(owner : Text, mint : Text, tokenProgram : Text) : ?Text {
  let ataProg = switch (Base58.decodeBase58(ATA_PROGRAM_ID)) {
    case (?b) { b };
    case null { return null };
  };
  if (ataProg.size() != 32) { return null };
  switch (
    Base58.decodeBase58(owner),
    Base58.decodeBase58(mint),
    Base58.decodeBase58(tokenProgram)
  ) {
    case (?o, ?m, ?t) { ?Base58.encodeBase58(deriveRaw(o, m, t, ataProg)) };
    case _ { null };
  };
};
