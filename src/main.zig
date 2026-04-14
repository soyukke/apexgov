//! main — CLI エントリポイント。
//!
//! `check`, `profile` サブコマンドのルーティングと引数パースを行う。

const std = @import("std");
const apexgov = @import("apexgov");

const CheckOptions = struct {
    config_path: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    format: apexgov.model.OutputFormat = .text,
    threshold: ?apexgov.model.Severity = .warning,
    include_tests: bool = false,
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

pub fn main() void {
    // 再帰が深い Apex コードの解釈実行に備え、スタックサイズを拡大した
    // ワーカースレッドで実行する（macOS メインスレッドのデフォルトは 8 MB）。
    const thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, mainWorker, .{}) catch {
        std.process.exit(2);
    };
    thread.join();
}

fn mainWorker() void {
    const gpa = std.heap.page_allocator;

    const argv = std.process.argsAlloc(gpa) catch std.process.exit(2);
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
    if (std.mem.eql(u8, cmd, "interpret")) {
        return runInterpret(gpa, argv[2..]);
    }
    if (std.mem.eql(u8, cmd, "lsp")) {
        return runLsp(gpa);
    }
    if (std.mem.eql(u8, cmd, "typegen")) {
        return runTypegen(gpa, argv[2..]);
    }

    return error.UnknownCommand;
}

fn runCheck(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    var opts = try parseCheckOptions(gpa, args);
    defer opts.deinit(gpa);

    var cfg = try apexgov.config.load(gpa, opts.config_path);
    cfg.include_tests = opts.include_tests;

    var findings = try apexgov.check.runWithConfig(gpa, opts.paths.items, cfg);
    defer apexgov.model.deinitFindings(gpa, &findings);

    try emitOutput(opts.out_path, apexgov.report.writeCheck, .{ opts.format, findings.items });

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

    try emitOutput(opts.out_path, apexgov.report.writeProfile, .{ opts.format, profiles.items });

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

fn runLsp(gpa: std.mem.Allocator) !u8 {
    try apexgov.lsp.serve(gpa);
    return 0;
}

fn runTypegen(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    var project_root: ?[]const u8 = null;
    var out_dir: []const u8 = ".sfdx/typings/lwc";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            std.debug.print(
                \\Usage: apexgov typegen <sfdx-project-root> [--out DIR]
                \\
                \\Generate LWC TypeScript type definitions from SFDX metadata.
                \\
                \\Options:
                \\  --out DIR   Output directory (default: .sfdx/typings/lwc)
                \\
            , .{});
            return 0;
        } else {
            project_root = args[i];
        }
    }

    const root = project_root orelse {
        std.debug.print("error: project root path is required\n", .{});
        return 2;
    };

    const typegen = apexgov.typegen;

    // 出力ディレクトリを作成
    std.fs.cwd().makePath(out_dir) catch |err| {
        std.debug.print("error: cannot create output directory '{s}': {s}\n", .{ out_dir, @errorName(err) });
        return 2;
    };

    var total_files: u32 = 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const writer = buf.writer(gpa);

    // ファイルパスをソート済みで収集する（出力を決定的にするため）
    const root_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open '{s}': {s}\n", .{ root, @errorName(err) });
        return 2;
    };
    var all_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (all_paths.items) |p| gpa.free(p);
        all_paths.deinit(gpa);
    }
    {
        var walker = try root_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            try all_paths.append(gpa, try gpa.dupe(u8, entry.path));
        }
    }
    std.mem.sort([]const u8, all_paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // --- @salesforce/schema ---
    {
        buf.clearRetainingCapacity();
        var schema_count: u32 = 0;
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            if (!std.mem.endsWith(u8, basename, ".field-meta.xml")) continue;

            const object_name = extractObjectName(entry_path) orelse continue;
            const field_xml = root_dir.readFileAlloc(gpa, entry_path, 64 * 1024) catch continue;
            defer gpa.free(field_xml);

            if (typegen.parseFieldMeta(field_xml, object_name)) |field| {
                try typegen.renderSchemaField(field, writer);
                try writer.writeByte('\n');
                schema_count += 1;
            }
        }

        if (schema_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(&path_buf, "{s}/schema.d.ts", .{out_dir}) catch unreachable;
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items });
            std.debug.print("  schema.d.ts: {d} fields\n", .{schema_count});
            total_files += 1;
        }
    }

    // --- @salesforce/label ---
    {
        buf.clearRetainingCapacity();
        var label_count: u32 = 0;
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            if (!std.mem.endsWith(u8, basename, ".labels-meta.xml")) continue;

            const xml = root_dir.readFileAlloc(gpa, entry_path, 4 * 1024 * 1024) catch continue;
            defer gpa.free(xml);

            const names = try typegen.parseLabelNames(xml, gpa);
            defer gpa.free(names);
            for (names) |name| {
                if (label_count > 0) try writer.writeByte('\n');
                try typegen.renderLabel(name, writer);
                label_count += 1;
            }
        }

        if (label_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(&path_buf, "{s}/customlabels.d.ts", .{out_dir}) catch unreachable;
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items });
            std.debug.print("  customlabels.d.ts: {d} labels\n", .{label_count});
            total_files += 1;
        }
    }

    // --- @salesforce/resourceUrl, messageChannel, contentAssetUrl ---
    // 公式と同じ: 1 リソースにつき 1 ファイル（{name}.{type}.d.ts）
    {
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            const meta = parseMetaFilename(basename) orelse continue;

            buf.clearRetainingCapacity();
            if (std.mem.eql(u8, meta.meta_type, "resource")) {
                try typegen.renderResourceUrl(meta.name, writer);
            } else if (std.mem.eql(u8, meta.meta_type, "messageChannel")) {
                try typegen.renderMessageChannel(meta.name, writer);
            } else if (std.mem.eql(u8, meta.meta_type, "asset")) {
                try typegen.renderContentAssetUrl(meta.name, writer);
            } else continue;

            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.{s}.d.ts", .{ out_dir, meta.name, meta.meta_type }) catch continue;
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items });
            total_files += 1;
        }
    }

    // --- @salesforce/apex ---
    {
        buf.clearRetainingCapacity();
        var method_count: u32 = 0;
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            if (!std.mem.endsWith(u8, basename, ".cls")) continue;
            const class_name = basename[0 .. basename.len - ".cls".len];
            if (class_name.len == 0) continue;

            const source = root_dir.readFileAlloc(gpa, entry_path, 1024 * 1024) catch continue;
            defer gpa.free(source);

            if (std.ascii.indexOfIgnoreCase(source, "@AuraEnabled") == null) continue;

            const methods = try typegen.findAuraEnabledMethods(source, class_name, gpa);
            defer gpa.free(methods);
            for (methods) |method| {
                try typegen.renderApexMethod(method, writer);
                try writer.writeByte('\n');
                method_count += 1;
            }
        }

        if (method_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(&path_buf, "{s}/apex.d.ts", .{out_dir}) catch unreachable;
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items });
            std.debug.print("  apex.d.ts: {d} @AuraEnabled methods\n", .{method_count});
            total_files += 1;
        }
    }

    std.debug.print("typegen: generated {d} type definition file(s) in {s}\n", .{ total_files, out_dir });
    return 0;
}

