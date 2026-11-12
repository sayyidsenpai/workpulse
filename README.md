# WorkPulse

A local-first macOS menu bar app that tracks which application you are using, turns that into
work time, keeps an editable history, measures optional goals and can remind you to go to bed.
No account, no network, no telemetry. Nothing leaves the Mac.

- macOS 14 or later, Apple Silicon (a universal build is one flag away)
- Swift 5.9+ toolchain (Xcode 15 or later). No third-party dependencies.

## Build, install, launch

```bash
./scripts/build-app.sh
```

This compiles a release binary, assembles `build/WorkPulse.app` and signs it ad hoc.
`./scripts/build-app.sh universal` builds arm64 + x86_64.

```bash
cp -R build/WorkPulse.app /Applications/
```

```bash
open /Applications/WorkPulse.app
```

WorkPulse appears in the menu bar (stopwatch icon), not in the Dock. Click it for the dashboard;
the row of icons at the bottom opens History, Reports, Goals, Apps & Rules, Sleep and Settings.
Turn on **Settings › Launch at login** after copying the app to `/Applications` (the login item
points at the app's current location).

Tests and development:

```bash
swift test
```

```bash
swift build
```

`Package.swift` opens directly in Xcode. Setting `WORKPULSE_DATA_DIR=/some/folder` makes the app
use that folder instead of the real data folder, which is handy for experiments.

## Code signing, Gatekeeper, notarization

- The build script signs with an **ad-hoc signature** (`codesign --sign -`). This needs no Apple
  Developer membership and is what Apple Silicon requires to run locally built code.
- An app built on your own Mac carries no quarantine flag, so Gatekeeper does not block it.
- The app is **not notarized** and has no Developer ID. If you copy the `.app` to another Mac by
  download, AirDrop or chat, macOS quarantines it and Gatekeeper will refuse to open it. The clean
  options are: build it from source on that Mac, or sign with a Developer ID certificate and
  notarize it (both require the paid Apple Developer Program). macOS also offers its own per-app
  override under System Settings › Privacy & Security › "Open Anyway". WorkPulse does not and
  should not work around these protections.
- macOS ties notification permission and the login item to the app's signature. An ad-hoc
  signature changes on every rebuild, so after rebuilding you may be asked again or need to
  re-enable "Launch at login".

## Permissions

| Feature | Permission | If denied |
| --- | --- | --- |
| Activity tracking | none | n/a |
| Sleep reminders | Notifications (asked when you enable reminders) | reminders are skipped; nothing else changes |
| Launch at login | Login Items entry (visible in System Settings › General) | app simply does not auto-start |

Tracking uses `NSWorkspace` (frontmost application) and the system's "seconds since last input"
counter. It does **not** use Accessibility, Screen Recording or Input Monitoring, and never sees
keystrokes, window titles, screen contents, URLs or browser tabs.

## How tracking works

There is one timeline. At any moment at most one interval is open, and each new interval starts
where the previous one ended, so time is never counted twice.

Every interval has a kind, and all screens and exports derive their numbers from the same rows:

| Kind | Meaning |
| --- | --- |
| Work | Time classified as work. This is "recorded work time". |
| Non-work | An app was in front and you were present, but it is not work. Work + Non-work = "active application time". |
| Idle | No input for longer than the idle threshold, or the screen was locked. |
| Excluded | Time in an application you put in the "Ignored" category. Only the duration is stored, never which app. |

Modes:

- **Automatic**: records whenever you are active; each app's category decides work vs non-work.
  Stop turns tracking off until Start.
- **Manual**: records only between Start and Stop; everything in between counts as work.
- **Hybrid**: automatic, plus Start/Stop "work sessions" that count everything as work while
  they run. When the session stops, automatic rules apply again.

Pause/Resume suspends recording in any mode. Idle detection, screen lock and sleep pause
tracking in every mode; idle time is trimmed back to the last keyboard or mouse input.

Rules (Apps & Rules tab): each application gets a category (built-in Work, Non-work, Ignored,
Uncategorized, plus your own), an optional idle override (for example "never idle" for a video
call app) and an optional project. Applications without a rule are Uncategorized = non-work,
unless you turn on "Count applications without a rule as work".

**Browsers** are never counted as work automatically, even with that switch on. WorkPulse cannot
see tabs or sites, so it does not pretend to: a browser's category applies to all browsing. Give
the browser a category yourself, or leave it uncategorized and use a manual session for
browser-based work.

Rule and goal changes apply from now on. They never rewrite recorded sessions.

## AI agent work (Claude Code, Codex)

When an AI coding agent is working on a task for you, that time can count as your work, even
while you are idle, the screen is locked or another app is in front. A reply that takes an hour
is an hour of work.

Detection is exact, not guessed: the agents' own hooks tell WorkPulse when a turn starts, when a
tool runs and when the turn ends. Each hook runs `agent-hook.sh`, which touches or removes an
empty marker file in `~/Library/Application Support/WorkPulse/agents/`. WorkPulse sees only that
a marker exists and when it was last touched. It never reads prompts, transcripts or output.

- Agent time is recorded as Work with the application "Claude Code" or "Codex" and the source
  "AI agent".
- Your own work in a work app keeps its own application. Agent work fills in only where your own
  activity is not already work (idle, locked, non-work or ignored app), so nothing counts twice.
- Pause, Stop, sleep and Manual mode without a running session still record nothing.
- If an agent is interrupted or crashes it cannot say it stopped. After 15 minutes without any
  hook signal (Settings › AI agents) the session is ended at the last signal, not at the time it
  was noticed.
- Only tools with hooks are covered: Claude Code (terminal and the desktop app's Code tab) and
  Codex (CLI and the ChatGPT app's Codex). Plain chat has no hooks and is not detected.

Setup. WorkPulse keeps the script at `~/Library/Application Support/WorkPulse/agent-hook.sh`.

Claude Code, in `~/.claude/settings.json` under `"hooks"`: run the command below with `busy` for
`UserPromptSubmit`, `PreToolUse` and `PostToolUse` (matcher `*`), and with `done` for `Stop` and
`SessionEnd`:

```json
{ "type": "command", "timeout": 5,
  "command": "sh \"$HOME/Library/Application Support/WorkPulse/agent-hook.sh\" claude-code busy 2>/dev/null || true" }
```

Codex, in `~/.codex/config.toml`: the same for `UserPromptSubmit`, `PreToolUse`, `PostToolUse`
(`busy`) and `Stop` (`done`), then approve the new hooks once in Codex:

```toml
[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "sh \"$HOME/Library/Application Support/WorkPulse/agent-hook.sh\" codex done 2>/dev/null || true"
timeout = 5
```

Turn the feature off in Settings › AI agents, or remove the hook entries.

## Goals, reports, compensation

- Goals are optional, per profile (overall and per project): daily / weekly / monthly hours,
  working days per week (1 to 7), scheduled working days, and the minimum minutes for a day to
  count as worked. Goals only measure. They never stop tracking.
- Saving goals writes a new version effective today. A past week or month is always judged by the
  version in force at the time, so changing a goal never changes history.
- Reports cover any month, any year, or all time: totals, working days, average per working day,
  daily/weekly/monthly trend, activity calendar, time by application / category / project, goal
  achievement history, comparison with the previous period, CSV export (sessions and daily summary).
- Compensation is optional: a monthly amount and currency with an effective month. Reports show
  the effective hourly rate (amount ÷ hours worked that month). No tax or employment assumptions.

## Sleep reminders

Optional and independent of tracking: target bedtime, lead time, every day / weekdays / custom
days, sound, snooze length. Reminders are native repeating notifications scheduled with macOS, so
they fire even when WorkPulse is not running, and offer Snooze and Dismiss. They never stop a
session, change tracked time or close anything.

## Data

Everything lives in `~/Library/Application Support/WorkPulse/`:

- `workpulse.sqlite`: the database (SQLite, WAL mode).
- `Backups/`: one automatic snapshot per day plus manual ones; the newest ten are kept.
- On launch the database is integrity-checked. A damaged file is moved aside
  (`corrupt-<timestamp>.sqlite`), the newest healthy backup is restored, and the dashboard says so.
  If the disk cannot be used at all, the app keeps running in memory and says so.
- The open session is written to disk at least every 30 seconds, so a crash or power loss costs
  at most that much, and the lost seconds are dropped rather than guessed.
- Settings › Data: back up now, restore a backup, delete activity history, delete everything
  (including backups). Deletion rewrites the database file so removed rows are really gone.

Diagnostics go to the unified log:

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "com.workpulse.app"'
```

## Architecture

```
Sources/WorkPulseCore/     pure logic, no UI, fully unit-tested
  Models.swift             sessions, categories, rules, goals, settings, LocalDay
  Database.swift           thin wrapper over the system SQLite
  Store.swift              schema, queries, manual-edit carving, backup/restore/recovery
  TrackingEngine.swift     the single writer of the timeline (state flags -> reconcile)
  Analytics.swift          Aggregator, Goals, Pay, CSV
  AgentSignals.swift       reads the AI agent "working" markers
  SleepSchedule.swift      reminder trigger maths
Sources/WorkPulse/         SwiftUI + AppKit menu bar app
  ActivityMonitor.swift    NSWorkspace / lock / sleep / clock events + one adaptive timer
  AppModel.swift           observable glue between core and views
  SleepReminders.swift     UNUserNotificationCenter scheduling
  *View.swift              dashboard, history, reports, goals, rules, sleep, settings
Tests/WorkPulseCoreTests/  63 tests
scripts/agent-hook.sh      hook script for Claude Code and Codex (copied into the app bundle)
```

Design points worth knowing:

- **Durations come from the monotonic uptime clock**, not the wall clock, so clock adjustments and
  sleep cannot add or remove tracked time. If the wall clock is set backwards, new sessions are
  placed after the newest recorded one instead of overlapping it.
- **Each session stores the UTC offset it was recorded in.** Days, weeks and months are computed
  from that, so travelling or a daylight-saving change never moves past work to another day.
- **Sessions crossing midnight** are stored once and split at local midnight when totals are computed.
- **Manual edits win.** Saving a corrected or hand-made session trims, splits or removes whatever
  it overlaps, inside one transaction.
- The monitor is event-driven. Its only timer fires every 30 s, sooner only when the idle
  threshold is about to be reached, and every 3 s while waiting for you to come back.

## Known limitations

- No tab- or site-level browser tracking, by design (see above).
- Watching or reading without touching keyboard or mouse counts as idle after the threshold.
  Raise the threshold or give that app a "never idle" rule.
- Intervals shorter than one second (fast app switching) are dropped.
- Screen lock is detected through the system's lock/unlock notifications, which Apple does not
  document. If they ever stop arriving, the idle threshold still pauses tracking.
- A debug build accepts `--snapshot <folder>` to render every screen to PNG (used to check the UI
  where screen capture is unavailable). It is compiled out of release builds.
