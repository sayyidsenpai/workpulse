#!/usr/bin/env python3
"""Sample data for the pictures in the README. It never touches the real WorkPulse data.

    python3 scripts/demo-data.py <folder>

writes <folder>/demo-data (a WorkPulse data folder with 75 days of sample sessions) and
<folder>/demo-home (an empty home folder for the agent setup). Then render the pictures:

    WORKPULSE_DEMO=1 WORKPULSE_DATA_DIR=<folder>/demo-data WORKPULSE_HOME=<folder>/demo-home \
        .build/debug/WorkPulse --snapshot <folder>/out

Run both commands during the work hours of a work day (08.00 to 16.00, Monday to Friday),
or give both the same TZ, for example TZ=America/Phoenix. On a weekend everywhere, add --weekend:
Saturday is then a work day too, so the pictures can be made with a TZ where it is morning.

With --holiday, today is a holiday that WorkPulse did not know: work from 08.00 to 10.00, then
Safari. Render it with WORKPULSE_DEMO_APP="com.apple.Safari:Safari" for the day-off pictures.
"""
import sqlite3, os, sys, json, time, datetime, shutil
holiday = '--holiday' in sys.argv
weekend = '--weekend' in sys.argv
args = [a for a in sys.argv[1:] if a not in ('--holiday', '--weekend')]
work_days = [2, 3, 4, 5, 6, 7] if weekend else [2, 3, 4, 5, 6]
work_mask = sum(1 << (d - 1) for d in work_days)
if len(args) != 1:
    sys.exit(__doc__)
root = args[0]
data = os.path.join(root, 'demo-data'); home = os.path.join(root, 'demo-home')
# Only a folder this script made before is replaced.
if os.path.exists(data) and not os.path.exists(os.path.join(data, 'workpulse.sqlite')):
    sys.exit(data + ' exists and is not a WorkPulse data folder. Nothing was changed.')
shutil.rmtree(data, ignore_errors=True); os.makedirs(os.path.join(data, 'agents')); os.makedirs(home, exist_ok=True)
open(os.path.join(data, 'agents', '.seen-claude-code'), 'w').close()
db = sqlite3.connect(os.path.join(data, 'workpulse.sqlite'))
db.executescript("""
CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, tz_offset INTEGER NOT NULL,
 kind TEXT NOT NULL, bundle_id TEXT, app_name TEXT, category_id INTEGER, project_id INTEGER, source TEXT NOT NULL,
 edited INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '', end_reason TEXT NOT NULL DEFAULT '', CHECK(end >= start));
CREATE TABLE IF NOT EXISTS categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, builtin INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS projects(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS app_rules(bundle_id TEXT PRIMARY KEY, app_name TEXT NOT NULL, category_id INTEGER NOT NULL, idle_threshold INTEGER, project_id INTEGER);
CREATE TABLE IF NOT EXISTS goals(id INTEGER PRIMARY KEY, project_id INTEGER, effective_from INTEGER NOT NULL, daily_hours REAL, weekly_hours REAL,
 monthly_hours REAL, weekly_days INTEGER, min_day_minutes INTEGER NOT NULL, working_days INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS compensation(id INTEGER PRIMARY KEY, effective_from INTEGER NOT NULL, monthly_amount REAL NOT NULL, currency TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO categories(id, name, kind, builtin) VALUES (1,'Work','work',1),(2,'Non-work','nonwork',1),(3,'Ignored','excluded',1),(4,'Uncategorized','nonwork',1);
""")
tz = time.localtime().tm_gmtoff
XCODE = ('Xcode', 'com.apple.dt.Xcode'); SAFARI = ('Safari', 'com.apple.Safari'); AGENT = ('Claude Code', 'agent.Claude Code')
def ts(d, h): return time.mktime((d.year, d.month, d.day, 0, 0, 0, 0, 0, -1)) + h * 3600
def add(d, a, b, kind, app=None, cat=None, source='automatic'):
    if b <= a: return
    db.execute("INSERT INTO sessions(start,end,tz_offset,kind,bundle_id,app_name,category_id,source,end_reason) VALUES (?,?,?,?,?,?,?,?,?)",
               (ts(d, a), ts(d, b), tz, kind, app[1] if app else None, app[0] if app else None, cat, source, 'switch'))
