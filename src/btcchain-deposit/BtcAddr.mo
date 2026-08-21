// Bitcoin address → scriptPubKey decoder for the BTC deposit detector.
//
// When an address is registered we turn it into the exact scriptPubKey bytes it
// expects on-chain, then store the script (hex) as the match key. During block
// scanning we hex the raw output script and look it up — so the hot path never
// needs to parse scripts, and registration (rare) absorbs the decode cost.
//
// Supported: P2PKH (base58, version 0x00), P2SH (base58, version 0x05),
// P2WPKH (bech32, witness v0) and P2TR (bech32m, witness v1 / Taproot). Both
// base58 and bech32/bech32m checksums are verified, so a typo'd address is
// rejected at registration time rather than silently never matching.
//
// NOTE: the core/base libraries available here have no Word32 / bitwise ops on
// Nat, so all bit manipulation (BIP173 polymod, 5→8 convertBits) is done with
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

  // ── base58 (P2PKH / P2SH) ───────────────────────────────────
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
      // OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
      ?concat([0x76, 0xa9, 0x14], concat(hash160, [0x88, 0xac]));
    } else if (version == 5) {
      // OP_HASH160 <20> OP_EQUAL
      ?concat([0xa9, 0x14], concat(hash160, [0x87]));
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

  // BIP173/BIP350 polymod checksum. Returns the witness version (the first
  // 5-bit group) if `data` is a valid bech32 (chk == 1) OR bech32m
  // (chk == 0x2bc830a3) checksum for `hrp`; otherwise null. `data` already
  // includes the 6 checksum groups, so we feed hrp_expand ++ data directly —
  // appending extra zero groups (a common mistake) rejects every valid address.
  // All bit ops emulated with + * / % (no Word32 / bitwise ops available).
  func bech32Version(hrp : Text, data : [Nat8]) : ?Nat8 {
    let GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    let n = hrp.size() * 2 + 1 + data.size();
    let vals : [var Nat8] = Array.toVarArray(Array.repeat(0 : Nat8, n));
    var p = 0;
    for (c in hrp.chars()) {
      let o = Nat32.toNat(Char.toNat32(c));
      vals[p] := Nat8.fromNat(o / 32); p += 1;  // high 3 bits
    };
    vals[p] := 0; p += 1; // separator
    for (c in hrp.chars()) {
      let o = Nat32.toNat(Char.toNat32(c));
      vals[p] := Nat8.fromNat(o % 32); p += 1;  // low 5 bits
    };
    for (b in data.vals()) { vals[p] := b; p += 1 };
    var chk : Nat = 1;
    var idx = 0;
    while (idx < n) {
      let v = Nat8.toNat(vals[idx]);
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
    // bech32 (BIP173, segwit v0) vs bech32m (BIP350, segwit v1+ / Taproot)
    if (chk == 1) { return ?data[0] };
    if (chk == 0x2bc830a3) { return ?data[0] };
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
        if (version > 16) { return null };
        let program = convertBits(slice(dataArr, 1, dpSize - 6), 5, 8, false);
        if (program.size() < 2) { return null };
        // OP_0 for v0; OP_1..OP_16 = 0x51..0x60 for v1..v16 (incl. Taproot v1)
        let op : Nat8 = if (version == 0) { 0x00 } else { Nat8.fromNat(0x50 + Nat8.toNat(version)) };
        ?concat([op, Nat8.fromNat(program.size())], program);
      };
    };
  };

};
