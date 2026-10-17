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
  or a title; a new title creates the task).
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
| `prompt` | the user handed the run work: it takes the focus (parallel when unattended) |
| `busy` | the run is still working; a run that was idle starts in parallel |
| `stop` | the run's turn is over: its task stays open for a 5-minute grace |
| `end` | the run is gone: its task closes now |

## Rules

- One focus: the attended run that got the last prompt holds it. A run
  that loses the focus while it still works goes on in parallel, so only
  the user's attention counts toward totals and posted hours.
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
- Tracking by hand outranks capture: while a focus you started is open, a
  `prompt` for another task runs in parallel, and that run does not take
  the focus later without a new prompt. Capture never closes or carries on
  an interval you opened by hand.
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