/// メタファイル名をパースする。例: "leafletjs.resource-meta.xml" → { .name = "leafletjs", .meta_type = "resource" }
fn parseMetaFilename(basename: []const u8) ?struct { name: []const u8, meta_type: []const u8 } {
    const suffix = "-meta.xml";
    if (!std.mem.endsWith(u8, basename, suffix)) return null;
    const without_suffix = basename[0 .. basename.len - suffix.len];
    // 最後の '.' で name と type を分割
    const dot_pos = std.mem.lastIndexOfScalar(u8, without_suffix, '.') orelse return null;
    const name = without_suffix[0..dot_pos];
    const meta_type = without_suffix[dot_pos + 1 ..];
    if (name.len == 0) return null;
    // resource, messageChannel, asset のみ対応
    if (std.mem.eql(u8, meta_type, "resource") or
        std.mem.eql(u8, meta_type, "messageChannel") or
        std.mem.eql(u8, meta_type, "asset"))
    {
        return .{ .name = name, .meta_type = meta_type };
    }
    return null;
}

/// パスから SObject 名を抽出する。
/// 例: "force-app/main/default/objects/Account/fields/Name.field-meta.xml" → "Account"
fn extractObjectName(path: []const u8) ?[]const u8 {
    // "/fields/" の直前のディレクトリ名がオブジェクト名
    const fields_marker = "/fields/";
    const fields_pos = std.mem.indexOf(u8, path, fields_marker) orelse return null;
    const before = path[0..fields_pos];
    // 最後の "/" の直後がオブジェクト名
    const last_sep = std.mem.lastIndexOfScalar(u8, before, '/') orelse return null;
    return before[last_sep + 1 ..];
}

fn runInterpret(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "test")) {
        return runInterpretTest(gpa, args[1..]);
    }
    // Default: interpret test
    return runInterpretTest(gpa, args);
}

