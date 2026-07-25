# Session Stats — macOS menu bar

Today's Claude Code token usage, per model, in the menu bar.

```
O5 215k/74.2M · F5 15k/8.6M
```

Each entry reads `<model> <output>/<total input>` for the current calendar day.
Models with no traffic today are hidden. The numbers move while you work — they
do not wait for a session to end.

Models are ordered by **cost**, not by token count, and the dropdown prices each
one. Worth knowing why the two differ: output tokens are only ~13% of what you
actually pay, and the prompt cache is ~87% — see
[Where the money goes](#where-the-money-goes).

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
opus-5         $31.2 ·   154k out ·  31.8M in
               cache read $15.3 · cache write $11.7 · output $3.85
fable-5        $5.78 ·   7.7k out ·   2.5M in
               cache write $3.04 · cache read $2.35 · output $0.39
──────────────────────────────────────────────────────────
Total          $36.9 ·   162k out ·  34.4M in
Cache hit rate  95.9%  ·  237 requests
4 sessions · 5 subagents
──────────────────────────────────────────────────────────
Running now
awr_timeline_comparison  $32.8 ·    92k out · O48
  5 subagents · $16.3 (50% of session)
   ● fleet-b-impl         $10.5 ·    18k out · O48
   · fleet-docs           $2.10 ·   3.9k out · O48
   · mock-b-console       $1.77 ·   3.6k out · O48
   · mock-c-timeline      $1.14 ·     2k out · O48
   · mock-a-cards         $0.74 ·   451 out · O48
session_stats_macosapp   $25.7 ·    99k out · O5
  no subagents
──────────────────────────────────────────────────────────
Open Dashboard        ⌘D
Refresh Now           ⌘R
──────────────────────────────────────────────────────────
Open at Login
Quit Session Stats    ⌘Q
```

The dimmed second line under each model is where that money actually went,
biggest component first.

### Running now

A session is listed as running if anything under it — its main thread or any
subagent — wrote to a transcript in the last 5 minutes. Each one shows the
project directory, its cost including subagents, and the model that did most of
the work.

Subagents are nested under the session that spawned them, labelled with the name
the parent gave them (`fleet-b-impl`) or their agent type (`Explore`, `Plan`)
when unnamed, and priced against the model that actually served them — which is
often not the parent's model. The `● / ·` marker distinguishes agents still
running from ones that have finished.

The `(50% of session)` figure is the point of the section: fan-out is easy to
under-estimate, and on a heavy day subagents can outspend the main thread.

Bounded at 4 sessions and 6 subagents each, with a `+N more` line, so a wide
fan-out can't grow the menu past the screen.

## Where the money goes

The intuition that output tokens drive cost is wrong for Claude Code. Output is
billed at 5× the input rate, but the prompt cache moves far more tokens. Here is
a real day, measured:

| Component | Rate (× input) | Share of spend |
|---|---|---|
| Cache read | 0.1× | **46%** |
| Cache write (1h TTL) | 2× | **41%** |
| Output | 5× | 13% |
| Uncached input | 1× | ~0% |

Cache reads are cheap per token and enormous in volume — every request re-sends
the whole conversation. Cache writes cost double the input rate on a 1-hour TTL.
Uncached input rounds to zero. So treat the menu bar's token counts as a measure
of *volume*, not of spend — no single token count is a usable proxy for price.
The dropdown is where the money is, which is also why models are ordered by cost
rather than by tokens.

### Rates

Per million tokens, accurate as of 2026-07-25:

| Model | Input | Output |
|---|---|---|
| Opus 5, Opus 4.8 / 4.7 / 4.6 / 4.5 | $5 | $25 |
| Fable 5, Mythos 5 | $10 | $50 |
| Sonnet 5, Sonnet 4.6 / 4.5 | $3 | $15 |
| Haiku 4.5 | $1 | $5 |

Cache read is 0.1× the model's input rate; cache write is 1.25× (5-minute TTL) or
2× (1-hour). Sonnet 5's introductory $2/$10 is applied automatically until
2026-08-31. A model with no entry is priced at Opus rates and flagged in the
dropdown rather than silently counted as free.

**These prices will go stale.** The
[session-stats](https://github.com/davidbudac/session-stats) skill deliberately
reports tokens and no prices for exactly that reason. Override any rate without
rebuilding:

```bash
# input and output $/MTok for a model prefix
defaults write com.davidbudac.SessionStatsBar rate_opus-5 -array 5 25
```

Figures are an estimate. They don't know about Batch API discounts, priority
tier, fast mode, or anything negotiated in your contract.

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
  nested subagents count exactly once. Those rows carry the *parent's*
  `sessionId`, which is what lets an agent be grouped under the session that
  spawned it; its name and type come from the sibling `agent-*.meta.json`.
- **`<synthetic>` messages are skipped** — they're not billed API calls.
- **Total input** = uncached input + cache write + cache read, as in the skill.
  It's large by design: every API request re-sends the whole conversation, and
  most of it is served from cache.
- **Cache hit rate** = cache read ÷ total input.
- **Cache-write TTL is tracked separately** (`ephemeral_1h_input_tokens`), because
  a 1-hour write bills at 2× input and a 5-minute one at 1.25×. A transcript with
  no TTL split is priced at the 5-minute tier, matching the API default.

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

# Override a model's $/MTok rates (input, output) — see Rates above
defaults write com.davidbudac.SessionStatsBar rate_opus-5 -array 5 25
```

The skill's environment overrides are respected too: `CLAUDE_CONFIG_DIR` and
`CLAUDE_SESSION_STATS_LOG`.

## Privacy

Everything stays on the machine. The app reads local files, has no network code,
and the only process it ever starts is `python3 visualize.py`, on your click.

## License

MIT
