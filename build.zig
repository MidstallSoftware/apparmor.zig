const std = @import("std");

fn evalChildProcess(s: *std.Build.Step, argv: []const []const u8, cwd: []const u8) !void {
    const arena = s.owner.allocator;

    try s.handleChildProcUnsupported(null, argv);
    try std.Build.Step.handleVerbose(s.owner, null, argv);

    const result = std.ChildProcess.run(.{
        .allocator = arena,
        .argv = argv,
        .cwd = cwd,
    }) catch |err| return s.fail("unable to spawn {s}: {s}", .{ argv[0], @errorName(err) });

    if (result.stderr.len > 0) {
        try s.result_error_msgs.append(arena, result.stderr);
    }

    try s.handleChildProcessTerm(result.term, null, argv);
}

const LexStep = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    output_source: std.Build.GeneratedFile,
    output_header: std.Build.GeneratedFile,

    pub fn create(b: *std.Build, source: std.Build.LazyPath) *LexStep {
        const self = b.allocator.create(LexStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("Lex {s}", .{source.getDisplayName()}),
                .owner = b,
                .makeFn = make,
            }),
            .source = source,
            .output_source = .{ .step = &self.step },
            .output_header = .{ .step = &self.step },
        };

        source.addStepDependencies(&self.step);
        return self;
    }

    fn make(step: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
        const b = step.owner;
        const self = @fieldParentPtr(LexStep, "step", step);

        var man = b.graph.cache.obtain();
        defer man.deinit();

        _ = try man.addFile(self.source.getPath2(b, step), null);

        const name = std.fs.path.stem(self.source.getPath2(b, step));

        if (try step.cacheHit(&man)) {
            const digest = man.final();
            self.output_source.path = try b.cache_root.join(b.allocator, &.{ "o", &digest, b.fmt("{s}.c", .{name}) });
            self.output_header.path = try b.cache_root.join(b.allocator, &.{ "o", &digest, b.fmt("{s}.h", .{name}) });
            return;
        }

        const digest = man.final();
        const cache_path = "o" ++ std.fs.path.sep_str ++ digest;

        var cache_dir = b.cache_root.handle.makeOpenPath(cache_path, .{}) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, cache_path, @errorName(err),
            });
        };
        defer cache_dir.close();

        const cmd = try b.findProgram(&.{ "flex", "lex" }, &.{});

        try evalChildProcess(step, &.{
            cmd,
            self.source.getPath2(b, step),
        }, try b.cache_root.join(b.allocator, &.{ "o", &digest }));

        self.output_source.path = try b.cache_root.join(b.allocator, &.{ "o", &digest, b.fmt("{s}.c", .{name}) });
        self.output_header.path = try b.cache_root.join(b.allocator, &.{ "o", &digest, b.fmt("{s}.h", .{name}) });

        try step.writeManifest(&man);
    }
};

