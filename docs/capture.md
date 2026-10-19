# Captured time

Outside sources, such as agent sessions or a game overlay, can record time
without anyone pressing start and stop. Each source sends events for its
runs to `POST /api/capture` (or `kowalski capture`), and kowalski opens and
closes intervals from them.

Settings > Captured text chooses whether to keep prompts and outcomes (the default) or record time only; time only also gives unnamed runs the title "Session". Settings > Remove captured text previews and removes prompt and outcome notes for selected reporting days. Time and plain notes are kept.

```json
{"source":"agent","run":"<session id>","event":"<unique id>","kind":"prompt","project_key":"<stable source key>","project_hint":"my-repo","first_prompt":"Investigate startup failure","attended":true}
```

- `source` and `run` name one run (one session). `event` is a stable id:
  an event sent again is ignored, so a source can retry freely.
- `subject` names the run's task as `kowalski switch` does (a ref, `#id`
  or a title; a new title creates the task). A new all-digit `subject` or
  `default_subject` is bound to that ref when a provider is configured.
- `project_key` is an opaque stable source identity; `project_hint` is only
  its display hint. Kowalski maps `(source, project_key)` to a project and
  creates one on first sight. A known key can be repointed later. The first
  qualifying prompt in an unnamed run creates a local task titled from `first_prompt`
  (trimmed to about 60 characters); `subject`/`track` can name another task
  later. Legacy `default_subject` remains accepted for older sources.
- `attended: false` marks a run nobody watches; it never takes the focus.
- `note` (on `prompt`, `busy` or `stop`, up to 2000 characters) records a
  line on the run's interval: what was asked, a report along the way, or
  what came of the turn.

## Kinds

| kind | effect |
|---|---|
| `start` | registers the run; records no time |
| `subject` | the run's task from now on; a working run moves its time there |
| `prompt` | the user handed the run work: it starts in parallel when another task has focus; unattended runs stay parallel |
| `busy` | the run is still working; a run that was idle starts in parallel |
| `stop` | the run's turn is over: its task stays open for a 5-minute grace |
| `end` | the run is gone: its task closes now |

## Rules

- One focus: an attended prompt takes it immediately when no task has it.
  While another task has it, the prompted task works in parallel. If its
  attended prompts span 10 minutes without an attended prompt to the focus
  task, it takes the focus from the first prompt in that stretch. The old
  focus runs in parallel from then. Posted time is never changed.
- A task several runs work on stays open until the last of them stops,
  and closes at the latest point any of them left it.
- A `subject` sent with any event names the run's task before the event
  applies.
- A turn ends without closing anything: a prompt or tool use within 5
  minutes carries on the same interval, so a conversation is one interval,
  not one per turn. Unused, the grace closes the task where the turn ended.
- A task reopened within those 5 minutes in the same role carries on its
  last interval: across a daemon restart, or a short focus handoff when no
  other run held the focus in between.
- A working run that sends nothing for 20 minutes is taken as gone: its
  task closes where that lease ran out, marked `recovered`.
- Switching tasks in kowalski takes the focus immediately. Capture prompts
  for another task begin in parallel and follow the 10-minute rule above.
  Capture never closes or carries on an interval you opened by hand.
- When another task takes the focus while a run sits in its grace, that
  task's focus ends where the run's turn ended: the grace counts only when
  the same conversation carries on.
- The setting `capture_hold_sources` lists sources whose working run keeps
  the focus, such as a game being played: other runs' prompts meanwhile
  run in parallel. The holding run gives the focus up when it stops.

A run remembers its project key and re-resolves its mapping for each event.
A changed effective project while working splits its interval at that
event's timestamp; the earlier portion keeps its prior project. Terminal
events do not reopen time. An archived mapped project continues to receive
capture. Event retries do not create projects, tasks or duplicate intervals.

## History

A source can send closed intervals it missed to `POST /api/capture/history`,
using the same `X-Kowalski` header as `/api/capture`:

```json
{"source":"agent","run":"session-1","attended":true,
 "intervals":[{"event":"span-1","subject":"Project notes",
   "start_ms":1000,"end_ms":2000,
   "notes":[{"event":"note-1","at_ms":1500,"text":"Reviewed the outline"}]}]}
```

`subject` resolves or creates a task as it does for capture. Attended spans
are focus intervals; unattended spans are parallel. Times are Unix
milliseconds. Each interval must end after it starts and no later than now;
each note time must lie within its interval, including either endpoint.
Source, run, event and subject are 1–200 characters; note text is 1–2000
characters. A batch holds at most 500 intervals and 5000 notes.

The batch is atomic. A focus span cannot overlap another focus span, and
spans of the same task cannot overlap, including open intervals and other
spans in the batch. A posting in `confirmed`, `sending` or `unknown` state
for that task on any reporting day the span touches also rejects the batch.
A conflict returns HTTP 409 with the first failing interval index and reason.

Interval and note event ids are unique per source. Sending a known interval
again skips it and its notes; a known note is skipped. Successful requests
return HTTP 200 with `applied` (intervals inserted), `skipped` (known
intervals) and `notes` (notes inserted). History leaves the current focus
and live capture runs as they were.
