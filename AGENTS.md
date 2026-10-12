# AGENTS.md

kowalski is a personal work-session tracker for Windows, written in Zig
0.17. Rules for agents:

- **Free design, one hard requirement: existing data.** The API, schema,
  CLI and UI can change. What must always work: opening an existing
  database and keeping its work history (sessions, notes, day summaries,
  posted hours). Schema changes upgrade it in place.
- **Ticketing is a plugin.** The core knows nothing about any ticketing
  system: task ids, clients or environments are not built-in concepts. A
  task is a generic reference plus fields its provider fills in. The current
  provider lives outside this repo, and removing it leaves a complete
  tracker. Another system plugs in by implementing the provider contract,
  with no change to the core.
- **No vendor identifiers in this repo:** no provider names, URLs, project
  or business-line ids. Importing from another tool belongs to a separate
  tool, not the core; the core exports no database module for one.
- **No environment variables** for input or config. Known folders come from
  the Windows API; options live in settings.
- **Real data never enters the repo.** Check against a copy in a scratch
  dir, never a fixture made from it.
- Build with `zig build`, test with `zig build test` (Zig 0.17).
