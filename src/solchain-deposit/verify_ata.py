#!/usr/bin/env python3
"""Verify solchain-deposit/Ata.mo + Base58.mo ATA derivation vs the Solana SDK.

The on-curve test mirrors Solana's Pubkey::bytes_are_curve_point, which is
RFC 8032 CompressedEdwardsY::decompress().is_some():
  - interpret the 32 bytes as a LITTLE-ENDIAN 255-bit integer (mask the sign
    bit, byte31 0x80);
  - reject non-canonical encodings where that value >= P;
  - a point exists iff x^2 = (y^2-1)/(d*y^2+1) mod P has a square root
    (Euler criterion, equivalent to the p==5 mod 8 sqrt shortcut).
Endianness is the subtle part: the bytes are little-endian, NOT big-endian.
"""
import os, hashlib

ATA_PROGRAM_ID = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
TWO255 = 57896044618658097711785492504343953926634992332820282019728792003956564819968
P      = 57896044618658097711785492504343953926634992332820282019728792003956564819949
D      = 37095705934669439343138083508754565189542113879843219016388785533085940283555
SUFFIX = b"ProgramDerivedAddress"
from solders.pubkey import Pubkey
ATA = Pubkey.from_string(ATA_PROGRAM_ID)
PROG_B = bytes(ATA)
LEGACY_B  = bytes(Pubkey.from_string("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"))
TOKEN22_B = bytes(Pubkey.from_string("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"))

# ---- base58 mirror of Base58.mo (full, with leading zeros) ----
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def decode_base58(s):
    lz = 0; started = False; num = 0
    for c in s:
        if (not started) and c == '1': lz += 1; continue
        started = True; num = num * 58 + ALPHABET.index(c)
    vb = []
    if num > 0:
        n = num; rev = []
        while n > 0: rev = [n % 256] + rev; n //= 256
        vb = rev
    return bytes([0]*lz + vb)
def encode_base58(b):
    lz = 0; i = 0
    while i < len(b) and b[i] == 0: lz += 1; i += 1
    num = 0; j = i
    while j < len(b): num = num * 256 + b[j]; j += 1
    dig = []
    if num > 0:
        n = num
        while n > 0: dig = [n % 58] + dig; n //= 58
    return '1'*lz + ''.join(ALPHABET[d] for d in dig)

def pow_mod(base, exp, m):
    r = 1; b = base % m; e = exp
    while e > 0:
        if e % 2 == 1: r = (r * b) % m
        e //= 2; b = (b * b) % m
    return r

# ---- on-curve mirror of Ata.mo (CORRECTED: little-endian) ----
def is_on_curve(b):
    # 32 bytes, little-endian; mask the sign bit (bit 255) -> 255-bit value.
    y = int.from_bytes(b, 'little') & ((1 << 255) - 1)
    if y >= P: return False            # reject non-canonical encoding
    y2 = (y * y) % P
    u = (y2 - 1) % P
    vv = (D * y2 + 1) % P
    if vv == 0: return False           # no x exists
    x2 = (u * pow_mod(vv, P - 2, P)) % P
    if x2 == 0: return True            # y = +/-1 -> x = 0 (valid point)
    return pow_mod(x2, (P - 1) // 2, P) == 1   # Euler QR test

def derive_raw(owner, mint, token_program, ata_program):
    user_seeds = owner + mint + token_program
    bump = 255
    while True:
        h = hashlib.sha256(user_seeds + bytes([bump]) + ata_program + SUFFIX).digest()
        if not is_on_curve(h): return h, bump
        if bump == 0: return h, bump
        bump -= 1

def ata_address_mirror(owner_b58, mint_b58, tp_b58):
    ata_prog = decode_base58(ATA_PROGRAM_ID)
    o = decode_base58(owner_b58); m = decode_base58(mint_b58); t = decode_base58(tp_b58)
    if o is None or m is None or t is None or len(ata_prog) != 32: return None
    raw, _ = derive_raw(o, m, t, ata_prog)
    return encode_base58(raw)

def sdk_ata(owner_b, mint_b, tp_b):
    addr, _ = Pubkey.find_program_address([owner_b, mint_b, tp_b], ATA)
    return str(addr)

# ---- Test 1: end-to-end ATA vs SDK ----
N = 5000
mm = 0; rt_fail = 0
for k in range(N):
    owner_b = os.urandom(32); mint_b = os.urandom(32)
    tp_b = LEGACY_B if (k % 2 == 0) else TOKEN22_B
    ob = encode_base58(owner_b); mb = encode_base58(mint_b); tb = encode_base58(tp_b)
    if decode_base58(ob) != owner_b: rt_fail += 1; continue
    if decode_base58(mb) != mint_b: rt_fail += 1; continue
    sdk = sdk_ata(owner_b, mint_b, tp_b)
    mir = ata_address_mirror(ob, mb, tb)
    if sdk != mir:
        mm += 1
        if mm <= 5:
            h = hashlib.sha256(owner_b+mint_b+tp_b+bytes([255])+PROG_B+SUFFIX).digest()
            print(f"  MISMATCH iter {k}: sdk={sdk} mir={mir} my_oncurve(h255)={is_on_curve(h)}")
print(f"[E2E] N={N}  ata mismatches={mm}  base58 roundtrip failures={rt_fail}")

# ---- Test 2: per-value on-curve vs SDK oracle (correct input matching) ----
M = 30000
curve_mm = 0
for k in range(M):
    s = os.urandom(32)
    H = hashlib.sha256(s + PROG_B + SUFFIX).digest()
    sdk_on = False
    try:
        Pubkey.create_program_address([s], ATA)
    except Exception:
        sdk_on = True
    if is_on_curve(H) != sdk_on:
        curve_mm += 1
print(f"[CURVE] M={M}  mismatches(vs SDK oracle)={curve_mm}")

# ---- known vector ----
USDC  = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
OWNER = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
sdk_v = sdk_ata(decode_base58(OWNER), decode_base58(USDC), LEGACY_B)
mir_v = ata_address_mirror(OWNER, USDC, encode_base58(LEGACY_B))
print(f"[KNOWN] known vector match={sdk_v == mir_v}  sdk={sdk_v}")
print(f"[ATA_PROGRAM_ID] decodes to 32 bytes={len(decode_base58(ATA_PROGRAM_ID))==32}")

all_ok = (mm == 0) and (rt_fail == 0) and (curve_mm == 0) and (sdk_v == mir_v)
print("RESULT:", "ALL PASS" if all_ok else "FAILURES PRESENT")
