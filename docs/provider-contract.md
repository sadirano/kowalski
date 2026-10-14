# Provider contract v3

This is the normative contract for provider DLLs loaded by kowalski. Build
one Windows x86_64 DLL that imports `kowalski_provider` and exports
`kowalskiProvider` and `kowalskiProviderInfo`. The example builds with
`zig build example-provider`.

Place one DLL directly in the `providers` folder beside the database. The
daemon copies it into its private cache, verifies its SHA-256, and loads it
only after the user approves that exact hash. DLL dependencies may be loaded
only from System32. A Windows version resource is recommended: its
ProductName, FileVersion, and CompanyName are displayed as publisher claims
before approval. Only the daemon process loads and calls the provider; the
CLI uses the daemon.

## ABI and versioning

The ABI targets Windows x86_64. Both exports and all function pointers use
the C calling convention. `Bytes`, `Status`, and `Table` have the `extern`
layouts in `src/provider_api.zig`; their fields and order are fixed for v3.
`Bytes` is a UTF-8 pointer and length, with a null pointer representing an
empty value. The entry is `fn (requested: u32) callconv(.c) ?*const Table`.
It returns null for every version it does not implement, including future
versions. A returned table's `version` exactly matches the request.

`kowalskiProviderInfo` has type `Info = fn () callconv(.c) Bytes`. It returns
static UTF-8 JSON `{"contracts":[3],"name":"...","build":"..."}`.
It can be called before initialization, and its bytes remain valid for the
process lifetime. `contracts` lists the versions the entry implements.

Changing the ABI or a required JSON meaning requires a new contract version.
Optional JSON keys may be added without a version bump only if ignoring them
keeps the operation's meaning. New behavior is enabled by capability keys in
`traits`, such as `sessions`.

## Lifecycle and threading

The host obtains the table from the entry, checks the exact version, reads
info, creates the provider data folder, and calls `init` once before any
operational function. Before init, it may read only `version`, `instance`,
and `traits`, and may call the info export. The init configuration is JSON
`{"contract":3,"data_dir":"<absolute path>"}`. The data folder is
`<database folder>/providers/<instance>`. The provider writes the context
for all later calls to `out_context`; it may return its original table
context. A nonzero init status makes the host continue without this provider.

Operational calls never run concurrently. They may run on any thread, and a
call may outlive the host's wait deadline. The host calls `deinit` at most
once, after the final call and never while a call is in flight. It may skip
`deinit` at process exit if a call is still running. A provider crash stops
the host process.

Request bytes are borrowed only for the duration of a call and may not be
retained. Output bytes and `Status.message` remain provider owned until
the host passes them to `free` using the initialized context. The host never
frees a null pointer. `instance`, `traits`, the table, and info bytes remain
valid for the process lifetime. The host copies the table and replaces its
context with init's output before making operational calls.

## Status and operations

`Status.code == 0` means success; other codes belong to the provider.
`retry_safe == 1` means calling again cannot repeat an effect.
`outcome_known == 0` means a remote operation may or may not have happened.
`message` is readable detail and is freed with `free` when non-null.

`instance` is the binding namespace for this provider's generic refs.
`traits` is empty or a static JSON object. All keys are optional:
`link` is a URL template with a percent-encoded `{ref}` replacement;
`paid_breaks` is an array of `{"from":"HH:MM","to":"HH:MM","minutes":N}`
windows, where a pause counts as work up to `minutes`; `sessions: true`
allows session posts with local start and end. `not_signed_in_code` is a
nonzero integer: the `Status.code` any call returns when the session it
needs is missing or rejected, never for a network or server failure. On it
the dashboard opens sign-in, so a provider that checks its session in
`quote` lets the user sign in before posting. `settings` has up to 16
entries shaped as `{"name":"a_z0_9","label":"...","labels":{...},
"hint":"...","hints":{...},"type":"choice"|"text",
"choices":[{"value":"...","label":"...","labels":{...}}],
"default":"..."}`. They appear in Settings and are stored as
`provider.<name>`. `post_options` has up to 16 entries of the same general
shape, but no choices or default and type `bool`; users choose them for each
post. Each malformed list is dropped whole, and each bad entry on its own.

`fields` returns a JSON array of objects with required `name`, `label`,
`type`, and `order`. Optional `labels` maps language codes (including `pt`
and `ja`) to translated labels; `label` remains the English CLI text.

`lookup` accepts a ref and returns JSON `{"title":"...","fields":
{"<name>":"<value>"}}`.

`quote` accepts JSON with `day`, `ref`, `day_over`, `task_open`,
`total_focus_ms`, and confirmed `posted` amounts in oldest-first order. It
returns JSON with `post`, `reason`, `amount_text`, and `amount_micro`. The
provider owns the posting policy.

`post` accepts JSON with stable `posting_id`, `day`, `ref`, `amount_text`,
`amount_micro`, `text`, the task title, the policy inputs, `settings`
(every declared setting, stored or default), and `options` (every declared
post option). A session post also carries `start` and `end` as local
`HH:MM` on the same day. A session reaching midnight uses end `23:59`;
the entry covers that span and its amounts are quoted for that session.
Output may be empty or JSON with accepted `amount_text`, `amount_micro`,
and arbitrary `data`.

`login_prompts` returns a JSON array of objects with required `name`,
`label`, plus optional boolean `secret` (default false) and `labels` as
for fields. The
CLI and dashboard mask secret answers. `login` accepts JSON
`{"<name>":"<answer>"}`; it may be called in the CLI process or on the
daemon's worker. The provider saves any credentials it needs itself.