fn runInterpretTest(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        if (isHelpFlag(args[i])) {
            std.debug.print(
                \\apexgov interpret test
                \\  Run Apex test classes using the Zig native interpreter.
                \\  Usage: apexgov interpret test <paths...>
                \\
            , .{});
            return 0;
        }
        if (std.mem.startsWith(u8, args[i], "--")) {
            i += 1;
            continue;
        }
        try paths.append(gpa, args[i]);
        i += 1;
    }

    if (paths.items.len == 0) {
        try paths.append(gpa, "force-app");
    }

    var write_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&write_buffer);
    const writer = &stderr_writer.interface;

    const suite = try apexgov.interpret.runTestSuite(gpa, paths.items, writer);
    try writer.flush();

    return if (suite.total > 0 and suite.passed == suite.total) 0 else 1;
}

fn parseCheckOptions(gpa: std.mem.Allocator, args: []const []const u8) !CheckOptions {
    var opts = CheckOptions{};
    errdefer opts.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        if (isHelpFlag(args[i])) {
            printCheckHelp();
            return error.HelpRequested;
        }
        if (try consumeOption(args, &i, "--config")) |v| {
            opts.config_path = v;
            continue;
        }
        if (try consumeOption(args, &i, "--format")) |v| {
            opts.format = apexgov.model.OutputFormat.fromString(v) orelse return error.InvalidFormat;
            continue;
        }
        if (try consumeOption(args, &i, "--out")) |v| {
            opts.out_path = v;
            continue;
        }
        if (try consumeOption(args, &i, "--severity-threshold")) |v| {
            opts.threshold = try parseThreshold(v);
            continue;
        }
        if (std.mem.eql(u8, args[i], "--include-tests")) {
            opts.include_tests = true;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) return error.UnknownOption;

        try opts.paths.append(gpa, args[i]);
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
        if (isHelpFlag(args[i])) {
            printProfileHelp();
            return error.HelpRequested;
        }
        if (try consumeOption(args, &i, "--config")) |v| {
            opts.config_path = v;
            continue;
        }
        if (try consumeOption(args, &i, "--format")) |v| {
            opts.format = apexgov.model.OutputFormat.fromString(v) orelse return error.InvalidFormat;
            continue;
        }
        if (try consumeOption(args, &i, "--out")) |v| {
            opts.out_path = v;
            continue;
        }
        if (try consumeOption(args, &i, "--baseline")) |v| {
            opts.baseline_path = v;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) return error.UnknownOption;

        try opts.paths.append(gpa, args[i]);
        i += 1;
    }

    if (opts.paths.items.len == 0) {
        return error.MissingInputPath;
    }

    return opts;
}

// ---------------------------------------------------------------------------
// 引数パース共通ヘルパー
// ---------------------------------------------------------------------------

/// `--key value` または `--key=value` 形式のオプションを消費して値を返す。
/// マッチしなければ null を返し、インデックスは変更しない。
/// `--key` がマッチしたが値がない場合は `error.MissingOptionValue` を返す。
fn consumeOption(args: []const []const u8, i: *usize, name: []const u8) !?[]const u8 {
    const arg = args[i.*];
    // --key=value 形式
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') {
        i.* += 1;
        return arg[(name.len + 1)..];
    }
    // --key value 形式
    if (std.mem.eql(u8, arg, name)) {
        const next_i = i.* + 1;
        if (next_i >= args.len) return error.MissingOptionValue;
        i.* = next_i + 1;
        return args[next_i];
    }
    return null;
}

/// `--help` / `-h` フラグを検出する。
fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
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

fn emitOutput(out_path: ?[]const u8, write_fn: anytype, args: anytype) !void {
    if (out_path) |path| {
        var file = try createOutputFile(path);
        defer file.close();

        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        const writer = &file_writer.interface;
        try @call(.auto, write_fn, .{writer} ++ args);
        try writer.writeAll("\n");
        try writer.flush();
        return;
    }

    var write_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&write_buffer);
    const writer = &stdout_writer.interface;
    try @call(.auto, write_fn, .{writer} ++ args);
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
        \\  apexgov interpret test <paths...>
        \\  apexgov typegen <sfdx-project-root> [--out DIR]
        \\  apexgov lsp
        \\
        \\Examples:
        \\  apexgov check force-app --format sarif --out reports/apexgov.sarif
        \\  apexgov profile artifacts/logs --config apexgov.toml --format json --out reports/profile.json
        \\  apexgov profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
        \\  apexgov interpret test force-app/main/default/classes
        \\  apexgov typegen my-sfdx-project --out .sfdx/typings/lwc
        \\  apexgov lsp                 Start the Language Server Protocol server (stdio)
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
