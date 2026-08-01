#!/usr/bin/env bash
# Snapshot the live leaderboard into the Provisional Phase Leaders page data.
#
# Two artifacts per run:
#   src/frontend/public/assets/phase1-provisional.json  — PUBLIC page data:
#     usernames and numbers only, machinery rows dropped, ranks re-packed.
#     NO PRINCIPALS — the public board's privacy stance (PublicLeaderRow:
#     names here, principals on the tape, no surface that joins the two).
#   ops/phase1/leaderboard-<stamp>.json — the RAW rows incl. principals, for
#     the prize audit. ops/phase1/ is gitignored: this repo is heading open
#     source, and committing the username↔principal join would publish it.
#
# Machinery filter: profileless accounts render as truncated principals
# ("6fdjt…") — the deployed fallback — and "a profileless ranked account is
# operator machinery" (main.mo, leaderRowFor). Belt and braces, any row whose
# principal matches a live simbot identity is dropped too.
#
# Rerunnable: run again at the Phase boundary (after adminRecomputeLeaderboard,
# before resetSeason) to freeze the FINAL standings into the same files.
#
# NOTE the deployed API returns at most 50 rows. Until the resetSeason deploy
# ships (whose SeasonRecord carries the top 100), a snapshot lists the top
# ~50 minus machinery. The page copy states standings are partial+provisional.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

ENV_NAME="${1:-ic}"
IDENTITY="${2:-multidex}"
STAMP=$(date -u +%Y%m%d-%H%M)
RAW=$(icp canister call backend getLeaderboard "()" --query -e "$ENV_NAME" --identity "$IDENTITY" 2>/dev/null)
[ -n "$RAW" ] || { echo "✗ getLeaderboard returned nothing (env $ENV_NAME)"; exit 1; }

SIMBOTS=$(for i in $(seq 1 32); do icp identity principal --identity "simbot_$i" 2>/dev/null || true; done | tr '\n' ' ')

mkdir -p ops/phase1 src/frontend/public/assets
RAW="$RAW" SIMBOTS="$SIMBOTS" STAMP="$STAMP" python3 - <<'PY'
import json, os, re, datetime

raw, stamp = os.environ["RAW"], os.environ["STAMP"]
simbots = set(os.environ["SIMBOTS"].split())

def field(rec, name, cast=int):
    m = re.search(rf'{name} = (-?[\d_]+)', rec)
    return cast(m.group(1).replace('_','')) if m else None

rows = []
for rec in re.findall(r'record \{[^{}]*?rank =[^{}]*?\}', raw):
    u = re.search(r'user = "([^"]+)"', rec)
    n = re.search(r'username = "([^"]+)"', rec)
    if not (u and n): continue
    rows.append({
        "rank": field(rec, "rank"), "user": u.group(1), "username": n.group(1),
        "profitUsd": field(rec, "profitUsd"), "capitalUsd": field(rec, "capitalUsd"),
        "equityUsd": field(rec, "equityUsd"), "returnBps": field(rec, "returnBps"),
        "feeLevel": field(rec, "feeLevel"), "badgeCount": field(rec, "badgeCount"),
    })
rows.sort(key=lambda r: r["rank"])
total = int(re.search(r'totalRanked = ([\d_]+)', raw).group(1).replace('_',''))
as_of_ns = int(re.search(r'computedAtNs = ([\d_]+)', raw).group(1).replace('_',''))
as_of = datetime.datetime.fromtimestamp(as_of_ns/1e9, datetime.timezone.utc)

audit = {"snappedAt": stamp, "computedAtNs": as_of_ns, "totalRanked": total, "rows": rows}
with open(f"ops/phase1/leaderboard-{stamp}.json", "w") as f: json.dump(audit, f, indent=1)

def machinery(r):
    return "…" in r["username"] or r["user"] in simbots

humans = [r for r in rows if not machinery(r)]
public = {
    "phase": 1,
    "asOf": as_of.strftime("%Y-%m-%d %H:%M UTC"),
    "totalRanked": total,
    "rows": [{
        "rank": i+1, "username": r["username"],
        "profitUsd": round(r["profitUsd"]/1e8, 2), "returnBps": r["returnBps"],
        "feeLevel": r["feeLevel"], "badgeCount": r["badgeCount"],
    } for i, r in enumerate(humans)],
}
with open("src/frontend/public/assets/phase1-provisional.json", "w") as f:
    json.dump(public, f, indent=1)
print(f"✓ {len(rows)} rows fetched → {len(humans)} traders "
      f"({len(rows)-len(humans)} machinery rows dropped), as of {public['asOf']}")
print(f"✓ public : src/frontend/public/assets/phase1-provisional.json")
print(f"✓ audit  : ops/phase1/leaderboard-{stamp}.json  (gitignored)")
PY
