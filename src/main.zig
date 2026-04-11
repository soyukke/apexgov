//! main — CLI エントリポイント。
//!
//! `check`, `profile`, `emulate` サブコマンドのルーティングと引数パースを行う。

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
    best_effort: bool = false,
    register_standard_schema: bool = false,
};

const EmulateTranspileOptions = struct {
    out_dir: []const u8 = "reports/apex-transpile",
    package_name: []const u8 = "generated",
    overwrite: bool = false,
    strict: bool = false,
    input_paths: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *EmulateTranspileOptions, gpa: std.mem.Allocator) void {
        self.input_paths.deinit(gpa);
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
    if (std.mem.eql(u8, cmd, "emulate")) {
        return runEmulate(gpa, argv[2..]);
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

fn runEmulate(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "test")) {
        return runEmulateTest(gpa, args[1..]);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "transpile")) {
        return runEmulateTranspile(gpa, args[1..]);
    }

    return runEmulateCalibration(gpa, args);
}

fn runEmulateCalibration(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    const opts = try parseEmulateOptions(args);
    const script_path = try resolveToolScript(gpa, "tools/java-calibration/run.sh", error.JavaCalibrationScriptNotFound);
    defer gpa.free(script_path);

    const EnvEntry = struct { []const u8, u64 };
    var env_entries: [4]EnvEntry = undefined;
    var env_count: usize = 0;

    const optional_envs: []const struct { []const u8, ?u64 } = &.{
        .{ "ITERATIONS", opts.iterations },
        .{ "ANCHOR_SOQL_MS", opts.anchor_soql_ms },
        .{ "BASE_MS", opts.base_ms },
        .{ "MAX_WEIGHT_MS", opts.max_weight_ms },
    };
    for (optional_envs) |entry| {
        if (entry[1]) |value| {
            env_entries[env_count] = .{ entry[0], value };
            env_count += 1;
        }
    }

    const script_args: []const []const u8 = if (opts.out_dir) |d| &.{d} else &.{};

    return spawnScript(gpa, script_path, opts.use_nix, script_args, env_entries[0..env_count], &.{});
}

