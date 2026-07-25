# Session Stats — macOS menu bar

Shows today's Claude Code token usage, per model, in the menu bar.

```
O5 114k/20.7M · F5 7.7k/2.5M
```

Each entry is `<model> <output>/<total input>` for the current calendar day,
biggest output first. Models with no traffic today are hidden. Companion to the
[session-stats](https://github.com/davidbudac/session-stats) skill — same
numbers, always on screen.

## Build and install

```bash
./build.sh --install     # builds, copies to /Applications, launches
./build.sh               # just builds into ./build/
```

Needs Swift 6 (Xcode command line tools) and macOS 13+. No other dependencies.

Enable **Open at Login** from the dropdown once it lives in `/Applications`.

## The dropdown

```
Today · 2026-07-25
opus-5        114k out ·  20.7M in · 142 req
fable-5       7.7k out ·   2.5M in ·  30 req
────────────────────────────────────────────
Total         122k out ·  23.2M in · 172 req
Cache hit rate  95.6%
3 sessions · 1 active now
────────────────────────────────────────────
Open Dashboard        ⌘D
Refresh Now           ⌘R
────────────────────────────────────────────
Open at Login
Quit Session Stats    ⌘Q
```

**Open Dashboard** runs the skill's `visualize.py --open`, which regenerates
`~/.claude/session-stats/dashboard.html` and opens it in your browser. The app
deliberately doesn't render the report itself — one implementation, one thing to
keep true.

## Where the numbers come from

The app reads Claude Code's own transcripts under `~/.claude/projects/`, not
just the skill's `sessions.jsonl` log. That log only gets a line when a session
*ends*, so it can't see work in flight; today's transcripts always exist on
disk. `sessions.jsonl` is still consulted as a fallback for sessions whose
transcript has gone missing.

Counting matches `session_stats.py`:

- Usage is repeated on every content block of a message, so requests are deduped
  on `requestId` + `message.id` — without that, totals run 2–4× high.
- Subagent turns appear both in the parent transcript (as `isSidechain`) and in
  their own `subagents/agent-*.jsonl`; they're counted once, from their own file.
- `<synthetic>` messages are skipped.
- **Total input** = uncached + cache write + cache read, as in the skill.

Verified against `session_stats.py --rollup --json` for a completed day
(2026-07-24: 886 requests, 4,045 input, 90,770,579 total in, 526,959 output —
identical).

One deliberate difference: the app buckets each API request by its own
timestamp in **local time**, while the skill's `--rollup` buckets a whole
session by its `ended_at` day in **UTC**. For a session that spans midnight the
app splits it across both days; the skill puts all of it on one.

### Performance

Files are read incrementally — a byte offset per transcript, streamed through a
fixed 256 KB buffer via `read(2)`, and only lines containing `"type":"assistant"`
are parsed. The first pass over a 20 MB day takes ~0.6 s and peaks at 31 MB;
every 30-second refresh after that is nearly free. Resident size settles around
60 MB, nearly all of it the AppKit baseline.

(The `read(2)` buffer isn't premature: going through `FileHandle`/`Data`, which
hands back a fresh `Data` per chunk, peaked at 144 MB for the same work.)

Refresh happens every 30 seconds, and again whenever you open the dropdown.

## Headless mode

To check the numbers, or to diff them against the skill:

```bash
.build/arm64-apple-macosx/release/SessionStatsBar --print
.build/arm64-apple-macosx/release/SessionStatsBar --print 2026-07-24
```

## Settings

No preferences window; the two knobs live in `defaults`:

```bash
# Models shown in the menu bar before collapsing to "+N" (default 3)
defaults write com.davidbudac.SessionStatsBar maxModels -int 2

# Explicit path to visualize.py, if it isn't in a standard skill location
defaults write com.davidbudac.SessionStatsBar visualizePath /path/to/visualize.py
```

The skill's own environment overrides are respected too: `CLAUDE_CONFIG_DIR`,
`CLAUDE_SESSION_STATS_LOG`.
