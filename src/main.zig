//! main — CLI エントリポイント。
//!
//! `check`, `profile` サブコマンドのルーティングと引数パースを行う。

const std = @import("std");
const Io = std.Io;
const apexgov = @import("apexgov");

/// stderr にフォーマット文字列を一度で書き出すヘルパ。
/// lint (tools/check_style.zig の debug_print ルール) で `std.debug` 直出力が
/// 検出されるため、CLI のエラー/使用法出力にはこちらを使う。
fn print_stderr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var state = Io.File.stderr().writer(io, &buf);
    const w = &state.interface;
    w.print(fmt, args) catch return;
    w.flush() catch return;
}

/// stdout に書き出すヘルパ。typegen の情報ログで使う。
fn print_stdout(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var state = Io.File.stdout().writer(io, &buf);
    const w = &state.interface;
    w.print(fmt, args) catch return;
    w.flush() catch return;
}

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

const InterpretTestOptions = struct {
    filter_class: ?[]const u8 = null,
    filter_method: ?[]const u8 = null,
    summary_only: bool = false,
    shard: ?apexgov.interpret.TestShard = null,
    paths: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *InterpretTestOptions, gpa: std.mem.Allocator) void {
        self.paths.deinit(gpa);
    }
};

fn parse_interpret_test_shard(raw: []const u8) !apexgov.interpret.TestShard {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.InvalidShard;
    const index = try std.fmt.parseInt(usize, raw[0..slash], 10);
    const count = try std.fmt.parseInt(usize, raw[slash + 1 ..], 10);
    if (count == 0 or index >= count) return error.InvalidShard;
    return .{ .index = index, .count = count };
}

const SummaryOnlyTestWriter = struct {
    inner: *Io.Writer,

    pub fn print(self: *SummaryOnlyTestWriter, comptime fmt: []const u8, args: anytype) !void {
        if (std.mem.startsWith(u8, fmt, "[PASS] ")) return;
        try self.inner.print(fmt, args);
    }
};

pub fn main(init: std.process.Init) void {
    // 再帰が深い Apex コードの解釈実行に備え、スタックサイズを拡大した
    // ワーカースレッドで実行する（macOS メインスレッドのデフォルトは 8 MB）。
    const thread = std.Thread.spawn(
        .{ .stack_size = 64 * 1024 * 1024 },
        main_worker,
        .{init},
    ) catch {
        std.process.exit(2);
    };
    thread.join();
}

fn main_worker(init: std.process.Init) void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // `Init.Minimal.args` は [:0]const u8 のスライスだが、以降の関数は
    // []const u8 スライスを前提としているので一度詰め直す。
    const argv_raw = init.minimal.args.toSlice(arena) catch std.process.exit(2);
    const argv = arena.alloc([]const u8, argv_raw.len) catch std.process.exit(2);
    for (argv_raw, 0..) |a, i| argv[i] = a;

    const exit_code = run(gpa, io, argv) catch |err| {
        if (err == error.HelpRequested) return;
        print_stderr(io, "error: {s}\n\n", .{@errorName(err)});
        print_usage(io);
        std.process.exit(2);
    };

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

fn run(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) !u8 {
    if (argv.len < 2) {
        print_usage(io);
        return 0;
    }

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        print_usage(io);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "check")) {
        return run_check(gpa, io, argv[2..]);
    }
    if (std.mem.eql(u8, cmd, "profile")) {
        return run_profile(gpa, io, argv[2..]);
    }
    if (std.mem.eql(u8, cmd, "interpret")) {
        return run_interpret(gpa, io, argv[2..]);
    }
    if (std.mem.eql(u8, cmd, "lsp")) {
        return run_lsp(gpa, io);
    }
    if (std.mem.eql(u8, cmd, "typegen")) {
        return run_typegen(gpa, io, argv[2..]);
    }

    return error.UnknownCommand;
}

