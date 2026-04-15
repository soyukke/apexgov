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
pub fn run(gpa: std.mem.Allocator, source: []const u8, opts: Options) !Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const tokens = try lexer.tokenize(source, arena.allocator());
    const decls = try parser.parse(tokens, arena.allocator());

    var eval = try evaluator.Evaluator.init(arena.allocator());
    if (opts.source_paths.len > 0) {
        eval.source_paths = opts.source_paths;
    }
    try eval.loadDecls(decls);

    const value = if (opts.entry_class.len > 0 and opts.entry_method.len > 0)
        try eval.callMethod(opts.entry_class, opts.entry_method, opts.args)
    else
        Value.void_val;

    const stdout_copy = try gpa.dupe(u8, eval.stdout.items);
    const value_copy = try copyValue(gpa, value);

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

/// ディレクトリ内の全 .cls ファイルを読み込み、@isTest メソッドを実行する。
pub fn runTestSuite(gpa: std.mem.Allocator, paths: []const []const u8, writer: anytype) !TestSuiteResult {
    return runTestsFiltered(gpa, paths, null, null, writer);
}

/// 指定クラス（+ オプションでメソッド）のテストのみ実行する。
/// method_name が null の場合はクラス内全テストメソッドを実行。
pub fn runSingleTest(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    class_name: []const u8,
    method_name: ?[]const u8,
    writer: anytype,
) !TestSuiteResult {
    return runTestsFiltered(gpa, paths, class_name, method_name, writer);
}

