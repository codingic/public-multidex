---
name: mdex-process-safety
description: How to find, wait on, and stop processes on this machine without hanging or killing someone else's work. Read BEFORE writing any pgrep/pkill/ps lookup, before polling for a background job or deploy to finish, before stopping a bot fleet, simulator, or dev server, before running or scripting any icp CLI command (the identity rules), and before trusting a red test run. This machine runs many parallel Claude sessions plus long-lived MULTI/DEX fleets driving the LIVE subnet, so pattern-matching a process is never safe here.
metadata:
  title: Process safety on a shared machine
  category: Operations
---

# Process safety on a shared machine

This checkout is worked on by **many Claude sessions at once**, on a machine that is
also running **long-lived bot fleets** — one against the local replica, one against the
cloud engine, and one driving the **live subnet at multidex.ai**. Several worktrees of
other projects run their own background jobs beside them.

Two consequences, and both have already cost real time:

- **A process pattern you write will match things you did not mean** — other sessions'
  shells, other fleets, and *your own waiter*.
- **A wait that never ends looks exactly like work in progress.** Nobody notices for
  twenty minutes.

---

## 1. Never wait by `pgrep`. It matches your own shell.

This hangs forever:

```bash
until ! pgrep -f "cold_start.sh --mode full" >/dev/null; do sleep 5; done
```

The pattern string is **inside the waiting shell's own command line**, so `pgrep -f`
matches the waiter itself. The condition can never go false. `pgrep` excludes its own
PID, not its parent's, so this is not defended against.

Three of these were spawned in one session on 2026-08-05. One was supposed to run the
integration suite after a deploy; it sat in the loop and the suite **never started**,
while a `pgrep -f run_all.sh` status check "confirmed" it was running — that check
matched the stuck waiter's command text, not a real process.

**Instead:**

- **Preferred — don't poll at all.** Launch with the Bash tool's `run_in_background` and
  let the completion notification wake you. For "A then B", put both in *one*
  backgrounded command: `bash a.sh && bash b.sh`. No waiter, nothing to self-match.
- **If you must poll a process, poll a PID you captured**, never a pattern:
  ```bash
  bash long_thing.sh & PID=$!
  until ! kill -0 "$PID" 2>/dev/null; do sleep 5; done
  ```
- **If you must poll for a condition, poll a marker the job writes** — a file, a log
  line — and make sure the marker can actually appear. A second waiter that session
  polled for `"Cold start complete|✗|Error|failed"`; the script prints none of those
  strings, so its exit condition could never fire either. Before arming a grep-based
  wait, grep the *finished* log of a previous run for the pattern.

---

## 2. Never `pkill -f` / pattern-kill. Kill by PID or by ancestry.

The repo's incident trail records a pattern kill taking down the **live subnet fleet**
on 2026-07-23, 2026-07-28 and 2026-08-01. `pkill -f simulate_trading.sh` could not tell
a local simulator from the one driving multidex.ai, and a legacy fleet carried its
target only in `IC_ENV` — invisible to `ps`.

The repo already has the correct architecture. **Use it, do not reinvent it:**

| Need | Use |
|---|---|
| Start a fleet | `bash scripts/start_bots_<target>.sh` |
| Stop a fleet | `bash scripts/stop_bots_<target>.sh` |
| What is recorded | `.run/bots-<target>.pid` — one supervisor PID per target |
| How stopping works | `mdx_kill_tree` in `scripts/lib/bots.sh` — walks `pgrep -P` (parent), never a name |

`stop_bots_<target>.sh` **deliberately does not fall back to a pattern search** when the
PID file is missing. It reports the unrecorded processes and stops. Preserve that. An
unrecorded fleet is a thing for a human to look at, not something to guess at.

If you truly must stop something with no PID file: identify it with
`ps -eo pid,ppid,etime,command`, confirm which target it drives, and `kill` **that
numeric PID**. Never a pattern. Never in a loop.

Before killing anything, check what else is running so you can prove you didn't touch it:

