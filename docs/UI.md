# Dashboard

The daemon serves the desktop dashboard at `http://127.0.0.1:47100/`. The
[guide](guide.md) describes it from the user's side; this file holds the
rules behind it.

## Rules

- **Icons, not text buttons.** Every icon button has a tooltip, an
  accessible name in all languages, a visible focus ring and a fair hit area.
- **No seconds anywhere.** Durations are `Xh YYm`; times are `HH:MM`.
  Totals are summed in milliseconds and formatted once.
- **One command bar:** logo, date, tabs, search, the current task (round
  play/pause, ref and title, elapsed time and fields) and the action icons.
  Rarely used commands sit in the ⋯ menu. The task text never overlaps the
  controls; a long title is cut with an ellipsis and shown on hover.
- **Post hours** is a clock icon in the command bar for the selected day,
  plus the clock on each day in the list. Amounts come from the provider's
  quote, never typed.
- **Full task titles** stay readable. A ref is a link with a dashed
  underline; its URL comes from the provider, and no provider URL lives in
  kowalski.
- **Notes** live in the 15-minute slots of an interval. Click an interval to
  open its slots; notes can be added, edited and deleted.
- **Only focus counts** toward totals, hops, clock-out, the chart and
  posting. Parallel intervals are shown with a badge and never added in.
- **Preferences live in kowalski** (daemon settings): day order (oldest
  first by default, today at the bottom), days shown, collapsed panels,
  language and the rest of Settings.
- **Languages:** English, Portuguese and Japanese, chosen in the ⋯ menu or
  in Settings.

## Day clock colors

Each listed day gets a clock icon (it also opens Post hours for that day):

| Color | Meaning |
|---|---|
| green | the provider's quote says nothing is left to post for every bound task |
| yellow | some posted, or changed after posting, or a `sending`/`unknown` posting (yellow with `!`) |
| red | bound tasks with time and nothing posted |
| gray | nothing to post (no bound task with focus time) |

kowalski computes this in one place by asking the provider's quote (no
posting). `unknown` is never shown as posted or offered for retry.

## Work periods card

Shows **start - lunch out / lunch back - end** on one line (today's schedule
box takes its place). The lunch is the day's longest pause of at least half
the minimum break. A lunch already stored for the day takes its place.

## Paid breaks

The provider may declare paid break windows (for example 15 minutes in
08:00-12:00 and 15 minutes in 13:00-18:00). Paused time inside a window,
lunch excluded, is credited as worked time up to the allowance, so a short
pause does not move clock-out. It counts toward the day's target only, never
toward a task's posted hours. The `paid_breaks` setting overrides the
provider's windows (`08:00-12:00=15,13:00-18:00=15`; empty turns them off).

## History editing

Edit an interval's start and end, merge adjacent intervals, move intervals
or slots to another task, add a past entry, and add, edit or delete notes.
Rules:

- Edits are atomic and refused when stale (the interval changed meanwhile).
- No two focus intervals overlap; an edit that would overlap is refused.
- An interval crossing midnight counts in each day by its part.
- Only intervals of the same task and role merge; parallel never merges
  with focus. Notes keep their absolute times; an edit that would leave a
  note outside its interval is refused.
- The open interval's start can be edited; its end cannot.
- **Posted days may be edited.** Confirmed postings never change; the day
  turns yellow, "changed after posting", with the difference.

## Safety

Strings from notes, titles and the provider render as text. Refs are
encoded in URLs and link schemes are checked. Every change keeps the
`X-Kowalski: 1` and same-origin rules.
