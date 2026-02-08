const std = @import("std");
const apexgov = @import("apexgov");

const CheckOptions = struct {
    config_path: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    format: apexgov.model.OutputFormat = .text,
    threshold: ?apexgov.model.Severity = .warning,
    paths: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *CheckOptions, gpa: std.mem.Allocator) void {
        self.paths.deinit(gpa);
    }
};

const ProfileOptions = struct {
    config_path: ?[]const u8 = null,
    baseline_path: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    format: apexgov.model.OutputFormat = .text,
    paths: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ProfileOptions, gpa: std.mem.Allocator) void {
        self.paths.deinit(gpa);
    }
};

const EmulateOptions = struct {
    out_dir: ?[]const u8 = null,
    iterations: ?u64 = null,
    anchor_soql_ms: ?u64 = null,
    base_ms: ?u64 = null,
    max_weight_ms: ?u64 = null,
    use_nix: bool = false,
};

const EmulateTestOptions = struct {
    tests_dir: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    cpu_limit_ms: ?u64 = null,
    heap_limit_bytes: ?u64 = null,
    use_nix: bool = false,
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    const exit_code = run(gpa, argv) catch |err| {
        if (err == error.HelpRequested) return;
        std.debug.print("error: {s}\n\n", .{@errorName(err)});
        printUsage();
        std.process.exit(2);
    };

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

fn run(gpa: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len < 2) {
        printUsage();
        return 0;
    }

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return 0;
    }

    if (std.mem.eql(u8, cmd, "check")) {
        return runCheck(gpa, argv[2..]);
    }
    if (std.mem.eql(u8, cmd, "profile")) {
        return runProfile(gpa, argv[2..]);
    }
    if (std.mem.eql(u8, cmd, "emulate")) {
        return runEmulate(gpa, argv[2..]);
    }

    return error.UnknownCommand;
}

fn runCheck(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    var opts = try parseCheckOptions(gpa, args);
    defer opts.deinit(gpa);

    const cfg = try apexgov.config.load(gpa, opts.config_path);

    var findings = try apexgov.check.runWithConfig(gpa, opts.paths.items, cfg);
    defer apexgov.model.deinitFindings(gpa, &findings);

    try emitCheckOutput(opts.out_path, opts.format, findings.items);

    if (opts.threshold) |threshold| {
        const fail_count = countFindingsAtOrAbove(findings.items, threshold);
        if (fail_count > 0) return 1;
    }

    return 0;
}

fn runProfile(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    var opts = try parseProfileOptions(gpa, args);
    defer opts.deinit(gpa);

    const cfg = try apexgov.config.load(gpa, opts.config_path);

    var profiles = try apexgov.profile.run(gpa, opts.paths.items, cfg);
    defer apexgov.model.deinitProfiles(gpa, &profiles);

    var regressions = try apexgov.profile.compareWithBaseline(
        gpa,
        profiles.items,
        opts.baseline_path,
        cfg.ci.regression_percent,
    );
    defer apexgov.profile.deinitRegressions(gpa, &regressions);

    try emitProfileOutput(opts.out_path, opts.format, profiles.items);

    var has_violation = false;
    for (profiles.items) |profile| {
        if (profile.anyExceeded()) {
            has_violation = true;
            break;
        }
    }

    if (regressions.items.len > 0) {
        printRegressions(regressions.items, cfg.ci.regression_percent);
    }

    const fail_for_regression = cfg.ci.fail_on_regression and regressions.items.len > 0;
    return if (has_violation or fail_for_regression) 1 else 0;
}

fn runEmulate(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "test")) {
        return runEmulateTest(gpa, args[1..]);
    }

    return runEmulateCalibration(gpa, args);
}

