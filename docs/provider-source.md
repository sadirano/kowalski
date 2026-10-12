# Signed provider sources

A provider publisher creates an Ed25519 signing key with `zig build provider-keygen -- <key-file>`. Keep the key file private and backed up offline. Give users the printed 64 character public key through a separate, trusted channel.

Publish a DLL with:

```text
zig build provider-publish -- <dll> --key <key-file> --provider <instance> --channel <name> --sequence <n> --version <display-version> --out <folder>
```

The output folder contains `manifest.json`, `manifest.sig`, and `<instance>-<sequence>.dll`. The signature is lowercase hexadecimal Ed25519 over the exact bytes `kowalski-provider-manifest-v1\n` followed by the exact `manifest.json` bytes. The publisher writes the DLL first, then renames the signature into place, then renames the manifest into place. Copy to an HTTPS source in that same order. Keep each DLL name immutable. Never reuse a sequence, even for a correction.

Users enroll the HTTPS base URL or folder/UNC source with `kowalski provider source <source> --key <public-key>`. A setup package may place `providers/source.json` next to the user's database with `{"source":"...","key":"..."}`; the user runs `kowalski provider source --from-setup --key <public-key>` after comparing the key, or `--accept-as-is` to accept the proposal without an independent comparison. Enrollment pins the provider and channel and records the current sequence; it does not install a DLL. Run `kowalski provider check` to check for a newer signed release, then `kowalski provider install` to install the newest verified release. Restart kowalski when prompted. `kowalski provider source --stop` returns to manual DLL discovery.

The source is checked once shortly after daemon startup and on explicit checks. The dashboard in step 2 should show the last successful check and any error. A valid signature proves publisher control of the key, but it does not prove that the source is fresh. A lost or stolen signing key requires every user to enroll again with a new key obtained out of band; key rotation inside a manifest is deliberately unsupported.