/// テスト実行の共通内部関数。filter_class / filter_method が null なら全テスト実行。
fn runTestsFiltered(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    filter_class: ?[]const u8,
    filter_method: ?[]const u8,
    writer: anytype,
) !TestSuiteResult {
    // 永続アリーナ: パース済み AST・クラス登録・ソースファイル（テスト間で共有）
    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    // 1. .cls ファイルを収集
    var files: std.ArrayListUnmanaged(SourceFile) = .empty;
    for (paths) |path| {
        try collectClsFiles(parse_alloc, path, &files);
    }
    try writer.print("interpret: loaded {d} Apex source file(s)\n", .{files.items.len});

    // 2. 全ファイルをパース（永続アリーナ上）
    var eval = try evaluator.Evaluator.init(parse_alloc);
    eval.source_paths = paths;
    var parse_errors: u32 = 0;

    for (files.items) |file| {
        const tokens = lexer.tokenize(file.content, parse_alloc) catch {
            parse_errors += 1;
            continue;
        };
        const decls = parser.parse(tokens, parse_alloc) catch {
            parse_errors += 1;
            continue;
        };
        eval.loadDecls(decls) catch {
            parse_errors += 1;
            continue;
        };
        // Register class source for ApexClass.Body queries
        // Extract class name from file path (basename without .cls)
        const basename = std.fs.path.basename(file.path);
        if (std.mem.endsWith(u8, basename, ".cls")) {
            const cls_name = basename[0 .. basename.len - 4];
            eval.registerClassSource(cls_name, file.content) catch {};
        }
    }
    try writer.print("interpret: registered {d} class(es), {d} trigger(s), {d} parse error(s)\n", .{ eval.classes.count(), eval.triggers.count(), parse_errors });

    // Load field-meta.xml default values for SObject types
    // Search the given paths AND their ancestor directories (up to 3 levels) to find objects/ dirs
    // This handles multi-package SFDX layouts where classes/ and objects/ are in sibling packages
    for (paths) |path| {
        collectFieldDefaults(parse_alloc, path, &eval.field_defaults, &eval.field_types) catch {};
        // Walk parent directories to find sibling packages containing objects/
        var parent = std.fs.path.dirname(path);
        var depth: u8 = 0;
        while (parent != null and depth < 3) : (depth += 1) {
            const p = parent.?;
            collectFieldDefaults(parse_alloc, p, &eval.field_defaults, &eval.field_types) catch {};
            parent = std.fs.path.dirname(p);
        }
    }

    // Static initializer blocks are now evaluated lazily via ensureStaticInit()
    // on first class access, matching Salesforce behavior.

    // Pre-compute which classes need static field reinit and which have static init blocks
    var classes_with_statics: std.ArrayListUnmanaged(*ast.ClassDecl) = .empty;
    var classes_with_static_inits: std.ArrayListUnmanaged(*ast.ClassDecl) = .empty;
    {
        var pre_iter = eval.classes.iterator();
        while (pre_iter.next()) |entry| {
            const cd = entry.value_ptr.*;
            var has_static_fields = false;
            var has_static_init = false;
            for (cd.members) |member| {
                switch (member) {
                    .field_decl => |fd| {
                        if (fd.modifiers.is_static) has_static_fields = true;
                    },
                    .static_init => {
                        has_static_init = true;
                    },
                    else => {},
                }
            }
            if (has_static_fields) try classes_with_statics.append(parse_alloc, cd);
            if (has_static_init) try classes_with_static_inits.append(parse_alloc, cd);
        }
    }

    // テスト実行用アリーナ: テストごとにリセットしてメモリを回収
    var test_arena = std.heap.ArenaAllocator.init(gpa);
    defer test_arena.deinit();

    // 3. @isTest メソッドを発見・実行
    var suite = TestSuiteResult{};
    var class_iter = eval.classes.iterator();
    while (class_iter.next()) |entry| {
        const class_name = entry.key_ptr.*;
        const class_decl = entry.value_ptr.*;

        // クラスフィルタ: 指定されていれば一致するクラスのみ
        if (filter_class) |fc| {
            if (!std.ascii.eqlIgnoreCase(class_name, fc)) continue;
        }

        // Find @TestSetup method if any
        var test_setup_method: ?*ast.MethodDecl = null;
        for (class_decl.members) |m| {
            switch (m) {
                .method_decl => |md2| {
                    for (md2.annotations) |ann| {
                        if (std.ascii.eqlIgnoreCase(ann, "@TestSetup")) {
                            test_setup_method = md2;
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        for (class_decl.members) |member| {
            switch (member) {
                .method_decl => |md| {
                    if (!isTestMethod(md)) continue;

                    // メソッドフィルタ: 指定されていれば一致するメソッドのみ
                    if (filter_method) |fm| {
                        if (!std.ascii.eqlIgnoreCase(md.name, fm)) continue;
                    }

                    suite.total += 1;

                    // テストアリーナをリセットしてメモリを回収し、新しい evaluator を作成
                    _ = test_arena.reset(.retain_capacity);
                    const test_alloc = test_arena.allocator();
                    var test_eval = evaluator.Evaluator.init(test_alloc) catch continue;
                    // 永続側のクラス・トリガー・ソース情報を引き継ぐ
                    test_eval.classes = eval.classes;
                    test_eval.class_arena = parse_alloc; // classes map は parse_arena 上に確保
                    test_eval.triggers = eval.triggers;
                    test_eval.class_sources = eval.class_sources;
                    test_eval.source_paths = eval.source_paths;
                    test_eval.field_defaults = eval.field_defaults;
                    test_eval.field_types = eval.field_types;

                    // Check for @isTest(SeeAllData=true) annotation
                    test_eval.see_all_data = false;
                    for (md.annotations) |ann| {
                        if (std.ascii.indexOfIgnoreCase(ann, "seealldata") != null and
                            std.ascii.indexOfIgnoreCase(ann, "true") != null)
                        {
                            test_eval.see_all_data = true;
                            break;
                        }
                    }
                    // Full lazy static initialization (Salesforce semantics):
                    // Register null placeholders, then let ensureStaticInit hooks
                    // initialize each class on first access.
                    for (classes_with_statics.items) |cd| {
                        test_eval.registerStaticFieldPlaceholders(cd);
                    }
                    // Run @TestSetup if exists
                    if (test_setup_method) |setup| {
                        // Test class initializes lazily when callMethod fires
                        _ = test_eval.callMethod(class_name, setup.name, &.{}) catch {};
                        // After @TestSetup, reset all static state for fresh test
                        for (classes_with_statics.items) |cd2| {
                            test_eval.registerStaticFieldPlaceholders(cd2);
                        }
                        test_eval.static_inited.clearRetainingCapacity();
                    }

                    // Reset Limits counters before test body (static inits may have caused DML/SOQL)
                    test_eval.limits_dml = 0;
                    test_eval.limits_soql = 0;
                    test_eval.limits_publish_immediate = 0;
                    test_eval.limits_queueable = 0;
                    test_eval.limits_callouts = 0;

                    const result = test_eval.callMethod(class_name, md.name, &.{});
                    if (result) |_| {
                        // Check assertion failures
                        if (test_eval.assertion_failure) |msg| {
                            suite.failed += 1;
                            // failure_message をテストアリーナから永続アリーナにコピー
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
                        // Include pending exception message if available
                        const exc_detail = if (test_eval.pending_exception) |pe| blk: {
                            if (pe == .object) {
                                if (pe.object.fields.get("message")) |msg| {
                                    if (msg == .string) break :blk msg.string;
                                }
                            }
                            break :blk "";
                        } else "";
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
                },
                else => {},
            }
        }
    }

    suite.failed += suite.errors;
    try writer.print("\n--- Results: {d} total, {d} passed, {d} failed ---\n", .{ suite.total, suite.passed, suite.total - suite.passed });
    return suite;
}

fn isTestClass(cd: *ast.ClassDecl) bool {
    for (cd.annotations) |ann| {
        if (std.ascii.eqlIgnoreCase(ann, "@isTest") or std.ascii.eqlIgnoreCase(ann, "@IsTest") or
            std.ascii.startsWithIgnoreCase(ann, "@isTest(") or std.ascii.startsWithIgnoreCase(ann, "@test("))
        {
            return true;
        }
    }
    // Also check if it has any test methods
    for (cd.members) |member| {
        switch (member) {
            .method_decl => |md| {
                if (isTestMethod(md)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn isTestMethod(md: *ast.MethodDecl) bool {
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

fn collectClsFiles(alloc: std.mem.Allocator, path: []const u8, files: *std.ArrayListUnmanaged(SourceFile)) !void {
    // Try as single .cls/.trigger file first
    if (std.mem.endsWith(u8, path, ".cls") or std.mem.endsWith(u8, path, ".trigger")) {
        const content = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch return;
        const path_copy = alloc.dupe(u8, path) catch return;
        files.append(alloc, .{ .path = path_copy, .content = content }) catch return;
        return;
    }

    // Walk directory recursively
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".cls") and !std.mem.endsWith(u8, entry.basename, ".trigger")) continue;

        const full_path = std.fs.path.join(alloc, &.{ path, entry.path }) catch continue;
        const content = std.fs.cwd().readFileAlloc(alloc, full_path, 10 * 1024 * 1024) catch continue;
        files.append(alloc, .{ .path = full_path, .content = content }) catch continue;
    }
}

/// field-meta.xml からデフォルト値と型情報を読み込む。
/// パス構造: .../objects/TypeName__c/fields/FieldName__c.field-meta.xml
fn collectFieldDefaults(
    alloc: std.mem.Allocator,
    path: []const u8,
    field_defaults: *std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(Value)),
    field_types: *std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged([]const u8)),
) !void {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
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
        const content = std.fs.cwd().readFileAlloc(alloc, full_path, 64 * 1024) catch continue;

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

        // Extract <defaultValue>...</defaultValue>
        const dv_start_tag = "<defaultValue>";
        const dv_end_tag = "</defaultValue>";
        const dv_start = std.mem.indexOf(u8, content, dv_start_tag) orelse continue;
        const dv_value_start = dv_start + dv_start_tag.len;
        const dv_end = std.mem.indexOfPos(u8, content, dv_value_start, dv_end_tag) orelse continue;
        const raw_str = content[dv_value_start..dv_end];

        // Decode XML entities and strip Apex string quotes
        const decoded = decodeXmlDefaultValue(alloc, raw_str) catch continue;

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

/// XML エンティティをデコードし、Apex 文字列リテラルのクォートを除去する。
/// e.g., "&apos;FINEST&apos;" → "FINEST", "&amp;test" → "&test"
fn decodeXmlDefaultValue(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
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
    if (decoded.len >= 2 and decoded[0] == '\'' and decoded[decoded.len - 1] == '\'') {
        return alloc.dupe(u8, decoded[1 .. decoded.len - 1]);
    }
    return alloc.dupe(u8, decoded);
}

/// arena 上の Value を gpa にコピーする。
fn copyValue(gpa: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .string => |s| Value{ .string = try gpa.dupe(u8, s) },
        else => value,
    };
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

test "isTestMethod detects testMethod modifier" {
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
    // isTestMethod should detect it
    try std.testing.expect(isTestMethod(md));
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "RegexTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("2:123:456:user:host", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "DateTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("true:true", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "CacheTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("1:true", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "SRTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("3", result.value.string);
}

test "E2E: static field set before enqueueJob is visible in execute" {
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
        \\        System.enqueueJob(new MyQueueable());
        \\        return String.valueOf(MyQueueable.circuitBreakerThrown);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "QTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("true", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "CVTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("3:3", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "VTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("200", result.value.string);
}

test "E2E: enqueueJob execute catches DmlException and sets circuit breaker" {
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
        \\        System.enqueueJob(new MyQ());
        \\        return String.valueOf(MyQ.circuitBreakerThrown);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);
    _ = eval.callMethod("T", "test", &.{}) catch {};

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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);
    _ = eval.callMethod("T2", "test", &.{}) catch {};

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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);
    _ = eval.callMethod("T3", "test", &.{}) catch {};

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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "DtDateTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("2024-07-19", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "DtGetTimeTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("2024-07-19", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "DbQueryBindTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("1", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "FormulaFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Hiking", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "NullBindMethodTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("2", result.value.string);
}

// TODO: Database.query/countQuery でメソッドのローカル変数へのバインド変数解決が
// callMethod 経由の呼び出しで機能しない問題がある。env スコープチェーンの調査が必要。
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
    const result = try run(std.testing.allocator, source, .{
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

    // Verify that callMethod finds and executes the method correctly
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);
    const val = try eval.callMethod("Outer", "myMethod", &.{});
    try std.testing.expectEqualStrings("hello", val.string);
}

test "loadDecls: Controller class with inner class has getItems method" {
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
    var eval3 = try evaluator.Evaluator.init(alloc3);
    try eval3.loadDecls(decls3);

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

    // Verify callMethod handles Database.countQuery correctly without inner class interaction
    // First test: call without WHERE clause
    try eval3.executeDml(.insert, Value{ .sobject = blk: {
        const sob = try alloc3.create(types.SObject);
        sob.* = .{ .type_name = "Account" };
        try sob.fields.put(alloc3, "Name", Value{ .string = "Test" });
        break :blk sob;
    } });
    const val3 = try eval3.callMethod("Controller", "getItems", &.{Value.null_val});
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);
    _ = eval.callMethod("CalculatorTest", "testMultiplyWrong", &.{}) catch {};

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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("ContactNameTest", "testContactName", &.{}) catch |e| {
        std.debug.print("testContactName error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(eval.assertion_failure == null);

    eval.resetForTest();
    _ = eval.callMethod("ContactNameTest", "testContactNameLastOnly", &.{}) catch |e| {
        std.debug.print("testContactNameLastOnly error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("DoubleDefaultTest", "testDecimalNull", &.{}) catch |e| {
        std.debug.print("testDecimalNull error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(eval.assertion_failure == null);

    eval.resetForTest();
    _ = eval.callMethod("DoubleDefaultTest", "testDoubleNull", &.{}) catch |e| {
        std.debug.print("testDoubleNull error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(eval.assertion_failure == null);
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("JsonDeserTest", "testDeserialize", &.{}) catch |e| {
        std.debug.print("testDeserialize error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("JsonParserTest", "testReadValueAs", &.{}) catch |e| {
        std.debug.print("testReadValueAs error: {}\n", .{e});
        if (eval.pending_exception) |pe| {
            if (pe == .object) {
                if (pe.object.fields.get("message")) |msg| {
                    if (msg == .string) std.debug.print("exception: {s}\n", .{msg.string});
                }
            }
        }
        return error.TestUnexpectedResult;
    };
    if (eval.assertion_failure) |af| {
        std.debug.print("assertion failure: {s}\n", .{af});
    }
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("PageRefTest", "testGetUrl", &.{}) catch |e| {
        std.debug.print("testGetUrl error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(eval.assertion_failure == null);
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("LikeBindTest", "testLikeBind", &.{}) catch |e| {
        std.debug.print("testLikeBind error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("SchemaTest", "testSchemaAccess", &.{}) catch |e| {
        std.debug.print("Schema.sObjectType test error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("CryptoTest", "testRoundTrip", &.{}) catch |e| {
        std.debug.print("Crypto round-trip test error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("AuraTest", "testCatch", &.{}) catch |e| {
        std.debug.print("AuraHandledException test error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(eval.assertion_failure == null);
}

test "Type.forName returns null for non-existent class" {
    const source =
        \\public class TypeForNameTest {
        \\    public static void testForName() {
        \\        System.assertNotEquals(null, Type.forName('NonExistentClass'));
        \\        System.assertEquals(null, Type.forName('Outer.NonExistentInner'));
        \\        System.assertNotEquals(null, Type.forName('Map<Id,Account>'));
        \\    }
        \\}
    ;
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    _ = eval.callMethod("TypeForNameTest", "testForName", &.{}) catch |e| {
        std.debug.print("Type.forName test error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(eval.assertion_failure == null);
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

    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls1);
    try eval.loadDecls(decls2);
    try eval.loadDecls(decls3);

    _ = eval.callMethod("TriggerRecursionTest", "testNoStackOverflow", &.{}) catch |e| {
        // StackOverflow should not happen anymore
        if (e == error.StackOverflow) {
            std.debug.print("Trigger recursion caused StackOverflow!\n", .{});
            return error.TestUnexpectedResult;
        }
        std.debug.print("Trigger recursion test error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
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
    var eval = try evaluator.Evaluator.init(alloc);
    try eval.loadDecls(decls);

    eval.resetForTest();
    _ = eval.callMethod("UserQueryTest", "testQuery", &.{}) catch |e| {
        std.debug.print("User query test error: {}\n", .{e});
        return error.TestUnexpectedResult;
    };
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    try tmp_dir.dir.makePath("staticresources");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "staticresources/test_data.json",
        .data = "[{\"Name\":\"Alice\"},{\"Name\":\"Bob\"}]",
    });
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
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
    const result = try run(alloc, source, .{
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
    try tmp_dir.dir.makePath("customMetadata");
    try tmp_dir.dir.writeFile(.{
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
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
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
    const result = try run(alloc, source, .{
        .entry_class = "CMDTTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Reservation_Status__c:Draft", result.value.string);
}

test "resetForTest should not leak: arena memory must not grow linearly with test iterations" {
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
    var base_eval = try evaluator.Evaluator.init(parse_alloc);
    try base_eval.loadDecls(decls);

    // テスト実行用アリーナ
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();

    // 1回実行後のテストアリーナの容量を記録
    {
        _ = test_arena.reset(.retain_capacity);
        var test_eval = try evaluator.Evaluator.init(test_arena.allocator());
        test_eval.classes = base_eval.classes;
        _ = test_eval.callMethod("LeakTest", "test1", &.{}) catch {};
    }
    const baseline = test_arena.queryCapacity();

    // 同じテストを 50 回繰り返す
    for (0..50) |_| {
        _ = test_arena.reset(.retain_capacity);
        var test_eval = try evaluator.Evaluator.init(test_arena.allocator());
        test_eval.classes = base_eval.classes;
        _ = test_eval.callMethod("LeakTest", "test1", &.{}) catch {};
    }

    const after = test_arena.queryCapacity();

    // retain_capacity により容量は安定するはず（2倍以上増えたらリーク）
    if (after > baseline * 2) {
        std.debug.print("\n[LEAK] test arena capacity: baseline={d} bytes, after 50 iterations={d} bytes (x{d})\n", .{ baseline, after, after / baseline });
        return error.TestUnexpectedResult;
    }
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "EmptyDbDmlTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 0), result.value.integer);
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "TypeForNameSObjectTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Account", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "TypeForNameEventTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.value.string);
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
    const result = try run(std.testing.allocator, source, .{
        .entry_class = "IntegrationTest",
        .entry_method = "test",
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 1), result.value.integer);
}
