#!/bin/bash
# OQL request guard — the anonymous, pre-auth denial-of-service surface.
#
# `execute` and `archiveExecute` are PUBLIC and UNAUTHENTICATED: authorization
# is per-entity and resolved AFTER parsing, so anyone can reach the JSON parser
# for free (a query call bills the caller nothing). mo:json — which oql/Json.mo
# parses with — has two properties that turn that into a DoS. Measured on this
# canister before the guard (2026-07-29):
#
#   * lexing cost grows super-linearly: 8 KB → 208 ms, 16 KB → 475 ms, and
#     24 KB EXCEEDED the 5e9-instruction single-message limit;
#   * ANY UTF-16 surrogate escape in the D800-DFFF range TRAPPED the canister
#     with 'codepoint out of range' — a lone "\ud800" (~75 bytes) and equally
#     a well-formed pair like "\ud83d\ude00" (U+1F600). The same character
#     sent literally as UTF-8 parses fine, which is what the guard's error
#     message points callers to.
#
# Neither is fixed upstream — mo:json 1.4.0 is its latest release and
# oql-prototype's Json.mo is byte-identical to ours — and neither is helped by
# the index/planner work, because both fire during PARSING, before a plan
# exists. main.mo therefore screens the text before mo:json sees it.
#
# What this pins:
#   §1 an oversized query is REJECTED (and cheaply — no instruction blowout)
#   §2 every lone-surrogate shape is rejected instead of trapping the canister
#   §3 a WELL-FORMED surrogate pair is refused too — mo:json traps on those
#      as well — while the same character sent as raw UTF-8 is accepted
#   §4 the guard covers archiveExecute too — it fans out to the sidecars, so
#      an unguarded request spends their cycles as well
#   §5 legitimate queries are unaffected, including a deliberately heavy one,
#      and per-entity authorization still scopes rows
#   §6 the RESULT WINDOW is bounded: an absent limit is defaulted rather than
#      meaning "every row", an absurd limit is clamped, and a huge offset
#      cannot push the executor's early stop past the end of the store
#
# Read-only: places no orders, opens no positions, never calls resetExchange —
# safe against a live venue.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_oql_guard ──"

# Call execute() with a raw JSON string, via an args file so the shell cannot
# mangle backslash escapes (a bare \ud800 on the command line is eaten by zsh).
oql() {
  python3 - "$1" <<'PY' > /tmp/oqlguard.did
import sys
inner = sys.argv[1]
print('("' + inner.replace("\\", "\\\\").replace('"', '\\"') + '")', end="")
PY
  icp canister call --args-file /tmp/oqlguard.did backend "${2:-execute}" --query --identity anonymous 2>&1
}

