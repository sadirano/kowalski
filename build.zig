const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite = b.dependency("sqlite", .{});
    const contract = b.addModule("kowalski_provider", .{ .root_source_file = b.path("src/provider_api.zig"), .target = target, .optimize = optimize });
    const provider_check = b.addModule("kowalski_provider_check", .{ .root_source_file = b.path("src/provider_check.zig"), .target = target, .optimize = optimize });
    provider_check.addImport("kowalski_provider", contract);
    const seams: Seams = .{ .sqlite = sqlite, .contract = contract };

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

    // What a dependent package builds tools against (see src/lib.zig).
    const lib = makeModule(b, seams, target, optimize, "src/lib.zig");
    b.modules.put(b.graph.arena, "kowalski", lib) catch @panic("OOM");

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

    const tests = b.addTest(.{
        .root_module = makeModule(b, seams, target, optimize, "src/main.zig"),
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
    const signer_tests = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "tools/sign.zig") });
    addSignerImports(b, seams, target, optimize, signer_tests.root_module);
    test_step.dependOn(&b.addRunArtifact(signer_tests).step);
    const contract_tests = b.addTest(.{ .root_module = makeModule(b, seams, target, optimize, "src/provider_check_test.zig") });
    contract_tests.root_module.addImport("kowalski_provider_check", provider_check);
    const example_module = b.createModule(.{ .root_source_file = b.path("examples/provider.zig"), .target = target, .optimize = optimize });
    example_module.addImport("kowalski_provider", contract);
    contract_tests.root_module.addImport("example_provider", example_module);
    test_step.dependOn(&b.addRunArtifact(contract_tests).step);
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

const Seams = struct {
    sqlite: *std.Build.Dependency,
    contract: *std.Build.Module,
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
    // The release version has one home: build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
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