fn run_check(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    var opts = try parse_check_options(gpa, io, args);
    defer opts.deinit(gpa);

    var cfg = try apexgov.config.load(gpa, io, opts.config_path);
    cfg.include_tests = opts.include_tests;

    var findings = try apexgov.check.run_with_config(gpa, io, opts.paths.items, cfg);
    defer apexgov.model.deinit_findings(gpa, &findings);

    try emit_output(
        io,
        opts.out_path,
        apexgov.report.write_check,
        .{ opts.format, findings.items },
    );

    if (opts.threshold) |threshold| {
        const fail_count = count_findings_at_or_above(findings.items, threshold);
        if (fail_count > 0) return 1;
    }

    return 0;
}

fn run_profile(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    var opts = try parse_profile_options(gpa, io, args);
    defer opts.deinit(gpa);

    const cfg = try apexgov.config.load(gpa, io, opts.config_path);

    var profiles = try apexgov.profile.run(gpa, io, opts.paths.items, cfg);
    defer apexgov.model.deinit_profiles(gpa, &profiles);

    var regressions = try apexgov.profile.compare_with_baseline(
        gpa,
        io,
        profiles.items,
        opts.baseline_path,
        cfg.ci.regression_percent,
    );
    defer apexgov.profile.deinit_regressions(gpa, &regressions);

    try emit_output(
        io,
        opts.out_path,
        apexgov.report.write_profile,
        .{ opts.format, profiles.items },
    );

    var has_violation = false;
    for (profiles.items) |profile| {
        if (profile.any_exceeded()) {
            has_violation = true;
            break;
        }
    }

    if (regressions.items.len > 0) {
        print_regressions(io, regressions.items, cfg.ci.regression_percent);
    }

    const fail_for_regression = cfg.ci.fail_on_regression and regressions.items.len > 0;
    return if (has_violation or fail_for_regression) 1 else 0;
}

fn run_lsp(gpa: std.mem.Allocator, io: Io) !u8 {
    try apexgov.lsp.serve(gpa, io);
    return 0;
}