fn runEmulateCalibration(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    const opts = try parseEmulateOptions(args);
    const script_path = try resolveToolScript(gpa, "tools/java-calibration/run.sh", error.JavaCalibrationScriptNotFound);
    defer gpa.free(script_path);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    if (opts.use_nix) {
        try ensureNixCacheEnv(gpa, &env_map);
    }

    if (opts.iterations) |value| try setUnsignedEnv(gpa, &env_map, "ITERATIONS", value);
    if (opts.anchor_soql_ms) |value| try setUnsignedEnv(gpa, &env_map, "ANCHOR_SOQL_MS", value);
    if (opts.base_ms) |value| try setUnsignedEnv(gpa, &env_map, "BASE_MS", value);
    if (opts.max_weight_ms) |value| try setUnsignedEnv(gpa, &env_map, "MAX_WEIGHT_MS", value);

    var child_args: std.ArrayList([]const u8) = .empty;
    defer child_args.deinit(gpa);

    if (opts.use_nix) {
        try child_args.append(gpa, "nix");
        try child_args.append(gpa, "develop");
        try child_args.append(gpa, "-c");
    }
    try child_args.append(gpa, "/bin/bash");
    try child_args.append(gpa, script_path);
    if (opts.out_dir) |out_dir| {
        try child_args.append(gpa, out_dir);
    }

    var child = std.process.Child.init(child_args.items, gpa);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.env_map = &env_map;

    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn runEmulateTest(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    const opts = try parseEmulateTestOptions(args);
    const script_path = try resolveToolScript(gpa, "tools/java-emulation/run-tests.sh", error.JavaEmulationScriptNotFound);
    defer gpa.free(script_path);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    if (opts.use_nix) {
        try ensureNixCacheEnv(gpa, &env_map);
    }
    if (opts.cpu_limit_ms) |value| try setUnsignedEnv(gpa, &env_map, "CPU_LIMIT_MS", value);
    if (opts.heap_limit_bytes) |value| try setUnsignedEnv(gpa, &env_map, "HEAP_LIMIT_BYTES", value);

    var child_args: std.ArrayList([]const u8) = .empty;
    defer child_args.deinit(gpa);

    if (opts.use_nix) {
        try child_args.append(gpa, "nix");
        try child_args.append(gpa, "develop");
        try child_args.append(gpa, "-c");
    }
    try child_args.append(gpa, "/bin/bash");
    try child_args.append(gpa, script_path);
    if (opts.tests_dir) |tests_dir| {
        try child_args.append(gpa, "--tests-dir");
        try child_args.append(gpa, tests_dir);
    }
    if (opts.out_dir) |out_dir| {
        try child_args.append(gpa, "--out-dir");
        try child_args.append(gpa, out_dir);
    }

    var child = std.process.Child.init(child_args.items, gpa);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.env_map = &env_map;

    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn parseCheckOptions(gpa: std.mem.Allocator, args: []const []const u8) !CheckOptions {
    var opts = CheckOptions{};
    errdefer opts.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printCheckHelp();
            return error.HelpRequested;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.config_path = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--config")) |value| {
            opts.config_path = value;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.format = apexgov.model.OutputFormat.fromString(args[i]) orelse return error.InvalidFormat;
            i += 1;
            continue;
        }
        if (optionValue(arg, "--format")) |value| {
            opts.format = apexgov.model.OutputFormat.fromString(value) orelse return error.InvalidFormat;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.out_path = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--out")) |value| {
            opts.out_path = value;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--severity-threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.threshold = try parseThreshold(args[i]);
            i += 1;
            continue;
        }
        if (optionValue(arg, "--severity-threshold")) |value| {
            opts.threshold = try parseThreshold(value);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;

        try opts.paths.append(gpa, arg);
        i += 1;
    }

    if (opts.paths.items.len == 0) {
        try opts.paths.append(gpa, "force-app");
    }

    return opts;
}

fn parseProfileOptions(gpa: std.mem.Allocator, args: []const []const u8) !ProfileOptions {
    var opts = ProfileOptions{};
    errdefer opts.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printProfileHelp();
            return error.HelpRequested;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.config_path = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--config")) |value| {
            opts.config_path = value;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.format = apexgov.model.OutputFormat.fromString(args[i]) orelse return error.InvalidFormat;
            i += 1;
            continue;
        }
        if (optionValue(arg, "--format")) |value| {
            opts.format = apexgov.model.OutputFormat.fromString(value) orelse return error.InvalidFormat;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.out_path = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--out")) |value| {
            opts.out_path = value;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--baseline")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.baseline_path = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--baseline")) |value| {
            opts.baseline_path = value;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;

        try opts.paths.append(gpa, arg);
        i += 1;
    }

    if (opts.paths.items.len == 0) {
        return error.MissingInputPath;
    }

    return opts;
}

