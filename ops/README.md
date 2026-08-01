# ops/ — operator-box supervision

Templates for the launchd jobs that keep the **live subnet** (multidex.ai)
fleet running. Paths are placeholders so the files carry no personal home
directory into the open-source repo.

| file | job |
|---|---|
| `ai.multidex.bots.plist.template` | the trading fleet, `KeepAlive` |
| `ai.multidex.botlog-rotate.plist.template` | hourly 10 MiB cap on its log |

Install both:

```bash
for t in ops/*.plist.template; do
  name=$(basename "$t" .template)
  sed -e "s|__PROJECT_DIR__|$PWD|g" -e "s|__HOME__|$HOME|g" "$t" > ~/Library/LaunchAgents/"$name"
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/"$name"
done
```

Status, logs, and a real stop (a plain `kill` only bounces a `KeepAlive` job):

```bash
launchctl print gui/$(id -u)/ai.multidex.bots | grep -E 'state|pid|runs'
tail -f ~/Library/Logs/mdex-bots.log
launchctl bootout gui/$(id -u)/ai.multidex.bots
```

**Why `MDX_FOREGROUND=1`.** `start_bots_<target>.sh` normally daemonises and
returns, which is right in a terminal and wrong under a supervisor: launchd
would see the job exit immediately, restart it, and hit the pidfile guard —
a throttled crash-loop. In foreground mode the starter `exec`s the engine, so
launchd supervises the fleet itself and its signals reach the cleanup trap.

Fleet size, pace and margin collateral live in `scripts/lib/targets.sh`, not
here — the launch profile belongs in version control with the code.