```bash
ps -eo pid,ppid,etime,command | grep '[t]rading_simulation'
```

Other sessions' jobs are usually recognisable by a different parent shell and a
different worktree path in their command line. Leave them alone.

---

## 3. Verify the effect, not the mechanism

A guard that fails silently is worse than no guard, because the run still prints a
total and the total gets believed.

`tests/run_all.sh`'s bot guard was inert for its whole life: it resolved the stopper via
`$(dirname "$0")/../scripts/...` while the script had already `cd`-ed into `tests/`, so
from the repo root it tested a path that does not exist, and the `if` had no `else`. It
worked when run from inside `tests/` and no-oped when run the normal way. It was read,
reviewed and *documented as fixed* before anyone watched it actually stop a fleet. The
suite came back **20 red**; the true number was lower and 7 of those tests were pure
simulator noise.

So:

- After a stop, assert the thing is **gone**: `kill -0 "$PID"` fails, PID file removed.
- After a start, assert it is **there** and recorded.
- In scripts, prefer `$SCRIPT_DIR` (absolute, computed once at the top) over
  `$(dirname "$0")` — `$0` is the invocation path and breaks the moment anything `cd`s.
- Gate on `-f`, not `-x`, for a helper you invoke as `bash <path>`; it needs no
  executable bit, and `-x` lets a stray `chmod` silently disable the guard.
- Any guard whose failure mode is "do nothing" needs an `else` that says so out loud.

---

## 4. Before you trust a red test run

Integration results here are only meaningful on a **quiet, freshly seeded** venue. Two
independent things corrupt them, and both look like code regressions:

1. **A bot fleet trading underneath the assertions.** Confirm the suite printed
   `Stopping the local simulator…` and that `.run/bots-local.pid` is gone. Symptoms:
   value-conservation drift, moving balances, `arb "idle"`, anchors that will not stay put.
2. **A venue an earlier run already wiped.** `tests/test_state_reset.sh` calls
   `resetExchange` near the end of the suite, so a *second* run starts against an empty
   exchange — no AMM pools, no vault. The suite is **not idempotent across runs**.
   Symptoms: zeros where money should be (`vaultLPSupply = 0`, balances `0`, nothing
   staged), and empty `got:` values.

Cheap check before believing anything:

```bash
echo y | icp canister call backend getAmmPools '()' --query --identity anonymous
```

`(vec {})` means the venue is wiped — reseed with `bash scripts/cold_start.sh --mode full`
and re-run. Otherwise you are reading noise.

---

## 5. Never use the CLI's default identity. Every `icp` command carries `--identity`.

The default identity lives in the machine-global icp store
(`~/Library/Application Support/org.dfinity.icp-cli/identity/identity_defaults.json`)
and is state **this repo does not own**. Other sessions and connected MCP connectors
(the Open SaaS connector holds its own principals) move it whenever they like — on
2026-08-06 it changed hands twice within hours (`opensaas`, then `opensaas-engine`)
while three workstreams shared the machine — including between your
`icp identity default` call and the command a line later.

When that happens the command runs as whoever won the race. A deploy runs as a
non-controller and every canister fails with `IC0512 ... Only controllers ... can call
ic00 method update_settings` — which reads like a project permissions bug and is not
one. A bare `icp canister call` silently acts as the wrong principal — on the live
subnet that misattributes actions on the public, principal-attributed tape.

Two rules, no exceptions:

- **Every `icp` invocation that acts as an identity carries `--identity <name>`** —
  `icp deploy`, `icp canister call`, `icp canister status`, scripts, one-off shell
  lines, all of it. `--identity` scopes the identity to that one command and cannot
  be raced.
- **Never run `icp identity default <name>`.** Reading the default is unreliable
  precisely because other actors write it; do not become one of them. A workstream
  that genuinely needs its own ambient identity gets an isolated store via
  `ICP_HOME=<dir>`, never the shared default.

Locally the controller is `anonymous`; admin scripts use `alice`.