fn parseEmulateOptions(args: []const []const u8) !EmulateOptions {
    var opts = EmulateOptions{};
    var seen_runtime = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printEmulateHelp();
            return error.HelpRequested;
        }
        if (std.mem.eql(u8, arg, "--nix")) {
            opts.use_nix = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.out_dir = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--out")) |value| {
            opts.out_dir = value;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.iterations = try parseUnsignedOption(args[i]);
            i += 1;
            continue;
        }
        if (optionValue(arg, "--iterations")) |value| {
            opts.iterations = try parseUnsignedOption(value);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--anchor-soql-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.anchor_soql_ms = try parseUnsignedOption(args[i]);
            i += 1;
            continue;
        }
        if (optionValue(arg, "--anchor-soql-ms")) |value| {
            opts.anchor_soql_ms = try parseUnsignedOption(value);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--base-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.base_ms = try parseUnsignedOption(args[i]);
            i += 1;
            continue;
        }
        if (optionValue(arg, "--base-ms")) |value| {
            opts.base_ms = try parseUnsignedOption(value);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-weight-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.max_weight_ms = try parseUnsignedOption(args[i]);
            i += 1;
            continue;
        }
        if (optionValue(arg, "--max-weight-ms")) |value| {
            opts.max_weight_ms = try parseUnsignedOption(value);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;

        if (!seen_runtime and std.mem.eql(u8, arg, "java")) {
            seen_runtime = true;
            i += 1;
            continue;
        }
        if (opts.out_dir != null) return error.TooManyInputPaths;

        opts.out_dir = arg;
        i += 1;
    }

    return opts;
}

fn parseEmulateTestOptions(args: []const []const u8) !EmulateTestOptions {
    var opts = EmulateTestOptions{};

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printEmulateHelp();
            return error.HelpRequested;
        }
        if (std.mem.eql(u8, arg, "--nix")) {
            opts.use_nix = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.out_dir = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--out")) |value| {
            opts.out_dir = value;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cpu-limit-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.cpu_limit_ms = try parseUnsignedOption(args[i]);
            i += 1;
            continue;
        }
        if (optionValue(arg, "--cpu-limit-ms")) |value| {
            opts.cpu_limit_ms = try parseUnsignedOption(value);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--heap-limit-bytes")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.heap_limit_bytes = try parseUnsignedOption(args[i]);
            i += 1;
            continue;
        }
        if (optionValue(arg, "--heap-limit-bytes")) |value| {
            opts.heap_limit_bytes = try parseUnsignedOption(value);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tests-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.tests_dir = args[i];
            i += 1;
            continue;
        }
        if (optionValue(arg, "--tests-dir")) |value| {
            opts.tests_dir = value;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;

        if (opts.tests_dir != null) return error.TooManyInputPaths;
        opts.tests_dir = arg;
        i += 1;
    }

    return opts;
}

fn optionValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    if (arg.len <= name.len) return null;
    if (arg[name.len] != '=') return null;
    return arg[(name.len + 1)..];
}

fn parseThreshold(value: []const u8) !?apexgov.model.Severity {
    if (std.ascii.eqlIgnoreCase(value, "none")) return null;
    return apexgov.model.Severity.fromString(value) orelse error.InvalidSeverity;
}

fn parseUnsignedOption(value: []const u8) !u64 {
    return try std.fmt.parseUnsigned(u64, value, 10);
}

fn setUnsignedEnv(gpa: std.mem.Allocator, env_map: *std.process.EnvMap, key: []const u8, value: u64) !void {
    const as_text = try std.fmt.allocPrint(gpa, "{d}", .{value});
    defer gpa.free(as_text);
    try env_map.put(key, as_text);
}

