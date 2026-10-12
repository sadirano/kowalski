# kowalski

A personal work-session tracker for Windows, written in Zig. You pick the
task you're on; kowalski records each stretch as a timed interval, reports
your day grouped by task, and projects when you can clock out.

![The dashboard](docs/img/overview.png)

Version 0.1.0. There is no compatibility promise yet: the CLI, the HTTP
API, the provider contract and the database schema may change before 1.0.

## Getting started

kowalski runs on Windows; the dashboard is made for desktop browsers.

1. Download the zip from the latest
   [release](https://github.com/sadirano/kowalski/releases) and unzip it
   into a folder that stays put, such as `%LOCALAPPDATA%\Programs\kowalski`.
2. Open `kowalski.exe`. It starts kowalski in the background and opens the
   dashboard at `http://127.0.0.1:47100/`. Opening it again while kowalski
   runs just opens the dashboard.
3. Choose **New task**, type a title and press Start. **Take the tour** in
   the ⋯ menu walks through the dashboard on made-up data.

The executables are not signed, so Windows SmartScreen may warn the first
time: choose **More info**, then **Run anyway**.

From a terminal in that folder, `kowalski autostart on` starts kowalski at
logon (quietly, without opening the browser), `kowalski open` opens the
dashboard, and `kowalski --help` lists every command. Settings has a switch
to stop opening the dashboard on launch. Your data lives in
`%APPDATA%\sadirano\kowalski`, not next to the executables.

[docs/guide.md](docs/guide.md) covers the dashboard, the shortcuts and the
command line; [docs/DESIGN.md](docs/DESIGN.md) and [docs/UI.md](docs/UI.md)
hold the design notes.

## Providers

The public build tracks tasks locally and needs nothing else. An optional
provider connects tasks to an external ticketing system, for looking up a
task by its reference and for posting hours. See [Attaching a provider](docs/guide.md#attaching-a-provider)
for installation and approval; `examples/provider.zig` shows the API.
The [provider contract](docs/provider-contract.md) defines its lifecycle,
ownership, JSON shapes, and version rules.

## Development

Building needs Zig 0.17: `zig build` puts `kowalski.exe` and
`kowalskiw.exe` (the same daemon without a console window) in
`zig-out/bin`. `zig build test` runs the tests, `scripts/events-smoke.ps1` checks the
daemon end to end on a scratch database, and `kowalski demo` fills an empty
database with made-up history for screenshots. Pushing a version tag
(`v1.2.3`, matching `build.zig.zon`) builds the release zip and publishes it
on GitHub.

## Credits

Task search was proposed and first built by
[VStorch](https://github.com/VStorch).

## License

MIT, see [LICENSE](LICENSE). The dashboard vendors Chart.js 4.4.0 (MIT)
under `src/ui/vendor/`, with its license beside it.
