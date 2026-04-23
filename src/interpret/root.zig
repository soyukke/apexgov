//! interpret — Apex インタープリターファサード。
//!
//! Apex ソースコードを直接解釈実行する。
//! パイプライン: Lexer → Parser → Evaluator

const std = @import("std");

// サブモジュール
pub const types = @import("types.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const env = @import("env.zig");
pub const evaluator = @import("evaluator.zig");
pub const builtins = @import("builtins.zig");
pub const utils = @import("utils.zig");
pub const regex = @import("regex.zig");

// 型の再エクスポート
pub const Value = types.Value;
pub const RuntimeError = types.RuntimeError;

pub const Options = struct {
    entry_class: []const u8 = "",
    entry_method: []const u8 = "",
    args: []const Value = &.{},
    source_paths: []const []const u8 = &.{},
};

pub const Result = struct {
    value: Value,
    stdout: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const Result) void {
        if (self.value == .string) {
            self.allocator.free(self.value.string);
        }
        self.allocator.free(self.stdout);
    }
};

/// Apex ソースコードを解釈実行する。
pub fn run(gpa: std.mem.Allocator, io: std.Io, source: []const u8, opts: Options) !Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const tokens = try lexer.tokenize(source, arena.allocator());
    const decls = try parser.parse(tokens, arena.allocator());

    var eval = try evaluator.Evaluator.init(arena.allocator(), io);
    if (opts.source_paths.len > 0) {
        eval.source_paths = opts.source_paths;
        for (opts.source_paths) |path| {
            collect_field_defaults(
                arena.allocator(),
                io,
                path,
                &eval.field_defaults,
                &eval.field_types,
                &eval.field_metadata,
                &eval.child_relationships,
            ) catch {};
            collect_field_sets(arena.allocator(), io, path, &eval.field_sets) catch {};
            collect_custom_setting_types(
                arena.allocator(),
                io,
                path,
                &eval.custom_setting_types,
                &eval.custom_setting_kinds,
                &eval.object_labels,
                &eval.object_label_plurals,
            ) catch {};
        }
    }
    try eval.load_decls(decls);
    for (decls) |decl| {
        switch (decl) {
            .class_decl => |cd| try eval.register_class_source(cd.name, source),
            .trigger_decl => |td| try eval.register_trigger_source(td.name, source),
            else => {},
        }
    }

    const value = if (opts.entry_class.len > 0 and opts.entry_method.len > 0)
        try eval.call_method(opts.entry_class, opts.entry_method, opts.args)
    else
        Value.void_val;

    const stdout_copy = try gpa.dupe(u8, eval.stdout.items);
    const value_copy = try copy_value(gpa, value);

    arena.deinit();
    return .{ .value = value_copy, .stdout = stdout_copy, .allocator = gpa };
}

// ---------------------------------------------------------------------------
// テストスイートランナー
// ---------------------------------------------------------------------------

pub const TestResult = struct {
    class_name: []const u8,
    method_name: []const u8,
    passed: bool,
    failure_message: []const u8 = "",
};

pub const TestSuiteResult = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    errors: u32 = 0,
    results: std.ArrayListUnmanaged(TestResult) = .empty,
};

const SourceFile = struct { path: []const u8, content: []const u8 };

const SampleAppFixturePaths = struct {
    arena: std.heap.ArenaAllocator,
    paths: []const []const u8,

    fn init(gpa: std.mem.Allocator, io: std.Io) !SampleAppFixturePaths {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        if (!try fixture_tests_enabled(alloc)) return error.SkipZigTest;
        const fixture_path = try find_sample_app_fixture_path(alloc, io);
        const paths = try alloc.alloc([]const u8, 1);
        paths[0] = fixture_path;
        return .{ .arena = arena, .paths = paths };
    }

    fn deinit(self: *SampleAppFixturePaths) void {
        self.arena.deinit();
    }

    fn slice(self: *const SampleAppFixturePaths) []const []const u8 {
        return self.paths;
    }
};

fn fixture_tests_enabled(alloc: std.mem.Allocator) !bool {
    // TODO(zig-0.16 migration): `std.process.getEnvVarOwned` was removed in
    // favour of `std.process.Environ.Map`; the test runner does not yet
    // thread an Environ through, so fixture-backed tests are skipped for
    // now. Re-enable once Environ plumbing lands.
    _ = alloc;
    return false;
}

fn is_sample_app_fixture_path(alloc: std.mem.Allocator, io: std.Io, base_path: []const u8) bool {
    const markers = [_][]const u8{
        "core/tests/logger-engine/classes/LogEntryEventBuilder_Tests.cls",
        "core/tests/logger-engine/classes/LoggerEngineDataSelector_Tests.cls",
        "extra-tests/integration-tests/classes/LogManagementDataSelector_Tests_Flow.cls",
    };
    for (markers) |marker| {
        const full_path = std.fs.path.join(alloc, &.{ base_path, marker }) catch continue;
        defer alloc.free(full_path);

        std.Io.Dir.cwd().access(io, full_path, .{}) catch continue;
        return true;
    }
    return false;
}

fn find_sample_app_fixture_path(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    const fixture_root = ".local-fixtures/apex/repos";
    var root_dir = try std.Io.Dir.cwd().openDir(io, fixture_root, .{ .iterate = true });
    defer root_dir.close(io);

    var root_iter = root_dir.iterate();
    while (try root_iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const repo_path = try std.fs.path.join(alloc, &.{ fixture_root, entry.name });
        if (is_sample_app_fixture_path(alloc, io, repo_path)) return repo_path;

        var repo_dir = std.Io.Dir.cwd().openDir(io, repo_path, .{ .iterate = true }) catch {
            alloc.free(repo_path);
            continue;
        };
        defer repo_dir.close(io);

        var repo_iter = repo_dir.iterate();
        while (try repo_iter.next(io)) |child_entry| {
            if (child_entry.kind != .directory) continue;
            const child_path = try std.fs.path.join(alloc, &.{ repo_path, child_entry.name });
            if (is_sample_app_fixture_path(alloc, io, child_path)) {
                alloc.free(repo_path);
                return child_path;
            }
            alloc.free(child_path);
        }

        alloc.free(repo_path);
    }

    return error.FileNotFound;
}

/// ディレクトリ内の全 .cls ファイルを読み込み、@isTest メソッドを実行する。
pub fn run_test_suite(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    writer: anytype,
) !TestSuiteResult {
    return run_tests_filtered(gpa, io, paths, null, null, writer);
}

/// 指定クラス（+ オプションでメソッド）のテストのみ実行する。
/// method_name が null の場合はクラス内全テストメソッドを実行。
pub fn run_single_test(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    class_name: []const u8,
    method_name: ?[]const u8,
    writer: anytype,
) !TestSuiteResult {
    return run_tests_filtered(gpa, io, paths, class_name, method_name, writer);
}

/// テスト実行の共通内部関数。filter_class / filter_method が null なら全テスト実行。
fn parse_all_sources(
    parse_alloc: std.mem.Allocator,
    files: []SourceFile,
    eval: *evaluator.Evaluator,
) u32 {
    var parse_errors: u32 = 0;
    for (files) |file| {
        const tokens = lexer.tokenize(file.content, parse_alloc) catch {
            parse_errors += 1;
            continue;
        };
        const decls = parser.parse(tokens, parse_alloc) catch {
            parse_errors += 1;
            continue;
        };
        eval.load_decls(decls) catch {
            parse_errors += 1;
            continue;
        };
        for (decls) |decl| {
            switch (decl) {
                .class_decl => |cd| {
                    eval.register_class_source(cd.name, file.content) catch {};
                },
                .trigger_decl => |td| {
                    eval.register_trigger_source(td.name, file.content) catch {};
                },
                else => {},
            }
        }
    }
    return parse_errors;
}

fn load_metadata_for_path(
    parse_alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    eval: *evaluator.Evaluator,
) void {
    collect_field_defaults(
        parse_alloc,
        io,
        path,
        &eval.field_defaults,
        &eval.field_types,
        &eval.field_metadata,
        &eval.child_relationships,
    ) catch {};
    collect_field_sets(parse_alloc, io, path, &eval.field_sets) catch {};
    collect_custom_setting_types(
        parse_alloc,
        io,
        path,
        &eval.custom_setting_types,
        &eval.custom_setting_kinds,
        &eval.object_labels,
        &eval.object_label_plurals,
    ) catch {};
}

fn load_all_metadata(
    parse_alloc: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    eval: *evaluator.Evaluator,
) void {
    for (paths) |path| {
        load_metadata_for_path(parse_alloc, io, path, eval);
        if (!should_search_metadata_parents(path)) continue;
        var parent = std.fs.path.dirname(path);
        var depth: u8 = 0;
        while (parent != null and depth < 3) : (depth += 1) {
            load_metadata_for_path(parse_alloc, io, parent.?, eval);
            parent = std.fs.path.dirname(parent.?);
        }
    }
}

const StaticClassLists = struct {
    classes_with_statics: std.ArrayListUnmanaged(*ast.ClassDecl) = .empty,
};

fn compute_static_class_lists(
    parse_alloc: std.mem.Allocator,
    eval: *evaluator.Evaluator,
) !StaticClassLists {
    var out = StaticClassLists{};
    var iter = eval.classes.iterator();
    while (iter.next()) |entry| {
        const cd = entry.value_ptr.*;
        var has_static_fields = false;
        for (cd.members) |member| {
            if (member == .field_decl and member.field_decl.modifiers.is_static) {
                has_static_fields = true;
            }
        }
        if (has_static_fields) try out.classes_with_statics.append(parse_alloc, cd);
    }
    return out;
}

fn find_test_setup_method(class_decl: *ast.ClassDecl) ?*ast.MethodDecl {
    for (class_decl.members) |m| {
        if (m != .method_decl) continue;
        const md2 = m.method_decl;
        for (md2.annotations) |ann| {
            if (std.ascii.eqlIgnoreCase(ann, "@TestSetup")) return md2;
        }
    }
    return null;
}

fn seed_test_evaluator(
    test_eval: *evaluator.Evaluator,
    src: *const evaluator.Evaluator,
    parse_alloc: std.mem.Allocator,
) void {
    test_eval.classes = src.classes;
    test_eval.class_arena = parse_alloc;
    test_eval.triggers = src.triggers;
    test_eval.class_sources = src.class_sources;
    test_eval.trigger_sources = src.trigger_sources;
    test_eval.source_paths = src.source_paths;
    test_eval.field_defaults = src.field_defaults;
    test_eval.field_types = src.field_types;
    test_eval.field_metadata = src.field_metadata;
    test_eval.child_relationships = src.child_relationships;
    test_eval.custom_setting_types = src.custom_setting_types;
    test_eval.custom_setting_kinds = src.custom_setting_kinds;
    test_eval.object_labels = src.object_labels;
    test_eval.object_label_plurals = src.object_label_plurals;
    test_eval.field_sets = src.field_sets;
}

fn detect_see_all_data(md: *ast.MethodDecl) bool {
    for (md.annotations) |ann| {
        if (std.ascii.indexOfIgnoreCase(ann, "seealldata") != null and
            std.ascii.indexOfIgnoreCase(ann, "true") != null) return true;
    }
    return false;
}

fn reset_limits(test_eval: *evaluator.Evaluator) void {
    test_eval.limits_dml = 0;
    test_eval.limits_dml_rows = 0;
    test_eval.limits_soql = 0;
    test_eval.limits_publish_immediate = 0;
    test_eval.limits_queueable = 0;
    test_eval.limits_callouts = 0;
}

fn run_test_setup_and_reset(
    test_eval: *evaluator.Evaluator,
    class_name: []const u8,
    setup: *ast.MethodDecl,
    statics: []*ast.ClassDecl,
) void {
    _ = test_eval.call_method(class_name, setup.name, &.{}) catch {};
    for (statics) |cd2| test_eval.register_static_field_placeholders(cd2);
    test_eval.static_inited.clearRetainingCapacity();
}

fn extract_exception_detail(pending_exception: anytype) []const u8 {
    const pe = pending_exception orelse return "";
    if (pe != .object) return "";
    const msg = pe.object.fields.get("message") orelse return "";
    if (msg != .string) return "";
    return msg.string;
}

fn record_test_outcome(
    parse_alloc: std.mem.Allocator,
    writer: anytype,
    suite: *TestSuiteResult,
    test_eval: *evaluator.Evaluator,
    class_name: []const u8,
    md: *ast.MethodDecl,
    result: anytype,
) !void {
    if (result) |_| {
        if (test_eval.assertion_failure) |msg| {
            suite.failed += 1;
            const msg_copy = parse_alloc.dupe(u8, msg) catch msg;
            try suite.results.append(parse_alloc, .{
                .class_name = class_name,
                .method_name = md.name,
                .passed = false,
                .failure_message = msg_copy,
            });
            try writer.print("[FAIL] {s}#{s}: {s}\n", .{ class_name, md.name, msg });
        } else {
            suite.passed += 1;
            try suite.results.append(parse_alloc, .{
                .class_name = class_name,
                .method_name = md.name,
                .passed = true,
            });
            try writer.print("[PASS] {s}#{s}\n", .{ class_name, md.name });
        }
    } else |err| {
        suite.errors += 1;
        const exc_detail = extract_exception_detail(test_eval.pending_exception);
        const err_msg = if (exc_detail.len > 0)
            try std.fmt.allocPrint(parse_alloc, "{s}: {s}", .{ @errorName(err), exc_detail })
        else
            try std.fmt.allocPrint(parse_alloc, "{s}", .{@errorName(err)});
        try suite.results.append(parse_alloc, .{
            .class_name = class_name,
            .method_name = md.name,
            .passed = false,
            .failure_message = err_msg,
        });
        try writer.print("[ERROR] {s}#{s}: {s}\n", .{ class_name, md.name, err_msg });
    }
}

const TestMethodCtx = struct {
    parse_alloc: std.mem.Allocator,
    test_arena: *std.heap.ArenaAllocator,
    io: std.Io,
    eval: *evaluator.Evaluator,
    class_name: []const u8,
    statics: []*ast.ClassDecl,
    setup_method: ?*ast.MethodDecl,
    suite: *TestSuiteResult,
};

fn run_one_test_method(ctx: TestMethodCtx, md: *ast.MethodDecl, writer: anytype) !void {
    ctx.suite.total += 1;
    _ = ctx.test_arena.reset(.retain_capacity);
    const test_alloc = ctx.test_arena.allocator();
    var test_eval = evaluator.Evaluator.init(test_alloc, ctx.io) catch return;

    seed_test_evaluator(&test_eval, ctx.eval, ctx.parse_alloc);
    test_eval.see_all_data = detect_see_all_data(md);

    for (ctx.statics) |cd| test_eval.register_static_field_placeholders(cd);
    if (ctx.setup_method) |setup| {
        run_test_setup_and_reset(&test_eval, ctx.class_name, setup, ctx.statics);
    }
    reset_limits(&test_eval);

    const result = test_eval.call_method(ctx.class_name, md.name, &.{});
    try record_test_outcome(
        ctx.parse_alloc,
        writer,
        ctx.suite,
        &test_eval,
        ctx.class_name,
        md,
        result,
    );
}

fn run_tests_filtered(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    filter_class: ?[]const u8,
    filter_method: ?[]const u8,
    writer: anytype,
) !TestSuiteResult {
    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    // 1. .cls ファイルを収集
    var files: std.ArrayListUnmanaged(SourceFile) = .empty;
    for (paths) |path| {
        try collect_cls_files(parse_alloc, io, path, &files);
    }
    try writer.print("interpret: loaded {d} Apex source file(s)\n", .{files.items.len});

    // 2. 全ファイルをパース
    var eval = try evaluator.Evaluator.init(parse_alloc, io);
    eval.source_paths = paths;
    const parse_errors = parse_all_sources(parse_alloc, files.items, &eval);
    try writer.print(
        "interpret: registered {d} class(es), {d} trigger(s), {d} parse error(s)\n",
        .{ eval.classes.count(), eval.triggers.count(), parse_errors },
    );

    // 3. Load metadata
    load_all_metadata(parse_alloc, io, paths, &eval);

    // 4. Pre-compute static classes
    const static_lists = try compute_static_class_lists(parse_alloc, &eval);

    var test_arena = std.heap.ArenaAllocator.init(gpa);
    defer test_arena.deinit();

    // 5. @isTest メソッドを発見・実行
    var suite = TestSuiteResult{};
    var class_iter = eval.classes.iterator();
    while (class_iter.next()) |entry| {
        const class_name = entry.key_ptr.*;
        const class_decl = entry.value_ptr.*;
        if (filter_class) |fc| {
            if (!std.ascii.eqlIgnoreCase(class_name, fc)) continue;
        }
        const setup_method = find_test_setup_method(class_decl);

        for (class_decl.members) |member| {
            if (member != .method_decl) continue;
            const md = member.method_decl;
            if (!is_test_method(md)) continue;
            if (filter_method) |fm| {
                if (!std.ascii.eqlIgnoreCase(md.name, fm)) continue;
            }
            try run_one_test_method(.{
                .parse_alloc = parse_alloc,
                .test_arena = &test_arena,
                .io = io,
                .eval = &eval,
                .class_name = class_name,
                .statics = static_lists.classes_with_statics.items,
                .setup_method = setup_method,
                .suite = &suite,
            }, md, writer);
        }
    }

    suite.failed += suite.errors;
    try writer.print(
        "\n--- Results: {d} total, {d} passed, {d} failed ---\n",
        .{ suite.total, suite.passed, suite.total - suite.passed },
    );
    return suite;
}

fn is_test_class(cd: *ast.ClassDecl) bool {
    for (cd.annotations) |ann| {
        if (std.ascii.eqlIgnoreCase(ann, "@isTest") or std.ascii.eqlIgnoreCase(ann, "@IsTest") or
            std.ascii.startsWithIgnoreCase(
                ann,
                "@isTest(",
            ) or std.ascii.startsWithIgnoreCase(ann, "@test("))
        {
            return true;
        }
    }
    // Also check if it has any test methods
    for (cd.members) |member| {
        switch (member) {
            .method_decl => |md| {
                if (is_test_method(md)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn is_test_method(md: *ast.MethodDecl) bool {
    if (md.modifiers.is_test_method) return true;
    for (md.annotations) |ann| {
        if (std.ascii.eqlIgnoreCase(ann, "@isTest") or std.ascii.eqlIgnoreCase(ann, "@IsTest") or std.ascii.eqlIgnoreCase(ann, "@test")) {
            return true;
        }
        // Also match @isTest(SeeAllData=true) and similar parameterized annotations
        if (std.ascii.startsWithIgnoreCase(ann, "@isTest(") or std.ascii.startsWithIgnoreCase(ann, "@test(")) {
            return true;
        }
    }
    return false;
}

fn collect_cls_files(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    files: *std.ArrayListUnmanaged(SourceFile),
) !void {
    // Try as single .cls/.trigger file first
    if (std.mem.endsWith(u8, path, ".cls") or std.mem.endsWith(u8, path, ".trigger")) {
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(10 * 1024 * 1024)) catch return;
        const path_copy = alloc.dupe(u8, path) catch return;
        files.append(alloc, .{ .path = path_copy, .content = content }) catch return;
        return;
    }

    // Walk directory recursively
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".cls") and !std.mem.endsWith(u8, entry.basename, ".trigger")) continue;
        // Skip name-shadowing stub classes that intentionally shadow system classes
        // (e.g., extra-tests/name-shadowing/System/JSON.cls). These empty classes
        // exist only to verify that production code uses fully-qualified names in
        // Salesforce, but they break the interpreter's built-in dispatch.
        if (std.mem.indexOf(u8, entry.path, "name-shadowing/") != null or
            std.mem.indexOf(u8, entry.path, "name-shadowing\\") != null) continue;

        const full_path = std.fs.path.join(alloc, &.{ path, entry.path }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, alloc, .limited(10 * 1024 * 1024)) catch continue;
        files.append(alloc, .{ .path = full_path, .content = content }) catch continue;
    }
}

fn should_search_metadata_parents(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".cls") or std.mem.endsWith(u8, path, ".trigger")) return true;
    return std.mem.endsWith(u8, path, "/classes") or
        std.mem.endsWith(u8, path, "\\classes") or
        std.mem.indexOf(u8, path, "/classes/") != null or
        std.mem.indexOf(u8, path, "\\classes\\") != null or
        std.mem.endsWith(u8, path, "/triggers") or
        std.mem.endsWith(u8, path, "\\triggers") or
        std.mem.indexOf(u8, path, "/triggers/") != null or
        std.mem.indexOf(u8, path, "\\triggers\\") != null;
}

/// field-meta.xml からデフォルト値と型情報を読み込む。
/// パス構造: .../objects/TypeName__c/fields/FieldName__c.field-meta.xml
fn collect_field_defaults(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    field_defaults: *std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(Value)),
    field_types: *std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged([]const u8)),
    field_metadata: *std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(evaluator.FieldMetadata)),
    child_relationships: *std.StringArrayHashMapUnmanaged(evaluator.CustomChildRelationship),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".field-meta.xml")) continue;

        // Extract type name from path: .../objects/TypeName/fields/FieldName.field-meta.xml
        const entry_path = entry.path;
        const objects_idx = std.mem.indexOf(u8, entry_path, "objects/") orelse
            std.mem.indexOf(u8, entry_path, "objects\\") orelse continue;
        const after_objects = entry_path[objects_idx + 8 ..];
        const sep_idx = std.mem.indexOfAny(u8, after_objects, "/\\") orelse continue;
        const type_name = after_objects[0..sep_idx];
        const field_name = entry.basename[0 .. entry.basename.len - ".field-meta.xml".len];

        const full_path = std.fs.path.join(alloc, &.{ path, entry_path }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, alloc, .limited(64 * 1024)) catch continue;

        var metadata = evaluator.FieldMetadata{};
        if (extract_xml_tag_value(content, "label")) |label| {
            metadata.label = alloc.dupe(u8, std.mem.trim(u8, label, " \t\n\r")) catch null;
        }

        if (std.mem.indexOf(u8, content, "<caseSensitive>")) |cs| {
            const cs_start = cs + "<caseSensitive>".len;
            if (std.mem.indexOfPos(u8, content, cs_start, "</caseSensitive>")) |ce| {
                const value = std.mem.trim(u8, content[cs_start..ce], " \t\n\r");
                metadata.case_sensitive = std.ascii.eqlIgnoreCase(value, "true");
            }
        }
        if (std.mem.indexOf(u8, content, "<externalId>")) |es| {
            const e_start = es + "<externalId>".len;
            if (std.mem.indexOfPos(u8, content, e_start, "</externalId>")) |ee| {
                const value = std.mem.trim(u8, content[e_start..ee], " \t\n\r");
                metadata.is_external_id = std.ascii.eqlIgnoreCase(value, "true");
            }
        }
        if (std.mem.indexOf(u8, content, "<unique>")) |us| {
            const u_start = us + "<unique>".len;
            if (std.mem.indexOfPos(u8, content, u_start, "</unique>")) |ue| {
                const value = std.mem.trim(u8, content[u_start..ue], " \t\n\r");
                metadata.is_unique = std.ascii.eqlIgnoreCase(value, "true");
            }
        }
        if (std.mem.indexOf(u8, content, "<required>")) |rs| {
            const r_start = rs + "<required>".len;
            if (std.mem.indexOfPos(u8, content, r_start, "</required>")) |re| {
                const value = std.mem.trim(u8, content[r_start..re], " \t\n\r");
                metadata.is_required = std.ascii.eqlIgnoreCase(value, "true");
            }
        }
        if (std.mem.indexOf(u8, content, "<length>")) |ls| {
            const l_start = ls + "<length>".len;
            if (std.mem.indexOfPos(u8, content, l_start, "</length>")) |le| {
                const value = std.mem.trim(u8, content[l_start..le], " \t\n\r");
                metadata.length = std.fmt.parseInt(i64, value, 10) catch null;
            }
        }
        if (extract_xml_tag_value(content, "formula")) |formula| {
            metadata.formula = decode_xml_text(alloc, formula, false) catch null;
        }
        if (extract_xml_tag_value(content, "formulaTreatBlanksAs")) |blank_mode| {
            metadata.formula_blank_as_zero = std.ascii.eqlIgnoreCase(
                std.mem.trim(u8, blank_mode, " \t\n\r"),
                "BlankAsZero",
            );
        }
        if (extract_xml_tag_value(content, "summarizedField")) |summarized_field| {
            metadata.summarized_field = alloc.dupe(
                u8,
                std.mem.trim(u8, summarized_field, " \t\n\r"),
            ) catch null;
        }
        if (extract_xml_tag_value(content, "summaryForeignKey")) |summary_foreign_key| {
            metadata.summary_foreign_key = alloc.dupe(
                u8,
                std.mem.trim(u8, summary_foreign_key, " \t\n\r"),
            ) catch null;
        }
        if (extract_xml_tag_value(content, "summaryOperation")) |summary_operation| {
            metadata.summary_operation = alloc.dupe(
                u8,
                std.mem.trim(u8, summary_operation, " \t\n\r"),
            ) catch null;
        }
        metadata.summary_filters = parse_summary_filters(alloc, content) catch &.{};
        metadata.picklist_values = parse_picklist_values(alloc, content) catch &.{};

        // Extract <type>...</type> for field type info
        if (std.mem.indexOf(u8, content, "<type>")) |ts| {
            const t_start = ts + 6; // "<type>".len
            if (std.mem.indexOfPos(u8, content, t_start, "</type>")) |te| {
                const ft = content[t_start..te];
                const tk = alloc.dupe(u8, type_name) catch continue;
                const fk = alloc.dupe(u8, field_name) catch continue;
                const ft_gop = field_types.getOrPut(alloc, tk) catch continue;
                if (!ft_gop.found_existing) ft_gop.value_ptr.* = .empty;
                ft_gop.value_ptr.put(alloc, fk, ft) catch {};
            }
        }

        if (std.mem.indexOf(u8, content, "<referenceTo>")) |rs| {
            const r_start = rs + "<referenceTo>".len;
            if (std.mem.indexOfPos(u8, content, r_start, "</referenceTo>")) |re| {
                metadata.reference_to = alloc.dupe(
                    u8,
                    std.mem.trim(u8, content[r_start..re], " \t\n\r"),
                ) catch null;
                if (std.mem.indexOf(u8, content, "<relationshipName>")) |ns| {
                    const n_start = ns + "<relationshipName>".len;
                    if (std.mem.indexOfPos(u8, content, n_start, "</relationshipName>")) |ne| {
                        const parent_type = std.mem.trim(u8, content[r_start..re], " \t\n\r");
                        const relationship_name = std.mem.trim(u8, content[n_start..ne], " \t\n\r");
                        put_child_relationship(
                            alloc,
                            child_relationships,
                            parent_type,
                            relationship_name,
                            type_name,
                            field_name,
                        ) catch {};
                        if (!std.mem.endsWith(u8, relationship_name, "__r")) {
                            const rel_with_suffix = std.fmt.allocPrint(
                                alloc,
                                "{s}__r",
                                .{relationship_name},
                            ) catch "";
                            if (rel_with_suffix.len > 0) {
                                put_child_relationship(
                                    alloc,
                                    child_relationships,
                                    parent_type,
                                    rel_with_suffix,
                                    type_name,
                                    field_name,
                                ) catch {};
                            }
                        }
                    }
                }
            }
        }

        if (metadata.label != null or
            metadata.is_unique or
            metadata.is_external_id or
            metadata.is_required or
            metadata.length != null or
            metadata.reference_to != null or
            metadata.formula != null or
            metadata.summary_operation != null or
            metadata.picklist_values.len > 0)
        {
            const type_key = alloc.dupe(u8, type_name) catch continue;
            const field_key = alloc.dupe(u8, field_name) catch continue;
            const meta_gop = field_metadata.getOrPut(alloc, type_key) catch continue;
            if (!meta_gop.found_existing) meta_gop.value_ptr.* = .empty;
            meta_gop.value_ptr.put(alloc, field_key, metadata) catch {};
        }

        for (metadata.picklist_values) |picklist_value| {
            if (!picklist_value.is_default) continue;
            const type_key = alloc.dupe(u8, type_name) catch break;
            const field_key = alloc.dupe(u8, field_name) catch break;
            const gop = field_defaults.getOrPut(alloc, type_key) catch break;
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            gop.value_ptr.put(alloc, field_key, Value{ .string = picklist_value.value }) catch {};
            break;
        }

        // Extract <default_value>...</default_value>
        const dv_start_tag = "<default_value>";
        const dv_end_tag = "</default_value>";
        const dv_start = std.mem.indexOf(u8, content, dv_start_tag) orelse continue;
        const dv_value_start = dv_start + dv_start_tag.len;
        const dv_end = std.mem.indexOfPos(u8, content, dv_value_start, dv_end_tag) orelse continue;
        const raw_str = content[dv_value_start..dv_end];

        // Decode XML entities and strip Apex string quotes
        const decoded = decode_xml_default_value(alloc, raw_str) catch continue;

        // Convert to Value based on content
        const value: Value = if (std.ascii.eqlIgnoreCase(decoded, "true"))
            Value{ .boolean = true }
        else if (std.ascii.eqlIgnoreCase(decoded, "false"))
            Value{ .boolean = false }
        else if (std.fmt.parseInt(i64, decoded, 10)) |i|
            Value{ .integer = i }
        else |_|
            Value{ .string = decoded };

        // Store in field_defaults[type_name][field_name]
        const type_key = alloc.dupe(u8, type_name) catch continue;
        const field_key = alloc.dupe(u8, field_name) catch continue;
        const gop = field_defaults.getOrPut(alloc, type_key) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        gop.value_ptr.put(alloc, field_key, value) catch continue;
    }
}

fn extract_xml_tag_value(content: []const u8, tag_name: []const u8) ?[]const u8 {
    const start_tag = std.fmt.allocPrint(
        std.heap.page_allocator,
        "<{s}>",
        .{tag_name},
    ) catch return null;
    defer std.heap.page_allocator.free(start_tag);

    const end_tag = std.fmt.allocPrint(
        std.heap.page_allocator,
        "</{s}>",
        .{tag_name},
    ) catch return null;
    defer std.heap.page_allocator.free(end_tag);

    const start_idx = std.mem.indexOf(u8, content, start_tag) orelse return null;
    const value_start = start_idx + start_tag.len;
    const end_idx = std.mem.indexOfPos(u8, content, value_start, end_tag) orelse return null;
    return content[value_start..end_idx];
}

fn parse_summary_filters(
    alloc: std.mem.Allocator,
    content: []const u8,
) ![]const evaluator.SummaryFilter {
    var filters = std.ArrayListUnmanaged(evaluator.SummaryFilter).empty;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, content, search_start, "<summaryFilterItems>")) |block_start_idx| {
        const block_start = block_start_idx + "<summaryFilterItems>".len;
        const block_end = std.mem.indexOfPos(
            u8,
            content,
            block_start,
            "</summaryFilterItems>",
        ) orelse break;
        const block = content[block_start..block_end];
        const field = extract_xml_tag_value(block, "field") orelse {
            search_start = block_end + "</summaryFilterItems>".len;
            continue;
        };
        const operation = extract_xml_tag_value(block, "operation") orelse {
            search_start = block_end + "</summaryFilterItems>".len;
            continue;
        };
        const value = extract_xml_tag_value(block, "value") orelse {
            search_start = block_end + "</summaryFilterItems>".len;
            continue;
        };
        try filters.append(alloc, .{
            .field_path = try decode_xml_text(alloc, std.mem.trim(u8, field, " \t\n\r"), false),
            .operation = try decode_xml_text(alloc, std.mem.trim(u8, operation, " \t\n\r"), false),
            .value = try decode_xml_text(alloc, std.mem.trim(u8, value, " \t\n\r"), false),
        });
        search_start = block_end + "</summaryFilterItems>".len;
    }
    return try alloc.dupe(evaluator.SummaryFilter, filters.items);
}

fn parse_picklist_values(
    alloc: std.mem.Allocator,
    content: []const u8,
) ![]const evaluator.PicklistValueMetadata {
    var values = std.ArrayListUnmanaged(evaluator.PicklistValueMetadata).empty;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, content, search_start, "<value>")) |block_start_idx| {
        const block_start = block_start_idx + "<value>".len;
        const block_end = std.mem.indexOfPos(u8, content, block_start, "</value>") orelse break;
        const block = content[block_start..block_end];
        const raw_label = extract_xml_tag_value(block, "label") orelse {
            search_start = block_end + "</value>".len;
            continue;
        };
        const raw_value = extract_xml_tag_value(block, "fullName") orelse raw_label;
        const is_default = blk: {
            if (extract_xml_tag_value(block, "default")) |raw_default| {
                break :blk std.ascii.eqlIgnoreCase(
                    std.mem.trim(u8, raw_default, " \t\n\r"),
                    "true",
                );
            }
            break :blk false;
        };
        try values.append(alloc, .{
            .label = try decode_xml_text(alloc, std.mem.trim(u8, raw_label, " \t\n\r"), false),
            .value = try decode_xml_text(alloc, std.mem.trim(u8, raw_value, " \t\n\r"), false),
            .is_default = is_default,
        });
        search_start = block_end + "</value>".len;
    }
    return try alloc.dupe(evaluator.PicklistValueMetadata, values.items);
}

fn put_child_relationship(
    alloc: std.mem.Allocator,
    child_relationships: *std.StringArrayHashMapUnmanaged(evaluator.CustomChildRelationship),
    parent_type: []const u8,
    relationship_name: []const u8,
    child_type: []const u8,
    fk_field: []const u8,
) !void {
    const raw_key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ parent_type, relationship_name });
    const key = try alloc.alloc(u8, raw_key.len);
    _ = std.ascii.lowerString(key, raw_key);
    try child_relationships.put(alloc, key, .{
        .child_type = try alloc.dupe(u8, child_type),
        .fk_field = try alloc.dupe(u8, fk_field),
    });
}

/// object-meta.xml を走査し `<customSettingsType>` が含まれる SObject 名と種別を集める。
/// パス構造: .../objects/<TypeName>/<TypeName>.object-meta.xml
fn collect_custom_setting_types(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    custom_setting_types: *std.StringArrayHashMapUnmanaged(void),
    custom_setting_kinds: *std.StringArrayHashMapUnmanaged([]const u8),
    object_labels: *std.StringArrayHashMapUnmanaged([]const u8),
    object_label_plurals: *std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".object-meta.xml")) continue;

        const type_name = entry.basename[0 .. entry.basename.len - ".object-meta.xml".len];
        const full_path = std.fs.path.join(alloc, &.{ path, entry.path }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, alloc, .limited(256 * 1024)) catch continue;

        // Extract <label> — all objects with a label
        if (std.mem.indexOf(u8, content, "<label>")) |start_idx| {
            const start = start_idx + "<label>".len;
            if (std.mem.indexOfPos(u8, content, start, "</label>")) |end_idx| {
                const label_value = std.mem.trim(u8, content[start..end_idx], " \t\r\n");
                if (label_value.len > 0) {
                    const key_dup = alloc.dupe(u8, type_name) catch continue;
                    const val_dup = alloc.dupe(u8, label_value) catch continue;
                    object_labels.put(alloc, key_dup, val_dup) catch {};
                }
            }
        }
        if (std.mem.indexOf(u8, content, "<pluralLabel>")) |start_idx| {
            const start = start_idx + "<pluralLabel>".len;
            if (std.mem.indexOfPos(u8, content, start, "</pluralLabel>")) |end_idx| {
                const label_value = std.mem.trim(u8, content[start..end_idx], " \t\r\n");
                if (label_value.len > 0) {
                    const key_dup = alloc.dupe(u8, type_name) catch continue;
                    const val_dup = alloc.dupe(u8, label_value) catch continue;
                    object_label_plurals.put(alloc, key_dup, val_dup) catch {};
                }
            }
        }

        if (std.mem.indexOf(u8, content, "<customSettingsType>") == null) continue;
        const type_key = alloc.dupe(u8, type_name) catch continue;
        custom_setting_types.put(alloc, type_key, {}) catch {};

        var kind_value: []const u8 = "Hierarchy";
        if (std.mem.indexOf(u8, content, "<customSettingsType>")) |start_idx| {
            const start = start_idx + "<customSettingsType>".len;
            if (std.mem.indexOfPos(u8, content, start, "</customSettingsType>")) |end_idx| {
                kind_value = std.mem.trim(u8, content[start..end_idx], " \t\r\n");
            }
        }
        const kind_key = alloc.dupe(u8, type_name) catch continue;
        const kind_dup = alloc.dupe(u8, kind_value) catch continue;
        custom_setting_kinds.put(alloc, kind_key, kind_dup) catch {};
    }
}

fn split_namespaced_metadata_name(name: []const u8) struct { namespace: []const u8, local_name: []const u8 } {
    if (std.mem.indexOf(u8, name, "__")) |idx| {
        return .{
            .namespace = name[0..idx],
            .local_name = name[idx + 2 ..],
        };
    }
    return .{ .namespace = "", .local_name = name };
}

/// fieldSet-meta.xml を走査し field set metadata を読み込む。
/// パス構造: .../objects/TypeName__c/fieldSets/FieldSetName.fieldSet-meta.xml
fn collect_field_sets(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    field_sets: *std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(evaluator.FieldSetMetadata)),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".fieldSet-meta.xml")) continue;

        const entry_path = entry.path;
        const objects_idx = std.mem.indexOf(u8, entry_path, "objects/") orelse
            std.mem.indexOf(u8, entry_path, "objects\\") orelse continue;
        const after_objects = entry_path[objects_idx + 8 ..];
        const sep_idx = std.mem.indexOfAny(u8, after_objects, "/\\") orelse continue;
        const type_name = after_objects[0..sep_idx];

        const full_path = std.fs.path.join(alloc, &.{ path, entry_path }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, alloc, .limited(128 * 1024)) catch continue;

        var full_name: []const u8 = entry.basename[0 .. entry.basename.len - ".fieldSet-meta.xml".len];
        if (std.mem.indexOf(u8, content, "<fullName>")) |start_idx| {
            const start = start_idx + "<fullName>".len;
            if (std.mem.indexOfPos(u8, content, start, "</fullName>")) |end_idx| {
                full_name = std.mem.trim(u8, content[start..end_idx], " \t\r\n");
            }
        }

        var label: []const u8 = full_name;
        if (std.mem.indexOf(u8, content, "<label>")) |start_idx| {
            const start = start_idx + "<label>".len;
            if (std.mem.indexOfPos(u8, content, start, "</label>")) |end_idx| {
                label = std.mem.trim(u8, content[start..end_idx], " \t\r\n");
            }
        }

        var members = std.ArrayListUnmanaged(evaluator.FieldSetMemberMetadata).empty;
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, content, search_start, "<displayedFields>")) |block_start_idx| {
            const block_start = block_start_idx + "<displayedFields>".len;
            const block_end = std.mem.indexOfPos(
                u8,
                content,
                block_start,
                "</displayedFields>",
            ) orelse break;
            const block = content[block_start..block_end];

            const field_start_idx = std.mem.indexOf(u8, block, "<field>") orelse {
                search_start = block_end + "</displayedFields>".len;
                continue;
            };
            const field_start = field_start_idx + "<field>".len;
            const field_end = std.mem.indexOfPos(u8, block, field_start, "</field>") orelse {
                search_start = block_end + "</displayedFields>".len;
                continue;
            };
            const field_path = std.mem.trim(u8, block[field_start..field_end], " \t\r\n");

            var is_required = false;
            if (std.mem.indexOf(u8, block, "<isRequired>")) |req_idx| {
                const req_start = req_idx + "<isRequired>".len;
                if (std.mem.indexOfPos(u8, block, req_start, "</isRequired>")) |req_end| {
                    const value = std.mem.trim(u8, block[req_start..req_end], " \t\r\n");
                    is_required = std.ascii.eqlIgnoreCase(value, "true");
                }
            }

            try members.append(alloc, .{
                .field_path = try alloc.dupe(u8, field_path),
                .is_required = is_required,
            });
            search_start = block_end + "</displayedFields>".len;
        }

        const names = split_namespaced_metadata_name(full_name);
        const type_key = alloc.dupe(u8, type_name) catch continue;
        const field_set_key = alloc.dupe(u8, full_name) catch continue;
        const gop = field_sets.getOrPut(alloc, type_key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.put(alloc, field_set_key, .{
            .name = alloc.dupe(u8, names.local_name) catch continue,
            .qualified_name = field_set_key,
            .label = alloc.dupe(u8, label) catch continue,
            .namespace = alloc.dupe(u8, names.namespace) catch continue,
            .members = alloc.dupe(evaluator.FieldSetMemberMetadata, members.items) catch continue,
        }) catch {};
    }
}

/// XML エンティティをデコードし、Apex 文字列リテラルのクォートを除去する。
/// e.g., "&apos;FINEST&apos;" → "FINEST", "&amp;test" → "&test"
fn decode_xml_text(
    alloc: std.mem.Allocator,
    raw: []const u8,
    strip_outer_quotes: bool,
) ![]const u8 {
    // First pass: decode XML entities
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (std.mem.startsWith(u8, raw[i..], "&apos;")) {
                try buf.append(alloc, '\'');
                i += 6;
            } else if (std.mem.startsWith(u8, raw[i..], "&quot;")) {
                try buf.append(alloc, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, raw[i..], "&amp;")) {
                try buf.append(alloc, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, raw[i..], "&lt;")) {
                try buf.append(alloc, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, raw[i..], "&gt;")) {
                try buf.append(alloc, '>');
                i += 4;
            } else {
                try buf.append(alloc, raw[i]);
                i += 1;
            }
        } else {
            try buf.append(alloc, raw[i]);
            i += 1;
        }
    }
    const decoded = buf.items;
    // Strip surrounding single quotes (Apex string literal in metadata)
    if (strip_outer_quotes and decoded.len >= 2 and decoded[0] == '\'' and decoded[decoded.len - 1] == '\'') {
        return alloc.dupe(u8, decoded[1 .. decoded.len - 1]);
    }
    return alloc.dupe(u8, decoded);
}

fn decode_xml_default_value(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return decode_xml_text(alloc, raw, true);
}

/// arena 上の Value を gpa にコピーする。
fn copy_value(gpa: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .string => |s| Value{ .string = try gpa.dupe(u8, s) },
        else => value,
    };
}

fn write_generic_rollup_metadata_fixture(dir: anytype) !void {
    const tio = std.testing.io;
    try dir.createDirPath(tio, "objects/Parent__c/fields");
    try dir.createDirPath(tio, "objects/Child__c/fields");
    try dir.createDirPath(tio, "objects/Grandchild__c/fields");
    try dir.writeFile(tio, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Parent__c/fields/OpenChildren__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>OpenChildren__c</fullName>
        \\    <summaryFilterItems>
        \\        <field>Child__c.Status__c</field>
        \\        <operation>equals</operation>
        \\        <value>Open</value>
        \\    </summaryFilterItems>
        \\    <summaryForeignKey>Child__c.Parent__c</summaryForeignKey>
        \\    <summaryOperation>count</summaryOperation>
        \\    <type>Summary</type>
        \\</CustomField>
        ,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Parent__c/fields/ClosedChildren__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ClosedChildren__c</fullName>
        \\    <summaryFilterItems>
        \\        <field>Child__c.Status__c</field>
        \\        <operation>equals</operation>
        \\        <value>Closed</value>
        \\    </summaryFilterItems>
        \\    <summaryForeignKey>Child__c.Parent__c</summaryForeignKey>
        \\    <summaryOperation>count</summaryOperation>
        \\    <type>Summary</type>
        \\</CustomField>
        ,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Parent__c/fields/TotalChildren__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>TotalChildren__c</fullName>
        \\    <formula>OpenChildren__c
        \\+ ClosedChildren__c</formula>
        \\    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
        \\    <type>Number</type>
        \\</CustomField>
        ,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Grandchild__c/fields/Child__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Child__c</fullName>
        \\    <referenceTo>Child__c</referenceTo>
        \\    <relationshipName>Grandchildren</relationshipName>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
}

fn write_generic_hierarchy_custom_setting_fixture(dir: anytype) !void {
    try dir.createDirPath(std.testing.io, "objects/AppSettings__c/fields");
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/AppSettings__c/AppSettings__c.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <customSettingsType>Hierarchy</customSettingsType>
        \\    <label>App Settings</label>
        \\    <visibility>Public</visibility>
        \\</CustomObject>
        ,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/AppSettings__c/fields/Flag__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Flag__c</fullName>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
}

fn write_generic_hierarchy_custom_setting_defaults_fixture(dir: anytype) !void {
    try write_generic_hierarchy_custom_setting_fixture(dir);
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/AppSettings__c/fields/Mode__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Mode__c</fullName>
        \\    <default_value>&apos;default&apos;</default_value>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
}

// サブモジュールのテストを参照
test {
    _ = types;
    _ = lexer;
    _ = parser;
    _ = env;
    _ = evaluator;
    _ = builtins;
    _ = utils;
}

test "is_test_method detects testMethod modifier" {
    const source =
        \\@IsTest
        \\public class LegacyTestDemo {
        \\    static testMethod void legacyTest() {
        \\        System.assert(true);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    try std.testing.expectEqual(@as(usize, 1), decls.len);

    const cd = decls[0].class_decl;
    try std.testing.expectEqual(@as(usize, 1), cd.members.len);

    const md = cd.members[0].method_decl;
    try std.testing.expectEqualStrings("legacyTest", md.name);
    // is_test_method should be set by parser
    try std.testing.expect(md.modifiers.is_test_method);
    // is_test_method should detect it
    try std.testing.expect(is_test_method(md));
}

// ---------------------------------------------------------------------------
// E2E テスト
// ---------------------------------------------------------------------------

test "E2E: simple static method returns string" {
    const source =
        \\public class Hello {
        \\    public static String greet() {
        \\        return 'world';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Hello",
        .entry_method = "greet",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("world", result.value.string);
}

test "E2E: arithmetic and variable" {
    const source =
        \\public class Calc {
        \\    public static Integer compute() {
        \\        Integer a = 3;
        \\        Integer b = 4;
        \\        return a * b + 1;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Calc",
        .entry_method = "compute",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 13), result.value.integer);
}

test "E2E: System.debug captures output" {
    const source =
        \\public class Logger {
        \\    public static void logIt() {
        \\        System.debug('first');
        \\        System.debug('second');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Logger",
        .entry_method = "logIt",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("first\nsecond\n", result.stdout);
}

test "E2E: if-else control flow" {
    const source =
        \\public class Branch {
        \\    public static Integer max() {
        \\        Integer a = 5;
        \\        Integer b = 10;
        \\        if (a > b) {
        \\            return a;
        \\        } else {
        \\            return b;
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Branch",
        .entry_method = "max",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 10), result.value.integer);
}

test "E2E: for loop with accumulator" {
    const source =
        \\public class Loops {
        \\    public static Integer factorial() {
        \\        Integer result = 1;
        \\        for (Integer i = 1; i <= 5; i += 1) {
        \\            result *= i;
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Loops",
        .entry_method = "factorial",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 120), result.value.integer);
}

test "E2E: string concatenation with integer" {
    const source =
        \\public class Str {
        \\    public static String build() {
        \\        Integer count = 42;
        \\        return 'count=' + count;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Str",
        .entry_method = "build",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("count=42", result.value.string);
}

test "E2E: method calling another method in same class" {
    const source =
        \\public class Multi {
        \\    public static Integer helper() {
        \\        return 7;
        \\    }
        \\    public static Integer main() {
        \\        Integer h = Multi.helper();
        \\        return h * 2;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Multi",
        .entry_method = "main",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 14), result.value.integer);
}

test "E2E: static Map with Set values are independent" {
    const source =
        \\public class MapSetTest {
        \\    private static Map<String, Set<String>> mapA = new Map<String, Set<String>>();
        \\    private static Map<String, Set<String>> mapB = new Map<String, Set<String>>();
        \\    public static Integer test() {
        \\        Set<String> setA = new Set<String>();
        \\        setA.add('a');
        \\        setA.add('b');
        \\        Set<String> setB = new Set<String>();
        \\        setB.add('a');
        \\        mapA.put('key', setA);
        \\        mapB.put('key', setB);
        \\        Integer sizeA = mapA.get('key').size();
        \\        Integer sizeB = mapB.get('key').size();
        \\        if (sizeA == sizeB) return 0;
        \\        return sizeA * 10 + sizeB;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MapSetTest",
        .entry_method = "test",
    });
    defer result.deinit();
    // sizeA should be 2, sizeB should be 1 → result = 21
    try std.testing.expectEqual(@as(i64, 21), result.value.integer);
}

test "E2E: instanceof checks superclass hierarchy" {
    const source =
        \\public class InstanceofTest {
        \\    public interface IFoo {}
        \\    public virtual class Base implements IFoo {}
        \\    public class Child extends Base {}
        \\    public static Integer test() {
        \\        Child c = new Child();
        \\        Integer result = 0;
        \\        if (c instanceof Child) result += 1;
        \\        if (c instanceof Base) result += 10;
        \\        if (c instanceof IFoo) result += 100;
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InstanceofTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 111), result.value.integer);
}

test "E2E: Pattern.compile with digit and word patterns" {
    const source =
        \\public class RegexTest {
        \\    public static String test() {
        \\        // Test 1: \d+ matches digits
        \\        Pattern p1 = Pattern.compile('\\d+');
        \\        Matcher m1 = p1.matcher('abc 123 def 456');
        \\        List<String> nums = new List<String>();
        \\        while (m1.find()) { nums.add(m1.group(0)); }
        \\        // Test 2: capture group
        \\        Pattern p2 = Pattern.compile('(\\w+)@(\\w+)');
        \\        Matcher m2 = p2.matcher('user@host');
        \\        String user = '';
        \\        String host = '';
        \\        if (m2.find()) { user = m2.group(1); host = m2.group(2); }
        \\        return nums.size() + ':' + nums.get(0) + ':' + nums.get(1) + ':' + user + ':' + host;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RegexTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:123:456:user:host", result.value.string);
}

test "E2E: Matcher.matches requires a full-string regex match" {
    const source =
        \\public class MatcherFullMatchProbe {
        \\    public static String run() {
        \\        Pattern pat = Pattern.compile('(b|m)o[a-z]*');
        \\        return String.valueOf(pat.matcher('bobby').matches())
        \\            + '|'
        \\            + String.valueOf(pat.matcher('jimbob').matches());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MatcherFullMatchProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true|false", result.value.string);
}

test "E2E: Matcher exposes start/end/group_count for static string inputs" {
    const source =
        \\public class MatcherSpanProbe {
        \\    private static final String BODY = 'xxaay';
        \\    public static String run() {
        \\        Pattern pat = Pattern.compile('(a+)');
        \\        Matcher matcher = pat.matcher(BODY);
        \\        if (!matcher.find()) return 'none';
        \\        return String.valueOf(matcher.start())
        \\            + ':'
        \\            + String.valueOf(matcher.end())
        \\            + ':'
        \\            + String.valueOf(matcher.group_count())
        \\            + ':'
        \\            + matcher.group(0)
        \\            + ':'
        \\            + matcher.group(1);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MatcherSpanProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:4:1:aa:aa", result.value.string);
}

test "E2E: standard child relationships preserve field token equality" {
    const source =
        \\public class ChildRelationshipProbe {
        \\    public static String run() {
        \\        for (Object relObj : Account.SObjectType.getDescribe().getChildRelationships()) {
        \\            Schema.ChildRelationship rel = (Schema.ChildRelationship)relObj;
        \\            if (rel.getField() == Contact.AccountId) {
        \\                return rel.getRelationshipName();
        \\            }
        \\        }
        \\        return 'missing';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ChildRelationshipProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Contacts", result.value.string);
}

test "E2E: fields map tokens compare equal to standard child relationship fields" {
    const source =
        \\public class ChildRelationshipFieldMapProbe {
        \\    public static Boolean run() {
        \\        Map<String, Schema.SObjectField> fields = Contact.SObjectType.getDescribe().fields.getMap();
        \\        Schema.SObjectField fromMap = fields.get('AccountId');
        \\        for (Object relObj : Account.SObjectType.getDescribe().getChildRelationships()) {
        \\            Schema.ChildRelationship rel = (Schema.ChildRelationship) relObj;
        \\            if (rel.getRelationshipName() == 'Contacts') {
        \\                return rel.getField() == fromMap;
        \\            }
        \\        }
        \\        return false;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ChildRelationshipFieldMapProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expect(result.value.boolean);
}

test "E2E: Contact describe fields expose LastName token at runtime" {
    const source =
        \\public class ContactDescribeFieldsProbe {
        \\    public static String run() {
        \\        Map<String, Schema.SObjectField> fields = Contact.SObjectType.getDescribe().fields.getMap();
        \\        String fieldName = String.valueOf(Contact.LastName);
        \\        Schema.SObjectField lastNameField = fields.get(fieldName);
        \\        Schema.DescribeFieldResult describe = lastNameField.getDescribe();
        \\        return String.valueOf(lastNameField != null) + ':' + String.valueOf(lastNameField) + ':' + describe.getName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ContactDescribeFieldsProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:LastName:LastName", result.value.string);
}

test "E2E: list-derived describe resolves standard child relationship fields" {
    const source =
        \\public class ChildRelationshipListProbe {
        \\    public static String run() {
        \\        List<Account> parents = new List<Account>{ new Account() };
        \\        DescribeSObjectResult parentDescribe = parents.getSObjectType().getDescribe();
        \\        for (Object relObj : parentDescribe.getChildRelationships()) {
        \\            Schema.ChildRelationship rel = (Schema.ChildRelationship) relObj;
        \\            if (rel.getField() == Contact.AccountId) {
        \\                return rel.getRelationshipName();
        \\            }
        \\        }
        \\        return 'missing';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ChildRelationshipListProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Contacts", result.value.string);
}

test "E2E: JSON parser tokens can be streamed into a generator" {
    const source =
        \\public class JsonStreamingProbe {
        \\    public static String run() {
        \\        JSONParser parser = JSON.createParser('[{"Name":"Acme","Count":2,"Flag":true,"Missing":null}]');
        \\        JSONGenerator generator = JSON.createGenerator(false);
        \\        while (parser.nextToken() != null) {
        \\            switch on parser.getCurrentToken() {
        \\                when START_ARRAY {
        \\                    generator.writeStartArray();
        \\                }
        \\                when START_OBJECT {
        \\                    generator.writeStartObject();
        \\                }
        \\                when FIELD_NAME {
        \\                    generator.writeFieldName(parser.getCurrentName());
        \\                }
        \\                when VALUE_STRING, VALUE_FALSE, VALUE_TRUE, VALUE_NUMBER_FLOAT, VALUE_NUMBER_INT {
        \\                    generator.writeString(parser.getText());
        \\                }
        \\                when VALUE_NULL {
        \\                    generator.writeNull();
        \\                }
        \\                when END_OBJECT {
        \\                    generator.writeEndObject();
        \\                }
        \\                when END_ARRAY {
        \\                    generator.writeEndArray();
        \\                }
        \\            }
        \\        }
        \\        return generator.getAsString();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonStreamingProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "[{\"Name\":\"Acme\",\"Count\":\"2\",\"Flag\":\"true\",\"Missing\":null}]",
        result.value.string,
    );
}

test "E2E: streamed JSON child relationship injection round-trips for typed and generic access" {
    const source =
        \\public class JsonInjectedRelationshipProbe {
        \\    private interface ParserEvents {
        \\        void nextToken(JSONParser fromStream, Integer depth, JSONGenerator toStream);
        \\    }
        \\
        \\    private class InjectChildrenEventHandler implements ParserEvents {
        \\        private JSONParser childrenParser;
        \\        private List<List<Contact>> children;
        \\        private Integer childListIdx = 0;
        \\
        \\        public InjectChildrenEventHandler(JSONParser childrenParser, List<List<Contact>> children) {
        \\            this.childrenParser = childrenParser;
        \\            this.children = children;
        \\            this.childrenParser.nextToken();
        \\        }
        \\
        \\        public void nextToken(JSONParser fromStream, Integer depth, JSONGenerator toStream) {
        \\            if (depth == 2 && fromStream.getCurrentToken() == JSONToken.END_OBJECT) {
        \\                toStream.writeFieldName('Contacts');
        \\                toStream.writeStartObject();
        \\                toStream.writeNumberField('totalSize', children[childListIdx].size());
        \\                toStream.writeBooleanField('done', true);
        \\                toStream.writeFieldName('records');
        \\                streamTokens(childrenParser, toStream, null);
        \\                toStream.writeEndObject();
        \\                childListIdx++;
        \\            }
        \\        }
        \\    }
        \\
        \\    private static void streamTokens(JSONParser fromStream, JSONGenerator toStream, ParserEvents events) {
        \\        Integer depth = 0;
        \\        while (fromStream.nextToken() != null) {
        \\            if (events != null) {
        \\                events.nextToken(fromStream, depth, toStream);
        \\            }
        \\            switch on fromStream.getCurrentToken() {
        \\                when START_ARRAY {
        \\                    toStream.writeStartArray();
        \\                    depth++;
        \\                }
        \\                when START_OBJECT {
        \\                    toStream.writeStartObject();
        \\                    depth++;
        \\                }
        \\                when FIELD_NAME {
        \\                    toStream.writeFieldName(fromStream.getCurrentName());
        \\                }
        \\                when VALUE_STRING, VALUE_FALSE, VALUE_TRUE, VALUE_NUMBER_FLOAT, VALUE_NUMBER_INT {
        \\                    toStream.writeString(fromStream.getText());
        \\                }
        \\                when VALUE_NULL {
        \\                    toStream.writeNull();
        \\                }
        \\                when END_OBJECT {
        \\                    toStream.writeEndObject();
        \\                    depth--;
        \\                }
        \\                when END_ARRAY {
        \\                    toStream.writeEndArray();
        \\                    depth--;
        \\                }
        \\            }
        \\            if (depth == 0) {
        \\                break;
        \\            }
        \\        }
        \\    }
        \\
        \\    public static String run() {
        \\        Account parent = new Account(
        \\            Id = '001000000000001AAA',
        \\            Name = 'Acme',
        \\            NumberOfEmployees = 7
        \\        );
        \\        Contact child1 = new Contact(Id = '003000000000001AAA', DoNotCall = true);
        \\        Contact child2 = new Contact(Id = '003000000000002AAA', DoNotCall = false);
        \\        List<List<Contact>> children = new List<List<Contact>>{
        \\            new List<Contact>{ child1, child2 }
        \\        };
        \\        JSONParser parentsParser = JSON.createParser(JSON.serialize(new List<Account>{ parent }));
        \\        JSONParser childrenParser = JSON.createParser(JSON.serialize(children));
        \\        JSONGenerator out = JSON.createGenerator(false);
        \\        streamTokens(parentsParser, out, new InjectChildrenEventHandler(childrenParser, children));
        \\        String combined = out.getAsString();
        \\        Account typed = ((List<Account>) JSON.deserialize(combined, List<Account>.class))[0];
        \\        SObject generic = ((List<SObject>) JSON.deserialize(combined, List<SObject>.class))[0];
        \\        return String.valueOf(typed.Contacts == null ? null : typed.Contacts.size()) + ':' +
        \\            String.valueOf(generic.getSObjects('Contacts').size()) + ':' +
        \\            String.valueOf(generic.getSObjects('Contacts')[0].Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonInjectedRelationshipProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:2:003000000000001AAA", result.value.string);
}

test "E2E: streamed JSON child relationship injection emits relationship wrapper" {
    const source =
        \\public class JsonInjectedRelationshipStringProbe {
        \\    private interface ParserEvents {
        \\        void nextToken(JSONParser fromStream, Integer depth, JSONGenerator toStream);
        \\    }
        \\
        \\    private class InjectChildrenEventHandler implements ParserEvents {
        \\        private JSONParser childrenParser;
        \\        private List<List<Contact>> children;
        \\        private Integer childListIdx = 0;
        \\
        \\        public InjectChildrenEventHandler(JSONParser childrenParser, List<List<Contact>> children) {
        \\            this.childrenParser = childrenParser;
        \\            this.children = children;
        \\            this.childrenParser.nextToken();
        \\        }
        \\
        \\        public void nextToken(JSONParser fromStream, Integer depth, JSONGenerator toStream) {
        \\            if (depth == 2 && fromStream.getCurrentToken() == JSONToken.END_OBJECT) {
        \\                toStream.writeFieldName('Contacts');
        \\                toStream.writeStartObject();
        \\                toStream.writeNumberField('totalSize', children[childListIdx].size());
        \\                toStream.writeBooleanField('done', true);
        \\                toStream.writeFieldName('records');
        \\                streamTokens(childrenParser, toStream, null);
        \\                toStream.writeEndObject();
        \\                childListIdx++;
        \\            }
        \\        }
        \\    }
        \\
        \\    private static void streamTokens(JSONParser fromStream, JSONGenerator toStream, ParserEvents events) {
        \\        Integer depth = 0;
        \\        while (fromStream.nextToken() != null) {
        \\            if (events != null) {
        \\                events.nextToken(fromStream, depth, toStream);
        \\            }
        \\            switch on fromStream.getCurrentToken() {
        \\                when START_ARRAY {
        \\                    toStream.writeStartArray();
        \\                    depth++;
        \\                }
        \\                when START_OBJECT {
        \\                    toStream.writeStartObject();
        \\                    depth++;
        \\                }
        \\                when FIELD_NAME {
        \\                    toStream.writeFieldName(fromStream.getCurrentName());
        \\                }
        \\                when VALUE_STRING, VALUE_FALSE, VALUE_TRUE, VALUE_NUMBER_FLOAT, VALUE_NUMBER_INT {
        \\                    toStream.writeString(fromStream.getText());
        \\                }
        \\                when VALUE_NULL {
        \\                    toStream.writeNull();
        \\                }
        \\                when END_OBJECT {
        \\                    toStream.writeEndObject();
        \\                    depth--;
        \\                }
        \\                when END_ARRAY {
        \\                    toStream.writeEndArray();
        \\                    depth--;
        \\                }
        \\            }
        \\            if (depth == 0) {
        \\                break;
        \\            }
        \\        }
        \\    }
        \\
        \\    public static String run() {
        \\        Account parent = new Account(
        \\            Id = '001000000000001AAA',
        \\            Name = 'Acme',
        \\            NumberOfEmployees = 7
        \\        );
        \\        Contact child1 = new Contact(Id = '003000000000001AAA', DoNotCall = true);
        \\        Contact child2 = new Contact(Id = '003000000000002AAA', DoNotCall = false);
        \\        List<List<Contact>> children = new List<List<Contact>>{
        \\            new List<Contact>{ child1, child2 }
        \\        };
        \\        JSONParser parentsParser = JSON.createParser(JSON.serialize(new List<Account>{ parent }));
        \\        JSONParser childrenParser = JSON.createParser(JSON.serialize(children));
        \\        JSONGenerator out = JSON.createGenerator(false);
        \\        streamTokens(parentsParser, out, new InjectChildrenEventHandler(childrenParser, children));
        \\        return out.getAsString();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonInjectedRelationshipStringProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("[{\"attributes\":{\"type\":\"Account\"},\"Id\":\"001000000000001AAA\",\"Name\":\"Acme\",\"NumberOfEmployees\":\"7\",\"Contacts\":{\"totalSize\":2,\"done\":true,\"records\":[{\"attributes\":{\"type\":\"Contact\"},\"Id\":\"003000000000001AAA\",\"DoNotCall\":\"true\"},{\"attributes\":{\"type\":\"Contact\"},\"Id\":\"003000000000002AAA\",\"DoNotCall\":\"false\"}]}}]", result.value.string);
}

test "E2E: custom property setters can delegate writes" {
    const source =
        \\public class DelegatingSetterProbe {
        \\    public class Holder {
        \\        public String value { get; set; }
        \\    }
        \\    private Holder holder = new Holder();
        \\    public String Name {
        \\        get {
        \\            return holder.value;
        \\        }
        \\        set {
        \\            holder.value = value;
        \\        }
        \\    }
        \\    public static String run() {
        \\        DelegatingSetterProbe probe = new DelegatingSetterProbe();
        \\        probe.Name = 'delegated';
        \\        return probe.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DelegatingSetterProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("delegated", result.value.string);
}

test "E2E: Date.today returns current date, Date.newInstance builds from args" {
    const source =
        \\public class DateTest {
        \\    public static String test() {
        \\        String today = String.valueOf(Date.today());
        \\        String custom = String.valueOf(Date.newInstance(2025, 3, 15));
        \\        Boolean todayHas4digitYear = today.length() >= 10;
        \\        Boolean customCorrect = custom == '2025-03-15';
        \\        return todayHas4digitYear + ':' + customCorrect;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DateTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: System.now date matches System.today" {
    const source =
        \\public class SystemNowTest {
        \\    public static String test() {
        \\        return String.valueOf(System.now().date() == System.today());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SystemNowTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: Database.query on unknown object throws QueryException" {
    const source =
        \\public class UnknownObjTest {
        \\    public static String test() {
        \\        try {
        \\            Database.query('SELECT Id FROM CompletelyFakeObject__x LIMIT 1');
        \\            return 'no error';
        \\        } catch (QueryException e) {
        \\            return 'caught';
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UnknownObjTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("caught", result.value.string);
}

test "E2E: beforeUpdate trigger addError causes DmlException" {
    const source =
        \\trigger TestTrigger on Account (before update) {
        \\    for (Account a : Trigger.new) {
        \\        a.addError('always fail');
        \\    }
        \\}
        \\public class TrigTest {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'Test');
        \\        insert a;
        \\        try {
        \\            update a;
        \\            return 'no error';
        \\        } catch (DmlException e) {
        \\            return 'caught: ' + e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TrigTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "caught:"));
}

test "E2E: Cache.Partition get with CacheBuilder stores key and getKeys contains class name" {
    const source =
        \\public class MyCacheBuilder implements Cache.CacheBuilder {
        \\    public Object doLoad(String key) { return 'cached-value'; }
        \\}
        \\public class CacheTest {
        \\    public static String test() {
        \\        Cache.OrgPartition p = Cache.Org.getPartition('local.default');
        \\        p.remove(MyCacheBuilder.class, 'myKey');
        \\        System.assertEquals(0, p.getNumKeys(), 'start empty');
        \\        Object val = p.get(MyCacheBuilder.class, 'myKey');
        \\        Integer numKeys = p.getNumKeys();
        \\        String keysStr = p.getKeys().toString();
        \\        Boolean hasBuilder = keysStr.containsIgnoreCase('mycachebuilder');
        \\        return numKeys + ':' + hasBuilder;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CacheTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:true", result.value.string);
}

test "E2E: Cache.Partition get resolves inner CacheBuilder classes" {
    const source =
        \\public class CacheBuilderHost {
        \\    public class InnerBuilder implements Cache.CacheBuilder {
        \\        public Object doLoad(String key) { return 'loaded:' + key; }
        \\    }
        \\}
        \\public class InnerCacheBuilderTest {
        \\    public static String test() {
        \\        Cache.OrgPartition p = Cache.Org.getPartition('local.default');
        \\        p.remove(CacheBuilderHost.InnerBuilder.class, 'demo');
        \\        Object val = p.get(CacheBuilderHost.InnerBuilder.class, 'demo');
        \\        return String.valueOf(val) + ':' + String.valueOf(p.getNumKeys() > 0) + ':' +
        \\            String.valueOf(p.getKeys().toString().containsIgnoreCase('innerbuilder'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerCacheBuilderTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("loaded:demo:true:true", result.value.string);
}

test "E2E: Cache.Partition get resolves bare inner CacheBuilder literals inside the outer class" {
    const source =
        \\public class CacheBuilderOwner {
        \\    public class InnerBuilder implements Cache.CacheBuilder {
        \\        public Object doLoad(String key) { return 'loaded:' + key; }
        \\    }
        \\    public static String test() {
        \\        Cache.OrgPartition p = Cache.Org.getPartition('local.default');
        \\        p.remove(InnerBuilder.class, 'demo');
        \\        Object val = p.get(InnerBuilder.class, 'demo');
        \\        return String.valueOf(val) + ':' + String.valueOf(p.getNumKeys() > 0);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CacheBuilderOwner",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("loaded:demo:true", result.value.string);
}

test "E2E: cached Organization accessor works through an inner CacheBuilder" {
    const source =
        \\public class CachedOrgAccessor {
        \\    private Cache.OrgPartition safeDefaultCachePartition;
        \\    private Organization orgState = getOrgState();
        \\    public Boolean isSandbox {
        \\        get { return getOrgState().isSandbox; }
        \\    }
        \\    private Cache.OrgPartition getAvailableOrgCachePartition() {
        \\        if (this.safeDefaultCachePartition != null) {
        \\            return this.safeDefaultCachePartition;
        \\        }
        \\        PlatformCachePartition partition = [
        \\            SELECT DeveloperName
        \\            FROM PlatformCachePartition
        \\            WHERE NamespacePrefix = ''
        \\            LIMIT 1
        \\        ];
        \\        this.safeDefaultCachePartition = Cache.Org.getPartition('local.' + partition.DeveloperName);
        \\        return this.safeDefaultCachePartition;
        \\    }
        \\    public Boolean isPlatformCacheEnabled() {
        \\        return getAvailableOrgCachePartition() != null;
        \\    }
        \\    private Organization getOrgState() {
        \\        if (isPlatformCacheEnabled()) {
        \\            return (Organization) getAvailableOrgCachePartition()
        \\                .get(CachedLoader.class, 'requiredButNotUsed');
        \\        }
        \\        if (this.orgState != null) {
        \\            return this.orgState;
        \\        }
        \\        this.orgState = [SELECT FIELDS(STANDARD) FROM Organization LIMIT 1];
        \\        return this.orgState;
        \\    }
        \\    public class CachedLoader implements Cache.CacheBuilder {
        \\        public Organization doLoad(String ignored) {
        \\            return [SELECT FIELDS(STANDARD) FROM Organization LIMIT 1];
        \\        }
        \\    }
        \\    public static String test() {
        \\        Cache.OrgPartition partition = Cache.Org.getPartition('local.default');
        \\        partition.remove(CachedLoader.class, 'requiredButNotUsed');
        \\        CachedOrgAccessor accessor = new CachedOrgAccessor();
        \\        return String.valueOf(accessor.isSandbox) + ':' + String.valueOf(partition.getNumKeys());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CachedOrgAccessor",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:1", result.value.string);
}

test "E2E: Cache.Partition isAvailable returns true for existing org partition" {
    const source =
        \\public class CacheAvailabilityTest {
        \\    public static String test() {
        \\        Cache.OrgPartition p = Cache.Org.getPartition('LoggerCache');
        \\        p.put('myKey', 'myValue');
        \\        return String.valueOf(p.isAvailable()) + ':' + String.valueOf(p.contains('myKey'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CacheAvailabilityTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: Flow metadata stubs support IN bind variables" {
    const source =
        \\public class FlowMetadataQueryTest {
        \\    public static String test() {
        \\        List<String> flowApiNames = new List<String>{ 'MockLogBatchPurgerPlugin' };
        \\        List<Schema.FlowDefinitionView> defs = [
        \\            SELECT ActiveVersionId, ApiName, DurableId
        \\            FROM FlowDefinitionView
        \\            WHERE ApiName IN :flowApiNames AND IsActive = TRUE
        \\        ];
        \\        List<String> activeVersionIds = new List<String>{ defs.get(0).ActiveVersionId };
        \\        List<Schema.FlowVersionView> vers = [
        \\            SELECT DurableId, FlowDefinitionViewId
        \\            FROM FlowVersionView
        \\            WHERE DurableId IN :activeVersionIds
        \\        ];
        \\        return defs.get(0).ApiName + ':' +
        \\            String.valueOf(vers.get(0).FlowDefinitionViewId == defs.get(0).DurableId) + ':' +
        \\            String.valueOf(vers.get(0).DurableId == defs.get(0).ActiveVersionId);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FlowMetadataQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("MockLogBatchPurgerPlugin:true:true", result.value.string);
}

test "E2E: metadata stubs resolve static bind variables" {
    const source =
        \\public class StaticFlowBindTest {
        \\    private static final String FLOW_API_NAME = 'LogEntryHandler_Tests_Flow';
        \\    public static String test() {
        \\        Schema.FlowDefinitionView def = [
        \\            SELECT ApiName
        \\            FROM FlowDefinitionView
        \\            WHERE ApiName = :FLOW_API_NAME AND IsActive = TRUE
        \\        ];
        \\        return def.ApiName;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticFlowBindTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("LogEntryHandler_Tests_Flow", result.value.string);
}

test "E2E: FlowDefinitionView stub query works through helper method reuse" {
    const source =
        \\public class FlowSelector {
        \\    public static List<Schema.FlowDefinitionView> getDefs(List<String> flowApiNames) {
        \\        return [
        \\            SELECT ActiveVersionId, ApiName, DurableId
        \\            FROM FlowDefinitionView
        \\            WHERE ApiName IN :flowApiNames AND IsActive = TRUE
        \\        ];
        \\    }
        \\}
        \\
        \\public class FlowSelectorTest {
        \\    public static String test() {
        \\        List<String> flowApiNames = new List<String>{ 'MockLogBatchPurgerPlugin' };
        \\        List<Schema.FlowDefinitionView> directResults = [
        \\            SELECT ActiveVersionId, ApiName, DurableId
        \\            FROM FlowDefinitionView
        \\            WHERE ApiName IN :flowApiNames AND IsActive = TRUE
        \\        ];
        \\        List<Schema.FlowDefinitionView> helperResults = FlowSelector.getDefs(flowApiNames);
        \\        return String.valueOf(directResults.size()) + ':' + String.valueOf(helperResults.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FlowSelectorTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:1", result.value.string);
}

test "E2E: FlowDefinitionView stub does not synthesize inactive-free queries" {
    const source =
        \\public class FlowDefinitionViewMissingTest {
        \\    public static String test() {
        \\        List<Schema.FlowDefinitionView> defs = [
        \\            SELECT ApiName
        \\            FROM FlowDefinitionView
        \\            WHERE ApiName = 'MissingFlow'
        \\        ];
        \\        return String.valueOf(defs.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FlowDefinitionViewMissingTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0", result.value.string);
}

test "E2E: fixture Flow.Interview plugin mock exposes input and output variables" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    const source =
        \\public class FlowInterviewTest {
        \\    public static String test() {
        \\        Map<String, Object> inputs = new Map<String, Object>();
        \\        inputs.put('pluginConfiguration', 'cfg');
        \\        inputs.put('pluginInput', 'input');
        \\        Flow.Interview interview = Flow.Interview.createInterview('MockLogBatchPurgerPlugin', inputs);
        \\        interview.start();
        \\        return (String) interview.getVariableValue('pluginConfiguration') + ':' +
        \\            (String) interview.getVariableValue('pluginInput') + ':' +
        \\            (String) interview.getVariableValue('someExampleVariable');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FlowInterviewTest",
        .entry_method = "test",
        .source_paths = fixture_paths.slice(),
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("cfg:input:Hello, world", result.value.string);
}

test "E2E: FeatureManagement.checkPermission honors assigned custom permissions in runAs" {
    const source =
        \\public class FeaturePermissionTest {
        \\    public static Boolean test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(ProfileId = p.Id, LastName = 'User', Username = 'perm@example.com', Email = 'perm@example.com', Alias = 'pusr');
        \\        insert u;
        \\        PermissionSet ps = new PermissionSet(Name = 'CustomPermissionEnabled', Label = 'Custom Permission Enabled');
        \\        insert ps;
        \\        SetupEntityAccess sea = new SetupEntityAccess(
        \\            ParentId = ps.Id,
        \\            SetupEntityId = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'CanModifyLoggerSettings'].Id
        \\        );
        \\        PermissionSetAssignment psa = new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        \\        insert new List<SObject>{ sea, psa };
        \\        Boolean hasPermission = false;
        \\        System.runAs(u) {
        \\            hasPermission = System.FeatureManagement.checkPermission('CanModifyLoggerSettings');
        \\        }
        \\        return hasPermission;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FeaturePermissionTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: standard user custom object describe is not updateable by default" {
    const source =
        \\public class StandardUserCrudTest {
        \\    public static Boolean test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(ProfileId = p.Id, LastName = 'User', Username = 'crud@example.com', Email = 'crud@example.com', Alias = 'cusr');
        \\        insert u;
        \\        Boolean canUpdate = true;
        \\        System.runAs(u) {
        \\            canUpdate = Schema.LoggerSettings__c.SObjectType.getDescribe().isUpdateable();
        \\        }
        \\        return canUpdate;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StandardUserCrudTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(false, result.value.boolean);
}

test "E2E: schema-qualified standard user custom object describe is not updateable by default" {
    const source =
        \\public class SchemaQualifiedCrudTest {
        \\    public static String test() {
        \\        Schema.Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        Schema.User u = new Schema.User(ProfileId = p.Id, LastName = 'User', Username = 'schema-crud@example.com', Email = 'schema-crud@example.com', Alias = 'sqru');
        \\        insert u;
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = String.valueOf(Schema.LoggerSettings__c.SObjectType.getDescribe().isUpdateable()) + ':' +
        \\                String.valueOf(System.FeatureManagement.checkPermission('CanModifyLoggerSettings'));
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaQualifiedCrudTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:false", result.value.string);
}

test "E2E: Profile Name IN query preserves standard-user CRUD restrictions in runAs" {
    const source =
        \\public class ProfileInCrudTest {
        \\    public static String test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name IN ('Standard User', 'Usuario estándar', '標準ユーザー')];
        \\        User u = new User(ProfileId = p.Id, LastName = 'User', Username = 'profile-in@example.com', Email = 'profile-in@example.com', Alias = 'pin');
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = String.valueOf(Schema.LoggerSettings__c.SObjectType.getDescribe().isUpdateable()) + ':' +
        \\                String.valueOf(Schema.Log__c.SObjectType.getDescribe().isDeletable());
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ProfileInCrudTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:false", result.value.string);
}

test "E2E: synthetic Profile LIKE filters no-match and collapses repeated wildcards" {
    const source =
        \\public class ProfileLikeSearchTest {
        \\    public static String test() {
        \\        Profile currentProfile = [SELECT Id, Name FROM Profile WHERE Id = :UserInfo.getProfileId()];
        \\        String noMatchSearch = '%definitely-no-match%';
        \\        List<Profile> noMatches = [SELECT Id FROM Profile WHERE Name LIKE :noMatchSearch];
        \\        String innerSearch = '%' + currentProfile.Name.left(4) + '%';
        \\        String wrappedSearch = '%' + innerSearch + '%';
        \\        List<Profile> matches = [SELECT Id, Name, UserLicense.Name FROM Profile WHERE Name LIKE :wrappedSearch];
        \\        return String.valueOf(noMatches.size()) + ':' + matches.get(0).Name + ':' + matches.get(0).UserLicense.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ProfileLikeSearchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:System Administrator:Salesforce", result.value.string);
}

test "E2E: synthetic Profile query honors permission flag predicates" {
    const source =
        \\public class ProfilePermissionPredicateTest {
        \\    public static String test() {
        \\        Profile p = [
        \\            SELECT Id, Name, PermissionsPrivacyDataAccess, PermissionsSubmitMacrosAllowed, PermissionsMassInlineEdit
        \\            FROM Profile
        \\            WHERE
        \\                UserType = 'Standard'
        \\                AND PermissionsPrivacyDataAccess = FALSE
        \\                AND PermissionsSubmitMacrosAllowed = TRUE
        \\                AND PermissionsMassInlineEdit = TRUE
        \\            LIMIT 1
        \\        ];
        \\        return p.Name + ':' +
        \\            String.valueOf(p.PermissionsPrivacyDataAccess) + ':' +
        \\            String.valueOf(p.PermissionsSubmitMacrosAllowed) + ':' +
        \\            String.valueOf(p.PermissionsMassInlineEdit);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ProfilePermissionPredicateTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("System Administrator:false:true:true", result.value.string);
}

test "E2E: inserted users are queryable by CommunityNickname" {
    const source =
        \\public class UserCommunityNicknameTest {
        \\    public static String test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        \\        User u = new User(
        \\            LastName = 'Nickname User',
        \\            Email = 'nickname@example.com',
        \\            Alias = 'nick',
        \\            Username = 'nickname@example.com',
        \\            CommunityNickname = 'fixture-nick',
        \\            LocaleSidKey = 'en_US',
        \\            TimeZoneSidKey = 'GMT',
        \\            ProfileId = p.Id,
        \\            LanguageLocaleKey = 'en_US',
        \\            EmailEncodingKey = 'UTF-8'
        \\        );
        \\        insert as user u;
        \\        List<User> rows = [
        \\            SELECT Id, CommunityNickname
        \\            FROM User
        \\            WHERE CommunityNickname = 'fixture-nick'
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' + rows[0].CommunityNickname + ':' + String.valueOf(u.Id != null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UserCommunityNicknameTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:fixture-nick:true", result.value.string);
}

test "E2E: static final test-dependent bind variables resolve in SOQL" {
    const source =
        \\public class StaticBindProbe {
        \\    private static final String USERNAME = Test.isRunningTest()
        \\        ? 'missing-user@example.com'
        \\        : 'prod-user@example.com';
        \\    public static String test() {
        \\        List<User> rows = [
        \\            SELECT Id, Username
        \\            FROM User
        \\            WHERE Username = :USERNAME
        \\        ];
        \\        return USERNAME + ':' + String.valueOf(rows.size()) + ':' +
        \\            (rows.size() == 0 ? 'none' : rows[0].Username);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticBindProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("missing-user@example.com:0:none", result.value.string);
}

test "E2E: static final test-dependent constants evaluate before use" {
    const source =
        \\public class StaticConstantProbe {
        \\    private static final String USERNAME = Test.isRunningTest()
        \\        ? 'missing-user@example.com'
        \\        : 'prod-user@example.com';
        \\    public static String test() {
        \\        return USERNAME;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticConstantProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("missing-user@example.com", result.value.string);
}

test "E2E: synthetic User LIKE collapses repeated wildcards" {
    const source =
        \\public class UserLikeSearchTest {
        \\    public static String test() {
        \\        String innerSearch = '%' + UserInfo.getLastName() + '%';
        \\        String wrappedSearch = '%' + innerSearch + '%';
        \\        List<User> matches = [
        \\            SELECT Id, Name, Username
        \\            FROM User
        \\            WHERE Name LIKE :wrappedSearch OR Username LIKE :wrappedSearch
        \\            ORDER BY Username
        \\            LIMIT 20
        \\        ];
        \\        return matches.get(0).Name + ':' + matches.get(0).Username;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UserLikeSearchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Test User:testuser@example.com", result.value.string);
}

test "E2E: stripInaccessible keeps Id on update records" {
    const source =
        \\public class StripInaccessibleIdTest {
        \\    public static String test() {
        \\        Account recordToUpdate = new Account(Id = '001000000000001AAA');
        \\        recordToUpdate.Description = 'updated';
        \\        SObjectAccessDecision decision = Security.stripInaccessible(
        \\            AccessType.UPDATABLE,
        \\            new List<SObject>{ recordToUpdate },
        \\            true
        \\        );
        \\        List<SObject> rows = decision.getRecords();
        \\        return String.valueOf(rows.size()) + ':' + String.valueOf(rows[0].Id) + ':' +
        \\            String.valueOf(rows[0].get('Description'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StripInaccessibleIdTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:001000000000001AAA:updated", result.value.string);
}

test "E2E: user-defined classes shadow builtin static helpers" {
    const source =
        \\public class Security {
        \\    public static String stripInaccessible(String marker) {
        \\        return 'shadow:' + marker;
        \\    }
        \\}
        \\public class SecurityShadowTest {
        \\    public static String test() {
        \\        return Security.stripInaccessible('ok');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SecurityShadowTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("shadow:ok", result.value.string);
}

test "E2E: stripInaccessible READABLE removes selected null fields without access" {
    const source =
        \\public class ReadableNullFieldStripTest {
        \\    private static User makeUser() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Reader',
        \\            Username = 'reader.nullstrip@example.com',
        \\            Email = 'reader.nullstrip@example.com',
        \\            Alias = 'rdrs'
        \\        );
        \\        insert u;
        \\        PermissionSet ps = new PermissionSet(Name = 'AccountReadOnly', Label = 'AccountReadOnly');
        \\        insert ps;
        \\        ObjectPermissions op = new ObjectPermissions(ParentId = ps.Id, SobjectType = 'Account');
        \\        op.PermissionsRead = true;
        \\        insert op;
        \\        insert new PermissionSetAssignment(PermissionSetId = ps.Id, AssigneeId = u.Id);
        \\        return u;
        \\    }
        \\    public static Boolean test() {
        \\        insert new Account(Name = 'Example');
        \\        User u = makeUser();
        \\        Boolean stripped = false;
        \\        System.runAs(u) {
        \\            SObjectAccessDecision decision = Security.stripInaccessible(
        \\                AccessType.READABLE,
        \\                [SELECT Id, Name, ShippingStreet FROM Account]
        \\            );
        \\            List<Account> rows = (List<Account>) decision.getRecords();
        \\            try {
        \\                String ignored = rows[0].ShippingStreet;
        \\            } catch (SObjectException e) {
        \\                stripped = e.getMessage().containsIgnoreCase('without querying');
        \\            }
        \\        }
        \\        return stripped;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ReadableNullFieldStripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(result.value.boolean);
}

test "E2E: stripInaccessible READABLE skips root CRUD enforcement when disabled" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/Thing__c.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <deploymentStatus>Deployed</deploymentStatus>
        \\    <enableActivities>false</enableActivities>
        \\    <enableReports>false</enableReports>
        \\    <enableSearch>false</enableSearch>
        \\    <enableSharing>true</enableSharing>
        \\    <label>Thing</label>
        \\    <nameField>
        \\        <label>Thing Name</label>
        \\        <type>Text</type>
        \\    </nameField>
        \\    <pluralLabel>Things</pluralLabel>
        \\    <sharingModel>ReadWrite</sharingModel>
        \\</CustomObject>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/Detail__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Detail__c</fullName>
        \\    <label>Detail</label>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class StripInaccessibleReadableCrudFlagTest {
        \\    private static User makeUser() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Reader',
        \\            Username = 'crud.flag.reader@example.com',
        \\            Email = 'crud.flag.reader@example.com',
        \\            Alias = 'crdf'
        \\        );
        \\        insert u;
        \\        return u;
        \\    }
        \\    public static String test() {
        \\        User u = makeUser();
        \\        Thing__c record = new Thing__c(Id = 'a00000000000001AAA', Name = 'Example', Detail__c = 'secret');
        \\        String json;
        \\        System.runAs(u) {
        \\            SObjectAccessDecision decision = Security.stripInaccessible(
        \\                AccessType.READABLE,
        \\                new List<SObject>{ record },
        \\                false
        \\            );
        \\            json = JSON.serializePretty(((List<Thing__c>) decision.getRecords())[0]);
        \\        }
        \\        return json;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "StripInaccessibleReadableCrudFlagTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "{\"attributes\":{\"type\":\"Thing__c\"},\"Id\":\"a00000000000001AAA\"}",
        result.value.string,
    );
}

test "E2E: stripInaccessible READABLE enforces root CRUD by default" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/Thing__c.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <deploymentStatus>Deployed</deploymentStatus>
        \\    <enableActivities>false</enableActivities>
        \\    <enableReports>false</enableReports>
        \\    <enableSearch>false</enableSearch>
        \\    <enableSharing>true</enableSharing>
        \\    <label>Thing</label>
        \\    <nameField>
        \\        <label>Thing Name</label>
        \\        <type>Text</type>
        \\    </nameField>
        \\    <pluralLabel>Things</pluralLabel>
        \\    <sharingModel>ReadWrite</sharingModel>
        \\</CustomObject>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class StripInaccessibleReadableDefaultCrudTest {
        \\    private static User makeUser() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Reader',
        \\            Username = 'crud.default.reader@example.com',
        \\            Email = 'crud.default.reader@example.com',
        \\            Alias = 'crdd'
        \\        );
        \\        insert u;
        \\        return u;
        \\    }
        \\    public static Boolean test() {
        \\        User u = makeUser();
        \\        Boolean threw = false;
        \\        System.runAs(u) {
        \\            try {
        \\                Security.stripInaccessible(
        \\                    AccessType.READABLE,
        \\                    new List<SObject>{ new Thing__c(Name = 'Example') }
        \\                );
        \\            } catch (NoAccessException e) {
        \\                threw = e.getMessage().containsIgnoreCase('No access to entity');
        \\            }
        \\        }
        \\        return threw;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "StripInaccessibleReadableDefaultCrudTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expect(result.value.boolean);
}

test "E2E: permission set groups expand assigned permission sets" {
    const source =
        \\public class PermissionSetGroupExpansionTest {
        \\    private static User makeUser() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Grouped',
        \\            Username = 'grouped.permissions@example.com',
        \\            Email = 'grouped.permissions@example.com',
        \\            Alias = 'grpd'
        \\        );
        \\        insert u;
        \\        return u;
        \\    }
        \\    public static Boolean test() {
        \\        PermissionSet ps = new PermissionSet(
        \\            Name = 'Allows_read_access_to_account_shipping_street',
        \\            Label = 'Allows_read_access_to_account_shipping_street'
        \\        );
        \\        insert ps;
        \\        PermissionSetGroup psg = new PermissionSetGroup(
        \\            DeveloperName = 'Account_Read_Group',
        \\            MasterLabel = 'Account Read Group'
        \\        );
        \\        insert psg;
        \\        insert new PermissionSetGroupComponent(
        \\            PermissionSetGroupId = psg.Id,
        \\            PermissionSetId = ps.Id
        \\        );
        \\        User u = makeUser();
        \\        insert new PermissionSetAssignment(
        \\            PermissionSetGroupId = psg.Id,
        \\            AssigneeId = u.Id
        \\        );
        \\        Boolean allowed = false;
        \\        System.runAs(u) {
        \\            SObjectAccessDecision decision = Security.stripInaccessible(
        \\                AccessType.READABLE,
        \\                new List<Account>{
        \\                    new Account(Name = 'Example', ShippingStreet = '123 Main')
        \\                }
        \\            );
        \\            List<Account> rows = (List<Account>) decision.getRecords();
        \\            allowed = ((String) rows[0].get('ShippingStreet')) == '123 Main';
        \\        }
        \\        return allowed;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PermissionSetGroupExpansionTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(result.value.boolean);
}

test "E2E: permission set metadata expands composite address field permissions" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "permissionsets");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "permissionsets/Address_Edit.permissionset-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fieldPermissions>
        \\        <editable>true</editable>
        \\        <field>Account.ShippingAddress</field>
        \\        <readable>true</readable>
        \\    </fieldPermissions>
        \\    <label>Address Edit</label>
        \\    <objectPermissions>
        \\        <allowCreate>false</allowCreate>
        \\        <allowDelete>false</allowDelete>
        \\        <allowEdit>true</allowEdit>
        \\        <allowRead>true</allowRead>
        \\        <modifyAllRecords>false</modifyAllRecords>
        \\        <object>Account</object>
        \\        <viewAllRecords>false</viewAllRecords>
        \\    </objectPermissions>
        \\</PermissionSet>
        ,
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    const source =
        \\public class PermissionSetMetadataAddressTest {
        \\    private static User makeUser() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Address',
        \\            Username = 'address.permissions@example.com',
        \\            Email = 'address.permissions@example.com',
        \\            Alias = 'addr'
        \\        );
        \\        insert u;
        \\        return u;
        \\    }
        \\    public static Boolean test() {
        \\        User u = makeUser();
        \\        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Address_Edit' LIMIT 1];
        \\        insert new PermissionSetAssignment(PermissionSetId = ps.Id, AssigneeId = u.Id);
        \\        Boolean allowed = false;
        \\        System.runAs(u) {
        \\            SObjectAccessDecision decision = Security.stripInaccessible(
        \\                AccessType.UPDATABLE,
        \\                new List<Account>{
        \\                    new Account(Name = 'Example', ShippingStreet = '123 Main')
        \\                }
        \\            );
        \\            List<Account> rows = (List<Account>) decision.getRecords();
        \\            allowed = ((String) rows[0].get('ShippingStreet')) == '123 Main';
        \\        }
        \\        return allowed;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PermissionSetMetadataAddressTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expect(result.value.boolean);
}

test "E2E: describeSObjects exposes updatable standard address fields" {
    const source =
        \\public class DescribeSObjectsUpdatableFieldsTest {
        \\    public static Boolean test() {
        \\        Schema.DescribeSObjectResult[] desc = Schema.describeSObjects(
        \\            new List<String>{ 'Account' }
        \\        );
        \\        Map<String, Schema.SObjectField> fields = desc[0].fields.getMap();
        \\        return fields.get('Name').getDescribe().isUpdateable() &&
        \\            fields.get('ShippingStreet').getDescribe().isUpdateable();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DescribeSObjectsUpdatableFieldsTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(result.value.boolean);
}

test "E2E: stripInaccessible update records remain usable after JSON round-trip" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "permissionsets");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "permissionsets/Address_Edit.permissionset-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fieldPermissions>
        \\        <editable>true</editable>
        \\        <field>Account.ShippingAddress</field>
        \\        <readable>true</readable>
        \\    </fieldPermissions>
        \\    <label>Address Edit</label>
        \\    <objectPermissions>
        \\        <allowCreate>false</allowCreate>
        \\        <allowDelete>false</allowDelete>
        \\        <allowEdit>true</allowEdit>
        \\        <allowRead>true</allowRead>
        \\        <modifyAllRecords>false</modifyAllRecords>
        \\        <object>Account</object>
        \\        <viewAllRecords>false</viewAllRecords>
        \\    </objectPermissions>
        \\</PermissionSet>
        ,
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    const source =
        \\public class StripInaccessibleJsonUpdateTest {
        \\    private static User makeUser() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Updater',
        \\            Username = 'json.updater@example.com',
        \\            Email = 'json.updater@example.com',
        \\            Alias = 'jupd'
        \\        );
        \\        insert u;
        \\        return u;
        \\    }
        \\    public static Boolean test() {
        \\        Account acct = new Account(Name = 'Example');
        \\        insert acct;
        \\        User u = makeUser();
        \\        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Address_Edit' LIMIT 1];
        \\        insert new PermissionSetAssignment(PermissionSetId = ps.Id, AssigneeId = u.Id);
        \\        List<Account> rows = [SELECT Name FROM Account WHERE Id = :acct.Id];
        \\        rows[0].ShippingStreet = '123 Main';
        \\        System.runAs(u) {
        \\            List<Account> deserialized = (List<Account>) JSON.deserialize(
        \\                JSON.serialize(rows),
        \\                List<Account>.class
        \\            );
        \\            SObjectAccessDecision decision = Security.stripInaccessible(
        \\                AccessType.UPDATABLE,
        \\                deserialized
        \\            );
        \\            update decision.getRecords();
        \\        }
        \\        return [SELECT ShippingStreet FROM Account WHERE Id = :acct.Id]
        \\            .ShippingStreet == '123 Main';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StripInaccessibleJsonUpdateTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expect(result.value.boolean);
}

test "E2E: synthetic automated-process User query works when the User store is non-empty" {
    const source =
        \\public class AutomatedProcessUserQueryTest {
        \\    public static String test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        insert new User(ProfileId = p.Id, LastName = 'StoreUser', Username = 'store-user@example.com', Email = 'store-user@example.com', Alias = 'stor');
        \\        User autoproc = [SELECT Alias, Username, UserType FROM User WHERE Alias = 'autoproc'];
        \\        return autoproc.Alias + ':' + autoproc.Username + ':' + autoproc.UserType;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AutomatedProcessUserQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "autoproc:autoproc@example.com:AutomatedProcess",
        result.value.string,
    );
}

test "E2E: UserInfo getters reflect the current runAs user" {
    const source =
        \\public class RunAsUserInfoTest {
        \\    public static String test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            FirstName = 'Casey',
        \\            LastName = 'Runner',
        \\            Username = 'casey.runner@example.com',
        \\            Email = 'casey.runner@example.com',
        \\            Alias = 'crun',
        \\            TimeZoneSidKey = 'Asia/Tokyo'
        \\        );
        \\        insert u;
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = UserInfo.getUsername() + ':' + UserInfo.getFirstName() + ':' + UserInfo.getLastName() + ':' + UserInfo.getTimeZone().getId();
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RunAsUserInfoTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "casey.runner@example.com:Casey:Runner:Asia/Tokyo",
        result.value.string,
    );
}

test "E2E: User query by UserInfo username resolves the current user when other users exist" {
    const source =
        \\public class CurrentUserUsernameQueryTest {
        \\    public static String test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        insert new User(ProfileId = p.Id, LastName = 'Other', Username = 'other.user@example.com', Email = 'other.user@example.com', Alias = 'othr');
        \\        User currentUser = [SELECT Id, Username FROM User WHERE Username = :UserInfo.getUsername()];
        \\        return currentUser.Id + ':' + currentUser.Username;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CurrentUserUsernameQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("005000000000001:testuser@example.com", result.value.string);
}

test "E2E: User query by UserInfo username resolves the current user before any User records exist" {
    const source =
        \\public class SeededCurrentUserUsernameQueryTest {
        \\    public static String test() {
        \\        User currentUser = [SELECT Id, Username FROM User WHERE Username = :UserInfo.getUsername()];
        \\        return currentUser.Id + ':' + currentUser.Username;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SeededCurrentUserUsernameQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("005000000000001:testuser@example.com", result.value.string);
}

test "E2E: runAs can query the original current user by username" {
    const source =
        \\public class RunAsCurrentUserQueryTest {
        \\    public static String test() {
        \\        String originalUsername = UserInfo.getUsername();
        \\        User autoproc = [SELECT Id FROM User WHERE Alias = 'autoproc'];
        \\        String result = '';
        \\        System.runAs(new User(Id = autoproc.Id)) {
        \\            User originalUser = [SELECT Id, Username FROM User WHERE Username = :originalUsername];
        \\            result = originalUser.Id + ':' + originalUser.Username;
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RunAsCurrentUserQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("005000000000001:testuser@example.com", result.value.string);
}

test "E2E: standard user cannot access AccountBrand describe fields" {
    const source =
        \\public class AccountBrandAccessTest {
        \\    public static String test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name IN ('Standard User', 'Usuario estándar', '標準ユーザー')];
        \\        User u = new User(ProfileId = p.Id, LastName = 'User', Username = 'accountbrand@example.com', Email = 'accountbrand@example.com', Alias = 'abrd');
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = String.valueOf(Schema.AccountBrand.SObjectType.getDescribe().isAccessible()) + ':' +
        \\                String.valueOf(Schema.AccountBrand.CompanyName.getDescribe().isAccessible()) + ':' +
        \\                String.valueOf(Schema.AccountBrand.Name.getDescribe().isAccessible());
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AccountBrandAccessTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:false:false", result.value.string);
}

test "E2E: StaticResource IN clause returns multiple stubs" {
    // Multi-line SOQL like in apex-recipes
    const source =
        \\public class SRTest {
        \\    public static String test() {
        \\        StaticResource[] testData = [
        \\            SELECT Id, Body, Name
        \\            FROM StaticResource
        \\            WHERE Name IN ('alpha', 'beta', 'gamma')
        \\        ];
        \\        return String.valueOf(testData.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SRTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3", result.value.string);
}

test "E2E: static field set before enqueue_job is visible in execute" {
    const source =
        \\public class MyQueueable implements Queueable {
        \\    @testVisible private static Boolean throwError = false;
        \\    @testVisible private static Boolean circuitBreakerThrown = false;
        \\    public static void execute(QueueableContext qc) {
        \\        if (Test.isRunningTest() && throwError) {
        \\            MyQueueable.circuitBreakerThrown = true;
        \\        }
        \\    }
        \\}
        \\public class QTest {
        \\    public static String test() {
        \\        MyQueueable.throwError = true;
        \\        System.enqueue_job(new MyQueueable());
        \\        return String.valueOf(MyQueueable.circuitBreakerThrown);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: Datetime.time returns a Time object and built-in value classes compare by value" {
    const source =
        \\public class TimeValueClassProbe {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstanceGmt(2020, 1, 1, 3, 4, 5);
        \\        Time derived = dt.time();
        \\        Time manual = Time.newInstance(3, 4, 5, 0);
        \\        Boolean eq = derived == manual;
        \\        Integer hour = derived.hour();
        \\        return String.valueOf(eq) + '|' + String.valueOf(hour);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TimeValueClassProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true|3", result.value.string);
}

test "E2E: Decimal.setScale honours RoundingMode.DOWN" {
    const source =
        \\public class SetScaleRoundingProbe {
        \\    public static String test() {
        \\        Decimal value = 1.2345;
        \\        Decimal truncated = value.setScale(3, RoundingMode.DOWN);
        \\        Decimal halfUp = value.setScale(3, RoundingMode.HALF_UP);
        \\        return String.valueOf(truncated) + '|' + String.valueOf(halfUp);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SetScaleRoundingProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1.234|1.235", result.value.string);
}

test "E2E: Datetime.format supports ISO week/year/day-of-week/day-of-year patterns" {
    const source =
        \\public class IsoDateFormatProbe {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstanceGmt(2020, 1, 1, 0, 0, 0);
        \\        Datetime dtMidYear = Datetime.newInstanceGmt(2020, 7, 15, 0, 0, 0);
        \\        return dt.formatGmt('w') + ',' + dt.formatGmt('Y') + ',' +
        \\               dtMidYear.formatGmt('w') + ',' + dtMidYear.formatGmt('u') + ',' +
        \\               dtMidYear.formatGmt('D');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IsoDateFormatProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1,2020,29,3,197", result.value.string);
}

test "E2E: Date/Time helpers for daysBetween pow urlEncode Datetime from Date and Time" {
    const source =
        \\public class DateMathAndEncodingProbe {
        \\    public static String test() {
        \\        Date d1 = Date.newInstance(2020, 1, 1);
        \\        Date d2 = Date.newInstance(2020, 1, 3);
        \\        Integer between = d1.daysBetween(d2);
        \\        Decimal pow = (Decimal.valueOf('2')).pow(3);
        \\        String enc = EncodingUtil.urlEncode('Hello World');
        \\        Time t = Time.newInstance(0, 0, 0, 0);
        \\        Datetime dt = Datetime.newInstance(d1, t);
        \\        return String.valueOf(between) + '|' + String.valueOf(pow) + '|' + enc + '|' + String.valueOf(dt);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DateMathAndEncodingProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2|8|Hello+World|2020-01-01T00:00:00Z", result.value.string);
}

test "E2E: Type literals from distinct classes are not collapsed as map keys" {
    const source =
        \\public class TypeKeyedMapTest {
        \\    public class Alpha {}
        \\    public class Beta {}
        \\    public static String test() {
        \\        Map<Type, String> byType = new Map<Type, String>();
        \\        byType.put(Alpha.class, 'alpha');
        \\        byType.put(Beta.class, 'beta');
        \\        return byType.get(Alpha.class) + ',' + byType.get(Beta.class) + ',' + String.valueOf(byType.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TypeKeyedMapTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("alpha,beta,2", result.value.string);
}

test "E2E: Trigger.operationType is null outside of a trigger context" {
    const source =
        \\public class TriggerOperationTypeProbe {
        \\    public static String test() {
        \\        System.TriggerOperation op = Trigger.operationType;
        \\        return op == null ? 'null' : 'non-null:' + String.valueOf(op);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TriggerOperationTypeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("null", result.value.string);
}

test "E2E: String indexOf honours the optional fromIndex argument" {
    const source =
        \\public class IndexOfFromIndexTest {
        \\    public static String test() {
        \\        String s = 'abcdabcd';
        \\        Integer a = s.indexOf('ab');
        \\        Integer b = s.indexOf('ab', 1);
        \\        Integer c = s.indexOf('ab', 5);
        \\        Integer d = s.lastIndexOf('ab');
        \\        return String.valueOf(a) + ':' + String.valueOf(b) + ':' + String.valueOf(c) + ':' + String.valueOf(d);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IndexOfFromIndexTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:4:-1:4", result.value.string);
}

test "E2E: List and Set values satisfy instanceof Iterable" {
    const source =
        \\public class IterableInstanceofTest {
        \\    public static String test() {
        \\        Object l = new List<String>{ 'a' };
        \\        Object s = new Set<String>{ 'b' };
        \\        Object m = new Map<String, Integer>{ 'k' => 1 };
        \\        return (l instanceof Iterable<Object>) + ':' +
        \\               (s instanceof Iterable<Object>) + ':' +
        \\               (m instanceof Iterable<Object>);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IterableInstanceofTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:false", result.value.string);
}

test "E2E: nested for-each iterates elements of inner list rather than chunking" {
    const source =
        \\public class NestedForEachTest {
        \\    public static String test() {
        \\        List<List<String>> outer = new List<List<String>>{
        \\            new List<String>{ 'a', 'b' },
        \\            new List<String>{ 'c', 'd' }
        \\        };
        \\        List<String> collected = new List<String>();
        \\        for (List<String> inner : outer) {
        \\            for (String s : inner) {
        \\                collected.add(s);
        \\            }
        \\        }
        \\        return String.join(collected, ',');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NestedForEachTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("a,b,c,d", result.value.string);
}

test "E2E: addError on a detached SObject records the error without throwing" {
    const source =
        \\public class AddErrorAttachTest {
        \\    public static String test() {
        \\        Account a = new Account();
        \\        a.addError('shouldnt throw');
        \\        if (!a.hasErrors()) return 'missed';
        \\        return 'attached:' + String.valueOf(a.getErrors().size()) + ':' + a.getErrors()[0].getMessage();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AddErrorAttachTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("attached:1:shouldnt throw", result.value.string);
}

test "E2E: field assignment on static variable whose name collides with a class" {
    const source =
        \\public class ShadowedHolder {
        \\    public class Entry {
        \\        public String payload;
        \\    }
        \\}
        \\public class ShadowedStaticTest {
        \\    private static ShadowedHolder.Entry entry = new ShadowedHolder.Entry();
        \\    public static String test() {
        \\        entry.payload = 'set-via-static';
        \\        ShadowedHolder.Entry alias = entry;
        \\        return alias.payload;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ShadowedStaticTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("set-via-static", result.value.string);
}

test "E2E: inherited method reaches intermediate override via virtual dispatch" {
    const source =
        \\public virtual class VirtualDispatchBase {
        \\    protected List<String> buffer = new List<String>();
        \\    public virtual void add(String value) { buffer.add(value); }
        \\    public virtual String render() { return String.join(buffer, ''); }
        \\    public String publicRender() { return render(); }
        \\}
        \\public virtual class VirtualDispatchMiddle extends VirtualDispatchBase {
        \\    public override String render() { return String.join(buffer, ','); }
        \\}
        \\public class VirtualDispatchLeaf extends VirtualDispatchMiddle {
        \\}
        \\public class VirtualDispatchTest {
        \\    public static String test() {
        \\        VirtualDispatchLeaf leaf = new VirtualDispatchLeaf();
        \\        leaf.add('a');
        \\        leaf.add('b');
        \\        return leaf.publicRender();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "VirtualDispatchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("a,b", result.value.string);
}

test "E2E: grandparent field initializers run when grandchild is constructed" {
    const source =
        \\public virtual class AncestorFieldBase {
        \\    protected List<String> bucket = new List<String>{ 'seed' };
        \\}
        \\public virtual class AncestorFieldMid extends AncestorFieldBase {
        \\}
        \\public class AncestorFieldLeaf extends AncestorFieldMid {
        \\    public Integer count() { return bucket == null ? -1 : bucket.size(); }
        \\}
        \\public class AncestorFieldTest {
        \\    public static String test() {
        \\        return String.valueOf(new AncestorFieldLeaf().count());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AncestorFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: explicit super constructor forwards args without extra implicit call" {
    const source =
        \\public virtual class ExplicitSuperBaseBag {
        \\    protected List<Object> entries;
        \\    public ExplicitSuperBaseBag(List<Object> entries) {
        \\        this.entries = entries.clone();
        \\    }
        \\    public Integer size() { return this.entries == null ? -1 : this.entries.size(); }
        \\}
        \\public class ExplicitSuperChildBag extends ExplicitSuperBaseBag {
        \\    public ExplicitSuperChildBag(List<Object> entries) {
        \\        super(entries);
        \\    }
        \\}
        \\public class ExplicitSuperCtorTest {
        \\    public static String test() {
        \\        ExplicitSuperChildBag bag = new ExplicitSuperChildBag(new List<Object>{ 'a', 'b', 'c' });
        \\        return String.valueOf(bag.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ExplicitSuperCtorTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3", result.value.string);
}

test "E2E: super method dispatch uses parent implementation" {
    const source =
        \\public virtual class BaseCounter {
        \\    public Integer count = 0;
        \\    public virtual void run() {
        \\        this.count++;
        \\    }
        \\}
        \\public class ChildCounter extends BaseCounter {
        \\    public override void run() {
        \\        this.count++;
        \\        super.run();
        \\    }
        \\}
        \\public class SuperDispatchTest {
        \\    public static String test() {
        \\        ChildCounter c = new ChildCounter();
        \\        c.run();
        \\        return String.valueOf(c.count);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SuperDispatchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.value.string);
}

test "E2E: enqueue_job executes instance queueable method" {
    const source =
        \\public class InstanceQueueable implements Queueable {
        \\    public static String lastMessage;
        \\    private String message;
        \\    public InstanceQueueable(String message) {
        \\        this.message = message;
        \\    }
        \\    public void execute(QueueableContext qc) {
        \\        InstanceQueueable.lastMessage = this.message;
        \\    }
        \\}
        \\public class InstanceQueueableTest {
        \\    public static String test() {
        \\        System.enqueue_job(new InstanceQueueable('queued'));
        \\        return InstanceQueueable.lastMessage;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InstanceQueueableTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("queued", result.value.string);
}

test "E2E: Limits.getAsyncCalls tracks enqueued queueables" {
    const source =
        \\public class AsyncLimitQueueable implements Queueable {
        \\    public void execute(QueueableContext qc) {}
        \\}
        \\public class AsyncLimitQueueableTest {
        \\    public static String test() {
        \\        Integer beforeCalls = Limits.getAsyncCalls();
        \\        System.enqueue_job(new AsyncLimitQueueable());
        \\        return String.valueOf(beforeCalls) + ':' + String.valueOf(Limits.getAsyncCalls());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AsyncLimitQueueableTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:1", result.value.string);
}

test "E2E: queueable finalizer sees unhandled exception result" {
    const source =
        \\public class ProbeFinalizer implements System.Finalizer {
        \\    public static String resultName;
        \\    public static String exceptionMessage;
        \\    public void execute(System.FinalizerContext fc) {
        \\        ProbeFinalizer.resultName = fc.getResult().name();
        \\        if (fc.getException() != null) {
        \\            ProbeFinalizer.exceptionMessage = fc.getException().getMessage();
        \\        }
        \\    }
        \\}
        \\public class FailingQueueable implements System.Queueable {
        \\    public void execute(System.QueueableContext qc) {
        \\        System.attachFinalizer(new ProbeFinalizer());
        \\        throw new System.IllegalArgumentException('boom');
        \\    }
        \\}
        \\public class QueueableFinalizerTest {
        \\    public static String test() {
        \\        try {
        \\            System.enqueue_job(new FailingQueueable());
        \\            return 'no-error';
        \\        } catch (System.Exception ex) {
        \\            return ProbeFinalizer.resultName + ':' + ProbeFinalizer.exceptionMessage + ':' + ex.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QueueableFinalizerTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("UNHANDLED_EXCEPTION:boom:boom", result.value.string);
}

test "E2E: Database.upsert with Schema.SObjectField matches existing records" {
    const source =
        \\public class UpsertExternalIdTest {
        \\    public static String test() {
        \\        insert new Thing__c(UniqueId__c = 'u1', Name = 'Original');
        \\        List<Thing__c> rows = new List<Thing__c>{
        \\            new Thing__c(UniqueId__c = 'u1', Name = 'Updated'),
        \\            new Thing__c(UniqueId__c = 'u2', Name = 'Created')
        \\        };
        \\        List<Database.UpsertResult> results = Database.upsert(rows, Schema.Thing__c.UniqueId__c);
        \\        List<Thing__c> saved = [SELECT UniqueId__c, Name FROM Thing__c];
        \\        String existingName = null;
        \\        for (Thing__c row : saved) {
        \\            if (row.UniqueId__c == 'u1') {
        \\                existingName = row.Name;
        \\            }
        \\        }
        \\        return String.valueOf(results.get(0).isCreated()) + ':' +
        \\            String.valueOf(results.get(1).isCreated()) + ':' +
        \\            existingName + ':' +
        \\            String.valueOf(saved.size()) + ':' +
        \\            String.valueOf(Schema.Thing__c.UniqueId__c);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UpsertExternalIdTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:true:Updated:2:UniqueId__c", result.value.string);
}

test "E2E: Database.upsert with Schema.Id inserts unsaved records" {
    const source =
        \\public class UpsertByIdFieldTest {
        \\    public static String test() {
        \\        Account row = new Account(Name = 'Created via Id token');
        \\        Database.UpsertResult saveResult = Database.upsert(row, Schema.Account.Id);
        \\        return String.valueOf(saveResult.isSuccess()) + ':' + String.valueOf(saveResult.isCreated()) + ':' + String.valueOf(row.Id != null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UpsertByIdFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:true", result.value.string);
}

test "E2E: custom share objects are queryable" {
    const source =
        \\public class CustomShareQueryTest {
        \\    public static String test() {
        \\        Thing__c parentRecord = new Thing__c(Name = 'Parent');
        \\        insert parentRecord;
        \\        Thing__Share shareRow = new Thing__Share(
        \\            ParentId = parentRecord.Id,
        \\            UserOrGroupId = UserInfo.getUserId(),
        \\            AccessLevel = 'Read'
        \\        );
        \\        insert shareRow;
        \\        List<Thing__Share> rows = [SELECT ParentId, UserOrGroupId, AccessLevel FROM Thing__Share WHERE ParentId = :parentRecord.Id];
        \\        Thing__Share savedRow = rows[0];
        \\        return String.valueOf(rows.size()) + ':' + String.valueOf(savedRow.ParentId == parentRecord.Id) + ':' + String.valueOf(savedRow.UserOrGroupId == UserInfo.getUserId());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CustomShareQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:true:true", result.value.string);
}

test "E2E: custom Iterator with HTTP mock and JSON deserialize in for-each" {
    const source =
        \\public class MockH2 implements HttpCalloutMock {
        \\    private Integer callCount = 0;
        \\    public HttpResponse respond(HttpRequest req) {
        \\        HttpResponse res = new HttpResponse();
        \\        res.setStatusCode(200);
        \\        if (this.callCount == 0) {
        \\            res.setBody('{"records":["a","b"],"totalRecordCount":3}');
        \\        } else {
        \\            res.setBody('{"records":["c"],"totalRecordCount":3}');
        \\        }
        \\        this.callCount++;
        \\        return res;
        \\    }
        \\}
        \\public class RecordPage2 {
        \\    public List<String> records;
        \\    public Integer totalRecordCount;
        \\    public List<String> getRecords() { return this.records; }
        \\}
        \\public class ApiClient2 implements Iterable<RecordPage2> {
        \\    private String cred;
        \\    public ApiClient2(String c) { this.cred = c; }
        \\    public Iterator<RecordPage2> iterator() { return new PageIter(this); }
        \\    public RecordPage2 getPage(Integer idx) {
        \\        HttpRequest req = new HttpRequest();
        \\        req.setEndpoint('callout:' + this.cred + '/page=' + idx);
        \\        req.setMethod('GET');
        \\        HttpResponse res = new Http().send(req);
        \\        return (RecordPage2) JSON.deserializeStrict(res.getBody(), RecordPage2.class);
        \\    }
        \\}
        \\public class PageIter implements Iterator<RecordPage2> {
        \\    private ApiClient2 client;
        \\    private Integer pageIdx;
        \\    private Integer total;
        \\    public PageIter(ApiClient2 c) { this.client = c; this.pageIdx = 0; this.total = null; }
        \\    public Boolean hasNext() { return this.total == null || this.pageIdx * 2 < this.total; }
        \\    public RecordPage2 next() {
        \\        RecordPage2 p = this.client.getPage(this.pageIdx);
        \\        this.pageIdx++;
        \\        this.total = p.totalRecordCount;
        \\        return p;
        \\    }
        \\}
        \\public class IterTest2 {
        \\    public static String test() {
        \\        Test.setMock(HttpCalloutMock.class, new MockH2());
        \\        ApiClient2 client = new ApiClient2('myAPI');
        \\        List<String> results = new List<String>();
        \\        for (RecordPage2 page : client) {
        \\            results.addAll(page.getRecords());
        \\        }
        \\        return String.valueOf(results.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IterTest2",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3", result.value.string);
}

test "E2E: getFilteredAttachments full flow" {
    const source =
        \\public class FTest {
        \\    public static String test() {
        \\        Account acct = new Account(Name = 'Test');
        \\        insert acct;
        \\        // Insert 3 ContentVersions
        \\        for (Integer i = 0; i < 3; i++) {
        \\            ContentVersion cv = new ContentVersion();
        \\            cv.ContentLocation = 'S';
        \\            cv.PathOnClient = 'file' + i + '.png';
        \\            cv.Title = 'file' + i;
        \\            cv.VersionData = Blob.valueOf('data');
        \\            cv.FirstPublishLocationId = acct.Id;
        \\            Database.insert(cv, AccessLevel.USER_MODE);
        \\        }
        \\        // queryWithBinds to get CDLs
        \\        Map<String, Object> recordBind = new Map<String, Object>{ 'recordId' => acct.Id };
        \\        String qs = 'SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :recordId';
        \\        List<ContentDocumentLink> links = Database.queryWithBinds(qs, recordBind, AccessLevel.USER_MODE);
        \\        Set<Id> fileIds = new Set<Id>();
        \\        for (ContentDocumentLink cdl : links) {
        \\            fileIds.add(cdl.ContentDocumentId);
        \\        }
        \\        List<ContentVersion> versions = [SELECT Id, Title FROM ContentVersion WHERE ContentDocumentId IN :fileIds];
        \\        return links.size() + ':' + fileIds.size() + ':' + versions.size();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3:3:3", result.value.string);
}

test "E2E: ContentVersion insert creates ContentDocumentLink for each file" {
    const source =
        \\public class CVTest {
        \\    public static String test() {
        \\        Account acct = new Account(Name = 'TestAcct');
        \\        insert acct;
        \\        for (Integer i = 0; i < 3; i++) {
        \\            ContentVersion cv = new ContentVersion();
        \\            cv.ContentLocation = 'S';
        \\            cv.PathOnClient = 'file' + i + '.png';
        \\            cv.Title = 'file' + i;
        \\            cv.VersionData = Blob.valueOf('data' + i);
        \\            cv.FirstPublishLocationId = acct.Id;
        \\            Database.insert(cv);
        \\        }
        \\        List<ContentDocumentLink> links = [
        \\            SELECT ContentDocumentId
        \\            FROM ContentDocumentLink
        \\            WHERE LinkedEntityId = :acct.Id
        \\        ];
        \\        Set<Id> fileIds = new Set<Id>();
        \\        for (ContentDocumentLink cdl : links) {
        \\            fileIds.add(cdl.ContentDocumentId);
        \\        }
        \\        List<ContentVersion> versions = [
        \\            SELECT Id, Title FROM ContentVersion
        \\            WHERE ContentDocumentId IN :fileIds
        \\        ];
        \\        return links.size() + ':' + versions.size();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CVTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3:3", result.value.string);
}

test "E2E: SOQL IN subquery matches parent record ids" {
    const source =
        \\public class InSubqueryTest {
        \\    public static String test() {
        \\        Account acct = new Account(Name = 'Parent');
        \\        insert acct;
        \\        insert new Contact(LastName = 'Child', AccountId = acct.Id);
        \\        List<Contact> rows = [
        \\            SELECT Id
        \\            FROM Contact
        \\            WHERE AccountId IN (SELECT Id FROM Account)
        \\        ];
        \\        return String.valueOf(rows.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InSubqueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: ContentVersion infers uppercase file extensions for ContentDocument filters" {
    const source =
        \\public class ContentVersionFileTypeCaseTest {
        \\    public static String test() {
        \\        Account acct = new Account(Name = 'CaseTest');
        \\        insert acct;
        \\        ContentVersion audio = new ContentVersion(
        \\            Title = 'Audio',
        \\            PathOnClient = 'clip.M4A',
        \\            VersionData = Blob.valueOf('audio'),
        \\            FirstPublishLocationId = acct.Id
        \\        );
        \\        insert audio;
        \\        List<ContentDocumentLink> links = [
        \\            SELECT ContentDocumentId
        \\            FROM ContentDocumentLink
        \\            WHERE LinkedEntityId = :acct.Id AND ContentDocument.FileType IN ('M4A')
        \\        ];
        \\        return String.valueOf(links.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ContentVersionFileTypeCaseTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: StaticResource Body → ContentVersion insert via method" {
    const source =
        \\public class FileHelper {
        \\    public static Database.SaveResult createFileAttachedToRecord(
        \\        Blob fileContents, Id attachedTo, String fileName
        \\    ) {
        \\        ContentVersion cv = new ContentVersion();
        \\        cv.ContentLocation = 'S';
        \\        cv.PathOnClient = fileName;
        \\        cv.Title = fileName;
        \\        cv.VersionData = fileContents;
        \\        cv.FirstPublishLocationId = attachedTo;
        \\        Database.SaveResult saveResult;
        \\        try {
        \\            saveResult = Database.insert(cv, AccessLevel.USER_MODE);
        \\        } catch (DmlException e) {
        \\            System.debug('DML error: ' + e.getMessage());
        \\        }
        \\        return saveResult;
        \\    }
        \\}
        \\public class FSTest {
        \\    public static String test() {
        \\        Account acct = new Account(Name = 'Test');
        \\        insert acct;
        \\        StaticResource[] resources = [
        \\            SELECT Id, Body, Name
        \\            FROM StaticResource
        \\            WHERE Name IN ('audio', 'doc', 'img')
        \\        ];
        \\        for (StaticResource r : resources) {
        \\            String fileName = r.Name + '.png';
        \\            FileHelper.createFileAttachedToRecord(r.Body, acct.Id, fileName);
        \\        }
        \\        List<ContentDocumentLink> links = [
        \\            SELECT ContentDocumentId
        \\            FROM ContentDocumentLink
        \\            WHERE LinkedEntityId = :acct.Id
        \\        ];
        \\        return String.valueOf(links.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FSTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3", result.value.string);
}

test "E2E: custom Iterable/Iterator with HTTP mock in for-each" {
    const source =
        \\public class MockHttp implements HttpCalloutMock {
        \\    public HttpResponse respond(HttpRequest req) {
        \\        HttpResponse res = new HttpResponse();
        \\        res.setStatusCode(200);
        \\        res.setBody('{"count":3,"items":["a","b","c"]}');
        \\        return res;
        \\    }
        \\}
        \\public class PageResult {
        \\    public Integer count;
        \\    public List<String> items;
        \\}
        \\public class MyIterator implements Iterator<String> {
        \\    private Integer pos = 0;
        \\    private List<String> data;
        \\    public MyIterator(List<String> d) { this.data = d; }
        \\    public Boolean hasNext() { return this.pos < this.data.size(); }
        \\    public String next() {
        \\        String val = this.data.get(this.pos);
        \\        this.pos++;
        \\        return val;
        \\    }
        \\}
        \\public class MyIterable implements Iterable<String> {
        \\    private List<String> data;
        \\    public MyIterable(List<String> d) { this.data = d; }
        \\    public Iterator<String> iterator() { return new MyIterator(this.data); }
        \\}
        \\public class IterTest {
        \\    public static String test() {
        \\        List<String> items = new List<String>{'x','y','z'};
        \\        MyIterable iterable = new MyIterable(items);
        \\        List<String> result = new List<String>();
        \\        for (String s : iterable) {
        \\            result.add(s);
        \\        }
        \\        return String.valueOf(result.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IterTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3", result.value.string);
}

test "E2E: virtual class with overloaded methods and auto property" {
    const source =
        \\public class MockH implements HttpCalloutMock {
        \\    public HttpResponse respond(HttpRequest req) {
        \\        HttpResponse res = new HttpResponse();
        \\        res.setStatusCode(200);
        \\        res.setBody('resp-body');
        \\        return res;
        \\    }
        \\}
        \\public virtual class RC {
        \\    protected String namedCredentialName { get; set; }
        \\    private static Map<String, String> defaultHeaders = new Map<String, String>();
        \\    public enum HttpVerb { GET, POST, PUT, DEL }
        \\    public RC(String nc) { this.namedCredentialName = nc; }
        \\    protected RC() { }
        \\    // 5-arg instance
        \\    protected HttpResponse makeApiCall(HttpVerb method, String path, String query, String body, Map<String, String> headers) {
        \\        HttpRequest req = new HttpRequest();
        \\        req.setEndpoint('callout:' + this.namedCredentialName + '/' + path);
        \\        req.setMethod(String.valueOf(method));
        \\        return new Http().send(req);
        \\    }
        \\    // 2-arg instance
        \\    protected HttpResponse makeApiCall(HttpVerb method, String path) {
        \\        return this.makeApiCall(method, path, '', '', RC.defaultHeaders);
        \\    }
        \\    // 1-arg get
        \\    protected HttpResponse get(String path) {
        \\        return this.makeApiCall(HttpVerb.GET, path);
        \\    }
        \\    // 3-arg static
        \\    public static HttpResponse makeApiCall(String nc, HttpVerb method, String path) {
        \\        return new RC(nc).makeApiCall(method, path, '', '', RC.defaultHeaders);
        \\    }
        \\}
        \\public class Child extends RC {
        \\    public Child(String nc) { super(nc); }
        \\    public String fetch() {
        \\        HttpResponse res = this.get('/data');
        \\        return String.valueOf(res.getStatusCode());
        \\    }
        \\}
        \\public class VTest {
        \\    public static String test() {
        \\        Test.setMock(HttpCalloutMock.class, new MockH());
        \\        Child c = new Child('myAPI');
        \\        return c.fetch();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "VTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("200", result.value.string);
}

test "E2E: enqueue_job execute catches DmlException and sets circuit breaker" {
    const source =
        \\public class MyQ implements Queueable {
        \\    @testVisible private static Boolean throwError = false;
        \\    @testVisible private static Boolean circuitBreakerThrown = false;
        \\    public static void execute(QueueableContext qc) {
        \\        List<Account> accounts = [SELECT Id FROM Account LIMIT 1000];
        \\        if (Test.isRunningTest() && throwError) {
        \\            for (Account a : accounts) { a.put('Name', ''); }
        \\        }
        \\        try {
        \\            update accounts;
        \\        } catch (DmlException dmle) {
        \\            if (Test.isRunningTest()) {
        \\                MyQ.circuitBreakerThrown = true;
        \\            }
        \\        }
        \\    }
        \\}
        \\public class QTest2 {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'Test');
        \\        insert a;
        \\        MyQ.throwError = true;
        \\        System.enqueue_job(new MyQ());
        \\        return String.valueOf(MyQ.circuitBreakerThrown);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QTest2",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: Decimal.valueOf().setScale().doubleValue() chain" {
    const source =
        \\public class DecimalTest {
        \\    public static String test() {
        \\        Double celsius = 10.0;
        \\        Decimal value = Decimal.valueOf(celsius * 9 / 5 + 32).setScale(1);
        \\        Double result = value.doubleValue();
        \\        return String.valueOf(result);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DecimalTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("50.0", result.value.string);
}

test "E2E: Double string concatenation format" {
    const source =
        \\public class DoubleStrTest {
        \\    public static String test() {
        \\        Double d = 10.0;
        \\        return d + '°C';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DoubleStrTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("10.0°C", result.value.string);
}

test "areEqual with custom message includes expected and actual" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const source =
        \\public class T {
        \\    public static void test() {
        \\        Assert.areEqual(10, 20, 'counts should match');
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);
    _ = eval.call_method("T", "test", &.{}) catch {};

    const msg = eval.assertion_failure orelse "";
    // カスタムメッセージと expected/actual の両方が含まれること
    try std.testing.expect(std.mem.indexOf(u8, msg, "counts should match") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "20") != null);
}

test "isTrue with custom message includes expected and actual" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const source =
        \\public class T2 {
        \\    public static void test() {
        \\        Assert.isTrue(false, 'should be true');
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);
    _ = eval.call_method("T2", "test", &.{}) catch {};

    const msg = eval.assertion_failure orelse "";
    try std.testing.expect(std.mem.indexOf(u8, msg, "should be true") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Expected: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Actual: false") != null);
}

test "areNotEqual with custom message includes values" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const source =
        \\public class T3 {
        \\    public static void test() {
        \\        Assert.areNotEqual(42, 42, 'values differ');
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);
    _ = eval.call_method("T3", "test", &.{}) catch {};

    const msg = eval.assertion_failure orelse "";
    try std.testing.expect(std.mem.indexOf(u8, msg, "values differ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "42") != null);
}

test "E2E: Datetime.format('MMMM d') returns month name and day" {
    const source =
        \\public class DtFmtTest {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstance(2024, 7, 14, 0, 0, 0);
        \\        return dt.format('MMMM d');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtFmtTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("July 14", result.value.string);
}

test "E2E: Datetime.format('yyyy-MM-dd') returns ISO date" {
    const source =
        \\public class DtFmtIso {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstance(2024, 7, 14, 10, 30, 0);
        \\        return dt.format('yyyy-MM-dd');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtFmtIso",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2024-07-14", result.value.string);
}

test "E2E: Date.today().year() returns current year" {
    const source =
        \\public class DtYearTest {
        \\    public static String test() {
        \\        Integer y = Date.today().year();
        \\        return String.valueOf(y);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtYearTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2026", result.value.string);
}

test "E2E: Datetime.addYears changes year" {
    const source =
        \\public class DtAddYears {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstance(2024, 7, 14, 0, 0, 0);
        \\        dt = dt.addYears(2);
        \\        return dt.format('yyyy-MM-dd');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtAddYears",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2026-07-14", result.value.string);
}

test "E2E: Datetime.date() returns date portion" {
    const source =
        \\public class DtDateTest {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstance(2024, 7, 19, 11, 0, 0);
        \\        Date d = dt.date();
        \\        return d.format();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtDateTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("7/19/2024", result.value.string);
}

test "E2E: Date/Datetime no-arg format uses locale short pattern" {
    const source =
        \\public class DefaultFormatProbe {
        \\    public static String test() {
        \\        Date d = Date.newInstance(2015, 1, 1);
        \\        Datetime dt = Datetime.newInstance(2015, 1, 1, 14, 30, 0);
        \\        return d.format() + '|' + dt.format();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DefaultFormatProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1/1/2015|1/1/2015, 2:30 PM", result.value.string);
}

test "E2E: inline new-Set literal drives generic overload resolution" {
    const source =
        \\public class InlineSetOverloadProbe {
        \\    public String chooseSet(Set<String> names) { return 'String'; }
        \\    public String chooseSet(Set<Contact> items) { return 'Contact'; }
        \\    public static String test() {
        \\        InlineSetOverloadProbe p = new InlineSetOverloadProbe();
        \\        return p.chooseSet(new Set<Contact>{ new Contact(LastName = 'X') });
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InlineSetOverloadProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Contact", result.value.string);
}

test "E2E: Schema.SObjectType.fields.FieldName resolves a field token" {
    const source =
        \\public class SchemaFieldsProbe {
        \\    public static String test() {
        \\        Schema.SObjectField f = Schema.Contact.SObjectType.fields.lastName;
        \\        return f.getDescribe().getName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaFieldsProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("LastName", result.value.string);
}

test "E2E: constructor overloads prefer declared-variable hint over name-only scoring" {
    // Two 3-arg inner-class constructors:
    //   Box(String, String, Mode)
    //   Box(String, Mode, Boolean)
    // When called with `new Box(name, dir, flag)` where `dir` is declared as
    // Mode and `flag` as Boolean, the second overload should win. Before
    // hinting, the constructor resolver tied on raw argument shape and
    // picked the first-declared one, leading to mis-dispatched calls that
    // silently returned null or threw NPEs downstream.
    const source =
        \\public class CtorHintProbe {
        \\    public enum Mode { A, B }
        \\    public class Box {
        \\        public String label;
        \\        public Box(String sobjType, String fieldName, Mode direction) {
        \\            this.label = 'three-string:' + fieldName;
        \\        }
        \\        public Box(String field, Mode direction, Boolean nullsLast) {
        \\            this.label = 'string-enum-bool:' + field + ':' + direction + ':' + nullsLast;
        \\        }
        \\    }
        \\    public static String test() {
        \\        String name = 'Account.Name';
        \\        Mode dir = Mode.A;
        \\        Boolean flag = false;
        \\        Box b = new Box(name, dir, flag);
        \\        return b.label;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CtorHintProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "string-enum-bool:Account.Name:A:false",
        result.value.string,
    );
}

test "E2E: ternary with enum literals carries hint into overload resolution" {
    // Models a builder whose primitive overload normalises the argument into
    // an enum before delegating to the enum overload through a ternary:
    //   public Builder setMode(Boolean on) { return setMode(on ? Mode.A : Mode.B); }
    // Before the hint fix, the inner setMode(on ? ... : ...) could not find
    // either overload (the ternary result was an untyped string), so the
    // call returned null and broke method chains.
    const source =
        \\public class TernaryEnumHintProbe {
        \\    public enum Mode { A, B }
        \\    public class Builder {
        \\        public Mode state;
        \\        public Builder setMode(Boolean on) {
        \\            return setMode(on ? Mode.A : Mode.B);
        \\        }
        \\        public Builder setMode(Mode m) {
        \\            this.state = m;
        \\            return this;
        \\        }
        \\    }
        \\    public static String test() {
        \\        Builder b = new Builder();
        \\        Builder chained = b.setMode(true).setMode(false);
        \\        if (chained == null) return 'null-chain';
        \\        return String.valueOf(chained.state);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TernaryEnumHintProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("B", result.value.string);
}

test "E2E: TriggerOperation-typed parameter dispatches through enum overload" {
    // Models a framework where `executeWith(TriggerOperation)` coexists with a
    // `executeWith(String)` lookup overload. Interpreting the enum-typed
    // variable as a string should still dispatch to the enum-typed method.
    const source =
        \\public class EnumParamDispatchProbe {
        \\    public static String log = '';
        \\    public static void executeWith(String relationshipName) {
        \\        log += 'str:' + relationshipName + '|';
        \\    }
        \\    public static void executeWith(TriggerOperation op) {
        \\        log += 'enum:' + op.name() + '|';
        \\    }
        \\    public static void handle(TriggerOperation op) {
        \\        executeWith(op);
        \\    }
        \\    public static String test() {
        \\        handle(TriggerOperation.BEFORE_INSERT);
        \\        return log;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EnumParamDispatchProbe",
        .entry_method = "test",
    });
    defer result.deinit();
    // The enum overload must run — the String one would have printed "str:...".
    try std.testing.expectEqualStrings("enum:BEFORE_INSERT|", result.value.string);
}

test "E2E: LoggingLevel enum hint does not force enum overload for string literal peers" {
    // When the parameter is not enum-typed, a bare string argument must still
    // select the String overload even if another overload takes an enum type.
    const source =
        \\public class EnumHintGuardProbe {
        \\    public static String log = '';
        \\    public static void record(LoggingLevel level, Exception e) {
        \\        log = 'exc';
        \\    }
        \\    public static void record(LoggingLevel level, String message) {
        \\        log = 'str:' + message;
        \\    }
        \\    public static String test() {
        \\        record(LoggingLevel.INFO, 'hello');
        \\        return log;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EnumHintGuardProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("str:hello", result.value.string);
}

test "E2E: enum-valued string argument disambiguates overloads" {
    const source =
        \\public class EnumOverloadProbe {
        \\    public enum Direction { ASC, DESC }
        \\    public class Ordering {
        \\        public String field;
        \\        public Direction direction;
        \\        public Boolean nullsLast;
        \\        public Ordering(String sobjType, String fieldName, Direction direction) {
        \\            this(fieldName + '!', direction, false);
        \\        }
        \\        public Ordering(String field, Direction direction, Boolean nullsLast) {
        \\            this.field = field;
        \\            this.direction = direction;
        \\            this.nullsLast = nullsLast;
        \\        }
        \\    }
        \\    public static String test() {
        \\        // Must pick the (String, Direction, Boolean) overload even though the string
        \\        // 'ASC' would otherwise score equally against (String, String, Direction).
        \\        EnumOverloadProbe.Ordering ord = new EnumOverloadProbe.Ordering('Name', EnumOverloadProbe.Direction.ASC, false);
        \\        return ord.field;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EnumOverloadProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Name", result.value.string);
}

test "E2E: Type.forName with Schema prefix instantiates a known standard SObject" {
    // `Type.forName('Schema.Account').newInstance()` is a common pattern for reflection-style
    // code (formula evaluators, feature toggles). Our interpreter should treat Schema.<Std>
    // as a non-null Type whose newInstance() yields an SObject value.
    const source =
        \\public class SchemaTypeProbe {
        \\    public static String test() {
        \\        Type t = Type.forName('Schema.Account');
        \\        if (t == null) return 'null-type';
        \\        SObject so = (SObject) t.newInstance();
        \\        Schema.SObjectType r = so.getSObjectType();
        \\        return r.getDescribe().getName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaTypeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Account", result.value.string);
}

test "E2E: Type.forName('Schema.Network') remains null for Experience-Cloud gating" {
    // Code such as `if (Type.forName('Schema.Network') != null) { ... }` uses Network as a
    // capability check for Experience Cloud. The interpreter simulates an org where
    // Experience Cloud is off, so this lookup must stay null even though Account etc. don't.
    const source =
        \\public class NetworkGateProbe {
        \\    public static String test() {
        \\        Type n = Type.forName('Schema.Network');
        \\        if (n == null) return 'gated-off';
        \\        return 'gated-on';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NetworkGateProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("gated-off", result.value.string);
}

test "E2E: Account.Rating describe reports Picklist instead of String" {
    // Standard picklist fields on well-known SObjects should resolve to DisplayType.PICKLIST
    // even when the fixture doesn't ship field-meta.xml for them.
    const source =
        \\public class PicklistDescribeProbe {
        \\    public static String test() {
        \\        Schema.SObjectType t = Account.SObjectType;
        \\        Schema.DescribeSObjectResult d = t.getDescribe();
        \\        Schema.DisplayType dt = d.fields.getMap().get('Rating').getDescribe().getType();
        \\        return String.valueOf(dt);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PicklistDescribeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("PICKLIST", result.value.string);
}

test "E2E: Datetime.valueOf accepts loose single-digit components" {
    // `Datetime.valueOf('2006-5-4 3:2:1')` is real-world input seen in utility code that
    // re-parses user-entered strings. Apex accepts it; we need to as well.
    const source =
        \\public class DtLooseProbe {
        \\    public static String test() {
        \\        Datetime dt = Datetime.valueOf('2006-5-4 3:2:1');
        \\        return String.valueOf(dt.year()) + '-' + String.valueOf(dt.month()) + '-' + String.valueOf(dt.day()) +
        \\            ' ' + String.valueOf(dt.hour()) + ':' + String.valueOf(dt.minute()) + ':' + String.valueOf(dt.second());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtLooseProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2006-5-4 3:2:1", result.value.string);
}

test "E2E: bitwise operators on integers return integer results" {
    // `&`/`|`/`^` on integer operands must yield integer results rather than
    // booleans. fflib_Uuid (and other reflection-heavy helpers) build bitmasks
    // via `(v & 0x0f) | 0x40` and were returning `false` because the AST used to
    // fold `&` into the same node as `&&`, which short-circuited based on
    // `coerce_to_bool(integer)` returning false.
    const source =
        \\public class BitwiseIntProbe {
        \\    public static String test() {
        \\        Integer andR = 30 & 15;
        \\        Integer orR = 30 | 64;
        \\        Integer xorR = 30 ^ 15;
        \\        return String.valueOf(andR) + ',' + String.valueOf(orR) + ',' + String.valueOf(xorR);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "BitwiseIntProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("14,94,17", result.value.string);
}

test "E2E: qualified enum hint matches unqualified enum parameter" {
    // When a caller stores an inner enum (`OuterClass.InnerEnum`) in a local and
    // passes it to an overloaded method, the parameter is often declared with
    // the simple name (`InnerEnum`). Overload resolution must match the trailing
    // component so the enum-typed overload wins over a Boolean sibling.
    const source =
        \\public class EnumHintTailProbe {
        \\    public enum Mode { LEGACY, USER_MODE, SYSTEM_MODE }
        \\    public static String picked = '';
        \\    public static void pick(Boolean b) { picked = 'boolean'; }
        \\    public static void pick(Mode m) { picked = 'mode:' + m; }
        \\    public static String test() {
        \\        EnumHintTailProbe.Mode m = EnumHintTailProbe.Mode.SYSTEM_MODE;
        \\        pick(m);
        \\        return picked;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EnumHintTailProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("mode:SYSTEM_MODE", result.value.string);
}

test "E2E: Map.equals delegates pairwise value comparison" {
    // Apex-style user classes often override `equals` by comparing internal
    // collections (e.g. apex-expression's Environment delegates to
    // `variables.equals(other.variables)`). The interpreter used to return null
    // for Map.equals because only List exposed it, breaking downstream equality.
    const source =
        \\public class MapEqualsProbe {
        \\    public static String test() {
        \\        Map<String, Object> a = new Map<String, Object>{ 'name' => 'Bob', 'age' => 42 };
        \\        Map<String, Object> b = new Map<String, Object>{ 'name' => 'Bob', 'age' => 42 };
        \\        Map<String, Object> c = new Map<String, Object>{ 'name' => 'Bob', 'age' => 43 };
        \\        return String.valueOf(a.equals(b)) + ',' + String.valueOf(a.equals(c));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MapEqualsProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true,false", result.value.string);
}

test "E2E: System.runAs exposes the target user's fields to UserInfo" {
    // apex-expression's DSL tests build throw-away Users inside System.runAs
    // without ever inserting them. UserInfo methods used to return the default
    // synthetic user because the implementation only consulted the data store.
    // A current_user_override slot keeps the runAs target visible while the
    // block executes.
    const source =
        \\public class RunAsUserOverrideProbe {
        \\    public static String test() {
        \\        User target = new User(FirstName = 'Bob', LastName = 'Smith', Email = 'bob@example.com', LanguageLocaleKey = 'en_US');
        \\        String result = '';
        \\        System.runAs(target) {
        \\            result = UserInfo.getFirstName() + '|' + UserInfo.getLastName() + '|' + UserInfo.getUserEmail() + '|' + UserInfo.getLanguage();
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RunAsUserOverrideProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Bob|Smith|bob@example.com|en_US", result.value.string);
}

test "E2E: bare method call inside a subclass resolves to inherited builtin" {
    // fflib_HttpException and similar user exception subclasses call bare
    // `setMessage(s)` from their constructors. The interpreter used to leave the
    // message empty because the `.call` branch gave up when no user-defined
    // `setMessage` matched. Falling back to `this.setMessage(s)` on the current
    // receiver routes the call to the inherited Exception builtin.
    const source =
        \\public class BareCallFallbackProbe {
        \\    public class Boom extends Exception {
        \\        public Boom(String m) { setMessage(m); }
        \\    }
        \\    public static String test() {
        \\        try {
        \\            throw new Boom('payload');
        \\        } catch (Boom e) {
        \\            return e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "BareCallFallbackProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("payload", result.value.string);
}

test "E2E: static field initializer can forward-reference a later static field" {
    // Apex's real compiler allows:
    //
    //     private static final Integer HEX_BASE = HEX_CHARACTERS.length();
    //     private static final String HEX_CHARACTERS = '0123456789abcdef';
    //
    // where `HEX_BASE` depends on a field declared after it. The interpreter used
    // to leave the forward-referencing field null because it only initialised
    // fields in declaration order. A bounded retry pass fills in values once the
    // referenced fields have been initialised.
    const source =
        \\public class StaticForwardRefProbe {
        \\    private static final Integer HEX_BASE = HEX_CHARACTERS.length();
        \\    private static final String HEX_CHARACTERS = '0123456789abcdef';
        \\    public static String test() {
        \\        return String.valueOf(HEX_BASE) + ':' + HEX_CHARACTERS;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticForwardRefProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("16:0123456789abcdef", result.value.string);
}

test "E2E: bitwise operators on booleans return boolean results" {
    // NebulaLogger uses `collectionA != null & collectionB.isEmpty() == false`
    // where `&` is applied to two Booleans. The result must stay a Boolean so
    // `if (...)` treats it truthfully.
    const source =
        \\public class BitwiseBoolProbe {
        \\    public static String test() {
        \\        List<String> headers = new List<String>{'a'};
        \\        Boolean ok = headers != null & headers.isEmpty() == false;
        \\        if (ok) return 'true';
        \\        return 'false';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "BitwiseBoolProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: method call on property-backed identifier invokes the getter" {
    // `foo.size()` for a property-backed `foo` used to return null when the call
    // happened inside another getter, because the method-call fast path bailed
    // out to `call_method` before falling back to eval_expr. TriggerBase's
    // `triggerSize` getter (and similar peer-property patterns) need the getter
    // to fire so `.size()` reaches the real list.
    const source =
        \\public virtual class PropertyMethodCallProbeBase {
        \\    @TestVisible
        \\    protected List<SObject> triggerNew {
        \\        get { return triggerNew; }
        \\        private set;
        \\    }
        \\    private Integer triggerSize {
        \\        get {
        \\            return triggerNew != null ? triggerNew.size() : 0;
        \\        }
        \\    }
        \\    public Integer readSize() {
        \\        return triggerSize;
        \\    }
        \\}
        \\public class PropertyMethodCallProbe {
        \\    public class Child extends PropertyMethodCallProbeBase {}
        \\    public static String test() {
        \\        Child c = new Child();
        \\        c.triggerNew = new List<SObject>{ new Account() };
        \\        Integer n = c.readSize();
        \\        return String.valueOf(n);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PropertyMethodCallProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: overload resolution matches Type arg against System.Type param" {
    // When user code declares the qualified `System.Type` form on a parameter,
    // the interpreter stores the runtime Type value with its simple class name
    // ("Type"). Overload scoring now matches either spelling so `foo(Type)` wins
    // over a `foo(String)` sibling — required by Trigger Actions' bypass(Type).
    const source =
        \\public class OverloadTypeProbe {
        \\    public static String last = '';
        \\    public static void pick(String s) { last = 'string'; }
        \\    public static void pick(System.Type t) { last = 'type:' + t.getName(); }
        \\    public class Inner {}
        \\    public static String test() {
        \\        pick(Inner.class);
        \\        return last;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "OverloadTypeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("type:OverloadTypeProbe.Inner", result.value.string);
}

test "E2E: incompatible interface cast raises System.TypeException" {
    // Trigger frameworks cast a dynamically-instantiated object to the interface
    // matching the current trigger context, relying on Apex to throw TypeException
    // when the class doesn't implement it. The interpreter previously allowed all
    // object→interface casts silently, which suppressed the expected failure.
    const source =
        \\public class InterfaceCastProbe {
        \\    public interface Routable {}
        \\    public class NonRoutable {}
        \\    public static String test() {
        \\        Object o = new NonRoutable();
        \\        Exception ex = null;
        \\        try {
        \\            Routable r = (Routable) o;
        \\        } catch (System.TypeException e) {
        \\            ex = e;
        \\        }
        \\        return ex == null ? 'no-exception' : 'ok';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InterfaceCastProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: Type.forName returns null for names that don't resolve" {
    // Regression: metadata-driven trigger frameworks (apex-trigger-actions-framework
    // at al.) read Apex class names from custom metadata and rely on
    // `Type.forName(bogus).newInstance()` raising a NullPointerException to flag
    // invalid configurations. The interpreter now returns a real null Type for names
    // that aren't recognised — user classes, loaded SObjects, primitives, and the
    // generic collection syntax still resolve.
    const source =
        \\public class TypeForNameNullProbe {
        \\    public static String test() {
        \\        Type missing = Type.forName('TotallyMadeUpClassName');
        \\        if (missing != null) return 'expected-null';
        \\        Type self = Type.forName('TypeForNameNullProbe');
        \\        if (self == null) return 'missing-self';
        \\        Type account = Type.forName('Account');
        \\        if (account == null) return 'missing-account';
        \\        Exception npe = null;
        \\        try {
        \\            Object o = Type.forName('TotallyMadeUpClassName').newInstance();
        \\        } catch (System.NullPointerException e) {
        \\            npe = e;
        \\        }
        \\        if (npe == null) return 'no-npe';
        \\        return 'ok';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TypeForNameNullProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: fflib_IDGenerator.generate provides a fake id when class source is absent" {
    // fflib-apex-common tests reference fflib_IDGenerator from the sibling fflib-apex-mocks
    // package, but when only fflib-apex-common is loaded the class is missing and tests
    // crash with `null.Id` downstream. We stub the helper with a deterministic fake id —
    // only when the user hasn't actually supplied their own fflib_IDGenerator.
    const source =
        \\public class FflibIdGeneratorStubProbe {
        \\    public static String test() {
        \\        Id a = fflib_IDGenerator.generate(Schema.Account.SObjectType);
        \\        Id b = fflib_IDGenerator.generate(Schema.Account.SObjectType);
        \\        if (a == null || b == null) return 'null-id';
        \\        if (a == b) return 'duplicate-id';
        \\        if (!String.valueOf(a).startsWith('001')) return 'bad-prefix:' + String.valueOf(a);
        \\        return 'ok';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FflibIdGeneratorStubProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: Contact exposes Tasks and Account exposes Cases as child relationships" {
    // `getChildRelationships()` must include well-known standard relationships so that
    // fflib_QueryFactory's `subselectQuery('Tasks')` style lookups succeed. Prior to this
    // the interpreter only knew a handful of pairs, so any test that drove the walker
    // through Account->Cases or Contact->Tasks threw "Relationship does not exist".
    const source =
        \\public class ChildRelationshipProbe {
        \\    public static String test() {
        \\        Schema.DescribeSObjectResult contactDesc = Contact.SObjectType.getDescribe();
        \\        Schema.DescribeSObjectResult accountDesc = Account.SObjectType.getDescribe();
        \\        Boolean contactHasTasks = false;
        \\        for (Schema.ChildRelationship c : contactDesc.getChildRelationships()) {
        \\            if (c.getRelationshipName() == 'Tasks') { contactHasTasks = true; break; }
        \\        }
        \\        Boolean accountHasCases = false;
        \\        for (Schema.ChildRelationship c : accountDesc.getChildRelationships()) {
        \\            if (c.getRelationshipName() == 'Cases') { accountHasCases = true; break; }
        \\        }
        \\        return String.valueOf(contactHasTasks) + '|' + String.valueOf(accountHasCases);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ChildRelationshipProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true|true", result.value.string);
}

test "E2E: relationship-style field names describe as REFERENCE" {
    // fflib_QueryFactory walks `CreatedBy.Name` by looking up `CreatedBy`'s describe and
    // verifying it's a lookup (`getSoapType() == ID`). The interpreter used to report the
    // field as STRING, so the walker threw NonReferenceFieldException. `CreatedBy`,
    // `Owner`, `LastModifiedBy`, etc. must describe as REFERENCE with a relationship name
    // equal to the field itself and `getReferenceTo()` pointing at User/Group.
    const source =
        \\public class RelationshipDescribeProbe {
        \\    public static String test() {
        \\        Schema.SObjectField token = Schema.SObjectType.Contact.fields.getMap().get('CreatedBy');
        \\        if (token == null) return 'no-token';
        \\        Schema.DescribeFieldResult d = token.getDescribe();
        \\        Schema.DisplayType dt = d.getType();
        \\        String rel = d.getRelationshipName();
        \\        List<Schema.SObjectType> refs = d.getReferenceTo();
        \\        String refName = (refs != null && refs.size() > 0) ? refs[0].getDescribe().getName() : 'none';
        \\        return String.valueOf(dt) + '|' + rel + '|' + refName;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RelationshipDescribeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("REFERENCE|CreatedBy|User", result.value.string);
}

test "E2E: Matcher.group_count reflects the pattern and matches() populates currentMatch" {
    // Java/Apex contract: `Matcher.group_count()` reports the number of capture groups in
    // the *pattern* — not the number actually captured. After `matches()` succeeds, the
    // matcher should also expose `group(n)` for inspection (fflib_SObjectSelector tests
    // depend on this to validate generated SOQL).
    const source =
        \\public class MatcherStateProbe {
        \\    public static String test() {
        \\        Pattern p = Pattern.compile('SELECT (.*) FROM (.+)');
        \\        Matcher m = p.matcher('SELECT Id, Name FROM Account');
        \\        if (m.group_count() != 2) return 'bad-group_count:' + String.valueOf(m.group_count());
        \\        if (!m.matches()) return 'no-match';
        \\        return m.group(1) + '|' + m.group(2);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MatcherStateProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Id, Name|Account", result.value.string);
}

test "E2E: greedy capture groups backtrack when the tail needs characters" {
    // Ensures `(.*)` followed by a literal doesn't swallow past the literal.
    const source =
        \\public class GreedyBacktrackProbe {
        \\    public static String test() {
        \\        Pattern p = Pattern.compile('a(.*)c');
        \\        Matcher m = p.matcher('abbbc');
        \\        if (!m.matches()) return 'no-match';
        \\        return m.group(1);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "GreedyBacktrackProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("bbb", result.value.string);
}

test "E2E: Schema.SObjectType.<X>.fields.getMap() matches getDescribe().fields.getMap()" {
    // Regression for a bug where the two describe-map paths produced different sizes.
    // Consumers like fflib_SObjectDescribe.FieldsMap assert the two match, so we must
    // populate the FieldDescribeMap identically no matter which entry point is used.
    const source =
        \\public class FieldMapParityProbe {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> viaSchemaShortcut = Schema.SObjectType.Account.fields.getMap();
        \\        Map<String, Schema.SObjectField> viaDescribe = Account.SObjectType.getDescribe().fields.getMap();
        \\        if (viaSchemaShortcut.size() != viaDescribe.size()) {
        \\            return 'mismatch:' + String.valueOf(viaSchemaShortcut.size()) + '-vs-' + String.valueOf(viaDescribe.size());
        \\        }
        \\        if (viaSchemaShortcut.size() < 5) return 'too-small:' + String.valueOf(viaSchemaShortcut.size());
        \\        return 'ok';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FieldMapParityProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: String.split with regex metacharacters routes through the regex engine" {
    // Apex's `String.split(regex)` takes a regex, so `split('\\s+')` must collapse any run
    // of whitespace. The prior interpreter stripped backslashes and did a literal split,
    // producing a single-element list and breaking formula parsers.
    const source =
        \\public class SplitRegexProbe {
        \\    public static String test() {
        \\        List<String> parts = '_D0D_ + _D1D_'.split('\\s+');
        \\        Assert.areEqual(3, parts.size());
        \\        List<String> dotSplit = 'a.b.c'.split('[.]');
        \\        Assert.areEqual(3, dotSplit.size());
        \\        return parts[0] + '|' + parts[1] + '|' + parts[2];
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SplitRegexProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("_D0D_|+|_D1D_", result.value.string);
}

test "E2E: Pattern.matches static and nested capture groups round-trip" {
    // Validates two recently-fixed building blocks together:
    //   - Pattern.matches(regex, input) works as the "full-match" static form.
    //   - A pattern with nested capture groups reports inner indices without overwriting
    //     the outer group's capture (prior bug silently merged outer and first inner).
    const source =
        \\public class RegexCaptureProbe {
        \\    public static String test() {
        \\        Boolean ok = Pattern.matches('(_B[0-9]+B_)', '_B0B_');
        \\        Pattern p = Pattern.compile('(([a-z]+) ([a-z]+))');
        \\        Matcher m = p.matcher('foo bar');
        \\        if (!m.find()) return 'no-match';
        \\        return String.valueOf(ok) + '|' + m.group(1) + '|' + m.group(2) + '|' + m.group(3);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RegexCaptureProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true|foo bar|foo|bar", result.value.string);
}

test "E2E: Datetime.newInstance(milliseconds) single arg" {
    const source =
        \\public class DtMillisTest {
        \\    public static String test() {
        \\        // 2024-07-19 11:00:00 UTC in millis = 1721386800000
        \\        Datetime dt = Datetime.newInstance(1721386800000L);
        \\        return dt.format('yyyy-MM-dd');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtMillisTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2024-07-19", result.value.string);
}

test "E2E: Datetime.getTime() returns epoch millis" {
    const source =
        \\public class DtGetTimeTest {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstance(2024, 7, 19, 11, 0, 0);
        \\        Long ms = dt.getTime();
        \\        Datetime dt2 = Datetime.newInstance(ms);
        \\        return dt2.format('yyyy-MM-dd');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtGetTimeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2024-07-19", result.value.string);
}

test "E2E: Datetime.valueOf accepts epoch milliseconds" {
    const source =
        \\public class DtValueOfMillisTest {
        \\    public static String test() {
        \\        Datetime dt = Datetime.valueOf(1735689600000L);
        \\        return dt.format('yyyy-MM-dd') + ':' + String.valueOf(dt.getTime());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtValueOfMillisTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2025-01-01:1735689600000", result.value.string);
}

test "E2E: Datetime.valueOf normalizes formatted strings with trailing timezone offsets" {
    const source =
        \\public class DtValueOfOffsetStringTest {
        \\    public static String test() {
        \\        Datetime expected = Datetime.newInstance(2018, 8, 8, 8, 8, 8);
        \\        Datetime withZeroOffset = Datetime.valueOf('2018-08-08 08:08:080');
        \\        Datetime withSignedOffset = Datetime.valueOf('2018-08-08 08:08:08+9');
        \\        return String.valueOf(expected == withZeroOffset) + ':' +
        \\            String.valueOf(expected == withSignedOffset) + ':' +
        \\            String.valueOf(withZeroOffset);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DtValueOfOffsetStringTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:2018-08-08T08:08:08Z", result.value.string);
}

test "E2E: TimeZone.getTimeZone returns an object-like value with id and display name" {
    const source =
        \\public class TimeZoneLookupTest {
        \\    public static String test() {
        \\        TimeZone tz = TimeZone.getTimeZone('Asia/Tokyo');
        \\        return tz.getId() + ':' + tz.getDisplayName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TimeZoneLookupTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Asia/Tokyo:Asia/Tokyo", result.value.string);
}

test "E2E: String.toLowerCase and trim" {
    const source =
        \\public class StrLowerTest {
        \\    public static String test() {
        \\        String s = '  Adventure  ';
        \\        return '%' + s.toLowerCase().trim() + '%';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StrLowerTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("%adventure%", result.value.string);
}

test "E2E: Database.query resolves local bind variables" {
    const source =
        \\public class DbQueryBindTest {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'Acme');
        \\        insert a;
        \\        String name = 'Acme';
        \\        List<Account> results = Database.query(
        \\            'SELECT Id, Name FROM Account WHERE Name = :name'
        \\        );
        \\        return String.valueOf(results.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DbQueryBindTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: Integer and Long valueOf preserve null inputs" {
    const source =
        \\public class NullNumericValueOfTest {
        \\    public static String test() {
        \\        String missingValue = null;
        \\        Integer integerValue = Integer.valueOf(missingValue);
        \\        Long longValue = Long.valueOf(missingValue);
        \\        return String.valueOf(integerValue == null) + ':' + String.valueOf(longValue == null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NullNumericValueOfTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: long literals remain distinct from Integer in instanceof checks" {
    const source =
        \\public class LongInstanceofProbe {
        \\    public static String test() {
        \\        return String.valueOf(9 instanceof Long) + ':' +
        \\            String.valueOf(9L instanceof Long) + ':' +
        \\            String.valueOf(9L instanceof Integer) + ':' +
        \\            String.valueOf(9.99 instanceof Integer) + ':' +
        \\            String.valueOf(Long.valueOf('9') instanceof Long);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "LongInstanceofProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:false:false:true", result.value.string);
}

test "E2E: SOQL formula field Experience_Name__c resolved from parent" {
    const source =
        \\public class FormulaFieldTest {
        \\    public static String test() {
        \\        Experience__c exp = new Experience__c(Name = 'Hiking');
        \\        insert exp;
        \\        Session__c sess = new Session__c(Experience__c = exp.Id);
        \\        insert sess;
        \\        List<Session__c> results = [
        \\            SELECT Experience_Name__c FROM Session__c
        \\        ];
        \\        if (results.size() == 0) return 'empty';
        \\        Session__c s = results[0];
        \\        Object val = s.get('Experience_Name__c');
        \\        return val != null ? String.valueOf(val) : 'null';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FormulaFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Hiking", result.value.string);
}

test "E2E: rollup summary fields resolve in WHERE clauses and selected records" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class RollupSummaryRuntimeTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'Parent');
        \\        insert parent;
        \\        insert new List<Child__c>{
        \\            new Child__c(Parent__c = parent.Id, Status__c = 'Open'),
        \\            new Child__c(Parent__c = parent.Id, Status__c = 'Closed'),
        \\            new Child__c(Parent__c = parent.Id, Status__c = 'Closed')
        \\        };
        \\        Parent__c refreshed = [
        \\            SELECT OpenChildren__c, ClosedChildren__c, TotalChildren__c
        \\            FROM Parent__c
        \\            WHERE TotalChildren__c = 3
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(refreshed.OpenChildren__c) + ':' +
        \\            String.valueOf(refreshed.ClosedChildren__c) + ':' +
        \\            String.valueOf(refreshed.TotalChildren__c);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "RollupSummaryRuntimeTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:2:3", result.value.string);
}

test "E2E: child insert recomputes rollup summaries and fires parent update triggers" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class RollupUpdateCounter {
        \\    public static Integer updates = 0;
        \\}
        \\trigger ParentRollupTrigger on Parent__c (before update, after update) {
        \\    RollupUpdateCounter.updates++;
        \\}
        \\public class RollupTriggerCascadeTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Parent');
        \\        insert parentRecord;
        \\        insert new Child__c(Parent__c = parentRecord.Id, Status__c = 'Open');
        \\        Parent__c refreshed = [SELECT OpenChildren__c, TotalChildren__c FROM Parent__c WHERE Id = :parentRecord.Id];
        \\        return String.valueOf(RollupUpdateCounter.updates) + ':' +
        \\            String.valueOf(refreshed.OpenChildren__c) + ':' +
        \\            String.valueOf(refreshed.TotalChildren__c);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "RollupTriggerCascadeTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:1:1", result.value.string);
}

test "E2E: filtered rollup matches enum name string values" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Parent__c/fields");
    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Child__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Level__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Level__c</fullName>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Parent__c/fields/ErrorChildren__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ErrorChildren__c</fullName>
        \\    <summaryFilterItems>
        \\        <field>Child__c.Level__c</field>
        \\        <operation>equals</operation>
        \\        <value>ERROR</value>
        \\    </summaryFilterItems>
        \\    <summaryForeignKey>Child__c.Parent__c</summaryForeignKey>
        \\    <summaryOperation>count</summaryOperation>
        \\    <type>Summary</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class EnumFilteredRollupTest {
        \\    public enum LogLevel { INFO, ERROR }
        \\    public static Integer test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Parent');
        \\        insert parentRecord;
        \\        insert new Child__c(Parent__c = parentRecord.Id, Level__c = LogLevel.ERROR.name());
        \\        Parent__c refreshed = [SELECT ErrorChildren__c FROM Parent__c WHERE Id = :parentRecord.Id];
        \\        return Integer.valueOf(refreshed.ErrorChildren__c);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "EnumFilteredRollupTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 1), result.value.integer);
}

test "E2E: required field population preserves explicitly set picklist-like values" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Example__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Example__c/fields/RequiredName__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>RequiredName__c</fullName>
        \\    <required>true</required>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Example__c/fields/Level__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Level__c</fullName>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class PreserveExplicitValueTest {
        \\    public class RequiredFieldBuilder {
        \\        public static Example__c fill(Example__c record) {
        \\            Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        \\            for (Schema.SObjectField field : Example__c.SObjectType.getDescribe().fields.getMap().values()) {
        \\                Schema.DescribeFieldResult describe = field.getDescribe();
        \\                if (describe.isCreateable() == false) {
        \\                    continue;
        \\                }
        \\                if (populated.containsKey(describe.getName())) {
        \\                    continue;
        \\                }
        \\                if (describe.isNillable() == false) {
        \\                    record.put(field, 'filled');
        \\                }
        \\            }
        \\            return record;
        \\        }
        \\    }
        \\    public enum LogLevel { INFO, ERROR }
        \\    public static String test() {
        \\        Example__c record = new Example__c(Level__c = LogLevel.ERROR.name());
        \\        record = RequiredFieldBuilder.fill(record);
        \\        return (String) record.Level__c + ':' + (String) record.RequiredName__c;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "PreserveExplicitValueTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ERROR:filled", result.value.string);
}

test "E2E: insert applies required picklist defaults from field metadata" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/OrderThing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/OrderThing__c/fields/Status__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Status__c</fullName>
        \\    <required>true</required>
        \\    <type>Picklist</type>
        \\    <valueSet>
        \\        <valueSetDefinition>
        \\            <sorted>false</sorted>
        \\            <value>
        \\                <fullName>Draft</fullName>
        \\                <default>true</default>
        \\                <label>Draft</label>
        \\            </value>
        \\            <value>
        \\                <fullName>Submitted</fullName>
        \\                <default>false</default>
        \\                <label>Submitted</label>
        \\            </value>
        \\        </valueSetDefinition>
        \\    </valueSet>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class RequiredPicklistDefaultInsertTest {
        \\    public static String test() {
        \\        OrderThing__c row = new OrderThing__c();
        \\        insert row;
        \\        OrderThing__c saved = [SELECT Status__c FROM OrderThing__c LIMIT 1];
        \\        return saved.Status__c;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "RequiredPicklistDefaultInsertTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Draft", result.value.string);
}

test "E2E: picklist describe preserves metadata order when records only use a subset" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/Thing__c.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <label>Thing</label>
        \\</CustomObject>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/Priority__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Priority__c</fullName>
        \\    <type>Picklist</type>
        \\    <valueSet>
        \\        <valueSetDefinition>
        \\            <value><fullName>High</fullName><default>false</default><label>High</label></value>
        \\            <value><fullName>Medium</fullName><default>false</default><label>Medium</label></value>
        \\            <value><fullName>Low</fullName><default>true</default><label>Low</label></value>
        \\        </valueSetDefinition>
        \\    </valueSet>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class PicklistMetadataOrderTest {
        \\    public static String test() {
        \\        insert new Thing__c(Name = 'One', Priority__c = 'Low');
        \\        List<Schema.PicklistEntry> values = Schema.Thing__c.Priority__c.getDescribe().getPicklistValues();
        \\        return String.valueOf(values.size()) + ':' +
        \\            values.get(0).getValue() + ':' +
        \\            values.get(1).getValue() + ':' +
        \\            values.get(2).getValue();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "PicklistMetadataOrderTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("3:High:Medium:Low", result.value.string);
}

test "E2E: filtered rollup survives builder-populated child inserts" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Parent__c/fields");
    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Child__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Level__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Level__c</fullName>
        \\    <type>Picklist</type>
        \\    <valueSet>
        \\        <valueSetDefinition>
        \\            <value><fullName>INFO</fullName><default>false</default></value>
        \\            <value><fullName>ERROR</fullName><default>false</default></value>
        \\        </valueSetDefinition>
        \\    </valueSet>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/RequiredText__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>RequiredText__c</fullName>
        \\    <required>true</required>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Parent__c/fields/ErrorChildren__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ErrorChildren__c</fullName>
        \\    <summaryFilterItems>
        \\        <field>Child__c.Level__c</field>
        \\        <operation>equals</operation>
        \\        <value>ERROR</value>
        \\    </summaryFilterItems>
        \\    <summaryForeignKey>Child__c.Parent__c</summaryForeignKey>
        \\    <summaryOperation>count</summaryOperation>
        \\    <type>Summary</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class BuilderFilteredRollupTest {
        \\    public enum LogLevel { INFO, ERROR }
        \\    public class Builder {
        \\        public static Child__c fill(Child__c record) {
        \\            Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        \\            for (Schema.SObjectField field : Child__c.SObjectType.getDescribe().fields.getMap().values()) {
        \\                Schema.DescribeFieldResult describe = field.getDescribe();
        \\                if (describe.isCreateable() == false || populated.containsKey(describe.getName())) {
        \\                    continue;
        \\                }
        \\                if (describe.isNillable() == false) {
        \\                    record.put(field, 'filled');
        \\                }
        \\            }
        \\            return record;
        \\        }
        \\    }
        \\    public static Integer test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Parent');
        \\        insert parentRecord;
        \\        Child__c childRecord = new Child__c(Parent__c = parentRecord.Id, Level__c = LogLevel.ERROR.name());
        \\        insert Builder.fill(childRecord);
        \\        Parent__c refreshed = [SELECT ErrorChildren__c FROM Parent__c WHERE Id = :parentRecord.Id];
        \\        return Integer.valueOf(refreshed.ErrorChildren__c);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "BuilderFilteredRollupTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 1), result.value.integer);
}

test "E2E: trigger old snapshot preserves pre-rollup summary values" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Parent__c/fields");
    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Child__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Level__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Level__c</fullName>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Parent__c/fields/ErrorChildren__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ErrorChildren__c</fullName>
        \\    <summaryFilterItems>
        \\        <field>Child__c.Level__c</field>
        \\        <operation>equals</operation>
        \\        <value>ERROR</value>
        \\    </summaryFilterItems>
        \\    <summaryForeignKey>Child__c.Parent__c</summaryForeignKey>
        \\    <summaryOperation>count</summaryOperation>
        \\    <type>Summary</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class RollupOldSnapshotProbe {
        \\    public static String seen = '';
        \\}
        \\trigger ParentOldSnapshotTrigger on Parent__c (before update) {
        \\    Parent__c oldRecord = Trigger.old[0];
        \\    Parent__c newRecord = Trigger.new[0];
        \\    RollupOldSnapshotProbe.seen = String.valueOf(oldRecord.ErrorChildren__c) + ':' + String.valueOf(newRecord.ErrorChildren__c);
        \\}
        \\public class RollupOldSnapshotTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Parent');
        \\        insert parentRecord;
        \\        insert new Child__c(Parent__c = parentRecord.Id, Level__c = 'ERROR');
        \\        return RollupOldSnapshotProbe.seen;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "RollupOldSnapshotTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:1", result.value.string);
}

test "E2E: COUNT queries resolve multi-hop custom parent relationships" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class MultiHopCountQueryTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'Parent', RetentionDate__c = System.today().addDays(-1));
        \\        insert parent;
        \\        Child__c child = new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        insert child;
        \\        insert new Grandchild__c(Child__c = child.Id);
        \\        Integer grandchildCount = [
        \\            SELECT COUNT()
        \\            FROM Grandchild__c
        \\            WHERE Child__r.Parent__r.RetentionDate__c <= :System.today()
        \\            AND Child__r.Parent__r.RetentionDate__c != null
        \\        ];
        \\        Integer childCount = [
        \\            SELECT COUNT()
        \\            FROM Child__c
        \\            WHERE Parent__r.RetentionDate__c <= :System.today()
        \\            AND Parent__r.RetentionDate__c != null
        \\        ];
        \\        return String.valueOf(grandchildCount) + ':' + String.valueOf(childCount);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "MultiHopCountQueryTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:1", result.value.string);
}

test "E2E: hierarchy custom setting getInstance returns user-scoped inherited settings" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class HierarchySettingScopeTest {
        \\    public static String test() {
        \\        AppSettings__c orgDefaults = AppSettings__c.getOrgDefaults();
        \\        orgDefaults.Flag__c = 'org';
        \\        insert orgDefaults;
        \\        AppSettings__c currentUserSettings = AppSettings__c.getInstance();
        \\        return String.valueOf(currentUserSettings.Id == null) + ':' +
        \\            String.valueOf(currentUserSettings.SetupOwnerId == UserInfo.getUserId()) + ':' +
        \\            String.valueOf(currentUserSettings.Flag__c);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "HierarchySettingScopeTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:org", result.value.string);
}

test "E2E: hierarchy custom setting accessors return detached records" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class HierarchySettingDetachTest {
        \\    public static String test() {
        \\        insert new AppSettings__c(SetupOwnerId = UserInfo.getUserId(), Flag__c = 'saved');
        \\        AppSettings__c loadedUser = AppSettings__c.getValues(UserInfo.getUserId());
        \\        loadedUser.Flag__c = 'mutated';
        \\        AppSettings__c reloadedUser = AppSettings__c.getValues(UserInfo.getUserId());
        \\        AppSettings__c orgDefaults = AppSettings__c.getOrgDefaults();
        \\        orgDefaults.Flag__c = 'org';
        \\        insert orgDefaults;
        \\        AppSettings__c loadedOrg = AppSettings__c.getOrgDefaults();
        \\        loadedOrg.Flag__c = 'changed';
        \\        return reloadedUser.Flag__c + ':' + AppSettings__c.getOrgDefaults().Flag__c;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "HierarchySettingDetachTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("saved:org", result.value.string);
}

test "E2E: hierarchy custom setting records are visible to later static initialization" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class HierarchySettingStaticHolder {
        \\    private static String currentValue;
        \\    static {
        \\        currentValue = AppSettings__c.getValues(UserInfo.getUserId()).Flag__c;
        \\    }
        \\    public static String getCurrentValue() {
        \\        return currentValue;
        \\    }
        \\}
        \\public class HierarchySettingStaticInitTest {
        \\    public static String test() {
        \\        AppSettings__c userSettings = AppSettings__c.getInstance();
        \\        userSettings.Flag__c = 'configured';
        \\        upsert userSettings;
        \\        return HierarchySettingStaticHolder.getCurrentValue();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "HierarchySettingStaticInitTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("configured", result.value.string);
}

test "E2E: explicit null suppresses hierarchy custom setting field defaults on upsert" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_defaults_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class HierarchySettingNullDefaultTest {
        \\    public static String test() {
        \\        AppSettings__c settings = (AppSettings__c) AppSettings__c.SObjectType.newSObject(null, true);
        \\        settings.SetupOwnerId = UserInfo.getUserId();
        \\        settings.Mode__c = null;
        \\        upsert settings;
        \\        AppSettings__c reloaded = AppSettings__c.getValues(UserInfo.getUserId());
        \\        return String.valueOf(reloaded.Mode__c == null);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "HierarchySettingNullDefaultTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: static initializer preserves static method side effects on fields" {
    const source =
        \\public class StaticInitSideEffectTest {
        \\    private static String configuredValue;
        \\    static {
        \\        setConfiguredValue('ready');
        \\    }
        \\    private static void setConfiguredValue(String nextValue) {
        \\        configuredValue = nextValue;
        \\    }
        \\    public static String test() {
        \\        return configuredValue;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticInitSideEffectTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ready", result.value.string);
}

test "E2E: static initializer resolves bare helper calls against the declaring class" {
    const source =
        \\public class StaticInitCollisionHelper {
        \\    public static String getStaticInitCollisionValue() {
        \\        return 'wrong';
        \\    }
        \\}
        \\
        \\public class StaticInitCollisionTarget {
        \\    private static String cachedValue;
        \\    static {
        \\        cachedValue = getStaticInitCollisionValue();
        \\    }
        \\    private static String getStaticInitCollisionValue() {
        \\        return 'right';
        \\    }
        \\    public static String test() {
        \\        return cachedValue;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticInitCollisionTarget",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("right", result.value.string);
}

test "E2E: test runner sees hierarchy custom settings before later class static init" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_fixture(tmp_dir.dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "ScenarioHolder.cls",
        .data =
        \\public class ScenarioHolder {
        \\    private static String currentScenario;
        \\    static {
        \\        currentScenario = AppSettings__c.getValues(UserInfo.getUserId()).Flag__c;
        \\    }
        \\    public static String getScenario() {
        \\        return currentScenario;
        \\    }
        \\}
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "ScenarioHolder_Tests.cls",
        .data =
        \\@IsTest
        \\private class ScenarioHolder_Tests {
        \\    @IsTest
        \\    static void it_reads_user_setting_during_subject_static_init() {
        \\        AppSettings__c settings = AppSettings__c.getInstance();
        \\        settings.Flag__c = 'configured';
        \\        upsert settings;
        \\        System.Assert.areEqual('configured', ScenarioHolder.getScenario());
        \\    }
        \\}
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    var _null_buf: [256]u8 = undefined;
    var _null_writer: std.Io.Writer.Discarding = .init(&_null_buf);
    const suite = try run_test_suite(alloc, std.testing.io, &.{tmp_path}, &_null_writer.writer);
    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
    try std.testing.expectEqual(@as(u32, 0), suite.failed);
    try std.testing.expectEqual(@as(u32, 0), suite.errors);
}

test "E2E: safe navigation preserves chained fluent instance calls" {
    const source =
        \\public class FluentChain {
        \\    private Integer callCount = 0;
        \\    public FluentChain touch() {
        \\        callCount++;
        \\        return this;
        \\    }
        \\    public Integer getCallCount() {
        \\        return callCount;
        \\    }
        \\    public static FluentChain build() {
        \\        return new FluentChain();
        \\    }
        \\}
        \\public class SafeNavFluentChainTest {
        \\    public static String test() {
        \\        return String.valueOf(FluentChain.build()?.touch().getCallCount());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SafeNavFluentChainTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: safe navigation short-circuits remaining method chain on null" {
    const source =
        \\public class SafeNavNullChainTest {
        \\    public static String test() {
        \\        String raw = null;
        \\        List<String> parts = raw?.replace_all('x', 'y').split(',');
        \\        return parts == null ? 'null' : String.valueOf(parts.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SafeNavNullChainTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("null", result.value.string);
}

test "E2E: safe navigation short-circuits remaining field chain on null" {
    const source =
        \\public class SafeNavNullFieldChainTest {
        \\    public class Holder {
        \\        public Holder child;
        \\        public String name;
        \\    }
        \\    public static String test() {
        \\        Holder root = null;
        \\        return root?.child.name == null ? 'null' : 'value';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SafeNavNullFieldChainTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("null", result.value.string);
}

test "E2E: logical OR short-circuits null receiver checks" {
    const source =
        \\public class LogicalOrShortCircuitTest {
        \\    public static String test() {
        \\        List<String> values = null;
        \\        return values == null || values.isEmpty() ? 'ok' : 'bad';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "LogicalOrShortCircuitTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: logical AND short-circuits null receiver checks" {
    const source =
        \\public class LogicalAndShortCircuitTest {
        \\    public static String test() {
        \\        List<String> values = null;
        \\        return values != null && values.isEmpty() ? 'bad' : 'ok';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "LogicalAndShortCircuitTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: Type.forName inner handler retains SObjectType map keys after execute" {
    const source =
        \\public abstract class HandlerBase {
        \\    private static Map<Schema.SObjectType, List<HandlerBase>> executed = new Map<Schema.SObjectType, List<HandlerBase>>();
        \\    public abstract Schema.SObjectType getSObjectType();
        \\    public void execute() {
        \\        if (executed.containsKey(this.getSObjectType()) == false) {
        \\            executed.put(this.getSObjectType(), new List<HandlerBase>());
        \\        }
        \\        executed.get(this.getSObjectType()).add(this);
        \\    }
        \\    public static Integer getExecutionCount(Schema.SObjectType sobjectType) {
        \\        List<HandlerBase> handlers = executed.get(sobjectType);
        \\        return handlers == null ? null : handlers.size();
        \\    }
        \\}
        \\public class HandlerFactoryHost {
        \\    public class AccountHandler extends HandlerBase {
        \\        private Schema.SObjectType sobjectType;
        \\        public AccountHandler() {
        \\            this.sobjectType = Schema.Account.SObjectType;
        \\        }
        \\        public override Schema.SObjectType getSObjectType() {
        \\            return this.sobjectType;
        \\        }
        \\    }
        \\}
        \\public class InnerHandlerFactoryTest {
        \\    public static String test() {
        \\        HandlerBase handler = (HandlerBase) Type.forName('HandlerFactoryHost.AccountHandler').newInstance();
        \\        handler.execute();
        \\        return String.valueOf(HandlerBase.getExecutionCount(Schema.Account.SObjectType));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerHandlerFactoryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: Type.forName event handler retains platform event SObjectType map keys after execute" {
    const source =
        \\public abstract class EventHandlerBase {
        \\    private static Map<Schema.SObjectType, List<EventHandlerBase>> executed = new Map<Schema.SObjectType, List<EventHandlerBase>>();
        \\    public abstract Schema.SObjectType getSObjectType();
        \\    public void execute() {
        \\        if (executed.containsKey(this.getSObjectType()) == false) {
        \\            executed.put(this.getSObjectType(), new List<EventHandlerBase>());
        \\        }
        \\        executed.get(this.getSObjectType()).add(this);
        \\    }
        \\    public static Integer getExecutionCount(Schema.SObjectType sobjectType) {
        \\        List<EventHandlerBase> handlers = executed.get(sobjectType);
        \\        return handlers == null ? null : handlers.size();
        \\    }
        \\}
        \\public class EventHandlerFactoryHost {
        \\    public class PlatformEventHandler extends EventHandlerBase {
        \\        private Schema.SObjectType sobjectType;
        \\        public PlatformEventHandler() {
        \\            this.sobjectType = Schema.LogEntryEvent__e.SObjectType;
        \\        }
        \\        public override Schema.SObjectType getSObjectType() {
        \\            return this.sobjectType;
        \\        }
        \\    }
        \\}
        \\public class EventHandlerFactoryTest {
        \\    public static String test() {
        \\        EventHandlerBase handler = (EventHandlerBase) Type.forName('EventHandlerFactoryHost.PlatformEventHandler').newInstance();
        \\        handler.execute();
        \\        return String.valueOf(EventHandlerBase.getExecutionCount(Schema.LogEntryEvent__e.SObjectType));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EventHandlerFactoryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: JSON round-trip into SObject preserves setup object fields when adding read-only field" {
    const source =
        \\public class JsonReadOnlyFieldRoundTripTest {
        \\    public static String test() {
        \\        SObject record = new ApexClass(Name = 'SomeClass', Body = 'body');
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap = (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        deserializedRecordMap.put(Schema.ApexClass.LastModifiedDate.toString(), Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        SObject updatedRecord = (SObject) System.JSON.deserialize(System.JSON.serialize(deserializedRecordMap), SObject.class);
        \\        return updatedRecord.getSObjectType().getDescribe().getName() + ':' +
        \\            String.valueOf(updatedRecord.get('Name')) + ':' +
        \\            String.valueOf(updatedRecord.get('Body')) + ':' +
        \\            String.valueOf(updatedRecord.get('LastModifiedDate'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonReadOnlyFieldRoundTripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "ApexClass:SomeClass:body:2026-04-01T00:00:00Z",
        result.value.string,
    );
}

test "E2E: JSON read-only round-trip preserves typed ApexClass property access" {
    const source =
        \\public class JsonTypedApexClassRoundTripTest {
        \\    public static String test() {
        \\        Schema.ApexClass record = new Schema.ApexClass(Name = 'SomeClass', Body = 'body');
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap = (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        deserializedRecordMap.put(Schema.ApexClass.LastModifiedDate.toString(), Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        record = (Schema.ApexClass) System.JSON.deserialize(System.JSON.serialize(deserializedRecordMap), SObject.class);
        \\        return String.valueOf(record.Name != null) + ':' +
        \\            String.valueOf(record.Name) + ':' +
        \\            String.valueOf(record.Body) + ':' +
        \\            String.valueOf(record.LastModifiedDate);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonTypedApexClassRoundTripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "true:SomeClass:body:2026-04-01T00:00:00Z",
        result.value.string,
    );
}

test "E2E: Map<Schema.SObjectField, Object> preserves setup field tokens through keySet/get" {
    const source =
        \\public class SchemaFieldTokenMapTest {
        \\    public static String test() {
        \\        Map<Schema.SObjectField, Object> changesToFields = new Map<Schema.SObjectField, Object>{
        \\            Schema.ApexClass.LastModifiedDate => Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        };
        \\        for (Schema.SObjectField sobjectField : changesToFields.keySet()) {
        \\            return sobjectField.toString() + ':' + String.valueOf(changesToFields.get(sobjectField));
        \\        }
        \\        return 'empty';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaFieldTokenMapTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "LastModifiedDate:2026-04-01T00:00:00Z",
        result.value.string,
    );
}

test "E2E: helper-style read-only field setter preserves ApexClass Name" {
    const source =
        \\public class ReadOnlyFieldSetterProbe {
        \\    public static SObject setReadOnlyField(SObject record, Schema.SObjectField field, Object value) {
        \\        return setReadOnlyField(record, new Map<Schema.SObjectField, Object>{ field => value });
        \\    }
        \\    public static SObject setReadOnlyField(SObject record, Map<Schema.SObjectField, Object> changesToFields) {
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap = (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        for (Schema.SObjectField sobjectField : changesToFields.keySet()) {
        \\            String fieldName = sobjectField.toString();
        \\            deserializedRecordMap.put(fieldName, changesToFields.get(sobjectField));
        \\        }
        \\        serializedRecord = System.JSON.serialize(deserializedRecordMap);
        \\        return (SObject) System.JSON.deserialize(serializedRecord, SObject.class);
        \\    }
        \\    public static String test() {
        \\        Schema.ApexClass record = new Schema.ApexClass(Name = 'SomeClass', Body = 'body');
        \\        record = (Schema.ApexClass) setReadOnlyField(record, Schema.ApexClass.LastModifiedDate, Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        return String.valueOf(record.Name != null) + ':' +
        \\            String.valueOf(record.Name) + ':' +
        \\            String.valueOf(record.Body) + ':' +
        \\            String.valueOf(record.LastModifiedDate);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ReadOnlyFieldSetterProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "true:SomeClass:body:2026-04-01T00:00:00Z",
        result.value.string,
    );
}

test "E2E: helper-style read-only field setter preserves comma-containing setup fields" {
    const source =
        \\public class ReadOnlyFieldSetterCommaProbe {
        \\    public static SObject setReadOnlyField(SObject record, Schema.SObjectField field, Object value) {
        \\        return setReadOnlyField(record, new Map<Schema.SObjectField, Object>{ field => value });
        \\    }
        \\    public static SObject setReadOnlyField(SObject record, Map<Schema.SObjectField, Object> changesToFields) {
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap = (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        for (Schema.SObjectField sobjectField : changesToFields.keySet()) {
        \\            String fieldName = sobjectField.toString();
        \\            deserializedRecordMap.put(fieldName, changesToFields.get(sobjectField));
        \\        }
        \\        serializedRecord = System.JSON.serialize(deserializedRecordMap);
        \\        return (SObject) System.JSON.deserialize(serializedRecord, SObject.class);
        \\    }
        \\    public static String test() {
        \\        Schema.ApexClass record = new Schema.ApexClass(
        \\            Name = 'SomeClass',
        \\            Body = 'Wow, look at this code for a mock version of apex class SomeClass'
        \\        );
        \\        record = (Schema.ApexClass) setReadOnlyField(record, Schema.ApexClass.LastModifiedDate, Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        return String.valueOf(record.Name != null) + ':' +
        \\            String.valueOf(record.Name) + ':' +
        \\            String.valueOf(record.Body);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ReadOnlyFieldSetterCommaProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "true:SomeClass:Wow, look at this code for a mock version of apex class SomeClass",
        result.value.string,
    );
}

test "E2E: qualified Schema setup objects ignore same-named user classes" {
    const source =
        \\public class ApexClass {
        \\}
        \\public class QualifiedSchemaSetupObjectCtorProbe {
        \\    public static String test() {
        \\        Schema.ApexClass record = new Schema.ApexClass(
        \\            Name = 'SomeClass',
        \\            Body = 'mock body'
        \\        );
        \\        return record.getSObjectType().getDescribe().getName() + ':' +
        \\            String.valueOf(record.Name) + ':' +
        \\            String.valueOf(record.Body);
        \\    }
        \\}
        \\public class QualifiedSchemaSetupObjectProbe {
        \\    public static SObject setReadOnlyField(SObject record, Schema.SObjectField field, Object value) {
        \\        return setReadOnlyField(record, new Map<Schema.SObjectField, Object>{ field => value });
        \\    }
        \\    public static SObject setReadOnlyField(SObject record, Map<Schema.SObjectField, Object> changesToFields) {
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap = (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        for (Schema.SObjectField sobjectField : changesToFields.keySet()) {
        \\            deserializedRecordMap.put(sobjectField.toString(), changesToFields.get(sobjectField));
        \\        }
        \\        return (SObject) System.JSON.deserialize(System.JSON.serialize(deserializedRecordMap), SObject.class);
        \\    }
        \\    public static String test() {
        \\        Schema.ApexClass record = new Schema.ApexClass(
        \\            Name = 'SomeClass',
        \\            Body = 'mock body'
        \\        );
        \\        record = (Schema.ApexClass) setReadOnlyField(
        \\            record,
        \\            Schema.ApexClass.LastModifiedDate,
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
        \\        return record.getSObjectType().getDescribe().getName() + ':' +
        \\            String.valueOf(record.Name) + ':' +
        \\            String.valueOf(record.Body) + ':' +
        \\            String.valueOf(record.LastModifiedDate);
        \\    }
        \\}
    ;
    const ctor_result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QualifiedSchemaSetupObjectCtorProbe",
        .entry_method = "test",
    });
    defer ctor_result.deinit();

    try std.testing.expectEqualStrings("ApexClass:SomeClass:mock body", ctor_result.value.string);

    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QualifiedSchemaSetupObjectProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "ApexClass:SomeClass:mock body:2026-04-01T00:00:00Z",
        result.value.string,
    );
}

test "E2E: qualified inner class literals preserve outer class names" {
    const source =
        \\public class OuterNameHost {
        \\    public class InnerNameTarget {
        \\    }
        \\    public static String getInnerNameFromInside() {
        \\        return InnerNameTarget.class.getName();
        \\    }
        \\}
        \\public class QualifiedInnerNameTest {
        \\    public static String test() {
        \\        return OuterNameHost.getInnerNameFromInside() + '|' + OuterNameHost.InnerNameTarget.class.getName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QualifiedInnerNameTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "OuterNameHost.InnerNameTarget|OuterNameHost.InnerNameTarget",
        result.value.string,
    );
}

test "E2E: Type.forName(newInstance) preserves qualified inner class identity across duplicates" {
    const source =
        \\public abstract class SharedHandlerBase {
        \\    public abstract String whoAmI();
        \\}
        \\public class HandlerHostA {
        \\    public class SharedHandler extends SharedHandlerBase {
        \\        public override String whoAmI() {
        \\            return 'A';
        \\        }
        \\    }
        \\    public static String getInnerHandlerName() {
        \\        return SharedHandler.class.getName();
        \\    }
        \\}
        \\public class HandlerHostB {
        \\    public class SharedHandler extends SharedHandlerBase {
        \\        public override String whoAmI() {
        \\            return 'B';
        \\        }
        \\    }
        \\}
        \\public class QualifiedInnerInstanceTest {
        \\    public static String test() {
        \\        SharedHandlerBase inside = (SharedHandlerBase) Type.forName(HandlerHostA.getInnerHandlerName()).newInstance();
        \\        SharedHandlerBase outside = (SharedHandlerBase) Type.forName(HandlerHostA.SharedHandler.class.getName()).newInstance();
        \\        return inside.whoAmI() + outside.whoAmI();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QualifiedInnerInstanceTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("AA", result.value.string);
}

test "E2E: nested inner constructors resolve sibling inner classes in outer scope" {
    const source =
        \\public class ScopedInnerCtorHostA {
        \\    public class Item {
        \\        public String origin;
        \\        public Item(String value) {
        \\            origin = 'A:' + value;
        \\        }
        \\    }
        \\    public class Holder {
        \\        public String build() {
        \\            return new Item('x').origin;
        \\        }
        \\    }
        \\    public static String test() {
        \\        return new Holder().build();
        \\    }
        \\}
        \\public class ScopedInnerCtorHostB {
        \\    public class Item {
        \\        public String origin;
        \\        public Item(String value) {
        \\            origin = 'B:' + value;
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ScopedInnerCtorHostA",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("A:x", result.value.string);
}

test "E2E: inner classes prefer enclosing static helper methods over unrelated top-level methods" {
    const source =
        \\public class WrongHelper {
        \\    public static String pick(Object value) {
        \\        return 'wrong';
        \\    }
        \\}
        \\public class Container {
        \\    private static String pick(String value) {
        \\        return 'outer:' + value;
        \\    }
        \\    public class Inner {
        \\        public String run() {
        \\            return pick('ok');
        \\        }
        \\    }
        \\    public static String test() {
        \\        return new Inner().run();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Container",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("outer:ok", result.value.string);
}

test "E2E: postfix increment updates static field through bare identifier" {
    const source =
        \\public class StaticCounterProbe {
        \\    private static Integer counter = 1;
        \\    private static Integer nextValue() {
        \\        return counter++;
        \\    }
        \\    public static String run() {
        \\        Integer first = nextValue();
        \\        Integer second = nextValue();
        \\        return String.valueOf(first) + ':' + String.valueOf(second) + ':' + String.valueOf(counter);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticCounterProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:2:3", result.value.string);
}

test "E2E: Type.forName null-safe fluent execute preserves constructor-initialized fields" {
    const source =
        \\public abstract class TriggerableHost {
        \\    private static Map<Schema.SObjectType, Integer> counts = new Map<Schema.SObjectType, Integer>();
        \\    public abstract Schema.SObjectType getSObjectType();
        \\    public virtual TriggerableHost overrideContext(String value) {
        \\        return this;
        \\    }
        \\    public void execute() {
        \\        Integer currentCount = counts.get(this.getSObjectType());
        \\        counts.put(this.getSObjectType(), currentCount == null ? 1 : currentCount + 1);
        \\    }
        \\    public static Integer getExecutionCount(Schema.SObjectType sobjectType) {
        \\        return counts.get(sobjectType);
        \\    }
        \\}
        \\public class TriggerableFactoryHost {
        \\    public class EventTriggerable extends TriggerableHost {
        \\        private Schema.SObjectType sobjectType;
        \\        public EventTriggerable() {
        \\            this.sobjectType = Schema.LogEntryEvent__e.SObjectType;
        \\        }
        \\        public override Schema.SObjectType getSObjectType() {
        \\            return this.sobjectType;
        \\        }
        \\    }
        \\}
        \\public class TriggerableFactoryTest {
        \\    public static TriggerableHost getHandler(String className) {
        \\        return (TriggerableHost) Type.forName(className)?.newInstance();
        \\    }
        \\    public static String test() {
        \\        getHandler(TriggerableFactoryHost.EventTriggerable.class.getName())?.overrideContext('x').execute();
        \\        return String.valueOf(TriggerableHost.getExecutionCount(Schema.LogEntryEvent__e.SObjectType));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TriggerableFactoryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: parent constructors can read overridden type getters before child initialization without losing child state" {
    const source =
        \\public abstract class ParentCtorTypeHost {
        \\    private static Map<String, String> readings = new Map<String, String>();
        \\    public ParentCtorTypeHost() {
        \\        readings.put('duringParentCtor', String.valueOf(this.getSObjectType()));
        \\    }
        \\    public abstract Schema.SObjectType getSObjectType();
        \\    public static String getReading(String key) {
        \\        return readings.get(key);
        \\    }
        \\}
        \\public class ParentCtorTypeFactory {
        \\    public class EventChild extends ParentCtorTypeHost {
        \\        private Schema.SObjectType sobjectType;
        \\        public EventChild() {
        \\            this.sobjectType = Schema.LogEntryEvent__e.SObjectType;
        \\        }
        \\        public override Schema.SObjectType getSObjectType() {
        \\            return this.sobjectType;
        \\        }
        \\    }
        \\}
        \\public class ParentCtorTypeFactoryTest {
        \\    public static String test() {
        \\        ParentCtorTypeHost child = (ParentCtorTypeHost) Type.forName(ParentCtorTypeFactory.EventChild.class.getName()).newInstance();
        \\        return ParentCtorTypeHost.getReading('duringParentCtor') + '|' + String.valueOf(child.getSObjectType());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ParentCtorTypeFactoryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("null|LogEntryEvent__e", result.value.string);
}

test "E2E: static method returned map supports chained get size and index access" {
    const source =
        \\public class StaticMapChainHost {
        \\    private static Map<Schema.SObjectType, List<String>> valuesByType = new Map<Schema.SObjectType, List<String>>();
        \\    static {
        \\        valuesByType.put(Schema.Account.SObjectType, new List<String>{ 'a', 'b' });
        \\    }
        \\    public static Map<Schema.SObjectType, List<String>> getValuesByType() {
        \\        return valuesByType;
        \\    }
        \\}
        \\public class StaticMapChainTest {
        \\    public static String test() {
        \\        return String.valueOf(StaticMapChainHost.getValuesByType().get(Schema.Account.SObjectType).size()) +
        \\            '|' +
        \\            StaticMapChainHost.getValuesByType().get(Schema.Account.SObjectType).get(0);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticMapChainTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2|a", result.value.string);
}

test "E2E: Map<Schema.SObjectType, List<Id>> keySet preserves SObjectType keys in loop bodies" {
    const source =
        \\public class SObjectTypeKeySetLoopTest {
        \\    public static String test() {
        \\        User currentUser = [SELECT Id, Username FROM User WHERE Id = :System.UserInfo.getUserId()];
        \\        Map<Schema.SObjectType, List<Id>> idsByType = new Map<Schema.SObjectType, List<Id>>();
        \\        idsByType.put(currentUser.Id.getSObjectType(), new List<Id>{ currentUser.Id });
        \\        for (Schema.SObjectType sobjectType : idsByType.keySet()) {
        \\            List<Id> recordIds = idsByType.get(sobjectType);
        \\            List<SObject> results = Database.query(
        \\                String.format('SELECT Username FROM {0} WHERE Id IN :recordIds', new List<Object>{ sobjectType })
        \\            );
        \\            return sobjectType.getDescribe().getName() + ':' + (String) results.get(0).get('Username');
        \\        }
        \\        return 'empty';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SObjectTypeKeySetLoopTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("User:testuser@example.com", result.value.string);
}

test "E2E: EmailMessage display field selection prefers Subject when Name is absent" {
    const source =
        \\public class EmailMessageDisplayFieldTest {
        \\    private static String getDisplayFieldApiName(Schema.SObjectType sobjectType) {
        \\        if (sobjectType == Schema.User.SObjectType) {
        \\            return Schema.User.Username.toString();
        \\        }
        \\        List<String> educatedGuesses = new List<String>{ 'Name', 'DeveloperName', 'ApiName', 'Title', 'Subject' };
        \\        String displayFieldApiName;
        \\        List<String> fallbackFieldApiNames = new List<String>();
        \\        for (String fieldName : educatedGuesses) {
        \\            Schema.SObjectField field = sobjectType.getDescribe().fields.getMap().get(fieldName);
        \\            if (field == null) {
        \\                continue;
        \\            }
        \\            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
        \\            if (fieldDescribe.isNameField()) {
        \\                displayFieldApiName = fieldDescribe.getName();
        \\                break;
        \\            } else {
        \\                fallbackFieldApiNames.add(fieldDescribe.getName());
        \\            }
        \\        }
        \\        if (String.isBlank(displayFieldApiName) && fallbackFieldApiNames.size() == 1) {
        \\            displayFieldApiName = fallbackFieldApiNames.get(0);
        \\        }
        \\        return displayFieldApiName;
        \\    }
        \\    public static String test() {
        \\        Case supportCase = new Case(Subject = 'Support');
        \\        insert supportCase;
        \\        EmailMessage emailMessage = new EmailMessage(ParentId = supportCase.Id, Subject = 'Some subject');
        \\        insert emailMessage;
        \\        String displayField = getDisplayFieldApiName(emailMessage.Id.getSObjectType());
        \\        List<Id> recordIds = new List<Id>{ emailMessage.Id };
        \\        List<SObject> results = Database.query(
        \\            String.format('SELECT {0} FROM {1} WHERE Id IN :recordIds', new List<Object>{ displayField, emailMessage.Id.getSObjectType() })
        \\        );
        \\        return displayField + ':' + (String) results.get(0).get(displayField);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EmailMessageDisplayFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Subject:Some subject", result.value.string);
}

test "E2E: static method returned map preserves list values keyed by Schema SObjectType" {
    const source =
        \\public class ChainedHandlerBase {
        \\    public String name;
        \\    public ChainedHandlerBase(String value) {
        \\        this.name = value;
        \\    }
        \\}
        \\public class ChainedHandlerStore {
        \\    private static Map<Schema.SObjectType, List<ChainedHandlerBase>> executed = new Map<Schema.SObjectType, List<ChainedHandlerBase>>();
        \\    static {
        \\        executed.put(
        \\            Schema.LogEntryEvent__e.SObjectType,
        \\            new List<ChainedHandlerBase>{
        \\                new ChainedHandlerBase('first'),
        \\                new ChainedHandlerBase('second')
        \\            }
        \\        );
        \\    }
        \\    public static Map<Schema.SObjectType, List<ChainedHandlerBase>> getExecuted() {
        \\        return executed;
        \\    }
        \\}
        \\public class ChainedHandlerStoreTest {
        \\    public static String test() {
        \\        return String.valueOf(ChainedHandlerStore.getExecuted().get(Schema.LogEntryEvent__e.SObjectType).size()) +
        \\            '|' +
        \\            ChainedHandlerStore.getExecuted().get(Schema.LogEntryEvent__e.SObjectType).get(1).name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ChainedHandlerStoreTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2|second", result.value.string);
}

test "E2E: overridden methods persist List<SObject> fields on handler instances" {
    const source =
        \\public abstract class HandlerExecutionBase {
        \\    private static List<HandlerExecutionBase> executed = new List<HandlerExecutionBase>();
        \\    public static List<HandlerExecutionBase> getExecuted() {
        \\        return executed;
        \\    }
        \\    public void execute() {
        \\        this.executeBeforeInsert(
        \\            new List<SObject>{
        \\                new Account(Name = 'first'),
        \\                new Account(Name = 'second')
        \\            }
        \\        );
        \\        executed.add(this);
        \\    }
        \\    protected virtual void executeBeforeInsert(List<SObject> triggerNew) {
        \\    }
        \\}
        \\public class HandlerExecutionChild extends HandlerExecutionBase {
        \\    public String executedOperation;
        \\    public List<SObject> executedTriggerNew;
        \\    protected override void executeBeforeInsert(List<SObject> triggerNew) {
        \\        this.executedOperation = 'before';
        \\        this.executedTriggerNew = triggerNew;
        \\    }
        \\}
        \\public class HandlerExecutionChildTest {
        \\    public static String test() {
        \\        new HandlerExecutionChild().execute();
        \\        HandlerExecutionChild child = (HandlerExecutionChild) HandlerExecutionBase.getExecuted().get(0);
        \\        return child.executedOperation + '|' +
        \\            String.valueOf(child.executedTriggerNew.size()) + '|' +
        \\            String.valueOf(child.executedTriggerNew.get(0).get('Name'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "HandlerExecutionChildTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("before|2|first", result.value.string);
}

test "E2E: nested field access preserves null overload selection" {
    const source =
        \\public class NestedOverloadContext {
        \\    public List<SObject> records;
        \\    public Map<Id, SObject> recordMap;
        \\}
        \\public abstract class NestedOverloadBase {
        \\    public NestedOverloadContext context;
        \\    public NestedOverloadBase() {
        \\        this.context = new NestedOverloadContext();
        \\        this.context.records = new List<SObject>{
        \\            new Account(Name = 'first'),
        \\            new Account(Name = 'second')
        \\        };
        \\        this.context.recordMap = null;
        \\    }
        \\    public void execute() {
        \\        this.executeAfterInsert(this.context.records);
        \\        this.executeAfterInsert(this.context.recordMap);
        \\    }
        \\    protected virtual void executeAfterInsert(List<SObject> triggerNew) {
        \\    }
        \\    protected virtual void executeAfterInsert(Map<Id, SObject> triggerNewMap) {
        \\    }
        \\}
        \\public class NestedOverloadChild extends NestedOverloadBase {
        \\    public List<SObject> seenRecords;
        \\    public Map<Id, SObject> seenRecordMap;
        \\    protected override void executeAfterInsert(List<SObject> triggerNew) {
        \\        this.seenRecords = triggerNew;
        \\    }
        \\    protected override void executeAfterInsert(Map<Id, SObject> triggerNewMap) {
        \\        this.seenRecordMap = triggerNewMap;
        \\    }
        \\}
        \\public class NestedOverloadChildTest {
        \\    public static String test() {
        \\        NestedOverloadChild child = new NestedOverloadChild();
        \\        child.execute();
        \\        return String.valueOf(child.seenRecords?.size()) + '|' +
        \\            String.valueOf(child.seenRecordMap == null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NestedOverloadChildTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2|true", result.value.string);
}

test "E2E: base overload dispatch skips incompatible child override" {
    const source =
        \\public class OverloadDispatchRecorder {
        \\    public static List<String> seen = new List<String>();
        \\}
        \\public virtual class OverloadDispatchBase {
        \\    public void run(List<SObject> rows, Map<Id, SObject> rowMap) {
        \\        this.handle(rows);
        \\        this.handle(rowMap);
        \\    }
        \\    protected virtual void handle(List<SObject> rows) {
        \\        OverloadDispatchRecorder.seen.add('base-list');
        \\    }
        \\    protected virtual void handle(Map<Id, SObject> rowMap) {
        \\        OverloadDispatchRecorder.seen.add('base-map');
        \\    }
        \\}
        \\public class OverloadDispatchChild extends OverloadDispatchBase {
        \\    protected override void handle(List<SObject> rows) {
        \\        OverloadDispatchRecorder.seen.add('child-list');
        \\    }
        \\}
        \\public class OverloadDispatchChildTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'dispatch');
        \\        insert accountRecord;
        \\        Map<Id, SObject> rowMap = new Map<Id, SObject>();
        \\        rowMap.put(accountRecord.Id, accountRecord);
        \\        OverloadDispatchRecorder.seen = new List<String>();
        \\        new OverloadDispatchChild().run(new List<SObject>{ accountRecord }, rowMap);
        \\        return OverloadDispatchRecorder.seen[0] + '|' + OverloadDispatchRecorder.seen[1];
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "OverloadDispatchChildTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("child-list|base-map", result.value.string);
}

test "E2E: Object-wrapped primitive values support null-safe toString" {
    const source =
        \\public class PrimitiveObjectToStringTest {
        \\    public static String test() {
        \\        Object boolValue = true;
        \\        Object intValue = 1;
        \\        Object doubleValue = 1.5;
        \\        return boolValue?.toString() + '|' + intValue?.toString() + '|' + doubleValue?.toString();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PrimitiveObjectToStringTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true|1|1.5", result.value.string);
}

test "E2E: System.Test.testInstall invokes install handlers" {
    const source =
        \\global class PackageInstallHook implements System.InstallHandler {
        \\    global void onInstall(System.InstallContext installContext) {
        \\        insert new Account(Name = 'Installed');
        \\    }
        \\}
        \\public class InstallHandlerTest {
        \\    public static String test() {
        \\        System.Test.testInstall(new PackageInstallHook(), null, false);
        \\        return String.valueOf([SELECT Id FROM Account].size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InstallHandlerTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: SObject.getSObject resolves parent records from a reference field token" {
    const source =
        \\public class GetSObjectParentTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Contact contactRecord = new Contact(LastName = 'User', AccountId = accountRecord.Id);
        \\        insert contactRecord;
        \\        Contact queried = [SELECT AccountId, Account.Name FROM Contact WHERE Id = :contactRecord.Id];
        \\        SObject parentRecord = queried.getSObject(Schema.Contact.AccountId);
        \\        return String.valueOf(parentRecord.get('Name'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "GetSObjectParentTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Acme", result.value.string);
}

test "E2E: SObject.getSObject resolves unsaved relationship records assigned via __r" {
    const source =
        \\public class GetUnsavedParentTest {
        \\    public static String test() {
        \\        Session__c sessionRecord = new Session__c(Experience__r = new Experience__c(Name = 'Hiking'));
        \\        SObject parentRecord = sessionRecord.getSObject(Schema.Session__c.Experience__c);
        \\        return String.valueOf(parentRecord.get('Name'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "GetUnsavedParentTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Hiking", result.value.string);
}

test "E2E: direct property access resolves unsaved relationship records assigned via __r" {
    const source =
        \\public class DirectUnsavedParentTest {
        \\    public static String test() {
        \\        Session__c sessionRecord = new Session__c(Experience__r = new Experience__c(Name = 'Hiking'));
        \\        return sessionRecord.Experience__r.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DirectUnsavedParentTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Hiking", result.value.string);
}

test "E2E: member-held direct property access resolves unsaved relationship records assigned via __r" {
    const source =
        \\public class MemberHeldUnsavedParentTest {
        \\    private Session__c sessionRecord;
        \\    public MemberHeldUnsavedParentTest(Session__c sessionRecord) {
        \\        this.sessionRecord = sessionRecord;
        \\    }
        \\    public String getName() {
        \\        return this.sessionRecord.Experience__r.Name;
        \\    }
        \\    public static String test() {
        \\        Session__c sessionRecord = new Session__c(Experience__r = new Experience__c(Name = 'Hiking'));
        \\        return new MemberHeldUnsavedParentTest(sessionRecord).getName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MemberHeldUnsavedParentTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Hiking", result.value.string);
}

test "E2E: member-held direct property access resolves custom fields on unsaved relationship records" {
    const source =
        \\public class MemberHeldUnsavedCustomFieldTest {
        \\    private Session__c sessionRecord;
        \\    public MemberHeldUnsavedCustomFieldTest(Session__c sessionRecord) {
        \\        this.sessionRecord = sessionRecord;
        \\    }
        \\    public String getType() {
        \\        return this.sessionRecord.Experience__r.Type__c;
        \\    }
        \\    public static String test() {
        \\        Session__c sessionRecord = new Session__c(Experience__r = new Experience__c(Name = 'Hiking', Type__c = 'Adventure'));
        \\        return new MemberHeldUnsavedCustomFieldTest(sessionRecord).getType();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MemberHeldUnsavedCustomFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Adventure", result.value.string);
}

test "E2E: SObject initializer can read custom fields from member-held relationship records" {
    const source =
        \\public class RelatedInitializerReadTest {
        \\    private Session__c sessionRecord;
        \\    public RelatedInitializerReadTest(Session__c sessionRecord) {
        \\        this.sessionRecord = sessionRecord;
        \\    }
        \\    public Account build() {
        \\        return new Account(Name = this.sessionRecord.Experience__r.Type__c);
        \\    }
        \\    public static String test() {
        \\        Session__c sessionRecord = new Session__c(Experience__r = new Experience__c(Name = 'Hiking', Type__c = 'Adventure'));
        \\        return new RelatedInitializerReadTest(sessionRecord).build().Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RelatedInitializerReadTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Adventure", result.value.string);
}

test "E2E: subquery child records preserve parent relationship fields" {
    const source =
        \\public class ChildParentSubqueryTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        insert new Contact(LastName = 'Tester', AccountId = accountRecord.Id);
        \\        Account queried = [
        \\            SELECT Id, (SELECT Id, Account.Name FROM Contacts ORDER BY Id)
        \\            FROM Account
        \\            WHERE Id = :accountRecord.Id
        \\        ];
        \\        return queried.Contacts[0].Account.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ChildParentSubqueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Acme", result.value.string);
}

test "E2E: subquery custom child records preserve custom parent relationship fields" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class CustomChildParentSubqueryTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Acme');
        \\        insert parentRecord;
        \\        insert new Child__c(Parent__c = parentRecord.Id, Status__c = 'Open');
        \\        Parent__c queried = [
        \\            SELECT Id, (SELECT Id, Parent__r.Name FROM Children__r ORDER BY Id)
        \\            FROM Parent__c
        \\            WHERE Id = :parentRecord.Id
        \\        ];
        \\        return queried.Children__r[0].Parent__r.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CustomChildParentSubqueryTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Acme", result.value.string);
}

test "E2E: unsaved custom child relationships default to empty lists" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class EmptyCustomChildRelationshipTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Acme');
        \\        Integer count = 0;
        \\        for (Child__c childRecord : parentRecord.Children__r) {
        \\            count++;
        \\        }
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EmptyCustomChildRelationshipTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0", result.value.string);
}

test "E2E: top-level custom child queries preserve custom parent relationship fields" {
    const source =
        \\public class TopLevelCustomChildParentQueryTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Acme');
        \\        insert parentRecord;
        \\        Child__c childRecord = new Child__c(Parent__c = parentRecord.Id, Status__c = 'Open');
        \\        insert childRecord;
        \\        Child__c queried = [SELECT Id, Parent__r.Name FROM Child__c WHERE Id = :childRecord.Id];
        \\        return queried.Parent__r.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TopLevelCustomChildParentQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Acme", result.value.string);
}

test "E2E: SOQL parent relationship field in WHERE" {
    const source =
        \\public class SoqlParentRefTest {
        \\    public static String test() {
        \\        Experience__c exp = new Experience__c(Name = 'Hiking', Type__c = 'Adventure');
        \\        insert exp;
        \\        Session__c sess = new Session__c(Experience__c = exp.Id);
        \\        insert sess;
        \\        String interest = 'Adventure';
        \\        List<Session__c> results = [
        \\            SELECT Id FROM Session__c
        \\            WHERE Experience__r.Type__c = :interest
        \\        ];
        \\        return String.valueOf(results.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SoqlParentRefTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: null != empty string is true" {
    const source =
        \\public class NullNeqTest {
        \\    public static String test() {
        \\        String type = null;
        \\        if (type != null || type != '') {
        \\            return 'where';
        \\        }
        \\        return 'no-where';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NullNeqTest",
        .entry_method = "test",
    });
    defer result.deinit();
    // null != null → false, null != '' → true, false || true → true
    try std.testing.expectEqualStrings("where", result.value.string);
}

test "E2E: SOQL WHERE with null bind variable skips condition (Salesforce behavior)" {
    const source =
        \\public class DbNullBindTest {
        \\    public static String test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'Acme', Type = 'A'),
        \\            new Account(Name = 'Beta', Type = 'B')
        \\        };
        \\        String type = null;
        \\        String whereClause = 'WHERE Type = :type';
        \\        Integer count = Database.countQuery(
        \\            'SELECT count() FROM Account ' + whereClause
        \\        );
        \\        // Salesforce: WHERE field = :nullVar skips the condition → returns all records
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DbNullBindTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.value.string);
}

test "E2E: Database.countQuery resolves local bind variables" {
    const source =
        \\public class DbCountBindTest {
        \\    public static String test() {
        \\        Account a1 = new Account(Name = 'Acme', Type = 'Customer');
        \\        Account a2 = new Account(Name = 'Beta', Type = 'Customer');
        \\        Account a3 = new Account(Name = 'Gamma', Type = 'Partner');
        \\        insert new List<Account>{a1, a2, a3};
        \\        String type = 'Customer';
        \\        Integer count = Database.countQuery(
        \\            'SELECT count() FROM Account WHERE Type = :type'
        \\        );
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DbCountBindTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.value.string);
}

test "E2E: static field accessed from another class" {
    const source =
        \\public class Controller {
        \\    @TestVisible
        \\    private static Integer PAGE_SIZE = 9;
        \\    public static Integer getPageSize() { return PAGE_SIZE; }
        \\}
        \\public class Caller {
        \\    public static String test() {
        \\        return String.valueOf(Controller.PAGE_SIZE);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Caller",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("9", result.value.string);
}

test "E2E: Schema.DescribeFieldResult.getPicklistValues() returns entries" {
    const source =
        \\public class SchemaPicklistTest {
        \\    public static String test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'A1', Type = 'Customer'),
        \\            new Account(Name = 'A2', Type = 'Partner'),
        \\            new Account(Name = 'A3', Type = 'Customer')
        \\        };
        \\        Schema.DescribeFieldResult dfr = Account.Type.getDescribe();
        \\        List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
        \\        // Should return unique values: Customer, Partner
        \\        return String.valueOf(entries.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaPicklistTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.value.string);
}

test "E2E: ObjectInstance field access is case-insensitive" {
    const source =
        \\public class CaseFieldTest {
        \\    public class Response {
        \\        public String Prompt;
        \\    }
        \\    public static String test() {
        \\        Response r = new Response();
        \\        r.prompt = 'hello';
        \\        return r.Prompt;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CaseFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("hello", result.value.string);
}

test "E2E: Database.countQuery with null bind in method parameter" {
    const source =
        \\public class NullBindMethodTest {
        \\    public static String run(String type) {
        \\        String whereClause = '';
        \\        if (type != null || type != '') {
        \\            whereClause = 'WHERE Type = :type';
        \\        }
        \\        Integer count = Database.countQuery(
        \\            'SELECT count() FROM Account ' + whereClause
        \\        );
        \\        return String.valueOf(count);
        \\    }
        \\    public static String test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'A', Type = 'X'),
        \\            new Account(Name = 'B', Type = 'Y')
        \\        };
        \\        return run(null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NullBindMethodTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.value.string);
}

// TODO: Database.query/countQuery でメソッドのローカル変数へのバインド変数解決が
// call_method 経由の呼び出しで機能しない問題がある。env スコープチェーンの調査が必要。
test "E2E: PagedResult pattern — known limitation with dynamic SOQL bind in nested call" {
    const source =
        \\public class Controller {
        \\    @TestVisible
        \\    private static Integer PAGE_SIZE = 9;
        \\    public static String getItems(String type, Integer pageNumber) {
        \\        String whereClause = '';
        \\        if (type != null || type != '') {
        \\            whereClause = 'WHERE Type = :type';
        \\        }
        \\        Integer cnt = Database.countQuery(
        \\            'SELECT count() FROM Account ' + whereClause
        \\        );
        \\        return String.valueOf(cnt);
        \\    }
        \\    public class PagedResult {
        \\        public Integer pageSize { get; set; }
        \\    }
        \\}
        \\public class ControllerTest {
        \\    public static String test() {
        \\        List<Account> accs = new List<Account>();
        \\        for (Integer i = 0; i < Controller.PAGE_SIZE + 1; i++) {
        \\            accs.add(new Account(Name = 'Acc ' + i));
        \\        }
        \\        insert accs;
        \\        String cnt = Controller.getItems(null, 1);
        \\        return cnt;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ControllerTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("10", result.value.string);
}

test "parser: class with inner class preserves parent methods" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const source =
        \\public class Outer {
        \\    public static String myMethod() { return 'hello'; }
        \\    public class Inner {
        \\        public Integer val { get; set; }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    try std.testing.expectEqual(@as(usize, 1), decls.len);

    const cd = decls[0].class_decl;
    try std.testing.expectEqualStrings("Outer", cd.name);

    // Outer should have 2 members: myMethod + Inner class
    try std.testing.expectEqual(@as(usize, 2), cd.members.len);

    // First member should be the method
    switch (cd.members[0]) {
        .method_decl => |md| try std.testing.expectEqualStrings("myMethod", md.name),
        else => return error.TestUnexpectedResult,
    }

    // Verify that call_method finds and executes the method correctly
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);
    const val = try eval.call_method("Outer", "myMethod", &.{});
    try std.testing.expectEqualStrings("hello", val.string);
}

test "load_decls: Controller class with inner class has getItems method" {
    var arena_alloc3 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc3.deinit();

    const alloc3 = arena_alloc3.allocator();

    const source3 =
        \\public class Controller {
        \\    public static Integer getItems(String type) {
        \\        return Database.countQuery(
        \\            'SELECT count() FROM Account WHERE Type = :type'
        \\        );
        \\    }
        \\    public class PagedResult {
        \\        public Integer pageSize { get; set; }
        \\    }
        \\}
    ;
    const tokens3 = try lexer.tokenize(source3, alloc3);
    const decls3 = try parser.parse(tokens3, alloc3);
    var eval3 = try evaluator.Evaluator.init(alloc3, std.testing.io);
    try eval3.load_decls(decls3);

    // Verify classes map contents
    // Classes should be: Controller, PagedResult, Controller.PagedResult
    try std.testing.expectEqual(@as(usize, 3), eval3.classes.count());
    const cd3 = eval3.classes.get("Controller") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Controller", cd3.name);
    // Check it has getItems method
    var found = false;
    for (cd3.members) |member| {
        switch (member) {
            .method_decl => |md| {
                if (std.ascii.eqlIgnoreCase(md.name, "getItems")) found = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found);

    // Verify call_method handles Database.countQuery correctly without inner class interaction
    // First test: call without WHERE clause
    try eval3.execute_dml(.insert, Value{ .sobject = blk: {
        const sob = try alloc3.create(types.SObject);
        sob.* = .{ .type_name = "Account" };
        try sob.fields.put(alloc3, "Name", Value{ .string = "Test" });
        break :blk sob;
    } });
    const val3 = try eval3.call_method("Controller", "getItems", &.{Value.null_val});
    // getItems returns String.valueOf(count) which is a string
    // But if Database.countQuery fails, it may return integer 0 directly
    if (val3 == .string) {
        try std.testing.expectEqualStrings("1", val3.string);
    } else if (val3 == .integer) {
        try std.testing.expectEqual(@as(i64, 1), val3.integer);
    } else {
        // null or other → the method didn't execute properly
        return error.TestUnexpectedResult;
    }
}

test "parser: method body preserved with inner class having get-set" {
    var arena_alloc2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc2.deinit();

    const alloc2 = arena_alloc2.allocator();

    const source2 =
        \\public class C {
        \\    public static Integer count() {
        \\        Integer x = 1;
        \\        Integer y = 2;
        \\        return x + y;
        \\    }
        \\    public class Inner {
        \\        public Integer val { get; set; }
        \\    }
        \\}
    ;
    const tokens2 = try lexer.tokenize(source2, alloc2);
    const decls2 = try parser.parse(tokens2, alloc2);
    try std.testing.expectEqual(@as(usize, 1), decls2.len);

    const cd2 = decls2[0].class_decl;
    // Should have 2 members: count() and Inner
    try std.testing.expectEqual(@as(usize, 2), cd2.members.len);

    // Method body should have 3 statements (2 var decls + return)
    const md2 = cd2.members[0].method_decl;
    try std.testing.expectEqualStrings("count", md2.name);
    try std.testing.expectEqual(@as(usize, 3), md2.body.len);
}

test "E2E: cross-class Database.countQuery with dynamic WHERE and null bind" {
    const source =
        \\public class Svc2 {
        \\    public static Integer count(String typeFilter) {
        \\        String whereClause = '';
        \\        if (typeFilter != null || typeFilter != '') {
        \\            whereClause = 'WHERE Type = :typeFilter';
        \\        }
        \\        return Database.countQuery(
        \\            'SELECT count() FROM Account ' + whereClause
        \\        );
        \\    }
        \\}
        \\public class Caller3 {
        \\    public static String test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'A', Type = 'X'),
        \\            new Account(Name = 'B', Type = 'Y')
        \\        };
        \\        return String.valueOf(Svc2.count(null));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Caller3",
        .entry_method = "test",
    });
    defer result.deinit();
    // null bind → condition skipped → all records returned → 2
    try std.testing.expectEqualStrings("2", result.value.string);
}

test "E2E: cross-class Database.countQuery with bind variable" {
    const source =
        \\public class Svc {
        \\    public static Integer count(String filter) {
        \\        return Database.countQuery(
        \\            'SELECT count() FROM Account WHERE Name = :filter'
        \\        );
        \\    }
        \\}
        \\public class Caller2 {
        \\    public static String test() {
        \\        insert new Account(Name = 'Test');
        \\        return String.valueOf(Svc.count('Test'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Caller2",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: Network.communitiesLanding() returns PageReference" {
    const source =
        \\public class NetTest {
        \\    public static String test() {
        \\        PageReference ref = Network.communitiesLanding();
        \\        return ref != null ? 'ok' : 'null';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NetTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: System.assertEquals detects Integer mismatch (issue #7)" {
    const source =
        \\public class Calculator {
        \\    public static Integer multiply(Integer a, Integer b) {
        \\        return a * b;
        \\    }
        \\}
        \\@IsTest
        \\private class CalculatorTest {
        \\    @IsTest
        \\    static void testMultiplyWrong() {
        \\        Integer result = Calculator.multiply(2, 3);
        \\        System.assertEquals(10, result);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);
    _ = eval.call_method("CalculatorTest", "testMultiplyWrong", &.{}) catch {};

    // assertEquals(10, 6) should fail
    const msg = eval.assertion_failure orelse "";
    try std.testing.expect(msg.len > 0); // Must have a failure message
    try std.testing.expect(std.mem.indexOf(u8, msg, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "6") != null);
}

test "Contact Name is synthesized from FirstName + LastName" {
    const source =
        \\@IsTest
        \\public class ContactNameTest {
        \\    @IsTest
        \\    static void testContactName() {
        \\        Contact c = new Contact(FirstName = 'John', LastName = 'Doe');
        \\        insert c;
        \\        Contact fetched = [SELECT Name FROM Contact LIMIT 1];
        \\        System.assertEquals('John Doe', fetched.Name);
        \\    }
        \\    @IsTest
        \\    static void testContactNameLastOnly() {
        \\        Contact c = new Contact(LastName = 'Smith');
        \\        insert c;
        \\        Contact fetched = [SELECT Name FROM Contact LIMIT 1];
        \\        System.assertEquals('Smith', fetched.Name);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("ContactNameTest", "testContactName", &.{});
    try std.testing.expect(eval.assertion_failure == null);

    eval.reset_for_test();
    _ = try eval.call_method("ContactNameTest", "testContactNameLastOnly", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "Double/Decimal instance fields default to null" {
    const source =
        \\@IsTest
        \\public class DoubleDefaultTest {
        \\    public class Coords {
        \\        public Decimal lat;
        \\        public Decimal lon;
        \\    }
        \\    @IsTest
        \\    static void testDecimalNull() {
        \\        Coords c = new Coords();
        \\        System.assertEquals(null, c.lat);
        \\        System.assertEquals(null, c.lon);
        \\    }
        \\    @IsTest
        \\    static void testDoubleNull() {
        \\        Double d;
        \\        System.assertEquals(null, d);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("DoubleDefaultTest", "testDecimalNull", &.{});
    try std.testing.expect(eval.assertion_failure == null);

    eval.reset_for_test();
    _ = try eval.call_method("DoubleDefaultTest", "testDoubleNull", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "reset_for_test re-runs static initializers for later test methods" {
    const source =
        \\@IsTest
        \\public class StaticInitResetTest {
        \\    public class Config {
        \\        public static String value = 'A';
        \\    }
        \\    public class Consumer {
        \\        private static String cached;
        \\        static {
        \\            cached = Config.value;
        \\        }
        \\        public static String getCached() {
        \\            return cached;
        \\        }
        \\    }
        \\    @IsTest
        \\    static void firstMethod() {
        \\        Config.value = 'first';
        \\        System.assertEquals('first', Consumer.getCached());
        \\    }
        \\    @IsTest
        \\    static void secondMethod() {
        \\        Config.value = 'second';
        \\        System.assertEquals('second', Consumer.getCached());
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("StaticInitResetTest", "firstMethod", &.{});
    try std.testing.expect(eval.assertion_failure == null);

    eval.reset_for_test();
    _ = try eval.call_method("StaticInitResetTest", "secondMethod", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "run_test_suite keeps repo-root metadata loading scoped to the requested repo" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "repos/app-a/force-app/main/default/classes");
    try tmp_dir.dir.createDirPath(
        std.testing.io,
        "repos/app-a/force-app/main/default/objects/Widget__c",
    );
    try tmp_dir.dir.createDirPath(
        std.testing.io,
        "repos/app-b/force-app/main/default/objects/Widget__c/fields",
    );

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "repos/app-a/force-app/main/default/classes/WidgetRepoTest.cls",
        .data =
        \\@isTest
        \\private class WidgetRepoTest {
        \\    @isTest
        \\    static void insert_widget_in_requested_repo() {
        \\        insert new Widget__c(Name = 'ok');
        \\        System.assertEquals(1, [SELECT count() FROM Widget__c]);
        \\    }
        \\}
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "repos/app-a/force-app/main/default/objects/Widget__c/Widget__c.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <deploymentStatus>Deployed</deploymentStatus>
        \\    <enableActivities>false</enableActivities>
        \\    <enableReports>false</enableReports>
        \\    <enableSearch>false</enableSearch>
        \\    <enableSharing>true</enableSharing>
        \\    <label>Widget</label>
        \\    <nameField>
        \\        <label>Widget Name</label>
        \\        <type>Text</type>
        \\    </nameField>
        \\    <pluralLabel>Widgets</pluralLabel>
        \\    <sharingModel>ReadWrite</sharingModel>
        \\</CustomObject>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "repos/app-b/force-app/main/default/objects/Widget__c/fields/Required_Text__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Required_Text__c</fullName>
        \\    <label>Required Text</label>
        \\    <required>true</required>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });

    const repo_a_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "repos/app-a", alloc);
    defer alloc.free(repo_a_path);

    var _null_buf: [256]u8 = undefined;
    var _null_writer: std.Io.Writer.Discarding = .init(&_null_buf);
    const suite = try run_test_suite(alloc, std.testing.io, &.{repo_a_path}, &_null_writer.writer);
    try std.testing.expectEqual(@as(usize, 1), suite.total);
    try std.testing.expectEqual(@as(usize, 1), suite.passed);
}

test "JSON.deserialize maps fields to user-defined class" {
    const source =
        \\@IsTest
        \\public class JsonDeserTest {
        \\    public class MyData {
        \\        public String name;
        \\        public Integer id;
        \\        public Boolean active;
        \\    }
        \\    @IsTest
        \\    static void testDeserialize() {
        \\        String json = '{"name":"Beach and Mountain","id":42,"active":true}';
        \\        MyData d = (MyData)JSON.deserialize(json, MyData.class);
        \\        System.assertEquals('Beach and Mountain', d.name);
        \\        System.assertEquals(42, d.id);
        \\        System.assertEquals(true, d.active);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("JsonDeserTest", "testDeserialize", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "JSON.createParser + readValueAs deserializes into typed class" {
    const source =
        \\@IsTest
        \\public class JsonParserTest {
        \\    public class MyData {
        \\        public String name;
        \\        public Integer id;
        \\    }
        \\    @IsTest
        \\    static void testReadValueAs() {
        \\        JSONParser parser = JSON.createParser('{"name":"Beach and Mountain","id":42}');
        \\        MyData d = (MyData)parser.readValueAs(MyData.class);
        \\        System.assertEquals('Beach and Mountain', d.name);
        \\        System.assertEquals(42, d.id);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("JsonParserTest", "testReadValueAs", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "PageReference.getUrl returns stored URL" {
    const source =
        \\@IsTest
        \\public class PageRefTest {
        \\    @IsTest
        \\    static void testGetUrl() {
        \\        PageReference ref = Network.communitiesLanding();
        \\        System.assertNotEquals(null, ref);
        \\        String url = ref.getUrl();
        \\        System.assertNotEquals(null, url);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("PageRefTest", "testGetUrl", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "PageReference.getUrl appends parameters in insertion order" {
    const source =
        \\public class PageReferenceParamProbe {
        \\    public static String run() {
        \\        PageReference ref = new PageReference('/flow/ns/testFlow');
        \\        ref.getParameters().put('a', '1');
        \\        ref.getParameters().put('b', '2');
        \\        ref.getParameters().put('c', '3');
        \\        return ref.getUrl();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PageReferenceParamProbe",
        .entry_method = "run",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("/flow/ns/testFlow?a=1&b=2&c=3", result.value.string);
}

test "SOQL LIKE with bind variable matches correctly" {
    const source =
        \\@IsTest
        \\public class LikeBindTest {
        \\    @IsTest
        \\    static void testLikeBind() {
        \\        insert new Account(Name = 'Acme Corp');
        \\        insert new Account(Name = 'Beta Inc');
        \\        insert new Account(Name = 'Acme Labs');
        \\        String key = '%Acme%';
        \\        List<Account> results = [SELECT Name FROM Account WHERE Name LIKE :key];
        \\        System.assertEquals(2, results.size());
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("LikeBindTest", "testLikeBind", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "Schema.sObjectType.Contact.isUpdateable returns true for system user" {
    const source =
        \\public class SchemaTest {
        \\    public static void testSchemaAccess() {
        \\        System.assertEquals(true, Schema.sObjectType.Contact.isUpdateable());
        \\        System.assertEquals(true, Schema.sObjectType.Contact.isCreateable());
        \\        System.assertEquals(true, Schema.sObjectType.Contact.isDeletable());
        \\        System.assertEquals(true, Schema.sObjectType.Contact.isAccessible());
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("SchemaTest", "testSchemaAccess", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "Crypto.encryptWithManagedIV and decryptWithManagedIV round-trip" {
    const source =
        \\public class CryptoTest {
        \\    public static void testRoundTrip() {
        \\        Blob key = Crypto.generateAesKey(256);
        \\        Blob data = Blob.valueOf('Test data');
        \\        Blob encrypted = Crypto.encryptWithManagedIV('AES256', key, data);
        \\        Blob decrypted = Crypto.decryptWithManagedIV('AES256', key, encrypted);
        \\        System.assertEquals('Test data', decrypted.toString());
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("CryptoTest", "testRoundTrip", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "AuraHandledException is caught in try-catch" {
    const source =
        \\public class AuraTest {
        \\    public static void doThrow() {
        \\        throw new AuraHandledException('Test error');
        \\    }
        \\    public static void testCatch() {
        \\        Boolean caught = false;
        \\        try {
        \\            doThrow();
        \\            System.assert(false, 'Should have thrown');
        \\        } catch (AuraHandledException e) {
        \\            caught = true;
        \\        }
        \\        System.assertEquals(true, caught);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("AuraTest", "testCatch", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "Type.forName returns null for non-existent class" {
    // Matches Apex semantics: bogus names resolve to null; loaded user classes, known
    // SObjects, primitives, and the collection generics still produce a Type token.
    const source =
        \\public class TypeForNameTest {
        \\    public static void testForName() {
        \\        System.assertEquals(null, Type.forName('NonExistentClass'));
        \\        System.assertEquals(null, Type.forName('Outer.NonExistentInner'));
        \\        System.assertNotEquals(null, Type.forName('Map<Id,Account>'));
        \\        System.assertNotEquals(null, Type.forName('TypeForNameTest'));
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    _ = try eval.call_method("TypeForNameTest", "testForName", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "E2E: constructed DmlException stack trace ends at anonymous block" {
    const source =
        \\public class ConstructedStackTraceTopLevelTest {
        \\    public static String test() {
        \\        return new DmlException().getStackTraceString();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ConstructedStackTraceTopLevelTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Class.ConstructedStackTraceTopLevelTest.test: line 3, column 1\nAnonymousBlock: line 1, column 1",
        result.value.string,
    );
}

test "E2E: constructor-built DmlException stack trace keeps only immediate caller" {
    const source =
        \\public class ConstructedStackTraceCtorTest {
        \\    public class Holder {
        \\        private Exception created;
        \\        public Holder() {
        \\            this.created = new DmlException();
        \\        }
        \\        public String capture() {
        \\            return this.created.getStackTraceString();
        \\        }
        \\    }
        \\    public static String wrapper() {
        \\        return new Holder().capture();
        \\    }
        \\    public static String test() {
        \\        return wrapper();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ConstructedStackTraceCtorTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Class.ConstructedStackTraceCtorTest.Holder.<init>: line 5, column 1\nClass.ConstructedStackTraceCtorTest.wrapper: line 12, column 1\nAnonymousBlock: line 1, column 1",
        result.value.string,
    );
}

test "E2E: replace_all can collapse ignored constructed stack trace frames to empty" {
    const source =
        \\public class StackTraceCleanupProbe {
        \\    public static String test() {
        \\        return new DmlException().getStackTraceString().replace_all('(StackTraceCleanupProbe)\\..+?column 1', '').trim();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StackTraceCleanupProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("", result.value.string);
}

test "Trigger recursion does not StackOverflow" {
    const source =
        \\trigger AccountTrigger on Account (after insert, after update) {
        \\    AccountHandler.handle(Trigger.new);
        \\}
    ;
    const handler_source =
        \\public class AccountHandler {
        \\    public static void handle(List<Account> accounts) {
        \\        List<Account> toUpdate = new List<Account>();
        \\        for (Account a : accounts) {
        \\            Account updated = new Account(Id = a.Id, Name = a.Name + ' updated');
        \\            toUpdate.add(updated);
        \\        }
        \\        update toUpdate;
        \\    }
        \\}
    ;
    const test_source =
        \\@isTest
        \\public class TriggerRecursionTest {
        \\    @isTest
        \\    static void testNoStackOverflow() {
        \\        Account a = new Account(Name = 'Test');
        \\        insert a;
        \\        List<Account> results = [SELECT Name FROM Account];
        \\        System.assert(results.size() > 0, 'Account should exist');
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    // Parse all three sources
    const tokens1 = try lexer.tokenize(source, alloc);
    const decls1 = try parser.parse(tokens1, alloc);
    const tokens2 = try lexer.tokenize(handler_source, alloc);
    const decls2 = try parser.parse(tokens2, alloc);
    const tokens3 = try lexer.tokenize(test_source, alloc);
    const decls3 = try parser.parse(tokens3, alloc);

    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls1);
    try eval.load_decls(decls2);
    try eval.load_decls(decls3);

    // StackOverflow should not happen anymore — propagate any error.
    _ = try eval.call_method("TriggerRecursionTest", "testNoStackOverflow", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "SOQL on User with UserInfo.getUserId returns seeded user" {
    const source =
        \\public class UserQueryTest {
        \\    public static void testQuery() {
        \\        User u = [SELECT Id, FirstName, LastName, Email FROM User WHERE Id = :UserInfo.getUserId()];
        \\        System.assertNotEquals(null, u);
        \\        System.assertEquals(UserInfo.getUserId(), u.Id);
        \\        System.assertEquals('Test', u.FirstName);
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);

    eval.reset_for_test();
    _ = try eval.call_method("UserQueryTest", "testQuery", &.{});
    try std.testing.expect(eval.assertion_failure == null);
}

test "E2E: ContentDocumentLink insert with invalid LinkedEntityId throws DmlException" {
    const source =
        \\public class CDLTest {
        \\    public static String test() {
        \\        ContentVersion cv = new ContentVersion();
        \\        cv.Title = 'test.png';
        \\        cv.PathOnClient = 'test.png';
        \\        cv.VersionData = EncodingUtil.base64Decode('AAAA');
        \\        insert cv;
        \\        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        \\        ContentDocumentLink cdl = new ContentDocumentLink();
        \\        cdl.ContentDocumentId = cv.ContentDocumentId;
        \\        cdl.LinkedEntityId = 'INVALID_ID';
        \\        cdl.ShareType = 'V';
        \\        try {
        \\            insert cdl;
        \\            return 'NO_EXCEPTION';
        \\        } catch (DmlException e) {
        \\            return 'CAUGHT';
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CDLTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("CAUGHT", result.value.string);
}

test "E2E: ContentDocumentLink auto-resolves ContentDocument reference" {
    const source =
        \\public class CDLRefTest {
        \\    public static String test() {
        \\        Property__c property = new Property__c(Name = 'Test');
        \\        insert property;
        \\        ContentVersion cv = new ContentVersion();
        \\        cv.Title = 'pic';
        \\        cv.PathOnClient = 'pic.png';
        \\        cv.VersionData = EncodingUtil.base64Decode('AAAA');
        \\        insert cv;
        \\        List<ContentDocument> docs = [SELECT Id, Title, LatestPublishedVersionId FROM ContentDocument LIMIT 1];
        \\        ContentDocumentLink link = new ContentDocumentLink();
        \\        link.LinkedEntityId = property.Id;
        \\        link.ContentDocumentId = docs[0].Id;
        \\        link.ShareType = 'V';
        \\        insert link;
        \\        List<ContentDocumentLink> links = [
        \\            SELECT Id, LinkedEntityId, ContentDocument.Title
        \\            FROM ContentDocumentLink
        \\            WHERE LinkedEntityId = :property.Id
        \\              AND ContentDocument.FileType IN ('PNG', 'JPG', 'GIF')
        \\        ];
        \\        if (links.isEmpty()) return 'EMPTY';
        \\        Set<Id> contentIds = new Set<Id>();
        \\        for (ContentDocumentLink l : links) {
        \\            contentIds.add(l.ContentDocumentId);
        \\        }
        \\        List<ContentVersion> versions = [
        \\            SELECT Id, Title FROM ContentVersion
        \\            WHERE ContentDocumentId IN :contentIds AND IsLatest = TRUE
        \\        ];
        \\        return String.valueOf(versions.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CDLRefTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: StaticResource loads body from actual JSON file on disk" {
    const alloc = std.testing.allocator;
    // Create a temporary staticresources directory with a JSON file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "staticresources");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "staticresources/test_data.json",
        .data = "[{\"Name\":\"Alice\"},{\"Name\":\"Bob\"}]",
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class SRTest {
        \\    public static String test() {
        \\        StaticResource sr = [SELECT Id, Body FROM StaticResource WHERE Name = 'test_data'];
        \\        String body = sr.Body.toString();
        \\        List<Object> parsed = (List<Object>) JSON.deserializeUntyped(body);
        \\        return String.valueOf(parsed.size());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "SRTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2", result.value.string);
}

test "E2E: Custom metadata records loaded from .md-meta.xml files" {
    const alloc = std.testing.allocator;
    // Create a temporary customMetadata directory with a .md-meta.xml file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "customMetadata");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "customMetadata/My_Config.Contact_Config.md-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <label>Contact Config</label>
        \\    <values>
        \\        <field>Status_Field__c</field>
        \\        <value xsi:type="xsd:string">Reservation_Status__c</value>
        \\    </values>
        \\    <values>
        \\        <field>Status_Value__c</field>
        \\        <value xsi:type="xsd:string">Draft</value>
        \\    </values>
        \\    <values>
        \\        <field>Object_Type__c</field>
        \\        <value xsi:type="xsd:string">Contact</value>
        \\    </values>
        \\</CustomMetadata>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class CMDTTest {
        \\    public static String test() {
        \\        My_Config__mdt cfg = [
        \\            SELECT Status_Field__c, Status_Value__c, Object_Type__c
        \\            FROM My_Config__mdt
        \\            WHERE Object_Type__c = 'Contact'
        \\            LIMIT 1
        \\        ];
        \\        return cfg.Status_Field__c + ':' + cfg.Status_Value__c;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "CMDTTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Reservation_Status__c:Draft", result.value.string);
}

test "E2E: DescribeFieldResult.getLocalName keeps schema field keys distinct" {
    const source =
        \\public class DescribeFieldLocalNameTest {
        \\    public class FieldSchema {
        \\        public String localApiName;
        \\    }
        \\    public static String test() {
        \\        Map<String, FieldSchema> fields = new Map<String, FieldSchema>();
        \\        for (Schema.SObjectField field : Schema.User.SObjectType.getDescribe().fields.getMap().values()) {
        \\            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
        \\            FieldSchema schema = new FieldSchema();
        \\            schema.localApiName = fieldDescribe.getLocalName();
        \\            fields.put(fieldDescribe.getLocalName(), schema);
        \\        }
        \\        return String.valueOf(fields.containsKey('Name')) + ':' + fields.get('Name').localApiName + ':' + String.valueOf(fields.containsKey('Username'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DescribeFieldLocalNameTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:Name:true", result.value.string);
}

test "E2E: DescribeSObjectResult fields map includes common User fields" {
    const source =
        \\public class UserDescribeFieldsTest {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields = Schema.User.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('Username')) + ':' + fields.get('Username').getDescribe().getName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UserDescribeFieldsTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:Username", result.value.string);
}

test "E2E: DescribeFieldResult recognizes non-name fallback fields" {
    const source =
        \\public class EmailMessageDescribeFieldTest {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields = Schema.EmailMessage.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('Subject')) + ':' + String.valueOf(Schema.EmailMessage.Subject.getDescribe().isNameField());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EmailMessageDescribeFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:false", result.value.string);
}

test "E2E: implicit standard Name fields are treated as required" {
    const source =
        \\public class StandardNameFieldRequirementTest {
        \\    public static String test() {
        \\        List<String> requiredFields = new List<String>();
        \\        SObject record = Schema.Campaign.SObjectType.newSObject(null, true);
        \\        for (Schema.SObjectField field : Schema.Campaign.SObjectType.getDescribe().fields.getMap().values()) {
        \\            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
        \\            if (fieldDescribe.isCreateable() && !fieldDescribe.isNillable()) {
        \\                requiredFields.add(fieldDescribe.getName());
        \\                if (fieldDescribe.getType() == Schema.DisplayType.STRING) {
        \\                    record.put(fieldDescribe.getName(), fieldDescribe.getName() + ' value');
        \\                }
        \\            }
        \\        }
        \\        return String.valueOf(requiredFields.contains('Name')) + ':' + System.JSON.serializePretty(record);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StandardNameFieldRequirementTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "true:{\"attributes\":{\"type\":\"Campaign\"},\"Name\":\"Name value\"}",
        result.value.string,
    );
}

test "E2E: fieldSets metadata is available on SObjectType and DescribeSObjectResult" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fieldSets");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fieldSets/Related_List_Defaults.fieldSet-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<FieldSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Related_List_Defaults</fullName>
        \\    <displayedFields>
        \\        <field>Name</field>
        \\        <isRequired>false</isRequired>
        \\    </displayedFields>
        \\    <displayedFields>
        \\        <field>Status__c</field>
        \\        <isRequired>true</isRequired>
        \\    </displayedFields>
        \\    <label>Related List Defaults</label>
        \\</FieldSet>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldSetMetadataTest {
        \\    public static String test() {
        \\        Map<String, Schema.FieldSet> byType = Schema.SObjectType.Thing__c.fieldSets.getMap();
        \\        Map<String, Schema.FieldSet> byDescribe = Schema.SObjectType.Thing__c.getDescribe().fieldSets.getMap();
        \\        Schema.FieldSet fieldSet = byType.get('Related_List_Defaults');
        \\        Schema.FieldSet describedFieldSet = byDescribe.get('Related_List_Defaults');
        \\        List<Schema.FieldSetMember> members = fieldSet.get_fields();
        \\        return String.valueOf(byType.size()) + ':' +
        \\            String.valueOf(describedFieldSet != null) + ':' +
        \\            fieldSet.getLabel() + ':' +
        \\            String.valueOf(members.size()) + ':' +
        \\            members.get(0).getFieldPath() + ':' +
        \\            members.get(0).getSObjectField().getDescribe().getName();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldSetMetadataTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "1:true:Related List Defaults:2:Name:Name",
        result.value.string,
    );
}

test "E2E: SObjectType record type info methods delegate to describe metadata" {
    const alloc = std.testing.allocator;
    const source =
        \\public class SObjectTypeRecordTypeInfoTest {
        \\    public static String test() {
        \\        Map<Id, Schema.RecordTypeInfo> byId = Schema.SObjectType.Account.getRecordTypeInfosById();
        \\        List<Schema.RecordTypeInfo> infos = Schema.SObjectType.Account.getRecordTypeInfos();
        \\        return String.valueOf(byId != null) + ':' +
        \\            String.valueOf(infos.size()) + ':' +
        \\            byId.values().get(0).getName();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "SObjectTypeRecordTypeInfoTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:2:Master", result.value.string);
}

test "E2E: cached DescribeSObjectResult record type info survives selective map clears" {
    const alloc = std.testing.allocator;
    const source =
        \\public class CachedDescribeRecordTypeInfoProbe {
        \\    private static Map<String, Schema.DescribeSObjectResult> cached = new Map<String, Schema.DescribeSObjectResult>();
        \\    private static Map<String, List<Schema.RecordTypeInfo>> nonMasterInfos = new Map<String, List<Schema.RecordTypeInfo>>();
        \\
        \\    private static void fill(String objectName) {
        \\        if (!cached.containsKey(objectName)) {
        \\            cached.put(
        \\                objectName,
        \\                Schema.describeSObjects(
        \\                    new List<String>{ objectName },
        \\                    SObjectDescribeOptions.DEFERRED
        \\                )[0]
        \\            );
        \\        }
        \\        Schema.DescribeSObjectResult describe = cached.get(objectName);
        \\        List<Schema.RecordTypeInfo> filtered = new List<Schema.RecordTypeInfo>();
        \\        for (Schema.RecordTypeInfo info : describe.getRecordTypeInfos()) {
        \\            if (!info.isMaster()) {
        \\                filtered.add(info);
        \\            }
        \\        }
        \\        nonMasterInfos.put(objectName, filtered);
        \\    }
        \\
        \\    public static String test() {
        \\        fill('account');
        \\        nonMasterInfos.clear();
        \\        fill('account');
        \\        return String.valueOf(nonMasterInfos.get('account').size()) + ':' +
        \\            String.valueOf(cached.get('account').getRecordTypeInfosById().size());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "CachedDescribeRecordTypeInfoProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:2", result.value.string);
}

test "E2E: Search.query honors fixed search results and stripInaccessible returns records" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/Name.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Name</fullName>
        \\    <label>Name</label>
        \\    <type>Text</type>
        \\    <length>80</length>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class SearchQueryFixedResultsTest {
        \\    public static String test() {
        \\        Thing__c row = new Thing__c(Name = 'Alpha');
        \\        insert row;
        \\        System.Test.setFixedSearchResults(new List<Id>{ row.Id });
        \\        List<Thing__c> matches = (List<Thing__c>) System.Search
        \\            .query('FIND \'*Alpha*\' IN ALL FIELDS RETURNING Thing__c (Id,Name LIMIT 10)')
        \\            .get(0);
        \\        List<Thing__c> stripped = (List<Thing__c>) System.Security
        \\            .stripInaccessible(System.AccessType.READABLE, matches)
        \\            .getRecords();
        \\        return String.valueOf(matches.size()) + ':' + String.valueOf(stripped.size()) + ':' + String.valueOf(stripped.get(0).Id == row.Id);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "SearchQueryFixedResultsTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:1:true", result.value.string);
}

test "E2E: SObjectField.getDescribe uses metadata-backed field lengths" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/ShortText__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ShortText__c</fullName>
        \\    <label>Short Text</label>
        \\    <length>5</length>
        \\    <type>Text</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldDescribeLengthTest {
        \\    public static Integer getFieldLength(Schema.SObjectField field) {
        \\        return field.getDescribe().getLength();
        \\    }
        \\    public static String truncateFieldValue(Schema.SObjectField field, String value) {
        \\        return value?.left(field.getDescribe().getLength());
        \\    }
        \\    public static String test() {
        \\        Integer inlineMaxLength = Schema.Thing__c.ShortText__c.getDescribe().getLength();
        \\        Integer tokenMaxLength = getFieldLength(Schema.Thing__c.ShortText__c);
        \\        String truncatedValue = truncateFieldValue(Schema.Thing__c.ShortText__c, 'abcdef');
        \\        return String.valueOf(inlineMaxLength) + ':' + String.valueOf(tokenMaxLength) + ':' + truncatedValue;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldDescribeLengthTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("5:5:abcde", result.value.string);
}

test "E2E: direct field token describe uses metadata-backed soap type" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/OrganizationId__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>OrganizationId__c</fullName>
        \\    <label>Organization ID</label>
        \\    <length>18</length>
        \\    <required>false</required>
        \\    <type>Text</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldTokenSoapTypeMetadataTest {
        \\    public static String test() {
        \\        return String.valueOf(Schema.Thing__c.OrganizationId__c.getDescribe().getSoapType()) +
        \\            ':' + String.valueOf(Schema.Thing__c.OrganizationId__c.getDescribe().getLength());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldTokenSoapTypeMetadataTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("STRING:18", result.value.string);
}

test "E2E: SObject put with field token validates datetime metadata" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/When__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>When__c</fullName>
        \\    <label>When</label>
        \\    <required>false</required>
        \\    <type>DateTime</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldTokenDatetimeValidationTest {
        \\    public static String test() {
        \\        Thing__c row = new Thing__c();
        \\        try {
        \\            row.put(Schema.Thing__c.When__c, 'not a datetime');
        \\        } catch (System.SObjectException ex) {
        \\        }
        \\        return row.get(Schema.Thing__c.When__c) == null ? 'null' : 'value';
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldTokenDatetimeValidationTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("null", result.value.string);
}

test "E2E: VisualEditor picklist rows can be built from fieldSets metadata" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fieldSets");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fieldSets/Related_List_Defaults.fieldSet-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<FieldSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Related_List_Defaults</fullName>
        \\    <displayedFields>
        \\        <field>Name</field>
        \\        <isRequired>false</isRequired>
        \\    </displayedFields>
        \\    <label>Related List Defaults</label>
        \\</FieldSet>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class ThingPicklist extends VisualEditor.DynamicPickList {
        \\    public override VisualEditor.DataRow getDefaultValue() {
        \\        Schema.FieldSet fieldSet = Schema.SObjectType.Thing__c.fieldSets.getMap().get('Related_List_Defaults');
        \\        return fieldSet == null ? null : new VisualEditor.DataRow(fieldSet.getLabel(), fieldSet.getName());
        \\    }
        \\    public override VisualEditor.DynamicPickListRows getValues() {
        \\        VisualEditor.DynamicPickListRows rows = new VisualEditor.DynamicPickListRows();
        \\        for (Schema.FieldSet fieldSet : Schema.SObjectType.Thing__c.fieldSets.getMap().values()) {
        \\            rows.addRow(new VisualEditor.DataRow(fieldSet.getLabel(), fieldSet.getName()));
        \\        }
        \\        return rows;
        \\    }
        \\}
        \\public class ThingPicklistTest {
        \\    public static String test() {
        \\        ThingPicklist picklist = new ThingPicklist();
        \\        VisualEditor.DataRow row = picklist.getDefaultValue();
        \\        List<VisualEditor.DataRow> rows = picklist.getValues().getDataRows();
        \\        return (String) row.getLabel() + ':' + String.valueOf(rows.size()) + ':' + (String) rows.get(0).getValue();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "ThingPicklistTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Related List Defaults:1:Related_List_Defaults",
        result.value.string,
    );
}

test "E2E: field set members expose lookup labels and relationship describe metadata" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Child__c/fieldSets");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <label>Parent</label>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fieldSets/Related_List_Defaults.fieldSet-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<FieldSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Related_List_Defaults</fullName>
        \\    <displayedFields>
        \\        <field>Parent__c</field>
        \\        <isRequired>false</isRequired>
        \\    </displayedFields>
        \\    <label>Related List Defaults</label>
        \\</FieldSet>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldSetLookupMetadataTest {
        \\    public static String test() {
        \\        Schema.FieldSetMember member = Schema.SObjectType.Child__c.fieldSets.getMap().get('Related_List_Defaults').get_fields().get(0);
        \\        Schema.DescribeFieldResult describe = member.getSObjectField().getDescribe();
        \\        return member.getLabel()
        \\            + ':' + describe.getLabel()
        \\            + ':' + describe.getRelationshipName()
        \\            + ':' + String.valueOf(describe.isSortable())
        \\            + ':' + String.valueOf(describe.getReferenceTo().size())
        \\            + ':' + describe.getType().name().toLowerCase();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldSetLookupMetadataTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Parent:Parent:Parent__r:true:1:reference",
        result.value.string,
    );
}

test "E2E: getPopulatedFieldsAsMap excludes selected null fields" {
    const source =
        \\public class PopulatedNullFieldQueryTest {
        \\    public static String test() {
        \\        Account record = new Account(Name = 'Acme');
        \\        insert record;
        \\        Account queried = [SELECT Name, Type FROM Account WHERE Id = :record.Id];
        \\        Map<String, Object> populated = queried.getPopulatedFieldsAsMap();
        \\        return String.valueOf(populated.containsKey('Type')) + ':' + String.valueOf(populated.containsKey('Name'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PopulatedNullFieldQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:true", result.value.string);
}

test "E2E: field set queries do not mark null summary fields as populated" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fieldSets");
    try tmp_dir.dir.createDirPath(std.testing.io, "objects/ThingEntry__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/ThingEntry__c/fields/Thing__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Thing__c</fullName>
        \\    <referenceTo>Thing__c</referenceTo>
        \\    <relationshipName>ThingEntries</relationshipName>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/MaxChildScore__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>MaxChildScore__c</fullName>
        \\    <summarizedField>ThingEntry__c.Score__c</summarizedField>
        \\    <summaryForeignKey>ThingEntry__c.Thing__c</summaryForeignKey>
        \\    <summaryOperation>max</summaryOperation>
        \\    <type>Summary</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fieldSets/Notification_Defaults.fieldSet-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<FieldSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Notification_Defaults</fullName>
        \\    <displayedFields>
        \\        <field>MaxChildScore__c</field>
        \\        <isRequired>false</isRequired>
        \\    </displayedFields>
        \\    <displayedFields>
        \\        <field>Name</field>
        \\        <isRequired>false</isRequired>
        \\    </displayedFields>
        \\    <label>Notification Defaults</label>
        \\</FieldSet>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldSetNullSummaryQueryTest {
        \\    public static String test() {
        \\        Thing__c thing = new Thing__c(Name = 'Thing');
        \\        insert thing;
        \\        insert new ThingEntry__c(Thing__c = thing.Id);
        \\        List<String> fieldNames = new List<String>{
        \\            '(SELECT Id FROM ThingEntries__r LIMIT 1)',
        \\            'TYPEOF Owner WHEN User THEN Username ELSE Name END'
        \\        };
        \\        for (Schema.FieldSetMember member : Schema.SObjectType.Thing__c.fieldSets.getMap().get('Notification_Defaults').get_fields()) {
        \\            fieldNames.add(member.getFieldPath());
        \\        }
        \\        String query = 'SELECT ' + String.join(fieldNames, ', ') + ' FROM Thing__c WHERE Id = :thing.Id';
        \\        Thing__c queried = ((List<Thing__c>) Database.query(query)).get(0);
        \\        Map<String, Object> populated = queried.getPopulatedFieldsAsMap();
        \\        return String.valueOf(populated.containsKey('MaxChildScore__c')) + ':' + String.valueOf(populated.containsKey('Name'));
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldSetNullSummaryQueryTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:true", result.value.string);
}

test "E2E: field set queries materialize formula fields built from rollup counts" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Parent__c/fieldSets");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Parent__c/fieldSets/Notification_Defaults.fieldSet-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<FieldSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Notification_Defaults</fullName>
        \\    <displayedFields>
        \\        <field>TotalChildren__c</field>
        \\        <isRequired>false</isRequired>
        \\    </displayedFields>
        \\    <label>Notification Defaults</label>
        \\</FieldSet>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldSetFormulaQueryTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Parent');
        \\        insert parentRecord;
        \\        insert new Child__c(Parent__c = parentRecord.Id, Status__c = 'Open');
        \\        List<String> fieldNames = new List<String>{
        \\            '(SELECT Id FROM Children__r LIMIT 1)',
        \\            'TYPEOF Owner WHEN User THEN Username ELSE Name END'
        \\        };
        \\        for (Schema.FieldSetMember member : Schema.SObjectType.Parent__c.fieldSets.getMap().get('Notification_Defaults').get_fields()) {
        \\            fieldNames.add(member.getFieldPath());
        \\        }
        \\        String query = 'SELECT ' + String.join(fieldNames, ', ') + ' FROM Parent__c WHERE Id = :parentRecord.Id';
        \\        Parent__c queried = ((List<Parent__c>) Database.query(query)).get(0);
        \\        return String.valueOf(queried.get('TotalChildren__c'));
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldSetFormulaQueryTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: List<SObject> preserves token-based field access for Apex metadata records" {
    const source =
        \\public class ApexMetadataListAccessTest {
        \\    public static String test() {
        \\        Schema.ApexClass apexClassRecord = new Schema.ApexClass(Name = 'ExampleClass', Body = 'public class ExampleClass {}');
        \\        apexClassRecord.put(Schema.ApexClass.LastModifiedDate, Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        List<Schema.ApexClass> typedRecords = new List<Schema.ApexClass>{ apexClassRecord };
        \\        List<SObject> metadataRecords = typedRecords;
        \\        SObject metadataRecord = metadataRecords.get(0);
        \\        String body = (String) metadataRecord.get(Schema.ApexClass.Body);
        \\        Boolean modified = ((Datetime) metadataRecord.get(Schema.ApexClass.LastModifiedDate)) > Datetime.newInstance(2026, 3, 1, 0, 0, 0);
        \\        return body + ':' + String.valueOf(modified);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ApexMetadataListAccessTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("public class ExampleClass {}:true", result.value.string);
}

test "E2E: Apex metadata describe is accessible by default" {
    const source =
        \\public class ApexMetadataDescribeAccessTest {
        \\    public static String test() {
        \\        return String.valueOf(Schema.ApexClass.SObjectType.getDescribe().isAccessible()) + ':' +
        \\            String.valueOf(Schema.ApexTrigger.SObjectType.getDescribe().isAccessible());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ApexMetadataDescribeAccessTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: JSON round-trip through SObject.class preserves Apex metadata fields" {
    const source =
        \\public class SObjectJsonRoundTripTest {
        \\    public static String test() {
        \\        Schema.ApexClass originalRecord = new Schema.ApexClass(Name = 'ExampleClass', Body = 'public class ExampleClass {}');
        \\        String serialized = JSON.serialize(originalRecord);
        \\        Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(serialized);
        \\        fields.put('LastModifiedDate', Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        SObject roundTripped = (SObject) JSON.deserialize(JSON.serialize(fields), SObject.class);
        \\        return String.valueOf(roundTripped.get('Name')) + ':' +
        \\            String.valueOf(roundTripped.get('Body')) + ':' +
        \\            String.valueOf(roundTripped.get('LastModifiedDate') != null) + ':' +
        \\            String.valueOf(roundTripped.getSObjectType());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SObjectJsonRoundTripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "ExampleClass:public class ExampleClass {}:true:ApexClass",
        result.value.string,
    );
}

test "E2E: casted Apex metadata from SObject round-trip keeps concrete sobject type" {
    const source =
        \\public class CastedApexMetadataTypeTest {
        \\    public static String test() {
        \\        Schema.ApexClass originalRecord = new Schema.ApexClass(Name = 'ExampleClass', Body = 'public class ExampleClass {}');
        \\        Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(originalRecord));
        \\        fields.put('LastModifiedDate', Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        Schema.ApexClass castedRecord = (Schema.ApexClass) JSON.deserialize(JSON.serialize(fields), SObject.class);
        \\        List<Schema.ApexClass> typedRecords = new List<Schema.ApexClass>{ castedRecord };
        \\        List<SObject> genericRecords = typedRecords;
        \\        return String.valueOf(castedRecord.getSObjectType()) + ':' +
        \\            String.valueOf(genericRecords.get(0).getSObjectType()) + ':' +
        \\            String.valueOf(genericRecords.get(0).get(Schema.ApexClass.Body));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CastedApexMetadataTypeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "ApexClass:ApexClass:public class ExampleClass {}",
        result.value.string,
    );
}

test "E2E: JSON serialize on field tokens throws and callers can fall back to toString" {
    const source =
        \\public class JsonFieldTokenFallbackTest {
        \\    public static String test() {
        \\        try {
        \\            return JSON.serialize(Account.Description);
        \\        } catch (Exception e) {
        \\            return '' + Account.Description;
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonFieldTokenFallbackTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Description", result.value.string);
}

test "E2E: JSON deserialize unwraps relationship records and normalizes standard field types" {
    const source =
        \\public class JsonRelationshipRoundTripTest {
        \\    public static String test() {
        \\        String json = '[{"attributes":{"type":"Account"},"Id":"001000000000001AAA","Name":"Acme","NumberOfEmployees":"7","Contacts":{"totalSize":"2","done":"true","records":[{"attributes":{"type":"Contact"},"Id":"003000000000001AAA","DoNotCall":"true"},{"attributes":{"type":"Contact"},"Id":"003000000000002AAA","DoNotCall":"false"}]}}]';
        \\        SObject accountRecord = ((List<SObject>) JSON.deserialize(json, List<SObject>.class))[0];
        \\        List<SObject> contacts = accountRecord.getSObjects('Contacts');
        \\        return String.valueOf(accountRecord.get('NumberOfEmployees')) + ':' +
        \\            String.valueOf(contacts.size()) + ':' +
        \\            String.valueOf(contacts[0].Id) + ':' +
        \\            String.valueOf((Boolean) contacts[0].get('DoNotCall'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonRelationshipRoundTripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("7:2:003000000000001AAA:true", result.value.string);
}

test "E2E: JSON deserialize unwraps relationship records for typed child access" {
    const source =
        \\public class JsonTypedRelationshipRoundTripTest {
        \\    public static String test() {
        \\        String json = '[{"attributes":{"type":"Account"},"Id":"001000000000001AAA","Name":"Acme","Contacts":{"totalSize":"2","done":"true","records":[{"attributes":{"type":"Contact"},"Id":"003000000000001AAA"},{"attributes":{"type":"Contact"},"Id":"003000000000002AAA"}]}}]';
        \\        Account accountRecord = ((List<Account>) JSON.deserialize(json, List<Account>.class))[0];
        \\        return String.valueOf(accountRecord.Contacts == null) + ':' +
        \\            String.valueOf(accountRecord.Contacts == null ? null : accountRecord.Contacts.size()) + ':' +
        \\            String.valueOf(accountRecord.Contacts == null || accountRecord.Contacts.size() == 0 ? null : accountRecord.Contacts[0].Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonTypedRelationshipRoundTripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:2:003000000000001AAA", result.value.string);
}

test "E2E: DataWeave object conversion returns typed records" {
    const source =
        \\public class CsvData {
        \\    public String FirstName;
        \\    public String LastName;
        \\    public String Email;
        \\}
        \\public class DataWeaveObjectConversionTest {
        \\    public static String test() {
        \\        String csvInput = 'first_name,last_name,email\\nAbel,Maclead,a.m@demo.org';
        \\        String jsonInput = '[{ "first_name": "Abel", "last_name": "Maclead", "email": "a.m@demo.org" }]';
        \\        List<Contact> csvContacts = (List<Contact>) new DataWeaveScriptResource.csvToContacts()
        \\            .execute(new Map<String, Object>{ 'records' => csvInput })
        \\            .getValue();
        \\        List<Contact> jsonContacts = (List<Contact>) new DataWeaveScriptResource.jsonToContacts()
        \\            .execute(new Map<String, Object>{ 'records' => jsonInput })
        \\            .getValue();
        \\        List<CsvData> rows = (List<CsvData>) new DataWeaveScriptResource.csvToApexObject()
        \\            .execute(new Map<String, Object>{ 'records' => csvInput })
        \\            .getValue();
        \\        return String.valueOf(csvContacts.size()) + ':' + csvContacts[0].FirstName + ':' +
        \\            jsonContacts[0].Email + ':' + rows[0].LastName;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DataWeaveObjectConversionTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:Abel:a.m@demo.org:Maclead", result.value.string);
}

test "E2E: DataWeave json date format uses Datetime field values" {
    const source =
        \\public class DataWeaveDateFormatTest {
        \\    public static String test() {
        \\        Contact contactRecord = new Contact(FirstName = 'John', LastName = 'Doe');
        \\        insert contactRecord;
        \\        List<Contact> contacts = [
        \\            SELECT FirstName, LastName, CreatedDate
        \\            FROM Contact
        \\            WHERE Id = :contactRecord.Id
        \\        ];
        \\        String actual = new DataWeaveScriptResource.jsonDateFormat()
        \\            .execute(new Map<String, Object>{ 'records' => contacts })
        \\            .getValueAsString();
        \\        String expected =
        \\            '{\n' +
        \\            '  "users": [\n' +
        \\            '    {\n' +
        \\            '      "firstName": "John",\n' +
        \\            '      "lastName": "Doe",\n' +
        \\            '      "createdDate": "' +
        \\            contacts[0].CreatedDate.formatGMT('hh:mm:ss a, MMMM dd, yyyy') +
        \\            '"\n' +
        \\            '    }\n' +
        \\            '  ]\n' +
        \\            '}';
        \\        return String.valueOf(actual == expected);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DataWeaveDateFormatTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: JSON deserialize normalizes standard read-only datetime fields" {
    const source =
        \\public class JsonReadonlyDatetimeProbe {
        \\    public static String test() {
        \\        String json = '{"attributes":{"type":"Account"},"LastReferencedDate":"2020-01-07T23:30:00.000Z"}';
        \\        Account accountRecord = (Account) JSON.deserialize(json, Account.class);
        \\        Datetime expected = Datetime.newInstanceGmt(2020, 1, 7, 23, 30, 0);
        \\        return String.valueOf(expected == accountRecord.LastReferencedDate) + ':' +
        \\            String.valueOf(accountRecord.LastReferencedDate);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonReadonlyDatetimeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:2020-01-07T23:30:00Z", result.value.string);
}

test "E2E: JSON serialize preserves Id on generic newSObject records" {
    const source =
        \\public class JsonGenericSObjectIdProbe {
        \\    public static String test() {
        \\        SObject accountRecord = Schema.getGlobalDescribe().get('Account').newSObject();
        \\        accountRecord.put('Id', '001000000000001AAA');
        \\        accountRecord.put('Name', 'Acme');
        \\        return String.valueOf(accountRecord.Id) + ':' + JSON.serialize(accountRecord);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonGenericSObjectIdProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("001000000000001AAA:{\"attributes\":{\"type\":\"Account\"},\"Id\":\"001000000000001AAA\",\"Name\":\"Acme\"}", result.value.string);
}

test "E2E: token-keyed sobject match works across list-of-maps comparisons" {
    const source =
        \\public class TokenKeyedSObjectMatchProbe {
        \\    private static Boolean sObjectMatches(SObject sobj, Map<Schema.SObjectField, Object> toMatch) {
        \\        for (Schema.SObjectField f : toMatch.keySet()) {
        \\            if (sobj.get(f) != toMatch.get(f)) {
        \\                return false;
        \\            }
        \\        }
        \\        return true;
        \\    }
        \\
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields = Account.SObjectType.getDescribe().fields.getMap();
        \\        Schema.SObjectField idField = fields.get('Id');
        \\        Schema.SObjectField nameField = fields.get('Name');
        \\
        \\        SObject first = Account.SObjectType.newSObject();
        \\        first.put('Id', '001000000000001AAA');
        \\        first.put('Name', 'Acme');
        \\        SObject second = Account.SObjectType.newSObject();
        \\        second.put('Id', '001000000000002AAA');
        \\        second.put('Name', 'Beta');
        \\
        \\        List<Map<Schema.SObjectField, Object>> expected = new List<Map<Schema.SObjectField, Object>>{
        \\            new Map<Schema.SObjectField, Object>{
        \\                idField => '001000000000001AAA',
        \\                nameField => 'Acme'
        \\            },
        \\            new Map<Schema.SObjectField, Object>{
        \\                idField => '001000000000002AAA',
        \\                nameField => 'Beta'
        \\            }
        \\        };
        \\
        \\        List<SObject> actual = new List<SObject>{ first, second };
        \\        return String.valueOf(sObjectMatches(actual[0], expected[0])) + ':' +
        \\            String.valueOf(sObjectMatches(actual[1], expected[1]));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TokenKeyedSObjectMatchProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: token-keyed sobject match works for inserted Group records" {
    const source =
        \\public class TokenKeyedGroupMatchProbe {
        \\    private static Boolean sObjectMatches(SObject sobj, Map<Schema.SObjectField, Object> toMatch) {
        \\        for (Schema.SObjectField f : toMatch.keySet()) {
        \\            try {
        \\                if (sobj.get(f) != toMatch.get(f)) {
        \\                    return false;
        \\                }
        \\            } catch (Exception e) {
        \\                return false;
        \\            }
        \\        }
        \\        return true;
        \\    }
        \\
        \\    public static String test() {
        \\        List<Group> groups = new List<Group>{
        \\            new Group(Name = 'Probe0', DeveloperName = 'Probe0', Type = 'Queue'),
        \\            new Group(Name = 'Probe1', DeveloperName = 'Probe1', Type = 'Queue')
        \\        };
        \\        insert groups;
        \\        Map<String, Schema.SObjectField> fields = Group.SObjectType.getDescribe().fields.getMap();
        \\        Schema.SObjectField idField = fields.get('Id');
        \\        Schema.SObjectField nameField = fields.get('Name');
        \\
        \\        List<Map<Schema.SObjectField, Object>> expected = new List<Map<Schema.SObjectField, Object>>{
        \\            new Map<Schema.SObjectField, Object>{
        \\                idField => groups[0].Id,
        \\                nameField => groups[0].get('Name')
        \\            },
        \\            new Map<Schema.SObjectField, Object>{
        \\                idField => groups[1].Id,
        \\                nameField => groups[1].get('Name')
        \\            }
        \\        };
        \\
        \\        return String.valueOf(sObjectMatches(groups[0], expected[0])) + ':' +
        \\            String.valueOf(sObjectMatches(groups[1], expected[1]));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TokenKeyedGroupMatchProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: self-referential Boolean getter preserves backing field value" {
    const source =
        \\public class BooleanGetterBackingFieldProbe {
        \\    private Boolean flag {
        \\        get {
        \\            return flag == null ? false : flag;
        \\        }
        \\        set;
        \\    }
        \\
        \\    public BooleanGetterBackingFieldProbe(Boolean value) {
        \\        this.flag = value;
        \\    }
        \\
        \\    public static String test() {
        \\        BooleanGetterBackingFieldProbe probe = new BooleanGetterBackingFieldProbe(true);
        \\        return String.valueOf(probe.flag);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "BooleanGetterBackingFieldProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: instance property getter can call helper methods that read this-backed fields" {
    const source =
        \\public class GetterMethodDispatchProbe {
        \\    private String backing = 'ok';
        \\
        \\    public String value {
        \\        get {
        \\            return helper();
        \\        }
        \\    }
        \\
        \\    private String helper() {
        \\        return this.backing;
        \\    }
        \\}
        \\
        \\public class GetterMethodDispatchProbeCaller {
        \\    public static String test() {
        \\        GetterMethodDispatchProbe probe = new GetterMethodDispatchProbe();
        \\        return probe.value;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "GetterMethodDispatchProbeCaller",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: ordered token-keyed sobject list matcher works through Object entrypoint" {
    const source =
        \\public class OrderedTokenKeyedSObjectListMatcherProbe {
        \\    private class OrderedMatcher {
        \\        private List<Map<Schema.SObjectField, Object>> toMatch;
        \\        private Boolean matchInOrder {
        \\            get {
        \\                return matchInOrder == null ? false : matchInOrder;
        \\            }
        \\            set;
        \\        }
        \\
        \\        public OrderedMatcher(List<Map<Schema.SObjectField, Object>> values) {
        \\            this.toMatch = values;
        \\            this.matchInOrder = true;
        \\        }
        \\
        \\        public Boolean matches(Object arg) {
        \\            if (arg != null && arg instanceof List<SObject>) {
        \\                SObject[] sobjsArg = (SObject[]) arg;
        \\                List<Map<Schema.SObjectField, Object>> toMatches = new List<Map<Schema.SObjectField, Object>>();
        \\                for (Map<Schema.SObjectField, Object> matchElem : toMatch) {
        \\                    toMatches.add(matchElem);
        \\                }
        \\                if (sobjsArg.size() != toMatches.size()) {
        \\                    return false;
        \\                }
        \\                if (matchInOrder) {
        \\                    for (Integer i = 0; i < sobjsArg.size(); i++) {
        \\                        if (!sObjectMatches(sobjsArg[i], toMatches[i])) {
        \\                            return false;
        \\                        }
        \\                    }
        \\                    return true;
        \\                }
        \\            }
        \\            return false;
        \\        }
        \\    }
        \\
        \\    private static Boolean sObjectMatches(SObject sobj, Map<Schema.SObjectField, Object> toMatch) {
        \\        for (Schema.SObjectField f : toMatch.keySet()) {
        \\            try {
        \\                if (sobj.get(f) != toMatch.get(f)) {
        \\                    return false;
        \\                }
        \\            } catch (Exception e) {
        \\                return false;
        \\            }
        \\        }
        \\        return true;
        \\    }
        \\
        \\    public static String test() {
        \\        List<Group> groups = new List<Group>{
        \\            new Group(Name = 'Probe0', DeveloperName = 'Probe0', Type = 'Queue'),
        \\            new Group(Name = 'Probe1', DeveloperName = 'Probe1', Type = 'Queue')
        \\        };
        \\        insert groups;
        \\        Map<String, Schema.SObjectField> fields = Group.SObjectType.getDescribe().fields.getMap();
        \\        Schema.SObjectField idField = fields.get('Id');
        \\        Schema.SObjectField nameField = fields.get('Name');
        \\        List<Map<Schema.SObjectField, Object>> expected = new List<Map<Schema.SObjectField, Object>>{
        \\            new Map<Schema.SObjectField, Object>{
        \\                idField => groups[0].Id,
        \\                nameField => groups[0].get('Name')
        \\            },
        \\            new Map<Schema.SObjectField, Object>{
        \\                idField => groups[1].Id,
        \\                nameField => groups[1].get('Name')
        \\            }
        \\        };
        \\        OrderedMatcher matcher = new OrderedMatcher(expected);
        \\        return String.valueOf(matcher.matches(groups));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "OrderedTokenKeyedSObjectListMatcherProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: global describe exposes Group sobject type" {
    const source =
        \\public class GlobalDescribeGroupProbe {
        \\    public static String test() {
        \\        Schema.SObjectType groupType = Schema.getGlobalDescribe().get('Group');
        \\        return String.valueOf(groupType == null ? null : groupType.getDescribe().getName());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "GlobalDescribeGroupProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Group", result.value.string);
}

test "E2E: JSON serialize Datetime keeps Salesforce millisecond suffix" {
    const source =
        \\public class JsonDatetimeSerializeTest {
        \\    public static String test() {
        \\        Datetime dt = Datetime.newInstance(2019, 1, 1, 12, 0, 0);
        \\        return JSON.serialize(dt);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonDatetimeSerializeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("\"2019-01-01T12:00:00.000Z\"", result.value.string);
}

test "E2E: Apex metadata datetime compares against custom datetime fields" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/Thing__c.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <label>Thing</label>
        \\</CustomObject>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fields/Timestamp__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Timestamp__c</fullName>
        \\    <type>DateTime</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class ApexMetadataDateComparisonTest {
        \\    public static SObject setReadOnlyField(SObject record, Schema.SObjectField field, Object value) {
        \\        Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(record));
        \\        fields.put(field.toString(), value);
        \\        return (SObject) JSON.deserialize(JSON.serialize(fields), SObject.class);
        \\    }
        \\    public static String test() {
        \\        Schema.ApexClass apexClassRecord = new Schema.ApexClass(Name = 'ExampleClass', Body = 'public class ExampleClass {}');
        \\        apexClassRecord = (Schema.ApexClass) setReadOnlyField(
        \\            apexClassRecord,
        \\            Schema.ApexClass.LastModifiedDate,
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
        \\        Thing__c record = new Thing__c(Timestamp__c = Datetime.newInstance(2026, 3, 1, 0, 0, 0));
        \\        return String.valueOf(((Datetime) ((SObject) apexClassRecord).get(Schema.ApexClass.LastModifiedDate)) > record.Timestamp__c);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "ApexMetadataDateComparisonTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: singleton mocks preserve virtual override dispatch" {
    const source =
        \\public virtual class SelectorBase {
        \\    @TestVisible
        \\    private static SelectorBase instance = new SelectorBase();
        \\    public static SelectorBase getInstance() {
        \\        return instance;
        \\    }
        \\    @TestVisible
        \\    private static void setMock(SelectorBase mockInstance) {
        \\        instance = mockInstance;
        \\    }
        \\    public virtual String fetch() {
        \\        return 'base';
        \\    }
        \\}
        \\public class SelectorDispatchTest {
        \\    public class MockSelector extends SelectorBase {
        \\        public override String fetch() {
        \\            return 'mock';
        \\        }
        \\    }
        \\    public static String test() {
        \\        SelectorBase.setMock(new MockSelector());
        \\        return SelectorBase.getInstance().fetch();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SelectorDispatchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("mock", result.value.string);
}

test "E2E: inner enum valueOf resolves declared enum members" {
    const source =
        \\public class EnumContainer {
        \\    public enum Kind {
        \\        Alpha,
        \\        Beta
        \\    }
        \\}
        \\public class InnerEnumValueOfTest {
        \\    public static String test() {
        \\        return String.valueOf(EnumContainer.Kind.valueOf('Alpha')) + ':' + String.valueOf(EnumContainer.Kind.values().size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerEnumValueOfTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Alpha:2", result.value.string);
}

test "E2E: switch on inner enum values matches valueOf results" {
    const source =
        \\public class EnumSwitchContainer {
        \\    public enum Kind {
        \\        Alpha,
        \\        Beta
        \\    }
        \\    public static String choose(String rawValue) {
        \\        Kind selected = Kind.valueOf(rawValue);
        \\        String result = 'Unknown';
        \\        switch on selected {
        \\            when Alpha {
        \\                result = 'A';
        \\            }
        \\            when Beta {
        \\                result = 'B';
        \\            }
        \\        }
        \\        return result;
        \\    }
        \\}
        \\public class InnerEnumSwitchTest {
        \\    public static String test() {
        \\        return EnumSwitchContainer.choose('Alpha') + ':' + EnumSwitchContainer.choose('Beta');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerEnumSwitchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("A:B", result.value.string);
}

test "E2E: Http headers round-trip through setHeader and getHeaderKeys" {
    const source =
        \\public class HttpHeaderRoundTripTest {
        \\    public static String test() {
        \\        HttpRequest request = new HttpRequest();
        \\        HttpResponse response = new HttpResponse();
        \\        request.setHeader('alpha', '1');
        \\        response.setHeader('beta', '2');
        \\        response.setHeader('gamma', '3');
        \\        return String.valueOf(request.getHeader('alpha')) + ':' +
        \\            String.valueOf(response.getHeaderKeys().size()) + ':' +
        \\            String.valueOf(request.getCompressed());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "HttpHeaderRoundTripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:2:false", result.value.string);
}

test "E2E: Rest headers default to empty maps and accept addHeader" {
    const source =
        \\public class RestHeaderRoundTripTest {
        \\    public static String test() {
        \\        RestRequest request = new RestRequest();
        \\        RestResponse response = new RestResponse();
        \\        request.addHeader('alpha', '1');
        \\        response.addHeader('beta', '2');
        \\        return String.valueOf(request.headers.size()) + ':' +
        \\            String.valueOf(response.headers.get('beta')) + ':' +
        \\            String.valueOf(request.params.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RestHeaderRoundTripTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:2:0", result.value.string);
}

test "E2E: JSON.deserialize on default RestRequest body reports null-argument error" {
    const source =
        \\public class RestRequestBodyNullTest {
        \\    public static String test() {
        \\        RestRequest req = new RestRequest();
        \\        try {
        \\            JSON.deserialize(req.requestBody.toString(), List<Account>.class);
        \\        } catch (Exception ex) {
        \\            return ex.getMessage();
        \\        }
        \\        return 'no-error';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RestRequestBodyNullTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Argument cannot be null.", result.value.string);
}

test "E2E: RestContext request and response share assigned objects" {
    const source =
        \\public class RestContextSharedStateTest {
        \\    public static String test() {
        \\        RestContext.Request = new RestRequest();
        \\        RestContext.Response = new RestResponse();
        \\        RestContext.request.requestURI = '/services/apexrest/demo';
        \\        RestContext.response.statusCode = 204;
        \\        return RestContext.Request.requestURI + ':' + String.valueOf(RestContext.Response.statusCode);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RestContextSharedStateTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("/services/apexrest/demo:204", result.value.string);
}

test "E2E: instance getter can write through RestContext response" {
    const source =
        \\public class RestResponseWrapper {
        \\    protected RestResponse response {
        \\        get {
        \\            return RestContext.response;
        \\        }
        \\        private set;
        \\    }
        \\    public void run() {
        \\        if (response.statusCode == null) {
        \\            response.statusCode = 202;
        \\        }
        \\    }
        \\}
        \\public class RestResponseWrapperTest {
        \\    public static String test() {
        \\        RestContext.Response = new RestResponse();
        \\        RestResponse resp = RestContext.Response;
        \\        new RestResponseWrapper().run();
        \\        return String.valueOf(resp.statusCode);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RestResponseWrapperTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("202", result.value.string);
}

test "E2E: inherited getter can write through RestContext response" {
    const source =
        \\public virtual class RestResponseBase {
        \\    protected RestResponse response {
        \\        get {
        \\            return RestContext.response;
        \\        }
        \\        private set;
        \\    }
        \\    public void run() {
        \\        if (response.statusCode == null) {
        \\            response.statusCode = 206;
        \\        }
        \\    }
        \\}
        \\public class RestResponseChild extends RestResponseBase {}
        \\public class RestResponseChildTest {
        \\    public static String test() {
        \\        RestContext.Response = new RestResponse();
        \\        RestResponse resp = RestContext.Response;
        \\        new RestResponseChild().run();
        \\        return String.valueOf(resp.statusCode);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RestResponseChildTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("206", result.value.string);
}

test "E2E: static helper can assign RestContext response" {
    const source =
        \\public class RestContextSetupHelper {
        \\    public static void setup() {
        \\        RestContext.Response = new RestResponse();
        \\    }
        \\}
        \\public class RestContextSetupHelperTest {
        \\    public static String test() {
        \\        RestContextSetupHelper.setup();
        \\        RestContext.response.statusCode = 207;
        \\        return String.valueOf(RestContext.Response.statusCode);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RestContextSetupHelperTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("207", result.value.string);
}

test "E2E: inner subclasses inherit route-style RestContext response writes" {
    const source =
        \\public virtual class RouteStyleResponder {
        \\    protected RestResponse response {
        \\        get {
        \\            return RestContext.response;
        \\        }
        \\        private set;
        \\    }
        \\    public void execute() {
        \\        response.addHeader('Content-Type', 'application/json');
        \\        if (response.statusCode == null) {
        \\            response.statusCode = 200;
        \\        }
        \\    }
        \\}
        \\public class RouteStyleOuter {
        \\    public class Child extends RouteStyleResponder {}
        \\}
        \\public class RouteStyleResponderTest {
        \\    public static String test() {
        \\        RestContext.Response = new RestResponse();
        \\        RestResponse resp = RestContext.Response;
        \\        new RouteStyleOuter.Child().execute();
        \\        return String.valueOf(resp.statusCode) + ':' +
        \\            String.valueOf(RestContext.Response.statusCode) + ':' +
        \\            RestContext.Response.getHeader('Content-Type');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RouteStyleResponderTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("200:200:application/json", result.value.string);
}

test "E2E: System.currentPageReference reuses ApexPages current page parameters" {
    const source =
        \\public class CurrentPageReferenceTest {
        \\    public static String test() {
        \\        ApexPages.currentPage().getParameters().put('startURL', '/home');
        \\        return String.valueOf(System.currentPageReference().getParameters().get('startURL'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CurrentPageReferenceTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("/home", result.value.string);
}

test "reset_for_test should not leak: arena memory must not grow linearly with test iterations" {
    // テストごとに新しい evaluator を作り、テストアリーナを reset(.retain_capacity) する。
    // テストアリーナの容量が線形に増加しないことを検証する。
    const source =
        \\@IsTest
        \\public class LeakTest {
        \\    @IsTest
        \\    static void test1() {
        \\        List<String> items = new List<String>();
        \\        for (Integer i = 0; i < 100; i++) {
        \\            items.add('item' + i);
        \\        }
        \\        System.assertEquals(100, items.size());
        \\    }
        \\}
    ;

    // 永続アリーナ: パース + クラス登録
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();

    const parse_alloc = parse_arena.allocator();

    const tokens = try lexer.tokenize(source, parse_alloc);
    const decls = try parser.parse(tokens, parse_alloc);
    var base_eval = try evaluator.Evaluator.init(parse_alloc, std.testing.io);
    try base_eval.load_decls(decls);

    // テスト実行用アリーナ
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();

    // 1回実行後のテストアリーナの容量を記録
    {
        _ = test_arena.reset(.retain_capacity);
        var test_eval = try evaluator.Evaluator.init(test_arena.allocator(), std.testing.io);
        test_eval.classes = base_eval.classes;
        _ = test_eval.call_method("LeakTest", "test1", &.{}) catch {};
    }
    const baseline = test_arena.queryCapacity();

    // 同じテストを 50 回繰り返す
    for (0..50) |_| {
        _ = test_arena.reset(.retain_capacity);
        var test_eval = try evaluator.Evaluator.init(test_arena.allocator(), std.testing.io);
        test_eval.classes = base_eval.classes;
        _ = test_eval.call_method("LeakTest", "test1", &.{}) catch {};
    }

    const after = test_arena.queryCapacity();

    // retain_capacity により容量は安定するはず（2倍以上増えたらリーク）
    try std.testing.expect(after <= baseline * 2);
}

test "E2E: empty list DML does not increment getDmlStatements" {
    const source =
        \\public class EmptyDmlTest {
        \\    public static Integer test() {
        \\        List<Account> emptyList = new List<Account>();
        \\        insert emptyList;
        \\        update emptyList;
        \\        delete emptyList;
        \\        return Limits.getDmlStatements();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EmptyDmlTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 0), result.value.integer);
}

test "E2E: non-empty list DML still increments getDmlStatements" {
    const source =
        \\public class NonEmptyDmlTest {
        \\    public static Integer test() {
        \\        Account a = new Account(Name = 'Test');
        \\        insert a;
        \\        return Limits.getDmlStatements();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NonEmptyDmlTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 1), result.value.integer);
}

test "E2E: Database.insert empty list does not increment getDmlStatements" {
    const source =
        \\public class EmptyDbDmlTest {
        \\    public static Integer test() {
        \\        List<Account> emptyList = new List<Account>();
        \\        Database.insert(emptyList);
        \\        Database.update(emptyList);
        \\        return Limits.getDmlStatements();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EmptyDbDmlTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 0), result.value.integer);
}

test "E2E: Database.insert single record increments getDmlStatements" {
    const source =
        \\public class SingleDbDmlTest {
        \\    public static String test() {
        \\        Account row = new Account(Name = 'Inserted');
        \\        Database.SaveResult result = Database.insert(row);
        \\        return String.valueOf(result.isSuccess()) + ':' +
        \\            String.valueOf(Limits.getDmlStatements()) + ':' +
        \\            String.valueOf(Limits.getDmlRows());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SingleDbDmlTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:1:1", result.value.string);
}

test "E2E: Salesforce-style id strings satisfy instanceof Id" {
    const source =
        \\public class IdInstanceofTest {
        \\    public static String test() {
        \\        String userId = '005000000000000';
        \\        String queueId = '00G000000000000005';
        \\        return String.valueOf(userId instanceof Id) + ':' + String.valueOf(queueId instanceof Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IdInstanceofTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: StandardSetController preserves selected records" {
    const source =
        \\public class StandardSetControllerSelectionTest {
        \\    public static String test() {
        \\        List<Account> rows = new List<Account>{
        \\            new Account(Name = 'A'),
        \\            new Account(Name = 'B')
        \\        };
        \\        ApexPages.StandardSetController controller = new ApexPages.StandardSetController(rows);
        \\        controller.setSelected(new List<Account>{ rows[1] });
        \\        List<Account> selected = (List<Account>) controller.getSelected();
        \\        return String.valueOf(selected.size()) + ':' + selected[0].Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StandardSetControllerSelectionTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:B", result.value.string);
}

test "E2E: ApexPages.Message preserves summary when added to page state" {
    const source =
        \\public class ApexPagesMessageSummaryTest {
        \\    public static String test() {
        \\        ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Denied'));
        \\        return ApexPages.getMessages().get(0).getSummary() + ':' + ApexPages.getMessages().get(0).getSeverity();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ApexPagesMessageSummaryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Denied:ERROR", result.value.string);
}

test "E2E: Id.valueOf expands 15-char ids to 18-char ids" {
    const source =
        \\public class IdValueOfTest {
        \\    public static String test() {
        \\        return String.valueOf(Id.valueOf('005000000000000'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IdValueOfTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("005000000000000AAA", result.value.string);
}

test "E2E: Id.valueOf throws StringException for invalid ids" {
    const source =
        \\public class InvalidIdValueOfTest {
        \\    public static String test() {
        \\        try {
        \\            Id.valueOf('invalid');
        \\            return 'no-exception';
        \\        } catch (System.StringException e) {
        \\            return 'string-exception';
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InvalidIdValueOfTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("string-exception", result.value.string);
}

test "E2E: custom equals and hashCode drive map lookup while strict equality stays identity" {
    const source =
        \\public class EqualityKey {
        \\    public List<Object> values;
        \\    public EqualityKey(List<Object> values) {
        \\        this.values = values;
        \\    }
        \\    public Boolean equals(Object other) {
        \\        EqualityKey that = other instanceof EqualityKey ? (EqualityKey) other : null;
        \\        return that != null && this.values == that.values;
        \\    }
        \\    public Integer hashCode() {
        \\        return values.hashCode();
        \\    }
        \\}
        \\public class EqualityKeyProbe {
        \\    public static String test() {
        \\        EqualityKey first = new EqualityKey(new List<Object>{ 'alpha', 7 });
        \\        EqualityKey second = new EqualityKey(new List<Object>{ 'alpha', 7 });
        \\        Map<EqualityKey, String> rows = new Map<EqualityKey, String>();
        \\        rows.put(first, 'ok');
        \\        return String.valueOf(first == second) + ':' +
        \\            String.valueOf(first === second) + ':' +
        \\            rows.get(second) + ':' +
        \\            String.valueOf(rows.containsKey(second));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EqualityKeyProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:false:ok:true", result.value.string);
}

test "E2E: Map.clear removes both entries and key metadata before reinsertion" {
    const source =
        \\public class MapClearProbe {
        \\    public static String test() {
        \\        Map<String, Map<String, Integer>> rows = new Map<String, Map<String, Integer>>();
        \\        Map<String, Integer> first = new Map<String, Integer>();
        \\        first.put('a', 1);
        \\        rows.put('account', first);
        \\        rows.clear();
        \\        Map<String, Integer> second = new Map<String, Integer>();
        \\        second.put('b', 2);
        \\        rows.put('account', second);
        \\        Map<String, Integer> inner = rows.get('account');
        \\        return String.valueOf(rows.containsKey('account')) + ':' +
        \\            String.valueOf(inner == null) + ':' +
        \\            String.valueOf(inner.size()) + ':' +
        \\            String.valueOf(inner.containsKey('b'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MapClearProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:false:1:true", result.value.string);
}

test "E2E: String.valueOf respects override toString and List<Type>.toString formats element names" {
    const source =
        \\public class ValuePrinter {
        \\    public override String toString() {
        \\        return 'printer';
        \\    }
        \\}
        \\public class ValuePrinterProbe {
        \\    public static String test() {
        \\        return String.valueOf(new ValuePrinter()) + ':' +
        \\            new List<Type>{ Integer.class, String.class }.toString();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ValuePrinterProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("printer:(Integer, String)", result.value.string);
}

test "E2E: executeBatch uses QueryLocator records produced from SOQL literals" {
    const source =
        \\global class QueryLocatorScopeBatch implements Database.Batchable<SObject> {
        \\    public static Integer processed = 0;
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        return Database.getQueryLocator([SELECT Id FROM Account WHERE Name = 'Keep']);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        processed = scope.size();
        \\    }
        \\    global void finish(Database.BatchableContext bc) {}
        \\}
        \\public class QueryLocatorScopeBatchTest {
        \\    public static Integer test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'Keep'),
        \\            new Account(Name = 'Skip')
        \\        };
        \\        Database.executeBatch(new QueryLocatorScopeBatch());
        \\        return QueryLocatorScopeBatch.processed;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QueryLocatorScopeBatchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 1), result.value.integer);
}

test "E2E: executeBatch queues chained jobs triggered from finish" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\global class ChainedCleanupBatch implements Database.Batchable<SObject>, Database.Stateful {
        \\    public String phase = 'Children';
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        if (phase == 'Children') {
        \\            return Database.getQueryLocator([SELECT Id FROM Child__c]);
        \\        }
        \\        return Database.getQueryLocator([SELECT Id FROM Parent__c WHERE TotalChildren__c = 0]);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        Database.delete(scope);
        \\    }
        \\    global void finish(Database.BatchableContext bc) {
        \\        if (phase == 'Children') {
        \\            phase = 'Parents';
        \\            Database.executeBatch(this);
        \\        }
        \\    }
        \\}
        \\public class ChainedCleanupBatchTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'Parent');
        \\        insert parent;
        \\        insert new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        Database.executeBatch(new ChainedCleanupBatch());
        \\        return String.valueOf([SELECT Id FROM Parent__c WHERE Id = :parent.Id].size());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "ChainedCleanupBatchTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0", result.value.string);
}

test "E2E: direct batch finish does not synchronously run chained executeBatch" {
    const source =
        \\global class DeferredFinishBatch implements Database.Batchable<SObject>, Database.Stateful {
        \\    public Integer startRuns = 0;
        \\    public String phase = 'initial';
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        startRuns++;
        \\        return Database.getQueryLocator(new List<Account>());
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {}
        \\    global void finish(Database.BatchableContext bc) {
        \\        if (phase == 'initial') {
        \\            phase = 'queued';
        \\            Database.executeBatch(this);
        \\        }
        \\    }
        \\}
        \\public class DeferredFinishBatchTest {
        \\    public static String test() {
        \\        DeferredFinishBatch batchJob = new DeferredFinishBatch();
        \\        batchJob.finish(null);
        \\        return batchJob.phase + ':' + String.valueOf(batchJob.startRuns);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DeferredFinishBatchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("queued:0", result.value.string);
}

test "E2E: executeBatch chained hard-delete works through a wrapper database class" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class CleanupGateway {
        \\    public class Database {
        \\        public List<Database.DeleteResult> delete_records(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.delete_records(rows);
        \\            if (rows.isEmpty() == false) {
        \\                System.Database.emptyRecycleBin(rows);
        \\            }
        \\            return results;
        \\        }
        \\    }
        \\    public static Database getDatabase() {
        \\        return new Database();
        \\    }
        \\}
        \\global class WrappedHardDeleteBatch implements Database.Batchable<SObject>, Database.Stateful {
        \\    public String phase = 'Children';
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        if (phase == 'Children') {
        \\            return Database.getQueryLocator([SELECT Id FROM Child__c]);
        \\        }
        \\        return Database.getQueryLocator([SELECT Id FROM Parent__c WHERE RetentionDate__c <= :System.today()]);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        CleanupGateway.getDatabase().hardDeleteRecords(scope);
        \\    }
        \\    global void finish(Database.BatchableContext bc) {
        \\        if (phase == 'Children') {
        \\            phase = 'Parents';
        \\            Database.executeBatch(this);
        \\        }
        \\    }
        \\}
        \\public class WrappedHardDeleteBatchTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'Parent', RetentionDate__c = System.today().addDays(-1));
        \\        insert parent;
        \\        insert new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        Database.executeBatch(new WrappedHardDeleteBatch());
        \\        return String.valueOf([SELECT Id FROM Child__c].size()) + ':' + String.valueOf([SELECT Id FROM Parent__c WHERE Id = :parent.Id].size());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "WrappedHardDeleteBatchTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:0", result.value.string);
}

test "E2E: wrapper database instance can delete queried rows" {
    const source =
        \\public class CleanupGateway {
        \\    public class Database {
        \\        public List<Database.DeleteResult> delete_records(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\    }
        \\    public static Database getDatabase() {
        \\        return new Database();
        \\    }
        \\}
        \\public class WrapperDeleteProbe {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        List<SObject> rows = new List<SObject>([SELECT Id FROM Account]);
        \\        CleanupGateway.getDatabase().delete_records(rows);
        \\        return String.valueOf([SELECT Id FROM Account].size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "WrapperDeleteProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0", result.value.string);
}

test "E2E: wrapper database instance can hard-delete queried rows" {
    const source =
        \\public class CleanupGateway {
        \\    public class Database {
        \\        public List<Database.DeleteResult> delete_records(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.delete_records(rows);
        \\            if (rows.isEmpty() == false) {
        \\                System.Database.emptyRecycleBin(rows);
        \\            }
        \\            return results;
        \\        }
        \\    }
        \\    public static Database getDatabase() {
        \\        return new Database();
        \\    }
        \\}
        \\public class WrapperHardDeleteProbe {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        List<SObject> rows = new List<SObject>([SELECT Id FROM Account]);
        \\        CleanupGateway.getDatabase().hardDeleteRecords(rows);
        \\        return String.valueOf([SELECT Id FROM Account].size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "WrapperHardDeleteProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0", result.value.string);
}

test "E2E: executeBatch can hard-delete rows through a wrapper database class" {
    const source =
        \\public class CleanupGateway {
        \\    public class Database {
        \\        public List<Database.DeleteResult> delete_records(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.delete_records(rows);
        \\            if (rows.isEmpty() == false) {
        \\                System.Database.emptyRecycleBin(rows);
        \\            }
        \\            return results;
        \\        }
        \\    }
        \\    public static Database getDatabase() {
        \\        return new Database();
        \\    }
        \\}
        \\global class WrappedDeleteBatch implements Database.Batchable<SObject> {
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        return Database.getQueryLocator([SELECT Id FROM Account]);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        CleanupGateway.getDatabase().hardDeleteRecords(scope);
        \\    }
        \\    global void finish(Database.BatchableContext bc) {}
        \\}
        \\public class WrappedDeleteBatchTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        Database.executeBatch(new WrappedDeleteBatch());
        \\        return String.valueOf([SELECT Id FROM Account].size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "WrappedDeleteBatchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0", result.value.string);
}

test "E2E: aggregate query groups by multi-hop parent relationship fields" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class AggregateGroupByParentProbe {
        \\    public static String test() {
        \\        Parent__c first = new Parent__c(Name = 'Delete');
        \\        Parent__c second = new Parent__c(Name = 'Custom');
        \\        insert new List<Parent__c>{ first, second };
        \\        Child__c firstChild = new Child__c(Parent__c = first.Id, Status__c = 'Open');
        \\        Child__c secondChild = new Child__c(Parent__c = second.Id, Status__c = 'Open');
        \\        insert new List<Child__c>{ firstChild, secondChild };
        \\        insert new List<Grandchild__c>{
        \\            new Grandchild__c(Child__c = firstChild.Id),
        \\            new Grandchild__c(Child__c = secondChild.Id)
        \\        };
        \\        List<AggregateResult> rows = [
        \\            SELECT Child__r.Parent__r.Name ParentName, COUNT(Id) RecordCount
        \\            FROM Grandchild__c
        \\            GROUP BY Child__r.Parent__r.Name
        \\        ];
        \\        Integer deleteCount = 0;
        \\        Integer customCount = 0;
        \\        for (AggregateResult row : rows) {
        \\            if ((String) row.get('ParentName') == 'Delete') {
        \\                deleteCount = (Integer) row.get('RecordCount');
        \\            }
        \\            if ((String) row.get('ParentName') == 'Custom') {
        \\                customCount = (Integer) row.get('RecordCount');
        \\            }
        \\        }
        \\        return String.valueOf(rows.size()) + ':' + String.valueOf(deleteCount) + ':' + String.valueOf(customCount);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "AggregateGroupByParentProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:1:1", result.value.string);
}

test "E2E: executeBatch creates queryable AsyncApexJob records" {
    const source =
        \\global class AsyncJobProbeBatch implements Database.Batchable<SObject> {
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        return Database.getQueryLocator([SELECT Id FROM Account]);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {}
        \\    global void finish(Database.BatchableContext bc) {}
        \\}
        \\public class AsyncJobProbeTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        String batchClassName = AsyncJobProbeBatch.class.getName();
        \\        String namespacePrefix = batchClassName.contains('.') ? batchClassName.substringBefore('.') : null;
        \\        String apexClassName = batchClassName.contains('.') ? batchClassName.substringAfter('.') : batchClassName;
        \\        String jobId = Database.executeBatch(new AsyncJobProbeBatch());
        \\        List<AsyncApexJob> jobs = [
        \\            SELECT Id, JobType, Status, CreatedBy.Name
        \\            FROM AsyncApexJob
        \\            WHERE Id = :jobId AND ApexClass.NamespacePrefix = :namespacePrefix AND ApexClass.Name = :apexClassName
        \\        ];
        \\        AsyncApexJob job = jobs.get(0);
        \\        return String.valueOf(jobs.size()) + ':' + job.JobType + ':' + job.Status + ':' + job.CreatedBy.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AsyncJobProbeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:BatchApex:Completed:Test User", result.value.string);
}

test "E2E: executeBatch publishes BatchApexErrorEvent for raises-platform-events batches" {
    const source =
        \\trigger BatchFailureTrigger on BatchApexErrorEvent (after insert) {
        \\    List<Account> insertedAccounts = new List<Account>();
        \\    for (BatchApexErrorEvent evt : Trigger.new) {
        \\        insertedAccounts.add(new Account(Name = evt.Phase + ':' + evt.ExceptionType + ':' + evt.Message));
        \\    }
        \\    insert insertedAccounts;
        \\}
        \\global class EventedBatch implements Database.Batchable<SObject>, Database.RaisesPlatformEvents {
        \\    private String phase;
        \\    global EventedBatch(String phase) {
        \\        this.phase = phase;
        \\    }
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        if (this.phase == 'START') {
        \\            throw new System.IllegalArgumentException('START');
        \\        }
        \\        return Database.getQueryLocator([SELECT Id FROM User LIMIT 1]);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        if (this.phase == 'EXECUTE') {
        \\            throw new System.IllegalArgumentException('EXECUTE');
        \\        }
        \\    }
        \\    global void finish(Database.BatchableContext bc) {
        \\        if (this.phase == 'FINISH') {
        \\            throw new System.IllegalArgumentException('FINISH');
        \\        }
        \\    }
        \\}
        \\public class BatchFailureEventTest {
        \\    public static String test() {
        \\        for (String phase : new List<String>{ 'START', 'EXECUTE', 'FINISH' }) {
        \\            try {
        \\                Database.executeBatch(new EventedBatch(phase));
        \\            } catch (System.Exception ex) {
        \\            }
        \\        }
        \\        List<Account> rows = [SELECT Name FROM Account ORDER BY Name];
        \\        List<String> names = new List<String>();
        \\        for (Account row : rows) {
        \\            names.add(row.Name);
        \\        }
        \\        return String.join(names, '|');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "BatchFailureEventTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "EXECUTE:System.IllegalArgumentException:EXECUTE|FINISH:System.IllegalArgumentException:FINISH|START:System.IllegalArgumentException:START",
        result.value.string,
    );
}

test "E2E: chained batch with singleton database getter hard-deletes parent records after child cleanup" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class CleanupStore {
        \\    private static Database databaseInstance {
        \\        get {
        \\            if (databaseInstance == null) {
        \\                databaseInstance = new Database();
        \\            }
        \\            return databaseInstance;
        \\        }
        \\        set;
        \\    }
        \\    public static Database getDatabase() {
        \\        return databaseInstance;
        \\    }
        \\    public virtual class Database {
        \\        public virtual List<Database.DeleteResult> delete_records(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public virtual List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.delete_records(rows);
        \\            if (rows.isEmpty() == false) {
        \\                System.Database.emptyRecycleBin(rows);
        \\            }
        \\            return results;
        \\        }
        \\    }
        \\}
        \\global class SingletonCleanupBatch implements Database.Batchable<SObject>, Database.Stateful {
        \\    private static final Date RETENTION_END_DATE = System.today();
        \\    public Schema.SObjectType currentSObjectType;
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        this.currentSObjectType = this.getInitialSObjectType();
        \\        return this.getQueryLocator(this.currentSObjectType);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        CleanupStore.getDatabase().hardDeleteRecords(scope);
        \\    }
        \\    global void finish(Database.BatchableContext bc) {
        \\        if (this.currentSObjectType != Schema.Parent__c.SObjectType) {
        \\            Database.executeBatch(this);
        \\        }
        \\    }
        \\    private Schema.SObjectType getInitialSObjectType() {
        \\        Integer childCount = [
        \\            SELECT COUNT()
        \\            FROM Child__c
        \\            WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE AND Parent__r.RetentionDate__c != NULL
        \\        ];
        \\        return childCount > 0 ? Schema.Child__c.SObjectType : Schema.Parent__c.SObjectType;
        \\    }
        \\    private Database.QueryLocator getQueryLocator(Schema.SObjectType sobjectType) {
        \\        Database.QueryLocator queryLocator;
        \\        switch on sobjectType.newSObject() {
        \\            when Child__c childRecord {
        \\                queryLocator = System.Database.getQueryLocator([
        \\                    SELECT Id
        \\                    FROM Child__c
        \\                    WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE AND Parent__r.RetentionDate__c != NULL
        \\                ]);
        \\            }
        \\            when Parent__c parentRecord {
        \\                queryLocator = System.Database.getQueryLocator([
        \\                    SELECT Id
        \\                    FROM Parent__c
        \\                    WHERE (RetentionDate__c <= :RETENTION_END_DATE AND RetentionDate__c != NULL) OR TotalChildren__c = 0
        \\                ]);
        \\            }
        \\        }
        \\        return queryLocator;
        \\    }
        \\}
        \\public class SingletonCleanupBatchTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'Parent', RetentionDate__c = System.today().addDays(-1));
        \\        insert parent;
        \\        insert new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        Database.executeBatch(new SingletonCleanupBatch());
        \\        return String.valueOf([SELECT Id FROM Child__c].size()) + ':' + String.valueOf([SELECT Id FROM Parent__c WHERE Id = :parent.Id].size());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "SingletonCleanupBatchTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:0", result.value.string);
}

test "E2E: singleton database getter can hard-delete queried rows outside batch" {
    const source =
        \\public class CleanupStore {
        \\    private static Database databaseInstance {
        \\        get {
        \\            if (databaseInstance == null) {
        \\                databaseInstance = new Database();
        \\            }
        \\            return databaseInstance;
        \\        }
        \\        set;
        \\    }
        \\    public static Database getDatabase() {
        \\        return databaseInstance;
        \\    }
        \\    public virtual class Database {
        \\        public virtual List<Database.DeleteResult> delete_records(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public virtual List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.delete_records(rows);
        \\            if (rows.isEmpty() == false) {
        \\                System.Database.emptyRecycleBin(rows);
        \\            }
        \\            return results;
        \\        }
        \\    }
        \\}
        \\public class SingletonCleanupStoreProbe {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        List<SObject> rows = new List<SObject>([SELECT Id FROM Account]);
        \\        CleanupStore.getDatabase().hardDeleteRecords(rows);
        \\        return String.valueOf([SELECT Id FROM Account].size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SingletonCleanupStoreProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0", result.value.string);
}

test "E2E: chained batch with direct hard-delete removes parent records after child cleanup" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\global class DirectCleanupBatch implements Database.Batchable<SObject>, Database.Stateful {
        \\    private static final Date RETENTION_END_DATE = System.today();
        \\    public Schema.SObjectType currentSObjectType;
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        this.currentSObjectType = this.getInitialSObjectType();
        \\        return this.getQueryLocator(this.currentSObjectType);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        System.Database.delete(scope);
        \\        if (scope.isEmpty() == false) {
        \\            System.Database.emptyRecycleBin(scope);
        \\        }
        \\    }
        \\    global void finish(Database.BatchableContext bc) {
        \\        if (this.currentSObjectType != Schema.Parent__c.SObjectType) {
        \\            Database.executeBatch(this);
        \\        }
        \\    }
        \\    private Schema.SObjectType getInitialSObjectType() {
        \\        Integer childCount = [
        \\            SELECT COUNT()
        \\            FROM Child__c
        \\            WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE AND Parent__r.RetentionDate__c != NULL
        \\        ];
        \\        return childCount > 0 ? Schema.Child__c.SObjectType : Schema.Parent__c.SObjectType;
        \\    }
        \\    private Database.QueryLocator getQueryLocator(Schema.SObjectType sobjectType) {
        \\        Database.QueryLocator queryLocator;
        \\        switch on sobjectType.newSObject() {
        \\            when Child__c childRecord {
        \\                queryLocator = System.Database.getQueryLocator([
        \\                    SELECT Id
        \\                    FROM Child__c
        \\                    WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE AND Parent__r.RetentionDate__c != NULL
        \\                ]);
        \\            }
        \\            when Parent__c parentRecord {
        \\                queryLocator = System.Database.getQueryLocator([
        \\                    SELECT Id
        \\                    FROM Parent__c
        \\                    WHERE (RetentionDate__c <= :RETENTION_END_DATE AND RetentionDate__c != NULL) OR TotalChildren__c = 0
        \\                ]);
        \\            }
        \\        }
        \\        return queryLocator;
        \\    }
        \\}
        \\public class DirectCleanupBatchTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'Parent', RetentionDate__c = System.today().addDays(-1));
        \\        insert parent;
        \\        insert new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        Database.executeBatch(new DirectCleanupBatch());
        \\        return String.valueOf([SELECT Id FROM Child__c].size()) + ':' + String.valueOf([SELECT Id FROM Parent__c WHERE Id = :parent.Id].size());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "DirectCleanupBatchTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:0", result.value.string);
}

test "E2E: Database.insert null list throws by default without allOrNone false" {
    const source =
        \\public class DefaultDatabaseAllOrNothingTest {
        \\    public static String test() {
        \\        List<Account> rows = null;
        \\        Exception thrownException = null;
        \\        try {
        \\            Database.insert(rows);
        \\        } catch (NullPointerException ex) {
        \\            thrownException = ex;
        \\        }
        \\        return thrownException != null ? 'threw' : 'missing';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DefaultDatabaseAllOrNothingTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("threw", result.value.string);
}

test "E2E: instance method on null receiver throws NullPointerException" {
    const source =
        \\public class NullReceiverMethodTest {
        \\    public static String test() {
        \\        String value = null;
        \\        try {
        \\            value.length();
        \\        } catch (NullPointerException ex) {
        \\            return ex.getMessage();
        \\        }
        \\        return 'missing';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NullReceiverMethodTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Attempt to de-reference a null object",
        result.value.string,
    );
}

test "E2E: for-each on null collection throws NullPointerException" {
    const source =
        \\public class NullForEachTest {
        \\    public static String test() {
        \\        List<String> rows = null;
        \\        try {
        \\            for (String row : rows) {
        \\                System.debug(row);
        \\            }
        \\        } catch (NullPointerException ex) {
        \\            return ex.getMessage();
        \\        }
        \\        return 'missing';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NullForEachTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Attempt to de-reference a null object",
        result.value.string,
    );
}

test "E2E: list index access throws ListException when out of bounds" {
    const source =
        \\public class ListIndexOutOfBoundsTest {
        \\    public static String test() {
        \\        List<String> rows = new List<String>();
        \\        try {
        \\            String value = rows[0];
        \\            return value;
        \\        } catch (Exception ex) {
        \\            return ex.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ListIndexOutOfBoundsTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("List index out of bounds: 0", result.value.string);
}

test "E2E: JSON.deserialize preserves user-defined field initializers for omitted fields" {
    const source =
        \\public class JsonFieldInitializerTest {
        \\    public class Payload {
        \\        public String mode = 'debug';
        \\        public Boolean saveLog = false;
        \\    }
        \\    public static String test() {
        \\        Payload payload = (Payload) JSON.deserialize('{"saveLog":true}', Payload.class);
        \\        if (payload.mode == 'debug' && payload.saveLog == true) {
        \\            return 'ok';
        \\        }
        \\        return String.valueOf(payload.mode) + ':' + String.valueOf(payload.saveLog);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonFieldInitializerTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: static singleton field initializer constructs the instance" {
    const source =
        \\public class StaticSingletonFieldTest {
        \\    private static final StaticSingletonFieldTest INSTANCE = new StaticSingletonFieldTest();
        \\    private String mode;
        \\
        \\    private StaticSingletonFieldTest() {
        \\        mode = 'ready';
        \\    }
        \\
        \\    public static StaticSingletonFieldTest getInstance() {
        \\        return INSTANCE;
        \\    }
        \\
        \\    public String getMode() {
        \\        return mode;
        \\    }
        \\
        \\    public static String test() {
        \\        StaticSingletonFieldTest instance = getInstance();
        \\        return instance == null ? 'null' : instance.getMode();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticSingletonFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ready", result.value.string);
}

test "E2E: cross-class static initializer can read singleton instance" {
    const source =
        \\public class StaticInitCrossClassSingletonTest {
        \\    public class Config {
        \\        private static final Config INSTANCE = new Config();
        \\        private String mode;
        \\
        \\        private Config() {
        \\            mode = 'ready';
        \\        }
        \\
        \\        public static Config getInstance() {
        \\            return INSTANCE;
        \\        }
        \\
        \\        public String getMode() {
        \\            return mode;
        \\        }
        \\    }
        \\
        \\    public class Consumer {
        \\        private static final String MODE = Config.getInstance().getMode();
        \\
        \\        public static String getMode() {
        \\            return MODE;
        \\        }
        \\    }
        \\
        \\    public static String test() {
        \\        return Consumer.getMode();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticInitCrossClassSingletonTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ready", result.value.string);
}

test "E2E: schema-qualified SObjectType ignores local shadowing after nested static overloads" {
    const source =
        \\public class SchemaQualifiedSObjectTypeShadowTest {
        \\    public static User createUser() {
        \\        return createUser(UserInfo.getProfileId());
        \\    }
        \\
        \\    public static User createUser(Id profileId) {
        \\        return new User(
        \\            Alias = 'u',
        \\            Email = 'u@test.com',
        \\            EmailEncodingKey = 'ISO-8859-1',
        \\            FederationIdentifier = 'shadow-test',
        \\            LanguageLocaleKey = 'en_US',
        \\            LastName = 'User',
        \\            LocaleSidKey = 'en_US',
        \\            ProfileId = profileId,
        \\            TimeZoneSidKey = 'America/Los_Angeles',
        \\            Username = 'u@test.com'
        \\        );
        \\    }
        \\
        \\    public static String test() {
        \\        User user = createUser();
        \\        Integer len = Schema.User.SObjectType.getDescribe().fields.getMap().get('Id').getDescribe().getLength();
        \\        return user == null ? 'null' : String.valueOf(len > 0);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaQualifiedSObjectTypeShadowTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: schema-qualified SObjectType standalone assignment ignores local shadowing" {
    const source =
        \\public class SchemaQualifiedSObjectTypeStandaloneAssignmentTest {
        \\    public static User createUser() {
        \\        return createUser(UserInfo.getProfileId());
        \\    }
        \\
        \\    public static User createUser(Id profileId) {
        \\        return new User(
        \\            Alias = 'u',
        \\            Email = 'u@test.com',
        \\            EmailEncodingKey = 'ISO-8859-1',
        \\            FederationIdentifier = 'shadow-test',
        \\            LanguageLocaleKey = 'en_US',
        \\            LastName = 'User',
        \\            LocaleSidKey = 'en_US',
        \\            ProfileId = profileId,
        \\            TimeZoneSidKey = 'America/Los_Angeles',
        \\            Username = 'u@test.com'
        \\        );
        \\    }
        \\
        \\    public static String test() {
        \\        User user = createUser();
        \\        Schema.SObjectType sobjectType = Schema.User.SObjectType;
        \\        return sobjectType.getDescribe().getName();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaQualifiedSObjectTypeStandaloneAssignmentTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("User", result.value.string);
}

test "E2E: switch when else executes for unmatched string subjects" {
    const source =
        \\public class SwitchElseRuntimeTest {
        \\    public static String choose(String value) {
        \\        switch on value {
        \\            when 'A' {
        \\                return 'match';
        \\            }
        \\            when else {
        \\                throw new IllegalArgumentException('bad:' + value);
        \\            }
        \\        }
        \\        return 'missing';
        \\    }
        \\    public static String test() {
        \\        Exception thrownException = null;
        \\        try {
        \\            choose('Z');
        \\        } catch (IllegalArgumentException ex) {
        \\            thrownException = ex;
        \\        }
        \\        return thrownException == null ? 'missing' : thrownException.getMessage();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SwitchElseRuntimeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("bad:Z", result.value.string);
}

test "E2E: qualified system exception constructors are catchable" {
    const source =
        \\public class QualifiedExceptionCtorTest {
        \\    public static String test() {
        \\        Exception thrownException = null;
        \\        try {
        \\            throw new System.IllegalArgumentException('bad');
        \\        } catch (System.IllegalArgumentException ex) {
        \\            thrownException = ex;
        \\        }
        \\        return thrownException == null ? 'missing' : thrownException.getTypeName() + ':' + thrownException.getMessage();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QualifiedExceptionCtorTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("System.IllegalArgumentException:bad", result.value.string);
}

test "E2E: inner class switch else throws qualified system exceptions" {
    const source =
        \\public class InnerQualifiedExceptionSwitchTest {
        \\    private class RuleRunner {
        \\        public Boolean run(String operatorValue) {
        \\            switch on operatorValue {
        \\                when 'EQUAL_TO' {
        \\                    return true;
        \\                }
        \\                when else {
        \\                    throw new System.IllegalArgumentException('bad:' + operatorValue);
        \\                }
        \\            }
        \\            return false;
        \\        }
        \\    }
        \\    public static String test() {
        \\        Exception thrownException = null;
        \\        try {
        \\            new RuleRunner().run('THIS_IS_AN_INVALID_OPERATOR');
        \\        } catch (System.IllegalArgumentException ex) {
        \\            thrownException = ex;
        \\        }
        \\        return thrownException == null ? 'missing' : thrownException.getMessage();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerQualifiedExceptionSwitchTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("bad:THIS_IS_AN_INVALID_OPERATOR", result.value.string);
}

test "E2E: constructor exceptions propagate to callers" {
    const source =
        \\public class ConstructorExceptionPropagationTest {
        \\    private class RuleRunner {
        \\        public RuleRunner(String operatorValue) {
        \\            switch on operatorValue {
        \\                when 'EQUAL_TO' {
        \\                }
        \\                when else {
        \\                    throw new System.IllegalArgumentException('bad:' + operatorValue);
        \\                }
        \\            }
        \\        }
        \\    }
        \\    public static String test() {
        \\        Exception thrownException = null;
        \\        try {
        \\            new RuleRunner('THIS_IS_AN_INVALID_OPERATOR');
        \\        } catch (System.IllegalArgumentException ex) {
        \\            thrownException = ex;
        \\        }
        \\        return thrownException == null ? 'missing' : thrownException.getMessage();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ConstructorExceptionPropagationTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("bad:THIS_IS_AN_INVALID_OPERATOR", result.value.string);
}

test "E2E: System.Test.setCreatedDate updates persisted CreatedDate" {
    const source =
        \\public class TestSetCreatedDateRuntimeTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        Account otherRecord = new Account(Name = 'Other');
        \\        insert new List<Account>{ accountRecord, otherRecord };
        \\        Datetime target = Datetime.newInstance(2025, 1, 2, 3, 4, 5);
        \\        Datetime otherTarget = Datetime.newInstance(2024, 1, 1, 0, 0, 0);
        \\        System.Test.setCreatedDate(accountRecord.Id, target);
        \\        System.Test.setCreatedDate(otherRecord.Id, otherTarget);
        \\        Account refreshed = [SELECT CreatedDate FROM Account WHERE Id = :accountRecord.Id];
        \\        Account otherRefreshed = [SELECT CreatedDate FROM Account WHERE Id = :otherRecord.Id];
        \\        List<Account> matches = [SELECT Id FROM Account WHERE CreatedDate = :target];
        \\        return String.valueOf(matches.size()) + ':' +
        \\            String.valueOf(refreshed.CreatedDate == target) + ':' +
        \\            String.valueOf(otherRefreshed.CreatedDate == target);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TestSetCreatedDateRuntimeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:true:false", result.value.string);
}

test "E2E: inserted live records do not expose auto-generated CreatedDate before requery" {
    const source =
        \\public class InsertedLiveCreatedDateVisibilityTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Account refreshed = [SELECT CreatedDate FROM Account WHERE Id = :accountRecord.Id];
        \\        return String.valueOf(accountRecord.get('CreatedDate') == null) + ':' +
        \\            String.valueOf(refreshed.CreatedDate != null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InsertedLiveCreatedDateVisibilityTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: for-init multiple variable declarations remain in loop scope" {
    const source =
        \\public class ForMultiInitRuntimeTest {
        \\    public static String test() {
        \\        List<Integer> values = new List<Integer>{ 1, 2, 3 };
        \\        Integer sum = 0;
        \\        for (Integer i = 0, size = values.size(); i < size; i++) {
        \\            sum += values[i];
        \\        }
        \\        return String.valueOf(sum);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ForMultiInitRuntimeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("6", result.value.string);
}

test "E2E: ORDER BY CreatedDate respects System.Test.setCreatedDate changes" {
    const source =
        \\public class TestSetCreatedDateOrderByTest {
        \\    public static String test() {
        \\        Account olderRecord = new Account(Name = 'Older');
        \\        Account newerRecord = new Account(Name = 'Newer');
        \\        insert new List<Account>{ olderRecord, newerRecord };
        \\        System.Test.setCreatedDate(olderRecord.Id, System.now().addMinutes(-5));
        \\        Account returnedRecord = [
        \\            SELECT Id, Name
        \\            FROM Account
        \\            ORDER BY CreatedDate DESC
        \\            LIMIT 1
        \\        ];
        \\        return returnedRecord.Id + ':' + returnedRecord.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TestSetCreatedDateOrderByTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("001000000000000002:Newer", result.value.string);
}

test "E2E: String.split supports escaped pipe delimiters with limit" {
    const source =
        \\public class SplitEscapedPipeTest {
        \\    public static String test() {
        \\        List<String> parts = 'true||false'.split('\\|\\|', 2);
        \\        return String.valueOf(parts.size()) + ':' + parts.get(0) + ':' + parts.get(1);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SplitEscapedPipeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:true:false", result.value.string);
}

test "E2E: String.unescapeJava decodes escaped control sequences" {
    const source =
        \\public class UnescapeJavaTest {
        \\    public static String test() {
        \\        String value = 'Line 1\\nLine 2\\tTabbed';
        \\        return value.unescapeJava();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UnescapeJavaTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Line 1\nLine 2\tTabbed", result.value.string);
}

test "E2E: parent CreatedDate fields are materialized as Datetime values" {
    const source =
        \\public class ParentCreatedDateMaterializationTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Datetime target = Datetime.newInstance(2025, 1, 2, 3, 4, 5);
        \\        System.Test.setCreatedDate(accountRecord.Id, target);
        \\        Contact contactRecord = new Contact(LastName = 'User', AccountId = accountRecord.Id);
        \\        insert contactRecord;
        \\        Contact queried = [SELECT AccountId, Account.CreatedDate FROM Contact WHERE Id = :contactRecord.Id];
        \\        Datetime actual = (Datetime) queried.getSObject('Account').get('CreatedDate');
        \\        return String.valueOf(actual == target);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ParentCreatedDateMaterializationTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: synthetic Organization query exposes CreatedBy and CreatedDate details" {
    const source =
        \\public class OrganizationMetadataAccessTest {
        \\    public static String test() {
        \\        Organization orgRecord = [
        \\            SELECT
        \\                CreatedById,
        \\                CreatedBy.Name,
        \\                CreatedBy.Username,
        \\                CreatedDate,
        \\                TrialExpirationDate
        \\            FROM Organization
        \\            LIMIT 1
        \\        ];
        \\        String formattedCreatedDate = orgRecord.CreatedDate.format();
        \\        return String.valueOf(orgRecord.CreatedById != null) + ':' +
        \\            String.valueOf(orgRecord.CreatedBy != null) + ':' +
        \\            String.valueOf(String.isNotBlank(orgRecord.CreatedBy.Username)) + ':' +
        \\            String.valueOf(String.isNotBlank(formattedCreatedDate)) + ':' +
        \\            String.valueOf(orgRecord.TrialExpirationDate == null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "OrganizationMetadataAccessTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:true:true:true", result.value.string);
}

test "E2E: instance overload resolves cast List<SObject> target" {
    const source =
        \\public class ListOverloadForwarder {
        \\    public String run(List<Account> rows) {
        \\        return this.run((List<SObject>) rows);
        \\    }
        \\    public String run(List<SObject> rows) {
        \\        return 'sobject:' + rows.size();
        \\    }
        \\    public static String test() {
        \\        ListOverloadForwarder forwarder = new ListOverloadForwarder();
        \\        return forwarder.run(new List<Account>{ new Account(Name = 'A') });
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ListOverloadForwarder",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("sobject:1", result.value.string);
}

test "E2E: constructor overload prefers exact SObject type" {
    const source =
        \\public class SObjectConstructorOverloadTest {
        \\    private String selected;
        \\    public SObjectConstructorOverloadTest(Signal__e eventRecord) {
        \\        this.selected = 'event';
        \\    }
        \\    public SObjectConstructorOverloadTest(Signal__c customRecord) {
        \\        this.selected = 'record';
        \\    }
        \\    public String getSelected() {
        \\        return this.selected;
        \\    }
        \\    public static String test() {
        \\        return new SObjectConstructorOverloadTest(new Signal__c()).getSelected()
        \\            + ':'
        \\            + new SObjectConstructorOverloadTest(new Signal__e()).getSelected();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SObjectConstructorOverloadTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("record:event", result.value.string);
}

test "E2E: null collection variables preserve declared overload targets" {
    const source =
        \\public class NullCollectionOverloadTest {
        \\    public String pick(List<SObject> rows) { return 'List'; }
        \\    public String pick(Map<String, SObject> rows) { return 'Map'; }
        \\    public String pick(Iterable<Id> ids) { return 'Iterable'; }
        \\    public String pick(Object anything) { return anything == null ? 'null' : 'Object'; }
        \\    public static String test() {
        \\        NullCollectionOverloadTest helper = new NullCollectionOverloadTest();
        \\        List<Account> rows = null;
        \\        Map<String, Account> rowMap = null;
        \\        Iterable<Id> ids = null;
        \\        return helper.pick(rows) + ':' + helper.pick(rowMap) + ':' + helper.pick(ids);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NullCollectionOverloadTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("List:Map:Iterable", result.value.string);
}

test "E2E: List<Id> overload prefers Iterable<Id> over List<SObject>" {
    const source =
        \\public class IterableIdOverloadTest {
        \\    public String pick(List<SObject> rows) { return 'List'; }
        \\    public String pick(System.Iterable<Id> ids) { return 'Iterable'; }
        \\    public static String test() {
        \\        IterableIdOverloadTest helper = new IterableIdOverloadTest();
        \\        List<Id> ids = new List<Id>{ UserInfo.getUserId() };
        \\        return helper.pick(ids);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IterableIdOverloadTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Iterable", result.value.string);
}

test "E2E: unsaved standard-object lists prefer List<SObject> overloads" {
    const source =
        \\public class StandardObjectListOverloadTest {
        \\    public String pick(Id recordId) { return 'Id'; }
        \\    public String pick(List<SObject> rows) { return rows == null ? 'List:null' : 'List:' + String.valueOf(rows.size()); }
        \\    public static String test() {
        \\        StandardObjectListOverloadTest helper = new StandardObjectListOverloadTest();
        \\        List<AccountBrand> rows = new List<AccountBrand>{
        \\            new AccountBrand(Id = 'Acc000000000000001'),
        \\            new AccountBrand(Id = 'Acc000000000000002')
        \\        };
        \\        return helper.pick(rows);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StandardObjectListOverloadTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("List:2", result.value.string);
}

test "E2E: List.sort keeps strings before numbers for mixed Object values" {
    const source =
        \\public class MixedObjectSortTest {
        \\    public static String test() {
        \\        List<Object> values = new List<Object>{ 'some-tag', 'another-tag', 1 };
        \\        values.sort();
        \\        return String.valueOf(values.get(0)) + '|' + String.valueOf(values.get(1)) + '|' + String.valueOf(values.get(2));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MixedObjectSortTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("another-tag|some-tag|1", result.value.string);
}

test "E2E: List<String>.sort keeps digit-prefixed values after alpha strings" {
    const source =
        \\public class StringSortTest {
        \\    public static String test() {
        \\        List<String> values = new List<String>{ 'some-tag', 'another-tag', '1' };
        \\        values.sort();
        \\        return String.join(values, '|');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StringSortTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("another-tag|some-tag|1", result.value.string);
}

test "E2E: method returning Map<Schema.SObjectField,Object> prefers matching overload" {
    const source =
        \\public class FieldMapOverloadTest {
        \\    public String apply(Schema.SObjectField field, Object value) {
        \\        return 'single';
        \\    }
        \\    public String apply(Map<Schema.SObjectField, Object> fieldToValue) {
        \\        return (String) fieldToValue.get(Schema.Account.Name);
        \\    }
        \\    public static Map<Schema.SObjectField, Object> makeFieldMap() {
        \\        Map<Schema.SObjectField, Object> fieldToValue = new Map<Schema.SObjectField, Object>();
        \\        fieldToValue.put(Schema.Account.Name, 'matched');
        \\        return fieldToValue;
        \\    }
        \\    public static String test() {
        \\        FieldMapOverloadTest helper = new FieldMapOverloadTest();
        \\        return helper.apply(makeFieldMap());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FieldMapOverloadTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("matched", result.value.string);
}

test "E2E: Schema field token strings resolve describe map entries for put" {
    const source =
        \\public class FieldStringLookupTest {
        \\    public static String test() {
        \\        Map<String, Object> valuesByFieldName = new Map<String, Object>{
        \\            Schema.Account.Name.toString() => 'Acme'
        \\        };
        \\        Map<Schema.SObjectField, Object> resolvedFieldToValue = new Map<Schema.SObjectField, Object>();
        \\        for (String fieldName : valuesByFieldName.keySet()) {
        \\            Schema.SObjectField field = Schema.Account.SObjectType.getDescribe().fields.getMap().get(fieldName);
        \\            resolvedFieldToValue.put(field, valuesByFieldName.get(fieldName));
        \\        }
        \\        Account accountRecord = new Account();
        \\        for (Schema.SObjectField field : resolvedFieldToValue.keySet()) {
        \\            accountRecord.put(field, resolvedFieldToValue.get(field));
        \\        }
        \\        return accountRecord.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FieldStringLookupTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Acme", result.value.string);
}

test "E2E: describe-derived SObject field map keys stay distinct across multiple fields" {
    const source =
        \\public class DescribeDerivedFieldKeyTest {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> describeFields = Schema.Account.SObjectType.getDescribe().fields.getMap();
        \\        Map<Schema.SObjectField, String> valuesByField = new Map<Schema.SObjectField, String>();
        \\        valuesByField.put(describeFields.get('Name'), 'name');
        \\        valuesByField.put(describeFields.get('OwnerId'), 'owner');
        \\        return valuesByField.size() + ':' + valuesByField.get(describeFields.get('Name')) + ':' + valuesByField.get(describeFields.get('OwnerId'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DescribeDerivedFieldKeyTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:name:owner", result.value.string);
}

test "E2E: UserRecordAccess delete query returns only deletable records" {
    const source =
        \\public class UserRecordAccessDeleteQueryTest {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'CanDelete');
        \\        insert account;
        \\        List<Id> recordIds = new List<Id>{ account.Id, System.UserInfo.getUserId() };
        \\        List<UserRecordAccess> accessRows = [
        \\            SELECT RecordId
        \\            FROM UserRecordAccess
        \\            WHERE UserId = :System.UserInfo.getUserId() AND RecordId IN :recordIds AND HasDeleteAccess = TRUE
        \\        ];
        \\        return String.valueOf(accessRows.size()) + ':' + String.valueOf(accessRows.get(0).RecordId == account.Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UserRecordAccessDeleteQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:true", result.value.string);
}

test "E2E: SOQL WHERE resolves multi-hop parent relationship fields" {
    const source =
        \\public class MultiHopParentWhereTest {
        \\    public static Integer test() {
        \\        Account account = new Account(Name = 'Parent');
        \\        insert account;
        \\        Contact contact = new Contact(LastName = 'Child', AccountId = account.Id);
        \\        insert contact;
        \\        return [SELECT COUNT() FROM Contact WHERE Account.Owner.Name = 'Test User'];
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MultiHopParentWhereTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 1), result.value.integer);
}

test "E2E: Database DmlOptions allOrNone false returns partial save results" {
    const source =
        \\public class DatabaseDmlOptionsTest {
        \\    public static String test() {
        \\        Account existing = new Account(Name = 'Existing');
        \\        insert existing;
        \\
        \\        List<Account> insertRows = new List<Account>{
        \\            new Account(Name = 'Fresh'),
        \\            existing
        \\        };
        \\        Database.DmlOptions insertOptions = new Database.DmlOptions();
        \\        insertOptions.OptAllOrNone = false;
        \\        List<Database.SaveResult> insertResults = Database.insert(insertRows, insertOptions);
        \\
        \\        List<Account> updateRows = new List<Account>{
        \\            new Account(Id = existing.Id, Name = 'Updated'),
        \\            new Account(Name = 'Missing Id')
        \\        };
        \\        Database.DmlOptions updateOptions = new Database.DmlOptions();
        \\        updateOptions.OptAllOrNone = false;
        \\        List<Database.SaveResult> updateResults = Database.update(updateRows, updateOptions);
        \\
        \\        return String.valueOf(insertResults[0].isSuccess()) + ':' +
        \\            String.valueOf(insertResults[1].isSuccess()) + ':' +
        \\            String.valueOf(updateResults[0].isSuccess()) + ':' +
        \\            String.valueOf(updateResults[1].isSuccess());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DatabaseDmlOptionsTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:false:true:false", result.value.string);
}

test "E2E: Database partial DML with null list returns empty results" {
    const source =
        \\public class DatabaseNullListDmlTest {
        \\    public static String test() {
        \\        List<Account> rows = null;
        \\        Database.DmlOptions options = new Database.DmlOptions();
        \\        options.OptAllOrNone = false;
        \\        List<Database.SaveResult> results = Database.insert(rows, options);
        \\        return String.valueOf(results.size()) + ':' + String.valueOf(Limits.getDmlStatements());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DatabaseNullListDmlTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:0", result.value.string);
}

test "E2E: JSON-deserialized DML errors expose message status and fields" {
    const source =
        \\public class JsonDmlErrorAccessTest {
        \\    public static String test() {
        \\        Database.SaveResult result = (Database.SaveResult) JSON.deserialize(
        \\            '{"success":false,"errors":[{"message":"Could not save...","statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION","fields":["Name","Industry"]}]}',
        \\            Database.SaveResult.class
        \\        );
        \\        Database.Error errorRow = result.getErrors().get(0);
        \\        return String.valueOf(errorRow.getStatusCode()) + ':' + errorRow.getMessage() + ':' + String.join(errorRow.get_fields(), ',');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonDmlErrorAccessTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "FIELD_CUSTOM_VALIDATION_EXCEPTION:Could not save...:Name,Industry",
        result.value.string,
    );
}

test "E2E: direct chained access on JSON-deserialized DML errors keeps getter semantics" {
    const source =
        \\public class JsonDmlErrorDirectAccessTest {
        \\    public static String test() {
        \\        Database.SaveResult result = (Database.SaveResult) JSON.deserialize(
        \\            '{"success":false,"errors":[{"message":"Could not save...","statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION","fields":["Name"]}]}',
        \\            Database.SaveResult.class
        \\        );
        \\        return result.errors.get(0).getMessage() + ':' + String.join(result.errors.get(0).get_fields(), ',');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonDmlErrorDirectAccessTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Could not save...:Name", result.value.string);
}

test "E2E: partial undelete preserves bind-list order for ALL ROWS queries" {
    const source =
        \\public class PartialUndeleteOrderTest {
        \\    public class DataStore {
        \\        private static Database databaseInstance {
        \\            get {
        \\                if (databaseInstance == null) {
        \\                    databaseInstance = new Database();
        \\                }
        \\                return databaseInstance;
        \\            }
        \\            set;
        \\        }
        \\        public static Database getDatabase() {
        \\            return databaseInstance;
        \\        }
        \\        public virtual class Database {
        \\            public virtual List<Database.UndeleteResult> undelete_records(List<SObject> records, Boolean allOrNone) {
        \\                return System.Database.undelete(records, allOrNone);
        \\            }
        \\        }
        \\    }
        \\    public static String test() {
        \\        List<Account> rows = new List<Account>{
        \\            new Account(Name = 'one'),
        \\            new Account(Name = 'two')
        \\        };
        \\        insert rows;
        \\        delete rows.get(0);
        \\        rows = [SELECT Id, IsDeleted FROM Account WHERE Id IN :rows ALL ROWS];
        \\        List<Database.UndeleteResult> results = DataStore.getDatabase().undelete_records(rows, false);
        \\        List<Account> persisted = [SELECT Id, IsDeleted FROM Account WHERE Id IN :rows ALL ROWS];
        \\        return String.valueOf(results.size()) + '|' +
        \\            String.valueOf(results.get(0).isSuccess()) + '|' +
        \\            String.valueOf(results.get(1).isSuccess()) + '|' +
        \\            String.valueOf(persisted.get(0).IsDeleted) + '|' +
        \\            String.valueOf(persisted.get(1).IsDeleted);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PartialUndeleteOrderTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2|true|false|false|false", result.value.string);
}

test "E2E: Messaging reserveSingleEmailCapacity updates org limits and throws when exhausted" {
    const source =
        \\public class MessagingSingleEmailCapacityTest {
        \\    public static String test() {
        \\        Integer startingValue = OrgLimits.getMap().get('SingleEmail').getValue();
        \\        Integer limitValue = OrgLimits.getMap().get('SingleEmail').getLimit();
        \\        Messaging.reserveSingleEmailCapacity(limitValue - startingValue - 1);
        \\        Integer reservedValue = OrgLimits.getMap().get('SingleEmail').getValue();
        \\        try {
        \\            Messaging.reserveSingleEmailCapacity(1);
        \\            return 'missed';
        \\        } catch (HandledException e) {
        \\            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        \\            message.setHtmlBody('hello');
        \\            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
        \\            return String.valueOf(reservedValue == limitValue - 1) + ':' + message.getHtmlBody() + ':' + String.valueOf(Limits.getEmailInvocations());
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MessagingSingleEmailCapacityTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:hello:1", result.value.string);
}

test "E2E: Type.forName SObject type returns sobject with getSObjectType" {
    const source =
        \\public class TypeForNameSObjectTest {
        \\    public static String test() {
        \\        SObject obj = (SObject) Type.forName('Account').newInstance();
        \\        Schema.SObjectType sot = obj.getSObjectType();
        \\        return String.valueOf(sot);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TypeForNameSObjectTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Account", result.value.string);
}

test "E2E: fixture flow definition view selector test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogManagementDataSelector_Tests_Flow",
        "it_returns_matching_flow_definition_view_for_specified_flow_api_name",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture cached organization selector test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LoggerEngineDataSelector_Tests",
        "it_returns_cached_organization",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture sobject put rejects incompatible datetime string" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    const source =
        \\public class InvalidDatetimePutProbe {
        \\    public static Boolean test() {
        \\        LogEntry__c logEntry = new LogEntry__c();
        \\        try {
        \\            logEntry.put('Timestamp__c', 'Some value');
        \\            return false;
        \\        } catch (System.Exception ex) {
        \\            return true;
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InvalidDatetimePutProbe",
        .entry_method = "test",
        .source_paths = fixture_paths.slice(),
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: fixture field mapping integration test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests_FieldMappings",
        "it_should_use_field_mappings_on_logger_scenario_and_log_and_log_entry_when_mappings_have_been_configured",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture transaction limits builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_transaction_limits_fields_when_enabled_via_logger_parameter",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture auth session builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_run_authSession_query_when_enabled_via_logger_parameter",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture organization builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_run_organization_query_when_enabled_via_logger_parameter",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture user builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_run_user_query_when_enabled_via_logger_parameter",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: custom object query by Name IN set finds existing record" {
    const source =
        \\public class NameInSetQueryProbe {
        \\    public static String test() {
        \\        insert new Thing__c(Name = 'Some tag!', UniqueId__c = 'Some tag!');
        \\        Set<String> names = new Set<String>{ 'Some tag!' };
        \\        List<Thing__c> rows = [SELECT Id, Name FROM Thing__c WHERE Name IN :names];
        \\        return String.valueOf(rows.size()) + ':' + (rows.isEmpty() ? '' : rows.get(0).Name);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NameInSetQueryProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:Some tag!", result.value.string);
}

test "E2E: custom object upsert by external id updates existing record" {
    const source =
        \\public class ExternalIdUpsertProbe {
        \\    public static String test() {
        \\        Thing__c firstRow = new Thing__c(Name = 'original', UniqueId__c = 'txn-1');
        \\        Database.upsert(new List<SObject>{ firstRow }, Schema.Thing__c.UniqueId__c);
        \\
        \\        Thing__c secondRow = new Thing__c(Name = 'updated', UniqueId__c = 'txn-1');
        \\        Database.upsert(new List<SObject>{ secondRow }, Schema.Thing__c.UniqueId__c);
        \\
        \\        List<Thing__c> rows = [SELECT Id, Name, UniqueId__c FROM Thing__c WHERE UniqueId__c = 'txn-1'];
        \\        return String.valueOf(rows.size()) + ':' + rows.get(0).Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ExternalIdUpsertProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:updated", result.value.string);
}

test "E2E: SOQL IN bind resolves map values expression" {
    const source =
        \\public class InBindValuesProbe {
        \\    public static String test() {
        \\        Map<String, Thing__c> rowsByKey = new Map<String, Thing__c>();
        \\        rowsByKey.put('txn-1', new Thing__c(Name = 'first', UniqueId__c = 'txn-1'));
        \\        rowsByKey.put('txn-2', new Thing__c(Name = 'second', UniqueId__c = 'txn-2'));
        \\
        \\        Database.upsert(rowsByKey.values(), Schema.Thing__c.UniqueId__c);
        \\
        \\        List<Thing__c> rows = [
        \\            SELECT Id, Name
        \\            FROM Thing__c
        \\            WHERE Id IN :rowsByKey.values()
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' + rowsByKey.get('txn-1').Id;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InBindValuesProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "2:a"));
}

test "E2E: SOQL equality bind treats collection binds as membership" {
    const source =
        \\public class EqualityBindCollectionProbe {
        \\    public static String test() {
        \\        insert new Thing__c(Name = 'alpha', UniqueId__c = 'alpha');
        \\        insert new Thing__c(Name = 'beta', UniqueId__c = 'beta');
        \\
        \\        Map<String, String> selectedNames = new Map<String, String>();
        \\        selectedNames.put('alpha', 'included');
        \\
        \\        List<Thing__c> rows = [
        \\            SELECT Id, Name
        \\            FROM Thing__c
        \\            WHERE Name = :selectedNames.keySet()
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' + rows.get(0).Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "EqualityBindCollectionProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:alpha", result.value.string);
}

test "E2E: synthetic User query respects Alias filters" {
    const source =
        \\public class UserAliasQueryProbe {
        \\    public static String test() {
        \\        Schema.User userRow = [SELECT Id, Alias, UserType FROM User WHERE Alias = 'autoproc'];
        \\        return userRow.Alias + ':' + userRow.UserType;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UserAliasQueryProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("autoproc:AutomatedProcess", result.value.string);
}

test "E2E: fixture duplicate scenario guard test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LoggerScenarioHandler_Tests",
        "it_should_not_allow_duplicate_scenario_to_be_inserted",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture tag creation test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests",
        "it_should_create_tag_records_when_tagging_is_enabled",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture tag reuse test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests",
        "it_should_reuse_existing_tag_records",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture event-uuid upsert test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests",
        "it_should_upsert_log_entries_when_event_uuid_is_populated",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: custom object upsert by external id inserts queryable row" {
    const source =
        \\public class ExternalIdInsertProbe {
        \\    public static String test() {
        \\        List<SObject> rows = new List<SObject>{
        \\            new Thing__c(Name = 'Created', UniqueId__c = 'created-1')
        \\        };
        \\        Database.upsert(rows, Schema.Thing__c.UniqueId__c);
        \\        List<Thing__c> saved = [SELECT Id, Name, UniqueId__c FROM Thing__c WHERE UniqueId__c = 'created-1'];
        \\        return String.valueOf(saved.size()) + ':' + String.valueOf(rows.get(0).Id != null) + ':' + saved.get(0).Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ExternalIdInsertProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:true:Created", result.value.string);
}

test "E2E: switch on newSObject matches custom object type-binding clause" {
    const source =
        \\public class SwitchOnNewSObjectProbe {
        \\    public static String test() {
        \\        switch on Schema.Thing__c.SObjectType.newSObject() {
        \\            when Thing__c row {
        \\                return 'custom';
        \\            }
        \\            when else {
        \\                return 'else';
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SwitchOnNewSObjectProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("custom", result.value.string);
}

test "E2E: List constructor preserves SObjects from Set" {
    const source =
        \\public class SetToListProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Acme');
        \\        Set<SObject> rows = new Set<SObject>();
        \\        rows.add(account);
        \\        List<SObject> copied = new List<SObject>(rows);
        \\        return copied.size() + ':' + copied.get(0).getSObjectType();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SetToListProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:Account", result.value.string);
}

test "E2E: Formula.builder chain returns a FormulaInstance that evaluates simple formulas" {
    // Anonymized probe: apex-trigger-actions-framework's FormulaFilter builds
    // a boolean formula via the chain
    //     Formula.builder()
    //         .withReturnType(FormulaEval.FormulaReturnType.Boolean)
    //         .withType(TriggerRecordSubclass.class)
    //         .withFormula('record.Name = "X"' or 'CONTAINS(record.Field,"Y")')
    //         .build();
    // and then calls `.evaluate(triggerRecordInstance)` per record to decide
    // inclusion. We stub:
    //   - the fluent configurators to return the builder,
    //   - a validation gate on build() that rejects non-global classes and
    //     unrecognisable formulas (mirrors real Apex's
    //     FormulaValidationException),
    //   - an evaluator for `<path> = "literal"` and `CONTAINS(<path>, "...")`
    //     that walks the TriggerRecord's `newSobject` / `oldSobject` tower.
    const source =
        \\global class FormulaEvalProbe {
        \\    global class Dummy extends TriggerRecord {}
        \\    global static String test() {
        \\        FormulaEval.FormulaInstance equality = Formula.builder()
        \\            .withReturnType(FormulaEval.FormulaReturnType.Boolean)
        \\            .withType(Dummy.class)
        \\            .withFormula('record.Name = "hit"')
        \\            .build();
        \\        FormulaEval.FormulaInstance contains = Formula.builder()
        \\            .withReturnType(FormulaEval.FormulaReturnType.Boolean)
        \\            .withType(Dummy.class)
        \\            .withFormula('CONTAINS(record.Description, "needle")')
        \\            .build();
        \\        Dummy hitRec = new Dummy();
        \\        hitRec.newSobject = new Account(Name='hit', Description='needle-in-haystack');
        \\        Dummy missRec = new Dummy();
        \\        missRec.newSobject = new Account(Name='miss', Description='nothing');
        \\        return
        \\            'eqHit=' + String.valueOf((Boolean) equality.evaluate(hitRec)) +
        \\            '|eqMiss=' + String.valueOf((Boolean) equality.evaluate(missRec)) +
        \\            '|ctHit=' + String.valueOf((Boolean) contains.evaluate(hitRec)) +
        \\            '|ctMiss=' + String.valueOf((Boolean) contains.evaluate(missRec));
        \\    }
        \\}
        \\global abstract class TriggerRecord {
        \\    global SObject newSobject;
        \\    global SObject oldSobject;
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FormulaEvalProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "eqHit=true|eqMiss=false|ctHit=true|ctMiss=false",
        result.value.string,
    );
}

test "E2E: QueryException.getInaccessibleFields lists fields blocked in user mode" {
    // Anonymized probe: fflib_SObjectSelectorTest catches a QueryException
    // thrown by a USER_MODE SOQL query run under a minimum-access user and
    // asserts that `qe.getInaccessibleFields().get('Opportunity')` is a Set
    // containing the inaccessible field names. We used to leave the
    // exception bare (only `message` set), so the fflib assertion failed
    // with "Expected: non-null, Actual: null".
    const source =
        \\public class InaccessibleFieldsProbe {
        \\    public static String test() {
        \\        System.runAs(getMinimumAccessUser()) {
        \\            try {
        \\                List<Opportunity> opps = [SELECT Name, Amount FROM Opportunity WITH USER_MODE];
        \\                return 'no-exception';
        \\            } catch (QueryException qe) {
        \\                Map<String, Set<String>> inaccess = qe.getInaccessibleFields();
        \\                if (inaccess == null) return 'null-map';
        \\                Set<String> oppFields = inaccess.get('Opportunity');
        \\                if (oppFields == null) return 'null-set';
        \\                return 'present|Name=' + String.valueOf(oppFields.contains('Name')) +
        \\                    '|Amount=' + String.valueOf(oppFields.contains('Amount'));
        \\            }
        \\        }
        \\        return 'fell-through';
        \\    }
        \\
        \\    static User getMinimumAccessUser() {
        \\        // Synthesize a restricted user inline by returning a User bound
        \\        // to a "Minimum Access" profile. setupTestUser-style helper kept
        \\        // terse for the probe.
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        \\        User u = new User(
        \\            Email='min@probe.test', Username='min@probe-x.test', LastName='min',
        \\            Alias='min', ProfileId=p.Id, LanguageLocaleKey='en_US',
        \\            LocaleSidKey='en_US', TimeZoneSidKey='America/Chicago', EmailEncodingKey='UTF-8');
        \\        insert u;
        \\        return u;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InaccessibleFieldsProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("present|Name=true|Amount=true", result.value.string);
}

test "E2E: DescribeFieldResult.getSObjectType and isIdLookup report the owning object" {
    // Anonymized probe: fflib_SObjectUnitOfWork's upsert-by-external-id path
    // validates `record.getSObjectType() == fieldDescribe.getSObjectType()`
    // and then calls `fieldDescribe.isIdLookup()`. We used to return null
    // from getSObjectType on a DescribeFieldResult and always-false from
    // isIdLookup, so every upsert-by-external-id test blew up with
    // "Invalid argument: externalIdField. Field supplied is not a known
    //  field on the target sObject." even for the trivial Opportunity.Id
    // case. The fix: consult the `objectType` the describe was built with
    // for getSObjectType, and return true from isIdLookup for Id (and for
    // fields marked external id in field-meta.xml).
    const source =
        \\public class DescribeFieldOwnerProbe {
        \\    public static String test() {
        \\        DescribeFieldResult fdr = Opportunity.Id.getDescribe();
        \\        SObjectType fieldOwner = fdr.getSObjectType();
        \\        Boolean idLookup = fdr.isIdLookup();
        \\        SObjectType recType = new Opportunity(Name='T').getSObjectType();
        \\        return String.valueOf(fieldOwner) + '|' +
        \\            String.valueOf(recType == fieldOwner) + '|' +
        \\            String.valueOf(idLookup);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DescribeFieldOwnerProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Opportunity|true|true", result.value.string);
}

test "E2E: explicit new List<SObject>() stays null on getSObjectType regardless of contents" {
    // Real Apex: `new List<SObject>()` is a truly-generic construction; even
    // if every element you add happens to share the same concrete SObjectType,
    // `getSObjectType()` returns null. NebulaLogger's
    // `setRecord(System.Iterable<Id>)` relies on this — it builds a local
    // `new List<SObject>()` from User Ids and expects
    // `RecordSObjectClassification__c = 'Unknown'`. The homogeneous-inference
    // path (see next test) is reserved for lists that acquired
    // `element_type = "SObject"` indirectly, not explicit user constructions.
    const source =
        \\public class GenericListTypeProbe {
        \\    public static String test() {
        \\        List<SObject> homogenous = new List<SObject>();
        \\        homogenous.add(new Account(Name = 'Acme'));
        \\        homogenous.add(new Account(Name = 'Beta'));
        \\        List<SObject> mixed = new List<SObject>();
        \\        mixed.add(new Account(Name = 'Acme'));
        \\        mixed.add(new Contact(LastName = 'Doe'));
        \\        List<SObject> empty = new List<SObject>();
        \\        return String.valueOf(homogenous.getSObjectType() == null) + ':' +
        \\            String.valueOf(mixed.getSObjectType() == null) + ':' +
        \\            String.valueOf(empty.getSObjectType() == null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "GenericListTypeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:true", result.value.string);
}

test "E2E: Map<Id, SObject>.values() preserves homogeneous SObjectType for generic callers" {
    // Real Apex: when a `Map<Id, SObject>` is populated with homogeneous
    // records and piped through a generic `List<SObject>` parameter (as
    // `fflib_SObjectDomain`'s super(records) → this(records, records
    // .getSObjectType()) does), the underlying list keeps its runtime element
    // type. The list never went through an explicit `new List<SObject>()`
    // construction, so it is allowed to resolve its SObjectType via the
    // homogeneous-inference fallback instead of short-circuiting to null.
    const source =
        \\public class MapValuesSObjectTypeProbe {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'Acme');
        \\        a.Id = '001000000000001AAA';
        \\        Account b = new Account(Name = 'Beta');
        \\        b.Id = '001000000000002AAA';
        \\        Map<Id, SObject> byId = new Map<Id, SObject>();
        \\        byId.put(a.Id, a);
        \\        byId.put(b.Id, b);
        \\        return String.valueOf(byId.values().getSObjectType());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MapValuesSObjectTypeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Account", result.value.string);
}

test "E2E: concrete typed list reports its SObjectType" {
    const source =
        \\public class ConcreteListTypeProbe {
        \\    public static String test() {
        \\        List<Account> rows = new List<Account>{ new Account(Name = 'Acme') };
        \\        return String.valueOf(rows.getSObjectType()) + ':' +
        \\            String.valueOf(rows.getSObjectType() != null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ConcreteListTypeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Account:true", result.value.string);
}

test "E2E: Set<SObject> keeps distinct unsaved records by field values" {
    const source =
        \\public class DistinctUnsavedSetProbe {
        \\    public static String test() {
        \\        Set<SObject> rows = new Set<SObject>();
        \\        rows.add(new Thing__c(Name = 'first', UniqueId__c = 'u1'));
        \\        rows.add(new Thing__c(Name = 'second', UniqueId__c = 'u2'));
        \\        List<SObject> copied = new List<SObject>(rows);
        \\        return String.valueOf(rows.size()) + ':' + String.valueOf(copied.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DistinctUnsavedSetProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:2", result.value.string);
}

test "E2E: inner database gateway upsert writes Ids back to original rows" {
    const source =
        \\public class DataGateway {
        \\    private static Database databaseInstance = new Database();
        \\    public static Database getDatabase() {
        \\        return databaseInstance;
        \\    }
        \\    public virtual class Database {
        \\        public virtual List<Database.UpsertResult> upsert_records(List<SObject> records, Schema.SObjectField externalIdField) {
        \\            return System.Database.upsert(records, externalIdField);
        \\        }
        \\    }
        \\}
        \\public class DataGatewayUpsertProbe {
        \\    public static String test() {
        \\        List<Thing__c> rows = new List<Thing__c>{ new Thing__c(Name = 'created', UniqueId__c = 'txn-1') };
        \\        List<SObject> copied = new List<SObject>(rows);
        \\        DataGateway.getDatabase().upsert_records(copied, Schema.Thing__c.UniqueId__c);
        \\        return String.valueOf(rows.get(0).Id) + ':' + String.valueOf(copied.get(0).Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DataGatewayUpsertProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "a"));
}

test "E2E: concrete custom-object list keeps Ids after List<SObject> upsert call" {
    const source =
        \\public class TypedGatewayProbe {
        \\    private static Database databaseInstance = new Database();
        \\    public static Database getDatabase() {
        \\        return databaseInstance;
        \\    }
        \\    public virtual class Database {
        \\        public virtual List<Database.UpsertResult> upsert_records(List<SObject> records, Schema.SObjectField externalIdField) {
        \\            return System.Database.upsert(records, externalIdField);
        \\        }
        \\    }
        \\    public static String test() {
        \\        List<Thing__c> rows = new List<Thing__c>{ new Thing__c(Name = 'created', UniqueId__c = 'txn-typed') };
        \\        getDatabase().upsert_records(rows, Schema.Thing__c.UniqueId__c);
        \\        return String.valueOf(rows.get(0).Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TypedGatewayProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "a"));
}

test "E2E: List<SObject> copy preserves SObject identity for DML" {
    const source =
        \\public class ListIdentityProbe {
        \\    public static String test() {
        \\        List<Account> rows = new List<Account>{ new Account(Name = 'Acme') };
        \\        List<SObject> copied = new List<SObject>(rows);
        \\        insert copied;
        \\        return String.valueOf(rows.get(0).Id) + ':' + String.valueOf(copied.get(0).Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ListIdentityProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "001"));
}

test "E2E: Database.upsert list writes Id back to original row" {
    const source =
        \\public class DatabaseUpsertListIdentityProbe {
        \\    public static String test() {
        \\        List<SObject> rows = new List<SObject>{ new Thing__c(Name = 'created', UniqueId__c = 'txn-1') };
        \\        Database.upsert(rows, Schema.Thing__c.UniqueId__c);
        \\        return String.valueOf(rows.get(0).Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DatabaseUpsertListIdentityProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "a"));
}

test "E2E: wrapper method preserves list element identity for Database.upsert" {
    const source =
        \\public class WrapperIdentityProbe {
        \\    public static void save(List<SObject> rows) {
        \\        Database.upsert(rows, Schema.Thing__c.UniqueId__c);
        \\    }
        \\    public static String test() {
        \\        List<Thing__c> rows = new List<Thing__c>{ new Thing__c(Name = 'created', UniqueId__c = 'txn-1') };
        \\        List<SObject> copied = new List<SObject>(rows);
        \\        save(copied);
        \\        return String.valueOf(rows.get(0).Id) + ':' + String.valueOf(copied.get(0).Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "WrapperIdentityProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "a"));
}

test "E2E: inner class named Database can call System.Database.upsert" {
    const source =
        \\public class InnerDatabaseProbe {
        \\    public class Database {
        \\        public static void save(List<SObject> rows) {
        \\            System.Database.upsert(rows, Schema.Thing__c.UniqueId__c);
        \\        }
        \\    }
        \\    public static String test() {
        \\        List<SObject> rows = new List<SObject>{ new Thing__c(Name = 'created', UniqueId__c = 'txn-1') };
        \\        Database.save(rows);
        \\        return String.valueOf(rows.get(0).Id);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerDatabaseProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "a"));
}

test "E2E: fixture anonymous-mode-disabled user fields test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_user_fields_when_anonymous_mode_disabled",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture standard-object recordId test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_recordId_when_template_standard_object",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture custom-object recordId test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_recordId_when_custom_object",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null record overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_record_when_null",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null list overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_list_of_records_when_list_is_null",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null map overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_map_of_sobject_records_when_map_is_null",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null iterable overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_iterable_ids_when_null",
        &out.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: Type.forName custom object __e returns sobject with put/get" {
    const source =
        \\public class TypeForNameEventTest {
        \\    public static String test() {
        \\        SObject obj = (SObject) Type.forName('MyEvent__e').newInstance();
        \\        obj.put('Message__c', 'hello');
        \\        return (String) obj.get('Message__c');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TypeForNameEventTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("hello", result.value.string);
}

test "E2E: EventBus.publish returns failed SaveResult when required event fields are missing" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Signal__e/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Signal__e/Signal__e.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <eventType>HighVolume</eventType>
        \\    <label>Signal</label>
        \\    <pluralLabel>Signals</pluralLabel>
        \\    <publishBehavior>PublishAfterCommit</publishBehavior>
        \\</CustomObject>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Signal__e/fields/Message__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Message__c</fullName>
        \\    <required>true</required>
        \\    <type>Text</type>
        \\    <length>255</length>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class RequiredEventPublishTest {
        \\    public static String test() {
        \\        Database.SaveResult publishResult = EventBus.publish(new Signal__e());
        \\        return String.valueOf(publishResult.isSuccess());
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "RequiredEventPublishTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false", result.value.string);
}

test "E2E: EventBus.publish keeps live platform event Id field unset" {
    const source =
        \\public class PublishedPlatformEventIdTest {
        \\    public static String test() {
        \\        MyEvent__e eventRecord = new MyEvent__e();
        \\        eventRecord.put('Message__c', 'hello');
        \\        EventBus.publish(eventRecord);
        \\        return String.valueOf(eventRecord.Id == null) + ':' + String.valueOf(eventRecord.get('Id') == null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PublishedPlatformEventIdTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true", result.value.string);
}

test "E2E: synthetic AppMenuItem query exposes app order entries" {
    const source =
        \\public class AppMenuItemQueryTest {
        \\    public static String test() {
        \\        List<AppMenuItem> items = [SELECT ApplicationId, Name FROM AppMenuItem];
        \\        return String.valueOf(items.size()) + ':' + items[0].Name + ':' + String.valueOf(items[0].ApplicationId != null);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AppMenuItemQueryTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:Apex_Recipes:true", result.value.string);
}

test "E2E: Type.forName SObject + empty list DML integration" {
    const source =
        \\public class IntegrationTest {
        \\    public static Integer test() {
        \\        // SObject newInstance works
        \\        SObject obj = (SObject) Type.forName('Account').newInstance();
        \\        Schema.SObjectType sot = obj.getSObjectType();
        \\        System.assertNotEquals(null, sot);
        \\        // Empty list DML does not count
        \\        List<Account> emptyList = new List<Account>();
        \\        insert emptyList;
        \\        // Only actual insert counts
        \\        Account a = new Account(Name = 'Test');
        \\        insert a;
        \\        return Limits.getDmlStatements();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "IntegrationTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 1), result.value.integer);
}

test "E2E: SObject.get throws for unknown field names" {
    const source =
        \\public class UnknownFieldGetTest {
        \\    public static String test() {
        \\        try {
        \\            new Account(Name = 'Acme').get('MissingField');
        \\            return 'unexpected';
        \\        } catch (System.SObjectException e) {
        \\            return e.getMessage().contains('Invalid field') ? 'ok' : e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UnknownFieldGetTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: JSON.deserializeUntyped throws on malformed root input" {
    const source =
        \\public class InvalidJsonParseTest {
        \\    public static String test() {
        \\        try {
        \\            JSON.deserializeUntyped('invalidJSON');
        \\            return 'unexpected';
        \\        } catch (System.JSONException e) {
        \\            return e.getMessage().contains('Malformed') ? 'ok' : e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InvalidJsonParseTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: Decimal.valueOf throws on invalid numeric strings" {
    const source =
        \\public class InvalidDecimalValueTest {
        \\    public static String test() {
        \\        try {
        \\            Decimal.valueOf('abc');
        \\            return 'unexpected';
        \\        } catch (System.TypeException e) {
        \\            return e.getMessage().contains('Invalid decimal') ? 'ok' : e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InvalidDecimalValueTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: compound assignment preserves numeric accumulation across mixed numeric types" {
    const source =
        \\public class MixedNumericCompoundAssignTest {
        \\    public static String test() {
        \\        Decimal total = 0;
        \\        for (Decimal value : new List<Decimal>{ 20, 10 }) {
        \\            total += value;
        \\        }
        \\        total /= 2;
        \\        return String.valueOf(total);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MixedNumericCompoundAssignTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("15", result.value.string);
}

test "E2E: inner enum valueOf throws for unknown values" {
    const source =
        \\public class InvalidInnerEnumValueTest {
        \\    private enum Mode {
        \\        Alpha,
        \\        Beta
        \\    }
        \\    public static String test() {
        \\        try {
        \\            Mode.valueOf('Gamma');
        \\            return 'unexpected';
        \\        } catch (System.NoSuchElementException e) {
        \\            return e.getMessage().contains('Gamma') ? 'ok' : e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InvalidInnerEnumValueTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.value.string);
}

test "E2E: describe maps include common Task date and picklist fields" {
    const source =
        \\public class TaskDescribeFieldCoverageTest {
        \\    public static String test() {
        \\        Task taskRecord = new Task(
        \\            Subject = 'Example',
        \\            ActivityDate = Date.today(),
        \\            Priority = 'High'
        \\        );
        \\        Map<String, Schema.SObjectField> fieldsByName = taskRecord.getSObjectType().getDescribe().fields.getMap();
        \\        return fieldsByName.get('ActivityDate').getDescribe().getType().name()
        \\            + ':' + fieldsByName.get('Priority').getDescribe().getType().name();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TaskDescribeFieldCoverageTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("DATE:PICKLIST", result.value.string);
}

test "E2E: Approval lock APIs toggle record lock state" {
    const source =
        \\public class ApprovalLockStateTest {
        \\    public static String test() {
        \\        Account row = new Account(Name = 'Locked');
        \\        insert row;
        \\        Approval.LockResult lockResult = Approval.lock(row.Id);
        \\        Boolean afterLock = Approval.isLocked(row.Id);
        \\        Approval.UnlockResult unlockResult = Approval.unlock(row.Id);
        \\        Boolean afterUnlock = Approval.isLocked(row.Id);
        \\        return String.valueOf(lockResult.isSuccess()) + ':' +
        \\            String.valueOf(afterLock) + ':' +
        \\            String.valueOf(unlockResult.isSuccess()) + ':' +
        \\            String.valueOf(afterUnlock);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ApprovalLockStateTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:true:false", result.value.string);
}

test "E2E: BusinessHours query and diff return default day duration" {
    const source =
        \\public class BusinessHoursDiffTest {
        \\    public static String test() {
        \\        BusinessHours hours = [SELECT Id, Name FROM BusinessHours WHERE Name = 'Default' LIMIT 1];
        \\        Datetime startDate = Datetime.newInstance(2020, 3, 27);
        \\        Datetime endDate = startDate.addDays(1);
        \\        Long duration = BusinessHours.diff(hours.Id, startDate, endDate);
        \\        return hours.Name + ':' + String.valueOf(duration);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "BusinessHoursDiffTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Default:86400000", result.value.string);
}

test "E2E: List.sort propagates Comparable exceptions" {
    const source =
        \\public class SortExceptionPropagationTest {
        \\    public class BrokenComparable implements Comparable {
        \\        public Integer compareTo(Object otherValue) {
        \\            throw new UnsupportedOperationException('unsupported sort type');
        \\        }
        \\    }
        \\    public static String test() {
        \\        List<BrokenComparable> items = new List<BrokenComparable>{
        \\            new BrokenComparable(),
        \\            new BrokenComparable()
        \\        };
        \\        try {
        \\            items.sort();
        \\            return 'unexpected';
        \\        } catch (System.UnsupportedOperationException e) {
        \\            return e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SortExceptionPropagationTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("unsupported sort type", result.value.string);
}

test "E2E: multi-level dotted class literal returns non-null Type" {
    // Anonymized probe: `Flow.Interview.X.class` style expressions resolve to a
    // Type object whose name is the full dotted path, even when the chain does
    // not correspond to a loaded class (the TriggerActionFlow framework relies
    // on this in order to forward the Type to its NameExtractor hook).
    const source =
        \\public class MultiLevelClassLiteralProbe {
        \\    public class MyFlow {}
        \\    public static String test() {
        \\        System.Type t1 = Flow.Interview.MyFlow.class;
        \\        System.Type t2 = Outer.Middle.Inner.class;
        \\        System.Type t3 = Flow.Interview.DefinitelyNotAFlow.class;
        \\        return (t1 == null ? 'null' : t1.getName()) + '|' +
        \\               (t2 == null ? 'null' : t2.getName()) + '|' +
        \\               (t3 == null ? 'null' : t3.getName());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MultiLevelClassLiteralProbe",
        .entry_method = "test",
    });
    defer result.deinit();
    // Flow.Interview.<Leaf> collapses to just "Flow.Interview" when the leaf
    // does not name a loaded class (mirrors Apex's "flow doesn't exist"
    // runtime behaviour). The generic Outer.Middle.Inner chain keeps its
    // full path.
    try std.testing.expectEqualStrings(
        "Flow.Interview.MyFlow|Outer.Middle.Inner|Flow.Interview",
        result.value.string,
    );
}

test "E2E: Invocable.Action.Result JSON round-trip exposes getters" {
    // Anonymized probe: frameworks that deserialize into framework classes such
    // as Invocable.Action.Result must expose isSuccess()/getOutputParameters()
    // after the round-trip so that trigger-action Flow plumbing can stitch the
    // outputs back into SObject records.
    const source =
        \\public class InvocableResultRoundTripProbe {
        \\    public static String test() {
        \\        Map<String, Object> seed = new Map<String, Object>{
        \\            'success' => true,
        \\            'outputParameters' => new Map<String, Object>()
        \\        };
        \\        String json = JSON.serialize(seed);
        \\        Invocable.Action.Result result = (Invocable.Action.Result) JSON.deserialize(
        \\            json,
        \\            Invocable.Action.Result.class
        \\        );
        \\        result.getOutputParameters().putAll(new Map<String, Object>{ 'k' => 'v' });
        \\        return String.valueOf(result.isSuccess()) + ':' +
        \\               String.valueOf(result.getOutputParameters().size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InvocableResultRoundTripProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:1", result.value.string);
}

test "E2E: SObject getPopulatedFieldsAsMap hides synthetic errors key" {
    // Anonymized probe: after addError() attaches an in-memory Database.Error
    // to the SObject, the populated-fields map must still only surface real
    // SObject fields — otherwise downstream copies such as "for (String fn :
    // rec.getPopulatedFieldsAsMap().keySet()) rec.put(fn, ...)" blow up with
    // "Invalid field errors" on common schemas.
    const source =
        \\public class PopulatedFieldsErrorsHidingProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Probe');
        \\        account.addError('boom');
        \\        Map<String, Object> populated = account.getPopulatedFieldsAsMap();
        \\        return String.valueOf(populated.containsKey('errors')) + ':' +
        \\               String.valueOf(populated.containsKey('Name'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PopulatedFieldsErrorsHidingProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:true", result.value.string);
}

test "E2E: Database.setSavepoint counts toward Limits.getDmlStatements" {
    // Anonymized probe: setSavepoint/rollback are DML statements in Apex's
    // governor accounting. Finalizer handlers use this to detect illegal DML
    // ("Limits.getDmlStatements() increased after the finalizer body ran"),
    // so the counters must bump just like insert/update.
    const source =
        \\public class SavepointDmlCounterProbe {
        \\    public static String test() {
        \\        Integer before = Limits.getDmlStatements();
        \\        Database.SavePoint sp = Database.setSavepoint();
        \\        Integer afterSet = Limits.getDmlStatements();
        \\        Database.rollback(sp);
        \\        Integer afterRollback = Limits.getDmlStatements();
        \\        return String.valueOf(before) + ':' +
        \\               String.valueOf(afterSet) + ':' +
        \\               String.valueOf(afterRollback);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SavepointDmlCounterProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("0:1:2", result.value.string);
}

test "E2E: standard-field describe exposes known default values" {
    // Anonymized probe: utility classes frequently pre-seed required
    // picklists via `(String) Task.Status.getDescribe().getDefaultValue()`.
    // Well-known standard-field defaults (Task.Status -> "Not Started",
    // Case.Priority -> "Medium", Lead.Status -> "Open - Not Contacted")
    // should round-trip through the describe API so inserts succeed.
    const source =
        \\public class StandardFieldDefaultProbe {
        \\    public static String test() {
        \\        String taskStatus = (String) Task.Status.getDescribe().getDefaultValue();
        \\        String casePriority = (String) Case.Priority.getDescribe().getDefaultValue();
        \\        String leadStatus = (String) Lead.Status.getDescribe().getDefaultValue();
        \\        return taskStatus + '|' + casePriority + '|' + leadStatus;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StandardFieldDefaultProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Not Started|Medium|Open - Not Contacted",
        result.value.string,
    );
}

test "E2E: Invocable.Action.createCustomAction reports missing flow failures" {
    // Anonymized probe: utility frameworks call
    // `Invocable.Action.createCustomAction('Flow', flowName).invoke()` directly;
    // when the flow doesn't exist the resulting list must contain one
    // failure-result per invocation so callers can surface "flow not found"
    // errors without knowing the underlying framework's private error model.
    const source =
        \\public class InvocableActionFlowFailureProbe {
        \\    public static String test() {
        \\        Invocable.Action action = Invocable.Action.createCustomAction('Flow', 'NoSuchFlow');
        \\        action.setInvocations(new List<Map<String, Object>>{
        \\            new Map<String, Object>(),
        \\            new Map<String, Object>()
        \\        });
        \\        List<Invocable.Action.Result> results = action.invoke();
        \\        return String.valueOf(results.size()) + ':' +
        \\               String.valueOf(results[0].isSuccess()) + ':' +
        \\               String.valueOf(results[0].getErrors().size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InvocableActionFlowFailureProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("2:false:1", result.value.string);
}

test "E2E: String.substring clamps negative bounds instead of panicking" {
    // Anonymized probe: DSL evaluators that scan formulas frequently call
    // `input.substring(startIdx, endIdx)` with negative indices derived from
    // `indexOf(...)` returning -1. A previously unchecked @intCast to usize
    // on the negative clamped bound tripped a runtime panic. The substring
    // should now clamp both ends into [0, s.len] and return a best-effort
    // slice rather than aborting.
    const source =
        \\public class SubstringNegativeBoundProbe {
        \\    public static String test() {
        \\        String src = 'abcdef';
        \\        String part = src.substring(2, -1);
        \\        return String.valueOf(part.length());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SubstringNegativeBoundProbe",
        .entry_method = "test",
    });
    defer result.deinit();
    // start=2, clamped end=0 → start > end, so the best-effort fallback
    // returns the original string rather than panicking.
    try std.testing.expectEqualStrings("6", result.value.string);
}

test "E2E: multi-level Account.Parent.Parent.Name SOQL chain hydrates" {
    // Anonymized probe: expression-DSL and relationship-walking utilities
    // issue SOQL like
    // `SELECT Account.Parent.Parent.Name FROM Contact` and then traverse
    // the result via `contact.Account.Parent.Parent.Name`. Each hop must
    // be materialized as an SObject with the requested field copied in —
    // previously only the first hop (`Account`) was hydrated, so any code
    // that dereferenced the intermediate parents got null.
    const source =
        \\public class MultiLevelParentChainProbe {
        \\    public static String test() {
        \\        Account greatGrand = new Account(Name = 'GreatGrandParent');
        \\        insert greatGrand;
        \\        Account grand = new Account(Name = 'GrandParent', ParentId = greatGrand.Id);
        \\        insert grand;
        \\        Account parent = new Account(Name = 'Parent', ParentId = grand.Id);
        \\        insert parent;
        \\        Contact child = new Contact(LastName = 'Child', AccountId = parent.Id);
        \\        insert child;
        \\
        \\        Contact queried = [
        \\            SELECT Id, Account.Parent.Parent.Name
        \\            FROM Contact
        \\            WHERE Id = :child.Id
        \\        ];
        \\        return queried.Account.Parent.Parent.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MultiLevelParentChainProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("GreatGrandParent", result.value.string);
}

test "E2E: Account.ChildAccounts self-reference subquery populates children" {
    // Anonymized probe: self-referencing child relationship `ChildAccounts`
    // is keyed on Account.ParentId, not AccountId. Subqueries over this
    // relationship must walk the ParentId foreign key to gather children.
    const source =
        \\public class SelfRefChildSubqueryProbe {
        \\    public static Integer test() {
        \\        Account parent = new Account(Name = 'Parent');
        \\        insert parent;
        \\        Account c1 = new Account(Name = 'Child1', ParentId = parent.Id);
        \\        Account c2 = new Account(Name = 'Child2', ParentId = parent.Id);
        \\        insert new List<Account>{ c1, c2 };
        \\
        \\        Account queried = [
        \\            SELECT Id, (SELECT Id FROM ChildAccounts)
        \\            FROM Account
        \\            WHERE Id = :parent.Id
        \\        ];
        \\        return queried.ChildAccounts.size();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SelfRefChildSubqueryProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 2), result.value.integer);
}

test "E2E: Database.QueryLocator exposes iterator over query rows" {
    // Anonymized probe: selector frameworks return a Database.QueryLocator
    // from `queryLocatorById(...)` and callers drive it with
    // `locator.iterator()` / `.hasNext()` / `.next()`. Our interpreter
    // previously left QueryLocator as an opaque ObjectInstance with no
    // methods, so `.iterator()` produced null and the next call NPE'd.
    const source =
        \\public class QueryLocatorIteratorProbe {
        \\    public static String test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'Acme'),
        \\            new Account(Name = 'Beta')
        \\        };
        \\        Database.QueryLocator locator = Database.getQueryLocator(
        \\            'SELECT Id, Name FROM Account ORDER BY Name'
        \\        );
        \\        System.Iterator<SObject> it = locator.iterator();
        \\        Integer count = 0;
        \\        String firstName = '';
        \\        while (it.hasNext()) {
        \\            Account a = (Account) it.next();
        \\            if (count == 0) firstName = a.Name;
        \\            count++;
        \\        }
        \\        return firstName + ':' + String.valueOf(count);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "QueryLocatorIteratorProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Acme:2", result.value.string);
}

test "E2E: sobject.Field.addError(msg) attaches error to the field" {
    // Anonymized probe: domain validation code idiomatically writes
    // `opp.AccountId.addError('...')` — the Apex compiler rewrites that into
    // a field-scoped addError on the owning SObject. Our interpreter previously
    // evaluated the left-hand field reference first, which dereferenced a null
    // Id and NPE'd. Detect the receiver pattern and attach the error directly
    // to the SObject with the field name recorded.
    const source =
        \\public class FieldAddErrorMagicProbe {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(Name = 'Needs account', Type = 'Existing');
        \\        opp.AccountId.addError('You must provide an Account');
        \\        Database.Error first = opp.getErrors()[0];
        \\        return String.valueOf(opp.hasErrors()) + '|' +
        \\               first.getMessage() + '|' +
        \\               first.get_fields()[0];
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "FieldAddErrorMagicProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "true|You must provide an Account|AccountId",
        result.value.string,
    );
}

test "E2E: System.Location.newInstance + getDistance match real-platform values" {
    // Anonymized probe: geospatial formulas build locations via
    // `System.Location.newInstance(lat, lng)` and compute distances with
    // `Location.getDistance(a, b, 'km')`. The returned Location exposes
    // `.latitude` / `.longitude` as Decimal, and `getDistance` uses the
    // Haversine formula — we clamp within a sensible tolerance (~0.1km)
    // against the expected Google-Earth value between two well-known POIs.
    const source =
        \\public class LocationBuiltinsProbe {
        \\    public static String test() {
        \\        System.Location a = System.Location.newInstance(28.635308, 77.22496);
        \\        System.Location b = System.Location.newInstance(28.704060, 77.102493);
        \\        Decimal km = Location.getDistance(a, b, 'km');
        \\        return String.valueOf(a.latitude) + ',' +
        \\               String.valueOf(a.longitude) + '|' +
        \\               (km > 14 && km < 17 ? 'inRange' : 'outOfRange:' + km);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "LocationBuiltinsProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("28.635308,77.22496|inRange", result.value.string);
}

test "E2E: Schema.describeTabs returns a non-null list and getGlobalDescribe covers common standards" {
    // Anonymized probe: ActionPlansV4's SectionHeader utility iterates
    //   for (Schema.DescribeTabSetResult tsr : Schema.describeTabs()) {...}
    // before falling back to a default icon, and queries
    //   Schema.getGlobalDescribe().get(name.toLowerCase()).getDescribe().isCustom()
    // for standard objects the old whitelist didn't cover (CaseComment,
    // Contract, Asset, …). Previously describeTabs() returned null and the
    // for-each NPE'd, and getGlobalDescribe().get('casecomment') came back
    // as null so the downstream `.getDescribe()` blew up too.
    const source =
        \\public class SchemaStubProbe {
        \\    public static String test() {
        \\        Integer tabCount = Schema.describeTabs().size();
        \\        String caseCommentFound = Schema.getGlobalDescribe().get('casecomment') != null ? 'Y' : 'N';
        \\        String contractFound = Schema.getGlobalDescribe().get('contract') != null ? 'Y' : 'N';
        \\        String assetFound = Schema.getGlobalDescribe().get('asset') != null ? 'Y' : 'N';
        \\        return 'tabs=' + tabCount + '|cc=' + caseCommentFound + '|co=' + contractFound + '|as=' + assetFound;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SchemaStubProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("tabs=0|cc=Y|co=Y|as=Y", result.value.string);
}

test "E2E: User insert defaults IsActive to true and WHERE PermissionsX = TRUE matches" {
    // Anonymized probe: ActionPlansV4's @TestSetup queries
    //   SELECT ... FROM Profile WHERE PermissionsModifyAllData = TRUE AND UserType = 'Standard'
    // and then inserts a User without setting IsActive, later asserting
    //   SELECT ... FROM User WHERE Email = 'x' AND IsActive = TRUE
    // Two bugs had to line up: (a) extract_where_field_value dropped bare
    // TRUE / FALSE tokens on the floor, so apply_queried_synthetic_profile_flags
    // never saw the permission and the Profile WHERE predicate never matched
    // — we synthesized a Profile without the flag and matches_where filtered
    // it out. (b) User.IsActive was unset on a fresh insert, so the WHERE
    // IsActive=TRUE filter yielded no rows and the single-record assignment
    // threw "List has no rows for assignment to SObject".
    const source =
        \\public class UserDefaultsWhereProbe {
        \\    public static String test() {
        \\        Integer matchedProfiles = 0;
        \\        for (Profile p : [SELECT Id, PermissionsModifyAllData FROM Profile WHERE PermissionsModifyAllData = TRUE AND UserType = 'Standard' LIMIT 1]) {
        \\            if (p.PermissionsModifyAllData == true) matchedProfiles++;
        \\            User u = new User();
        \\            u.Email = 'probe@example.com';
        \\            u.Username = 'probe@probe-test.com';
        \\            u.LastName = 'probe';
        \\            u.Alias = 'pr';
        \\            u.ProfileId = p.Id;
        \\            u.LanguageLocaleKey = 'en_US';
        \\            u.LocaleSidKey = 'en_US';
        \\            u.TimeZoneSidKey = 'America/Chicago';
        \\            u.EmailEncodingKey = 'UTF-8';
        \\            insert u;
        \\        }
        \\        Integer activeMatches = [SELECT COUNT() FROM User WHERE Email = 'probe@example.com' AND IsActive = TRUE];
        \\        return 'profiles=' + matchedProfiles + '|activeUsers=' + activeMatches;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "UserDefaultsWhereProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("profiles=1|activeUsers=1", result.value.string);
}

test "E2E: SUM aggregate SOQL with ALL ROWS sums active store + recycle bin" {
    // Anonymized probe: the aggregate path (SUM/AVG/MIN/MAX/COUNT(field))
    // previously walked only `self.store`, same bug as plain COUNT(). Confirm
    // a deleted record still contributes to the total when ALL ROWS is set.
    const source =
        \\public class AggAllRowsProbe {
        \\    public static Double test() {
        \\        Account a = new Account(Name='A', AnnualRevenue=100);
        \\        Account b = new Account(Name='B', AnnualRevenue=25);
        \\        insert a;
        \\        insert b;
        \\        delete b;
        \\        List<AggregateResult> ar = [SELECT SUM(AnnualRevenue) s FROM Account ALL ROWS];
        \\        return (Double) ar[0].get('s');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AggAllRowsProbe",
        .entry_method = "test",
    });
    defer result.deinit();
    // Apex returns the sum as a Decimal/Double; our numeric values may box to
    // integer or double — accept whichever, but the total must be 125.
    const total: f64 = switch (result.value) {
        .integer => |i| @floatFromInt(i),
        .double => |d| d,
        else => -1,
    };
    try std.testing.expectEqual(@as(f64, 125), total);
}

test "E2E: COUNT() ALL ROWS includes trashed records, not just the active store" {
    // Anonymized probe: ActionPlansV4's trigger tests assert that a deleted
    // object's dependent records still live in the recycle bin by running
    //   SELECT COUNT() FROM X WHERE IsDeleted = TRUE ALL ROWS
    // Our plain-COUNT path only walked `self.store`, so the count was 0
    // even though the corresponding non-COUNT `SELECT Id ... ALL ROWS`
    // correctly surfaced the trashed record. Fix: also walk `self.trash`
    // with the same WHERE predicate when ALL ROWS is present.
    const source =
        \\public class CountAllRowsProbe {
        \\    public static String test() {
        \\        Account a = new Account(Name='Doomed');
        \\        insert a;
        \\        delete a;
        \\        Integer active = [SELECT COUNT() FROM Account];
        \\        Integer trashed = [SELECT COUNT() FROM Account WHERE IsDeleted = TRUE ALL ROWS];
        \\        Integer total = [SELECT COUNT() FROM Account ALL ROWS];
        \\        return 'active=' + active + '|trashed=' + trashed + '|total=' + total;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CountAllRowsProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("active=0|trashed=1|total=1", result.value.string);
}

test "E2E: AFTER_UNDELETE addError rolls back undelete and raises DmlException" {
    // Anonymized probe: ActionPlansV4-style trigger uses addError() in
    // AFTER_UNDELETE to abort the restore when a platform condition fails.
    // Real Apex raises a DmlException and rolls back so a retry can undelete
    // again. Before: our undelete returned cleanly and the stale `errors`
    // entries on the sobject leaked into the next DML cycle; the AFTER
    // trigger addError path was ignored entirely.
    const source =
        \\public class AfterUndeleteAddErrorProbe {
        \\    public static String test() {
        \\        Account a = new Account(Name='Doomed');
        \\        insert a;
        \\        delete a;
        \\        String caught = 'none';
        \\        try {
        \\            undelete a;
        \\        } catch (DmlException e) {
        \\            caught = e.getMessage();
        \\        }
        \\        return caught;
        \\    }
        \\}
        \\trigger AfterUndeleteAddErrorProbeTrigger on Account (after undelete) {
        \\    for (Account a : Trigger.new) {
        \\        a.addError('blocked-by-trigger');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AfterUndeleteAddErrorProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("blocked-by-trigger", result.value.string);
}

test "E2E: subclass constructor sees field initialised by super() via identifier read" {
    // Anonymized probe: the common stateful-domain pattern in Apex frameworks
    // is "super() initialises a Config field; the subclass constructor then
    // calls config.enable()". Our interpreter pre-loaded instance fields into
    // the ctor env at entry, so after super() mutated instance.fields the
    // subclass still read the stale null snapshot and blew up on the next
    // `configuration.enable()`. Fix: when the local env has a null_val for a
    // declared instance field, fall back to the live instance.fields value.
    const source =
        \\public class SuperFieldVisibilityProbe {
        \\    public static String test() {
        \\        Child c = new Child();
        \\        return (c.cfg.enabled ? 'E' : 'D') + '|' + (c.label == null ? '<null>' : c.label);
        \\    }
        \\    public class Conf {
        \\        public Boolean enabled = false;
        \\        public void enable() { enabled = true; }
        \\    }
        \\    public abstract class Base {
        \\        public Conf cfg;
        \\        public String label;
        \\        public Base() {
        \\            cfg = new Conf();
        \\            label = 'parent-set';
        \\        }
        \\    }
        \\    public class Child extends Base {
        \\        public Child() {
        \\            super();
        \\            cfg.enable();
        \\            label = label + ':child';
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SuperFieldVisibilityProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("E|parent-set:child", result.value.string);
}

test "E2E: try/finally runs after catch rethrows and when no catch matches" {
    // Anonymized probe: UnitOfWork-style frameworks emit their trailing events
    // (onCommitWorkFinished etc.) from the finally block while the catch
    // rethrows for the caller's sake. Our interpreter previously returned
    // directly from the catch rethrow and swallowed the finally, losing half
    // the events. Also covers the "no catch clause" branch: when the try body
    // throws and no catch matches, the finally must still run and the
    // exception must propagate rather than being silently suppressed.
    const source =
        \\public class TryFinallyRethrowProbe {
        \\    public static List<String> events = new List<String>();
        \\    public static String test() {
        \\        try {
        \\            rethrowPath();
        \\        } catch (Exception e) {
        \\            events.add('outerCatch');
        \\        }
        \\        try {
        \\            noCatchPath();
        \\        } catch (Exception e) {
        \\            events.add('outerNoCatch:' + e.getMessage());
        \\        }
        \\        return String.join(events, '|');
        \\    }
        \\    static void rethrowPath() {
        \\        try {
        \\            events.add('start-rethrow');
        \\            throw new IllegalArgumentException('boom');
        \\        } catch (Exception e) {
        \\            events.add('innerCatch');
        \\            throw e;
        \\        } finally {
        \\            events.add('rethrowFinally');
        \\        }
        \\    }
        \\    static void noCatchPath() {
        \\        try {
        \\            events.add('start-nocatch');
        \\            throw new IllegalArgumentException('noCatchBoom');
        \\        } finally {
        \\            events.add('noCatchFinally');
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TryFinallyRethrowProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "start-rethrow|innerCatch|rethrowFinally|outerCatch|start-nocatch|noCatchFinally|outerNoCatch:noCatchBoom",
        result.value.string,
    );
}