fn ensureNixCacheEnv(gpa: std.mem.Allocator, env_map: *std.process.EnvMap) !void {
    if (env_map.get("XDG_CACHE_HOME") != null) return;

    const cache_dir = ".cache";
    try std.fs.cwd().makePath(cache_dir);

    const absolute_cache = try std.fs.cwd().realpathAlloc(gpa, cache_dir);
    defer gpa.free(absolute_cache);
    try env_map.put("XDG_CACHE_HOME", absolute_cache);
}

fn resolveToolScript(gpa: std.mem.Allocator, relative_path: []const u8, not_found_error: anyerror) ![]u8 {
    const cwd_candidate = relative_path;
    if (pathExists(cwd_candidate)) return try gpa.dupe(u8, cwd_candidate);

    const exe_path = try std.fs.selfExePathAlloc(gpa);
    defer gpa.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return not_found_error;

    const resolved = try std.fs.path.join(gpa, &.{ exe_dir, "..", "..", relative_path });
    errdefer gpa.free(resolved);
    if (pathExists(resolved)) return resolved;

    return not_found_error;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn countFindingsAtOrAbove(findings: []const apexgov.model.Finding, threshold: apexgov.model.Severity) usize {
    var count: usize = 0;
    for (findings) |finding| {
        if (finding.severity.rank() >= threshold.rank()) count += 1;
    }
    return count;
}

fn emitCheckOutput(out_path: ?[]const u8, format: apexgov.model.OutputFormat, findings: []const apexgov.model.Finding) !void {
    if (out_path) |path| {
        var file = try createOutputFile(path);
        defer file.close();

        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        const writer = &file_writer.interface;
        try apexgov.report.writeCheck(writer, format, findings);
        try writer.writeAll("\n");
        try writer.flush();
        return;
    }

    var write_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&write_buffer);
    const writer = &stdout_writer.interface;
    try apexgov.report.writeCheck(writer, format, findings);
    try writer.writeAll("\n");
    try writer.flush();
}

fn emitProfileOutput(out_path: ?[]const u8, format: apexgov.model.OutputFormat, profiles: []const apexgov.model.ProfileResult) !void {
    if (out_path) |path| {
        var file = try createOutputFile(path);
        defer file.close();

        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        const writer = &file_writer.interface;
        try apexgov.report.writeProfile(writer, format, profiles);
        try writer.writeAll("\n");
        try writer.flush();
        return;
    }

    var write_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&write_buffer);
    const writer = &stdout_writer.interface;
    try apexgov.report.writeProfile(writer, format, profiles);
    try writer.writeAll("\n");
    try writer.flush();
}

fn printUsage() void {
    std.debug.print(
        \\apexgov: offline Apex CPU/Heap checker and profiler
        \\
        \\Usage:
        \\  apexgov check [paths...] [--config FILE] [--format text|json|sarif] [--out FILE] [--severity-threshold info|warning|error|none]
        \\  apexgov profile <log_paths...> [--config FILE] [--baseline FILE] [--format text|json|sarif] [--out FILE]
        \\  apexgov emulate [java] [OUT_DIR] [--iterations N] [--anchor-soql-ms N] [--base-ms N] [--max-weight-ms N] [--nix]
        \\  apexgov emulate test [TESTS_DIR] [--out DIR] [--cpu-limit-ms N] [--heap-limit-bytes N] [--nix]
        \\
        \\Examples:
        \\  apexgov check force-app --format sarif --out reports/apexgov.sarif
        \\  apexgov profile artifacts/logs --config apexgov.toml --format json --out reports/profile.json
        \\  apexgov profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
        \\  apexgov emulate java reports/java-calibration-local --iterations 80000 --nix
        \\  apexgov emulate test tools/java-emulation/examples --out reports/java-emulation --nix
        \\
    , .{});
}