today = datetime.date.today()
now_h = (time.time() - ts(today, 0)) / 3600
day = today - datetime.timedelta(days=75)
while day < today:
    if day.weekday() < 5:
        v = (day.toordinal() * 7) % 5          # small, repeatable differences between days
        lunch = 11.5 + v * 0.1
        add(day, 8 + v * 0.05, lunch, 'work', XCODE, 1)
        add(day, lunch, lunch + 0.75, 'nonwork', SAFARI, 2)
        add(day, lunch + 0.75, lunch + 1.05, 'idle')
        add(day, lunch + 1.05, lunch + 2.05, 'work', AGENT, 1, 'agent')
        add(day, lunch + 2.05, 15.2 + v * 0.15, 'work', XCODE, 1)
        if v == 3: add(day, 16.0, 16.7, 'work', XCODE, 1)   # a day with overtime
    day += datetime.timedelta(days=1)
if holiday:
    # A holiday that WorkPulse did not know: 2h of work from 08.00, then the user notices at 10.00.
    add(today, 8, 9.75, 'work', XCODE, 1)
    add(today, 9.75, 10, 'work', ('Terminal', 'com.apple.Terminal'), 1)
    add(today, 10, min(now_h - 0.002, 15.9), 'nonwork', SAFARI, 2)
else:
    add(today, 8, 10, 'work', XCODE, 1)
    add(today, 10, 10.33, 'idle')
    add(today, 10.33, min(now_h - 0.002, 15.9), 'work', XCODE, 1)
for bid, name, cat in [('com.apple.dt.Xcode', 'Xcode', 1), ('com.apple.Safari', 'Safari', 2), ('com.apple.Terminal', 'Terminal', 1), ('com.apple.Notes', 'Notes', 1), ('com.apple.Music', 'Music', 2)]:
    db.execute("INSERT INTO app_rules(bundle_id, app_name, category_id) VALUES (?,?,?)", (bid, name, cat))
epoch_day = (today - datetime.date(1970, 1, 1)).days
def index(d): return (d - datetime.date(1970, 1, 1)).days
# Planned days off after today: sample holidays and leave.
year = today.year if today < datetime.date(today.year, 12, 24) else today.year + 1
days_off = [{"from": index(datetime.date(year, 12, 24)), "to": index(datetime.date(year, 12, 24)), "name": "Leave"},
            {"from": index(datetime.date(year, 12, 25)), "to": index(datetime.date(year, 12, 25)), "name": "Christmas Day"},
            {"from": index(datetime.date(year, 12, 29)), "to": index(datetime.date(year, 12, 31)), "name": "Leave"},
            {"from": index(datetime.date(year + 1, 1, 1)), "to": index(datetime.date(year + 1, 1, 1)), "name": "New Year's Day"}]
db.execute("INSERT INTO goals(effective_from, daily_hours, min_day_minutes, working_days) VALUES (?,?,?,?)", (epoch_day - 90, 6, 30, work_mask))
settings = {"onboarded": True, "profile": "work",
            "schedule": {"enabled": True, "days": work_days, "startMinutes": 480, "endMinutes": 960,
                         "daysOff": days_off},
            "sleep": {"enabled": True, "bedtimeMinutes": 23 * 60, "leadMinutes": 30, "days": [1, 2, 3, 4, 5, 6, 7]},
            "lastBackupDay": epoch_day, "firstWeekday": 2}
db.execute("INSERT INTO settings(key, value) VALUES ('app', ?)", (json.dumps(settings),))
db.commit()
