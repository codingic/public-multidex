// Bitcoin address ⇄ scriptPubKey conversion for the BTC deposit detector.
//
// Registration runs address→script purely as validation: an address that fails
// base58 double-SHA256 or bech32/bech32m checksum verification is rejected on
// the spot (a typo'd address can never silently never-match). Block scanning
// runs the reverse direction: each output's raw scriptPubKey is converted back
// into its canonical address (scriptToAddress) and looked up against the
// addresses registered in watchedAddresses.
//
// Supported both ways: P2PKH (base58, version 0x00), P2WPKH (bech32, witness
// v0) and P2TR / Taproot (bech32m, witness v1). These three are the ONLY
// address types accepted as deposits. They are chosen precisely because the
// address encodes the spending key directly (P2PKH/P2WPKH: HASH160(pubkey);
// P2TR: x-only pubkey with an always-available key path) — so an output that
// matches a registered address is provably spendable by the key holder, with
// NO way to "lock" it without changing the script (which would break the
// address match). P2SH and P2WSH are deliberately NOT supported: their address
// commits only to HASH160(redeemScript) / SHA256(witnessScript), whose
// spendability cannot be verified at deposit-scan time. A locked or
// unspendable redeem/witness script would let such an output be credited as a
// deposit but never moved — a fake deposit. Anything else yields null on BOTH
// sides: scripts that embed the user's key inside a lock (CLTV/CSV timelock,
// hashlock HTLC, multisig, OP_RETURN data — different byte shape), and
// non-standard witness programs (v0 with a wrong length is consensus-
// unspendable, i.e. coins locked forever; v1 wrong length and v2-16 are
// anyone-can-spend). So an output "containing the user's address" but locked
// can neither register nor be detected as a deposit.
//
// NOTE: the core/base libraries available here have no Word32 / bitwise ops on
// Nat, so all bit manipulation (BIP173 polymod, 5↔8 convertBits) is done with
// plain + * / % via the pow2/xor32 helpers.

import Sha256 "mo:sha2/Sha256";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";
import Char "mo:core/Char";

