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
- **One time field everywhere:** a time of day is typed in the field the
  work windows use, read and shown in the time-format preference. Zones are
  picked from a list, never typed, and an unset zone stays unset until the
  user picks one.
- **No form asks for internal ids** (task, interval or project numbers). A
  correction starts from the thing on screen.
- **Every control uses the dialog's own styling** (`.sel` selects, `.sw`
  switches, dark date fields); no native white control.
- **Renaming a key** is a schema step that moves the stored value, so an
  existing database keeps the user's choice.

## Storage

Settings, preferences and state live in the daemon's `settings` table.
Browser storage holds only caches that may be lost at any time with no
change in behaviour; nothing in it is a choice the user made.

## The dialog

Sections, in order: Workday, Day and time zone, Capture, Provider and
posting, Display (choices that change every view), Updates and service.
Each section names its help topic in `data-help`; nothing depends on the
order. Lists that grow with use (projects, capture sources) never live in
the dialog; they belong to their own view.

## Projects view

One line per project: the name edits in place, archive and delete appear on
hover, archived projects fold away. Deleting asks where the project's time
goes. Capture sources show one line per repository key with its sources;
choosing a project moves every source of that key together, and a key whose
sources disagree says so instead of picking one.
