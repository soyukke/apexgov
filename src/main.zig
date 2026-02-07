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
        \\
        \\Examples:
        \\  apexgov check force-app --format sarif --out reports/apexgov.sarif
        \\  apexgov profile artifacts/logs --config apexgov.toml --format json --out reports/profile.json
        \\  apexgov profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
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
