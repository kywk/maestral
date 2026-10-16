# Operations — Maestral fork

This fork of Maestral runs as a launchd-managed background daemon on this Mac
(user `kywk`). The GUI is a separate, optional app. All commands below assume
the daemon venv CLI is on `PATH` via `~/.local/bin/maestral`.

## Component map

| Component | Location / label |
| --- | --- |
| Canonical checkout | `/Users/kywk/kywk/project/maestral` (origin `github.com:kywk/maestral`) |
| Daemon venv | `/Users/kywk/.local/share/maestral-fork/venv` |
| launchd agent | `com.samschott.maestral-daemon.maestral` — plist in `~/Library/LaunchAgents/`; runs `<venv>/bin/maestral start --foreground --config-name maestral` (`PYTHONOPTIMIZE=2`), `RunAtLoad=true`, no `KeepAlive` |
| CLI | `~/.local/bin/maestral` → symlink to `<venv>/bin/maestral` |
| Config + state | `~/Library/Application Support/maestral/` (`maestral.ini`, `maestral.state`, `maestral.db`, `maestral.lock`, `maestral.sock`) |
| Logs | `~/Library/Logs/maestral/maestral.log` (+ rotated `maestral.log.1`) |
| Healthcheck | agent `com.kywk.maestral-healthcheck` (every 900 s) → `~/.local/bin/maestral-healthcheck`; history `~/.local/share/maestral-healthcheck/history.log`; agent stdout/err in `~/Library/Logs/maestral-healthcheck.{out,err}.log` |
| Deploy script | `scripts/deploy.sh` (installs a git ref into the daemon venv, restarts the agent) |
| GUI (manual) | `/Applications/Maestral.app` — `open -a Maestral` |
| Dropbox token | macOS Keychain, service `Maestral` (account `config:maestral:dbid:…`), via keyring |

Quitting the GUI does **not** stop sync: the daemon keeps running under launchd.

## Daily operations

```bash
maestral status              # account, usage, sync status, error count
maestral pause               # pause syncing (daemon stays up)
maestral resume
maestral stop                # stop daemon; launchd will NOT auto-restart it
launchctl kickstart -k gui/$(id -u)/com.samschott.maestral-daemon.maestral  # (re)start now
launchctl print gui/$(id -u)/com.samschott.maestral-daemon.maestral | grep state

open -a Maestral             # GUI on demand
maestral activity            # live event stream
maestral filestatus <path>   # sync state of one item
```

Healthcheck, manually:

```bash
~/.local/bin/maestral-healthcheck          # runs checks, appends to history.log, exit 0
~/.local/bin/maestral-healthcheck --test   # sends a test notification
tail ~/.local/share/maestral-healthcheck/history.log
```

## Update flow

1. Make changes in a worktree, run the offline suite:
   `pytest tests/offline -q` (green on the installed dropbox SDK).
2. Merge to `main` in `/Users/kywk/kywk/project/maestral` and tag the release
   (`git tag vX.Y.Z`). Version bump files: `pyproject.toml`,
   `src/maestral/__init__.py`, `docs/conf.py`, `.bumpversion.cfg`,
   `.bumpversion-cross-dependencies.cfg` (GUI pins are frozen — see below), plus
   `CHANGELOG.md`.
3. Deploy the tag into the daemon venv and restart it:
   ```bash
   bash scripts/deploy.sh vX.Y.Z
   ```
   The script runs `pip install --force-reinstall --no-deps` on purpose:
   `--no-deps` keeps the existing dependency set (in particular the dropbox SDK)
   untouched. Deploying code never changes dependencies.
4. Verify: `maestral status`; `tail -50 ~/Library/Logs/maestral/maestral.log`.

After a dependency change (rare), update the daemon venv explicitly and restart:

```bash
/Users/kywk/.local/share/maestral-fork/venv/bin/pip install 'dropbox==X.Y.Z'
launchctl kickstart -k gui/$(id -u)/com.samschott.maestral-daemon.maestral
```

## Rollback

```bash
bash scripts/deploy.sh v1.10.0   # any older existing tag
# and, if a dependency was also changed:
/Users/kywk/.local/share/maestral-fork/venv/bin/pip install 'dropbox==12.0.2'
launchctl kickstart -k gui/$(id -u)/com.samschott.maestral-daemon.maestral
```

Deploys never touch `maestral.ini` / `maestral.db` / `maestral.state`, so a code
rollback is safe and keeps sync history.

## Troubleshooting

- **Crash loop**: daemon exits right after start; `maestral status` may show
  `Paused` (a crashed sync cycle sets paused) and `maestral.log` shows repeated
  `Traceback`. The healthcheck sends a "BAD" notification. First read the last
  tracebacks, then stop the daemon (`maestral stop`) and roll back to the last
  known-good tag. A single `Paused` usually recovers with `maestral resume`.
- **Daemon not running**: if the launchd job state is not `running`,
  `launchctl kickstart -k …` starts it; check `maestral status` afterwards.
  The healthcheck already attempts one self-heal kickstart per run.
- **Healthcheck notifications**: sent on an OK → BAD transition (then at most
  hourly while BAD). BAD means one of: launchd job not running after one
  self-heal attempt, `maestral status` failing/timing out, status not in
  {Up to date, Syncing, Connecting…}, sync errors > 0, or new
  `ERROR|Traceback|Unexpected error` lines in the log. Details are in
  `history.log`, which also carries the byte-offset `log.cursor` used to scan
  forward from.
- **Index corruption** (endless `DataCorruptionError`, cursor resets, entries
  out of sync): `maestral rebuild-index`. It re-downloads the remote index;
  local files are untouched.
- **Lost/revoked token**: token lives in the macOS Keychain (service
  `Maestral`). `maestral auth status` shows link status; re-link with
  `maestral auth unlink` followed by `maestral auth link`.
- **Backup**: `maestral.db` (SQLite, sync index) is the only state worth
  backing up: stop the daemon, copy
  `~/Library/Application Support/maestral/maestral.db`, start again.
- **Logs**: `maestral log` (CLI) or read the files directly; keep an eye on
  `maestral.log.1` for pre-restart context.

## Dependency policy

- dropbox SDK: runtime compatibility with 12.1+ was restored in v1.10.1
  (verified offline against 12.0.2, 12.1.0 and 12.2.3); `pyproject.toml` allows
  `dropbox>=11.28.0,<13.0`. Do not re-introduce a `<12.1` ceiling. Note: 11.x
  cannot even import with setuptools ≥ 81 (`pkg_resources` removal), so 12.x is
  what this machine actually runs.
- Deploys must not touch dependencies (`scripts/deploy.sh` uses `--no-deps`),
  so a bad dependency can never ride along with a code deploy.
- The `[gui]` extra pins are frozen at the newest existing releases —
  `maestral-qt>=1.9.8,<2` and `maestral-cocoa>=1.9.6,<2` — because upstream GUI
  packages never reached 1.10. `.bumpversion-cross-dependencies.cfg` no longer
  rewrites them (that would point at nonexistent versions).
