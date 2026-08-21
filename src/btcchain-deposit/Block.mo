// Raw Bitcoin block decoder for the BTC deposit detector.
//
// The IC bitcoin canister hands us the full serialized block as a Blob
// (bitcoin_get_block). We walk it with a byte cursor and pull out every
// transaction output: its scriptPubKey (Blob), value (satoshis, Nat64), plus
// the tx index and output index (for a stable, replay-safe dedup key). We do
// NOT need txids or input scripts — deposits are detected at output creation,
// and the recipient is recovered by converting each output's scriptPubKey
// back into an address (BtcAddr.scriptToAddress, called from main.mo).
//
// Handles both legacy and segwit (BIP141) transactions, including the witness
// section, so we skip witnesses correctly and don't desync the cursor.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";

module {

  public type Output = {
    script : Blob;     // raw scriptPubKey bytes
    value : Nat64;     // satoshis
    txIndex : Nat;     // index of this transaction within the block
    vout : Nat;        // output index within the transaction
  };

  // little-endian unsigned integers
  func readU16LE(b : [Nat8], pos : Nat) : Nat {
    Nat8.toNat(b[pos]) + Nat8.toNat(b[pos + 1]) * 256;
  };
  func readU32LE(b : [Nat8], pos : Nat) : Nat {
    Nat8.toNat(b[pos]) + Nat8.toNat(b[pos + 1]) * 256
      + Nat8.toNat(b[pos + 2]) * 65536 + Nat8.toNat(b[pos + 3]) * 16777216;
  };
  func readU64LE(b : [Nat8], pos : Nat) : Nat64 {
    var v : Nat64 = 0;
    var mult : Nat64 = 1;
    var s = 0;
    while (s < 8) {
      v += Nat64.fromNat(Nat8.toNat(b[pos + s])) * mult;
      mult *= 256;
      s += 1;
    };
    v;
  };

  // Bitcoin compact-size varint → (value, next position)
  func readVarint(b : [Nat8], pos : Nat) : (Nat, Nat) {
    let first = b[pos];
    if (first < 0xfd) {
      (Nat8.toNat(first), pos + 1);
    } else if (first == 0xfd) {
      (readU16LE(b, pos + 1), pos + 3);
    } else if (first == 0xfe) {
      (readU32LE(b, pos + 1), pos + 5);
    } else {
      (Nat64.toNat(readU64LE(b, pos + 1)), pos + 9);
    };
  };

  // Decode a raw block. Returns null only on a structural/truncation error
  // (so the caller can mark the scan as failed and retry next cycle). All
  // reads are bounds-checked so malformed bytes yield null, never a trap
  // (scanBlocks' catch would contain a trap, but null keeps the failure
  // explicit and retry-safe).
  public func decodeBlock(raw : Blob) : ?[Output] {
    let b = Blob.toArray(raw);
    let n = b.size();
    if (n < 81) { return null };    // header + at least a 1-byte tx count
    var i = 80;                     // skip header
    let (txCount, ni) = readVarint(b, i);
    i := ni;
    var outs : [Output] = [];
    var txIndex = 0;
    while (txIndex < txCount) {
      if (i + 4 > n) { return null };
      i += 4; // version
      var segwit = false;
      if (i + 2 <= n and b[i] == 0x00 and b[i + 1] == 0x01) {
        segwit := true;
        i += 2; // marker + flag
      };
      // inputs
      if (i >= n) { return null };
      let (inCount, ii) = readVarint(b, i);
      i := ii;
      var k = 0;
      while (k < inCount) {
        if (i + 36 > n) { return null };
        i += 36; // outpoint: txid(32) + vout(4)
        let (slen, si) = readVarint(b, i);
        i := si;
        if (i + slen > n) { return null };
        i += slen; // scriptSig
        if (i + 4 > n) { return null };
        i += 4; // sequence
        k += 1;
      };
      // outputs
      let (outCount, oi) = readVarint(b, i);
      i := oi;
      var v = 0;
      while (v < outCount) {
        if (i + 8 > n) { return null };
        let value = readU64LE(b, i);
        i += 8;
        let (slen, si2) = readVarint(b, i);
        i := si2;
        if (i + slen > n) { return null };
        let scr : [var Nat8] = Array.toVarArray(Array.repeat(0 : Nat8, slen));
        var z = 0;
        while (z < slen) { scr[z] := b[i + z]; z += 1 };
        let script = Blob.fromArray(Array.fromVarArray(scr));
        i += slen;
        outs := Array.concat(outs, [{ script = script; value = value; txIndex = txIndex; vout = v }]);
        v += 1;
      };
      // witnesses (segwit only)
      if (segwit) {
        var w = 0;
        while (w < inCount) {
          if (i >= n) { return null };
          let (wcount, wi) = readVarint(b, i);
          i := wi;
          var j = 0;
          while (j < wcount) {
            if (i >= n) { return null };
            let (wlen, wj) = readVarint(b, i);
            i := wj;
            if (i + wlen > n) { return null };
            i += wlen;
            j += 1;
          };
          w += 1;
        };
      };
      if (i + 4 > n) { return null };
      i += 4; // locktime
      txIndex += 1;
    };
    ?outs;
  };

};
