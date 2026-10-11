# Parallel tasks

A parallel task stays open beside the focus, for work you keep an eye on
without it being the task you are on: a build, a call, a background job,
another task you look into for a few minutes.

- `kowalski parallel <task>` opens one. It gets its own intervals and
  notes, and the focus carries on.
- `kowalski note -t <task> <text>` writes a note on that task's open
  interval; without `-t` a note goes to the focus.
- Only focus time counts toward totals, hops, the chart and posted hours,
  so no quarter hour is ever posted twice. Parallel intervals keep their
  time and notes for history and search, and the report shows them with a
  badge.
- Switching to a task that runs in parallel closes its parallel interval
  and opens a focus interval on it. Other parallel tasks carry on.
- Pause closes every open task and remembers each one's role; resume
  reopens them the same way.
