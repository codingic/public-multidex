#!/usr/bin/env bash
# rotate_log.sh — cap a log file that a RUNNING process holds open.
#
#   usage: bash scripts/rotate_log.sh <logfile> [cap_bytes] [keep]
#          bash scripts/rotate_log.sh ~/Library/Logs/mdex-bots.log 10485760 3
#
# Written for the launchd bot fleet (ai.multidex.bots), whose stdout/stderr
# launchd appends to forever with no rotation of its own. macOS newsyslog
# would need root, so this runs as a user launchd agent instead.
#
# WHY TRUNCATE IN PLACE rather than mv-and-recreate: launchd opens the log
# once and hands that file DESCRIPTOR to the job. Renaming the file does not
# move the descriptor — the fleet would keep writing to the now-orphaned
# inode, the freshly created file would stay empty forever, and the "rotated"
# data would be invisible until the job restarted. Copying the contents out
# and then truncating the ORIGINAL keeps the inode (and every open fd) valid,
# so writers continue seamlessly.
set -uo pipefail

LOG="${1:?usage: rotate_log.sh <logfile> [cap_bytes] [keep]}"
CAP="${2:-10485760}"   # 10 MiB
KEEP="${3:-3}"         # generations of .N.gz to retain

[ -f "$LOG" ] || { echo "rotate_log: $LOG does not exist — nothing to do"; exit 0; }

size=$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)
if [ "$size" -le "$CAP" ]; then
  exit 0   # silent no-op: this runs hourly and must not spam its own log
fi

# Age the existing generations: .2.gz -> .3.gz, .1.gz -> .2.gz, ...
i="$KEEP"
while [ "$i" -gt 1 ]; do
  prev=$((i - 1))
  [ -f "$LOG.$prev.gz" ] && mv -f "$LOG.$prev.gz" "$LOG.$i.gz"
  i="$prev"
done

# Snapshot the current contents, then truncate the original IN PLACE so the
# fleet's open descriptor keeps working (see the note above).
cp "$LOG" "$LOG.1" && : > "$LOG"
gzip -f "$LOG.1" 2>/dev/null || true

echo "rotate_log: $(basename "$LOG") hit $size bytes (cap $CAP) — archived to $(basename "$LOG").1.gz and truncated"
