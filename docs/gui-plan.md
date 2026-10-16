# macOS GUI strategy — analysis and plan

Scope: how to keep a working macOS GUI for this fork's daemon. The daemon
(`kywk/maestral` v1.10.0) is CLI/launchd-managed; the GUI is the frozen upstream
**Maestral.app 1.9.5** that talks to it over Pyro. Upstream core and
`samschott/maestral-cocoa` were both archived on 2026-06-28, so no further official
app builds or fixes will appear. This document records verified facts, compares three
options plus one sketch, and gives a recommendation with trigger conditions.

## 1. Current state (verified on 2026-10-16, read-only)

- App bundle: `/Applications/Maestral.app`, `CFBundleShortVersionString` **1.9.5**,
  build 113, `LSUIElement` (menu-bar only), universal x86_64/arm64. Installed Oct 5
  2025; notarized `Developer ID Application: Sam Schott (G34LNR8C4Y)`,
  `spctl: accepted`, hardened runtime.
- Bundled runtime: CPython **3.12**, `toga`/`toga-cocoa` **0.5.2**, `rubicon-objc`
  0.5.2, bundled core **maestral 1.9.5**, dropbox 12.0.2, desktop-notifier 6.2.0,
  watchdog 6.0.0. `Contents/MacOS/maestral-cli` ships a CLI pointed at the bundle.
- Update channel: Sparkle with `SUFeedURL=https://maestral.app/appcast.xml`; the feed
  currently advertises 1.9.5/build 113 (= installed), so Sparkle has nothing to do.
  The feed and the public key are baked into the signed bundle; the fork cannot
  re-point them without a rebuild.
- Distribution: Homebrew cask `maestral` 1.9.5 (`auto_updates`) pulling
  `Maestral-1.9.5.dmg` from the **core** repo release `SamSchott/maestral` v1.9.5;
  `samschott/maestral-cocoa` has no releases and only source. The cask also links
  `/opt/homebrew/bin/maestral` → the app's bundled CLI.
