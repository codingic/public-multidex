#!/usr/bin/env bash
# stop_bots_subnet.sh — stop ONLY the subnet fleet.
#
# Kills by ancestry from the PID recorded at launch, never by pattern: a
# pattern cannot distinguish this fleet from one driving another venue, which
# is how the live subnet fleet was killed twice.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/bots.sh"
mdx_bots_stop "subnet"
