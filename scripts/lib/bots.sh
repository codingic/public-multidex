#!/usr/bin/env bash
# scripts/lib/bots.sh — start/stop the trading simulators for ONE target.
#
# SOURCE THIS from a start_bots_<target>.sh / stop_bots_<target>.sh wrapper.
# It is never invoked directly and takes no target from the environment: the
# wrapper passes it, so the target is always visible in the command that was
# typed, in the launched process's argv, and in the PID file.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/targets.sh"

# Which simulator drives each target.
#
# trading_simulation.sh supersedes the other two and is the one to run. The
# Every target runs the strategy engine; the old spot-only sim_trading.sh
# retired at the Phase I -> II reset (2026-08-01).
# driving multidex.ai's live volume today — switching the live fleet's engine
# is a behavioural change that belongs in its own commit, not in a refactor
# whose point is to stop things getting mixed up. When it is switched, this is
# the single line to change.
mdx_engine_for() {
  case "$1" in
    local|engine) echo "trading_simulation.sh" ;;
    subnet)       echo "trading_simulation.sh" ;;
  esac
}

mdx_bots_start() {
  local target="$1"; shift
  mdx_target_valid "$target" || mdx_die "unknown target '$target'"
  mkdir -p "$MDX_RUN_DIR"

  local pidfile; pidfile=$(mdx_pidfile "$target")
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    mdx_die "bots already running for '$target' (pid $(cat "$pidfile")) — stop_bots_$target.sh first"
  fi

  # Bare calls: these must be able to kill THIS shell (see targets.sh).
  mdx_assert_runtime_posture_for_target "$target"
  mdx_assert_identity "$target"
  local mode="$MDX_POSTURE" identity="$MDX_IDENTITY"
  local env_name; env_name=$(mdx_env_for "$target")
  local engine;   engine=$(mdx_engine_for "$target")
  local bots="${MDX_BOTS:-$(mdx_bots_for "$target")}" interval="${MDX_INTERVAL:-$(mdx_interval_for "$target")}"
  local pool_fund="${POOL_FUND_USD:-$(mdx_pool_fund_for "$target")}"
  local log="$MDX_RUN_DIR/bots-$target.log"

  # The target is passed to the engine in ARGV as well as via the variables it
  # reads, so `ps` shows which venue a bot fleet points at. Before this, the
  # target lived only in IC_ENV — invisible to ps — and a bare pattern kill
  # could not tell a local fleet from the one driving multidex.ai.
  mdx_info "starting bots → $target (env $env_name, identity $identity, posture #$mode, engine $engine)"

  # FOREGROUND mode, for a supervisor that expects to own the process
  # (launchd KeepAlive, systemd). The default backgrounds with nohup and
  # returns, which is right for a terminal but wrong under a supervisor: it
  # would see the starter exit within a second, restart it, and then hit the
  # "already running" pidfile guard — a throttled crash-loop. `exec` replaces
  # this shell so the supervisor's PID *is* the fleet, and its stop/restart
  # signals reach the engine's cleanup trap directly.
  if [ -n "${MDX_FOREGROUND:-}" ]; then
    echo "$$" > "$pidfile"
    mdx_ok "bots (foreground) for '$target' — $bots bots @ ${interval}s, pid $$"
    if [ "$target" = "local" ]; then
      exec env MDX_TARGET="$target" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
        bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval"
    else
      exec env MDX_TARGET="$target" IC_ENV="$env_name" BOT_IDENTITY="$identity" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
        bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval"
    fi
  fi

  if [ "$target" = "local" ]; then
    nohup env MDX_TARGET="$target" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
      bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval" \
      > "$log" 2>&1 &
  else
    nohup env MDX_TARGET="$target" IC_ENV="$env_name" BOT_IDENTITY="$identity" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
      bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval" \
      > "$log" 2>&1 &
  fi
  local pid=$!
  echo "$pid" > "$pidfile"
  sleep 1
  kill -0 "$pid" 2>/dev/null || { rm -f "$pidfile"; mdx_die "bots exited immediately — see $log"; }
  mdx_ok "bots running for '$target' (pid $pid, $bots bots @ ${interval}s) — log: $log"
  mdx_info "stop with: bash scripts/stop_bots_$target.sh"
}

mdx_bots_stop() {
  local target="$1"
  mdx_target_valid "$target" || mdx_die "unknown target '$target'"
  local pidfile; pidfile=$(mdx_pidfile "$target")

  if [ ! -f "$pidfile" ]; then
    mdx_ok "no bots recorded for '$target' (nothing to stop)"
    # Deliberately NOT falling back to a pattern search. A pattern cannot tell
    # this target's fleet from another's — that is the whole bug — so an
    # unrecorded fleet is reported, not guessed at.
    local stray
    stray=$(pgrep -f "MDX_TARGET=$target" 2>/dev/null | tr '\n' ' ')
    [ -n "$stray" ] && mdx_warn "processes tagged MDX_TARGET=$target exist but are not in a PID file: $stray
   (started outside the wrappers — stop them with the PID their own output printed)"
    return 0
  fi

  local pid; pid=$(cat "$pidfile" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    mdx_ok "bots for '$target' already stopped (stale PID file cleared)"
    rm -f "$pidfile"
    return 0
  fi

  mdx_info "stopping bots for '$target' (pid $pid and descendants)"
  mdx_kill_tree "$pid"
  rm -f "$pidfile"
  mdx_ok "bots stopped for '$target' — no other target was touched"
}
