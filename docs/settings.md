# Settings

Rules for anything kowalski remembers between runs that is not work data.

## Kinds

Every key is declared once, in `src/settings.zig`, with its kind and the
values it takes. The API refuses an undeclared key.

| Kind | What it is | Where it is changed | API |
|---|---|---|---|
| setting | Behaviour: how time is counted, captured, posted or updated | Settings dialog (or CLI) | listed, writable |
| preference | How a view looks | The view's options button (sidebar, report, chart, Summary); Display in the dialog for choices that change every view | writable |
| state | What the UI remembers (panel collapsed, tour offered) | Changed by using the UI | writable, never shown |
| dev | Only for tests and development | Debug builds only | absent from release builds |

- A **dev** key is compiled in only when the build is not a release build.
  A release build refuses it, the dialog never shows it, and a test fails if
  a release build declares one.
- **Prefixes follow the kind:** `ui_` is for preferences and state only. A key
  that changes counting, posting or launching has no `ui_` prefix.
- **Names say what is stored:** a boolean is named for its true value, and the
  label reads the same way (`ui_show_weekends` labelled "Show weekends").
- **No implementation knobs** as settings (poll rates, renderers, cache
  sizes). Pick a value in code. If it truly needs tuning, it is a dev key.
- **Times and zones use pickers** that follow the time-format preference; no
  free-text zone names.
- **Renaming a key** is a schema step that moves the stored value, so an
  existing database keeps the user's choice.

## Storage

Settings, preferences and state live in the daemon's `settings` table.
Browser storage holds only caches that may be lost at any time with no
change in behaviour; nothing in it is a choice the user made.

## The dialog

Sections, in order: Workday, Day and time zone, Capture, Provider and
posting, Display (choices that change every view), Updates and service. Lists that grow with use (projects, capture sources) never live in
the dialog; they belong to their own view.