# ── §1 oversized query is rejected, cheaply ──
BIG=$(python3 -c "
import json
q={'start':'market','limit':1,'where':{'and':[{'eq':{'field':'id','value':None}} for _ in range(600)]}}
print(json.dumps(q))")
R=$(oql "$BIG")
assert_contains "§1 24KB query rejected by the size cap" "$R" "query too large"
assert_not_contains "§1 ...and never reaches the instruction limit" "$R" "exceeded the limit"

# Just over the cap is rejected; comfortably under it is not.
OVER=$(python3 -c "
import json
q={'start':'market','limit':1,'where':{'icontains':{'field':'id','value':'x'*4100}}}
print(json.dumps(q))")
assert_contains "§1 just-over-cap rejected" "$(oql "$OVER")" "query too large"

# ── §2 lone surrogates are rejected, not trapped ──
for esc in 'ud800' 'udbff' 'udc00' 'udfff'; do
  R=$(oql "{\"start\":\"market\",\"limit\":1,\"where\":{\"eq\":{\"field\":\"id\",\"value\":\"\\$esc\"}}}")
  assert_contains "§2 \\$esc rejected" "$R" "unsupported surrogate escape"
  assert_not_contains "§2 \\$esc did NOT trap the canister" "$R" "codepoint out of range"
done

# A high surrogate followed by something that is not a low surrogate.
R=$(oql '{"start":"market","limit":1,"where":{"eq":{"field":"id","value":"\ud800\u0041"}}}')
assert_contains "§2 high surrogate + non-low rejected" "$R" "unsupported surrogate escape"

# ── §3 a WELL-FORMED pair is refused too — and the safe form still works ──
# \ud83d\ude00 is U+1F600 GRINNING FACE, a legal JSON surrogate pair. mo:json
# traps on it exactly as it does on a lone surrogate, so the guard refuses the
# whole D800-DFFF range rather than just the unpaired halves.
R=$(oql '{"start":"market","limit":1,"where":{"eq":{"field":"id","value":"\ud83d\ude00"}}}')
assert_contains "§3 well-formed pair is rejected (mo:json cannot decode it)" "$R" "unsupported surrogate escape"
assert_not_contains "§3 ...and does NOT trap the canister" "$R" "codepoint out of range"

# Nothing is lost: the SAME character sent literally as UTF-8 parses fine.
printf '("{\\"start\\":\\"market\\",\\"limit\\":1,\\"where\\":{\\"eq\\":{\\"field\\":\\"id\\",\\"value\\":\\"\xf0\x9f\x98\x80\\"}}}")' > /tmp/oqlguard_raw.did
R=$(icp canister call --args-file /tmp/oqlguard_raw.did backend execute --query --identity anonymous 2>&1)
assert_contains "§3 the same character as raw UTF-8 is accepted" "$R" "rows = vec"

# An escaped backslash must not be misread as the start of an escape:
# "\\ud800" is a literal backslash followed by the text ud800.
R=$(oql '{"start":"market","limit":1,"where":{"eq":{"field":"id","value":"\\ud800"}}}')
assert_not_contains "§3 literal backslash-ud800 is not treated as an escape" "$R" "unsupported surrogate escape"

# ── §4 archiveExecute is guarded too ──
assert_contains "§4 archiveExecute rejects oversized" "$(oql "$BIG" archiveExecute)" "query too large"
R=$(oql '{"start":"userEvent","limit":1,"where":{"eq":{"field":"token","value":"\ud800"}}}' archiveExecute)
assert_contains "§4 archiveExecute rejects lone surrogate" "$R" "unsupported surrogate escape"
assert_not_contains "§4 ...without trapping" "$R" "codepoint out of range"

# ── §5 legitimate traffic is untouched ──
assert_contains "§5 public entity still serves anonymously" \
  "$(oql '{"start":"market","limit":2}')" "rows = vec"
assert_not_contains "§5 ...and is not rejected" \
  "$(oql '{"start":"market","limit":2}')" "OQL: rejected"

# A deliberately heavy but legal query: many filters, a 50-value `in`, a full
# select list and ordering. Real UI queries are far smaller; this pins that the
# cap leaves genuine headroom rather than just fitting today's frontend.
HEAVY=$(python3 -c "
import json
q={'start':'userEvent',
   'where':{'and':[{'eq':{'field':'kind','value':'trade'}},
                   {'in':{'field':'marketId','value':['MKT%d-ICPUSD'%i for i in range(50)]}},
                   {'gt':{'field':'price','value':1000}},
                   {'lt':{'field':'price','value':99999}}]},
   'orderBy':[{'field':'ts','dir':'desc'},{'field':'seq','dir':'asc'}],
   'select':['seq','ts','user','ownerName','kind','token','amount','marketId','side','price','qty'],
   'limit':100}
print(json.dumps(q))")
assert_not_contains "§5 heavy-but-legal query fits under the cap" \
  "$(oql "$HEAVY" archiveExecute)" "query too large"

# schema() is a separate entry point and takes no query text — it must keep working.
assert_contains "§5 schema() still serves" \
  "$(icp canister call backend schema '()' --query --identity anonymous 2>&1)" "entities"

# The guard must not have loosened authorization: the leaderboard still
# publishes no principal (see the username de-linking work).
LB=$(oql '{"start":"leaderboard","limit":30}')
assert_not_contains "§5 leaderboard still exposes no principal field" "$LB" 'name = "user"'

# ── §6 result-window bounds ──
# The executor stops scanning at offset+limit+1, but only when there is no
# orderBy/aggregate/groupBy — and only when a limit EXISTS. A bare query
# therefore read the whole entity, and `offset` was a free 12-byte way to push
# the stop past the end of the store (measured 77 ms → 226 ms on 2,886 rows).
# main.mo defaults and clamps the window; `hasMore` tells honest callers to page.
# A 1000-row candid response is megabytes, so it goes to a FILE — passing it
# as a shell argument (which assert_contains does) overflows ARG_MAX.
rows() { grep -o 'name = "key"' "$1" | wc -l | tr -d ' '; }

oql '{"start":"closedOrder"}' > /tmp/oqlguard_nolimit.txt
N=$(rows /tmp/oqlguard_nolimit.txt)
if [ "$N" -le 1000 ] && [ "$N" -gt 0 ]; then _ok "§6 absent limit defaulted to a page ($N rows, not the whole store)"
else _fail "§6 absent limit returned $N rows — expected a bounded page"; fi
if grep -q "hasMore = true" /tmp/oqlguard_nolimit.txt; then _ok "§6 ...and says there is more to fetch"
else _fail "§6 defaulted page did not set hasMore"; fi

oql '{"start":"closedOrder","limit":100000000}' > /tmp/oqlguard_biglimit.txt
N=$(rows /tmp/oqlguard_biglimit.txt)
if [ "$N" -le 1000 ]; then _ok "§6 absurd limit clamped ($N rows)"
else _fail "§6 limit 1e8 returned $N rows — not clamped"; fi

# A huge offset must not be honoured verbatim; past the clamp there is nothing
# to return, and the request must still complete rather than blow the budget.
R=$(oql '{"start":"closedOrder","limit":10,"offset":100000000}')
assert_not_contains "§6 huge offset does not exceed the instruction limit" "$R" "exceeded the limit"
assert_contains "§6 huge offset completes past the end of the store" "$R" "hasMore = false"

# Paging still works normally under the clamp.
oql '{"start":"closedOrder","limit":5,"offset":0}' > /tmp/oqlguard_p1.txt
oql '{"start":"closedOrder","limit":5,"offset":5}' > /tmp/oqlguard_p2.txt
if [ "$(rows /tmp/oqlguard_p1.txt)" = "5" ] && [ "$(rows /tmp/oqlguard_p2.txt)" = "5" ] \
   && ! diff -q /tmp/oqlguard_p1.txt /tmp/oqlguard_p2.txt >/dev/null; then
  _ok "§6 ordinary paging is unaffected (two distinct 5-row pages)"
else _fail "§6 paging broke under the clamp"; fi

finish_test "oql_guard"
