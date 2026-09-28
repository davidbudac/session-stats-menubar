# Session Stats — macOS menu bar

Your coding subscriptions' remaining quota, and today's Claude Code token usage
per model, in the menu bar.

By default the menu bar shows three small rings — Claude, Codex, Cursor, told
apart by colour — each showing how much of that subscription's quota is
**left**, with that percentage as a number inside. A full ring is untouched
quota. Hover a ring for its details; click for the dropdown.
See [Subscription rings](#subscription-rings).

The original text readout is one setting away:

```
O5 268k · F5 31k
```

Output tokens for the current calendar day, by default. Models with no traffic
today are hidden. The numbers move while you work — they do not wait for a
session to end. What's shown is configurable — see [Settings](#settings).

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

There's no Dock icon — look for the three rings in the menu bar. To have it
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

### Distributing

```bash
./build.sh --dmg             # → build/Session Stats 1.5.dmg
./build.sh --install --dmg   # flags combine, in any order
```

`--dmg` builds a universal binary (arm64 + x86_64) and packages the app with
an Applications shortcut for drag-to-install. Universal builds need full Xcode;
with only the command line tools the script falls back to your Mac's native
architecture and says so.

The DMG is ad-hoc signed and not notarized, so recipients have to allow it on
first launch: **right-click the app → Open**, or **System Settings → Privacy &
Security → Open Anyway**, or:

```bash
xattr -dr com.apple.quarantine "/Applications/Session Stats.app"
```

If you have a Developer ID certificate, sign with it (hardened runtime is
enabled automatically; notarization is still up to you):

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh --dmg
```

## Subscription rings

```
 (81)  (88)  (–)        Claude (orange) · Codex (indigo) · Cursor (plain)
```

Each ring's arc is the remaining share of that subscription's **weekly (7-day)
window**. It starts at 12 o'clock and runs clockwise over a faint full-circle
track. The number inside is the same thing in figures: percent left, rounded.
The 5-hour window isn't on the ring — it's in the hover tooltip and the
dropdown — so a ring can look healthy while the 5-hour window is used up. A
provider that reports no weekly window falls back to whichever window has the
least left.

- **Amber dot** at the top right: the weekly window has 20% or less left.
- **Red arc and number**: 5% or less.
- **Track only, no arc, a dash inside**: no usable reading — nothing recorded
  yet, or the last reading is more than 8 days old.

Hovering a ring shows that provider on its own:

```
Claude — as of 2m ago
5h      25% used · 75% left · resets in 1h 5m
7d      63% used · 37% left · resets Thu 10:00

Today
opus-5-5    $119 · 37k out · 167M in
fable-5-1   $11.1 · 44k out · 2.8M in
Total       $130 · 81k out · 170M in
```

The Claude tooltip carries today's per-model spend that the text readout used to
show. The Codex one shows the plan, its windows, and today's tokens per model —
without dollars, as there's no Codex price table here and inventing one would be
worse than none.

### Where each ring comes from

| Provider | Source | Notes |
|---|---|---|
| Claude | `~/.claude/session-stats/rate-limits.json` | Written by your statusline script — see [Claude quota setup](#claude-quota-setup). Respects `CLAUDE_CONFIG_DIR`. |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Every `token_count` event carries the account's `rate_limits`; the newest one across all rollouts wins. Respects `CODEX_HOME`. |
| Cursor | — | No ring. See below. |

Codex rollouts are read the same way as Claude transcripts: incrementally, with
a per-file byte offset, through the same fixed `read(2)` buffer, and with a raw
byte prefilter so only `token_count` and `turn_context` lines are parsed. Only
day folders from the last 8 days are listed; older ones are only stat'ed, since
a resumed session keeps appending to the rollout in the folder of the day it
started. Today's Codex tokens are summed from each event's `last_token_usage`
(Codex's `input_tokens` already includes the cached part), attributed to the
model of the preceding `turn_context`, skipping the verbatim repeats Codex
sometimes writes.

**Why Cursor has no ring.** Cursor keeps its usage server-side; nothing on disk
records it. The only way to get it would be to call Cursor's API with your
session token, which would mean reading a credential and adding network code —
both things this app doesn't do. So its ring stays as a reminder, with a track,
no arc and a dash.

### Staleness

A reading is only as fresh as the last time that tool ran. Neither Claude Code
nor Codex has any way to tell this app about usage elsewhere — on another
machine, on the web, on your phone — until it runs here again. So:

- A new reading shows within about a second of the tool writing it (file
  system events; the 30-second poll is the fallback).
- Tooltips say how old the reading is ("as of 3h ago").
- If a window's reset time has passed since the reading, it has rolled over:
  it's counted as 0% used.
- Readings older than 8 days are shown as unknown.

### Claude quota setup

Claude Code hands its statusline command the session's `rate_limits` on stdin,
but doesn't write them anywhere. Add this to your statusline script, right after
it reads stdin into `$input` (requires `jq`):

```bash
# Snapshot subscription rate limits for the Session Stats menu bar app.
# Written atomically; skipped when the session carries no rate_limits.
rl=$(echo "$input" | jq -c 'select(.rate_limits != null) | {captured_at: (now | floor), rate_limits}' 2>/dev/null)
if [ -n "$rl" ]; then
    rl_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-stats"
    mkdir -p "$rl_dir" \
        && printf '%s\n' "$rl" > "$rl_dir/rate-limits.json.$$" \
        && mv -f "$rl_dir/rate-limits.json.$$" "$rl_dir/rate-limits.json"
fi
```

Until that has run once, the Claude ring shows as unknown.

## The dropdown

```
Subscriptions
Claude   5h 75% left · resets 1h 5m   |   7d 37% left · resets Thu
Codex    weekly 99% left · resets Wed · prolite · as of 2d ago
Cursor   not available locally
──────────────────────────────────────────────────────────
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

**Subscriptions** is the rings in words: every window, what's left, and when it
resets. The reading's age is added once it's more than 15 minutes old. A row
that would run too wide puts its windows on indented rows beneath it.

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

The subscription rings don't wait for that poll. One FSEvents stream watches
`~/.claude/session-stats/` and `~/.codex/sessions/`, so a new quota reading shows
up within about a second of the tool writing it — at most one refresh a second,
reading only the quota sources, not the transcripts. The 30-second poll stays as
the fallback: resets and "as of" ages move with the clock, and a folder that
doesn't exist yet is picked up on the next tick once it appears.

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

`--subscriptions` prints what's behind the rings: each provider's source, when
the reading was captured, every window as captured and as it stands now (after
the reset rule), plan, the ring and which window it shows, and today's Codex
tokens per model:

```bash
"/Applications/Session Stats.app/Contents/MacOS/SessionStatsBar" --subscriptions
```

`--render-icons <file.png>` draws the menu bar image on a light and a dark bar —
natively at 4x, and pixel-true at 1x and 2x — for real data plus sample states
(low, critical, unknown). Handy for checking the rings after touching the
drawing code:

```bash
"/Applications/Session Stats.app/Contents/MacOS/SessionStatsBar" --render-icons /tmp/rings.png
```

## Settings

Everything about the menu bar readout is configurable from the **Settings**
submenu in the dropdown:

| Setting | Options | Default |
|---|---|---|
| **Menu bar style** | Rings · Token text | Rings |
| **Menu bar shows** | Output tokens · Output / total input · Total input · Estimated cost · Requests | Output tokens |
| **Models in menu bar** | 1 · 2 · 3 · All (the rest collapse into `+N`) | 3 |
| **Show model labels** | on/off — drop the `O5` / `F5` prefixes for a bare number | on |
| **Collapse to ⋯** | shrink the item to a single glyph | off |

The middle three shape the token text only, so the submenu lists them only in
the **Token text** style. Collapsing works in either style.

Models are always ordered by **cost**, whichever metric you display — that ranks
them by what they actually cost rather than by volume. The dropdown always shows
every model regardless of the menu bar cap.

### Collapsing

**Collapse to ⋯** shrinks the item in place, from ~112pt to ~35pt. Clicking it
still opens the menu, so the setting is always reachable again.

It deliberately does *not* work the Bartender way — a second chevron item that
hides the first. That was built and abandoned: macOS places a new status item
where it likes, and on this notched display it landed at x≈778, **behind the
notch**. The item existed, had a size, reported itself to the accessibility tree
and responded to clicks — it was simply invisible, with no way for a user to
find it. Collapsing in place can't land somewhere unreachable.

### Via `defaults`

The same preferences, for scripting. Keys: `menuBarStyle` (`rings`, `text`),
`metric` (`output`,
`outputAndInput`, `totalInput`, `cost`, `requests`), `maxModels` (0 = all),
`showModelLabels`, `collapsed`.

```bash
defaults write com.davidbudac.SessionStatsBar menuBarStyle -string text
defaults write com.davidbudac.SessionStatsBar metric -string cost
defaults write com.davidbudac.SessionStatsBar maxModels -int 2
```

Run `"/Applications/Session Stats.app/Contents/MacOS/SessionStatsBar" --settings`
to print what the app actually reads — the reliable way to tell a preference
that didn't apply from one that was never written.

Two further knobs live only in `defaults`:

```bash
# Explicit path to visualize.py, if it isn't in a standard skill location
defaults write com.davidbudac.SessionStatsBar visualizePath /path/to/visualize.py

# Override a model's $/MTok rates (input, output) — see Rates above
defaults write com.davidbudac.SessionStatsBar rate_opus-5 -array 5 25
```

The skill's environment overrides are respected too: `CLAUDE_CONFIG_DIR` and
`CLAUDE_SESSION_STATS_LOG`, and Codex's `CODEX_HOME`.

## Privacy

Everything stays on the machine. The app reads local files, has no network code,
and the only process it ever starts is `python3 visualize.py`, on your click.

The files it reads: Claude Code's transcripts under `~/.claude/projects/`, the
skill's `~/.claude/session-stats/` log and the `rate-limits.json` snapshot, and
Codex's session logs under `~/.codex/sessions/`. It never opens a credential —
not `~/.codex/auth.json`, not the Keychain, not Cursor's state database. That's
also why Cursor has no ring: its quota lives only behind an authenticated API.

## License

MIT
