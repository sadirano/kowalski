# Kowalski

**Your workday, at a glance.**

Kowalski is a personal work-session tracker for Windows, built with Zig.
Pick the task you're on, and Kowalski records your time, shows how you
spent your day and projects when you can clock out. No account or external
service is required.

![The Kowalski dashboard](docs/img/overview.png)

> **Early release.** The CLI, HTTP API, provider contract and database
> schema may change before 1.0. Database upgrades always keep your work
> history: sessions, notes, day summaries and posted hours.

## What Kowalski does

### Tracks your time while you work

Start a task, then switch tasks or pause as your day changes. Kowalski
records each stretch as a timed interval, so there are no spreadsheets to
fill in and no start times to remember. A task can also run alongside your
focus task; see [Parallel tasks](docs/parallel-tasks.md).

### Shows you your day

- **Live tracking:** what you're working on right now.
- **Daily breakdown:** how much time went to each task.
- **Work history:** every session, kept day by day.
- **Clock-out projection:** when your workday is expected to end.
- **Task search:** find earlier work and pick it up again.

### Keeps your data yours

Kowalski runs on your machine and keeps your tasks and history there.
Integrations are optional, and it only contacts GitHub when you ask it to
check for updates.

## Get started in three steps

Kowalski runs on Windows; the dashboard is made for desktop browsers.

### 1. Download

Get the latest ZIP from [GitHub Releases](https://github.com/sadirano/kowalski/releases)
and extract it into a folder that stays put, such as
`%LOCALAPPDATA%\Programs\kowalski\`. There is no installer.

### 2. Open Kowalski

Double-click **kowalski.exe**. Kowalski starts in the background and opens
the dashboard at http://127.0.0.1:47100/ in your default browser. Opening it
again while Kowalski runs just opens the dashboard.

> **Windows SmartScreen:** the executables are not code-signed, so Windows
> may warn the first time. If you trust the release you downloaded, choose
> **More info**, then **Run anyway**.

### 3. Start your first task

Click **New task**, type a title and press **Start**.

To look around without touching your real history, open the **⋯** menu and
choose **Take the tour**: it walks through the dashboard on sample data.

The [User Guide](docs/guide.md) covers the dashboard, its shortcuts and the
command line.

## From the command line

From a terminal in the Kowalski folder:

```powershell
.\kowalski.exe autostart on   # start Kowalski at Windows logon, without opening the browser
.\kowalski.exe open           # open the dashboard
.\kowalski.exe update         # check for updates
.\kowalski.exe --help         # list every command
```

## Automation and integrations

Everyday tracking needs only the dashboard. Scripts, other applications and
AI agents can do more through the CLI and the local HTTP API.

Scripts and agents can switch tasks, add notes and correct recorded
intervals. All of this needs an integration you set up; Kowalski works fully
without one.

### Task providers

An optional provider connects tasks to an external ticketing system: it
looks up a task by its reference and posts your recorded hours. The public
build needs no provider. See [Attaching a provider](docs/guide.md#attaching-a-provider)
for installation and approval, the [provider contract](docs/provider-contract.md)
for the technical details, and [examples/provider.zig](examples/provider.zig)
for a reference implementation.

## Settings and updates

Settings live in the dashboard, including whether the browser opens when
Kowalski starts. Your data is kept apart from the application, in
`%APPDATA%\sadirano\kowalski\`.

To update, use **Settings → Advanced → Check for updates** or
`kowalski update`. When you approve an update, Kowalski downloads the release
ZIP, verifies its signature (an unsigned release is refused), checks its size
and the published SHA-256 when available, backs up your database, installs the
two executables and restarts the background service.

### Backups and rollback

Before each database schema upgrade, Kowalski saves a copy next to the
database: `backup-v<old>-<YYYYMMDD-HHMMSS>.db`.

To roll back an update, restore the two executables from the previous
release ZIP. If the schema changed too, restore the matching
`backup-before-<version>-<date>/` database copy. The updater deletes the
`.old` executables once the new version starts, so keep the previous ZIP for
this.

## For developers

Build with Zig 0.17:

```sh
zig build
```

This puts two executables in `zig-out/bin/`:

| Executable | Description |
|---|---|
| `kowalski.exe` | The CLI and daemon, with a console |
| `kowalskiw.exe` | The same daemon without a console window |

```powershell
zig build test                  # unit tests
.\scripts\events-smoke.ps1      # the daemon end to end, on a scratch database
.\kowalski.exe demo             # sample history in an empty database, for screenshots
```

Pushing a version tag such as `v1.2.3`, matching `build.zig.zon`, builds the
release ZIP and publishes it on GitHub.

- [User Guide](docs/guide.md): dashboard, shortcuts and CLI
- [Design notes](docs/DESIGN.md): architecture and implementation decisions
- [UI notes](docs/UI.md): interface design
- [Provider contract](docs/provider-contract.md): provider lifecycle, data formats and compatibility

## Credits

Task search was proposed and first built by [VStorch](https://github.com/VStorch).

## License

Kowalski is open source under the [MIT License](LICENSE). The dashboard
vendors Chart.js 4.4.0 (MIT) under `src/ui/vendor/`, with its license beside
it.