fn runEmulateTest(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    const opts = try parseEmulateTestOptions(args);
    const script_path = try resolveToolScript(gpa, "tools/java-emulation/run-tests.sh", error.JavaEmulationScriptNotFound);
    defer gpa.free(script_path);

    const EnvEntry = struct { []const u8, u64 };
    var env_entries: [2]EnvEntry = undefined;
    var env_count: usize = 0;

    if (opts.cpu_limit_ms) |v| {
        env_entries[env_count] = .{ "CPU_LIMIT_MS", v };
        env_count += 1;
    }
    if (opts.heap_limit_bytes) |v| {
        env_entries[env_count] = .{ "HEAP_LIMIT_BYTES", v };
        env_count += 1;
    }

    var extra_args_buf: [6][]const u8 = undefined;
    var extra_count: usize = 0;

    if (opts.tests_dir) |d| {
        extra_args_buf[extra_count] = "--tests-dir";
        extra_count += 1;
        extra_args_buf[extra_count] = d;
        extra_count += 1;
    }
    if (opts.out_dir) |d| {
        extra_args_buf[extra_count] = "--out-dir";
        extra_count += 1;
        extra_args_buf[extra_count] = d;
        extra_count += 1;
    }
    if (opts.best_effort) {
        extra_args_buf[extra_count] = "--best-effort";
        extra_count += 1;
    }

    const str_env: []const struct { []const u8, []const u8 } = if (opts.register_standard_schema)
        &.{.{ "REGISTER_STANDARD_SCHEMA", "true" }}
    else
        &.{};

    return spawnScript(gpa, script_path, opts.use_nix, extra_args_buf[0..extra_count], env_entries[0..env_count], str_env);
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

    // --- @salesforce/schema ---
    {
        buf.clearRetainingCapacity();
        var schema_count: u32 = 0;
        // objects/ ディレクトリを走査
        var objects_path_buf: [4096]u8 = undefined;
        const root_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
            std.debug.print("error: cannot open '{s}': {s}\n", .{ root, @errorName(err) });
            return 2;
        };

        // 再帰的に field-meta.xml を探す
        var walker = try root_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".field-meta.xml")) continue;

            // オブジェクト名をパスから抽出: objects/<ObjName>/fields/<field>.field-meta.xml
            const object_name = extractObjectName(entry.path) orelse continue;

            // ファイルを読む
            const field_xml = root_dir.readFileAlloc(gpa, entry.path, 64 * 1024) catch continue;
            defer gpa.free(field_xml);

            if (typegen.parseFieldMeta(field_xml, object_name)) |field| {
                try typegen.renderSchemaField(field, writer);
                try writer.writeByte('\n');
                schema_count += 1;
            }
        }

        if (schema_count > 0) {
            const out_path = std.fmt.bufPrint(&objects_path_buf, "{s}/schema.d.ts", .{out_dir}) catch unreachable;
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items });
            std.debug.print("  schema.d.ts: {d} fields\n", .{schema_count});
            total_files += 1;
        }
    }

    // --- @salesforce/label ---
    {
        buf.clearRetainingCapacity();
        var label_count: u32 = 0;
        const root_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return 2;
        var walker = try root_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".labels-meta.xml")) continue;

            const xml = root_dir.readFileAlloc(gpa, entry.path, 256 * 1024) catch continue;
            defer gpa.free(xml);

            const names = try typegen.parseLabelNames(xml, gpa);
            defer gpa.free(names);
            for (names) |name| {
                try typegen.renderLabel(name, writer);
                try writer.writeByte('\n');
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

    // --- @salesforce/resourceUrl ---
    {
        buf.clearRetainingCapacity();
        var res_count: u32 = 0;
        const root_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return 2;
        var walker = try root_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".resource-meta.xml")) continue;
            // リソース名: ファイル名から .resource-meta.xml を除去
            const name = entry.basename[0 .. entry.basename.len - ".resource-meta.xml".len];
            if (name.len == 0) continue;
            try typegen.renderResourceUrl(name, writer);
            try writer.writeByte('\n');
            res_count += 1;
        }

        if (res_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(&path_buf, "{s}/staticresources.d.ts", .{out_dir}) catch unreachable;
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items });
            std.debug.print("  staticresources.d.ts: {d} resources\n", .{res_count});
            total_files += 1;
        }
    }

    // --- @salesforce/messageChannel ---
    {
        buf.clearRetainingCapacity();
        var ch_count: u32 = 0;
        const root_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return 2;
        var walker = try root_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".messageChannel-meta.xml")) continue;
            const name = entry.basename[0 .. entry.basename.len - ".messageChannel-meta.xml".len];
            if (name.len == 0) continue;
            try typegen.renderMessageChannel(name, writer);
            try writer.writeByte('\n');
            ch_count += 1;
        }

        if (ch_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(&path_buf, "{s}/messagechannels.d.ts", .{out_dir}) catch unreachable;
            try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items });
            std.debug.print("  messagechannels.d.ts: {d} channels\n", .{ch_count});
            total_files += 1;
        }
    }

    // --- @salesforce/apex ---
    {
        buf.clearRetainingCapacity();
        var method_count: u32 = 0;
        const root_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return 2;
        var walker = try root_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".cls")) continue;
            // クラス名: .cls を除去
            const class_name = entry.basename[0 .. entry.basename.len - ".cls".len];
            if (class_name.len == 0) continue;

            const source = root_dir.readFileAlloc(gpa, entry.path, 1024 * 1024) catch continue;
            defer gpa.free(source);

            // @AuraEnabled がなければスキップ（高速パス）
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

