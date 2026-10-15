const std = @import("std");
const update_options = @import("tools/update_options.zig");

pub fn build(b: *std.Build) void {
    // Default to a baseline CPU, not the build machine's: a native release
    // build can emit instructions other machines lack and crash there.
    // Pass -Dcpu=native for a local-only build.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const update_repo = b.option([]const u8, "update-repo", "GitHub owner/name for signed updates; empty disables updates") orelse update_options.default_repo;
    const update_key = b.option([]const u8, "update-key", "Ed25519 release public key as 64 lowercase hex characters") orelse update_options.default_key;
    const preview = b.option(u32, "preview", "Positive preview release number");
    if (preview != null and preview.? == 0) @panic("-Dpreview must be a positive integer");
    const version = if (preview) |n| b.fmt("{s}-preview.{d}", .{ @import("build.zig.zon").version, n }) else @import("build.zig.zon").version;
    if (!update_options.validRepo(update_repo)) @panic("invalid -Dupdate-repo: expected owner/name using only ASCII letters, digits, dot, underscore or hyphen, or empty");
    if (!update_options.validKey(update_key)) @panic("invalid -Dupdate-key: expected exactly 64 lowercase hex characters");
    const sqlite = b.dependency("sqlite", .{});
    const contract = b.addModule("kowalski_provider", .{ .root_source_file = b.path("src/provider_api.zig"), .target = target, .optimize = optimize });
    const provider_check = b.addModule("kowalski_provider_check", .{ .root_source_file = b.path("src/provider_check.zig"), .target = target, .optimize = optimize });
    provider_check.addImport("kowalski_provider", contract);
    const manifest_module = b.createModule(.{ .root_source_file = b.path("src/provider_manifest.zig"), .target = target, .optimize = optimize });
    const no_replace_module = b.createModule(.{ .root_source_file = b.path("src/no_replace.zig"), .target = target, .optimize = optimize });
    const seams: Seams = .{ .sqlite = sqlite, .contract = contract, .manifest = manifest_module, .no_replace = no_replace_module, .update_repo = update_repo, .update_key = update_key, .version = version };

    const exe = b.addExecutable(.{
        .name = "kowalski",
        .root_module = makeModule(b, seams, target, optimize, "src/main.zig"),
    });
    b.installArtifact(exe);

    // The same daemon without a console window, for logon start.
    const background = b.addExecutable(.{
        .name = "kowalskiw",
        .root_module = makeModule(b, seams, target, optimize, "src/kowalskiw.zig"),
    });
    background.subsystem = .windows;
    b.installArtifact(background);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const run_step = b.step("run", "Run kowalski");
    run_step.dependOn(&run.step);

    const signer = b.addExecutable(.{
        .name = "kowalski-sign",
        .root_module = makeModule(b, seams, target, optimize, "tools/sign.zig"),
    });
    addSignerImports(b, seams, target, optimize, signer.root_module);
    const sign_run = b.addRunArtifact(signer);
    sign_run.addPassthruArgs();
    const sign_step = b.step("sign", "Sign a release ZIP");
    sign_step.dependOn(&sign_run.step);

    const keygen = b.addExecutable(.{
        .name = "kowalski-keygen",
        .root_module = makeModule(b, seams, target, optimize, "tools/keygen.zig"),
    });
    addKeygenImports(b, seams, target, optimize, keygen.root_module);
    const keygen_run = b.addRunArtifact(keygen);
    keygen_run.addPassthruArgs();
    const keygen_step = b.step("keygen", "Create an Ed25519 release signing key");
    keygen_step.dependOn(&keygen_run.step);

    const provider_keygen = b.addExecutable(.{ .name = "provider-keygen", .root_module = makeModule(b, seams, target, optimize, "tools/provider_keygen.zig") });
    const provider_keygen_run = b.addRunArtifact(provider_keygen);
    provider_keygen_run.addPassthruArgs();
    b.step("provider-keygen", "Create a provider signing key").dependOn(&provider_keygen_run.step);

    const provider_publish = b.addExecutable(.{ .name = "provider-publish", .root_module = makeModule(b, seams, target, optimize, "tools/provider_publish.zig") });
    const provider_publish_run = b.addRunArtifact(provider_publish);
    provider_publish_run.addPassthruArgs();
    b.step("provider-publish", "Publish a signed provider DLL").dependOn(&provider_publish_run.step);

    const tests = b.addTest(.{
        .root_module = makeModule(b, seams, target, optimize, "src/main.zig"),
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
    const option_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/update_options.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(option_tests).step);
    const signer_tests = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "tools/sign.zig") });
    addSignerImports(b, seams, target, optimize, signer_tests.root_module);
    test_step.dependOn(&b.addRunArtifact(signer_tests).step);
    const keygen_tests = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "tools/keygen.zig") });
    addKeygenImports(b, seams, target, optimize, keygen_tests.root_module);
    test_step.dependOn(&b.addRunArtifact(keygen_tests).step);
    const contract_tests = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "src/provider_check_test.zig") });
    contract_tests.root_module.addImport("kowalski_provider_check", provider_check);
    const example_module = b.createModule(.{ .root_source_file = b.path("examples/provider.zig"), .target = target, .optimize = optimize });
    example_module.addImport("kowalski_provider", contract);
    contract_tests.root_module.addImport("example_provider", example_module);
    test_step.dependOn(&b.addRunArtifact(contract_tests).step);
    const manifest_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/provider_manifest.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(manifest_tests).step);
    const source_tests = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "src/provider_source.zig") });
    test_step.dependOn(&b.addRunArtifact(source_tests).step);
    const fetch_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/provider_source_fetch.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(fetch_tests).step);
    const publisher_tests = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "tools/provider_publish.zig") });
    test_step.dependOn(&b.addRunArtifact(publisher_tests).step);
    const source_integration = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "src/provider_source_integration_test.zig") });
    const publisher_module = makeModule(b, seams, target, optimize, "tools/provider_publish.zig");
    source_integration.root_module.addImport("provider_publish", publisher_module);
    test_step.dependOn(&b.addRunArtifact(source_integration).step);
    const example_dll = b.addLibrary(.{ .name = "example-provider", .linkage = .dynamic, .root_module = example_module });
    const provider_test_options = b.addOptions();
    provider_test_options.addOptionPath("example_dll", example_dll.getEmittedBin());
    tests.root_module.addOptions("provider_test_options", provider_test_options);
    const example_step = b.step("example-provider", "Build and install the example provider DLL");
    const install_example = b.addInstallArtifact(example_dll, .{});
    example_step.dependOn(&install_example.step);
}