- Daemon relationship:
  - CLI and GUI use the same Pyro socket
    `~/Library/Application Support/maestral/maestral.sock`; the fork has not changed
    the RPC surface, so GUI 1.9.5 ↔ daemon 1.10.0 is protocol-compatible.
  - Quitting the GUI stops the daemon only if the GUI started it; if a daemon was
    already running (the launchd case), quitting leaves it running
    (`maestral_cocoa/app.py`: "Only quit the GUI but keep a previously started daemon
    running").
  - **Footgun:** `maestral_cocoa/__main__.py` calls `start_maestral_daemon_process()`,
    and in the frozen bundle that re-invokes the app stub with
    `-c "import maestral.daemon; ..."`. `maestral/daemon.py:freeze_support()` detects
    exactly that string and starts a daemon **from the bundle's bundled core 1.9.5**.
    So if the fork daemon is not running when the app is opened — or when someone runs
    `/opt/homebrew/bin/maestral` (cask symlink → bundled CLI) or
    `Maestral.app/Contents/MacOS/maestral-cli --cli` — an upstream 1.9.5 daemon comes
    up against the live account, without this fork's fixes.
  - This machine already mitigates it: fork daemon agent
    `com.samschott.maestral-daemon.maestral` (venv Python 3.13, launchd) runs the fork;
    the GUI "start on login" agent `com.samschott.maestral.maestral` is
    disabled (`*.disabled-20261015`); `~/.local/bin/maestral` (1.10.0) precedes
    `/opt/homebrew/bin/maestral` (1.9.5) on PATH; `maestral-healthcheck` runs every
    15 min. Keep all four properties.
- Notifications without the GUI — **currently broken on macOS, verified empirically**:
  - Sync notifications are sent by the **daemon** (`src/maestral/notify.py` →
    desktop-notifier), not by the GUI.
  - desktop-notifier 6.2.0 selects the real backend only when
    `NSBundle.mainBundle.bundleIdentifier` is non-nil; the fork daemon runs from a
    plain venv (mise Python 3.13, unsigned), so it gets `DummyNotificationCenter`.
    Test from the daemon venv printed `backend: DummyNotificationCenter`, warning
    "Notification Center can only be used from an app bundle", and `send()` silently
    succeeded. Maestral even silences the `desktop_notifier` logger to ERROR, so
    nothing appears in the log.
  - Net effect today: sync issues/errors produce **no desktop notifications in
    daemon+CLI mode**; `maestral-healthcheck` works around this with `osascript`
    for its own alerts. On Linux the dbus backend works from any process.

## 2. Options

### (a) Freeze the 1.9.5 app as-is; watch for breakage

Keep `/Applications/Maestral.app` (1.9.5) as the menu-bar GUI and the fork daemon on
launchd; update only the daemon (`scripts/deploy.sh`). Keeps: menu-bar
status/pause/resume, selective-sync picker, activity window, setup wizard, share-link
UI — zero GUI work.

Costs/risks: no desktop notifications (see above); the app will never receive fixes —
notably the cocoa-side fixes merged after the 1.9.5 build (commits 2025-10-18:
"Start maestral daemon before instantiating the GUI", "Move any Widget instantiation
out of class attributes", upstream's "multithreading/deadlock when using the macOS
GUI" fix; `maestral-cocoa` 1.9.6 is on PyPI but **no 1.9.6 dmg was ever released** —
core's last GitHub release and appcast entry remain 1.9.5/build 113); the bundled
Python 3.12 framework and Toga 0.5.2 are frozen against future macOS releases;
Sparkle is inert (feed says "no update"); the Homebrew cask depends on a GitHub
release asset from an archived repo that could be removed.

Breakage detection checklist (after each macOS major upgrade, and every ~quarter):

1. Launch the app; confirm the menu-bar icon appears and the menu opens.
2. Open **Activity** and **Selective sync** windows once (Toga/rubicon breakage
   typically shows here, cf. upstream #1032, #1135).
3. Quit the GUI; `launchctl print gui/$(id -u)/com.samschott.maestral-daemon.maestral`
   must still show `state = running`; `maestral status` (fork CLI) must answer.
4. `ps -Ao pid,command | grep -i maestral` — exactly one daemon, running from
   `~/.local/share/maestral-fork/venv`, never from the app bundle.
5. `log show --last 1d --predicate 'process == "Maestral"' --style compact | tail`
   for crash/fault lines.
6. `codesign --verify --deep --strict /Applications/Maestral.app` and
   `spctl -a -vvv` still pass.
7. Keep an archival copy so a cask/dmg disappearance cannot strand you:
   `ditto -c -k --keepParent /Applications/Maestral.app ~/Backups/Maestral-1.9.5.app.zip`
   plus the 1.9.5 dmg.

### (b) Rebuild a forked maestral-cocoa against this fork's core

What upstream does (from `samschott/maestral-cocoa`): Briefcase project
(`[tool.briefcase]` in `pyproject.toml`) using a custom template
`samschott/briefcase-macOS-Xcode-template@maestral-v2`; `requires` pins
`maestral==1.9.7.dev0` **from PyPI** plus chardet/click/markdown2/rubicon-objc/toga
pins; Sparkle feed URL + EdDSA public key in config; build workflow on a `macos-26`
runner imports Sam's Developer ID cert, stores notarization credentials, installs the
python.org 3.12.2 package, runs `briefcase create/build/package macOS Xcode`, then
`scripts/post-build-macos.py` (adds entry-point metadata, copies and codesigns
`Contents/MacOS/maestral-cli` with hardened runtime, compiles `.py` → optimized
`.pyc` and deletes sources) and uploads the dmg.

Fork adaptation sketch:

1. Fork/copy `maestral-cocoa` (upstream 1.9.6 source; the archived `maestral-v2`
   template branch is referenced by its Briefcase config); bump `requires` to this
   fork's core. Briefcase `requires` are pip requirements, so either publish the fork
   wheel to (Test)PyPI — acceptable, its name can stay `maestral` — or point at a local
   build artifact with a PEP 508 direct reference
   (`maestral @ file:///.../maestral-1.10.0-py3-none-any.whl`). **The fork core is not
   on PyPI** (PyPI `maestral` stops at 1.9.6), so a direct reference or a private index
   is required.
2. Install Xcode + Briefcase + the python.org 3.12 build the workflow uses; `briefcase
   create macOS Xcode` reuses the archived template — worth pinning Briefcase to the
   version that worked (0.3.20-era) because the template is unmaintained.
3. Build unsigned/ad-hoc (`briefcase package macOS Xcode --adhoc-sign`); notarization
   needs your own Apple Developer ID ($99/yr) and is unnecessary for personal use.
   Gatekeeper will quarantine a downloaded copy; locally built apps run fine.
4. Item to test **early** (30-minute spike): whether an ad-hoc-signed bundle may post
   `UNUserNotificationCenter` notifications. That determines whether (b) alone
   restores notifications; if not, the notify fallback below is still needed.

Cheap validation before committing to (b): install `maestral-cocoa==1.9.6` from PyPI
into a throwaway venv and run it against the fork daemon to confirm the 1.9.6 cocoa
code still speaks to core 1.10.0 — that isolates RPC/protocol risk from Briefcase
build risk. Note a fork-side nit that blocks the "install the GUI into the fork venv"
route: the fork's `gui` extra pins `maestral-cocoa>=1.10.0` while PyPI has only 1.9.6,
and `maestral/cli/cli_core.py:gui()` refuses to launch a GUI whose version is not in
the extra's specifier — relax that requirement for any venv-installed GUI path.

Effort: ~0.5–1 day for the first working build (template/Briefcase/Xcode quirks are
the variable); ~1–2 h per later rebuild. Ongoing risk is the archived template.

Behaviour after (b): the bundled daemon carries the fork fixes and can notify, but an
app-owned daemon dies when the app quits. Practical choice: keep the launchd daemon
as the always-on engine and the app purely as a GUI (notifications then still need the
fallback), or let the app own the daemon and keep it running at login.

### (c) CLI-only (drop the GUI)

Keeps: everything sync-critical; `maestral status|pause|resume|activity|history|
filestatus|ls|excluded add/remove|sharelink|autostart|...` cover the daily operations,
including share links (no GUI needed) and selective sync via `excluded add/remove`.
Loses: menu-bar at-a-glance status, one-click pause/resume, the folder-tree picker for
selective sync, the activity *window* (the `activity` TUI remains), first-run wizard,
update prompts, notification click actions — and, today, all desktop notifications.
Gains: no Toga/Python-3.12 bundle to rot, no upstream-daemon footgun, nothing to
maintain beyond the daemon + launchd + healthcheck. Best paired with a small
notification fallback (below); cost is essentially zero, real cost is ergonomics.

### (d) Minimal custom menu-bar app (out of scope; feasibility note)

A ~200–400-line Swift/SwiftUI `LSUIElement` app (or a pyobjc agent) that polls
`maestral status` / talks the same Pyro socket and shells out to
`maestral pause|resume|sharelink`. It would give status + pause/resume + native
notifications without Toga, but it is a new codebase to own (1–2 days initial,
ongoing maintenance). Reasonable fallback if (b) becomes painful and the tray is
missed. Not recommended now.

### Notification fallback (orthogonal, cheap — recommended either way)

The gap is not the GUI: it is that the daemon process is not in an app bundle. A
small fork change in `src/maestral/notify.py` to fall back to
`osascript -e 'display notification ...'` (already the healthcheck's pattern) when
desktop-notifier selects `DummyNotificationCenter` restores sync-issue alerts in
daemon+CLI mode. Roughly **S** (hours), low risk, no new runtime dependency, and it
makes option (a)/(c) sustainable without rebuilding anything.

## 3. Recommendation

**Keep (a) as the primary strategy now**, with the quarterly/macOS-upgrade checklist
and an archived copy of the app; add the `notify.py` osascript fallback so the
daemon-only setup regains sync notifications. Treat (b) as a **pre-planned, tested
fallback**: when the trigger fires, rebuild the forked cocoa app against the fork
core (recipe above) rather than adopting (c) unless the tray is genuinely unused.
Doing a (b) dry run (one ad-hoc build that connects to the fork daemon) is a good
investment if you want the fallback to be ready ahead of time; otherwise, budget the
first 0.5–1 day at trigger time. Stay CLI-first in all cases: launchd daemon + fork
venv + healthcheck, GUI attach on top.

Trigger conditions:

- Switch to **(b)** when the 1.9.5 app fails to launch or its menu bar/Selective sync
  and Activity windows break after a macOS upgrade (re-run the checklist to confirm),
  or when the cask/dmg can no longer be reinstalled, or when you need the tray to
  drive new fork behaviour.
- Switch to **(c)** only if the app breaks *and* you do not miss the tray; the
  notification fallback plus `maestral` CLI is a complete working setup.
- Revisit **(d)** if (b)'s template/maintenance burden proves annoying and you want a
  tray without Toga.
- Regardless of option: after every macOS upgrade and every fork release, re-check
  that only the launchd (fork) daemon is running and that PATH still resolves
  `maestral` to the fork CLI.

## 4. Open questions / uncertainties

- Can an ad-hoc-signed rebuilt app post UNUserNotificationCenter notifications? Test
  early if pursuing (b).
- Does current Briefcase still build against the archived `maestral-v2` template
  branch? Pin Briefcase to a known-good version.
- Shipping a dmg would need your own signing key, notarization, and a fork-local
  appcast (Sparkle users must install manually; the existing feed cannot be
  re-pointed). The bundled Python 3.12 has a finite support horizon, one more reason
  (b) exists.