const AfProtosStep = struct {
    step: std.Build.Step,
    target: std.Target,
    output: std.Build.GeneratedFile,

    pub fn create(b: *std.Build, target: std.Target) *AfProtosStep {
        const self = b.allocator.create(AfProtosStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "Generate af_protos.h",
                .owner = b,
                .makeFn = make,
            }),
            .target = target,
            .output = .{ .step = &self.step },
        };
        return self;
    }

    pub fn getDirectory(self: *AfProtosStep) std.Build.LazyPath {
        return .{ .generated_dirname = .{
            .generated = &self.output,
            .up = 0,
        } };
    }

    fn make(step: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
        const b = step.owner;
        const self = @fieldParentPtr(AfProtosStep, "step", step);

        const tempPath = b.makeTempPath();

        {
            var tempFile = try std.fs.createFileAbsolute(b.pathJoin(&.{ tempPath, "af_protos-input.h" }), .{});
            defer tempFile.close();

            try tempFile.writeAll("#include <netinet/in.h>");
        }

        try step.evalChildProcess(&.{
            b.graph.zig_exe,
            "cc",
            b.fmt("--target={s}", .{try self.target.zigTriple(b.allocator)}),
            "-E",
            "-dM",
            b.pathJoin(&.{ tempPath, "af_protos-input.h" }),
            "-o",
            b.pathJoin(&.{ tempPath, "af_protos-gen.h" }),
        });

        var man = b.graph.cache.obtain();
        defer man.deinit();

        var tempFile = try std.fs.openFileAbsolute(b.pathJoin(&.{ tempPath, "af_protos-gen.h" }), .{});
        defer tempFile.close();

        const tempFileMeta = try tempFile.metadata();

        _ = try man.addFile(b.pathJoin(&.{ tempPath, "af_protos-gen.h" }), tempFileMeta.size());

        if (try step.cacheHit(&man)) {
            const digest = man.final();
            self.output.path = try b.cache_root.join(b.allocator, &.{ "o", &digest, "af_protos.h" });
            return;
        }

        const digest = man.final();
        const cache_path = "o" ++ std.fs.path.sep_str ++ digest;
        self.output.path = try b.cache_root.join(b.allocator, &.{ "o", &digest, "af_protos.h" });

        var cache_dir = b.cache_root.handle.makeOpenPath(cache_path, .{}) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, cache_path, @errorName(err),
            });
        };
        defer cache_dir.close();

        var outputFile = try cache_dir.createFile("af_protos.h", .{});
        defer outputFile.close();

        while (try tempFile.reader().readUntilDelimiterOrEofAlloc(b.allocator, '\n', tempFileMeta.size())) |line| {
            defer b.allocator.free(line);

            if (std.mem.indexOf(u8, line, "IPPROTO_MAX") != null) continue;

            try outputFile.writer().writeAll(line);
            try outputFile.writer().writeByte('\n');
        }

        try step.writeManifest(&man);
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(std.Build.Step.Compile.Linkage, "linkage", "whether to statically or dynamically link the library") orelse .static;

    const source = b.dependency("apparmor", .{});

    const libapparmor = std.Build.Step.Compile.create(b, .{
        .name = "apparmor",
        .root_module = .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
        .kind = .lib,
        .linkage = linkage,
        .version = .{
            .major = 1,
            .minor = 12,
            .patch = 3,
        },
    });

    libapparmor.expect_errors = .{ .contains = "" };

    libapparmor.version_script = source.path("libraries/libapparmor/src/libapparmor.map");
    libapparmor.addIncludePath(source.path("libraries/libapparmor/include"));
    libapparmor.addIncludePath(AfProtosStep.create(b, target.result).getDirectory());

    {
        const lex = LexStep.create(b, source.path("libraries/libapparmor/src/scanner.l"));

        libapparmor.addIncludePath(.{ .generated_dirname = .{
            .generated = &lex.output_header,
            .up = 0,
        } });

        libapparmor.addCSourceFile(.{ .file = .{
            .generated = &lex.output_source,
        } });

        libapparmor.step.dependOn(&lex.step);
    }

    libapparmor.addCSourceFiles(.{
        .files = &.{
            source.path("libraries/libapparmor/src/libaalogparse.c").getPath(source.builder),
            source.path("libraries/libapparmor/src/kernel.c").getPath(source.builder),
            source.path("libraries/libapparmor/src/private.c").getPath(source.builder),
            source.path("libraries/libapparmor/src/features.c").getPath(source.builder),
            source.path("libraries/libapparmor/src/kernel_interface.c").getPath(source.builder),
            source.path("libraries/libapparmor/src/policy_cache.c").getPath(source.builder),
            source.path("libraries/libapparmor/src/PMurHash.c").getPath(source.builder),
        },
        .flags = &.{"-D_GNU_SOURCE"},
    });

    {
        const headers: []const []const u8 = &.{
            "sys/apparmor.h",
            "sys/apparmor_private.h",
        };

        for (headers) |header| {
            const install_file = b.addInstallFileWithDir(source.path(b.pathJoin(&.{ "libraries", "libapparmor", "include", header })), .header, header);
            b.getInstallStep().dependOn(&install_file.step);
            libapparmor.installed_headers.append(&install_file.step) catch @panic("OOM");
        }
    }

    b.installArtifact(libapparmor);
}
