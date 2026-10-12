# Releasing kowalski

Use a Windows machine with Zig 0.17, the release signing key, and `gh`.

1. Set the version in `build.zig.zon`, run `zig build test`, and build with `zig build -Doptimize=ReleaseSafe`. A `v*` tag only re-runs these checks in CI; it publishes nothing.
2. Make a directory named `kowalski-vX.Y.Z-windows-x86_64`. Put `zig-out/bin/kowalski.exe`, `zig-out/bin/kowalskiw.exe`, `LICENSE`, `src/ui/vendor/LICENSE-chart.js.txt`, and `README.md` directly inside it. Zip that directory as `kowalski-vX.Y.Z-windows-x86_64.zip` with `tar -a -c -f kowalski-vX.Y.Z-windows-x86_64.zip kowalski-vX.Y.Z-windows-x86_64` (Windows' own `tar`); Windows PowerShell's `Compress-Archive` writes backslash paths, which the updater rejects. The updater expects the two executables at `kowalski-vX.Y.Z-windows-x86_64/kowalski.exe` and `kowalski-vX.Y.Z-windows-x86_64/kowalskiw.exe` inside the archive.
3. Run `zig build sign -- kowalski-vX.Y.Z-windows-x86_64.zip`. The command writes `kowalski-vX.Y.Z-windows-x86_64.zip.sig` and prints its path and SHA-256. Use `--key <path>` after the ZIP path to select another key file.
4. Publish both assets with `gh release create vX.Y.Z kowalski-vX.Y.Z-windows-x86_64.zip kowalski-vX.Y.Z-windows-x86_64.zip.sig`.

For an offline install, put the ZIP and matching `.sig` together and run
`kowalski update --from <absolute path to ZIP>`. The updater verifies the same
signature and archive layout as a downloaded release. The previous daemon
guards the new one, taking a database snapshot after shutdown. If the candidate
does not become ready and stay healthy, it restores the previous executables
and snapshot. `update.json` beside the database records the result and lets the
next launch finish an interrupted rollback. Preserve it during diagnosis.

The signing seed lives outside the repository at `<Roaming AppData>\sadirano\kowalski-dev\release-signing-key.txt`, resolved through the Windows known-folder API. It has an offline backup. Losing both copies means users must reinstall by hand. Key rotation requires a release signed with the old key that carries the new public key.

## For forks

Run `zig build keygen -- <key file path>` to create a private release key outside the repository. Keep an offline backup. The command prints the public key and the exact `-Dupdate-key=<hex>` flag; never commit or share the key file. Build with `zig build -Doptimize=ReleaseSafe -Dupdate-repo=you/yourfork -Dupdate-key=<hex>`, then sign with `zig build sign -Dupdate-key=<hex> -- <zip path> --key <key file path>` and publish the ZIP and `.sig` as above. Fork builds and original builds reject each other's releases; switching between them requires a manual install. Organisations distributing builds themselves can use `-Dupdate-repo=` to turn off the updater.