fn run_typegen(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    var project_root: ?[]const u8 = null;
    var out_dir: []const u8 = ".sfdx/typings/lwc";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            print_stderr(io,
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
        print_stderr(io, "error: project root path is required\n", .{});
        return 2;
    };

    const typegen = apexgov.typegen;

    // 出力ディレクトリを作成
    Io.Dir.cwd().createDirPath(io, out_dir) catch |err| {
        print_stderr(
            io,
            "error: cannot create output directory '{s}': {s}\n",
            .{ out_dir, @errorName(err) },
        );
        return 2;
    };

    var total_files: u32 = 0;
    var allocating = Io.Writer.Allocating.init(gpa);
    defer allocating.deinit();

    const writer = &allocating.writer;

    // ファイルパスをソート済みで収集する（出力を決定的にするため）
    var root_dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        print_stderr(io, "error: cannot open '{s}': {s}\n", .{ root, @errorName(err) });
        return 2;
    };
    defer root_dir.close(io);

    var all_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (all_paths.items) |p| gpa.free(p);
        all_paths.deinit(gpa);
    }

    {
        var walker = try root_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            try all_paths.append(gpa, try gpa.dupe(u8, entry.path));
        }
    }
    std.mem.sort([]const u8, all_paths.items, {}, struct {
        fn less_than(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less_than);

    // --- @salesforce/schema ---
    {
        allocating.clearRetainingCapacity();
        var schema_count: u32 = 0;
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            if (!std.mem.endsWith(u8, basename, ".field-meta.xml")) continue;

            const object_name = extract_object_name(entry_path) orelse continue;
            const field_xml = root_dir.readFileAlloc(
                io,
                entry_path,
                gpa,
                .limited(64 * 1024),
            ) catch continue;
            defer gpa.free(field_xml);

            if (typegen.parse_field_meta(field_xml, object_name)) |field| {
                try typegen.render_schema_field(field, writer);
                try writer.writeByte('\n');
                schema_count += 1;
            }
        }

        if (schema_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(
                &path_buf,
                "{s}/schema.d.ts",
                .{out_dir},
            ) catch unreachable;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = allocating.written() });
            print_stdout(io, "  schema.d.ts: {d} fields\n", .{schema_count});
            total_files += 1;
        }
    }

    // --- @salesforce/label ---
    {
        allocating.clearRetainingCapacity();
        var label_count: u32 = 0;
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            if (!std.mem.endsWith(u8, basename, ".labels-meta.xml")) continue;

            const xml = root_dir.readFileAlloc(
                io,
                entry_path,
                gpa,
                .limited(4 * 1024 * 1024),
            ) catch continue;
            defer gpa.free(xml);

            const names = try typegen.parse_label_names(xml, gpa);
            defer gpa.free(names);

            for (names) |name| {
                if (label_count > 0) try writer.writeByte('\n');
                try typegen.render_label(name, writer);
                label_count += 1;
            }
        }

        if (label_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(
                &path_buf,
                "{s}/customlabels.d.ts",
                .{out_dir},
            ) catch unreachable;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = allocating.written() });
            print_stdout(io, "  customlabels.d.ts: {d} labels\n", .{label_count});
            total_files += 1;
        }
    }

    // --- @salesforce/resourceUrl, messageChannel, contentAssetUrl ---
    // 公式と同じ: 1 リソースにつき 1 ファイル（{name}.{type}.d.ts）
    {
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            const meta = parse_meta_filename(basename) orelse continue;

            allocating.clearRetainingCapacity();
            if (std.mem.eql(u8, meta.meta_type, "resource")) {
                try typegen.render_resource_url(meta.name, writer);
            } else if (std.mem.eql(u8, meta.meta_type, "messageChannel")) {
                try typegen.render_message_channel(meta.name, writer);
            } else if (std.mem.eql(u8, meta.meta_type, "asset")) {
                try typegen.render_content_asset_url(meta.name, writer);
            } else continue;

            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(
                &path_buf,
                "{s}/{s}.{s}.d.ts",
                .{ out_dir, meta.name, meta.meta_type },
            ) catch continue;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = allocating.written() });
            total_files += 1;
        }
    }

    // --- @salesforce/apex ---
    {
        allocating.clearRetainingCapacity();
        var method_count: u32 = 0;
        for (all_paths.items) |entry_path| {
            const basename = std.fs.path.basename(entry_path);
            if (!std.mem.endsWith(u8, basename, ".cls")) continue;
            const class_name = basename[0 .. basename.len - ".cls".len];
            if (class_name.len == 0) continue;

            const source = root_dir.readFileAlloc(
                io,
                entry_path,
                gpa,
                .limited(1024 * 1024),
            ) catch continue;
            defer gpa.free(source);

            if (std.ascii.indexOfIgnoreCase(source, "@AuraEnabled") == null) continue;

            const methods = try typegen.find_aura_enabled_methods(source, class_name, gpa);
            defer gpa.free(methods);

            for (methods) |method| {
                try typegen.render_apex_method(method, writer);
                try writer.writeByte('\n');
                method_count += 1;
            }
        }

        if (method_count > 0) {
            var path_buf: [4096]u8 = undefined;
            const out_path = std.fmt.bufPrint(
                &path_buf,
                "{s}/apex.d.ts",
                .{out_dir},
            ) catch unreachable;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = allocating.written() });
            print_stdout(io, "  apex.d.ts: {d} @AuraEnabled methods\n", .{method_count});
            total_files += 1;
        }
    }

    print_stdout(
        io,
        "typegen: generated {d} type definition file(s) in {s}\n",
        .{ total_files, out_dir },
    );
    return 0;
}

/// メタファイル名をパースする。
/// 例: "leafletjs.resource-meta.xml" → { .name = "leafletjs", .meta_type = "resource" }
fn parse_meta_filename(basename: []const u8) ?struct { name: []const u8, meta_type: []const u8 } {
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
fn extract_object_name(path: []const u8) ?[]const u8 {
    // "/fields/" の直前のディレクトリ名がオブジェクト名
    const fields_marker = "/fields/";
    const fields_pos = std.mem.indexOf(u8, path, fields_marker) orelse return null;
    const before = path[0..fields_pos];
    // 最後の "/" の直後がオブジェクト名
    const last_sep = std.mem.lastIndexOfScalar(u8, before, '/') orelse return null;
    return before[last_sep + 1 ..];
}

fn run_interpret(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "test")) {
        return run_interpret_test(gpa, io, args[1..]);
    }
    // Default: interpret test
    return run_interpret_test(gpa, io, args);
}

