# Design

The data model and behavior of kowalski. Contributor rules are in
`AGENTS.md`.

## Tasks

- A task has its own kowalski id and an editable title. An interval's own
  text is kept separately, so a later title change never rewrites history.
- A provider can bind a task to an external ticket: `(provider instance,
  external ref)`, both opaque strings. The provider describes its extra
  fields (label, type, order) and kowalski displays them; it never knows
  what they mean.
- A task without a provider is a complete local task.

## Time model

- A task is worked in **intervals**. Each interval has a fixed role:
  `focus` or `parallel`. A role never changes after the interval opens.
- At most one open focus interval exists. A task has at most one open
  interval.
- Only focus intervals count toward day totals, hops, clock-out and posted
  hours. Parallel intervals keep their time and notes for history and
  search.
- **Switch** closes the current focus and opens a focus interval on the
  target. If the target was running in parallel, its parallel interval
  closes and a focus interval opens. Other parallel intervals carry on.
- **Pause** saves the set of open tasks and their roles, then closes their
  intervals, in one transaction. Pausing with nothing open keeps the saved
  set. **Resume** needs nothing open and turns the saved set back into new
  intervals with the same roles; an empty set does nothing. Any new
  activity, Switch included, clears the saved set.
- **Notes** with a target go to that task's open interval; a target with no
  open interval is an error. Without a target they go to the focus; with no
  focus they are an error, not a guess. Switching to the task that is
  already the focus does nothing.
- Intervals are half-open `[start, end)` in UTC Unix milliseconds. The API
  carries milliseconds or strings, never nanoseconds (too large for
  JavaScript numbers).
- **Days** come from a reporting time zone kept in settings (a Windows zone
  id), not from whatever zone the OS has today. Intervals are not split in
  storage: reports intersect them with the day's bounds. Crossing midnight
  is not a switch.

## Numbers

- **Day total:** the exact focus milliseconds inside the day. Parallel time
  adds nothing.
- **Hop:** an explicit switch back to a task already focused earlier that
  day. Pause, resume and midnight are not switches.
- **Clock-out:** target = daily minutes from settings;
  remaining = target minus today's focus time; while working, clock-out =
  now + remaining, but never before first start + target + lunch minutes.
  While paused, the break taken so far counts toward lunch.
- **Posting amounts** come from the provider's quote. It applies its own
  policy, rounding and precision to the day's focus and confirmed postings,
  so a later post can send only the difference.

## When the machine is not running

- A heartbeat is written every 60 seconds. Every transaction that opens
  an interval also writes the heartbeat, so the heartbeat is never older
  than an open interval.
- **Shutdown, sleep and hibernate** all close every open interval at the
  last heartbeat, and never before the interval's own start. Two triggers,
  either enough: the Windows resume notification, and a heartbeat gap over
  180 seconds (a frozen process wakes up with a gap). Daemon start closes
  anything left open the same way. Recovery runs before any other change is
  accepted, and saves the closed set as the resumable set.
- Nothing restarts by itself afterwards. The user resumes or switches.
- Screen lock pauses inside the `lock_pause` windows (for example lunch and
  the end of the day), read in the reporting zone; a window may cross
  midnight. With no window set, lock does nothing.
- One daemon per user, enforced with a named mutex. Autostart uses the
  current user's Windows Run entry.

## Providers

- One provider interface: a versioned function table with a handshake at
  load. Across it go only fixed-width integers, opaque handles and UTF-8
  pointer-plus-length buffers. The provider frees its own outputs.
- Provider calls run one at a time on a dedicated worker, never while a
  database lock is held. A deadline bounds how long kowalski waits; it does
  not cancel the call. After a timeout the worker stays busy until the call
  returns, and new calls fail at once with "busy". Shutdown saves state and
  exits without waiting for a stuck provider.
- Errors carry a code, whether a retry is safe, and whether the outcome is
  known.
- The provider owns its HTTP/TLS, sessions and credentials (Windows
  Credential Manager). Passwords and tokens never enter kowalski's store or
  logs. `kowalski provider login` asks the prompts the provider lists
  (secret ones masked with `*`) and hands the answers straight to it.
- A provider is a user-approved DLL in the `providers` folder. With no
  provider, kowalski remains a complete tracker.
- **Posting hours** goes through `sending`, `confirmed`, `unknown` and
  `cancelled`. The provider decides whether and how much to post from the
  day's focus and confirmed postings. Several confirmed postings can share
  a day and ref. `sending` is saved before the provider is called, with a
  stable id for provider-side de-duplication. Only a `sending` or `unknown`
  posting blocks another for the same day, provider instance and ref. A
  timeout, or a `sending` row found at startup, becomes `unknown`; a late
  completion is applied when it arrives. Manual resolution is refused while
  that provider call still runs. After a crash, an `unknown` outcome needs
  explicit resolution before another post.

  A session posting records its exact focus range as coverage for its day,
  provider instance and ref. Confirmed, sending and unknown coverage is
  subtracted before offering more sessions, so overlapping or edited focus
  cannot book the same time twice. Older postings have NULL coverage and
  represent day totals; total and session postings cannot mix for one day
  and ref because a total does not identify which minutes it covered.

## Imported history

- Importing from another tool is a separate tool's job, not the core's.
  Up to v0.1.0 kowalski exported its database code as a Zig module for
  such a tool; it no longer does. An importer built against v0.1.0 writes
  schema v3. Kowalski upgrades that database to v5 on open. Imported
  rows become ordinary history;
  import provenance is no longer kept.

## HTTP

- Bound to 127.0.0.1 only. A request whose `Host` is not the loopback
  address and port is refused (this blocks DNS rebinding).
- Changes need `POST`, `PATCH` or `DELETE`, the `X-Kowalski` header, and an
  `Origin`, when present, equal to the dashboard's. GET never changes
  anything.
