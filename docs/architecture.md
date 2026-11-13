# Data, architecture and limitations

Where the data is, how the code is organised, and what WorkPulse does not do. [Back to the README](../README.md)

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
  AgentSetup.swift         adds and removes the hook entries in the agents' configuration
  SleepSchedule.swift      reminder trigger maths
Sources/WorkPulse/         SwiftUI + AppKit menu bar app
  ActivityMonitor.swift    NSWorkspace / lock / sleep / clock events + one adaptive timer
  AppModel.swift           observable glue between core and views
  SleepReminders.swift     UNUserNotificationCenter scheduling (sleep, end of work hours)
  DesignSystem.swift       colours, type scale, glass surfaces, shared controls
  Sounds.swift             the few chimes (goal reached, end of work hours, tracking controls)
  *View.swift              popover, main window, history, reports, work, apps, sleep, settings,
                           onboarding
Tests/WorkPulseCoreTests/  89 tests
scripts/agent-hook.sh      hook script for Claude Code and Codex (copied into the app bundle)
docs/                      this documentation and the pictures in the README
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
  `scripts/demo-data.py` makes the sample data for the pictures in the README; the comment at
  its top has the two commands.