fn run_interpret_test(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    var opts = InterpretTestOptions{};
    defer opts.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        if (is_help_flag(args[i])) {
            print_stderr(io,
                \\apexgov interpret test
                \\  Run Apex test classes using the Zig native interpreter.
                \\  Usage: apexgov interpret test [--class CLASS] [--method METHOD] [--summary-only] [--shard I/N] <paths...>
                \\
            , .{});
            return 0;
        }
        if (try consume_option(args, &i, "--class")) |v| {
            opts.filter_class = v;
            continue;
        }
        if (try consume_option(args, &i, "--method")) |v| {
            opts.filter_method = v;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--summary-only")) {
            opts.summary_only = true;
            i += 1;
            continue;
        }
        if (try consume_option(args, &i, "--shard")) |v| {
            opts.shard = try parse_interpret_test_shard(v);
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) return error.UnknownOption;
        try opts.paths.append(gpa, args[i]);
        i += 1;
    }

    if (opts.filter_method != null and opts.filter_class == null) return error.MissingTestClass;

    if (opts.paths.items.len == 0) {
        try opts.paths.append(gpa, "force-app");
    }

    var write_buffer: [8192]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &write_buffer);
    const writer = &stderr_writer.interface;

    var suite = if (opts.summary_only) blk: {
        var summary_writer = SummaryOnlyTestWriter{ .inner = writer };
        break :blk if (opts.filter_class) |class_name|
            try apexgov.interpret.run_single_test(
                gpa,
                io,
                opts.paths.items,
                class_name,
                opts.filter_method,
                &summary_writer,
            )
        else if (opts.shard) |shard|
            try apexgov.interpret.run_test_suite_sharded(
                gpa,
                io,
                opts.paths.items,
                shard,
                &summary_writer,
            )
        else
            try apexgov.interpret.run_test_suite(gpa, io, opts.paths.items, &summary_writer);
    } else if (opts.filter_class) |class_name|
        try apexgov.interpret.run_single_test(
            gpa,
            io,
            opts.paths.items,
            class_name,
            opts.filter_method,
            writer,
        )
    else if (opts.shard) |shard|
        try apexgov.interpret.run_test_suite_sharded(
            gpa,
            io,
            opts.paths.items,
            shard,
            writer,
        )
    else
        try apexgov.interpret.run_test_suite(gpa, io, opts.paths.items, writer);
    defer suite.deinit();

    try writer.flush();

    return if (suite.total > 0 and suite.passed == suite.total) 0 else 1;
}