fn runEmulateTranspile(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    var opts = try parseEmulateTranspileOptions(gpa, args);
    defer opts.deinit(gpa);

    const effective_out_dir = if (opts.strict)
        try std.fmt.allocPrint(gpa, "{s}.strict-staging", .{opts.out_dir})
    else
        try gpa.dupe(u8, opts.out_dir);
    defer gpa.free(effective_out_dir);

    if (opts.strict) {
        if (!opts.overwrite and pathExists(opts.out_dir)) return error.OutputAlreadyExists;
        try deleteTreeIfExists(effective_out_dir);
    }

    var summary = try apexgov.transpile.run(gpa, .{
        .input_paths = opts.input_paths.items,
        .out_dir = effective_out_dir,
        .package_name = opts.package_name,
        .overwrite = if (opts.strict) true else opts.overwrite,
        .strict = false,
    });
    defer summary.deinit(gpa);

    std.debug.print(
        "transpile: generated {d} Java file(s) from {d} Apex class file(s) into {s} (methods: {d}, unsupported: {d})\n",
        .{
            summary.files_generated,
            summary.files_scanned,
            opts.out_dir,
            summary.methods_generated,
            summary.unsupported_statements,
        },
    );

    if (summary.unsupported_examples.items.len > 0) {
        std.debug.print("unsupported details (first {d}):\n", .{summary.unsupported_examples.items.len});
        for (summary.unsupported_examples.items) |entry| {
            std.debug.print(
                "  - {s}:{d} [{s}] {s}: {s}\n",
                .{
                    entry.source_path,
                    entry.line_no,
                    entry.method_name,
                    entry.reason,
                    entry.statement,
                },
            );
        }
    }

    if (opts.strict and summary.unsupported_statements > 0) {
        try deleteTreeIfExists(effective_out_dir);
        std.debug.print("transpile: strict mode failed due to unsupported statements.\n", .{});
        return 1;
    }

    if (opts.strict) {
        if (opts.overwrite) {
            try deleteTreeIfExists(opts.out_dir);
        }
        try std.fs.cwd().rename(effective_out_dir, opts.out_dir);
    }
    return 0;
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

fn parseEmulateOptions(args: []const []const u8) !EmulateOptions {
    var opts = EmulateOptions{};
    var seen_runtime = false;

    var i: usize = 0;
    while (i < args.len) {
        if (isHelpFlag(args[i])) {
            printEmulateHelp();
            return error.HelpRequested;
        }
        if (consumeFlag(args, &i, "--nix")) {
            opts.use_nix = true;
            continue;
        }
        if (try consumeOption(args, &i, "--out")) |v| {
            opts.out_dir = v;
            continue;
        }
        if (try consumeOption(args, &i, "--iterations")) |v| {
            opts.iterations = try parseUnsignedOption(v);
            continue;
        }
        if (try consumeOption(args, &i, "--anchor-soql-ms")) |v| {
            opts.anchor_soql_ms = try parseUnsignedOption(v);
            continue;
        }
        if (try consumeOption(args, &i, "--base-ms")) |v| {
            opts.base_ms = try parseUnsignedOption(v);
            continue;
        }
        if (try consumeOption(args, &i, "--max-weight-ms")) |v| {
            opts.max_weight_ms = try parseUnsignedOption(v);
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) return error.UnknownOption;

        if (!seen_runtime and std.mem.eql(u8, args[i], "java")) {
            seen_runtime = true;
            i += 1;
            continue;
        }
        if (opts.out_dir != null) return error.TooManyInputPaths;

        opts.out_dir = args[i];
        i += 1;
    }

    return opts;
}

fn parseEmulateTestOptions(args: []const []const u8) !EmulateTestOptions {
    var opts = EmulateTestOptions{};

    var i: usize = 0;
    while (i < args.len) {
        if (isHelpFlag(args[i])) {
            printEmulateHelp();
            return error.HelpRequested;
        }
        if (consumeFlag(args, &i, "--nix")) {
            opts.use_nix = true;
            continue;
        }
        if (consumeFlag(args, &i, "--best-effort")) {
            opts.best_effort = true;
            continue;
        }
        if (consumeFlag(args, &i, "--register-standard-schema")) {
            opts.register_standard_schema = true;
            continue;
        }
        if (try consumeOption(args, &i, "--out")) |v| {
            opts.out_dir = v;
            continue;
        }
        if (try consumeOption(args, &i, "--cpu-limit-ms")) |v| {
            opts.cpu_limit_ms = try parseUnsignedOption(v);
            continue;
        }
        if (try consumeOption(args, &i, "--heap-limit-bytes")) |v| {
            opts.heap_limit_bytes = try parseUnsignedOption(v);
            continue;
        }
        if (try consumeOption(args, &i, "--tests-dir")) |v| {
            opts.tests_dir = v;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) return error.UnknownOption;

        if (opts.tests_dir != null) return error.TooManyInputPaths;
        opts.tests_dir = args[i];
        i += 1;
    }

    return opts;
}

fn parseEmulateTranspileOptions(gpa: std.mem.Allocator, args: []const []const u8) !EmulateTranspileOptions {
    var opts = EmulateTranspileOptions{};
    errdefer opts.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        if (isHelpFlag(args[i])) {
            printEmulateHelp();
            return error.HelpRequested;
        }
        if (consumeFlag(args, &i, "--overwrite")) {
            opts.overwrite = true;
            continue;
        }
        if (consumeFlag(args, &i, "--strict")) {
            opts.strict = true;
            continue;
        }
        if (try consumeOption(args, &i, "--out")) |v| {
            opts.out_dir = v;
            continue;
        }
        if (try consumeOption(args, &i, "--package")) |v| {
            opts.package_name = v;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) return error.UnknownOption;

        try opts.input_paths.append(gpa, args[i]);
        i += 1;
    }

    if (opts.input_paths.items.len == 0) {
        try opts.input_paths.append(gpa, defaultTranspileInputPath());
    }
    return opts;
}

