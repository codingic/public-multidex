#!/usr/bin/env bash
# set_ai_key.sh — install (or rotate) the AI assistant's API key on a deployed
# backend, safely, at any time — including POST-LAUNCH.
#
# The key lives only in a stable var on the canister (never in source; the
# historical hardcoded key was rotated provider-side). The LAST provider set
# WINS — setting an Anthropic key switches the assistant to Anthropic, setting
# a Google key switches it (back) to Gemini. Pass an empty key to CLEAR that
# provider.
#
# The key is read, in order of preference:
#   1. --key-file <path>      (recommended: never lands in shell history)
#   2. $AI_API_KEY            (env var)
#   3. scripts/.google-api-key / scripts/.anthropic-api-key  (per-provider dotfile)
#   4. interactive prompt     (hidden input)
#
# Usage:
#   bash scripts/set_ai_key.sh --provider anthropic -e engine|subnet --identity <controller>
#   bash scripts/set_ai_key.sh --provider google --key-file /path/to/key -e engine|subnet --identity <controller>
#   AI_API_KEY=sk-... bash scripts/set_ai_key.sh --provider anthropic --backend <canister-id> -e engine|subnet --identity <controller>
#
# Requires: icp CLI; the identity must be a CONTROLLER of the backend
# (setGoogleApiKey / setAnthropicApiKey are controller-gated; hard no-ops on
# #production are NOT in place for these — the assistant is a launch feature —
# so treat the key as an ops secret).
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

PROVIDER=""; KEY_FILE=""; BACKEND="backend"; PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)  PROVIDER="$2"; shift 2 ;;
    --key-file)  KEY_FILE="$2"; shift 2 ;;
    --backend)   BACKEND="$2";  shift 2 ;;
    -e|--identity) PASS+=("$1" "$2"); shift 2 ;;
    *) echo "set_ai_key: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

# -e/--identity thread through PASS. If the caller named no identity, pin
# anonymous rather than inherit the CLI's machine-global default, which
# other sessions and connectors move at will (mdex-process-safety §5).
# Locally anonymous IS the controller; against engine/subnet an anonymous
# call fails loudly as a non-controller instead of racing the default.
case " ${PASS[*]:-} " in
  *" --identity "*) ;;
  *) PASS+=(--identity anonymous) ;;
esac

case "$PROVIDER" in
  google)    METHOD="setGoogleApiKey";    DOTFILE="$(dirname "$0")/.google-api-key" ;;
  anthropic) METHOD="setAnthropicApiKey"; DOTFILE="$(dirname "$0")/.anthropic-api-key" ;;
  *) echo "set_ai_key: --provider must be 'google' or 'anthropic'" >&2; exit 1 ;;
esac

KEY="${AI_API_KEY:-}"
if [ -n "$KEY_FILE" ]; then KEY="$(tr -d '[:space:]' < "$KEY_FILE")"; fi
if [ -z "$KEY" ] && [ -f "$DOTFILE" ]; then KEY="$(tr -d '[:space:]' < "$DOTFILE")"; fi
if [ -z "$KEY" ]; then
  printf "Paste the %s API key (input hidden; empty = CLEAR): " "$PROVIDER" >&2
  read -rs KEY; echo >&2
fi

echo "set_ai_key: calling $METHOD on '$BACKEND' (${PASS[*]})…"
icp canister call ${PASS[@]+"${PASS[@]}"} "$BACKEND" "$METHOD" "(\"$KEY\")" >/dev/null

# Verify via the public gate the frontend itself uses.
CONFIGURED=$(icp canister call --query ${PASS[@]+"${PASS[@]}"} "$BACKEND" aiConfigured "()" 2>/dev/null | grep -oE "true|false" | head -1)
if [ -n "$KEY" ]; then
  [ "$CONFIGURED" = "true" ] && echo "✓ key set — aiConfigured() = true (Ask AI tab live)" \
    || { echo "✗ key call succeeded but aiConfigured() != true — investigate" >&2; exit 1; }
else
  echo "✓ $PROVIDER key cleared — aiConfigured() = ${CONFIGURED:-?} (falls back to the other provider if set)"
fi
