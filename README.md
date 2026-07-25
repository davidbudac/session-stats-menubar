# Session Stats — macOS menu bar

Today's Claude Code token usage, per model, in the menu bar.

```
O5 129k/23M · F5 7.7k/2.5M
```

Each entry reads `<model> <output>/<total input>` for the current calendar day,
biggest output first. Models with no traffic today are hidden. The number moves
while you work — it does not wait for a session to end.

Companion to the [session-stats](https://github.com/davidbudac/session-stats)
Claude Code skill: the same numbers that `/session-stats` reports, always on
screen.

## Install

Download `Session-Stats.dmg` from
[Releases](https://github.com/davidbudac/session-stats-menubar/releases), open
it, and drag **Session Stats** to Applications.

The app is ad-hoc signed, not notarized, so the first launch needs one extra
step: **right-click the app → Open**, then confirm. (Double-clicking will just
say it can't be opened.) Alternatively:

```bash
xattr -dr com.apple.quarantine "/Applications/Session Stats.app"
```

There's no Dock icon — look for the token counts in the menu bar. To have it
come back after a reboot, turn on **Open at Login** in the dropdown.

### Or build it yourself

```bash
git clone https://github.com/davidbudac/session-stats-menubar
cd session-stats-menubar
./build.sh --install     # builds, copies to /Applications, launches
./build.sh               # just builds into ./build/
```

Needs macOS 13+ and a Swift 6 toolchain (Xcode command line tools). No other
dependencies — no Python, no packages, no network access.

## The dropdown

```
Today · 2026-07-25
opus-5        129k out ·    23M in · 168 req
fable-5       7.7k out ·   2.5M in ·  30 req
────────────────────────────────────────────
Total         137k out ·  25.5M in · 198 req
Cache hit rate  95.8%
3 sessions · 1 active now
────────────────────────────────────────────
Open Dashboard        ⌘D
Refresh Now           ⌘R
────────────────────────────────────────────
Open at Login
Quit Session Stats    ⌘Q
```

## How it works

### Where the numbers come from

Claude Code writes a JSONL transcript of every session under
`~/.claude/projects/<project-slug>/<session-id>.jsonl`, with subagents in a
sibling `<session-id>/subagents/agent-<id>.jsonl`. Every assistant message in
those files carries a `usage` block — input tokens, cache write, cache read,
output tokens — and a timestamp.

The app reads those transcripts directly. That's the whole data source, and it's
why **the skill is not required** for the menu bar to work: the transcripts are
Claude Code's own, written whether or not the skill is installed. The skill is
only needed for the **Open Dashboard** menu item.

The skill's history log, `~/.claude/session-stats/sessions.jsonl`, is deliberately
*not* the primary source. A `SessionEnd` hook appends to it one line per
**finished** session, so it cannot see work in flight — the number would sit
still while you're working and jump when you quit. It's still read as a fallback,
for sessions logged there whose transcript has since been deleted.

### Counting rules

These match [`session_stats.py`](https://github.com/davidbudac/session-stats),
and getting them wrong is the difference between a plausible number and a correct
one:

- **Requests are deduped on `requestId` + `message.id`.** A message's `usage`
  block is repeated on every content block it contains (thinking, text, each
  tool_use). Summing them naively over-reports by 2–4×.
- **Subagent turns are counted once.** They appear both in the parent transcript
  flagged `isSidechain`, and again in their own `subagents/agent-*.jsonl`. The
  sidechain copies are skipped and the dedicated files are read instead, so
  nested subagents count exactly once.
- **`<synthetic>` messages are skipped** — they're not billed API calls.
- **Total input** = uncached input + cache write + cache read, as in the skill.
  It's large by design: every API request re-sends the whole conversation, and
  most of it is served from cache.
- **Cache hit rate** = cache read ÷ total input.

Verified rather than assumed: for a completed day (2026-07-24) the app and
`session_stats.py --rollup --json` agree exactly — 886 requests, 4,045 uncached
input, 90,770,579 total input, 526,959 output.

One deliberate difference. The app buckets **each API request by its own
timestamp, in local time**; the skill's `--rollup` buckets **a whole session by
its `ended_at` day, in UTC**. For a session that runs past midnight the app
splits it across both days, while the skill puts all of it on the later one.
Per-request local time is the right call for a "today" readout — but it means the
two won't always agree to the token on a day boundary.

### Freshness and cost

A refresh runs every 30 seconds, and again whenever you open the dropdown. A
session counts as **active now** if its transcript grew in the last 5 minutes.

Reading megabytes of JSON every 30 seconds would be a silly thing to put in a
menu bar, so it doesn't:

- **Per-file byte offsets.** Only bytes appended since the last pass are read.
  Files whose mtime predates the retention window are never opened at all.
- **A prefilter before parsing.** Only lines containing `"type":"assistant"`
  carry usage; the rest — tool results, user turns, the bulk of the bytes — are
  skipped on a raw byte scan without ever becoming JSON.
- **A fixed `read(2)` buffer.** 256 KB, reused. This isn't premature: going
  through `FileHandle`/`Data`, which returns a fresh `Data` per chunk, peaked at
  **144 MB** RSS on a 20 MB day. The buffer holds the same work to **31 MB**.

The first pass over a 20 MB day takes ~0.6 s on an M-series Mac; refreshes after
that are nearly free. Resident size settles around 60 MB, nearly all of it the
AppKit baseline. Scanning happens off the main thread, so the menu never blocks.

### The dashboard

**Open Dashboard** shells out to the skill's `visualize.py --open`, which
regenerates `~/.claude/session-stats/dashboard.html` — hero total, KPI tiles,
output per day, per model and per project, with range filters — and opens it in
your browser.

The app deliberately doesn't render the report itself. One implementation means
one thing to keep true. If the skill isn't installed, this menu item explains
where it looked.

It searches, in order: the `visualizePath` default (below), `$CLAUDE_PLUGIN_ROOT`,
`~/.claude/skills/session-stats/`, and any plugin under `~/.claude/plugins/`.

## Headless mode

The same scanner, printed to stdout — useful for checking the numbers or diffing
them against the skill:

```bash
"/Applications/Session Stats.app/Contents/MacOS/SessionStatsBar" --print
"/Applications/Session Stats.app/Contents/MacOS/SessionStatsBar" --print 2026-07-24
```

## Settings

No preferences window; two knobs live in `defaults`:

```bash
# Models shown in the menu bar before collapsing to "+N" (default 3).
# A five-model day would otherwise eat a lot of menu bar.
defaults write com.davidbudac.SessionStatsBar maxModels -int 2

# Explicit path to visualize.py, if it isn't in a standard skill location
defaults write com.davidbudac.SessionStatsBar visualizePath /path/to/visualize.py
```

The skill's environment overrides are respected too: `CLAUDE_CONFIG_DIR` and
`CLAUDE_SESSION_STATS_LOG`.

## Privacy

Everything stays on the machine. The app reads local files, has no network code,
and the only process it ever starts is `python3 visualize.py`, on your click.

## License

MIT
