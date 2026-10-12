# Releasing kowalski

Use a Windows machine with Zig 0.17, the release signing key, and `gh`.

1. Set the version in `build.zig.zon` and build with `zig build -Doptimize=ReleaseSafe`.
2. Make a directory named `kowalski-vX.Y.Z-windows-x86_64`. Put `zig-out/bin/kowalski.exe`, `zig-out/bin/kowalskiw.exe`, `LICENSE`, `src/ui/vendor/LICENSE-chart.js.txt`, and `README.md` directly inside it. Zip that directory as `kowalski-vX.Y.Z-windows-x86_64.zip`. The updater expects the two executables at `kowalski-vX.Y.Z-windows-x86_64/kowalski.exe` and `kowalski-vX.Y.Z-windows-x86_64/kowalskiw.exe` inside the archive.
3. Run `zig build sign -- kowalski-vX.Y.Z-windows-x86_64.zip`. The command writes `kowalski-vX.Y.Z-windows-x86_64.zip.sig` and prints its path and SHA-256. Use `--key <path>` after the ZIP path to select another key file.
4. Publish both assets with `gh release create vX.Y.Z kowalski-vX.Y.Z-windows-x86_64.zip kowalski-vX.Y.Z-windows-x86_64.zip.sig`.

The signing seed lives outside the repository at `<Roaming AppData>\sadirano\kowalski-dev\release-signing-key.txt`, resolved through the Windows known-folder API. It has an offline backup. Losing both copies means users must reinstall by hand. Key rotation requires a release signed with the old key that carries the new public key.