fn defaultTranspileInputPath() []const u8 {
    const preferred = "force-app/main/default/classes";
    if (pathExists(preferred)) return preferred;

    const fixture = "examples/apex-validation/force-app/main/default/classes";
    if (pathExists(fixture)) return fixture;

    return preferred;
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

/// `--flag` 形式のブールフラグを消費する。マッチすればインデックスを進めて true を返す。
fn consumeFlag(args: []const []const u8, i: *usize, name: []const u8) bool {
    if (std.mem.eql(u8, args[i.*], name)) {
        i.* += 1;
        return true;
    }
    return false;
}

/// `--help` / `-h` フラグを検出する。
fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
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

/// シェルスクリプトを子プロセスとして実行する共通ヘルパー。
/// nix 対応、環境変数(u64)・環境変数(文字列)・スクリプト引数を受け取り、
/// 終了コードを返す。
fn spawnScript(
    gpa: std.mem.Allocator,
    script_path: []const u8,
    use_nix: bool,
    extra_args: []const []const u8,
    uint_env: []const struct { []const u8, u64 },
    str_env: []const struct { []const u8, []const u8 },
) !u8 {
    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    if (use_nix) {
        try ensureNixCacheEnv(gpa, &env_map);
    }

    for (uint_env) |entry| {
        try setUnsignedEnv(gpa, &env_map, entry[0], entry[1]);
    }
    for (str_env) |entry| {
        try env_map.put(entry[0], entry[1]);
    }

    var child_args: std.ArrayList([]const u8) = .empty;
    defer child_args.deinit(gpa);

    if (use_nix) {
        try child_args.append(gpa, "nix");
        try child_args.append(gpa, "develop");
        try child_args.append(gpa, "-c");
    }
    try child_args.append(gpa, "/bin/bash");
    try child_args.append(gpa, script_path);
    try child_args.appendSlice(gpa, extra_args);

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

fn deleteTreeIfExists(path: []const u8) !void {
    if (!pathExists(path)) return;
    try std.fs.cwd().deleteTree(path);
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
        \\  apexgov emulate [java] [OUT_DIR] [--iterations N] [--anchor-soql-ms N] [--base-ms N] [--max-weight-ms N] [--nix]
        \\  apexgov emulate test [TESTS_DIR] [--out DIR] [--cpu-limit-ms N] [--heap-limit-bytes N] [--best-effort] [--nix]
        \\  apexgov emulate transpile [APEX_PATHS...] [--out DIR] [--package NAME] [--overwrite] [--strict]
        \\  apexgov typegen <sfdx-project-root> [--out DIR]
        \\
        \\Examples:
        \\  apexgov check force-app --format sarif --out reports/apexgov.sarif
        \\  apexgov profile artifacts/logs --config apexgov.toml --format json --out reports/profile.json
        \\  apexgov profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
        \\  apexgov emulate java reports/java-calibration-local --iterations 80000 --nix
        \\  apexgov emulate test tools/java-emulation/examples --out reports/java-emulation --best-effort --nix
        \\  apexgov emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated
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

fn printEmulateHelp() void {
    std.debug.print(
        \\apexgov emulate
        \\  Mode 1: CPU calibration
        \\    apexgov emulate [java] [OUT_DIR] [--iterations N] [--anchor-soql-ms N] [--base-ms N] [--max-weight-ms N] [--nix]
        \\  Mode 2: local @Test emulation
        \\    apexgov emulate test [TESTS_DIR] [--out DIR] [--cpu-limit-ms N] [--heap-limit-bytes N] [--best-effort] [--nix]
        \\  Mode 3: Apex -> Java test scaffold transpile (best-effort)
        \\    apexgov emulate transpile [APEX_PATHS...] [--out DIR] [--package NAME] [--overwrite] [--strict]
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
        "--best-effort",
        "--nix",
    };

    const opts = try parseEmulateTestOptions(args[0..]);
    try std.testing.expect(opts.tests_dir != null);
    try std.testing.expectEqualStrings("tools/java-emulation/examples", opts.tests_dir.?);
    try std.testing.expect(opts.out_dir != null);
    try std.testing.expectEqualStrings("reports/java-emulation-local", opts.out_dir.?);
    try std.testing.expectEqual(@as(?u64, 8500), opts.cpu_limit_ms);
    try std.testing.expectEqual(@as(?u64, 5500000), opts.heap_limit_bytes);
    try std.testing.expectEqual(true, opts.best_effort);
    try std.testing.expectEqual(true, opts.use_nix);
}

test "parseEmulateTestOptions rejects extra positional paths" {
    const args = [_][]const u8{ "tests-a", "tests-b" };
    try std.testing.expectError(error.TooManyInputPaths, parseEmulateTestOptions(args[0..]));
}

test "parseEmulateTranspileOptions parses flags and defaults" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "force-app/main/default/classes",
        "--out=reports/apex-transpile-local",
        "--package",
        "generated.demo",
        "--overwrite",
        "--strict",
    };

    var opts = try parseEmulateTranspileOptions(gpa, args[0..]);
    defer opts.deinit(gpa);

    try std.testing.expectEqualStrings("reports/apex-transpile-local", opts.out_dir);
    try std.testing.expectEqualStrings("generated.demo", opts.package_name);
    try std.testing.expectEqual(true, opts.overwrite);
    try std.testing.expectEqual(true, opts.strict);
    try std.testing.expectEqual(@as(usize, 1), opts.input_paths.items.len);
    try std.testing.expectEqualStrings("force-app/main/default/classes", opts.input_paths.items[0]);
}

test "parseEmulateTranspileOptions injects default input path" {
    const gpa = std.testing.allocator;
    var opts = try parseEmulateTranspileOptions(gpa, &.{});
    defer opts.deinit(gpa);

    try std.testing.expectEqual(false, opts.strict);
    try std.testing.expectEqual(@as(usize, 1), opts.input_paths.items.len);
    try std.testing.expectEqualStrings(defaultTranspileInputPath(), opts.input_paths.items[0]);
}

test "run emulate transpile forwards strict mode to transpiler" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class UnsupportedStrictDemo {
        \\  public static void run() {
        \\    when Account acc {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "UnsupportedStrictDemo.cls", .data = source });

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "strict-out" });
    defer gpa.free(out_dir);

    const argv = [_][]const u8{
        "apexgov",
        "emulate",
        "transpile",
        root,
        "--out",
        out_dir,
        "--strict",
        "--overwrite",
    };
    try std.testing.expectEqual(@as(u8, 1), try run(gpa, argv[0..]));
    try std.testing.expect(!pathExists(out_dir));
}
