const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite = b.dependency("sqlite", .{});
    // A private build compiles its provider in; the public build has none.
    // A package that depends on kowalski passes its own file as `provider`.
    const provider_path = b.option(std.Build.LazyPath, "provider", "Zig file of a private provider (see src/provider_api.zig)");
    const contract = b.addModule("kowalski_provider", .{ .root_source_file = b.path("src/provider_api.zig"), .target = target, .optimize = optimize });
    const provider = b.createModule(.{
        .root_source_file = provider_path orelse b.path("src/provider_none.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider.addImport("kowalski_provider", contract);
    const seams: Seams = .{ .sqlite = sqlite, .contract = contract, .provider = provider };

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

    const tests = b.addTest(.{
        .root_module = makeModule(b, seams, target, optimize, "src/main.zig"),
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
}

const Seams = struct {
    sqlite: *std.Build.Dependency,
    contract: *std.Build.Module,
    provider: *std.Build.Module,
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
    module.addImport("provider_impl", seams.provider);
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