fn printCheckHelp() void {
    std.debug.print(
        \\apexgov check
        \\  Static scan for CPU/Heap and governor anti-patterns.
        \\  Default path is `force-app` when omitted.
        \\
    , .{});
}

fn printProfileHelp() void {
    std.debug.print(
        \\apexgov profile
        \\  Parse Apex debug logs and compare CPU/Heap usage against budgets.
        \\  Accepts log files or directories containing .log files.
        \\  Optional: --baseline profile.json for regression checks.
        \\
    , .{});
}

fn printEmulateHelp() void {
    std.debug.print(
        \\apexgov emulate
        \\  Mode 1: CPU calibration
        \\    apexgov emulate [java] [OUT_DIR] [--iterations N] [--anchor-soql-ms N] [--base-ms N] [--max-weight-ms N] [--nix]
        \\  Mode 2: local @Test emulation
        \\    apexgov emulate test [TESTS_DIR] [--out DIR] [--cpu-limit-ms N] [--heap-limit-bytes N] [--nix]
        \\
    , .{});
}

fn createOutputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            try std.fs.cwd().makePath(parent);
        }
    }
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}

fn printRegressions(regressions: []const apexgov.profile.Regression, threshold_percent: u8) void {
    std.debug.print(
        "regression: {d} transaction(s) exceeded baseline by >{d}%\n",
        .{ regressions.len, threshold_percent },
    );
    for (regressions) |regression| {
        std.debug.print(
            "  {s} [{s}] cpu {d}->{d} heap {d}->{d}\n",
            .{
                regression.source,
                if (regression.is_async) "async" else "sync",
                regression.cpu_baseline,
                regression.cpu_current,
                regression.heap_baseline,
                regression.heap_current,
            },
        );
    }
}

test "parseEmulateOptions parses flags and positional values" {
    const args = [_][]const u8{
        "java",
        "reports/java-calibration-local",
        "--iterations=80000",
        "--anchor-soql-ms",
        "30",
        "--base-ms=450",
        "--max-weight-ms",
        "120",
        "--nix",
    };

    const opts = try parseEmulateOptions(args[0..]);
    try std.testing.expect(opts.out_dir != null);
    try std.testing.expectEqualStrings("reports/java-calibration-local", opts.out_dir.?);
    try std.testing.expectEqual(@as(?u64, 80000), opts.iterations);
    try std.testing.expectEqual(@as(?u64, 30), opts.anchor_soql_ms);
    try std.testing.expectEqual(@as(?u64, 450), opts.base_ms);
    try std.testing.expectEqual(@as(?u64, 120), opts.max_weight_ms);
    try std.testing.expectEqual(true, opts.use_nix);
}

test "parseEmulateOptions rejects extra positional paths" {
    const args = [_][]const u8{ "java", "out-a", "out-b" };
    try std.testing.expectError(error.TooManyInputPaths, parseEmulateOptions(args[0..]));
}

test "parseEmulateTestOptions parses flags and positional values" {
    const args = [_][]const u8{
        "tools/java-emulation/examples",
        "--out=reports/java-emulation-local",
        "--cpu-limit-ms",
        "8500",
        "--heap-limit-bytes=5500000",
        "--nix",
    };

    const opts = try parseEmulateTestOptions(args[0..]);
    try std.testing.expect(opts.tests_dir != null);
    try std.testing.expectEqualStrings("tools/java-emulation/examples", opts.tests_dir.?);
    try std.testing.expect(opts.out_dir != null);
    try std.testing.expectEqualStrings("reports/java-emulation-local", opts.out_dir.?);
    try std.testing.expectEqual(@as(?u64, 8500), opts.cpu_limit_ms);
    try std.testing.expectEqual(@as(?u64, 5500000), opts.heap_limit_bytes);
    try std.testing.expectEqual(true, opts.use_nix);
}

test "parseEmulateTestOptions rejects extra positional paths" {
    const args = [_][]const u8{ "tests-a", "tests-b" };
    try std.testing.expectError(error.TooManyInputPaths, parseEmulateTestOptions(args[0..]));
}