fn addSignerImports(b: *std.Build, seams: Seams, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, module: *std.Build.Module) void {
    module.addImport("release_update", makeModule(b, seams, target, optimize, "src/update.zig"));
    module.addImport("release_paths", b.createModule(.{ .root_source_file = b.path("src/paths.zig"), .target = target, .optimize = optimize }));
}

fn addKeygenImports(b: *std.Build, seams: Seams, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, module: *std.Build.Module) void {
    const signer_module = makeModule(b, seams, target, optimize, "tools/sign.zig");
    addSignerImports(b, seams, target, optimize, signer_module);
    module.addImport("release_sign", signer_module);
}

const Seams = struct {
    sqlite: *std.Build.Dependency,
    contract: *std.Build.Module,
    manifest: *std.Build.Module,
    no_replace: *std.Build.Module,
    update_repo: []const u8,
    update_key: []const u8,
    version: []const u8,
};

fn makeModule(
    b: *std.Build,
    seams: Seams,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("kowalski_provider", seams.contract);
    module.addImport("provider_manifest", seams.manifest);
    module.addImport("no_replace", seams.no_replace);
    // The release version has one home: build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", seams.version);
    options.addOption([]const u8, "update_repo", seams.update_repo);
    options.addOption([]const u8, "update_key", seams.update_key);
    module.addOptions("build_options", options);
    const sqlite = seams.sqlite;
    const translated = b.addTranslateC(.{
        .root_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("sqlite_c", translated.createModule());
    module.addIncludePath(sqlite.path("."));
    module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    });
    return module;
}