module {

  // 2^k for small k (used to emulate << and >> on Nat)
  func pow2(k : Nat) : Nat {
    var r = 1 : Nat;
    var i = 0;
    while (i < k) { r *= 2; i += 1 };
    r;
  };

  // 32-bit XOR implemented over Nat with + * / % only
  func xor32(a : Nat, b : Nat) : Nat {
    var r = 0 : Nat;
    var i = 0;
    var pw = 1 : Nat;
    while (i < 32) {
      let ba = (a / pw) % 2;
      let bb = (b / pw) % 2;
      if (ba != bb) { r += pw };
      i += 1;
      pw *= 2;
    };
    r;
  };

  // Returns the scriptPubKey bytes for a BTC address, or null if it is
  // unsupported or fails checksum verification.
  public func addressToScript(addr : Text) : ?[Nat8] {
    if (Text.startsWith(addr, #text("bc1")) or Text.startsWith(addr, #text("tb1")) or Text.startsWith(addr, #text("bcrt1"))) {
      bech32ToScript(addr);
    } else {
      base58ToScript(addr);
    };
  };

  // ── small byte helpers ──────────────────────────────────────
  func slice(a : [Nat8], start : Nat, end : Nat) : [Nat8] {
    let len = end - start;
    let out : [var Nat8] = Array.toVarArray(Array.repeat(0 : Nat8, len));
    var i = 0;
    while (i < len) { out[i] := a[start + i]; i += 1 };
    Array.fromVarArray(out);
  };
  func concat(a : [Nat8], b : [Nat8]) : [Nat8] {
    Array.concat(a, b);
  };
  func eq(a : [Nat8], b : [Nat8]) : Bool {
    if (a.size() != b.size()) { return false };
    var i = 0;
    while (i < a.size()) { if (a[i] != b[i]) { return false }; i += 1 };
    true;
  };

  // ── base58 (P2PKH) ──────────────────────────────────────────
  let B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

  func charVal(c : Char) : Nat {
    var i = 0;
    for (a in B58.chars()) {
      if (a == c) { return i };
      i += 1;
    };
    0;
  };

  // base58 → bytes (big-endian, with leading-zero handling). Sized buffer keeps
  // it allocation-free of growing arrays; bytes ≤ chars so sz is an upper bound.
  func base58Decode(s : Text) : [Nat8] {
    let sz = s.size();
    let buf : [var Nat8] = Array.toVarArray(Array.repeat(0 : Nat8, sz));
    var len = 0 : Nat;
    for (c in s.chars()) {
      let v = charVal(c);
      var carry : Nat = v;
      var i = 0;
      while (i < len) {
        carry += 58 * Nat8.toNat(buf[i]);
        buf[i] := Nat8.fromNat(carry % 256);
        carry /= 256;
        i += 1;
      };
      while (carry > 0) {
        buf[len] := Nat8.fromNat(carry % 256);
        len += 1;
        carry /= 256;
      };
    };
    // count leading '1' → leading zero bytes
    var leading = 0 : Nat;
    label l for (c in s.chars()) { if (c == '1') { leading += 1 } else { break l } };
    let out : [var Nat8] = Array.toVarArray(Array.repeat(0 : Nat8, leading + len));
    var j = 0;
    while (j < leading) { out[j] := 0; j += 1 };
    var k = len;
    while (k > 0) {
      k -= 1;
      out[j] := buf[k];
      j += 1;
    };
    Array.fromVarArray(out);
  };

  func base58ToScript(addr : Text) : ?[Nat8] {
    let d = base58Decode(addr);
    if (d.size() != 25) { return null };
    let payload = slice(d, 0, 21);
    let cs = slice(d, 21, 25);
    let h1 = Sha256.fromArray(payload);
    let h2 = Sha256.fromArray(Blob.toArray(h1));
    let chk = slice(Blob.toArray(h2), 0, 4);
    if (not eq(chk, cs)) { return null };
    let version = d[0];
    let hash160 = slice(d, 1, 21);
    if (version == 0) {
      // OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG — P2PKH.
      // (P2SH / version 0x05 is intentionally NOT supported: a P2SH address
      // commits only to HASH160(redeemScript), whose spendability cannot be
      // verified at deposit-scan time. A locked/unspendable redeem script
      // would let a "deposit" be credited but never moved — a fake deposit.)
      ?concat([0x76, 0xa9, 0x14], concat(hash160, [0x88, 0xac]));
    } else { null };
  };

  // ── bech32 (P2WPKH / P2TR) ──────────────────────────────────
  let B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

  func bech32Char(c : Char) : ?Nat8 {
    // Normalize A-Z -> a-z so all-uppercase addresses (valid per BIP173) decode
    // the same as all-lowercase. The charset itself is all lowercase.
    var code : Nat32 = Char.toNat32(c);
    if (code >= 0x41 and code <= 0x5a) { code := code + 0x20 };
    var i = 0;
    for (a in B32.chars()) {
      if (Char.toNat32(a) == code) { return ?Nat8.fromNat(i) };
      i += 1;
    };
    null;
  };

  // split a Text at the LAST occurrence of `c` → (before, after)
  func splitLast(s : Text, c : Char) : (Text, Text) {
    var last = -1 : Int;
    var idx = 0;
    for (ch in s.chars()) { if (ch == c) { last := idx }; idx += 1 };
    if (last < 0) { return ("", s) };
    var before = "";
    var after = "";
    idx := 0;
    for (ch in s.chars()) {
      if (idx < last) { before := before # Text.fromChar(ch) }
      else if (idx > last) { after := after # Text.fromChar(ch) };
      idx += 1;
    };
    (before, after);
  };

  // BIP173/BIP350 polymod over a sequence of 5-bit groups. Shared by the
  // decode-side version check (bech32Version) and the encode-side checksum.
  // All bit ops emulated with + * / % (no Word32 / bitwise ops available).
  func bech32Polymod(values : [Nat8]) : Nat {
    let GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    var chk : Nat = 1;
    var idx = 0;
    while (idx < values.size()) {
      let v = Nat8.toNat(values[idx]);
      let b = chk / 33554432;          // chk >> 25
      let low25 = chk % 33554432;      // chk & 0x1ffffff
      chk := low25 * 32 + v;           // (chk & 0x1ffffff) << 5 | v
      if ((b / 1) % 2 == 1) { chk := xor32(chk, GEN[0]) };
      if ((b / 2) % 2 == 1) { chk := xor32(chk, GEN[1]) };
      if ((b / 4) % 2 == 1) { chk := xor32(chk, GEN[2]) };
      if ((b / 8) % 2 == 1) { chk := xor32(chk, GEN[3]) };
      if ((b / 16) % 2 == 1) { chk := xor32(chk, GEN[4]) };
      idx += 1;
    };
    chk;
  };

  // BIP173 hrp expansion: high 3 bits of each char, separator 0, low 5 bits.
  func hrpExpand(hrp : Text) : [Nat8] {
    var out : [Nat8] = [];
    for (c in hrp.chars()) {
      out := Array.concat(out, [Nat8.fromNat(Nat32.toNat(Char.toNat32(c)) / 32)]);
    };
    out := Array.concat(out, [0 : Nat8]);
    for (c in hrp.chars()) {
      out := Array.concat(out, [Nat8.fromNat(Nat32.toNat(Char.toNat32(c)) % 32)]);
    };
    out;
  };

  // BIP173/BIP350 checksum check. Returns the witness version (the first
  // 5-bit group) if `data` carries a VALID checksum for `hrp`; otherwise null.
  // Per BIP350 the checksum variant must match the version: v0 → bech32
  // (polymod == 1), v1+ → bech32m (polymod == 0x2bc830a3). Enforcing the
  // pairing keeps decode↔encode round-trips exact — a v1 address carrying a
  // bech32 checksum would register but never re-encode to the same string,
  // silently never matching. `data` already includes the 6 checksum groups,
  // so we feed hrp_expand ++ data directly.
  func bech32Version(hrp : Text, data : [Nat8]) : ?Nat8 {
    let chk = bech32Polymod(Array.concat(hrpExpand(hrp), data));
    let version = data[0];
    if (chk == 1 and version == 0) { return ?version };
    if (chk == 0x2bc830a3 and version >= 1) { return ?version };
    null;
  };

  // 5-bit → 8-bit conversion (BIP173 style). pad=false drops leftover bits.
  // Bit shifts emulated with pow2; the mask is 2^toBits, i.e. (maxv + 1), NOT
  // maxv. Using `% maxv` (where maxv = 2^toBits - 1) is off by one and corrupts
  // every extracted byte once the accumulator exceeds 255 — which happens on
  // essentially all real addresses. `% pow2(toBits)` == `& (pow2(toBits)-1)`.
  func convertBits(data : [Nat8], fromBits : Nat, toBits : Nat, pad : Bool) : [Nat8] {
    let mask = pow2(toBits);   // 2^toBits; `shifted % mask` == `shifted & (2^toBits - 1)`
    let mul = pow2(fromBits);
    var acc : Nat = 0;
    var bits : Nat = 0;
    var out : [Nat8] = [];
    for (b in data.vals()) {
      acc := acc * mul + Nat8.toNat(b);
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        let shifted = acc / pow2(bits);    // acc >> bits
        out := Array.concat(out, [Nat8.fromNat(shifted % mask)]);
      };
    };
    if (pad and bits > 0) {
      let shifted = acc * pow2(toBits - bits);
      out := Array.concat(out, [Nat8.fromNat(shifted % mask)]);
    };
    out;
  };

  func bech32ToScript(addr : Text) : ?[Nat8] {
    let (hrp, dataPart) = splitLast(addr, '1');
    let dpSize = dataPart.size();
    // need: 1 version group + >=1 program group + 6 checksum groups
    if (dpSize < 8) { return null };
    let data : [var Nat8] = Array.toVarArray(Array.repeat(0 : Nat8, dpSize));
    var di = 0;
    for (c in dataPart.chars()) {
      switch (bech32Char(c)) {
        case null { return null };
        case (?v) { data[di] := v; di += 1 };
      };
    };
    let dataArr = Array.fromVarArray(data);
    // Checksum check (bech32 or bech32m) also yields the witness version group.
    let versionOpt = bech32Version(hrp, dataArr);
    switch (versionOpt) {
      case null { return null };
      case (?version) {
        // Standard, provably-spendable witness programs only: v0-20 (P2WPKH)
        // and v1-32 (P2TR / Taproot). v0-32 (P2WSH) is deliberately excluded:
        // like P2SH it commits to a hidden witness script whose spendability
        // is unknowable at deposit time, so a locked P2WSH output could be
        // credited as a deposit but never spent. Everything else (v0 wrong
        // length, v2-16) is non-standard / anyone-can-spend.
        if (version > 1) { return null };
        let program = convertBits(slice(dataArr, 1, dpSize - 6), 5, 8, false);
        let pl = program.size();
        if (not ((version == 0 and pl == 20) or (version == 1 and pl == 32))) { return null };
        // OP_0 for v0; OP_1 = 0x51 for v1 (Taproot)
        let op : Nat8 = if (version == 0) { 0x00 } else { 0x51 };
        ?concat([op, Nat8.fromNat(pl)], program);
      };
    };
  };

  // ── scriptPubKey → address (encode side) ────────────────────
  // Reconstructs the canonical address string from the raw script bytes —
  // the inverse of addressToScript. Used in the scan hot path: every output's
  // script is converted back into an address and matched against the
  // registered addresses. bech32 output is always lowercase (BIP173 canonical
  // form); base58 output is the unique canonical encoding.

  // nth char of a charset string (index is always in range for our callers)
  func nthChar(s : Text, n : Nat) : Char {
    var i = 0;
    for (c in s.chars()) {
      if (i == n) { return c };
      i += 1;
    };
    ' ';
  };

  // base58 encode: repeated division of the big-endian byte string by 58;
  // leading 0x00 bytes become leading '1's
  func base58Encode(bytes : [Nat8]) : Text {
    var leadingZeros = 0;
    label l for (b in bytes.vals()) { if (b == 0) { leadingZeros += 1 } else { break l } };
    let work : [var Nat] = Array.toVarArray(Array.repeat(0 : Nat, bytes.size()));
    var i = 0;
    while (i < bytes.size()) { work[i] := Nat8.toNat(bytes[i]); i += 1 };
    var out : [Nat8] = [];
    func isZero() : Bool {
      for (v in work.vals()) { if (v != 0) { return false } };
      true;
    };
    while (not isZero()) {
      var carry = 0 : Nat;
      var j = 0;
      while (j < work.size()) {
        let cur = carry * 256 + work[j];
        work[j] := cur / 58;
        carry := cur % 58;
        j += 1;
      };
      out := concat([Nat8.fromNat(carry)], out);
    };
    var s = "";
    var z = 0;
    while (z < leadingZeros) { s := s # "1"; z += 1 };
    for (d in out.vals()) { s := s # Text.fromChar(nthChar(B58, Nat8.toNat(d))) };
    s;
  };

  // base58 address = version ++ hash160 ++ double-SHA256 checksum
  func hash160ToBase58Addr(hash160 : [Nat8], version : Nat8) : Text {
    let payload = concat([version], hash160);
    let h1 = Sha256.fromArray(payload);
    let h2 = Sha256.fromArray(Blob.toArray(h1));
    base58Encode(concat(payload, slice(Blob.toArray(h2), 0, 4)));
  };

  // BIP173/BIP350 checksum groups for hrp ++ data. `constant` is 1 (bech32)
  // or 0x2bc830a3 (bech32m) — the mirror of bech32Version's accept check.
  func bech32Checksum(hrp : Text, data : [Nat8], constant : Nat) : [Nat8] {
    let values = concat(concat(hrpExpand(hrp), data), [0, 0, 0, 0, 0, 0]);
    let cs = xor32(bech32Polymod(values), constant);
    var out : [Nat8] = [];
    var i = 0;
    while (i < 6) {
      out := concat(out, [Nat8.fromNat((cs / pow2(5 * (5 - i))) % 32)]);
      i += 1;
    };
    out;
  };

  func bech32Encode(hrp : Text, data : [Nat8], bech32m : Bool) : Text {
    let constant = if (bech32m) { 0x2bc830a3 } else { 1 };
    var s = hrp # "1";
    for (g in concat(data, bech32Checksum(hrp, data, constant)).vals()) {
      s := s # Text.fromChar(nthChar(B32, Nat8.toNat(g)));
    };
    s;
  };

  // The raw scriptPubKey → canonical address conversion, used in the scan hot
  // path. `hrp` is the bech32 HRP ("bc"/"tb"/"bcrt"); base58 version byte is
  // mainnet P2PKH 0x00. Only provably-spendable standard shapes decode to an
  // address: P2PKH, P2WPKH (v0-20) and P2TR (v1-32). P2SH and P2WSH are
  // deliberately rejected (hidden redeem/witness script → fake-deposit/locked
  // risk), and any wrapped/locked script (CLTV/CSV/HTLC/multisig/OP_RETURN, or
  // a non-standard witness program) yields null and is therefore never matched.
  public func scriptToAddress(script : [Nat8], hrp : Text) : ?Text {
    let n = script.size();
    if (n < 4) { return null };
    if (n == 25 and script[0] == 0x76 and script[1] == 0xa9 and script[2] == 0x14
        and script[23] == 0x88 and script[24] == 0xac) {
      // P2PKH: OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
      ?hash160ToBase58Addr(slice(script, 3, 23), 0x00);
    } else {
      // witness program: OP_0 <len> <program> (v0) or OP_1 <len> <program> (v1)
      let op = Nat8.toNat(script[0]);
      let witVer = if (op == 0) { 0 } else if (op >= 0x51 and op <= 0x60) { op - 0x50 } else { 17 };
      let progLen = n - 2;
      // Standard, provably-spendable shapes only — must mirror bech32ToScript:
      // v0-20 (P2WPKH) and v1-32 (P2TR). P2WSH (v0-32) is excluded on purpose;
      // non-standard programs are consensus-unspendable (v0 wrong length) or
      // anyone-can-spend (v1 wrong length, v2-16). An output shaped like the
      // user's address but locked must never be encoded — and thus never
      // matched — as a deposit.
      let standard = (witVer == 0 and progLen == 20) or (witVer == 1 and progLen == 32);
      if (standard and Nat8.toNat(script[1]) == progLen) {
        let groups = convertBits(slice(script, 2, n), 8, 5, true);
        // BIP350: v0 → bech32, v1 → bech32m (Taproot)
        ?bech32Encode(hrp, concat([Nat8.fromNat(witVer)], groups), witVer >= 1);
      } else { null };
    };
  };

};
