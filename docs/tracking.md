# How tracking works

How WorkPulse turns activity into work time, and how goals, reports and sleep reminders use it. [Back to the README](../README.md)

## The timeline

There is one timeline. At any moment at most one interval is open, and each new interval starts
where the previous one ended, so time is never counted twice.

Every interval has a kind, and all screens and exports derive their numbers from the same rows:

| Kind | Meaning |
| --- | --- |
| Work | Time classified as work. This is "recorded work time". |
| Non-work | An app was in front and you were present, but it is not work. Work + Non-work = "active application time". |
| Idle | No input for longer than the idle threshold, or the screen was locked. |
| Excluded | Time in an application you put in the "Ignored" category. Only the duration is stored, never which app. |

Profiles. There are two, and one is always on:

- **Work**: each application's category decides work vs non-work.
- **Personal**: activity is still recorded, but none of it as work. Time in a work application is
  stored as non-work.

"Start work" and "End work" change the profile. Pause/Resume suspends recording. Idle detection,
screen lock and sleep pause tracking; idle time is trimmed back to the last keyboard or mouse
input.

Work hours (Work screen) are optional: work days, Start and End. They act only at the two
boundaries, and a choice you make by hand holds between them.

- At Start, WorkPulse changes to the Work profile and shows one quiet notification: "Work hours
  started at 08.00". It asks nothing and has no sound. Point at it to see a "Day off" button.
  Settings › Tracking › "Tell me when work hours start" turns it off.
- At End, if you still work (or an agent still works for you), WorkPulse continues, plays one
  chime and shows one notification with an "End work" button. This time is **overtime**. If you
  are away at End, WorkPulse changes to Personal without a word.
- Overtime ends by itself after 15 minutes without input (Settings), on screen lock and on sleep.
  Outside work hours you start overtime by hand.
- In Personal, WorkPulse asks "Is this work?" only with evidence: 12 minutes in work
  applications. "Start work" moves those minutes to work; "Not work" stops the question for the
  day. Nothing is ever counted without a recorded interval behind it.

Days off (Work screen › Days off): holidays and leave, one day or a range, with an optional name.

- On a day off there are no work hours: WorkPulse does not change to Work and sends no
  notification. Work that you start on a day off counts as overtime.
- The daily goal does not apply, and the week and month goals drop by one day (6h on 5 days:
  30h becomes 24h). Reports show the day with a muted label.
- If you notice a holiday too late, select "End work". In work hours the Personal card then asks
  one time "Is today a day off?". The confirmation shows the work recorded today, per application.
  "Move to Personal" makes that time non-work; "Keep as work" keeps it, as overtime. "Day off" in
  the morning notification moves the work of today without a question.
- Undo stays available until the next work hours start. Past days off stay in the list, so
  earlier reports never change.

Rules (Apps screen): each application gets a category (built-in Work, Non-work, Ignored,
Uncategorized, plus your own) and an optional idle override (for example "never idle" for a video
call app). Applications without a rule are Uncategorized = non-work, unless you turn on "Count
applications without a rule as work".

**Browsers** are never counted as work automatically, even with that switch on. WorkPulse cannot
see tabs or sites, so it does not pretend to: a browser's category applies to all browsing. Give
the browser a category yourself if your work is in the browser.

Rule and goal changes apply from now on. They never rewrite recorded sessions.

## Goals, reports, compensation

- There is one goal to set: the **daily goal** (Work screen), at most the length of your work
  hours. The weekly and monthly goals follow from it and your work days (6 h on 5 days = 30 h a
  week). A day counts as a working day after 30 minutes of work. Goals only measure. They never
  stop tracking.
- A change applies from today. A past week or month is always judged by the goal in force at the
  time, so changing a goal never changes history.
- Reports cover any month, any year, or all time: totals, working days, average per working day,
  daily/weekly/monthly trend, activity calendar, time by application / category, goal
  achievement history, comparison with the previous period, CSV export (sessions and daily summary).
- Compensation is optional: a monthly amount and currency with an effective month. Reports show
  the effective hourly rate (amount ÷ hours worked that month). No tax or employment assumptions.

## Sleep reminders

Optional and independent of tracking: target bedtime, lead time, every day / weekdays / custom
days, sound, snooze length. Reminders are native repeating notifications scheduled with macOS, so
they fire even when WorkPulse is not running, and offer Snooze and Dismiss. They never stop a
session, change tracked time or close anything.