fn parse_check_options(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !CheckOptions {
    var opts = CheckOptions{};
    errdefer opts.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        if (is_help_flag(args[i])) {
            print_check_help(io);
            return error.HelpRequested;
        }
        if (try consume_option(args, &i, "--config")) |v| {
            opts.config_path = v;
            continue;
        }
        if (try consume_option(args, &i, "--format")) |v| {
            opts.format = apexgov.model.OutputFormat.from_string(v) orelse
                return error.InvalidFormat;
            continue;
        }
        if (try consume_option(args, &i, "--out")) |v| {
            opts.out_path = v;
            continue;
        }
        if (try consume_option(args, &i, "--severity-threshold")) |v| {
            opts.threshold = try parse_threshold(v);
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

fn parse_profile_options(gpa: std.mem.Allocator, io: Io, args: []const []const u8) !ProfileOptions {
    var opts = ProfileOptions{};
    errdefer opts.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) {
        if (is_help_flag(args[i])) {
            print_profile_help(io);
            return error.HelpRequested;
        }
        if (try consume_option(args, &i, "--config")) |v| {
            opts.config_path = v;
            continue;
        }
        if (try consume_option(args, &i, "--format")) |v| {
            opts.format = apexgov.model.OutputFormat.from_string(v) orelse
                return error.InvalidFormat;
            continue;
        }
        if (try consume_option(args, &i, "--out")) |v| {
            opts.out_path = v;
            continue;
        }
        if (try consume_option(args, &i, "--baseline")) |v| {
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
fn consume_option(args: []const []const u8, i: *usize, name: []const u8) !?[]const u8 {
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
fn is_help_flag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn parse_threshold(value: []const u8) !?apexgov.model.Severity {
    if (std.ascii.eqlIgnoreCase(value, "none")) return null;
    return apexgov.model.Severity.from_string(value) orelse error.InvalidSeverity;
}

fn count_findings_at_or_above(
    findings: []const apexgov.model.Finding,
    threshold: apexgov.model.Severity,
) usize {
    var count: usize = 0;
    for (findings) |finding| {
        if (finding.severity.rank() >= threshold.rank()) count += 1;
    }
    return count;
}

fn emit_output(io: Io, out_path: ?[]const u8, write_fn: anytype, args: anytype) !void {
    if (out_path) |path| {
        var file = try create_output_file(io, path);
        defer file.close(io);

        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(io, &write_buffer);
        const writer = &file_writer.interface;
        try @call(.auto, write_fn, .{writer} ++ args);
        try writer.writeAll("\n");
        try writer.flush();
        return;
    }

    var write_buffer: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &write_buffer);
    const writer = &stdout_writer.interface;
    try @call(.auto, write_fn, .{writer} ++ args);
    try writer.writeAll("\n");
    try writer.flush();
}

fn print_usage(io: Io) void {
    print_stderr(io,
        \\apexgov: offline Apex CPU/Heap checker and profiler
        \\
        \\Usage:
        \\  apexgov check [paths...] [--config FILE] [--format text|json|sarif]
        \\                [--out FILE] [--severity-threshold info|warning|error|none]
        \\  apexgov profile <log_paths...> [--config FILE] [--baseline FILE]
        \\                                 [--format text|json|sarif] [--out FILE]
        \\  apexgov interpret test [--class CLASS] [--method METHOD] <paths...>
        \\  apexgov typegen <sfdx-project-root> [--out DIR]
        \\  apexgov lsp
        \\
        \\Examples:
        \\  apexgov check force-app --format sarif --out reports/apexgov.sarif
        \\  apexgov profile artifacts/logs --config apexgov.toml
        \\          --format json --out reports/profile.json
        \\  apexgov profile artifacts/logs
        \\          --baseline reports/profile-baseline.json --config apexgov.toml
        \\  apexgov interpret test force-app/main/default/classes
        \\  apexgov interpret test --class MyTest --method testCase force-app
        \\  apexgov typegen my-sfdx-project --out .sfdx/typings/lwc
        \\  apexgov lsp                 Start the Language Server Protocol server (stdio)
        \\
    , .{});
}

fn print_check_help(io: Io) void {
    print_stderr(io,
        \\apexgov check
        \\  Static scan for CPU/Heap and governor anti-patterns.
        \\  Default path is `force-app` when omitted.
        \\
    , .{});
}

fn print_profile_help(io: Io) void {
    print_stderr(io,
        \\apexgov profile
        \\  Parse Apex debug logs and compare CPU/Heap usage against budgets.
        \\  Accepts log files or directories containing .log files.
        \\  Optional: --baseline profile.json for regression checks.
        \\
    , .{});
}

fn create_output_file(io: Io, path: []const u8) !Io.File {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            try Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    return Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
}

fn print_regressions(
    io: Io,
    regressions: []const apexgov.profile.Regression,
    threshold_percent: u8,
) void {
    print_stderr(
        io,
        "regression: {d} transaction(s) exceeded baseline by >{d}%\n",
        .{ regressions.len, threshold_percent },
    );
    for (regressions) |regression| {
        print_stderr(
            io,
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
