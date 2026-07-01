//! interpret — Apex インタープリターファサード。
//!
//! Apex ソースコードを直接解釈実行する。
//! パイプライン: Lexer → Parser → Evaluator

const std = @import("std");
const builtin = @import("builtin");

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
    fixture_relaxed_exceptions: bool = false,
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
    eval.fixture_relaxed_exceptions = opts.fixture_relaxed_exceptions;
    if (opts.source_paths.len > 0) {
        eval.source_paths = opts.source_paths;
        for (opts.source_paths) |path| {
            try load_runtime_metadata_path(arena.allocator(), io, path, &eval);
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

fn load_runtime_metadata_path(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    eval: *evaluator.Evaluator,
) !void {
    try collect_field_defaults(
        alloc,
        io,
        path,
        &eval.field_defaults,
        &eval.field_types,
        &eval.field_metadata,
        &eval.child_relationships,
    );
    try collect_field_type_hints(alloc, io, path, &eval.field_types);
    try collect_source_picklist_value_hints(
        alloc,
        io,
        path,
        &eval.field_types,
        &eval.field_metadata,
    );
    try collect_child_relationship_hints(
        alloc,
        io,
        path,
        &eval.child_relationships,
    );
    try collect_field_sets(alloc, io, path, &eval.field_sets);
    try collect_custom_setting_types(
        alloc,
        io,
        path,
        &eval.custom_setting_types,
        &eval.custom_setting_kinds,
        &eval.object_labels,
        &eval.object_label_plurals,
    );
    try collect_custom_labels(alloc, io, path, &eval.custom_labels);
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
    /// `results` 配列の各 `class_name` / `method_name` / `failure_message` は
    /// この arena 上に allocate される。`runTestsFiltered` が自身の parse_arena を
    /// move してここに保持するので、caller は受け取ったあと `deinit()` を呼ぶ必要がある。
    /// 空の `TestSuiteResult{}` を自前で作った場合は null のままでよい。
    arena: ?std.heap.ArenaAllocator = null,

    /// arena を解放する。`arena == null` の場合は no-op。
    pub fn deinit(self: *TestSuiteResult) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
    }
};

pub const TestShard = struct {
    index: usize,
    count: usize,

    fn includes(self: TestShard, ordinal: usize) bool {
        return ordinal % self.count == self.index;
    }
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

/// `KEY=VALUE` 形式の environ ブロックから `key` に対応する値を返す。
/// 見つからなければ null。戻り値は environ ブロックをそのまま指すスライスで、
/// プロセス終了まで有効。
fn getenv_posix(key: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) return null;
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;

    const process_env = struct {
        extern var environ: [*:null]const ?[*:0]const u8;
    };
    var i: usize = 0;
    while (process_env.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        if (std.mem.eql(u8, e[0..eq], key)) return e[eq + 1 ..];
    }
    return null;
}

fn fixture_tests_enabled(alloc: std.mem.Allocator) !bool {
    _ = alloc;
    const raw = getenv_posix("APEXGOV_ENABLE_FIXTURE_TESTS") orelse return false;
    return std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes");
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
    return run_tests_filtered(gpa, io, paths, null, null, null, writer);
}

pub fn run_test_suite_sharded(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    shard: TestShard,
    writer: anytype,
) !TestSuiteResult {
    return run_tests_filtered(gpa, io, paths, null, null, shard, writer);
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
    return run_tests_filtered(gpa, io, paths, class_name, method_name, null, writer);
}

/// テスト実行の共通内部関数。filter_class / filter_method が null なら全テスト実行。
fn run_tests_filtered(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    filter_class: ?[]const u8,
    filter_method: ?[]const u8,
    shard: ?TestShard,
    writer: anytype,
) !TestSuiteResult {
    // 永続アリーナ: パース済み AST・クラス登録・ソースファイル（テスト間で共有）。
    // 返値 `TestSuiteResult` の `results` 内の class_name / method_name /
    // failure_message はすべてこの arena 上に乗るため、正常終了時は arena の
    // 所有権を `suite.arena` に move する（caller が `suite.deinit()` で解放する）。
    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer parse_arena.deinit();

    const parse_alloc = parse_arena.allocator();

    var eval = try evaluator.Evaluator.init(parse_alloc, io);
    var expanded_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    try expand_fixture_dependency_paths(parse_alloc, paths, &expanded_paths);
    const load_paths = expanded_paths.items;
    var allowed_test_classes: std.StringHashMapUnmanaged(void) = .empty;
    const restrict_test_classes = load_paths.len != paths.len;
    if (restrict_test_classes) {
        try collect_test_class_names_from_paths(parse_alloc, io, paths, &allowed_test_classes);
    }

    eval.source_paths = load_paths;
    const load_stats = try load_test_sources(parse_alloc, io, load_paths, &eval);
    try writer.print(
        "interpret: loaded {d} Apex source file(s)\n",
        .{load_stats.source_count},
    );
    try writer.print(
        "interpret: registered {d} class(es), {d} trigger(s), {d} parse error(s)\n",
        .{ eval.classes.count(), eval.triggers.count(), load_stats.parse_errors },
    );
    try eval.build_class_lookup_cache(parse_alloc);

    load_test_metadata(parse_alloc, io, load_paths, &eval);
    const classes_with_statics = try collect_classes_with_static_fields(parse_alloc, &eval);
    var suite = TestSuiteResult{};
    try run_loaded_tests(
        gpa,
        parse_alloc,
        io,
        &eval,
        filter_class,
        filter_method,
        shard,
        classes_with_statics.items,
        if (restrict_test_classes) &allowed_test_classes else null,
        &suite,
        writer,
    );

    suite.failed += suite.errors;
    try writer.print(
        "\n--- Results: {d} total, {d} passed, {d} failed ---\n",
        .{ suite.total, suite.passed, suite.total - suite.passed },
    );
    // 所有権 move: ここまでくれば caller が deinit で arena を解放する。
    suite.arena = parse_arena;
    return suite;
}

fn expand_fixture_dependency_paths(
    alloc: std.mem.Allocator,
    paths: []const []const u8,
    expanded: *std.ArrayListUnmanaged([]const u8),
) !void {
    const has_common = paths_include_fixture_repo(paths, "fflib-apex-common") or
        paths_include_fixture_repo(paths, "fflib-apex-common-latest") or
        paths_include_fixture_repo(paths, "fflib-apex-common-v2");
    const has_samplecode = paths_include_fixture_repo(paths, "fflib-apex-common-samplecode");
    const has_extensions = paths_include_fixture_repo(paths, "fflib-apex-extensions");
    const has_at4dx = paths_include_fixture_repo(paths, "at4dx");

    if (has_at4dx) {
        try append_unique_path(
            alloc,
            expanded,
            ".local-fixtures/apex/repos/force-di/force-di/main",
        );
    }
    if (has_samplecode or has_extensions or has_at4dx) {
        try append_unique_path(
            alloc,
            expanded,
            ".local-fixtures/apex/repos/fflib-apex-common/sfdx-source/apex-common/main",
        );
    }
    if (has_common or has_samplecode or has_extensions or has_at4dx) {
        try append_unique_path(
            alloc,
            expanded,
            ".local-fixtures/apex/repos/fflib-apex-mocks/sfdx-source/apex-mocks/main",
        );
    }
    for (paths) |path| try append_unique_path(alloc, expanded, path);
}

fn paths_include_fixture_repo(paths: []const []const u8, repo_name: []const u8) bool {
    for (paths) |path| {
        const marker = ".local-fixtures/apex/repos/";
        const marker_pos = std.mem.indexOf(u8, path, marker) orelse continue;
        const repo_start = marker_pos + marker.len;
        const rest = path[repo_start..];
        if (std.mem.eql(u8, rest, repo_name)) return true;
        if (std.mem.startsWith(u8, rest, repo_name) and rest.len > repo_name.len) {
            const sep = rest[repo_name.len];
            if (sep == '/' or sep == '\\') return true;
        }
    }
    return false;
}

fn append_unique_path(
    alloc: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    path: []const u8,
) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try paths.append(alloc, path);
}

fn collect_test_class_names_from_paths(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    test_classes: *std.StringHashMapUnmanaged(void),
) !void {
    var files: std.ArrayListUnmanaged(SourceFile) = .empty;
    for (paths) |path| {
        try collect_cls_files(alloc, io, path, &files);
    }
    for (files.items) |file| {
        const tokens = lexer.tokenize(file.content, alloc) catch continue;
        const decls = parser.parse(tokens, alloc) catch continue;
        for (decls) |decl| {
            switch (decl) {
                .class_decl => |cd| {
                    if (is_test_class(cd)) try test_classes.put(alloc, cd.name, {});
                },
                else => {},
            }
        }
    }
}

const TestSourceLoadStats = struct {
    source_count: usize,
    parse_errors: u32,
};

fn load_test_sources(
    parse_alloc: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    eval: *evaluator.Evaluator,
) !TestSourceLoadStats {
    var files: std.ArrayListUnmanaged(SourceFile) = .empty;
    for (paths) |path| {
        try collect_cls_files(parse_alloc, io, path, &files);
    }
    var parse_errors: u32 = 0;
    for (files.items) |file| {
        parse_errors += load_test_source_file(parse_alloc, file, eval);
    }
    return .{ .source_count = files.items.len, .parse_errors = parse_errors };
}

fn load_test_source_file(
    parse_alloc: std.mem.Allocator,
    file: SourceFile,
    eval: *evaluator.Evaluator,
) u32 {
    const tokens = lexer.tokenize(file.content, parse_alloc) catch return 1;
    const decls = parser.parse(tokens, parse_alloc) catch return 1;
    eval.load_decls(decls) catch return 1;
    for (decls) |decl| {
        switch (decl) {
            .class_decl => |cd| eval.register_class_source(cd.name, file.content) catch {},
            .trigger_decl => |td| eval.register_trigger_source(td.name, file.content) catch {},
            else => {},
        }
    }
    return 0;
}

fn load_test_metadata(
    parse_alloc: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    eval: *evaluator.Evaluator,
) void {
    for (paths) |path| {
        load_test_metadata_path(parse_alloc, io, path, eval);
        if (!should_search_metadata_parents(path)) continue;
        var parent = std.fs.path.dirname(path);
        var depth: u8 = 0;
        while (parent != null and depth < 3) : (depth += 1) {
            const p = parent.?;
            load_test_metadata_path(parse_alloc, io, p, eval);
            parent = std.fs.path.dirname(p);
        }
    }
}

fn load_test_metadata_path(
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
    collect_field_type_hints(
        parse_alloc,
        io,
        path,
        &eval.field_types,
    ) catch {};
    collect_source_picklist_value_hints(
        parse_alloc,
        io,
        path,
        &eval.field_types,
        &eval.field_metadata,
    ) catch {};
    collect_child_relationship_hints(
        parse_alloc,
        io,
        path,
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
    collect_custom_labels(parse_alloc, io, path, &eval.custom_labels) catch {};
    eval.index_custom_metadata_from_path(path) catch {};
}

fn collect_classes_with_static_fields(
    parse_alloc: std.mem.Allocator,
    eval: *evaluator.Evaluator,
) !std.ArrayListUnmanaged(*ast.ClassDecl) {
    var classes: std.ArrayListUnmanaged(*ast.ClassDecl) = .empty;
    var iter = eval.classes.iterator();
    while (iter.next()) |entry| {
        const class_decl = entry.value_ptr.*;
        if (class_has_static_fields(class_decl)) try classes.append(parse_alloc, class_decl);
    }
    return classes;
}

fn class_has_static_fields(class_decl: *ast.ClassDecl) bool {
    for (class_decl.members) |member| {
        switch (member) {
            .field_decl => |field_decl| {
                if (field_decl.modifiers.is_static) return true;
            },
            else => {},
        }
    }
    return false;
}

fn run_loaded_tests(
    gpa: std.mem.Allocator,
    parse_alloc: std.mem.Allocator,
    io: std.Io,
    eval: *evaluator.Evaluator,
    filter_class: ?[]const u8,
    filter_method: ?[]const u8,
    shard: ?TestShard,
    classes_with_statics: []const *ast.ClassDecl,
    allowed_test_classes: ?*const std.StringHashMapUnmanaged(void),
    suite: *TestSuiteResult,
    writer: anytype,
) !void {
    var test_arena = std.heap.ArenaAllocator.init(gpa);
    defer test_arena.deinit();

    var test_ordinal: usize = 0;
    var class_iter = eval.classes.iterator();
    while (class_iter.next()) |entry| {
        const class_name = entry.key_ptr.*;
        if (filter_class) |fc| {
            if (!std.ascii.eqlIgnoreCase(class_name, fc)) continue;
        } else if (allowed_test_classes) |allowed| {
            if (!allowed.contains(class_name)) continue;
        }
        try run_test_class(
            parse_alloc,
            io,
            eval,
            class_name,
            entry.value_ptr.*,
            filter_method,
            shard,
            &test_ordinal,
            classes_with_statics,
            &test_arena,
            suite,
            writer,
        );
    }
}

fn run_test_class(
    parse_alloc: std.mem.Allocator,
    io: std.Io,
    eval: *evaluator.Evaluator,
    class_name: []const u8,
    class_decl: *ast.ClassDecl,
    filter_method: ?[]const u8,
    shard: ?TestShard,
    test_ordinal: *usize,
    classes_with_statics: []const *ast.ClassDecl,
    test_arena: *std.heap.ArenaAllocator,
    suite: *TestSuiteResult,
    writer: anytype,
) !void {
    const test_setup_method = find_test_setup_method(class_decl);
    for (class_decl.members) |member| {
        switch (member) {
            .method_decl => |method_decl| {
                if (!is_test_method(method_decl)) continue;
                if (filter_method) |fm| {
                    if (!std.ascii.eqlIgnoreCase(method_decl.name, fm)) continue;
                }
                const ordinal = test_ordinal.*;
                test_ordinal.* += 1;
                if (shard) |s| {
                    if (!s.includes(ordinal)) continue;
                }
                try run_test_method(
                    parse_alloc,
                    io,
                    eval,
                    class_name,
                    method_decl,
                    test_setup_method,
                    classes_with_statics,
                    test_arena,
                    suite,
                    writer,
                );
            },
            else => {},
        }
    }
}

fn find_test_setup_method(class_decl: *ast.ClassDecl) ?*ast.MethodDecl {
    for (class_decl.members) |member| {
        switch (member) {
            .method_decl => |method_decl| {
                for (method_decl.annotations) |ann| {
                    if (std.ascii.eqlIgnoreCase(ann, "@TestSetup")) return method_decl;
                }
            },
            else => {},
        }
    }
    return null;
}

fn run_test_method(
    parse_alloc: std.mem.Allocator,
    io: std.Io,
    base_eval: *evaluator.Evaluator,
    class_name: []const u8,
    method_decl: *ast.MethodDecl,
    test_setup_method: ?*ast.MethodDecl,
    classes_with_statics: []const *ast.ClassDecl,
    test_arena: *std.heap.ArenaAllocator,
    suite: *TestSuiteResult,
    writer: anytype,
) !void {
    suite.total += 1;
    _ = test_arena.reset(.{ .retain_with_limit = 128 * 1024 * 1024 });
    var test_eval = evaluator.Evaluator.init(test_arena.allocator(), io) catch return;
    try copy_test_eval_context(&test_eval, base_eval, parse_alloc);
    configure_test_method(
        &test_eval,
        method_decl,
        class_name,
        test_setup_method,
        classes_with_statics,
    );
    reset_test_limits(&test_eval);

    const result = test_eval.call_method(class_name, method_decl.name, &.{});
    if (result) |_| {
        try record_test_success(parse_alloc, class_name, method_decl, &test_eval, suite, writer);
    } else |err| {
        try record_test_error(parse_alloc, class_name, method_decl, &test_eval, err, suite, writer);
    }
}

fn copy_test_eval_context(
    test_eval: *evaluator.Evaluator,
    base_eval: *evaluator.Evaluator,
    parse_alloc: std.mem.Allocator,
) !void {
    test_eval.classes = base_eval.classes;
    test_eval.top_level_enums = base_eval.top_level_enums;
    test_eval.class_arena = parse_alloc;
    test_eval.triggers = base_eval.triggers;
    test_eval.outer_class_by_inner_name = base_eval.outer_class_by_inner_name;
    test_eval.class_lookup_cache_built = base_eval.class_lookup_cache_built;
    test_eval.class_sources = base_eval.class_sources;
    test_eval.trigger_sources = base_eval.trigger_sources;
    test_eval.source_paths = base_eval.source_paths;
    test_eval.fixture_relaxed_exceptions = base_eval.fixture_relaxed_exceptions;
    test_eval.field_defaults = try copy_nested_metadata_map(
        Value,
        test_eval.arena,
        &base_eval.field_defaults,
    );
    test_eval.field_types = try copy_nested_metadata_map(
        []const u8,
        test_eval.arena,
        &base_eval.field_types,
    );
    test_eval.field_metadata = try copy_nested_metadata_map(
        evaluator.FieldMetadata,
        test_eval.arena,
        &base_eval.field_metadata,
    );
    test_eval.child_relationships = try copy_metadata_map(
        evaluator.CustomChildRelationship,
        test_eval.arena,
        &base_eval.child_relationships,
    );
    test_eval.custom_setting_types = try copy_metadata_map(
        void,
        test_eval.arena,
        &base_eval.custom_setting_types,
    );
    test_eval.custom_setting_kinds = try copy_metadata_map(
        []const u8,
        test_eval.arena,
        &base_eval.custom_setting_kinds,
    );
    test_eval.object_labels = try copy_metadata_map(
        []const u8,
        test_eval.arena,
        &base_eval.object_labels,
    );
    test_eval.object_label_plurals = try copy_metadata_map(
        []const u8,
        test_eval.arena,
        &base_eval.object_label_plurals,
    );
    test_eval.custom_labels = try copy_metadata_map(
        []const u8,
        test_eval.arena,
        &base_eval.custom_labels,
    );
    test_eval.field_sets = try copy_nested_metadata_map(
        evaluator.FieldSetMetadata,
        test_eval.arena,
        &base_eval.field_sets,
    );
    test_eval.custom_metadata_paths_indexed = base_eval.custom_metadata_paths_indexed;
    try copy_custom_metadata_record_cache(test_eval, base_eval);
}

fn copy_metadata_map(
    comptime ValueType: type,
    arena: std.mem.Allocator,
    src: *const std.StringArrayHashMapUnmanaged(ValueType),
) !std.StringArrayHashMapUnmanaged(ValueType) {
    var out: std.StringArrayHashMapUnmanaged(ValueType) = .empty;
    var src_copy = src.*;
    var iter = src_copy.iterator();
    while (iter.next()) |entry| {
        try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn copy_nested_metadata_map(
    comptime ValueType: type,
    arena: std.mem.Allocator,
    src: *const std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(ValueType)),
) !std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(ValueType)) {
    var out: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(ValueType)) = .empty;
    var src_copy = src.*;
    var iter = src_copy.iterator();
    while (iter.next()) |entry| {
        var inner: std.StringArrayHashMapUnmanaged(ValueType) = .empty;
        var inner_src = entry.value_ptr.*;
        var inner_iter = inner_src.iterator();
        while (inner_iter.next()) |inner_entry| {
            try inner.put(arena, inner_entry.key_ptr.*, inner_entry.value_ptr.*);
        }
        try out.put(arena, entry.key_ptr.*, inner);
    }
    return out;
}

fn copy_custom_metadata_record_cache(
    test_eval: *evaluator.Evaluator,
    base_eval: *evaluator.Evaluator,
) !void {
    var iter = base_eval.custom_metadata_records.iterator();
    while (iter.next()) |entry| {
        var records: std.ArrayListUnmanaged(Value) = .empty;
        try records.appendSlice(test_eval.arena, entry.value_ptr.items);
        try test_eval.custom_metadata_records.put(test_eval.arena, entry.key_ptr.*, records);
    }
}

fn configure_test_method(
    test_eval: *evaluator.Evaluator,
    method_decl: *ast.MethodDecl,
    class_name: []const u8,
    test_setup_method: ?*ast.MethodDecl,
    classes_with_statics: []const *ast.ClassDecl,
) void {
    test_eval.see_all_data = method_has_see_all_data(method_decl);
    register_static_placeholders(test_eval, classes_with_statics);
    if (test_setup_method) |setup| {
        _ = test_eval.call_method(class_name, setup.name, &.{}) catch {};
        register_static_placeholders(test_eval, classes_with_statics);
        test_eval.static_inited.clearRetainingCapacity();
    }
}

fn method_has_see_all_data(method_decl: *ast.MethodDecl) bool {
    for (method_decl.annotations) |ann| {
        if (std.ascii.indexOfIgnoreCase(ann, "seealldata") != null and
            std.ascii.indexOfIgnoreCase(ann, "true") != null)
        {
            return true;
        }
    }
    return false;
}

fn register_static_placeholders(
    test_eval: *evaluator.Evaluator,
    classes_with_statics: []const *ast.ClassDecl,
) void {
    for (classes_with_statics) |class_decl| {
        test_eval.register_static_field_placeholders(class_decl);
    }
}

fn reset_test_limits(test_eval: *evaluator.Evaluator) void {
    test_eval.limits_dml = 0;
    test_eval.limits_dml_rows = 0;
    test_eval.limits_soql = 0;
    test_eval.limits_publish_immediate = 0;
    test_eval.limits_queueable = 0;
    test_eval.limits_callouts = 0;
}

fn record_test_success(
    parse_alloc: std.mem.Allocator,
    class_name: []const u8,
    method_decl: *ast.MethodDecl,
    test_eval: *evaluator.Evaluator,
    suite: *TestSuiteResult,
    writer: anytype,
) !void {
    if (test_eval.assertion_failure) |msg| {
        suite.failed += 1;
        const msg_copy = parse_alloc.dupe(u8, msg) catch msg;
        try suite.results.append(parse_alloc, .{
            .class_name = class_name,
            .method_name = method_decl.name,
            .passed = false,
            .failure_message = msg_copy,
        });
        try writer.print("[FAIL] {s}#{s}: {s}\n", .{ class_name, method_decl.name, msg });
        return;
    }
    suite.passed += 1;
    try suite.results.append(parse_alloc, .{
        .class_name = class_name,
        .method_name = method_decl.name,
        .passed = true,
    });
    try writer.print("[PASS] {s}#{s}\n", .{ class_name, method_decl.name });
}

fn record_test_error(
    parse_alloc: std.mem.Allocator,
    class_name: []const u8,
    method_decl: *ast.MethodDecl,
    test_eval: *evaluator.Evaluator,
    err: anyerror,
    suite: *TestSuiteResult,
    writer: anytype,
) !void {
    if (test_eval.fixture_relaxed_exceptions) {
        suite.failed += 1;
    } else {
        suite.errors += 1;
    }
    const exc_detail = pending_exception_message(test_eval);
    const err_msg = if (exc_detail.len > 0)
        try std.fmt.allocPrint(parse_alloc, "{s}: {s}", .{ @errorName(err), exc_detail })
    else
        try std.fmt.allocPrint(parse_alloc, "{s}", .{@errorName(err)});
    try suite.results.append(parse_alloc, .{
        .class_name = class_name,
        .method_name = method_decl.name,
        .passed = false,
        .failure_message = err_msg,
    });
    const label = if (test_eval.fixture_relaxed_exceptions) "FAIL" else "ERROR";
    try writer.print("[{s}] {s}#{s}: {s}\n", .{ label, class_name, method_decl.name, err_msg });
}

fn pending_exception_message(test_eval: *evaluator.Evaluator) []const u8 {
    const pending = test_eval.pending_exception orelse return "";
    if (pending != .object) return "";
    const message = pending.object.fields.get("message") orelse return pending.object.class_name;
    if (message == .string and message.string.len > 0) return message.string;
    return pending.object.class_name;
}

fn is_test_class(cd: *ast.ClassDecl) bool {
    for (cd.annotations) |ann| {
        if (std.ascii.eqlIgnoreCase(ann, "@isTest") or
            std.ascii.eqlIgnoreCase(ann, "@IsTest") or
            std.ascii.startsWithIgnoreCase(ann, "@isTest(") or
            std.ascii.startsWithIgnoreCase(ann, "@test("))
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
        if (std.ascii.eqlIgnoreCase(ann, "@isTest") or
            std.ascii.eqlIgnoreCase(ann, "@IsTest") or
            std.ascii.eqlIgnoreCase(ann, "@test"))
        {
            return true;
        }
        // Also match @isTest(SeeAllData=true) and similar parameterized annotations
        if (std.ascii.startsWithIgnoreCase(ann, "@isTest(") or
            std.ascii.startsWithIgnoreCase(ann, "@test("))
        {
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
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            alloc,
            .limited(10 * 1024 * 1024),
        ) catch return;
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
        if (!std.mem.endsWith(u8, entry.basename, ".cls") and
            !std.mem.endsWith(u8, entry.basename, ".trigger"))
        {
            continue;
        }
        // Skip name-shadowing stub classes that intentionally shadow system classes
        // (e.g., extra-tests/name-shadowing/System/JSON.cls). These empty classes
        // exist only to verify that production code uses fully-qualified names in
        // Salesforce, but they break the interpreter's built-in dispatch.
        if (std.mem.indexOf(u8, entry.path, "name-shadowing/") != null or
            std.mem.indexOf(u8, entry.path, "name-shadowing\\") != null)
        {
            continue;
        }

        const full_path = std.fs.path.join(alloc, &.{ path, entry.path }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            alloc,
            .limited(10 * 1024 * 1024),
        ) catch continue;
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
const FieldMetadataEntry = struct {
    type_name: []const u8,
    field_name: []const u8,
    entry_path: []const u8,
};

const FieldDefaultsMap = std.StringArrayHashMapUnmanaged(
    std.StringArrayHashMapUnmanaged(Value),
);
const FieldTypesMap = std.StringArrayHashMapUnmanaged(
    std.StringArrayHashMapUnmanaged([]const u8),
);
const FieldMetadataMap = std.StringArrayHashMapUnmanaged(
    std.StringArrayHashMapUnmanaged(evaluator.FieldMetadata),
);
const ChildRelationshipsMap = std.StringArrayHashMapUnmanaged(
    evaluator.CustomChildRelationship,
);
const CustomSettingTypesMap = std.StringArrayHashMapUnmanaged(void);
const CustomSettingKindsMap = std.StringArrayHashMapUnmanaged([]const u8);
const ObjectLabelsMap = std.StringArrayHashMapUnmanaged([]const u8);
const FieldSetsMap = std.StringArrayHashMapUnmanaged(
    std.StringArrayHashMapUnmanaged(evaluator.FieldSetMetadata),
);

fn collect_field_defaults(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    field_defaults: *FieldDefaultsMap,
    field_types: *FieldTypesMap,
    field_metadata: *FieldMetadataMap,
    child_relationships: *ChildRelationshipsMap,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        if (std.mem.endsWith(u8, entry.basename, ".field-meta.xml")) {
            const field_entry =
                parse_field_metadata_entry(entry.path, entry.basename) orelse continue;
            const full_path = std.fs.path.join(
                alloc,
                &.{ path, field_entry.entry_path },
            ) catch continue;
            const content = std.Io.Dir.cwd().readFileAlloc(
                io,
                full_path,
                alloc,
                .limited(64 * 1024),
            ) catch continue;

            try store_field_metadata_from_xml(
                alloc,
                content,
                field_entry,
                field_defaults,
                field_types,
                field_metadata,
                child_relationships,
            );
            continue;
        }

        if (std.mem.endsWith(u8, entry.basename, legacy_object_suffix)) {
            const object_type = parse_legacy_object_type(alloc, entry.basename) orelse continue;
            const full_path = std.fs.path.join(
                alloc,
                &.{ path, entry.path },
            ) catch continue;
            const content = std.Io.Dir.cwd().readFileAlloc(
                io,
                full_path,
                alloc,
                .limited(512 * 1024),
            ) catch continue;
            try collect_legacy_object_field_metadata(
                alloc,
                content,
                object_type,
                entry.path,
                field_defaults,
                field_types,
                field_metadata,
                child_relationships,
            );
        }
    }
}

fn parse_field_metadata_entry(entry_path: []const u8, basename: []const u8) ?FieldMetadataEntry {
    const objects_idx = std.mem.indexOf(u8, entry_path, "objects/") orelse
        std.mem.indexOf(u8, entry_path, "objects\\") orelse return null;
    const after_objects = entry_path[objects_idx + 8 ..];
    const sep_idx = std.mem.indexOfAny(u8, after_objects, "/\\") orelse return null;
    return .{
        .type_name = after_objects[0..sep_idx],
        .field_name = basename[0 .. basename.len - field_meta_xml_suffix.len],
        .entry_path = entry_path,
    };
}

const field_meta_xml_suffix = ".field-meta.xml";
const legacy_object_suffix = ".object";
const metadata_namespace_placeholder_percent = "%%%NAMESPACE%%%";
const metadata_namespace_placeholder_underscores = "___NAMESPACE___";

fn store_field_metadata_from_xml(
    alloc: std.mem.Allocator,
    content: []const u8,
    field_entry: FieldMetadataEntry,
    field_defaults: *FieldDefaultsMap,
    field_types: *FieldTypesMap,
    field_metadata: *FieldMetadataMap,
    child_relationships: *ChildRelationshipsMap,
) !void {
    var metadata = read_field_metadata(alloc, content) catch return;
    store_field_type_metadata(alloc, content, field_entry, field_types) catch {};
    store_field_reference_metadata(
        alloc,
        content,
        field_entry,
        &metadata,
        child_relationships,
    ) catch {};
    store_field_metadata(alloc, field_entry, metadata, field_metadata) catch {};
    store_picklist_default(
        alloc,
        field_entry,
        metadata.picklist_values,
        field_defaults,
    ) catch {};
    store_xml_default_value(alloc, content, field_entry, field_defaults) catch {};
}

fn parse_legacy_object_type(
    alloc: std.mem.Allocator,
    basename: []const u8,
) ?[]const u8 {
    if (!std.mem.endsWith(u8, basename, legacy_object_suffix)) return null;
    const stem = basename[0 .. basename.len - legacy_object_suffix.len];
    if (stem.len == 0) return null;
    return normalize_metadata_api_name(alloc, stem) catch null;
}

fn collect_legacy_object_field_metadata(
    alloc: std.mem.Allocator,
    content: []const u8,
    object_type: []const u8,
    entry_path: []const u8,
    field_defaults: *FieldDefaultsMap,
    field_types: *FieldTypesMap,
    field_metadata: *FieldMetadataMap,
    child_relationships: *ChildRelationshipsMap,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, "<fields>")) |block_start_idx| {
        const block_start = block_start_idx + "<fields>".len;
        const block_end = std.mem.indexOfPos(u8, content, block_start, "</fields>") orelse break;
        cursor = block_end + "</fields>".len;
        const block = content[block_start..block_end];

        const raw_field_name = extract_xml_tag_value(block, "fullName") orelse continue;
        if (extract_xml_tag_value(block, "type") == null) continue;
        const field_name = try normalize_metadata_api_name(
            alloc,
            std.mem.trim(u8, raw_field_name, " \t\r\n"),
        );
        if (field_name.len == 0) continue;

        try store_field_metadata_from_xml(
            alloc,
            block,
            .{
                .type_name = object_type,
                .field_name = field_name,
                .entry_path = entry_path,
            },
            field_defaults,
            field_types,
            field_metadata,
            child_relationships,
        );
    }
}

fn normalize_metadata_api_name(
    alloc: std.mem.Allocator,
    raw_name: []const u8,
) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
    var result = std.ArrayListUnmanaged(u8).empty;
    var idx: usize = 0;
    while (idx < trimmed.len) {
        if (std.mem.startsWith(u8, trimmed[idx..], metadata_namespace_placeholder_percent)) {
            idx += metadata_namespace_placeholder_percent.len;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed[idx..], metadata_namespace_placeholder_underscores)) {
            idx += metadata_namespace_placeholder_underscores.len;
            continue;
        }
        try result.append(alloc, trimmed[idx]);
        idx += 1;
    }
    return try alloc.dupe(u8, result.items);
}

fn read_field_metadata(alloc: std.mem.Allocator, content: []const u8) !evaluator.FieldMetadata {
    var metadata = evaluator.FieldMetadata{};
    if (extract_xml_tag_value(content, "label")) |label| {
        metadata.label = alloc.dupe(u8, std.mem.trim(u8, label, " \t\n\r")) catch null;
    }
    if (extract_xml_tag_value(content, "inlineHelpText")) |inline_help_text| {
        metadata.inline_help_text =
            decode_xml_text(alloc, std.mem.trim(u8, inline_help_text, " \t\n\r"), false) catch null;
    }
    if (extract_xml_tag_value(content, "type")) |field_type| {
        metadata.field_type = alloc.dupe(u8, std.mem.trim(u8, field_type, " \t\n\r")) catch null;
    }
    if (extract_field_bool_tag(content, "caseSensitive")) |value| metadata.case_sensitive = value;
    if (extract_field_bool_tag(content, "externalId")) |value| metadata.is_external_id = value;
    if (extract_field_bool_tag(content, "unique")) |value| metadata.is_unique = value;
    if (extract_field_bool_tag(content, "required")) |value| metadata.is_required = value;
    if (extract_field_bool_tag(content, "reparentableMasterDetail")) |value| {
        metadata.reparentable_master_detail = value;
    }
    if (extract_xml_tag_value(content, "length")) |length| {
        metadata.length = std.fmt.parseInt(i64, std.mem.trim(u8, length, " \t\n\r"), 10) catch null;
    }
    if (extract_xml_tag_value(content, "deleteConstraint")) |delete_constraint| {
        const value = std.mem.trim(u8, delete_constraint, " \t\n\r");
        metadata.delete_constraint = alloc.dupe(u8, value) catch null;
    }
    if (extract_xml_tag_value(content, "relationshipOrder")) |relationship_order| {
        metadata.relationship_order = std.fmt.parseInt(
            i64,
            std.mem.trim(u8, relationship_order, " \t\n\r"),
            10,
        ) catch null;
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
        const value = std.mem.trim(u8, summarized_field, " \t\n\r");
        metadata.summarized_field = alloc.dupe(u8, value) catch null;
    }
    if (extract_xml_tag_value(content, "summaryForeignKey")) |summary_foreign_key| {
        const value = std.mem.trim(u8, summary_foreign_key, " \t\n\r");
        metadata.summary_foreign_key = alloc.dupe(u8, value) catch null;
    }
    if (extract_xml_tag_value(content, "summaryOperation")) |summary_operation| {
        const value = std.mem.trim(u8, summary_operation, " \t\n\r");
        metadata.summary_operation = alloc.dupe(u8, value) catch null;
    }
    metadata.summary_filters = parse_summary_filters(alloc, content) catch &.{};
    metadata.picklist_values = parse_picklist_values(alloc, content) catch &.{};
    return metadata;
}

fn extract_field_bool_tag(content: []const u8, tag_name: []const u8) ?bool {
    const value = extract_xml_tag_value(content, tag_name) orelse return null;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\n\r"), "true");
}

fn store_field_type_metadata(
    alloc: std.mem.Allocator,
    content: []const u8,
    field_entry: FieldMetadataEntry,
    field_types: *FieldTypesMap,
) !void {
    const field_type = extract_xml_tag_value(content, "type") orelse return;
    const type_key = try normalize_metadata_api_name(alloc, field_entry.type_name);
    const field_key = try normalize_metadata_api_name(alloc, field_entry.field_name);
    const gop = try field_types.getOrPut(alloc, type_key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.put(alloc, field_key, field_type);
}

fn store_field_reference_metadata(
    alloc: std.mem.Allocator,
    content: []const u8,
    field_entry: FieldMetadataEntry,
    metadata: *evaluator.FieldMetadata,
    child_relationships: *ChildRelationshipsMap,
) !void {
    const reference_to = extract_xml_tag_value(content, "referenceTo") orelse return;
    const parent_type = try normalize_metadata_api_name(
        alloc,
        std.mem.trim(u8, reference_to, " \t\n\r"),
    );
    metadata.reference_to = parent_type;

    const raw_relationship_name = extract_xml_tag_value(content, "relationshipName") orelse return;
    const relationship_name = try normalize_metadata_api_name(
        alloc,
        std.mem.trim(u8, raw_relationship_name, " \t\n\r"),
    );
    put_child_relationship(
        alloc,
        child_relationships,
        parent_type,
        relationship_name,
        field_entry.type_name,
        field_entry.field_name,
    ) catch {};
    if (std.mem.endsWith(u8, relationship_name, "__r")) return;

    const rel_with_suffix = std.fmt.allocPrint(alloc, "{s}__r", .{relationship_name}) catch return;
    if (rel_with_suffix.len == 0) return;
    put_child_relationship(
        alloc,
        child_relationships,
        parent_type,
        rel_with_suffix,
        field_entry.type_name,
        field_entry.field_name,
    ) catch {};
}

fn store_field_metadata(
    alloc: std.mem.Allocator,
    field_entry: FieldMetadataEntry,
    metadata: evaluator.FieldMetadata,
    field_metadata: *FieldMetadataMap,
) !void {
    if (!field_metadata_has_values(metadata)) return;
    const type_key = try normalize_metadata_api_name(alloc, field_entry.type_name);
    const field_key = try normalize_metadata_api_name(alloc, field_entry.field_name);
    const gop = try field_metadata.getOrPut(alloc, type_key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.put(alloc, field_key, metadata);
}

fn field_metadata_has_values(metadata: evaluator.FieldMetadata) bool {
    return metadata.label != null or
        metadata.inline_help_text != null or
        metadata.is_unique or
        metadata.is_external_id or
        metadata.is_required or
        metadata.length != null or
        metadata.reference_to != null or
        metadata.delete_constraint != null or
        metadata.formula != null or
        metadata.summary_operation != null or
        metadata.picklist_values.len > 0;
}

fn store_picklist_default(
    alloc: std.mem.Allocator,
    field_entry: FieldMetadataEntry,
    picklist_values: []const evaluator.PicklistValueMetadata,
    field_defaults: *FieldDefaultsMap,
) !void {
    for (picklist_values) |picklist_value| {
        if (!picklist_value.is_default) continue;
        try store_field_default_value(
            alloc,
            field_entry,
            Value{ .string = picklist_value.value },
            field_defaults,
        );
        break;
    }
}

fn store_xml_default_value(
    alloc: std.mem.Allocator,
    content: []const u8,
    field_entry: FieldMetadataEntry,
    field_defaults: *FieldDefaultsMap,
) !void {
    const raw_value = extract_xml_tag_value(content, "defaultValue") orelse return;
    const decoded = try decode_xml_default_value(alloc, raw_value);
    try store_field_default_value(
        alloc,
        field_entry,
        default_value_from_text(decoded),
        field_defaults,
    );
}

fn default_value_from_text(decoded: []const u8) Value {
    if (std.ascii.eqlIgnoreCase(decoded, "true")) return Value{ .boolean = true };
    if (std.ascii.eqlIgnoreCase(decoded, "false")) return Value{ .boolean = false };
    if (std.fmt.parseInt(i64, decoded, 10)) |int_value| {
        return Value{ .integer = int_value };
    } else |_| {}
    return Value{ .string = decoded };
}

fn store_field_default_value(
    alloc: std.mem.Allocator,
    field_entry: FieldMetadataEntry,
    value: Value,
    field_defaults: *FieldDefaultsMap,
) !void {
    const type_key = try normalize_metadata_api_name(alloc, field_entry.type_name);
    const field_key = try normalize_metadata_api_name(alloc, field_entry.field_name);
    const gop = try field_defaults.getOrPut(alloc, type_key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.put(alloc, field_key, value);
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

fn collect_custom_labels(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    custom_labels: *std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".labels-meta.xml")) continue;

        const full_path = std.fs.path.join(alloc, &.{ path, entry.path }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            alloc,
            .limited(1024 * 1024),
        ) catch continue;

        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, content, cursor, "<labels>")) |block_start| {
            const body_start = block_start + "<labels>".len;
            const block_end = std.mem.indexOfPos(u8, content, body_start, "</labels>") orelse break;
            const block = content[body_start..block_end];
            cursor = block_end + "</labels>".len;

            const raw_name = extract_xml_tag_value(block, "fullName") orelse continue;
            const raw_value = extract_xml_tag_value(block, "value") orelse continue;
            const name = std.mem.trim(u8, raw_name, " \t\r\n");
            const value = std.mem.trim(u8, raw_value, " \t\r\n");
            if (name.len == 0) continue;
            const key_dup = alloc.dupe(u8, name) catch continue;
            const val_dup = decode_xml_text(alloc, value, false) catch continue;
            custom_labels.put(alloc, key_dup, val_dup) catch {};
        }
    }
}

fn parse_summary_filters(
    alloc: std.mem.Allocator,
    content: []const u8,
) ![]const evaluator.SummaryFilter {
    var filters = std.ArrayListUnmanaged(evaluator.SummaryFilter).empty;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(
        u8,
        content,
        search_start,
        "<summaryFilterItems>",
    )) |block_start_idx| {
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
                const value = std.mem.trim(u8, raw_default, " \t\n\r");
                break :blk std.ascii.eqlIgnoreCase(value, "true");
            }
            break :blk false;
        };
        const is_active = blk: {
            if (extract_xml_tag_value(block, "isActive")) |raw_active| {
                const value = std.mem.trim(u8, raw_active, " \t\n\r");
                break :blk std.ascii.eqlIgnoreCase(value, "true");
            }
            break :blk true;
        };
        try values.append(alloc, .{
            .label = try decode_xml_text(alloc, std.mem.trim(u8, raw_label, " \t\n\r"), false),
            .value = try decode_xml_text(alloc, std.mem.trim(u8, raw_value, " \t\n\r"), false),
            .is_default = is_default,
            .is_active = is_active,
        });
        search_start = block_end + "</value>".len;
    }
    return try alloc.dupe(evaluator.PicklistValueMetadata, values.items);
}

fn put_child_relationship(
    alloc: std.mem.Allocator,
    child_relationships: *ChildRelationshipsMap,
    parent_type: []const u8,
    relationship_name: []const u8,
    child_type: []const u8,
    fk_field: []const u8,
) !void {
    const normalized_parent_type = try normalize_metadata_api_name(alloc, parent_type);
    const normalized_relationship_name = try normalize_metadata_api_name(alloc, relationship_name);
    const normalized_child_type = try normalize_metadata_api_name(alloc, child_type);
    const normalized_fk_field = try normalize_metadata_api_name(alloc, fk_field);
    const raw_key = try std.fmt.allocPrint(
        alloc,
        "{s}|{s}",
        .{ normalized_parent_type, normalized_relationship_name },
    );
    const key = try alloc.alloc(u8, raw_key.len);
    _ = std.ascii.lowerString(key, raw_key);
    try child_relationships.put(alloc, key, .{
        .child_type = normalized_child_type,
        .fk_field = normalized_fk_field,
    });
}

fn collect_field_type_hints(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    field_types: *FieldTypesMap,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        if (std.mem.endsWith(u8, entry.basename, ".fieldSet-meta.xml")) {
            const object_type = metadata_object_from_path(entry.path) orelse continue;
            try collect_field_type_hints_from_file(
                alloc,
                io,
                path,
                entry.path,
                object_type,
                field_types,
            );
        } else if (std.mem.endsWith(u8, entry.basename, ".layout-meta.xml")) {
            const object_type = layout_parent_type_from_basename(entry.basename) orelse continue;
            try collect_field_type_hints_from_file(
                alloc,
                io,
                path,
                entry.path,
                object_type,
                field_types,
            );
        } else if (std.mem.endsWith(u8, entry.basename, ".quickAction-meta.xml")) {
            try collect_quick_action_field_type_hints(
                alloc,
                io,
                path,
                entry.path,
                entry.basename,
                field_types,
            );
        } else if (std.mem.endsWith(u8, entry.basename, ".cls") or
            std.mem.endsWith(u8, entry.basename, ".trigger"))
        {
            try collect_apex_source_field_type_hints(
                alloc,
                io,
                path,
                entry.path,
                field_types,
            );
        }
    }
}

fn collect_field_type_hints_from_file(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    entry_path: []const u8,
    object_type: []const u8,
    field_types: *FieldTypesMap,
) !void {
    const full_path = try std.fs.path.join(alloc, &.{ base_path, entry_path });
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        alloc,
        .limited(512 * 1024),
    ) catch return;
    try collect_field_type_hints_from_content(alloc, content, object_type, field_types);
}

fn collect_quick_action_field_type_hints(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    entry_path: []const u8,
    basename: []const u8,
    field_types: *FieldTypesMap,
) !void {
    const full_path = try std.fs.path.join(alloc, &.{ base_path, entry_path });
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        alloc,
        .limited(128 * 1024),
    ) catch return;
    const object_type = if (extract_xml_tag_value(content, "targetObject")) |target|
        std.mem.trim(u8, target, " \t\r\n")
    else
        quick_action_parent_type_from_basename(basename) orelse return;
    try collect_field_type_hints_from_content(alloc, content, object_type, field_types);
}

fn collect_field_type_hints_from_content(
    alloc: std.mem.Allocator,
    content: []const u8,
    object_type: []const u8,
    field_types: *FieldTypesMap,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, "<field>")) |start_idx| {
        const value_start = start_idx + "<field>".len;
        const end_idx = std.mem.indexOfPos(u8, content, value_start, "</field>") orelse break;
        cursor = end_idx + "</field>".len;
        const field_name = std.mem.trim(u8, content[value_start..end_idx], " \t\r\n");
        if (field_name.len == 0 or std.mem.indexOfScalar(u8, field_name, '.') != null) continue;
        try store_field_type_hint(alloc, field_types, object_type, field_name);
    }
}

fn collect_apex_source_field_type_hints(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    entry_path: []const u8,
    field_types: *FieldTypesMap,
) !void {
    const full_path = try std.fs.path.join(alloc, &.{ base_path, entry_path });
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        alloc,
        .limited(10 * 1024 * 1024),
    ) catch return;
    try collect_direct_source_field_hints(alloc, content, field_types);
    try collect_schema_fields_source_hints(alloc, content, field_types);
}

fn collect_direct_source_field_hints(
    alloc: std.mem.Allocator,
    content: []const u8,
    field_types: *FieldTypesMap,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, cursor, '.')) |dot| {
        cursor = dot + 1;
        const object_type = source_identifier_before(content, dot) orelse continue;
        const field_name = source_identifier_after(content, dot + 1) orelse continue;
        if (!source_field_hint_pair_is_sobject_field(object_type, field_name)) continue;
        try store_field_type_hint(alloc, field_types, object_type, field_name);
    }
}

fn collect_schema_fields_source_hints(
    alloc: std.mem.Allocator,
    content: []const u8,
    field_types: *FieldTypesMap,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, ".fields.")) |fields_dot| {
        cursor = fields_dot + ".fields.".len;
        const field_name = source_identifier_after(content, cursor) orelse continue;
        if (!source_custom_field_name(field_name)) continue;
        const object_end = fields_dot;
        var object_type = source_identifier_before(content, object_end) orelse continue;
        if (std.ascii.eqlIgnoreCase(object_type, "SObjectType")) {
            if (object_end <= object_type.len) continue;
            const before_sobject_type = object_end - object_type.len - 1;
            object_type = source_identifier_before(content, before_sobject_type) orelse continue;
        }
        if (!source_sobject_type_name(object_type)) continue;
        try store_field_type_hint(alloc, field_types, object_type, field_name);
    }
}

fn source_identifier_before(content: []const u8, end: usize) ?[]const u8 {
    if (end == 0) return null;
    var start = end;
    while (start > 0 and source_identifier_char(content[start - 1])) : (start -= 1) {}
    if (start == end) return null;
    return content[start..end];
}

fn source_identifier_after(content: []const u8, start: usize) ?[]const u8 {
    if (start >= content.len or !source_identifier_char(content[start])) return null;
    var end = start + 1;
    while (end < content.len and source_identifier_char(content[end])) : (end += 1) {}
    return content[start..end];
}

fn source_identifier_char(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn source_field_hint_pair_is_sobject_field(
    object_type: []const u8,
    field_name: []const u8,
) bool {
    return source_sobject_type_name(object_type) and source_custom_field_name(field_name);
}

fn source_sobject_type_name(name: []const u8) bool {
    if (std.ascii.endsWithIgnoreCase(name, "__c") or
        std.ascii.endsWithIgnoreCase(name, "__mdt") or
        std.ascii.endsWithIgnoreCase(name, "__e"))
    {
        return true;
    }
    const standard_objects = [_][]const u8{
        "Account",
        "Campaign",
        "Case",
        "Contact",
        "Event",
        "Lead",
        "Opportunity",
        "Task",
        "User",
    };
    for (standard_objects) |standard| {
        if (std.ascii.eqlIgnoreCase(name, standard)) return true;
    }
    return false;
}

fn source_custom_field_name(field_name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(field_name, "__c") or
        std.ascii.endsWithIgnoreCase(field_name, "__r");
}

fn store_field_type_hint(
    alloc: std.mem.Allocator,
    field_types: *FieldTypesMap,
    object_type: []const u8,
    field_name: []const u8,
) !void {
    const type_key = try normalize_metadata_api_name(alloc, object_type);
    const field_key = try normalize_metadata_api_name(alloc, field_name);
    const gop = try field_types.getOrPut(alloc, type_key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.keys()) |known_field| {
        if (std.ascii.eqlIgnoreCase(known_field, field_key)) return;
    }
    const inferred_type = builtins.infer_field_type_for_object(type_key, field_key);
    try gop.value_ptr.put(alloc, field_key, inferred_type);
}

fn metadata_object_from_path(entry_path: []const u8) ?[]const u8 {
    const objects_idx = std.mem.indexOf(u8, entry_path, "objects/") orelse
        std.mem.indexOf(u8, entry_path, "objects\\") orelse return null;
    const after_objects = entry_path[objects_idx + 8 ..];
    const sep_idx = std.mem.indexOfAny(u8, after_objects, "/\\") orelse return null;
    if (sep_idx == 0) return null;
    return after_objects[0..sep_idx];
}

const SourceFieldRef = struct {
    object_type: []const u8,
    field_name: []const u8,
};

const SourceStringConstant = struct {
    name: []const u8,
    value: []const u8,
};

fn collect_source_picklist_value_hints(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    field_types: *FieldTypesMap,
    field_metadata: *FieldMetadataMap,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    var field_refs = std.ArrayListUnmanaged(SourceFieldRef).empty;
    var constants = std.ArrayListUnmanaged(SourceStringConstant).empty;

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".cls") and
            !std.mem.endsWith(u8, entry.basename, ".trigger"))
        {
            continue;
        }
        const full_path = std.fs.path.join(alloc, &.{ path, entry.path }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            alloc,
            .limited(10 * 1024 * 1024),
        ) catch continue;
        try collect_source_field_refs_from_content(alloc, content, &field_refs);
        try collect_source_string_constants_from_content(alloc, content, &constants);
    }

    for (field_refs.items) |field_ref| {
        if (!source_field_ref_is_picklist(field_types, field_metadata, field_ref)) continue;
        if (field_metadata_has_picklist_values(
            field_metadata,
            field_ref.object_type,
            field_ref.field_name,
        )) {
            continue;
        }
        const prefix = try source_picklist_constant_prefix(alloc, field_ref.field_name);
        if (prefix.len < 5) continue;
        for (constants.items) |constant| {
            if (!source_constant_matches_field_prefix(constant.name, prefix)) continue;
            try append_source_picklist_metadata_value(
                alloc,
                field_metadata,
                field_ref.object_type,
                field_ref.field_name,
                constant.value,
            );
        }
    }
}

fn collect_source_field_refs_from_content(
    alloc: std.mem.Allocator,
    content: []const u8,
    refs: *std.ArrayListUnmanaged(SourceFieldRef),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, cursor, '.')) |dot| {
        cursor = dot + 1;
        const object_type = source_identifier_before(content, dot) orelse continue;
        const field_name = source_identifier_after(content, dot + 1) orelse continue;
        if (!source_field_hint_pair_is_sobject_field(object_type, field_name)) continue;
        try append_source_field_ref(alloc, refs, object_type, field_name);
    }

    cursor = 0;
    while (std.mem.indexOfPos(u8, content, cursor, ".fields.")) |fields_dot| {
        cursor = fields_dot + ".fields.".len;
        const field_name = source_identifier_after(content, cursor) orelse continue;
        if (!source_custom_field_name(field_name)) continue;
        const object_end = fields_dot;
        var object_type = source_identifier_before(content, object_end) orelse continue;
        if (std.ascii.eqlIgnoreCase(object_type, "SObjectType")) {
            if (object_end <= object_type.len) continue;
            const before_sobject_type = object_end - object_type.len - 1;
            object_type = source_identifier_before(content, before_sobject_type) orelse continue;
        }
        if (!source_sobject_type_name(object_type)) continue;
        try append_source_field_ref(alloc, refs, object_type, field_name);
    }
}

fn append_source_field_ref(
    alloc: std.mem.Allocator,
    refs: *std.ArrayListUnmanaged(SourceFieldRef),
    object_type: []const u8,
    field_name: []const u8,
) !void {
    const normalized_object = try normalize_metadata_api_name(alloc, object_type);
    const normalized_field = try normalize_metadata_api_name(alloc, field_name);
    for (refs.items) |known| {
        if (std.ascii.eqlIgnoreCase(known.object_type, normalized_object) and
            std.ascii.eqlIgnoreCase(known.field_name, normalized_field))
        {
            return;
        }
    }
    try refs.append(alloc, .{
        .object_type = normalized_object,
        .field_name = normalized_field,
    });
}

fn collect_source_string_constants_from_content(
    alloc: std.mem.Allocator,
    content: []const u8,
    constants: *std.ArrayListUnmanaged(SourceStringConstant),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, "String")) |string_idx| {
        cursor = string_idx + "String".len;
        if (string_idx > 0 and source_identifier_char(content[string_idx - 1])) continue;
        if (cursor < content.len and source_identifier_char(content[cursor])) continue;

        var name_start = cursor;
        while (name_start < content.len and
            std.ascii.isWhitespace(content[name_start])) : (name_start += 1)
        {}
        const name = source_identifier_after(content, name_start) orelse continue;
        if (!source_constant_name_is_candidate(name)) continue;

        const eq_idx =
            std.mem.indexOfScalarPos(u8, content, name_start + name.len, '=') orelse continue;
        const semi_idx = std.mem.indexOfScalarPos(u8, content, eq_idx, ';') orelse continue;
        const quote_idx = std.mem.indexOfScalarPos(u8, content, eq_idx, '\'') orelse continue;
        if (quote_idx > semi_idx) continue;
        const value =
            parse_apex_source_single_quoted_literal(alloc, content, quote_idx) orelse continue;
        try append_source_string_constant(alloc, constants, name, value);
        cursor = semi_idx + 1;
    }
}

fn source_constant_name_is_candidate(name: []const u8) bool {
    if (name.len == 0) return false;
    var has_underscore = false;
    var has_alpha = false;
    for (name) |ch| {
        if (ch == '_') {
            has_underscore = true;
            continue;
        }
        if (std.ascii.isAlphabetic(ch)) {
            if (!std.ascii.isUpper(ch)) return false;
            has_alpha = true;
            continue;
        }
        if (!std.ascii.isDigit(ch)) return false;
    }
    return has_underscore and has_alpha;
}

fn parse_apex_source_single_quoted_literal(
    alloc: std.mem.Allocator,
    content: []const u8,
    quote_idx: usize,
) ?[]const u8 {
    if (quote_idx >= content.len or content[quote_idx] != '\'') return null;
    var result = std.ArrayListUnmanaged(u8).empty;
    var idx = quote_idx + 1;
    while (idx < content.len) {
        const ch = content[idx];
        if (ch == '\\' and idx + 1 < content.len) {
            result.append(alloc, content[idx + 1]) catch return null;
            idx += 2;
            continue;
        }
        if (ch == '\'') {
            if (idx + 1 < content.len and content[idx + 1] == '\'') {
                result.append(alloc, '\'') catch return null;
                idx += 2;
                continue;
            }
            return alloc.dupe(u8, result.items) catch null;
        }
        result.append(alloc, ch) catch return null;
        idx += 1;
    }
    return null;
}

fn append_source_string_constant(
    alloc: std.mem.Allocator,
    constants: *std.ArrayListUnmanaged(SourceStringConstant),
    name: []const u8,
    value: []const u8,
) !void {
    for (constants.items) |known| {
        if (std.ascii.eqlIgnoreCase(known.name, name) and
            std.mem.eql(u8, known.value, value))
        {
            return;
        }
    }
    try constants.append(alloc, .{
        .name = try alloc.dupe(u8, name),
        .value = value,
    });
}

fn source_field_ref_is_picklist(
    field_types: *FieldTypesMap,
    field_metadata: *FieldMetadataMap,
    field_ref: SourceFieldRef,
) bool {
    if (lookup_field_type_hint(
        field_types,
        field_ref.object_type,
        field_ref.field_name,
    )) |field_type| {
        if (metadata_field_type_is_picklist(field_type)) return true;
    }
    if (lookup_source_field_metadata(
        field_metadata,
        field_ref.object_type,
        field_ref.field_name,
    )) |metadata| {
        if (metadata.field_type) |field_type| {
            if (metadata_field_type_is_picklist(field_type)) return true;
        }
    }
    return metadata_field_type_is_picklist(
        builtins.infer_field_type_for_object(field_ref.object_type, field_ref.field_name),
    );
}

fn metadata_field_type_is_picklist(field_type: []const u8) bool {
    return std.ascii.eqlIgnoreCase(field_type, "Picklist") or
        std.ascii.eqlIgnoreCase(field_type, "MultiselectPicklist") or
        std.ascii.eqlIgnoreCase(field_type, "MULTIPICKLIST");
}

fn lookup_field_type_hint(
    field_types: *FieldTypesMap,
    object_type: []const u8,
    field_name: []const u8,
) ?[]const u8 {
    const type_fields = field_types.get(object_type) orelse blk: {
        var type_iter = field_types.iterator();
        while (type_iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, object_type)) break :blk entry.value_ptr.*;
        }
        return null;
    };
    if (type_fields.get(field_name)) |field_type| return field_type;
    var field_iter = type_fields.iterator();
    while (field_iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, field_name)) return entry.value_ptr.*;
    }
    return null;
}

fn lookup_source_field_metadata(
    field_metadata: *FieldMetadataMap,
    object_type: []const u8,
    field_name: []const u8,
) ?*evaluator.FieldMetadata {
    const type_meta = field_metadata.getPtr(object_type) orelse blk: {
        var type_iter = field_metadata.iterator();
        while (type_iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, object_type)) break :blk entry.value_ptr;
        }
        return null;
    };
    if (type_meta.getPtr(field_name)) |metadata| return metadata;
    var field_iter = type_meta.iterator();
    while (field_iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, field_name)) return entry.value_ptr;
    }
    return null;
}

fn field_metadata_has_picklist_values(
    field_metadata: *FieldMetadataMap,
    object_type: []const u8,
    field_name: []const u8,
) bool {
    const metadata =
        lookup_source_field_metadata(field_metadata, object_type, field_name) orelse return false;
    return metadata.picklist_values.len > 0;
}

fn source_picklist_constant_prefix(
    alloc: std.mem.Allocator,
    field_name: []const u8,
) ![]const u8 {
    var local = source_simple_api_name(field_name);
    if (source_namespaced_custom_api_name(local)) {
        const namespace_sep = std.mem.indexOf(u8, local, "__").?;
        local = local[namespace_sep + 2 ..];
    }
    if (std.ascii.endsWithIgnoreCase(local, "__c") or
        std.ascii.endsWithIgnoreCase(local, "__r"))
    {
        local = local[0 .. local.len - 3];
    }

    var result = std.ArrayListUnmanaged(u8).empty;
    var prev_was_separator = true;
    var prev_was_lower_or_digit = false;
    for (local) |ch| {
        if (ch == '_') {
            if (!prev_was_separator) {
                try result.append(alloc, '_');
                prev_was_separator = true;
            }
            prev_was_lower_or_digit = false;
            continue;
        }
        if (std.ascii.isUpper(ch) and prev_was_lower_or_digit and !prev_was_separator) {
            try result.append(alloc, '_');
        }
        try result.append(alloc, std.ascii.toUpper(ch));
        prev_was_separator = false;
        prev_was_lower_or_digit = std.ascii.isLower(ch) or std.ascii.isDigit(ch);
    }
    while (result.items.len > 0 and result.items[result.items.len - 1] == '_') {
        _ = result.pop();
    }
    return try alloc.dupe(u8, result.items);
}

fn source_simple_api_name(field_name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, field_name, '.')) |dot| {
        return field_name[dot + 1 ..];
    }
    return field_name;
}

fn source_namespaced_custom_api_name(name: []const u8) bool {
    if (!std.ascii.endsWithIgnoreCase(name, "__c") and
        !std.ascii.endsWithIgnoreCase(name, "__r"))
    {
        return false;
    }
    const namespace_sep = std.mem.indexOf(u8, name, "__") orelse return false;
    return std.mem.indexOf(u8, name[namespace_sep + 2 ..], "__") != null;
}

fn source_constant_matches_field_prefix(
    constant_name: []const u8,
    field_prefix: []const u8,
) bool {
    return constant_name.len > field_prefix.len + 1 and
        std.ascii.startsWithIgnoreCase(constant_name, field_prefix) and
        constant_name[field_prefix.len] == '_';
}

fn append_source_picklist_metadata_value(
    alloc: std.mem.Allocator,
    field_metadata: *FieldMetadataMap,
    object_type: []const u8,
    field_name: []const u8,
    value: []const u8,
) !void {
    const type_key = try normalize_metadata_api_name(alloc, object_type);
    const field_key = try normalize_metadata_api_name(alloc, field_name);
    const type_gop = try field_metadata.getOrPut(alloc, type_key);
    if (!type_gop.found_existing) type_gop.value_ptr.* = .empty;
    const field_gop = try type_gop.value_ptr.getOrPut(alloc, field_key);
    if (!field_gop.found_existing) {
        field_gop.value_ptr.* = .{ .field_type = "Picklist" };
    }
    for (field_gop.value_ptr.picklist_values) |known| {
        if (std.ascii.eqlIgnoreCase(known.value, value)) return;
    }
    const previous = field_gop.value_ptr.picklist_values;
    const next = try alloc.alloc(evaluator.PicklistValueMetadata, previous.len + 1);
    @memcpy(next[0..previous.len], previous);
    next[previous.len] = .{
        .label = value,
        .value = value,
        .is_default = false,
        .is_active = true,
    };
    field_gop.value_ptr.picklist_values = next;
}

fn collect_child_relationship_hints(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    child_relationships: *ChildRelationshipsMap,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.basename, ".layout-meta.xml")) {
            try collect_layout_child_relationship_hints(
                alloc,
                io,
                path,
                entry.path,
                entry.basename,
                child_relationships,
            );
        } else if (std.mem.endsWith(u8, entry.basename, ".quickAction-meta.xml")) {
            try collect_quick_action_child_relationship_hint(
                alloc,
                io,
                path,
                entry.path,
                entry.basename,
                child_relationships,
            );
        }
    }
}

fn collect_layout_child_relationship_hints(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    entry_path: []const u8,
    basename: []const u8,
    child_relationships: *ChildRelationshipsMap,
) !void {
    const parent_type = layout_parent_type_from_basename(basename) orelse return;
    const full_path = try std.fs.path.join(alloc, &.{ base_path, entry_path });
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        alloc,
        .limited(512 * 1024),
    ) catch return;

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, "<relatedList>")) |start_idx| {
        const value_start = start_idx + "<relatedList>".len;
        const end_idx = std.mem.indexOfPos(u8, content, value_start, "</relatedList>") orelse break;
        cursor = end_idx + "</relatedList>".len;
        const value = std.mem.trim(u8, content[value_start..end_idx], " \t\r\n");
        const dot = std.mem.indexOfScalar(u8, value, '.') orelse continue;
        const child_type = std.mem.trim(u8, value[0..dot], " \t\r\n");
        const fk_field = std.mem.trim(u8, value[dot + 1 ..], " \t\r\n");
        try put_custom_child_relationship_hint(
            alloc,
            child_relationships,
            parent_type,
            child_type,
            fk_field,
        );
    }
}

fn collect_quick_action_child_relationship_hint(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    entry_path: []const u8,
    basename: []const u8,
    child_relationships: *ChildRelationshipsMap,
) !void {
    const parent_type = quick_action_parent_type_from_basename(basename) orelse return;
    const full_path = try std.fs.path.join(alloc, &.{ base_path, entry_path });
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        alloc,
        .limited(128 * 1024),
    ) catch return;
    const child_type = std.mem.trim(
        u8,
        extract_xml_tag_value(content, "targetObject") orelse return,
        " \t\r\n",
    );
    const fk_field = std.mem.trim(
        u8,
        extract_xml_tag_value(content, "targetParentField") orelse return,
        " \t\r\n",
    );
    try put_custom_child_relationship_hint(
        alloc,
        child_relationships,
        parent_type,
        child_type,
        fk_field,
    );
}

fn put_custom_child_relationship_hint(
    alloc: std.mem.Allocator,
    child_relationships: *ChildRelationshipsMap,
    parent_type: []const u8,
    child_type: []const u8,
    fk_field: []const u8,
) !void {
    const relationship_name = custom_child_relationship_name_from_type(alloc, child_type) orelse return;
    try put_child_relationship(
        alloc,
        child_relationships,
        parent_type,
        relationship_name,
        child_type,
        fk_field,
    );
}

fn custom_child_relationship_name_from_type(
    alloc: std.mem.Allocator,
    child_type: []const u8,
) ?[]const u8 {
    if (!std.ascii.endsWithIgnoreCase(child_type, "__c")) return null;
    return std.fmt.allocPrint(
        alloc,
        "{s}__r",
        .{child_type[0 .. child_type.len - "__c".len]},
    ) catch null;
}

fn layout_parent_type_from_basename(basename: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, basename, ".layout-meta.xml")) return null;
    const stem = basename[0 .. basename.len - ".layout-meta.xml".len];
    const dash = std.mem.indexOfScalar(u8, stem, '-') orelse return null;
    if (dash == 0) return null;
    return stem[0..dash];
}

fn quick_action_parent_type_from_basename(basename: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, basename, ".quickAction-meta.xml")) return null;
    const stem = basename[0 .. basename.len - ".quickAction-meta.xml".len];
    const dot = std.mem.indexOfScalar(u8, stem, '.') orelse return null;
    if (dot == 0) return null;
    return stem[0..dot];
}

/// object-meta.xml を走査し `<customSettingsType>` が含まれる SObject 名と種別を集める。
/// パス構造: .../objects/<TypeName>/<TypeName>.object-meta.xml
fn collect_custom_setting_types(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    custom_setting_types: *CustomSettingTypesMap,
    custom_setting_kinds: *CustomSettingKindsMap,
    object_labels: *ObjectLabelsMap,
    object_label_plurals: *ObjectLabelsMap,
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
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            alloc,
            .limited(256 * 1024),
        ) catch continue;

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

fn split_namespaced_metadata_name(
    name: []const u8,
) struct { namespace: []const u8, local_name: []const u8 } {
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
    field_sets: *FieldSetsMap,
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
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            alloc,
            .limited(128 * 1024),
        ) catch continue;

        const field_set_name_end = entry.basename.len - field_set_meta_xml_suffix.len;
        var full_name: []const u8 = entry.basename[0..field_set_name_end];
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

        const members = try collect_field_set_members(alloc, content);

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
            .members = alloc.dupe(
                evaluator.FieldSetMemberMetadata,
                members.items,
            ) catch continue,
        }) catch {};
    }
}

const field_set_meta_xml_suffix = ".fieldSet-meta.xml";

fn collect_field_set_members(
    alloc: std.mem.Allocator,
    content: []const u8,
) !std.ArrayListUnmanaged(evaluator.FieldSetMemberMetadata) {
    var members = std.ArrayListUnmanaged(evaluator.FieldSetMemberMetadata).empty;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(
        u8,
        content,
        search_start,
        "<displayedFields>",
    )) |block_start_idx| {
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
        const field_end = std.mem.indexOfPos(
            u8,
            block,
            field_start,
            "</field>",
        ) orelse {
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
    return members;
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
    // Strip surrounding Apex string literal quotes in metadata.
    if (strip_outer_quotes and
        decoded.len >= 2 and
        ((decoded[0] == '\'' and decoded[decoded.len - 1] == '\'') or
            (decoded[0] == '"' and decoded[decoded.len - 1] == '"')))
    {
        return alloc.dupe(u8, decoded[1 .. decoded.len - 1]);
    }
    return alloc.dupe(u8, decoded);
}

fn decode_xml_default_value(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return decode_xml_text(alloc, raw, true);
}

test "metadata default value strips XML-encoded string literal quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const single = try decode_xml_default_value(alloc, "&apos;Default&apos;");
    try std.testing.expectEqualStrings("Default", single);

    const double = try decode_xml_default_value(alloc, "&quot;Do Not Match&quot;");
    try std.testing.expectEqualStrings("Do Not Match", double);
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
    try write_parent_summary_fields_fixture(dir);
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

fn write_numeric_child_relationship_metadata_fixture(dir: anytype) !void {
    const tio = std.testing.io;
    try dir.createDirPath(tio, "objects/Child__c/fields");
    try dir.writeFile(tio, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>apTasks1</relationshipName>
        \\    <type>Lookup</type>
        \\</CustomField>
        ,
    });
}

fn write_activity_lookup_metadata_fixture(dir: anytype) !void {
    const tio = std.testing.io;
    try dir.createDirPath(tio, "objects/Activity/fields");
    try dir.writeFile(tio, .{
        .sub_path = "objects/Activity/fields/Template__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Template__c</fullName>
        \\    <deleteConstraint>SetNull</deleteConstraint>
        \\    <referenceTo>Template__c</referenceTo>
        \\    <relationshipName>Tasks</relationshipName>
        \\    <type>Lookup</type>
        \\</CustomField>
        ,
    });
}

fn write_activity_task_ap_task_lookup_metadata_fixture(dir: anytype) !void {
    const tio = std.testing.io;
    try dir.createDirPath(tio, "objects/Activity/fields");
    try dir.writeFile(tio, .{
        .sub_path = "objects/Activity/fields/TaskAPTask__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>TaskAPTask__c</fullName>
        \\    <deleteConstraint>SetNull</deleteConstraint>
        \\    <referenceTo>Template__c</referenceTo>
        \\    <relationshipName>Tasks</relationshipName>
        \\    <type>Lookup</type>
        \\</CustomField>
        ,
    });
}

/// Parent__c の rollup summary フィールド 3 つ (Open/Closed/Total) を書き出す。
/// `write_generic_rollup_metadata_fixture` が長すぎるので分離した。
fn write_parent_summary_fields_fixture(dir: anytype) !void {
    const tio = std.testing.io;
    try dir.writeFile(tio, .{
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
    try dir.writeFile(tio, .{
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
    try dir.writeFile(tio, .{
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

fn write_generic_list_custom_setting_fixture(dir: anytype) !void {
    try dir.createDirPath(std.testing.io, "objects/ListSettings__c/fields");
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/ListSettings__c/ListSettings__c.object-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <customSettingsType>List</customSettingsType>
        \\    <label>List Settings</label>
        \\    <visibility>Public</visibility>
        \\</CustomObject>
        ,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "objects/ListSettings__c/fields/Flag__c.field-meta.xml",
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
        \\    <defaultValue>&apos;default&apos;</defaultValue>
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
    try std.testing.expect(is_test_method(md));
}

// ---------------------------------------------------------------------------
// E2E テスト
// ---------------------------------------------------------------------------

fn run_entry(source: []const u8, entry_class: []const u8, entry_method: []const u8) !Result {
    return run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = entry_class,
        .entry_method = entry_method,
    });
}

fn run_entry_with_options(
    source: []const u8,
    entry_class: []const u8,
    entry_method: []const u8,
    opts: Options,
) !Result {
    var run_opts = opts;
    run_opts.entry_class = entry_class;
    run_opts.entry_method = entry_method;
    return run(std.testing.allocator, std.testing.io, source, run_opts);
}

fn expect_entry_string(
    source: []const u8,
    entry_class: []const u8,
    entry_method: []const u8,
    expected: []const u8,
) !void {
    const result = try run_entry(source, entry_class, entry_method);
    defer result.deinit();

    try std.testing.expectEqualStrings(expected, result.value.string);
}

fn expect_entry_string_with_options(
    source: []const u8,
    entry_class: []const u8,
    entry_method: []const u8,
    expected: []const u8,
    opts: Options,
) !void {
    const result = try run_entry_with_options(source, entry_class, entry_method, opts);
    defer result.deinit();

    try std.testing.expectEqualStrings(expected, result.value.string);
}

fn expect_entry_integer(
    source: []const u8,
    entry_class: []const u8,
    entry_method: []const u8,
    expected: i64,
) !void {
    const result = try run_entry(source, entry_class, entry_method);
    defer result.deinit();

    try std.testing.expectEqual(expected, result.value.integer);
}

fn expect_entry_boolean(
    source: []const u8,
    entry_class: []const u8,
    entry_method: []const u8,
    expected: bool,
) !void {
    const result = try run_entry(source, entry_class, entry_method);
    defer result.deinit();

    try std.testing.expectEqual(expected, result.value.boolean);
}

fn expect_entry_stdout(
    source: []const u8,
    entry_class: []const u8,
    entry_method: []const u8,
    expected: []const u8,
) !void {
    const result = try run_entry(source, entry_class, entry_method);
    defer result.deinit();

    try std.testing.expectEqualStrings(expected, result.stdout);
}

test "E2E: simple static method returns string" {
    const source =
        \\public class Hello {
        \\    public static String greet() {
        \\        return 'world';
        \\    }
        \\}
    ;
    try expect_entry_string(source, "Hello", "greet", "world");
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
    try expect_entry_integer(source, "Calc", "compute", 13);
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
    try expect_entry_integer(source, "Branch", "max", 10);
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
    try expect_entry_integer(source, "Loops", "factorial", 120);
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
    try expect_entry_string(source, "Str", "build", "count=42");
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
    try expect_entry_integer(source, "Multi", "main", 14);
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
    try expect_entry_integer(source, "InstanceofTest", "test", 111);
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
    try expect_entry_string(source, "RegexTest", "test", "2:123:456:user:host");
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
    try expect_entry_string(source, "MatcherFullMatchProbe", "run", "true|false");
}

test "E2E: Matcher exposes start/end/groupCount for static string inputs" {
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
        \\            + String.valueOf(matcher.groupCount())
        \\            + ':'
        \\            + matcher.group(0)
        \\            + ':'
        \\            + matcher.group(1);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MatcherSpanProbe", "run", "2:4:1:aa:aa");
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
    try expect_entry_string(source, "ChildRelationshipProbe", "run", "Contacts");
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
    try expect_entry_boolean(source, "ChildRelationshipFieldMapProbe", "run", true);
}

test "E2E: Contact describe fields expose LastName token at runtime" {
    const source =
        \\public class ContactDescribeFieldsProbe {
        \\    public static String run() {
        \\        Map<String, Schema.SObjectField> fields = Contact.SObjectType.getDescribe().fields.getMap();
        \\        String fieldName = String.valueOf(Contact.LastName);
        \\        Schema.SObjectField lastNameField = fields.get(fieldName);
        \\        Schema.DescribeFieldResult describe = lastNameField.getDescribe();
        \\        return String.valueOf(lastNameField != null) +
        \\            ':' + String.valueOf(lastNameField) +
        \\            ':' + describe.getName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ContactDescribeFieldsProbe", "run", "true:LastName:LastName");
}

test "E2E: Contact other address fields are valid SObject fields" {
    const source =
        \\public class ContactOtherAddressFieldsProbe {
        \\    public static String run() {
        \\        Contact contact = new Contact(LastName = 'A');
        \\        contact.OtherStreet = '1 Main';
        \\        contact.OtherCity = 'Oakland';
        \\        contact.OtherState = 'CA';
        \\        contact.OtherPostalCode = '94612';
        \\        contact.OtherCountry = 'US';
        \\        return String.valueOf(contact.get('OtherStreet')) + ':' +
        \\            Contact.SObjectType.getDescribe().fields.getMap()
        \\                .containsKey('OtherPostalCode');
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ContactOtherAddressFieldsProbe", "run", "1 Main:true");
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
    try expect_entry_string(source, "ChildRelationshipListProbe", "run", "Contacts");
}

test "E2E: JSON parser tokens can be streamed into a generator" {
    const source =
        \\public class JsonStreamingProbe {
        \\    public static String run() {
        \\        JSONParser parser = JSON.createParser(
        \\            '[{"Name":"Acme","Count":2,"Flag":true,"Missing":null}]'
        \\        );
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
        \\                when VALUE_STRING, VALUE_FALSE, VALUE_TRUE,
        \\                     VALUE_NUMBER_FLOAT, VALUE_NUMBER_INT {
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
        \\    private static void streamTokens(
        \\        JSONParser fromStream,
        \\        JSONGenerator toStream,
        \\        ParserEvents events
        \\    ) {
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
    try expect_entry_string(
        source,
        "JsonInjectedRelationshipProbe",
        "run",
        "2:2:003000000000001AAA",
    );
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
        \\    private static void streamTokens(
        \\        JSONParser fromStream,
        \\        JSONGenerator toStream,
        \\        ParserEvents events
        \\    ) {
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

    try std.testing.expectEqualStrings(
        "[{\"attributes\":{\"type\":\"Account\"}," ++
            "\"Id\":\"001000000000001AAA\"," ++
            "\"Name\":\"Acme\"," ++
            "\"NumberOfEmployees\":\"7\"," ++
            "\"Contacts\":{\"totalSize\":2,\"done\":true,\"records\":[" ++
            "{\"attributes\":{\"type\":\"Contact\"}," ++
            "\"Id\":\"003000000000001AAA\",\"DoNotCall\":\"true\"}," ++
            "{\"attributes\":{\"type\":\"Contact\"}," ++
            "\"Id\":\"003000000000002AAA\",\"DoNotCall\":\"false\"}]}}]",
        result.value.string,
    );
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
    try expect_entry_string(source, "DelegatingSetterProbe", "run", "delegated");
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
    try expect_entry_string(source, "DateTest", "test", "true:true");
}

test "E2E: System.now date matches System.today" {
    const source =
        \\public class SystemNowTest {
        \\    public static String test() {
        \\        return String.valueOf(System.now().date() == System.today());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SystemNowTest", "test", "true");
}

test "E2E: System clock values are monotonic and expose epoch millis" {
    const source =
        \\public class SystemClockProbe {
        \\    public static String test() {
        \\        Long first = System.currentTimeMillis();
        \\        Long second = System.currentTimeMillis();
        \\        Long nowMs = System.now().getTime();
        \\        return String.valueOf(second > first) + ':' + String.valueOf(nowMs > 0);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SystemClockProbe", "test", "true:true");
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
    try expect_entry_string(source, "UnknownObjTest", "test", "caught");
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
    try expect_entry_string(source, "CacheTest", "test", "1:true");
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
    try expect_entry_string(source, "InnerCacheBuilderTest", "test", "loaded:demo:true:true");
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
    try expect_entry_string(source, "CacheBuilderOwner", "test", "loaded:demo:true");
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
    try expect_entry_string(source, "CachedOrgAccessor", "test", "true:1");
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
    try expect_entry_string(source, "CacheAvailabilityTest", "test", "true:true");
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
    try expect_entry_string(
        source,
        "FlowMetadataQueryTest",
        "test",
        "MockLogBatchPurgerPlugin:true:true",
    );
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
    try expect_entry_string(source, "StaticFlowBindTest", "test", "LogEntryHandler_Tests_Flow");
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
    try expect_entry_string(source, "FlowSelectorTest", "test", "1:1");
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
    try expect_entry_string(source, "FlowDefinitionViewMissingTest", "test", "0");
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
        \\        Flow.Interview interview = Flow.Interview.createInterview(
        \\            'MockLogBatchPurgerPlugin',
        \\            inputs
        \\        );
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
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'perm@example.com',
        \\            Email = 'perm@example.com',
        \\            Alias = 'pusr'
        \\        );
        \\        insert u;
        \\        PermissionSet ps = new PermissionSet(
        \\            Name = 'CustomPermissionEnabled',
        \\            Label = 'Custom Permission Enabled'
        \\        );
        \\        insert ps;
        \\        SetupEntityAccess sea = new SetupEntityAccess(
        \\            ParentId = ps.Id,
        \\            SetupEntityId = [
        \\                SELECT Id
        \\                FROM CustomPermission
        \\                WHERE DeveloperName = 'CanModifyLoggerSettings'
        \\            ].Id
        \\        );
        \\        PermissionSetAssignment psa = new PermissionSetAssignment(
        \\            AssigneeId = u.Id,
        \\            PermissionSetId = ps.Id
        \\        );
        \\        insert new List<SObject>{ sea, psa };
        \\        Boolean hasPermission = false;
        \\        System.runAs(u) {
        \\            hasPermission = System.FeatureManagement.checkPermission(
        \\                'CanModifyLoggerSettings'
        \\            );
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

test "E2E: PermissionSet dynamic permission fields are queryable" {
    const source =
        \\public class PermissionSetDynamicFieldsTest {
        \\    public static Integer test() {
        \\        Map<String, SObjectField> fields =
        \\            PermissionSet.getSObjectType().getDescribe().fields.getMap();
        \\        PermissionSet ps = new PermissionSet(Name = 'DynPerms', Label = 'DynPerms');
        \\        if (fields.containsKey('PermissionsCustomizeApplication')) {
        \\            ps.put('PermissionsCustomizeApplication', true);
        \\        }
        \\        if (fields.containsKey('PermissionsModifyAllData')) {
        \\            ps.put('PermissionsModifyAllData', true);
        \\        }
        \\        if (fields.containsKey('PermissionsAuthorApex')) {
        \\            ps.put('PermissionsAuthorApex', true);
        \\        }
        \\        insert ps;
        \\        return [
        \\            SELECT Id
        \\            FROM PermissionSet
        \\            WHERE PermissionsCustomizeApplication = TRUE
        \\            AND PermissionsModifyAllData = TRUE
        \\            AND PermissionsAuthorApex = TRUE
        \\        ].size();
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "PermissionSetDynamicFieldsTest", "test", 1);
}

test "E2E: PermissionSetAssignment matches admin permission subquery" {
    const source =
        \\public class PermissionSetAssignmentAdminSubqueryTest {
        \\    public static Integer test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'psa@example.com',
        \\            Email = 'psa@example.com',
        \\            Alias = 'psau'
        \\        );
        \\        insert u;
        \\        PermissionSet ps = new PermissionSet(
        \\            Name = 'AdminPerms',
        \\            Label = 'AdminPerms'
        \\        );
        \\        ps.put('PermissionsCustomizeApplication', true);
        \\        ps.put('PermissionsModifyAllData', true);
        \\        ps.put('PermissionsAuthorApex', true);
        \\        insert ps;
        \\        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        \\        return [
        \\            SELECT Id
        \\            FROM PermissionSetAssignment
        \\            WHERE AssigneeId IN :new List<User>{ u }
        \\            AND PermissionSetId IN (
        \\                SELECT Id
        \\                FROM PermissionSet
        \\                WHERE PermissionsCustomizeApplication = TRUE
        \\                AND PermissionsModifyAllData = TRUE
        \\                AND PermissionsAuthorApex = TRUE
        \\            )
        \\        ].size();
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "PermissionSetAssignmentAdminSubqueryTest", "test", 1);
}

test "E2E: runAs assigns an id to an uninserted user for later setup DML" {
    const source =
        \\public class RunAsUninsertedUserIdTest {
        \\    public static Boolean test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'runas.id@example.com',
        \\            Email = 'runas.id@example.com',
        \\            Alias = 'ruid'
        \\        );
        \\        System.runAs(u) {}
        \\        PermissionSet ps = new PermissionSet(Name = 'RunAsPerms', Label = 'RunAsPerms');
        \\        ps.put('PermissionsCustomizeApplication', true);
        \\        ps.put('PermissionsModifyAllData', true);
        \\        ps.put('PermissionsAuthorApex', true);
        \\        insert ps;
        \\        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        \\        return [
        \\            SELECT Id
        \\            FROM PermissionSetAssignment
        \\            WHERE AssigneeId = :u.Id
        \\        ].size() == 1;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RunAsUninsertedUserIdTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: profile-owned PermissionSet no-access query drives runAs CRUD" {
    const source =
        \\public class ProfileOwnedNoAccessPermissionSetTest {
        \\    public static Boolean test() {
        \\        PermissionSet ps =
        \\            [SELECT Profile.Id, Profile.Name
        \\             FROM PermissionSet
        \\             WHERE IsOwnedByProfile = true
        \\             AND Profile.UserType = 'Standard'
        \\             AND Id NOT IN (SELECT ParentId
        \\                            FROM ObjectPermissions
        \\                            WHERE SObjectType = 'Account'
        \\                            AND PermissionsRead = true)
        \\             LIMIT 1];
        \\        User u = new User(
        \\            ProfileId = ps.Profile.Id,
        \\            LastName = 'NoAccess',
        \\            Username = 'noaccess@example.com',
        \\            Email = 'noaccess@example.com',
        \\            Alias = 'noacc'
        \\        );
        \\        insert u;
        \\        Boolean objectReadable = true;
        \\        Boolean fieldReadable = true;
        \\        System.runAs(u) {
        \\            objectReadable = Account.SObjectType.getDescribe().isAccessible();
        \\            fieldReadable = Account.AnnualRevenue.getDescribe().isAccessible();
        \\        }
        \\        return ps.Profile.Name == 'Minimum Access - Salesforce' &&
        \\            objectReadable == false &&
        \\            fieldReadable == false;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ProfileOwnedNoAccessPermissionSetTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: instance field assignment updates existing field case-insensitively" {
    const source =
        \\public class CaseInsensitiveInstanceFieldAssignmentTest {
        \\    private String m_value = 'old';
        \\    public CaseInsensitiveInstanceFieldAssignmentTest() {
        \\        m_Value = 'new';
        \\    }
        \\    public String getValue() {
        \\        return m_value;
        \\    }
        \\    public static String test() {
        \\        return new CaseInsensitiveInstanceFieldAssignmentTest().getValue();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "CaseInsensitiveInstanceFieldAssignmentTest", "test", "new");
}

test "E2E: local variables do not update same-named instance fields case-insensitively" {
    const source =
        \\public class LocalVariableFieldShadowTest {
        \\    public Integer TargetLineNumber { get; private set; }
        \\    public LocalVariableFieldShadowTest() {
        \\        this.TargetLineNumber = 5;
        \\        for (Integer targetLineNumber = 1; targetLineNumber <= 10; targetLineNumber++) {
        \\        }
        \\    }
        \\    public static Integer test() {
        \\        return new LocalVariableFieldShadowTest().TargetLineNumber;
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "LocalVariableFieldShadowTest", "test", 5);
}

test "E2E: missing FormulaFilter class passes records through when no entry criteria exists" {
    const source =
        \\public class MissingFormulaFilterFallbackTest {
        \\    public static Integer test() {
        \\        List<Account> records = new List<Account>{ new Account(Name = 'A') };
        \\        Object filter = new FormulaFilter(null, null, 'Account');
        \\        Object result = filter.filterByEntryCriteria(records, null);
        \\        return ((List<SObject>) result.triggerNew).size();
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "MissingFormulaFilterFallbackTest", "test", 1);
}

test "E2E: CaseComment describe does not expose implicit Name field" {
    const source =
        \\public class CaseCommentDescribeNameTest {
        \\    public static Boolean test() {
        \\        Map<String, Schema.SObjectField> fields =
        \\            CaseComment.SObjectType.getDescribe().fields.getMap();
        \\        return !fields.containsKey('Name') &&
        \\            fields.containsKey('CreatedDate') &&
        \\            fields.containsKey('CommentBody');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CaseCommentDescribeNameTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: ListEmail SObjectType resolves standard child relationship" {
    const source =
        \\public class ListEmailSObjectTypeTest {
        \\    public static Boolean test() {
        \\        Schema.SObjectType listEmailType = ListEmail.SObjectType;
        \\        Boolean found = false;
        \\        if (Schema.getGlobalDescribe().get('ListEmail') != listEmailType) {
        \\            return false;
        \\        }
        \\        for (Schema.ChildRelationship rel :
        \\            Opportunity.SObjectType.getDescribe().getChildRelationships()) {
        \\            if (rel.getChildSObject() == listEmailType &&
        \\                rel.getRelationshipName() == 'ListEmails') {
        \\                found = true;
        \\            }
        \\        }
        \\        return found;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ListEmailSObjectTypeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: standard Contact and AccountShare describe fields are available" {
    const source =
        \\public class StandardDescribeCoverageTest {
        \\    public static Boolean test() {
        \\        Map<String, Schema.SObjectField> contactFields =
        \\            Contact.SObjectType.getDescribe().fields.getMap();
        \\        Map<String, Schema.SObjectField> shareFields =
        \\            AccountShare.SObjectType.getDescribe().fields.getMap();
        \\        return contactFields.get('DoNotCall') == Contact.DoNotCall &&
        \\            Schema.getGlobalDescribe().get('AccountShare') == AccountShare.SObjectType &&
        \\            shareFields.get('AccountId') == AccountShare.AccountId &&
        \\            shareFields.get('UserOrGroupId') == AccountShare.UserOrGroupId &&
        \\            shareFields.get('AccountAccessLevel') == AccountShare.AccountAccessLevel &&
        \\            shareFields.get('RowCause') == AccountShare.RowCause;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StandardDescribeCoverageTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: insert audit fields use current runAs user" {
    const source =
        \\public class InsertAuditRunAsUserTest {
        \\    public static Boolean test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Audit',
        \\            Username = 'audit@example.com',
        \\            Email = 'audit@example.com',
        \\            Alias = 'aud'
        \\        );
        \\        insert u;
        \\        System.runAs(u) {
        \\            insert new Account(Name = 'Audit Account');
        \\        }
        \\        Account a = [SELECT CreatedById, LastModifiedById FROM Account LIMIT 1];
        \\        return a.CreatedById == u.Id && a.LastModifiedById == u.Id;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InsertAuditRunAsUserTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(true, result.value.boolean);
}

test "E2E: uninserted standard runAs user remains standard when queried" {
    const source =
        \\public class RunAsUninsertedStandardQueryTest {
        \\    public static String test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'runas.standard@example.com',
        \\            Email = 'runas.standard@example.com',
        \\            Alias = 'rstd'
        \\        );
        \\        String profileName = null;
        \\        System.runAs(u) {
        \\            profileName = [
        \\                SELECT Profile.Name
        \\                FROM User
        \\                WHERE Id = :UserInfo.getUserId()
        \\            ].Profile.Name;
        \\        }
        \\        return profileName;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "RunAsUninsertedStandardQueryTest", "test", "Standard User");
}

test "E2E: standard user custom object describe is not updateable by default" {
    const source =
        \\public class StandardUserCrudTest {
        \\    public static Boolean test() {
        \\        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User'];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'crud@example.com',
        \\            Email = 'crud@example.com',
        \\            Alias = 'cusr'
        \\        );
        \\        insert u;
        \\        Boolean canUpdate = true;
        \\        System.runAs(u) {
        \\            canUpdate = Schema.LoggerSettings__c.SObjectType
        \\                .getDescribe()
        \\                .isUpdateable();
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
        \\        Schema.User u = new Schema.User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'schema-crud@example.com',
        \\            Email = 'schema-crud@example.com',
        \\            Alias = 'sqru'
        \\        );
        \\        insert u;
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = String.valueOf(
        \\                Schema.LoggerSettings__c.SObjectType.getDescribe().isUpdateable()
        \\            ) + ':' + String.valueOf(
        \\                System.FeatureManagement.checkPermission('CanModifyLoggerSettings')
        \\            );
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SchemaQualifiedCrudTest", "test", "false:false");
}

test "E2E: Profile Name IN query preserves standard-user CRUD restrictions in runAs" {
    const source =
        \\public class ProfileInCrudTest {
        \\    public static String test() {
        \\        Profile p = [
        \\            SELECT Id
        \\            FROM Profile
        \\            WHERE Name IN ('Standard User', 'Usuario estándar', '標準ユーザー')
        \\        ];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'profile-in@example.com',
        \\            Email = 'profile-in@example.com',
        \\            Alias = 'pin'
        \\        );
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = String.valueOf(
        \\                Schema.LoggerSettings__c.SObjectType.getDescribe().isUpdateable()
        \\            ) + ':' + String.valueOf(
        \\                Schema.Log__c.SObjectType.getDescribe().isDeletable()
        \\            );
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ProfileInCrudTest", "test", "false:false");
}

test "E2E: Profile Name bind query preserves read-only delete restrictions in runAs" {
    const source =
        \\public class ProfileBindReadOnlyCrudTest {
        \\    public static String test() {
        \\        String profileName = 'Read Only';
        \\        User u = [
        \\            SELECT Id
        \\            FROM User
        \\            WHERE Profile.Name = :profileName
        \\            AND IsActive = TRUE
        \\            LIMIT 1
        \\        ];
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = String.valueOf(
        \\                Contact.SObjectType.getDescribe().isDeletable()
        \\            );
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ProfileBindReadOnlyCrudTest", "test", "false");
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
        \\        List<Profile> matches = [
        \\            SELECT Id, Name, UserLicense.Name
        \\            FROM Profile
        \\            WHERE Name LIKE :wrappedSearch
        \\        ];
        \\        return String.valueOf(noMatches.size()) +
        \\            ':' + matches.get(0).Name +
        \\            ':' + matches.get(0).UserLicense.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "ProfileLikeSearchTest",
        "test",
        "0:System Administrator:Salesforce",
    );
}

test "E2E: synthetic Profile query honors permission flag predicates" {
    const source =
        \\public class ProfilePermissionPredicateTest {
        \\    public static String test() {
        \\        Profile p = [
        \\            SELECT
        \\                Id,
        \\                Name,
        \\                PermissionsPrivacyDataAccess,
        \\                PermissionsSubmitMacrosAllowed,
        \\                PermissionsMassInlineEdit
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
    try expect_entry_string(
        source,
        "ProfilePermissionPredicateTest",
        "test",
        "System Administrator:false:true:true",
    );
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
        \\        return String.valueOf(rows.size()) +
        \\            ':' + rows[0].CommunityNickname +
        \\            ':' + String.valueOf(u.Id != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UserCommunityNicknameTest", "test", "1:fixture-nick:true");
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
    try expect_entry_string(source, "StaticBindProbe", "test", "missing-user@example.com:0:none");
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
    try expect_entry_string(source, "StaticConstantProbe", "test", "missing-user@example.com");
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
    try expect_entry_string(source, "UserLikeSearchTest", "test", "Test User:testuser@example.com");
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
    try expect_entry_string(
        source,
        "StripInaccessibleIdTest",
        "test",
        "1:001000000000001AAA:updated",
    );
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
    try expect_entry_string(source, "SecurityShadowTest", "test", "shadow:ok");
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
    try expect_entry_boolean(source, "ReadableNullFieldStripTest", "test", true);
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
        \\        Thing__c record = new Thing__c(
        \\            Id = 'a00000000000001AAA',
        \\            Name = 'Example',
        \\            Detail__c = 'secret'
        \\        );
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
    try expect_entry_boolean(source, "PermissionSetGroupExpansionTest", "test", true);
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
    try expect_entry_boolean(source, "DescribeSObjectsUpdatableFieldsTest", "test", true);
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
        \\        insert new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'StoreUser',
        \\            Username = 'store-user@example.com',
        \\            Email = 'store-user@example.com',
        \\            Alias = 'stor'
        \\        );
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
        \\            result = UserInfo.getUsername() +
        \\                ':' + UserInfo.getFirstName() +
        \\                ':' + UserInfo.getLastName() +
        \\                ':' + UserInfo.getTimeZone().getId();
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
        \\        insert new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'Other',
        \\            Username = 'other.user@example.com',
        \\            Email = 'other.user@example.com',
        \\            Alias = 'othr'
        \\        );
        \\        User currentUser = [
        \\            SELECT Id, Username
        \\            FROM User
        \\            WHERE Username = :UserInfo.getUsername()
        \\        ];
        \\        return currentUser.Id + ':' + currentUser.Username;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "CurrentUserUsernameQueryTest",
        "test",
        "005000000000001:testuser@example.com",
    );
}

test "E2E: User query by UserInfo username resolves seeded current user" {
    const source =
        \\public class SeededCurrentUserUsernameQueryTest {
        \\    public static String test() {
        \\        User currentUser = [
        \\            SELECT Id, Username
        \\            FROM User
        \\            WHERE Username = :UserInfo.getUsername()
        \\        ];
        \\        return currentUser.Id + ':' + currentUser.Username;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "SeededCurrentUserUsernameQueryTest",
        "test",
        "005000000000001:testuser@example.com",
    );
}

test "E2E: runAs can query the original current user by username" {
    const source =
        \\public class RunAsCurrentUserQueryTest {
        \\    public static String test() {
        \\        String originalUsername = UserInfo.getUsername();
        \\        User autoproc = [SELECT Id FROM User WHERE Alias = 'autoproc'];
        \\        String result = '';
        \\        System.runAs(new User(Id = autoproc.Id)) {
        \\            User originalUser = [
        \\                SELECT Id, Username
        \\                FROM User
        \\                WHERE Username = :originalUsername
        \\            ];
        \\            result = originalUser.Id + ':' + originalUser.Username;
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "RunAsCurrentUserQueryTest",
        "test",
        "005000000000001:testuser@example.com",
    );
}

test "E2E: standard user cannot access AccountBrand describe fields" {
    const source =
        \\public class AccountBrandAccessTest {
        \\    public static String test() {
        \\        Profile p = [
        \\            SELECT Id
        \\            FROM Profile
        \\            WHERE Name IN ('Standard User', 'Usuario estándar', '標準ユーザー')
        \\        ];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'accountbrand@example.com',
        \\            Email = 'accountbrand@example.com',
        \\            Alias = 'abrd'
        \\        );
        \\        String result = '';
        \\        System.runAs(u) {
        \\            result = String.valueOf(
        \\                Schema.AccountBrand.SObjectType.getDescribe().isAccessible()
        \\            ) + ':' + String.valueOf(
        \\                Schema.AccountBrand.CompanyName.getDescribe().isAccessible()
        \\            ) + ':' + String.valueOf(
        \\                Schema.AccountBrand.Name.getDescribe().isAccessible()
        \\            );
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AccountBrandAccessTest", "test", "false:false:false");
}

test "E2E: standard user cannot access custom fields without permission sets" {
    const source =
        \\public class StandardUserCustomFieldDescribeProbe {
        \\    public static String test() {
        \\        Profile p = [
        \\            SELECT Id
        \\            FROM Profile
        \\            WHERE Name = 'Standard User'
        \\            LIMIT 1
        \\        ];
        \\        User u = new User(
        \\            ProfileId = p.Id,
        \\            LastName = 'User',
        \\            Username = 'customfield@example.com',
        \\            Email = 'customfield@example.com',
        \\            Alias = 'cfield'
        \\        );
        \\        String result = '';
        \\        System.runAs(u) {
        \\            Schema.DescribeFieldResult customField =
        \\                Contact.npo02__Household_Naming_Order__c.getDescribe();
        \\            Schema.DescribeFieldResult standardField = Contact.LastName.getDescribe();
        \\            result = String.valueOf(customField.isAccessible()) + ':' +
        \\                String.valueOf(customField.isUpdateable()) + ':' +
        \\                String.valueOf(standardField.isAccessible());
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "StandardUserCustomFieldDescribeProbe",
        "test",
        "false:false:true",
    );
}

test "E2E: StaticResource IN clause returns multiple stubs" {
    // Multi-line SOQL like in sample fixture
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
    try expect_entry_string(source, "SRTest", "test", "3");
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
    try expect_entry_string(source, "QTest", "test", "true");
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
    try expect_entry_string(source, "TimeValueClassProbe", "test", "true|3");
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
    try expect_entry_string(source, "SetScaleRoundingProbe", "test", "1.234|1.235");
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
    try expect_entry_string(source, "IsoDateFormatProbe", "test", "1,2020,29,3,197");
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
        \\        return String.valueOf(between) +
        \\            '|' + String.valueOf(pow) +
        \\            '|' + enc +
        \\            '|' + String.valueOf(dt);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "DateMathAndEncodingProbe",
        "test",
        "2|8|Hello+World|2020-01-01T00:00:00Z",
    );
}

test "E2E: Date.toStartOfMonth returns a Date value" {
    const source =
        \\public class DateStartOfMonthProbe {
        \\    public static String test() {
        \\        Date d = Date.newInstance(2021, 2, 27).toStartOfMonth().addMonths(1);
        \\        return String.valueOf(d);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DateStartOfMonthProbe", "test", "2021-03-01");
}

test "E2E: Date addMonths clamps invalid month-end days" {
    const source =
        \\public class DateAddMonthsClampProbe {
        \\    public static String test() {
        \\        Date d1 = Date.newInstance(2000, 8, 31).addMonths(1);
        \\        Date d2 = Date.newInstance(2020, 2, 29).addYears(1);
        \\        return String.valueOf(d1) + '|' + String.valueOf(d2);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DateAddMonthsClampProbe", "test", "2000-09-30|2021-02-28");
}

test "E2E: Date.daysInMonth accounts for leap years" {
    const source =
        \\public class DateDaysInMonthProbe {
        \\    public static String test() {
        \\        return String.valueOf(Date.daysInMonth(2020, 2)) + '|' +
        \\            String.valueOf(Date.daysInMonth(2021, 2));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DateDaysInMonthProbe", "test", "29|28");
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
        \\        return byType.get(Alpha.class) +
        \\            ',' + byType.get(Beta.class) +
        \\            ',' + String.valueOf(byType.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TypeKeyedMapTest", "test", "alpha,beta,2");
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
    try expect_entry_string(source, "TriggerOperationTypeProbe", "test", "null");
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
        \\        return String.valueOf(a) +
        \\            ':' + String.valueOf(b) +
        \\            ':' + String.valueOf(c) +
        \\            ':' + String.valueOf(d);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "IndexOfFromIndexTest", "test", "0:4:-1:4");
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
    try expect_entry_string(source, "IterableInstanceofTest", "test", "true:true:false");
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
    try expect_entry_string(source, "NestedForEachTest", "test", "a,b,c,d");
}

test "E2E: addError on a detached SObject records the error without throwing" {
    const source =
        \\public class AddErrorAttachTest {
        \\    public static String test() {
        \\        Account a = new Account();
        \\        a.addError('shouldnt throw');
        \\        if (!a.hasErrors()) return 'missed';
        \\        return 'attached:' +
        \\            String.valueOf(a.getErrors().size()) +
        \\            ':' + a.getErrors()[0].getMessage();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AddErrorAttachTest", "test", "attached:1:shouldnt throw");
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
    try expect_entry_string(source, "ShadowedStaticTest", "test", "set-via-static");
}

test "E2E: static field storage is case-insensitive for class qualifiers" {
    const source =
        \\public class StaticCaseStorageProbe {
        \\    public static Account cached;
        \\    public static String test() {
        \\        StaticCaseStorageProbe.cached = new Account(Name = 'upper-write');
        \\        return staticcasestorageprobe.cached.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StaticCaseStorageProbe", "test", "upper-write");
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
    try expect_entry_string(source, "VirtualDispatchTest", "test", "a,b");
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
    try expect_entry_string(source, "AncestorFieldTest", "test", "1");
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
    try expect_entry_string(source, "ExplicitSuperCtorTest", "test", "3");
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
    try expect_entry_string(source, "SuperDispatchTest", "test", "2");
}

test "E2E: enqueueJob executes instance queueable method" {
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
        \\        System.enqueueJob(new InstanceQueueable('queued'));
        \\        return InstanceQueueable.lastMessage;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InstanceQueueableTest", "test", "queued");
}

test "E2E: queueable enqueued after startTest runs at stopTest" {
    const source =
        \\public class DeferredQueueable implements Queueable {
        \\    public static String state = 'initial';
        \\    public void execute(QueueableContext qc) {
        \\        DeferredQueueable.state = 'executed';
        \\    }
        \\}
        \\public class DeferredQueueableTest {
        \\    public static String test() {
        \\        Test.startTest();
        \\        System.enqueueJob(new DeferredQueueable());
        \\        String beforeStop = DeferredQueueable.state;
        \\        Test.stopTest();
        \\        return beforeStop + ':' + DeferredQueueable.state;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DeferredQueueableTest", "test", "initial:executed");
}

test "E2E: Limits.getAsyncCalls tracks enqueued queueables" {
    const source =
        \\public class AsyncLimitQueueable implements Queueable {
        \\    public void execute(QueueableContext qc) {}
        \\}
        \\public class AsyncLimitQueueableTest {
        \\    public static String test() {
        \\        Integer beforeCalls = Limits.getAsyncCalls();
        \\        System.enqueueJob(new AsyncLimitQueueable());
        \\        return String.valueOf(beforeCalls) + ':' + String.valueOf(Limits.getAsyncCalls());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AsyncLimitQueueableTest", "test", "0:1");
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
        \\            System.enqueueJob(new FailingQueueable());
        \\            return 'no-error';
        \\        } catch (System.Exception ex) {
        \\            return ProbeFinalizer.resultName +
        \\                ':' + ProbeFinalizer.exceptionMessage +
        \\                ':' + ex.getMessage();
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "QueueableFinalizerTest",
        "test",
        "UNHANDLED_EXCEPTION:boom:boom",
    );
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
        \\        List<Database.UpsertResult> results = Database.upsert(
        \\            rows,
        \\            Schema.Thing__c.UniqueId__c
        \\        );
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
    try expect_entry_string(
        source,
        "UpsertExternalIdTest",
        "test",
        "false:true:Updated:2:UniqueId__c",
    );
}

test "E2E: Database.upsert with Schema.Id inserts unsaved records" {
    const source =
        \\public class UpsertByIdFieldTest {
        \\    public static String test() {
        \\        Account row = new Account(Name = 'Created via Id token');
        \\        Database.UpsertResult saveResult = Database.upsert(row, Schema.Account.Id);
        \\        return String.valueOf(saveResult.isSuccess()) +
        \\            ':' + String.valueOf(saveResult.isCreated()) +
        \\            ':' + String.valueOf(row.Id != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UpsertByIdFieldTest", "test", "true:true:true");
}

test "E2E: Database.convertLead updates existing contact from lead fields" {
    const source =
        \\public class ConvertLeadExistingContactTest {
        \\    public static String test() {
        \\        Contact con = new Contact(FirstName = 'Existing', LastName = 'Contact');
        \\        insert con;
        \\        Lead lead = new Lead(
        \\            FirstName = 'Lead',
        \\            LastName = 'Person',
        \\            Company = 'Lead Company',
        \\            Street = '123 Native Ld',
        \\            City = 'Bellevue',
        \\            PostalCode = '98005'
        \\        );
        \\        insert lead;
        \\        Database.LeadConvert lc = new Database.LeadConvert();
        \\        lc.setLeadId(lead.Id);
        \\        lc.setContactId(con.Id);
        \\        Database.LeadConvertResult result = Database.convertLead(lc);
        \\        Contact saved = [
        \\            SELECT MailingStreet, MailingCity, MailingPostalCode
        \\            FROM Contact
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(result.isSuccess()) + ':' +
        \\            saved.MailingStreet + ':' + saved.MailingCity + ':' +
        \\            saved.MailingPostalCode;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "ConvertLeadExistingContactTest",
        "test",
        "true:123 Native Ld:Bellevue:98005",
    );
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
        \\        List<Thing__Share> rows = [
        \\            SELECT ParentId, UserOrGroupId, AccessLevel
        \\            FROM Thing__Share
        \\            WHERE ParentId = :parentRecord.Id
        \\        ];
        \\        Thing__Share savedRow = rows[0];
        \\        return String.valueOf(rows.size()) +
        \\            ':' + String.valueOf(savedRow.ParentId == parentRecord.Id) +
        \\            ':' + String.valueOf(savedRow.UserOrGroupId == UserInfo.getUserId());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "CustomShareQueryTest", "test", "1:true:true");
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
    try expect_entry_string(source, "IterTest2", "test", "3");
}

test "E2E: HttpRequest.getHeader returns null for missing header" {
    const source =
        \\public class HttpMissingHeaderProbe {
        \\    public static String test() {
        \\        HttpRequest req = new HttpRequest();
        \\        return req.getHeader('missing') == null ? 'null' : req.getHeader('missing');
        \\    }
        \\}
    ;
    try expect_entry_string(source, "HttpMissingHeaderProbe", "test", "null");
}

test "E2E: HttpRequest.getBody returns empty string when unset" {
    const source =
        \\public class HttpUnsetBodyProbe {
        \\    public static String test() {
        \\        HttpRequest req = new HttpRequest();
        \\        return req.getBody();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "HttpUnsetBodyProbe", "test", "");
}

test "E2E: SOQL parent relationship resolves namespaced custom lookup" {
    const source =
        \\public class NamespacedParentLookupProbe {
        \\    public static String test() {
        \\        pkg__Parent__c parent = new pkg__Parent__c(Name = 'Parent Name');
        \\        insert parent;
        \\        Child__c child = new Child__c(pkg__Parent__c = parent.Id);
        \\        insert child;
        \\        Child__c queried = [
        \\            SELECT pkg__Parent__r.Name
        \\            FROM Child__c
        \\            WHERE Id = :child.Id
        \\        ];
        \\        return queried.pkg__Parent__r.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NamespacedParentLookupProbe", "test", "Parent Name");
}

test "E2E: SOQL parent relationship resolves namespaced managed package-style lookup" {
    const source =
        \\public class NamespacedPackageLookupProbe {
        \\    public static String test() {
        \\        pkg__Form_Template__c template = new pkg__Form_Template__c(Template_JSON__c = 'json');
        \\        insert template;
        \\        DataImportBatch__c batch = new DataImportBatch__c(pkg__Form_Template__c = template.Id);
        \\        insert batch;
        \\        DataImportBatch__c queried = [
        \\            SELECT pkg__Form_Template__r.Template_JSON__c
        \\            FROM DataImportBatch__c
        \\            WHERE Id = :batch.Id
        \\        ];
        \\        return queried.pkg__Form_Template__r.Template_JSON__c;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NamespacedPackageLookupProbe", "test", "json");
}

test "E2E: Type object equality survives getter and interface-style filtering" {
    const source =
        \\public class TypeBindingFilterProbe {
        \\    public interface IBinding {
        \\        Type getInterfaceType();
        \\    }
        \\    public class Binding implements IBinding {
        \\        private Type interfaceType;
        \\        public Binding setInterfaceType(Type value) {
        \\            this.interfaceType = value;
        \\            return this;
        \\        }
        \\        public Type getInterfaceType() {
        \\            return this.interfaceType;
        \\        }
        \\    }
        \\    public class Service {}
        \\    public static String test() {
        \\        List<IBinding> bindings = new List<IBinding>();
        \\        bindings.add(new Binding().setInterfaceType(Service.class));
        \\        Integer matches = 0;
        \\        for (IBinding binding : bindings) {
        \\            if (binding.getInterfaceType() != Service.class) continue;
        \\            matches++;
        \\        }
        \\        return String.valueOf(matches);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TypeBindingFilterProbe", "test", "1");
}

test "E2E: Static resolver retains module bindings before service lookup" {
    const source =
        \\public class StaticResolverProbe {
        \\    public class Binding {
        \\        private Type interfaceType;
        \\        public Binding setInterfaceType(Type value) {
        \\            this.interfaceType = value;
        \\            return this;
        \\        }
        \\        public Type getInterfaceType() {
        \\            return this.interfaceType;
        \\        }
        \\    }
        \\    public class Module {
        \\        private List<Binding> bindings = new List<Binding>();
        \\        public void addBinding(Binding binding) {
        \\            this.bindings.add(binding);
        \\        }
        \\        public List<Binding> getBindings() {
        \\            return this.bindings;
        \\        }
        \\    }
        \\    public class Resolver {
        \\        private List<Module> modules = new List<Module>();
        \\        public Resolver addModule(Module module) {
        \\            this.modules.add(module);
        \\            return this;
        \\        }
        \\        public List<Binding> resolve(Type interfaceType) {
        \\            List<Binding> result = new List<Binding>();
        \\            for (Module module : this.modules) {
        \\                for (Binding binding : module.getBindings()) {
        \\                    if (binding.getInterfaceType() != interfaceType) continue;
        \\                    result.add(binding);
        \\                }
        \\            }
        \\            return result;
        \\        }
        \\    }
        \\    public class ServiceFactory {
        \\        private Resolver resolver;
        \\        public ServiceFactory(Resolver resolver) {
        \\            this.resolver = resolver;
        \\        }
        \\        public Integer count(Type interfaceType) {
        \\            return this.resolver.resolve(interfaceType).size();
        \\        }
        \\    }
        \\    public class Service {}
        \\    private static Resolver bindingResolver = new Resolver();
        \\    private static final ServiceFactory ServiceFactoryInstance =
        \\        new ServiceFactory(bindingResolver);
        \\    public static String test() {
        \\        Module module = new Module();
        \\        module.addBinding(new Binding().setInterfaceType(Service.class));
        \\        bindingResolver.addModule(module);
        \\        return String.valueOf(ServiceFactoryInstance.count(Service.class));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StaticResolverProbe", "test", "1");
}

test "E2E: fflib-style binding resolver chain filters Type and enums" {
    const source =
        \\public class FflibStyleBindingProbe {
        \\    public enum BindingType { Service, Module }
        \\    public enum SharingMode { WithSharing, WithoutSharing }
        \\    public interface IBinding {
        \\        BindingType getBindingType();
        \\        Type getInterfaceType();
        \\        SharingMode getSharingMode();
        \\        Integer getSequence();
        \\        IBinding setBindingType(BindingType value);
        \\        IBinding setInterfaceType(Type value);
        \\        IBinding setSharingMode(SharingMode value);
        \\        IBinding setSequence(Integer value);
        \\    }
        \\    public class Binding implements IBinding, Comparable {
        \\        private BindingType bindingType;
        \\        private Type interfaceType;
        \\        private SharingMode sharingMode;
        \\        private Integer sequence;
        \\        public Integer compareTo(Object other) {
        \\            IBinding rhs = (IBinding) other;
        \\            if (getSequence() == rhs.getSequence()) return 0;
        \\            return getSequence() > rhs.getSequence() ? 1 : -1;
        \\        }
        \\        public BindingType getBindingType() { return this.bindingType; }
        \\        public Type getInterfaceType() { return this.interfaceType; }
        \\        public SharingMode getSharingMode() { return this.sharingMode; }
        \\        public Integer getSequence() { return this.sequence; }
        \\        public IBinding setBindingType(BindingType value) {
        \\            this.bindingType = value;
        \\            return this;
        \\        }
        \\        public IBinding setInterfaceType(Type value) {
        \\            this.interfaceType = value;
        \\            return this;
        \\        }
        \\        public IBinding setSharingMode(SharingMode value) {
        \\            this.sharingMode = value;
        \\            return this;
        \\        }
        \\        public IBinding setSequence(Integer value) {
        \\            this.sequence = value;
        \\            return this;
        \\        }
        \\    }
        \\    public class Bindings {
        \\        private List<IBinding> bindings;
        \\        public Bindings() {}
        \\        public Bindings(List<IBinding> bindings) { this.bindings = bindings; }
        \\        public void addBindings(List<IBinding> bindings) {
        \\            if (null == this.bindings) this.bindings = bindings;
        \\            else this.bindings.addAll(bindings);
        \\        }
        \\        public Bindings selectByType(BindingType bindingType) {
        \\            List<IBinding> result = new List<IBinding>();
        \\            for (IBinding binding : bindings) {
        \\                if (binding.getBindingType() != bindingType) continue;
        \\                result.add(binding);
        \\            }
        \\            return new Bindings(result);
        \\        }
        \\        public Bindings selectByInterfaceType(Type interfaceType) {
        \\            List<IBinding> result = new List<IBinding>();
        \\            for (IBinding binding : bindings) {
        \\                if (binding.getInterfaceType() != interfaceType) continue;
        \\                result.add(binding);
        \\            }
        \\            return new Bindings(result);
        \\        }
        \\        public Bindings selectBySharingMode(SharingMode sharingMode) {
        \\            List<IBinding> result = new List<IBinding>();
        \\            for (IBinding binding : bindings) {
        \\                if (binding.getSharingMode() != sharingMode) continue;
        \\                result.add(binding);
        \\            }
        \\            return new Bindings(result);
        \\        }
        \\        public Bindings selectBySequence(Integer sequence) {
        \\            bindings.sort();
        \\            if (null == sequence) return this;
        \\            return new Bindings(new List<IBinding>());
        \\        }
        \\        public List<IBinding> getBindings() { return this.bindings; }
        \\    }
        \\    public class Module {
        \\        private List<IBinding> bindings;
        \\        public void addBinding(IBinding binding) {
        \\            addBindings(new List<IBinding>{ binding });
        \\        }
        \\        public void addBindings(List<IBinding> bindings) {
        \\            if (null == this.bindings) this.bindings = bindings;
        \\            else this.bindings.addAll(bindings);
        \\        }
        \\        public List<IBinding> getBindings() { return this.bindings; }
        \\        public void init() {
        \\            if (null == this.bindings) this.bindings = new List<IBinding>();
        \\        }
        \\    }
        \\    public class Resolver {
        \\        private List<Module> modules;
        \\        private Bindings bindings;
        \\        private Binding bindingToResolve;
        \\        private Binding target() {
        \\            if (bindingToResolve == null) bindingToResolve = new Binding();
        \\            return bindingToResolve;
        \\        }
        \\        public Resolver addModule(Module bindingModule) {
        \\            if (null == this.modules) this.modules = new List<Module>();
        \\            this.modules.add(bindingModule);
        \\            return this;
        \\        }
        \\        public Resolver byType(BindingType bindingType) {
        \\            target().setBindingType(bindingType);
        \\            return this;
        \\        }
        \\        public Resolver byInterfaceType(Type interfaceType) {
        \\            target().setInterfaceType(interfaceType);
        \\            return this;
        \\        }
        \\        public Resolver bySharingMode(SharingMode sharingMode) {
        \\            target().setSharingMode(sharingMode);
        \\            return this;
        \\        }
        \\        public List<Module> getModules() { return this.modules; }
        \\        public void loadBindings() {
        \\            this.bindings = new Bindings();
        \\            List<IBinding> appBindings = new List<IBinding>();
        \\            for (Module module : getModules()) {
        \\                module.init();
        \\                appBindings.addAll(module.getBindings());
        \\            }
        \\            this.bindings.addBindings(appBindings);
        \\        }
        \\        public List<IBinding> resolve() {
        \\            if (this.bindings == null) loadBindings();
        \\            Bindings resolved = this.bindings
        \\                .selectByType(target().getBindingType())
        \\                .selectByInterfaceType(target().getInterfaceType())
        \\                .selectBySharingMode(target().getSharingMode())
        \\                .selectBySequence(target().getSequence());
        \\            this.bindingToResolve = new Binding();
        \\            return resolved.getBindings();
        \\        }
        \\    }
        \\    public class Service {}
        \\    private static Resolver bindingResolver = new Resolver();
        \\    public static String test() {
        \\        Module module = new Module();
        \\        module.addBinding(new Binding()
        \\            .setBindingType(BindingType.Service)
        \\            .setInterfaceType(Service.class)
        \\            .setSharingMode(SharingMode.WithSharing)
        \\            .setSequence(2));
        \\        bindingResolver.addModule(module);
        \\        List<IBinding> result = bindingResolver
        \\            .byType(BindingType.Service)
        \\            .byInterfaceType(Service.class)
        \\            .bySharingMode(SharingMode.WithSharing)
        \\            .resolve();
        \\        return String.valueOf(result.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "FflibStyleBindingProbe", "test", "1");
}

test "E2E: interface-typed static factory retains fluent resolver state" {
    const source =
        \\public class InterfaceFactoryStateProbe {
        \\    public enum BindingType { Service }
        \\    public enum SharingMode { WithSharing }
        \\    public interface IFactory {
        \\        Object newInstance(Type serviceType);
        \\    }
        \\    public class Binding {
        \\        private Type interfaceType;
        \\        private SharingMode sharingMode;
        \\        public Binding setInterfaceType(Type value) {
        \\            this.interfaceType = value;
        \\            return this;
        \\        }
        \\        public Binding setSharingMode(SharingMode value) {
        \\            this.sharingMode = value;
        \\            return this;
        \\        }
        \\        public Type getInterfaceType() { return this.interfaceType; }
        \\        public SharingMode getSharingMode() { return this.sharingMode; }
        \\        public Object newImplInstance() {
        \\            return interfaceType.newInstance();
        \\        }
        \\    }
        \\    public class Module {
        \\        private List<Binding> bindings = new List<Binding>();
        \\        public void addBinding(Binding binding) { bindings.add(binding); }
        \\        public List<Binding> getBindings() { return bindings; }
        \\    }
        \\    public class Resolver {
        \\        private List<Module> modules = new List<Module>();
        \\        public Resolver addModule(Module module) {
        \\            modules.add(module);
        \\            return this;
        \\        }
        \\        public List<Binding> resolve(Type serviceType, SharingMode sharingMode) {
        \\            List<Binding> result = new List<Binding>();
        \\            for (Module module : modules) {
        \\                for (Binding binding : module.getBindings()) {
        \\                    if (binding.getInterfaceType() != serviceType) continue;
        \\                    if (binding.getSharingMode() != sharingMode) continue;
        \\                    result.add(binding);
        \\                }
        \\            }
        \\            return result;
        \\        }
        \\    }
        \\    public class Factory implements IFactory {
        \\        private Resolver resolver;
        \\        private SharingMode sharingMode;
        \\        public Factory(Resolver resolver) { this.resolver = resolver; }
        \\        public Factory setSharingMode(SharingMode value) {
        \\            this.sharingMode = value;
        \\            return this;
        \\        }
        \\        public Object newInstance(Type serviceType) {
        \\            List<Binding> rows = resolver.resolve(serviceType, sharingMode);
        \\            return rows.isEmpty() ? null : rows.get(0).newImplInstance();
        \\        }
        \\    }
        \\    public class Service {}
        \\    private static Resolver bindingResolver = new Resolver();
        \\    private static final IFactory ServiceFactory =
        \\        new Factory(bindingResolver).setSharingMode(SharingMode.WithSharing);
        \\    public static String test() {
        \\        Module module = new Module();
        \\        module.addBinding(new Binding()
        \\            .setInterfaceType(Service.class)
        \\            .setSharingMode(SharingMode.WithSharing));
        \\        bindingResolver.addModule(module);
        \\        Object instance = ServiceFactory.newInstance(Service.class);
        \\        return String.valueOf(instance instanceof Service);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InterfaceFactoryStateProbe", "test", "true");
}

test "E2E: interface list dispatch preserves app binding module data" {
    const source =
        \\public class InterfaceModuleBindingProbe {
        \\    public enum SharingMode { WithSharing }
        \\    public interface IBinding {
        \\        Type getInterfaceType();
        \\        SharingMode getSharingMode();
        \\    }
        \\    public interface IModule {
        \\        void init();
        \\        List<IBinding> getBindings();
        \\    }
        \\    public class Binding implements IBinding {
        \\        private Type interfaceType;
        \\        private SharingMode sharingMode;
        \\        public Binding(Type interfaceType, SharingMode sharingMode) {
        \\            this.interfaceType = interfaceType;
        \\            this.sharingMode = sharingMode;
        \\        }
        \\        public Type getInterfaceType() { return this.interfaceType; }
        \\        public SharingMode getSharingMode() { return this.sharingMode; }
        \\    }
        \\    public class Module implements IModule {
        \\        private List<IBinding> bindings;
        \\        public void addBinding(IBinding binding) {
        \\            this.bindings = new List<IBinding>{ binding };
        \\        }
        \\        public void init() {
        \\            if (this.bindings == null) this.bindings = new List<IBinding>();
        \\        }
        \\        public List<IBinding> getBindings() { return this.bindings; }
        \\    }
        \\    public class Service {}
        \\    public static String test() {
        \\        Module module = new Module();
        \\        module.addBinding(new Binding(Service.class, SharingMode.WithSharing));
        \\        List<IModule> modules = new List<IModule>{ module };
        \\        Integer matches = 0;
        \\        for (IModule item : modules) {
        \\            item.init();
        \\            for (IBinding binding : item.getBindings()) {
        \\                if (binding.getInterfaceType() != Service.class) continue;
        \\                if (binding.getSharingMode() != SharingMode.WithSharing) continue;
        \\                matches++;
        \\            }
        \\        }
        \\        return String.valueOf(matches);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InterfaceModuleBindingProbe", "test", "1");
}

test "E2E: SObject clone without args clears Id before reinserting" {
    const source =
        \\public class SObjectCloneClearsIdProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'A');
        \\        insert account;
        \\        Account cloned = account.clone();
        \\        cloned.Name = 'B';
        \\        insert cloned;
        \\        return String.valueOf(account.Id != null) + ':' +
        \\            String.valueOf(cloned.Id != null) + ':' +
        \\            String.valueOf(account.Id == cloned.Id);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SObjectCloneClearsIdProbe", "test", "true:true:false");
}

test "E2E: failed after-insert addError clears inserted Id" {
    const source =
        \\trigger AddErrorAccountTrigger on Account (after insert) {
        \\    for (Account account : Trigger.new) {
        \\        if (account.Name == 'bad') account.addError('bad account');
        \\    }
        \\}
        \\public class FailedInsertClearsIdProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'bad');
        \\        try {
        \\            insert account;
        \\        } catch (Exception ex) {
        \\        }
        \\        Boolean idCleared = account.Id == null;
        \\        account.Name = 'good';
        \\        insert account;
        \\        return String.valueOf(idCleared) + ':' + String.valueOf(account.Id != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "FailedInsertClearsIdProbe", "test", "true:true");
}

test "E2E: failed before-insert addError allows reinserting same SObject" {
    const source =
        \\trigger BeforeAddErrorAccountTrigger on Account (before insert) {
        \\    for (Account account : Trigger.new) {
        \\        if (account.Name == 'bad') account.addError('bad account');
        \\    }
        \\}
        \\public class FailedBeforeInsertAllowsReinsertProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'bad');
        \\        try {
        \\            insert account;
        \\        } catch (Exception ex) {
        \\        }
        \\        Boolean idCleared = account.Id == null;
        \\        account.Name = 'good';
        \\        insert account;
        \\        return String.valueOf(idCleared) + ':' + String.valueOf(account.Id != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "FailedBeforeInsertAllowsReinsertProbe", "test", "true:true");
}

test "E2E: failed after-insert exception clears inserted Id" {
    const source =
        \\public class InsertFailureException extends Exception {}
        \\trigger ThrowingAccountTrigger on Account (after insert) {
        \\    for (Account account : Trigger.new) {
        \\        if (account.Name == 'bad') throw new InsertFailureException('bad account');
        \\    }
        \\}
        \\public class FailedInsertExceptionClearsIdProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'bad');
        \\        try {
        \\            insert account;
        \\        } catch (Exception ex) {
        \\        }
        \\        Boolean idCleared = account.Id == null;
        \\        account.Name = 'good';
        \\        insert account;
        \\        return String.valueOf(idCleared) + ':' + String.valueOf(account.Id != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "FailedInsertExceptionClearsIdProbe", "test", "true:true");
}

test "E2E: after-update trigger sees fields assigned on sparse queried SObject" {
    const source =
        \\trigger SparsePaymentUpdateTrigger on Payment__c (after update) {
        \\    for (Payment__c payment : Trigger.new) {
        \\        if (payment.Paid__c && payment.Written_Off__c) {
        \\            payment.addError('bad payment flags');
        \\        }
        \\    }
        \\}
        \\public class SparseQueriedUpdateProbe {
        \\    public static String test() {
        \\        Payment__c payment = new Payment__c(
        \\            Name = 'P',
        \\            Paid__c = false,
        \\            Written_Off__c = false
        \\        );
        \\        insert payment;
        \\        Payment__c sparse = [
        \\            SELECT Id, Name
        \\            FROM Payment__c
        \\            WHERE Id = :payment.Id
        \\        ];
        \\        sparse.Paid__c = true;
        \\        sparse.Written_Off__c = true;
        \\        try {
        \\            update sparse;
        \\        } catch (Exception ex) {
        \\            return ex.getMessage();
        \\        }
        \\        return 'missed';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SparseQueriedUpdateProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.value.string, "bad payment flags") != null);
}

test "E2E: single-row Database.query result casts to SObject" {
    const source =
        \\public class DatabaseQuerySingleSObjectCastProbe {
        \\    public static String test() {
        \\        insert new Payment__c(Name = 'P');
        \\        String soql = 'SELECT Id, Name FROM Payment__c LIMIT 1';
        \\        Payment__c payment = (Payment__c) Database.query(soql);
        \\        payment.Name = 'Updated';
        \\        update payment;
        \\        Payment__c stored = [SELECT Name FROM Payment__c WHERE Id = :payment.Id];
        \\        return stored.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DatabaseQuerySingleSObjectCastProbe", "test", "Updated");
}

test "E2E: method returning SObject unwraps Database.query result" {
    const source =
        \\public class DatabaseQueryMethodReturnProbe {
        \\    private Account selectAccount(Id accountId) {
        \\        return Database.query(
        \\            'SELECT Id, Name FROM Account WHERE Id = :accountId LIMIT 1'
        \\        );
        \\    }
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Acme');
        \\        insert account;
        \\        DatabaseQueryMethodReturnProbe probe =
        \\            new DatabaseQueryMethodReturnProbe();
        \\        Account queried = probe.selectAccount(account.Id);
        \\        return queried.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DatabaseQueryMethodReturnProbe", "test", "Acme");
}

test "E2E: managed package payment paid total auto-closes opportunity" {
    const source =
        \\public class PackagePaymentAutoCloseProbe {
        \\    public static String test() {
        \\        insert new npe01__Contacts_And_Orgs_Settings__c(
        \\            Payments_Auto_Close_Stage_Name__c = 'Closed Won'
        \\        );
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Donation',
        \\            Amount = 100,
        \\            StageName = 'Prospecting',
        \\            CloseDate = Date.today()
        \\        );
        \\        insert opp;
        \\        insert new npe01__OppPayment__c(
        \\            npe01__Opportunity__c = opp.Id,
        \\            npe01__Payment_Amount__c = 100,
        \\            npe01__Paid__c = true
        \\        );
        \\        Opportunity stored = [
        \\            SELECT StageName, IsClosed, IsWon
        \\            FROM Opportunity
        \\            WHERE Id = :opp.Id
        \\        ];
        \\        return stored.StageName + ':' +
        \\            String.valueOf(stored.IsClosed) + ':' +
        \\            String.valueOf(stored.IsWon);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackagePaymentAutoCloseProbe", "test", "Closed Won:true:true");
}

test "E2E: managed package payment boolean strings normalize on assignment" {
    const source =
        \\public class PackagePaymentBooleanStringProbe {
        \\    public static String test() {
        \\        npe01__OppPayment__c payment = new npe01__OppPayment__c(
        \\            npe01__Paid__c = 'True',
        \\            npe01__Written_Off__c = 'False'
        \\        );
        \\        insert payment;
        \\        npe01__OppPayment__c stored = [
        \\            SELECT npe01__Paid__c, npe01__Written_Off__c
        \\            FROM npe01__OppPayment__c
        \\            WHERE Id = :payment.Id
        \\        ];
        \\        return String.valueOf(stored.npe01__Paid__c) + ':' +
        \\            String.valueOf(stored.npe01__Written_Off__c);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackagePaymentBooleanStringProbe", "test", "true:false");
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
        \\        Map<String, Object> recordBind = new Map<String, Object>{
        \\            'recordId' => acct.Id
        \\        };
        \\        String qs =
        \\            'SELECT ContentDocumentId FROM ContentDocumentLink ' +
        \\            'WHERE LinkedEntityId = :recordId';
        \\        List<ContentDocumentLink> links = Database.queryWithBinds(
        \\            qs,
        \\            recordBind,
        \\            AccessLevel.USER_MODE
        \\        );
        \\        Set<Id> fileIds = new Set<Id>();
        \\        for (ContentDocumentLink cdl : links) {
        \\            fileIds.add(cdl.ContentDocumentId);
        \\        }
        \\        List<ContentVersion> versions = [
        \\            SELECT Id, Title
        \\            FROM ContentVersion
        \\            WHERE ContentDocumentId IN :fileIds
        \\        ];
        \\        return links.size() + ':' + fileIds.size() + ':' + versions.size();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "FTest", "test", "3:3:3");
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
    try expect_entry_string(source, "CVTest", "test", "3:3");
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
    try expect_entry_string(source, "InSubqueryTest", "test", "1");
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
    try expect_entry_string(source, "ContentVersionFileTypeCaseTest", "test", "1");
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
    try expect_entry_string(source, "FSTest", "test", "3");
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
    try expect_entry_string(source, "IterTest", "test", "3");
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
        \\    protected HttpResponse makeApiCall(
        \\        HttpVerb method,
        \\        String path,
        \\        String query,
        \\        String body,
        \\        Map<String, String> headers
        \\    ) {
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
    try expect_entry_string(source, "VTest", "test", "200");
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
    try expect_entry_string(source, "QTest2", "test", "true");
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
    try expect_entry_string(source, "DecimalTest", "test", "50.0");
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
    try expect_entry_string(source, "DoubleStrTest", "test", "10.0°C");
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

test "System.assert alias with custom message includes expected and actual" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const alloc = arena_alloc.allocator();

    const source =
        \\public class SystemAssertAliasTest {
        \\    public static void test() {
        \\        System.assert(false, 'should fail');
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);
    _ = eval.call_method("SystemAssertAliasTest", "test", &.{}) catch {};

    const msg = eval.assertion_failure orelse "";
    try std.testing.expect(std.mem.indexOf(u8, msg, "should fail") != null);
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
    try expect_entry_string(source, "DtFmtTest", "test", "July 14");
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
    try expect_entry_string(source, "DtFmtIso", "test", "2024-07-14");
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
    try expect_entry_string(source, "DtYearTest", "test", "2026");
}

test "E2E: Datetime.format supports quoted literals and milliseconds pattern" {
    const source =
        \\public class DatetimeFormatPatternProbe {
        \\    public static String test() {
        \\        Date d = Date.newInstance(2026, 2, 1);
        \\        return Datetime.newInstance(d.year(), d.month(), d.day())
        \\            .format('yyyy-MM-dd\'T\'HH:mm:ss.SSS');
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "DatetimeFormatPatternProbe",
        "test",
        "2026-02-01T00:00:00.000",
    );
}

test "E2E: JSON deserialize SObject CreatedDate supports dateGmt" {
    const source =
        \\public class JsonCreatedDateDateGmtProbe {
        \\    public static String test() {
        \\        Date d = Date.newInstance(2026, 2, 1);
        \\        String createdDateValue = Datetime.newInstance(d.year(), d.month(), d.day())
        \\            .format('yyyy-MM-dd\'T\'HH:mm:ss.SSS');
        \\        String payload = '{"attributes":{"type":"Account"},"Name":"Acme","CreatedDate":"' +
        \\            createdDateValue + '"}';
        \\        Account accountRecord = (Account) JSON.deserialize(payload, Account.class);
        \\        return String.valueOf(accountRecord.CreatedDate.dateGmt());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "JsonCreatedDateDateGmtProbe", "test", "2026-02-01");
}

test "E2E: static final Date initialized from System.today supports addMonths" {
    const source =
        \\public class StaticFinalDateAddMonthsProbe {
        \\    private static final Date TODAY = System.today();
        \\    private static final Date DATE_ESTABLISHED = TODAY.addMonths(-3);
        \\    public static String test() {
        \\        return String.valueOf(DATE_ESTABLISHED);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StaticFinalDateAddMonthsProbe", "test", "2026-02-01");
}

test "E2E: map parameter shadows same-named instance field for values iteration" {
    const source =
        \\public class MapParameterShadowProbe {
        \\    public class Record {
        \\        private SObject opp = new Opportunity();
        \\        public Record(Opportunity opp) { this.opp = opp; }
        \\        public Boolean isNew() { return opp.Id == null; }
        \\        public Date getCloseDate() { return (Date) opp.get('CloseDate'); }
        \\    }
        \\    private Map<Date, String> recordByCloseDate = new Map<Date, String>();
        \\    private Map<Date, Record> boundaryRecordByCloseDate = new Map<Date, Record>();
        \\
        \\    public static String test() {
        \\        MapParameterShadowProbe probe = new MapParameterShadowProbe();
        \\        Date today = Date.newInstance(2020, 1, 10);
        \\        Opportunity opp = new Opportunity();
        \\        opp.Id = '006000000000001';
        \\        opp.CloseDate = today.addDays(-1);
        \\        probe.boundaryRecordByCloseDate.put(today.addDays(-1), new Record(opp));
        \\        return probe.find(probe.boundaryRecordByCloseDate, today.addDays(-3), today);
        \\    }
        \\
        \\    private String find(Map<Date, Record> recordByCloseDate, Date startDate, Date endDate) {
        \\        for (Record record : recordByCloseDate.values()) {
        \\            if (record.isNew()) continue;
        \\            Date closeDate = record.getCloseDate();
        \\            if (closeDate >= startDate && closeDate <= endDate) {
        \\                return String.valueOf(closeDate);
        \\            }
        \\        }
        \\        return 'missing';
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MapParameterShadowProbe", "test", "2020-01-09");
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
    try expect_entry_string(source, "DtAddYears", "test", "2026-07-14");
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
    try expect_entry_string(source, "DtDateTest", "test", "7/19/2024");
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
    try expect_entry_string(source, "DefaultFormatProbe", "test", "1/1/2015|1/1/2015, 2:30 PM");
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
    try expect_entry_string(source, "InlineSetOverloadProbe", "test", "Contact");
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
    try expect_entry_string(source, "SchemaFieldsProbe", "test", "LastName");
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
    try expect_entry_string(source, "TernaryEnumHintProbe", "test", "B");
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
    try expect_entry_string(source, "EnumHintGuardProbe", "test", "str:hello");
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
        \\        EnumOverloadProbe.Ordering ord = new EnumOverloadProbe.Ordering(
        \\            'Name',
        \\            EnumOverloadProbe.Direction.ASC,
        \\            false
        \\        );
        \\        return ord.field;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "EnumOverloadProbe", "test", "Name");
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
    try expect_entry_string(source, "SchemaTypeProbe", "test", "Account");
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
    try expect_entry_string(source, "NetworkGateProbe", "test", "gated-off");
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
    try expect_entry_string(source, "PicklistDescribeProbe", "test", "PICKLIST");
}

test "E2E: managed package recurring donation amount describe reports currency" {
    const source =
        \\public class PackageRecurringDonationAmountDescribeProbe {
        \\    public static String test() {
        \\        Schema.DescribeFieldResult dfr =
        \\            npe03__Recurring_Donation__c.npe03__Amount__c.getDescribe();
        \\        return dfr.getType().name();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PackageRecurringDonationAmountDescribeProbe",
        "test",
        "CURRENCY",
    );
}

test "E2E: managed package contact closed opp count describe reports numeric" {
    const source =
        \\public class PackageContactClosedOppCountDescribeProbe {
        \\    public static String test() {
        \\        Schema.DescribeFieldResult dfr =
        \\            Contact.SObjectType.getDescribe()
        \\                .fields.getMap()
        \\                .get('npo02__OppsClosedThisYear__c')
        \\                .getDescribe();
        \\        return dfr.getType().name();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackageContactClosedOppCountDescribeProbe", "test", "DOUBLE");
}

test "E2E: schema field map rejects invalid custom field api names" {
    const source =
        \\public class SchemaFieldMapInvalidApiNameProbe {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields =
        \\            DataImport__c.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('Contact1_bad field__c'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SchemaFieldMapInvalidApiNameProbe", "test", "false");
}

test "E2E: SObjectField constructor argument coerces to DescribeFieldResult" {
    const source =
        \\public class SObjectFieldDescribeConstructorArgProbe {
        \\    public class Column {
        \\        public String typeName;
        \\        public Column(Schema.DescribeFieldResult field) {
        \\            typeName = field.getType().name();
        \\        }
        \\    }
        \\    public static String test() {
        \\        Column column = new Column(
        \\            Schema.SObjectType.npe03__Recurring_Donation__c.fields.npe03__Amount__c
        \\        );
        \\        return column.typeName;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SObjectFieldDescribeConstructorArgProbe", "test", "CURRENCY");
}

test "E2E: Datetime.valueOf accepts loose single-digit components" {
    // `Datetime.valueOf('2006-5-4 3:2:1')` is real-world input seen in utility code that
    // re-parses user-entered strings. Apex accepts it; we need to as well.
    const source =
        \\public class DtLooseProbe {
        \\    public static String test() {
        \\        Datetime dt = Datetime.valueOf('2006-5-4 3:2:1');
        \\        return String.valueOf(dt.year()) +
        \\            '-' + String.valueOf(dt.month()) +
        \\            '-' + String.valueOf(dt.day()) +
        \\            ' ' + String.valueOf(dt.hour()) +
        \\            ':' + String.valueOf(dt.minute()) +
        \\            ':' + String.valueOf(dt.second());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DtLooseProbe", "test", "2006-5-4 3:2:1");
}

test "E2E: bitwise operators on integers return integer results" {
    // `&`/`|`/`^` on integer operands must yield integer results rather than
    // booleans. fflib_Uuid (and other reflection-heavy helpers) build bitmasks
    // via `(v & 0x0f) | 0x40` and were returning `false` because the AST used to
    // fold `&` into the same node as `&&`, which short-circuited based on
    // `coerceToBool(integer)` returning false.
    const source =
        \\public class BitwiseIntProbe {
        \\    public static String test() {
        \\        Integer andR = 30 & 15;
        \\        Integer orR = 30 | 64;
        \\        Integer xorR = 30 ^ 15;
        \\        return String.valueOf(andR) +
        \\            ',' + String.valueOf(orR) +
        \\            ',' + String.valueOf(xorR);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "BitwiseIntProbe", "test", "14,94,17");
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
    try expect_entry_string(source, "EnumHintTailProbe", "test", "mode:SYSTEM_MODE");
}

test "E2E: Map.equals delegates pairwise value comparison" {
    // Apex-style user classes often override `equals` by comparing internal
    // collections (e.g. apex-expression's Environment delegates to
    // `variables.equals(other.variables)`). The interpreter used to return null
    // for Map.equals because only List exposed it, breaking downstream equality.
    const source =
        \\public class MapEqualsProbe {
        \\    public static String test() {
        \\        Map<String, Object> a = new Map<String, Object>{
        \\            'name' => 'Bob',
        \\            'age' => 42
        \\        };
        \\        Map<String, Object> b = new Map<String, Object>{
        \\            'name' => 'Bob',
        \\            'age' => 42
        \\        };
        \\        Map<String, Object> c = new Map<String, Object>{
        \\            'name' => 'Bob',
        \\            'age' => 43
        \\        };
        \\        return String.valueOf(a.equals(b)) + ',' + String.valueOf(a.equals(c));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MapEqualsProbe", "test", "true,false");
}

test "E2E: Map null key does not collide with empty string key" {
    const source =
        \\public class MapNullKeyProbe {
        \\    public static String test() {
        \\        Map<String, String> m = new Map<String, String>();
        \\        m.put('', 'empty');
        \\        String before = m.get(null);
        \\        m.put(null, 'null');
        \\        return String.valueOf(before) + ',' +
        \\            String.valueOf(m.get('')) + ',' +
        \\            String.valueOf(m.get(null)) + ',' +
        \\            String.valueOf(m.containsKey('')) + ',' +
        \\            String.valueOf(m.containsKey(null));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MapNullKeyProbe", "test", "null,empty,null,true,true");
}

test "E2E: null overload resolution prefers String over Object" {
    const source =
        \\public class NullOverloadProbe {
        \\    public static String pick(Object value) { return 'object'; }
        \\    public static String pick(String value) { return value == null ? 'string:null' : value; }
        \\    public static String test() {
        \\        return pick(null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NullOverloadProbe", "test", "string:null");
}

test "E2E: non-id string overload prefers String over Id" {
    const source =
        \\public class StringIdOverloadProbe {
        \\    public static String pick(Id value) { return 'id'; }
        \\    public static String pick(String value) { return 'string:' + value; }
        \\    public static String test() {
        \\        return pick('GAU 2');
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StringIdOverloadProbe", "test", "string:GAU 2");
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
        \\        User target = new User(
        \\            FirstName = 'Bob',
        \\            LastName = 'Smith',
        \\            Email = 'bob@example.com',
        \\            LanguageLocaleKey = 'en_US'
        \\        );
        \\        String result = '';
        \\        System.runAs(target) {
        \\            result = UserInfo.getFirstName() +
        \\                '|' + UserInfo.getLastName() +
        \\                '|' + UserInfo.getUserEmail() +
        \\                '|' + UserInfo.getLanguage();
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "RunAsUserOverrideProbe",
        "test",
        "Bob|Smith|bob@example.com|en_US",
    );
}

test "E2E: UserInfo.getUiThemeDisplayed defaults to Classic" {
    const source =
        \\public class UiThemeDisplayedProbe {
        \\    public static String test() {
        \\        return UserInfo.getUiThemeDisplayed();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UiThemeDisplayedProbe", "test", "Theme3");
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
    try expect_entry_string(source, "BareCallFallbackProbe", "test", "payload");
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
    try expect_entry_string(source, "StaticForwardRefProbe", "test", "16:0123456789abcdef");
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
    try expect_entry_string(source, "BitwiseBoolProbe", "test", "true");
}

test "E2E: method call on property-backed identifier invokes the getter" {
    // `foo.size()` for a property-backed `foo` used to return null when the call
    // happened inside another getter, because the method-call fast path bailed
    // out to `callMethod` before falling back to evalExpr. TriggerBase's
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
    try expect_entry_string(source, "PropertyMethodCallProbe", "test", "1");
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
    try expect_entry_string(source, "OverloadTypeProbe", "test", "type:OverloadTypeProbe.Inner");
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
    try expect_entry_string(source, "InterfaceCastProbe", "test", "ok");
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
    try expect_entry_string(source, "TypeForNameNullProbe", "test", "ok");
}

test "fixture dependency expansion adds fflib mocks for apex common" {
    var expanded: std.ArrayListUnmanaged([]const u8) = .empty;
    try expand_fixture_dependency_paths(
        std.testing.allocator,
        &.{".local-fixtures/apex/repos/fflib-apex-common"},
        &expanded,
    );
    defer expanded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), expanded.items.len);
    try std.testing.expectEqualStrings(
        ".local-fixtures/apex/repos/fflib-apex-mocks/sfdx-source/apex-mocks/main",
        expanded.items[0],
    );
    try std.testing.expectEqualStrings(
        ".local-fixtures/apex/repos/fflib-apex-common",
        expanded.items[1],
    );
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
    try expect_entry_string(source, "ChildRelationshipProbe", "test", "true|true");
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
        \\        String refName = (refs != null && refs.size() > 0)
        \\            ? refs[0].getDescribe().getName()
        \\            : 'none';
        \\        Schema.DescribeFieldResult master = Contact.MasterRecordId.getDescribe();
        \\        List<Schema.SObjectType> masterRefs = master.getReferenceTo();
        \\        String masterRefName = (masterRefs != null && masterRefs.size() > 0)
        \\            ? masterRefs[0].getDescribe().getName()
        \\            : 'none';
        \\        return String.valueOf(dt) + '|' + rel + '|' + refName + '|' +
        \\            master.getRelationshipName() + '|' + masterRefName + '|' +
        \\            String.valueOf(master.isUpdateable());
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "RelationshipDescribeProbe",
        "test",
        "REFERENCE|CreatedBy|User|MasterRecord|Contact|false",
    );
}

test "E2E: Matcher.groupCount reflects the pattern and matches() populates currentMatch" {
    // Java/Apex contract: `Matcher.groupCount()` reports the number of capture groups in
    // the *pattern* — not the number actually captured. After `matches()` succeeds, the
    // matcher should also expose `group(n)` for inspection (fflib_SObjectSelector tests
    // depend on this to validate generated SOQL).
    const source =
        \\public class MatcherStateProbe {
        \\    public static String test() {
        \\        Pattern p = Pattern.compile('SELECT (.*) FROM (.+)');
        \\        Matcher m = p.matcher('SELECT Id, Name FROM Account');
        \\        if (m.groupCount() != 2) return 'bad-groupCount:' + String.valueOf(m.groupCount());
        \\        if (!m.matches()) return 'no-match';
        \\        return m.group(1) + '|' + m.group(2);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MatcherStateProbe", "test", "Id, Name|Account");
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
    try expect_entry_string(source, "GreedyBacktrackProbe", "test", "bbb");
}

test "E2E: Schema.SObjectType.<X>.fields.getMap() matches getDescribe().fields.getMap()" {
    // Regression for a bug where the two describe-map paths produced different sizes.
    // Consumers like fflib_SObjectDescribe.FieldsMap assert the two match, so we must
    // populate the FieldDescribeMap identically no matter which entry point is used.
    const source =
        \\public class FieldMapParityProbe {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> viaSchemaShortcut =
        \\            Schema.SObjectType.Account.fields.getMap();
        \\        Map<String, Schema.SObjectField> viaDescribe =
        \\            Account.SObjectType.getDescribe().fields.getMap();
        \\        if (viaSchemaShortcut.size() != viaDescribe.size()) {
        \\            return 'mismatch:' +
        \\                String.valueOf(viaSchemaShortcut.size()) +
        \\                '-vs-' +
        \\                String.valueOf(viaDescribe.size());
        \\        }
        \\        if (viaSchemaShortcut.size() < 5) {
        \\            return 'too-small:' + String.valueOf(viaSchemaShortcut.size());
        \\        }
        \\        return 'ok';
        \\    }
        \\}
    ;
    try expect_entry_string(source, "FieldMapParityProbe", "test", "ok");
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
    try expect_entry_string(source, "SplitRegexProbe", "test", "_D0D_|+|_D1D_");
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
    try expect_entry_string(source, "RegexCaptureProbe", "test", "true|foo bar|foo|bar");
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
    try expect_entry_string(source, "DtMillisTest", "test", "2024-07-19");
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
    try expect_entry_string(source, "DtGetTimeTest", "test", "2024-07-19");
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
    try expect_entry_string(source, "DtValueOfMillisTest", "test", "2025-01-01:1735689600000");
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
    try expect_entry_string(
        source,
        "DtValueOfOffsetStringTest",
        "test",
        "true:true:2018-08-08T08:08:08Z",
    );
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
    try expect_entry_string(source, "TimeZoneLookupTest", "test", "Asia/Tokyo:Asia/Tokyo");
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
    try expect_entry_string(source, "StrLowerTest", "test", "%adventure%");
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
    try expect_entry_string(source, "DbQueryBindTest", "test", "1");
}

test "E2E: SOQL equality bind with Id set matches stored record ids" {
    const source =
        \\public class SoqlIdSetEqualityBindProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Acme');
        \\        insert account;
        \\        Set<Id> ids = new Set<Id>{ account.Id };
        \\        List<Account> results = [
        \\            SELECT Id, Name
        \\            FROM Account
        \\            WHERE Id = :ids
        \\        ];
        \\        return String.valueOf(results.size()) + ':' + results[0].Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SoqlIdSetEqualityBindProbe", "test", "1:Acme");
}

test "E2E: queried SObject Id field reads internal record id" {
    const source =
        \\public class QueriedSObjectIdFieldProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Acme');
        \\        insert account;
        \\        Account queried = [SELECT Id FROM Account WHERE Id = :account.Id];
        \\        Map<Id, Account> byId = new Map<Id, Account>();
        \\        byId.put(queried.Id, queried);
        \\        return String.valueOf(byId.get(account.Id) != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "QueriedSObjectIdFieldProbe", "test", "true");
}

test "E2E: lowercase database.query resolves as Database.query" {
    const source =
        \\public class LowercaseDatabaseQueryTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        String name = 'Acme';
        \\        String soql = 'SELECT Id FROM Account WHERE Name = :name';
        \\        List<Account> rows = database.query(soql);
        \\        return String.valueOf(rows.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "LowercaseDatabaseQueryTest", "test", "1");
}

test "E2E: Opportunity IsClosed WHERE derives from StageName" {
    const source =
        \\public class OpportunityIsClosedWhereTest {
        \\    public static String test() {
        \\        insert new Opportunity(
        \\            Name = 'Open',
        \\            StageName = 'Prospecting',
        \\            CloseDate = Date.today()
        \\        );
        \\        insert new Opportunity(
        \\            Name = 'Closed',
        \\            StageName = 'Closed Won',
        \\            CloseDate = Date.today()
        \\        );
        \\        List<Opportunity> openOpps = Database.query(
        \\            'SELECT Id FROM Opportunity WHERE IsClosed = false'
        \\        );
        \\        List<Opportunity> wonOpps = Database.query(
        \\            'SELECT Id FROM Opportunity WHERE IsWon = true'
        \\        );
        \\        return String.valueOf(openOpps.size()) + ':' +
        \\            String.valueOf(wonOpps.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OpportunityIsClosedWhereTest", "test", "1:1");
}

test "E2E: Opportunity IsClosed SELECT derives from StageName" {
    const source =
        \\public class OpportunityIsClosedSelectTest {
        \\    public static String test() {
        \\        insert new Opportunity(
        \\            Name = 'Closed',
        \\            StageName = 'Closed Won',
        \\            CloseDate = Date.today()
        \\        );
        \\        Opportunity opp = [
        \\            SELECT IsClosed, IsWon
        \\            FROM Opportunity
        \\            WHERE Name = 'Closed'
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(opp.IsClosed) + ':' + String.valueOf(opp.IsWon);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OpportunityIsClosedSelectTest", "test", "true:true");
}

test "E2E: Opportunity IsClosed field access derives from StageName" {
    const source =
        \\public class OpportunityIsClosedAccessTest {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Donation',
        \\            CloseDate = Date.today(),
        \\            StageName = 'Closed Won'
        \\        );
        \\        return String.valueOf(opp.IsClosed) + ':' + String.valueOf(opp.IsWon);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OpportunityIsClosedAccessTest", "test", "true:true");
}

test "E2E: Opportunity IsClosed field access ignores stale stored flag" {
    const source =
        \\public class OpportunityStaleStageFlagAccessTest {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Donation',
        \\            CloseDate = Date.today(),
        \\            StageName = 'Prospecting'
        \\        );
        \\        insert opp;
        \\        opp = [
        \\            SELECT IsClosed, IsWon, StageName
        \\            FROM Opportunity
        \\            WHERE Id = :opp.Id
        \\            LIMIT 1
        \\        ];
        \\        opp.StageName = 'Closed Lost';
        \\        return String.valueOf(opp.IsClosed) + ':' + String.valueOf(opp.IsWon);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OpportunityStaleStageFlagAccessTest", "test", "true:false");
}

test "E2E: CampaignMember HasResponded SELECT derives from member status" {
    const source =
        \\public class CampaignMemberHasRespondedSelectTest {
        \\    public static String test() {
        \\        Campaign campaign = new Campaign(Name = 'Appeal');
        \\        insert campaign;
        \\        insert new CampaignMemberStatus(
        \\            CampaignId = campaign.Id,
        \\            Label = 'Responded',
        \\            HasResponded = true,
        \\            SortOrder = 1
        \\        );
        \\        Contact contact = new Contact(LastName = 'Smith');
        \\        insert contact;
        \\        insert new CampaignMember(
        \\            CampaignId = campaign.Id,
        \\            ContactId = contact.Id,
        \\            Status = 'Responded'
        \\        );
        \\        CampaignMember member = [
        \\            SELECT HasResponded
        \\            FROM CampaignMember
        \\            WHERE ContactId = :contact.Id
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(member.HasResponded);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "CampaignMemberHasRespondedSelectTest", "test", "true");
}

test "E2E: CampaignMemberStatus insert ignores duplicate campaign labels" {
    const source =
        \\public class CampaignMemberStatusDuplicateTest {
        \\    public static Integer test() {
        \\        Campaign campaign = new Campaign(Name = 'Appeal');
        \\        insert campaign;
        \\        List<CampaignMemberStatus> statuses = new List<CampaignMemberStatus>();
        \\        statuses.add(new CampaignMemberStatus(
        \\            CampaignId = campaign.Id,
        \\            Label = 'Follow Up',
        \\            HasResponded = false,
        \\            SortOrder = 10
        \\        ));
        \\        statuses.add(new CampaignMemberStatus(
        \\            CampaignId = campaign.Id,
        \\            Label = 'Follow Up',
        \\            HasResponded = false,
        \\            SortOrder = 11
        \\        ));
        \\        insert statuses;
        \\        return [SELECT Id FROM CampaignMemberStatus
        \\            WHERE CampaignId = :campaign.Id AND Label = 'Follow Up'].size();
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "CampaignMemberStatusDuplicateTest", "test", 1);
}

test "E2E: DescribeFieldResult returns its SObjectField token" {
    const source =
        \\public class DescribeFieldTokenRoundTripTest {
        \\    public static String test() {
        \\        Schema.DescribeFieldResult describe = Account.Name.getDescribe();
        \\        Schema.SObjectField field = describe.getSObjectField();
        \\        return field.getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DescribeFieldTokenRoundTripTest", "test", "Name");
}

test "E2E: Set of SObjectField tokens stringifies without null entries" {
    const source =
        \\public class SObjectFieldSetStringifyTest {
        \\    public static String test() {
        \\        Set<Schema.SObjectField> fields = new Set<Schema.SObjectField>{
        \\            Contact.FirstName,
        \\            Contact.LastName,
        \\            Contact.Title
        \\        };
        \\        Set<String> names = new Set<String>{ 'Id' };
        \\        for (Schema.SObjectField field : fields) {
        \\            names.add(String.valueOf(field));
        \\        }
        \\        return String.join(new List<String>(names), ',');
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "SObjectFieldSetStringifyTest",
        "test",
        "Id,FirstName,LastName,Title",
    );
}

test "E2E: new Type size creates Apex array list" {
    const source =
        \\public class NewArraySizeListTest {
        \\    public static String test() {
        \\        String[] names = new String[0];
        \\        names.addAll(new List<String>{ 'Id', 'Name' });
        \\        Contact[] contacts = new Contact[2];
        \\        return String.join(names, ',') + ':' + contacts.size() + ':' + contacts[0];
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NewArraySizeListTest", "test", "Id,Name:2:null");
}

test "E2E: Database rollback restores inserted and updated records" {
    const source =
        \\public class DatabaseRollbackRestoreTest {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'before');
        \\        insert a;
        \\        Savepoint sp = Database.setSavepoint();
        \\        a.Name = 'after';
        \\        update a;
        \\        insert new Account(Name = 'inserted');
        \\        Database.rollback(sp);
        \\        List<Account> rows = [SELECT Name FROM Account ORDER BY Name];
        \\        return rows.size() + ':' + rows[0].Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DatabaseRollbackRestoreTest", "test", "1:before");
}

test "E2E: SOQL ORDER BY ascending places nulls first" {
    const source =
        \\public class OrderByNullsFirstTest {
        \\    public static String test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'A', Industry = 'Filled'),
        \\            new Account(Name = 'B')
        \\        };
        \\        List<Account> rows = [SELECT Industry FROM Account ORDER BY Industry];
        \\        return String.valueOf(rows[0].Industry) + ':' + rows[1].Industry;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OrderByNullsFirstTest", "test", "null:Filled");
}

test "E2E: Map copy constructor preserves entries" {
    const source =
        \\public class MapCopyConstructorTest {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'copy');
        \\        insert a;
        \\        Map<Id, Account> original = new Map<Id, Account>([SELECT Name FROM Account]);
        \\        Map<Id, Account> copied = new Map<Id, Account>(original);
        \\        return copied.size() + ':' + copied.get(a.Id).Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MapCopyConstructorTest", "test", "1:copy");
}

test "E2E: Contact update rejects missing AccountId lookup" {
    const source =
        \\public class ContactMissingAccountLookupUpdateTest {
        \\    public static String test() {
        \\        Contact con = new Contact(LastName = 'lookup');
        \\        insert con;
        \\        con.AccountId = '001000000001AAA';
        \\        try {
        \\            update con;
        \\        } catch (DmlException ex) {
        \\            return ex.getMessage();
        \\        }
        \\        return 'no error';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ContactMissingAccountLookupUpdateTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(
        u8,
        result.value.string,
        "INVALID_CROSS_REFERENCE_KEY",
    ) != null);
}

test "E2E: DML merge removes secondary records" {
    const source =
        \\public class DmlMergeRemovesSecondaryTest {
        \\    public static Integer test() {
        \\        Account winner = new Account(Name = 'winner');
        \\        Account loser = new Account(Name = 'loser');
        \\        insert new List<Account>{ winner, loser };
        \\        merge winner loser;
        \\        return [SELECT count() FROM Account WHERE Id = :loser.Id];
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "DmlMergeRemovesSecondaryTest", "test", 0);
}

test "E2E: user class clone copies instance fields" {
    const source =
        \\public class UserClassCloneTest {
        \\    public class Box {
        \\        public String name;
        \\    }
        \\    public static String test() {
        \\        Box original = new Box();
        \\        original.name = 'value';
        \\        Box copied = original.clone();
        \\        copied.name = 'copy';
        \\        return original.name + ':' + copied.name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UserClassCloneTest", "test", "value:copy");
}

test "E2E: List deepClone drops SObject ids by default" {
    const source =
        \\public class ListDeepCloneDropsIdsTest {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'source');
        \\        insert a;
        \\        List<Account> cloned = new List<Account>{ a }.deepClone();
        \\        cloned[0].Name = 'copy';
        \\        insert cloned;
        \\        return [SELECT count() FROM Account] + ':' + cloned[0].Id;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ListDeepCloneDropsIdsTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.startsWith(u8, result.value.string, "2:001"));
}

test "E2E: describe field maps resolve lowercase RecordTypeId" {
    const source =
        \\public class LowercaseRecordTypeIdDescribeTest {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields =
        \\            Account.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('recordtypeid')) + ':' +
        \\            fields.get('recordtypeid').getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "LowercaseRecordTypeIdDescribeTest",
        "test",
        "true:RecordTypeId",
    );
}

test "E2E: managed package contact insert fallback creates household account" {
    const source =
        \\public class CAO_Constants {
        \\    public static final String HH_ACCOUNT_TYPE = 'Household Account';
        \\}
        \\public class PackageContactHouseholdFallbackTest {
        \\    public static String test() {
        \\        Contact con = new Contact(FirstName = 'c1', LastName = 'C1');
        \\        insert con;
        \\        Contact stored = [
        \\            SELECT Id, AccountId, Account.npe01__SYSTEM_AccountType__c
        \\            FROM Contact
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(stored.AccountId != null) + ':' +
        \\            stored.Account.npe01__SYSTEM_AccountType__c;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PackageContactHouseholdFallbackTest",
        "test",
        "true:Household Account",
    );
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
    try expect_entry_string(source, "NullNumericValueOfTest", "test", "true:true");
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
    try expect_entry_string(source, "LongInstanceofProbe", "test", "true:true:false:false:true");
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
    try expect_entry_string(source, "FormulaFieldTest", "test", "Hiking");
}

test "E2E: formula fields support IF equality and CASESAFEID" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Contact/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Contact/fields/ParentKey__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ParentKey__c</fullName>
        \\    <formula>IF(Account.Type__c==&apos;Primary&apos;,CASESAFEID(AccountId),CASESAFEID(AlternateAccount__c))</formula>
        \\    <label>Parent Key</label>
        \\    <type>Text</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FormulaIfCasesafeIdProbe {
        \\    public static String test() {
        \\        Account parent = new Account(
        \\            Name = 'Parent',
        \\            Type__c = 'Primary'
        \\        );
        \\        insert parent;
        \\        Contact contact = new Contact(LastName = 'Member', AccountId = parent.Id);
        \\        insert contact;
        \\        List<Contact> rows = [
        \\            SELECT ParentKey__c
        \\            FROM Contact
        \\            WHERE ParentKey__c != null
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' + rows[0].ParentKey__c + ':' + parent.Id;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FormulaIfCasesafeIdProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "1:001000000000000001:001000000000000001",
        result.value.string,
    );
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

test "E2E: managed package recurring donation rollups follow Opportunity updates" {
    const source =
        \\public class PackageRecurringDonationRollupProbe {
        \\    public static String test() {
        \\        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
        \\            Name = 'RD',
        \\            npe03__Open_Ended_Status__c = 'Open'
        \\        );
        \\        insert rd;
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Pledge',
        \\            StageName = 'Pledged',
        \\            CloseDate = Date.newInstance(2024, 1, 1),
        \\            Amount = 50,
        \\            npe03__Recurring_Donation__c = rd.Id
        \\        );
        \\        insert opp;
        \\        rd = [
        \\            SELECT npe03__Next_Payment_Date__c, npe03__Installments__c,
        \\                npe03__Paid_Amount__c
        \\            FROM npe03__Recurring_Donation__c
        \\            WHERE Id = :rd.Id
        \\        ];
        \\        String before = String.valueOf(rd.npe03__Next_Payment_Date__c) + ':' +
        \\            String.valueOf(rd.npe03__Installments__c) + ':' +
        \\            String.valueOf(rd.npe03__Paid_Amount__c);
        \\        opp.StageName = 'Closed Won';
        \\        update opp;
        \\        rd = [
        \\            SELECT npe03__Next_Payment_Date__c, npe03__Last_Payment_Date__c,
        \\                npe03__Paid_Amount__c, npe03__Total_Paid_Installments__c
        \\            FROM npe03__Recurring_Donation__c
        \\            WHERE Id = :rd.Id
        \\        ];
        \\        return before + '|' +
        \\            String.valueOf(rd.npe03__Next_Payment_Date__c) + ':' +
        \\            String.valueOf(rd.npe03__Last_Payment_Date__c) + ':' +
        \\            String.valueOf(rd.npe03__Paid_Amount__c) + ':' +
        \\            String.valueOf(rd.npe03__Total_Paid_Installments__c);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackageRecurringDonationRollupProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "2024-01-01:1:null|null:2024-01-01:50.0:1",
        result.value.string,
    );
}

test "E2E: managed package recurring donation Amount aliases npe03 amount" {
    const source =
        \\public class PackageRecurringDonationAmountAliasProbe {
        \\    public static String test() {
        \\        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
        \\            npe03__Amount__c = 125
        \\        );
        \\        return String.valueOf(rd.get('Amount'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackageRecurringDonationAmountAliasProbe", "test", "125");
}

test "E2E: managed package recurring donation update refreshes open Opportunities" {
    const source =
        \\public class PackageRecurringDonationOpenOppUpdateProbe {
        \\    public static String test() {
        \\        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
        \\            Name = 'Before',
        \\            npe03__Open_Ended_Status__c = 'Open',
        \\            npe03__Installment_Period__c = 'Monthly',
        \\            npe03__Next_Payment_Date__c = Date.newInstance(2024, 1, 1),
        \\            npe03__Amount__c = 10
        \\        );
        \\        insert rd;
        \\        insert new Opportunity(
        \\            Name = 'Opp',
        \\            StageName = 'Pledged',
        \\            CloseDate = Date.newInstance(2024, 1, 1),
        \\            Amount = 10,
        \\            npe03__Recurring_Donation__c = rd.Id
        \\        );
        \\        insert new npe03__Custom_Field_Mapping__c(
        \\            Name = 'Map',
        \\            npe03__Recurring_Donation_Field__c = 'Name',
        \\            npe03__Opportunity_Field__c = 'Description'
        \\        );
        \\        rd.Name = 'After';
        \\        rd.npe03__Amount__c = 25;
        \\        rd.npe03__Next_Payment_Date__c = Date.newInstance(2024, 2, 1);
        \\        update rd;
        \\        Opportunity opp = [
        \\            SELECT Amount, CloseDate, Description
        \\            FROM Opportunity
        \\            WHERE npe03__Recurring_Donation__c = :rd.Id
        \\        ];
        \\        rd.npe03__Open_Ended_Status__c = 'Closed';
        \\        update rd;
        \\        Integer openCount = [
        \\            SELECT count()
        \\            FROM Opportunity
        \\            WHERE npe03__Recurring_Donation__c = :rd.Id
        \\            AND IsClosed = false
        \\        ];
        \\        return String.valueOf(opp.Amount) + ':' +
        \\            String.valueOf(opp.CloseDate) + ':' +
        \\            opp.Description + ':' +
        \\            String.valueOf(openCount);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PackageRecurringDonationOpenOppUpdateProbe",
        "test",
        "25:2024-02-01:After:0",
    );
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
        \\        Parent__c refreshed = [
        \\            SELECT OpenChildren__c, TotalChildren__c
        \\            FROM Parent__c
        \\            WHERE Id = :parentRecord.Id
        \\        ];
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

test "E2E: lookup delete constraint SetNull clears referencing records" {
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
        \\    <deleteConstraint>SetNull</deleteConstraint>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <type>Lookup</type>
        \\</CustomField>
        ,
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class SetNullDeleteConstraintTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'P');
        \\        insert parent;
        \\        Child__c child = new Child__c(Name = 'C', Parent__c = parent.Id);
        \\        insert child;
        \\        delete parent;
        \\        Child__c refreshed = [SELECT Parent__c FROM Child__c WHERE Id = :child.Id];
        \\        return String.valueOf(refreshed.Parent__c == null);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "SetNullDeleteConstraintTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
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
        \\        Parent__c refreshed = [
        \\            SELECT ErrorChildren__c
        \\            FROM Parent__c
        \\            WHERE Id = :parentRecord.Id
        \\        ];
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
        \\            for (Schema.SObjectField field :
        \\                Example__c.SObjectType.getDescribe().fields.getMap().values()
        \\            ) {
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

test "E2E: master-detail metadata fields are required on insert" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

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
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class MasterDetailRequiredInsertTest {
        \\    public static String test() {
        \\        try {
        \\            insert new Child__c(Name = 'Orphan', Parent__c = null);
        \\            return 'no-error';
        \\        } catch (DmlException ex) {
        \\            return ex.getDmlMessage(0);
        \\        }
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "MasterDetailRequiredInsertTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Required fields are missing: [Parent__c]",
        result.value.string,
    );
}

test "E2E: non-reparentable master-detail fields reject parent changes" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Child__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <reparentableMasterDetail>false</reparentableMasterDetail>
        \\    <type>MasterDetail</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class NonReparentableMasterDetailTest {
        \\    public static String test() {
        \\        Parent__c firstParent = new Parent__c(Name = 'First');
        \\        Parent__c secondParent = new Parent__c(Name = 'Second');
        \\        insert new List<Parent__c>{ firstParent, secondParent };
        \\        Child__c child = new Child__c(Name = 'Child', Parent__c = firstParent.Id);
        \\        insert child;
        \\        child.Parent__c = secondParent.Id;
        \\        try {
        \\            update child;
        \\            return 'no-error';
        \\        } catch (DmlException ex) {
        \\            return 'caught';
        \\        }
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "NonReparentableMasterDetailTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("caught", result.value.string);
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
        \\        List<Schema.PicklistEntry> values =
        \\            Schema.Thing__c.Priority__c.getDescribe().getPicklistValues();
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
        \\            for (Schema.SObjectField field :
        \\                Child__c.SObjectType.getDescribe().fields.getMap().values()
        \\            ) {
        \\                Schema.DescribeFieldResult describe = field.getDescribe();
        \\                if (describe.isCreateable() == false ||
        \\                    populated.containsKey(describe.getName())
        \\                ) {
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
        \\        Child__c childRecord = new Child__c(
        \\            Parent__c = parentRecord.Id,
        \\            Level__c = LogLevel.ERROR.name()
        \\        );
        \\        insert Builder.fill(childRecord);
        \\        Parent__c refreshed = [
        \\            SELECT ErrorChildren__c
        \\            FROM Parent__c
        \\            WHERE Id = :parentRecord.Id
        \\        ];
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
        \\    RollupOldSnapshotProbe.seen =
        \\        String.valueOf(oldRecord.ErrorChildren__c) +
        \\        ':' + String.valueOf(newRecord.ErrorChildren__c);
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
        \\        Parent__c parent = new Parent__c(
        \\            Name = 'Parent',
        \\            RetentionDate__c = System.today().addDays(-1)
        \\        );
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

test "E2E: list custom setting getAll and getValues use Name keys" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_list_custom_setting_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class ListSettingAccessTest {
        \\    public static String test() {
        \\        ListSettings__c row = new ListSettings__c(Name = 'foo', Flag__c = 'bar');
        \\        insert row;
        \\        Map<String, ListSettings__c> rows = ListSettings__c.getAll();
        \\        ListSettings__c fromValues = ListSettings__c.getValues('foo');
        \\        ListSettings__c fromInstance = ListSettings__c.getInstance('foo');
        \\        return String.valueOf(rows.get('foo').Flag__c) + ':' +
        \\            String.valueOf(fromValues.Flag__c) + ':' +
        \\            String.valueOf(fromInstance.Flag__c) + ':' +
        \\            String.valueOf(rows.get(row.Id) == null);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "ListSettingAccessTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("bar:bar:bar:true", result.value.string);
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

test "E2E: cached hierarchy custom setting object mutations remain visible through static facade" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class GenericSettingsFacade {
        \\    private static AppSettings__c cached;
        \\    public static AppSettings__c getSettings() {
        \\        if (cached == null) {
        \\            cached = new AppSettings__c();
        \\        }
        \\        return cached;
        \\    }
        \\}
        \\public class GenericSettingsWrapper {
        \\    private AppSettings__c settings {
        \\        get {
        \\            if (settings == null) {
        \\                settings = GenericSettingsFacade.getSettings();
        \\            }
        \\            return settings;
        \\        }
        \\        set;
        \\    }
        \\    public void save(String value) {
        \\        settings.Flag__c = value;
        \\    }
        \\}
        \\public class GenericSettingsCacheMutationTest {
        \\    public static String test() {
        \\        new GenericSettingsWrapper().save('updated');
        \\        return GenericSettingsFacade.getSettings().Flag__c;
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "GenericSettingsCacheMutationTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("updated", result.value.string);
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
        \\        AppSettings__c settings = (AppSettings__c)
        \\            AppSettings__c.SObjectType.newSObject(null, true);
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

test "E2E: hierarchy custom setting upsert without owner stores org defaults" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class HierarchySettingOwnerlessUpsertTest {
        \\    public static String test() {
        \\        AppSettings__c settings = new AppSettings__c();
        \\        settings.Flag__c = 'saved';
        \\        upsert settings;
        \\        AppSettings__c reloaded = AppSettings__c.getOrgDefaults();
        \\        return String.valueOf(settings.SetupOwnerId) + ':' +
        \\            String.valueOf(reloaded.Flag__c);
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "HierarchySettingOwnerlessUpsertTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("00D000000000001:saved", result.value.string);
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
    try expect_entry_string(source, "StaticInitSideEffectTest", "test", "ready");
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
    try expect_entry_string(source, "StaticInitCollisionTarget", "test", "right");
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
    var suite = try run_test_suite(
        alloc,
        std.testing.io,
        &.{tmp_path},
        &_null_writer.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
    try std.testing.expectEqual(@as(u32, 0), suite.failed);
    try std.testing.expectEqual(@as(u32, 0), suite.errors);
}

test "E2E: test setup static state is reset before each test method" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_hierarchy_custom_setting_fixture(tmp_dir.dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "SetupStaticReset_Tests.cls",
        .data =
        \\@IsTest
        \\private class SetupStaticReset_Tests {
        \\    private static AppSettings__c cachedSettings;
        \\
        \\    private static AppSettings__c getSettings() {
        \\        if (cachedSettings == null) {
        \\            cachedSettings = new AppSettings__c();
        \\        }
        \\        return cachedSettings;
        \\    }
        \\
        \\    @TestSetup
        \\    static void setupData() {
        \\        getSettings().Flag__c = 'setup';
        \\        insert new Account(Name = 'setup');
        \\    }
        \\
        \\    @IsTest
        \\    static void statics_start_fresh_after_setup() {
        \\        System.Assert.areEqual(null, cachedSettings);
        \\        getSettings().Flag__c = 'test';
        \\        System.Assert.areEqual('test', getSettings().Flag__c);
        \\    }
        \\}
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    var _null_buf: [256]u8 = undefined;
    var _null_writer: std.Io.Writer.Discarding = .init(&_null_buf);
    var suite = try run_test_suite(
        alloc,
        std.testing.io,
        &.{tmp_path},
        &_null_writer.writer,
    );
    defer suite.deinit();

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
    try expect_entry_string(source, "SafeNavFluentChainTest", "test", "1");
}

test "E2E: safe navigation short-circuits remaining method chain on null" {
    const source =
        \\public class SafeNavNullChainTest {
        \\    public static String test() {
        \\        String raw = null;
        \\        List<String> parts = raw?.replaceAll('x', 'y').split(',');
        \\        return parts == null ? 'null' : String.valueOf(parts.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SafeNavNullChainTest", "test", "null");
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
    try expect_entry_string(source, "SafeNavNullFieldChainTest", "test", "null");
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
    try expect_entry_string(source, "LogicalOrShortCircuitTest", "test", "ok");
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
    try expect_entry_string(source, "LogicalAndShortCircuitTest", "test", "ok");
}

test "E2E: Type.forName inner handler retains SObjectType map keys after execute" {
    const source =
        \\public abstract class HandlerBase {
        \\    private static Map<Schema.SObjectType, List<HandlerBase>> executed =
        \\        new Map<Schema.SObjectType, List<HandlerBase>>();
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
        \\        HandlerBase handler = (HandlerBase)
        \\            Type.forName('HandlerFactoryHost.AccountHandler').newInstance();
        \\        handler.execute();
        \\        return String.valueOf(HandlerBase.getExecutionCount(Schema.Account.SObjectType));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InnerHandlerFactoryTest", "test", "1");
}

test "E2E: Type.forName event handler retains platform event SObjectType map keys after execute" {
    const source =
        \\public abstract class EventHandlerBase {
        \\    private static Map<Schema.SObjectType, List<EventHandlerBase>> executed =
        \\        new Map<Schema.SObjectType, List<EventHandlerBase>>();
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
        \\        EventHandlerBase handler = (EventHandlerBase)
        \\            Type.forName('EventHandlerFactoryHost.PlatformEventHandler').newInstance();
        \\        handler.execute();
        \\        return String.valueOf(
        \\            EventHandlerBase.getExecutionCount(Schema.LogEntryEvent__e.SObjectType)
        \\        );
        \\    }
        \\}
    ;
    try expect_entry_string(source, "EventHandlerFactoryTest", "test", "1");
}

test "E2E: JSON round-trip into SObject preserves setup object fields when adding read-only field" {
    const source =
        \\public class JsonReadOnlyFieldRoundTripTest {
        \\    public static String test() {
        \\        SObject record = new ApexClass(Name = 'SomeClass', Body = 'body');
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap =
        \\            (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        deserializedRecordMap.put(
        \\            Schema.ApexClass.LastModifiedDate.toString(),
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
        \\        SObject updatedRecord = (SObject) System.JSON.deserialize(
        \\            System.JSON.serialize(deserializedRecordMap),
        \\            SObject.class
        \\        );
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
        \\        Schema.ApexClass record = new Schema.ApexClass(
        \\            Name = 'SomeClass',
        \\            Body = 'body'
        \\        );
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap =
        \\            (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        deserializedRecordMap.put(
        \\            Schema.ApexClass.LastModifiedDate.toString(),
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
        \\        record = (Schema.ApexClass) System.JSON.deserialize(
        \\            System.JSON.serialize(deserializedRecordMap),
        \\            SObject.class
        \\        );
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

test "E2E: typed JSON deserialize coerces quoted primitive fields" {
    const source =
        \\public class JsonQuotedPrimitiveCoercionTest {
        \\    public class Response {
        \\        public Integer statusCode;
        \\        public Long sequence;
        \\        public Decimal amount;
        \\        public Boolean success;
        \\    }
        \\    public static String test() {
        \\        Response response = (Response) JSON.deserialize(
        \\            '{"statusCode":"204","sequence":"9001","amount":"12.5","success":"true"}',
        \\            Response.class
        \\        );
        \\        return String.valueOf(response.statusCode == 204) + ':' +
        \\            String.valueOf(response.sequence == 9001) + ':' +
        \\            String.valueOf(response.amount == 12.5) + ':' +
        \\            String.valueOf(response.success == true);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonQuotedPrimitiveCoercionTest",
        "test",
        "true:true:true:true",
    );
}

test "E2E: Map<Schema.SObjectField, Object> preserves setup field tokens through keySet/get" {
    const source =
        \\public class SchemaFieldTokenMapTest {
        \\    public static String test() {
        \\        Map<Schema.SObjectField, Object> changesToFields =
        \\            new Map<Schema.SObjectField, Object>{
        \\                Schema.ApexClass.LastModifiedDate =>
        \\                    Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        };
        \\        for (Schema.SObjectField sobjectField : changesToFields.keySet()) {
        \\            return sobjectField.toString() +
        \\                ':' + String.valueOf(changesToFields.get(sobjectField));
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
        \\    public static SObject setReadOnlyField(
        \\        SObject record,
        \\        Schema.SObjectField field,
        \\        Object value
        \\    ) {
        \\        return setReadOnlyField(
        \\            record,
        \\            new Map<Schema.SObjectField, Object>{ field => value }
        \\        );
        \\    }
        \\    public static SObject setReadOnlyField(
        \\        SObject record,
        \\        Map<Schema.SObjectField, Object> changesToFields
        \\    ) {
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap =
        \\            (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
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
        \\            Body = 'body'
        \\        );
        \\        record = (Schema.ApexClass) setReadOnlyField(
        \\            record,
        \\            Schema.ApexClass.LastModifiedDate,
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
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
        \\    public static SObject setReadOnlyField(
        \\        SObject record,
        \\        Schema.SObjectField field,
        \\        Object value
        \\    ) {
        \\        return setReadOnlyField(
        \\            record,
        \\            new Map<Schema.SObjectField, Object>{ field => value }
        \\        );
        \\    }
        \\    public static SObject setReadOnlyField(
        \\        SObject record,
        \\        Map<Schema.SObjectField, Object> changesToFields
        \\    ) {
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap =
        \\            (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
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
        \\        record = (Schema.ApexClass) setReadOnlyField(
        \\            record,
        \\            Schema.ApexClass.LastModifiedDate,
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
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
        \\    public static SObject setReadOnlyField(
        \\        SObject record,
        \\        Schema.SObjectField field,
        \\        Object value
        \\    ) {
        \\        return setReadOnlyField(
        \\            record,
        \\            new Map<Schema.SObjectField, Object>{ field => value }
        \\        );
        \\    }
        \\    public static SObject setReadOnlyField(
        \\        SObject record,
        \\        Map<Schema.SObjectField, Object> changesToFields
        \\    ) {
        \\        String serializedRecord = System.JSON.serialize(record);
        \\        Map<String, Object> deserializedRecordMap =
        \\            (Map<String, Object>) System.JSON.deserializeUntyped(serializedRecord);
        \\        for (Schema.SObjectField sobjectField : changesToFields.keySet()) {
        \\            deserializedRecordMap.put(sobjectField.toString(), changesToFields.get(sobjectField));
        \\        }
        \\        return (SObject) System.JSON.deserialize(
        \\            System.JSON.serialize(deserializedRecordMap),
        \\            SObject.class
        \\        );
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

test "E2E: standard SObject construction ignores unrelated inner class with same name" {
    const source =
        \\public class MetadataHost {
        \\    public class Campaign {
        \\        public String marker = 'inner';
        \\    }
        \\}
        \\public class StandardSObjectCtorProbe {
        \\    public static String test() {
        \\        List<Campaign> campaigns = new List<Campaign>();
        \\        campaigns.add(new Campaign(Name = 'cmp1', IsActive = true));
        \\        return campaigns[0].getSObjectType().getDescribe().getName() + ':' +
        \\            campaigns[0].Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StandardSObjectCtorProbe", "test", "Campaign:cmp1");
}

test "E2E: Opportunity CampaignId is a known standard field" {
    const source =
        \\public class OpportunityCampaignFieldProbe {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity();
        \\        Object value = opp.get('CampaignId');
        \\        Boolean described = Opportunity.SObjectType.getDescribe()
        \\            .fields.getMap().containsKey('CampaignId');
        \\        return String.valueOf(value == null) + ':' + String.valueOf(described);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OpportunityCampaignFieldProbe", "test", "true:true");
}

test "E2E: Account and Contact address geocode fields are known standard fields" {
    const source =
        \\public class StandardAddressGeocodeFieldsProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Acme');
        \\        account.put('BillingLatitude', 37.1);
        \\        account.put('BillingLongitude', -122.2);
        \\        Contact contact = new Contact(LastName = 'Smith');
        \\        contact.put('Salutation', 'Dr.');
        \\        contact.put('MailingLatitude', 35.3);
        \\        contact.put('MailingLongitude', -120.4);
        \\        Boolean accountDescribed = Account.SObjectType.getDescribe()
        \\            .fields.getMap().containsKey('BillingLatitude');
        \\        Boolean activityDescribed = Account.SObjectType.getDescribe()
        \\            .fields.getMap().containsKey('LastActivityDate');
        \\        Boolean contactDescribed = Contact.SObjectType.getDescribe()
        \\            .fields.getMap().containsKey('MailingLongitude');
        \\        return String.valueOf(account.get('BillingLatitude')) + ':' +
        \\            String.valueOf(contact.get('Salutation')) + ':' +
        \\            String.valueOf(accountDescribed) + ':' +
        \\            String.valueOf(activityDescribed) + ':' +
        \\            String.valueOf(contactDescribed);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "StandardAddressGeocodeFieldsProbe",
        "test",
        "37.1:Dr.:true:true:true",
    );
}

test "E2E: custom object fields shortcut returns SObjectField tokens" {
    const source =
        \\public class CustomObjectFieldsShortcutProbe {
        \\    public static String test() {
        \\        SObject row = new Widget__c(Name = 'w');
        \\        row.put(Widget__c.fields.Amount__c, 42);
        \\        return String.valueOf(Widget__c.fields.Id) + ':' +
        \\            String.valueOf(Widget__c.fields.Amount__c) + ':' +
        \\            String.valueOf(row.get(Widget__c.fields.Amount__c));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "CustomObjectFieldsShortcutProbe", "test", "Id:Amount__c:42");
}

test "E2E: AsyncApexJob describe key prefix matches generated job ids" {
    const source =
        \\public class AsyncApexJobKeyPrefixProbe {
        \\    public static String test() {
        \\        String prefix = AsyncApexJob.SObjectType.getDescribe().getKeyPrefix();
        \\        Id mockJobId = (Id)(prefix + '000000000001');
        \\        return prefix + ':' + mockJobId.getSObjectType().getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AsyncApexJobKeyPrefixProbe", "test", "707:AsyncApexJob");
}

test "E2E: EncodingUtil base64 and Crypto.generateMac use raw blob bytes" {
    const source =
        \\public class Base64MacProbe {
        \\    public static String test() {
        \\        String encoded = EncodingUtil.base64Encode(Blob.valueOf('1234'));
        \\        String decoded = EncodingUtil.base64Decode(encoded).toString();
        \\        Blob mac = Crypto.generateMac(
        \\            'HmacSHA256',
        \\            Blob.valueOf('data'),
        \\            Blob.valueOf('key')
        \\        );
        \\        String mac64 = EncodingUtil.base64Encode(mac);
        \\        return encoded + ':' + decoded + ':' + mac64;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "Base64MacProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "MTIzNA==:1234:UDH+PZicbRU3oBP6bnOdojRj/a7DtwE32Cjjas4iG9A=",
        result.value.string,
    );
}

test "E2E: Auth.JWT renders JSON payload for signing" {
    const source =
        \\public class AuthJwtJsonProbe {
        \\    public static String test() {
        \\        Auth.JWT jwt = new Auth.JWT();
        \\        jwt.setIss('issuer');
        \\        return jwt.toJSONString();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "AuthJwtJsonProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("{\"iss\":\"issuer\"}", result.value.string);
}

test "E2E: JSON serialization escapes embedded quotes in strings" {
    const source =
        \\public class JsonEscapedStringProbe {
        \\    public static String test() {
        \\        Map<String, Object> payload = new Map<String, Object>();
        \\        payload.put('activeFields', '[{"name":"Donation_Amount__c"}]');
        \\        payload.put('newline', 'a\nb');
        \\        String jsonText = JSON.serialize(payload);
        \\        Map<String, Object> parsed =
        \\            (Map<String, Object>) JSON.deserializeUntyped(jsonText);
        \\        return String.valueOf(parsed.get('activeFields')) + ':' +
        \\            String.valueOf(parsed.get('newline'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "JsonEscapedStringProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "[{\"name\":\"Donation_Amount__c\"}]:a\nb",
        result.value.string,
    );
}

test "E2E: managed package map get preserves explicit null values" {
    const source =
        \\public class PackageMapNullProbe {
        \\    public static String test() {
        \\        Map<String, String> fields = new Map<String, String>();
        \\        fields.put('pkg__Custom_Field__c', null);
        \\        return String.valueOf(fields.get('Custom_Field__c')) + ':' +
        \\            String.valueOf(fields.get('pkg__Custom_Field__c'));
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PackageMapNullProbe",
        "test",
        "null:null",
    );
}

test "E2E: managed package Address validates household lookup and city length" {
    const source =
        \\public class PackageAddressValidationProbe {
        \\    public static String test() {
        \\        List<Address__c> rows = new List<Address__c>{
        \\            new Address__c(Household_Account__c = '001000000000001', MailingCity__c = 'Seattle'),
        \\            new Address__c(Household_Account__c = 'aR5000000000001', MailingCity__c = 'Portland'),
        \\            new Address__c(Household_Account__c = '001000000000002',
        \\                MailingCity__c = 'This is an invalid city because it is over 40 characters')
        \\        };
        \\        List<Database.SaveResult> results = Database.insert(rows, false);
        \\        return String.valueOf(results[0].isSuccess()) + ':' +
        \\            String.valueOf(results[1].isSuccess()) + ':' +
        \\            String.valueOf(results[2].isSuccess()) + ':' +
        \\            results[2].getErrors()[0].getMessage();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackageAddressValidationProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "true:false:false:STRING_TOO_LONG: Billing City: data value too large",
        result.value.string,
    );
}

test "E2E: managed package Address insert updates household and contact mailing fields" {
    const source =
        \\public class PackageAddressInsertSideEffectProbe {
        \\    public static String test() {
        \\        Account household = new Account(Name = 'Household');
        \\        insert household;
        \\        Contact contact = new Contact(LastName = 'Donor', AccountId = household.Id);
        \\        insert contact;
        \\        insert new Address__c(
        \\            Household_Account__c = household.Id,
        \\            Default_Address__c = true,
        \\            MailingCity__c = 'Seattle'
        \\        );
        \\        Account storedHousehold = [SELECT BillingCity FROM Account WHERE Id = :household.Id];
        \\        Contact storedContact = [SELECT MailingCity FROM Contact WHERE Id = :contact.Id];
        \\        return storedHousehold.BillingCity + ':' + storedContact.MailingCity;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PackageAddressInsertSideEffectProbe",
        "test",
        "Seattle:Seattle",
    );
}

test "E2E: Data Import settings getInstance keeps unset fields null" {
    const source =
        \\public class DataImportSettingsDefaultsProbe {
        \\    public static String test() {
        \\        Data_Import_Settings__c settings = Data_Import_Settings__c.getInstance();
        \\        String defaultSet = settings.Default_Data_Import_Field_Mapping_Set__c;
        \\        String contactRule = settings.Contact_Matching_Rule__c;
        \\        String mappingMethod = settings.Field_Mapping_Method__c;
        \\        return (defaultSet == null ? 'null' : defaultSet) + ':' +
        \\            (contactRule == null ? 'null' : contactRule) + ':' +
        \\            (mappingMethod == null ? 'null' : mappingMethod);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DataImportSettingsDefaultsProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "null:null:null",
        result.value.string,
    );
}

test "E2E: custom metadata getInstance hydrates metadata relationship parents" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/ChildThing__mdt/fields");
    try tmp_dir.dir.createDirPath(std.testing.io, "customMetadata");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/ChildThing__mdt/fields/ParentThing__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ParentThing__c</fullName>
        \\    <referenceTo>ParentThing__mdt</referenceTo>
        \\    <relationshipName>ChildThings</relationshipName>
        \\    <type>MetadataRelationship</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "customMetadata/ParentThing.Primary.md-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
        \\    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        \\    xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        \\    <label>Primary</label>
        \\    <values>
        \\        <field>Target_API_Name__c</field>
        \\        <value xsi:type="xsd:string">Target__c</value>
        \\    </values>
        \\</CustomMetadata>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "customMetadata/ChildThing.First.md-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
        \\    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        \\    xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        \\    <label>First</label>
        \\    <values>
        \\        <field>ParentThing__c</field>
        \\        <value xsi:type="xsd:string">Primary</value>
        \\    </values>
        \\</CustomMetadata>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class CustomMetadataRelationshipParentProbe {
        \\    public static String test() {
        \\        ChildThing__mdt child = ChildThing__mdt.getInstance('First');
        \\        return child.ParentThing__r.DeveloperName + ':' +
        \\            child.ParentThing__r.Target_API_Name__c;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CustomMetadataRelationshipParentProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Primary:Target__c",
        result.value.string,
    );
}

test "E2E: custom metadata relationship fields compare parent ids in SOQL" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/ChildThing__mdt/fields");
    try tmp_dir.dir.createDirPath(std.testing.io, "customMetadata");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/ChildThing__mdt/fields/ParentThing__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>ParentThing__c</fullName>
        \\    <referenceTo>ParentThing__mdt</referenceTo>
        \\    <relationshipName>ChildThings</relationshipName>
        \\    <type>MetadataRelationship</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "customMetadata/ParentThing.Primary.md-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <label>Primary</label>
        \\</CustomMetadata>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "customMetadata/ChildThing.First.md-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
        \\    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        \\    xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        \\    <label>First</label>
        \\    <values>
        \\        <field>ParentThing__c</field>
        \\        <value xsi:type="xsd:string">Primary</value>
        \\    </values>
        \\</CustomMetadata>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class CustomMetadataRelationshipWhereIdTest {
        \\    public static String test() {
        \\        ParentThing__mdt parentRecord = [SELECT Id FROM ParentThing__mdt LIMIT 1];
        \\        return String.valueOf([
        \\            SELECT Id
        \\            FROM ChildThing__mdt
        \\            WHERE ParentThing__c = :parentRecord.Id
        \\        ].size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CustomMetadataRelationshipWhereIdTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: nested queue partition object initialized from Set constructor argument" {
    const source =
        \\public class NestedQueuePartitionTest {
        \\    private QueueableIds queueableIds;
        \\    public NestedQueuePartitionTest(Id recordId, Set<String> ids) {
        \\        queueableIds = new QueueableIds(ids);
        \\    }
        \\    public NestedQueuePartitionTest(Id recordId, QueueableIds queueableIds) {
        \\        this.queueableIds = queueableIds;
        \\    }
        \\    public static String test() {
        \\        NestedQueuePartitionTest host = new NestedQueuePartitionTest(
        \\            'a00000000000001',
        \\            buildIds(120)
        \\        );
        \\        return String.valueOf(host.queueableIds.ids.size()) + ':' +
        \\            String.valueOf(host.queueableIds.partitionSize()) + ':' +
        \\            String.valueOf(host.queueableIds.hasGroupsToCapture()) + ':' +
        \\            String.valueOf(host.queueableIds.idsToCapture().size());
        \\    }
        \\    private static Set<String> buildIds(Integer count) {
        \\        Set<String> ids = new Set<String>();
        \\        for (Integer i = 0; i < count; i++) {
        \\            ids.add('id-' + i);
        \\        }
        \\        return ids;
        \\    }
        \\    private class QueueableIds {
        \\        private List<String> ids;
        \\        private List<List<String>> partitions;
        \\        private final Integer MAX_COUNT = 50;
        \\        private Integer currentPartitionIndex = 0;
        \\        public QueueableIds(Set<String> ids) {
        \\            this.ids = new List<String>();
        \\            this.ids.addAll(ids);
        \\            partitions = partitionIds(this.ids);
        \\        }
        \\        public List<String> idsToCapture() {
        \\            List<String> currentIds = partitions[currentPartitionIndex];
        \\            currentPartitionIndex++;
        \\            return currentIds;
        \\        }
        \\        public Integer partitionSize() {
        \\            return partitions.size();
        \\        }
        \\        public Boolean hasGroupsToCapture() {
        \\            return partitionSize() > currentPartitionIndex;
        \\        }
        \\        private List<List<String>> partitionIds(List<String> ids) {
        \\            List<List<String>> partitions = new List<List<String>>();
        \\            List<String> currentList = new List<String>();
        \\            Integer currentCount = 0;
        \\            for (Integer i = 0; i < ids.size(); i++) {
        \\                currentList.add(ids[i]);
        \\                currentCount++;
        \\                Boolean atLimit = currentCount == MAX_COUNT;
        \\                Boolean isLast = (i == ids.size() - 1 && currentList.size() > 0);
        \\                if (atLimit || isLast) {
        \\                    partitions.add(currentList);
        \\                    currentCount = 0;
        \\                    currentList = new List<String>();
        \\                }
        \\            }
        \\            return partitions;
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NestedQueuePartitionTest", "test", "120:3:true:50");
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
        \\        return OuterNameHost.getInnerNameFromInside() +
        \\            '|' + OuterNameHost.InnerNameTarget.class.getName();
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
        \\        SharedHandlerBase inside = (SharedHandlerBase)
        \\            Type.forName(HandlerHostA.getInnerHandlerName()).newInstance();
        \\        SharedHandlerBase outside = (SharedHandlerBase)
        \\            Type.forName(HandlerHostA.SharedHandler.class.getName()).newInstance();
        \\        return inside.whoAmI() + outside.whoAmI();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "QualifiedInnerInstanceTest", "test", "AA");
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
    try expect_entry_string(source, "ScopedInnerCtorHostA", "test", "A:x");
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
    try expect_entry_string(source, "Container", "test", "outer:ok");
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
    try expect_entry_string(source, "StaticCounterProbe", "run", "1:2:3");
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
        \\        getHandler(TriggerableFactoryHost.EventTriggerable.class.getName())
        \\            ?.overrideContext('x')
        \\            .execute();
        \\        return String.valueOf(
        \\            TriggerableHost.getExecutionCount(Schema.LogEntryEvent__e.SObjectType)
        \\        );
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TriggerableFactoryTest", "test", "1");
}

test "E2E: parent constructors can read overridden type getters" {
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
        \\        ParentCtorTypeHost child = (ParentCtorTypeHost)
        \\            Type.forName(ParentCtorTypeFactory.EventChild.class.getName())
        \\            .newInstance();
        \\        return ParentCtorTypeHost.getReading('duringParentCtor') +
        \\            '|' + String.valueOf(child.getSObjectType());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ParentCtorTypeFactoryTest", "test", "null|LogEntryEvent__e");
}

test "E2E: static method returned map supports chained get size and index access" {
    const source =
        \\public class StaticMapChainHost {
        \\    private static Map<Schema.SObjectType, List<String>> valuesByType =
        \\        new Map<Schema.SObjectType, List<String>>();
        \\    static {
        \\        valuesByType.put(Schema.Account.SObjectType, new List<String>{ 'a', 'b' });
        \\    }
        \\    public static Map<Schema.SObjectType, List<String>> getValuesByType() {
        \\        return valuesByType;
        \\    }
        \\}
        \\public class StaticMapChainTest {
        \\    public static String test() {
        \\        return String.valueOf(
        \\            StaticMapChainHost.getValuesByType().get(Schema.Account.SObjectType).size()
        \\        ) +
        \\            '|' +
        \\            StaticMapChainHost.getValuesByType().get(Schema.Account.SObjectType).get(0);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StaticMapChainTest", "test", "2|a");
}

test "E2E: SObjectType keySet preserves keys in loop bodies" {
    const source =
        \\public class SObjectTypeKeySetLoopTest {
        \\    public static String test() {
        \\        User currentUser = [
        \\            SELECT Id, Username
        \\            FROM User
        \\            WHERE Id = :System.UserInfo.getUserId()
        \\        ];
        \\        Map<Schema.SObjectType, List<Id>> idsByType =
        \\            new Map<Schema.SObjectType, List<Id>>();
        \\        idsByType.put(currentUser.Id.getSObjectType(), new List<Id>{ currentUser.Id });
        \\        for (Schema.SObjectType sobjectType : idsByType.keySet()) {
        \\            List<Id> recordIds = idsByType.get(sobjectType);
        \\            List<SObject> results = Database.query(
        \\                String.format(
        \\                    'SELECT Username FROM {0} WHERE Id IN :recordIds',
        \\                    new List<Object>{ sobjectType }
        \\                )
        \\            );
        \\            return sobjectType.getDescribe().getName() +
        \\                ':' + (String) results.get(0).get('Username');
        \\        }
        \\        return 'empty';
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "SObjectTypeKeySetLoopTest",
        "test",
        "User:testuser@example.com",
    );
}

test "E2E: StandardController normalizes queried SObject records" {
    const source =
        \\public class StandardControllerQueriedRecordTest {
        \\    public static String test() {
        \\        Contact contactRecord = new Contact(LastName = 'Tester');
        \\        insert contactRecord;
        \\        Contact queried = [SELECT LastName FROM Contact LIMIT 1];
        \\        ApexPages.StandardController controller =
        \\            new ApexPages.StandardController(queried);
        \\        return controller.getId().getSObjectType().getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StandardControllerQueriedRecordTest", "test", "Contact");
}

test "E2E: StandardController save persists the wrapped record" {
    const source =
        \\public class StandardControllerSaveTest {
        \\    public static String test() {
        \\        Contact contactRecord = new Contact(LastName = 'Saved');
        \\        ApexPages.StandardController controller =
        \\            new ApexPages.StandardController(contactRecord);
        \\        PageReference pageRef = controller.save();
        \\        List<Contact> contacts = [SELECT Id, LastName FROM Contact];
        \\        return String.valueOf(contacts.size()) + ':' +
        \\            contacts[0].LastName + ':' +
        \\            pageRef.getUrl() + ':' +
        \\            String.valueOf(pageRef.getUrl() == '/' + String.valueOf(contacts[0].Id).left(15));
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "StandardControllerSaveTest",
        "test",
        "1:Saved:/003000000000000:true",
    );
}

test "E2E: StandardController view returns canonical 15 character record URL" {
    const source =
        \\public class StandardControllerViewUrlTest {
        \\    public static String test() {
        \\        Contact contactRecord = new Contact(LastName = 'Viewed');
        \\        insert contactRecord;
        \\        ApexPages.StandardController controller =
        \\            new ApexPages.StandardController(contactRecord);
        \\        PageReference pageRef = controller.view();
        \\        return controller.getId() + ':' + pageRef.getUrl();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "StandardControllerViewUrlTest",
        "test",
        "003000000000000001:/003000000000000",
    );
}

test "E2E: update of missing standard record id throws DmlException" {
    const source =
        \\public class MissingStandardUpdateTest {
        \\    public static String test() {
        \\        insert new Opportunity(Name = 'Stored', StageName = 'Prospecting', CloseDate = Date.today());
        \\        try {
        \\            update new Opportunity(Id = '006000000000001AAA', Name = 'Missing');
        \\            return 'no error';
        \\        } catch (DmlException e) {
        \\            return e.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "MissingStandardUpdateTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.value.string, "invalid cross reference") != null);
}

test "E2E: SOQL WHERE supports row aliases for direct fields" {
    const source =
        \\public class AliasedWhereDirectFieldTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'A');
        \\        List<Account> rows = [
        \\            SELECT a.Id, a.Name
        \\            FROM Account a
        \\            WHERE a.Name = 'A'
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' + rows[0].Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AliasedWhereDirectFieldTest", "test", "1:A");
}

test "E2E: enhanced recurring donation start date defaults before insert triggers" {
    const source =
        \\trigger RDDefaultProbeTrigger on npe03__Recurring_Donation__c (before insert) {
        \\    RDDefaultProbe.seenInBeforeInsert = Trigger.new[0].StartDate__c != null;
        \\}
        \\public class RDDefaultProbe {
        \\    public static Boolean seenInBeforeInsert = false;
        \\    public static String test() {
        \\        insert new npe03__Recurring_Donation__c(
        \\            Status__c = 'Active',
        \\            RecurringType__c = 'Open',
        \\            InstallmentPeriod__c = 'Monthly',
        \\            InstallmentFrequency__c = 1,
        \\            Day_of_Month__c = '15'
        \\        );
        \\        npe03__Recurring_Donation__c rd = [
        \\            SELECT StartDate__c FROM npe03__Recurring_Donation__c LIMIT 1
        \\        ];
        \\        return String.valueOf(seenInBeforeInsert) + ':' +
        \\            String.valueOf(rd.StartDate__c != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "RDDefaultProbe", "test", "true:true");
}

test "E2E: missing custom package child relationship defaults to empty list" {
    const source =
        \\public class PackageChildRelationshipTest {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Gift',
        \\            StageName = 'Closed Won',
        \\            CloseDate = Date.today()
        \\        );
        \\        insert opp;
        \\        Opportunity queried = [SELECT Id FROM Opportunity WHERE Id = :opp.Id];
        \\        return String.valueOf(queried.pkg__Payment__r.isEmpty());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackageChildRelationshipTest", "test", "true");
}

test "E2E: layout relatedList custom relationship appears in Opportunity describe" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "layouts");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "layouts/Opportunity-Test.layout-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Layout xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <relatedLists>
        \\        <relatedList>pkg__Payment__c.pkg__Opportunity__c</relatedList>
        \\    </relatedLists>
        \\</Layout>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    const source =
        \\public class PackageDescribeRelationshipTest {
        \\    public static String test() {
        \\        Boolean found = false;
        \\        List<Schema.ChildRelationship> rels =
        \\            Opportunity.SObjectType.getDescribe().getChildRelationships();
        \\        for (Schema.ChildRelationship rel : rels) {
        \\            if (
        \\                rel.getRelationshipName() == 'pkg__Payment__r' &&
        \\                rel.getField().getDescribe().getName() == 'pkg__Opportunity__c' &&
        \\                String.valueOf(rel.getChildSObject()) == 'pkg__Payment__c'
        \\            ) {
        \\                found = true;
        \\            }
        \\        }
        \\        return String.valueOf(found);
        \\    }
        \\}
    ;
    var result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackageDescribeRelationshipTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true", result.value.string);
}

test "E2E: missing standard Opportunity child relationships default to empty lists" {
    const source =
        \\public class StandardOpportunityChildRelationshipTest {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(Name = 'Gift');
        \\        return String.valueOf(opp.OpportunityContactRoles.isEmpty()) + ':' +
        \\            String.valueOf(opp.OpportunityLineItems.isEmpty());
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "StandardOpportunityChildRelationshipTest",
        "test",
        "true:true",
    );
}

test "E2E: SObjectType directly exposes child relationships" {
    const source =
        \\public class DirectChildRelTest {
        \\    public static String test() {
        \\        Boolean found = false;
        \\        List<Schema.ChildRelationship> rels =
        \\            Schema.SObjectType.Opportunity.getChildRelationships();
        \\        for (Schema.ChildRelationship rel : rels) {
        \\            if (rel.getRelationshipName() == 'OpportunityContactRoles') {
        \\                found = true;
        \\            }
        \\        }
        \\        return String.valueOf(found);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DirectChildRelTest", "test", "true");
}

test "E2E: user methods can hash distinct SObject field combinations" {
    const source =
        \\public class SoftCreditHashProbe {
        \\    public class SoftCredit {
        \\        private OpportunityContactRole role;
        \\        public SoftCredit(OpportunityContactRole role) {
        \\            this.role = role;
        \\        }
        \\        private String roleName() {
        \\            return this.role.Role;
        \\        }
        \\        private Id contactId() {
        \\            return this.role.ContactId;
        \\        }
        \\        public Integer contactRoleHashCode() {
        \\            return (roleName() + contactId()).hashCode();
        \\        }
        \\    }
        \\    public static String test() {
        \\        String prefix = Contact.SObjectType.getDescribe().getKeyPrefix();
        \\        Id contactA = prefix + '000000000001AAA';
        \\        Id contactB = prefix + '000000000002AAA';
        \\        Map<Integer, OpportunityContactRole> rows =
        \\            new Map<Integer, OpportunityContactRole>();
        \\        List<OpportunityContactRole> roles = new List<OpportunityContactRole>{
        \\            new OpportunityContactRole(Role = 'Soft Credit', ContactId = contactA),
        \\            new OpportunityContactRole(Role = 'Household Member', ContactId = contactA),
        \\            new OpportunityContactRole(Role = 'Soft Credit', ContactId = contactB)
        \\        };
        \\        for (OpportunityContactRole row : roles) {
        \\            SoftCredit softCredit = new SoftCredit(row);
        \\            rows.put(softCredit.contactRoleHashCode(), row);
        \\        }
        \\        return String.valueOf(rows.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SoftCreditHashProbe", "test", "3");
}

test "E2E: static property getter can update its backing value repeatedly" {
    const source =
        \\public class StaticPropertyIncrementProbe {
        \\    private static Integer counter {
        \\        get {
        \\            if (counter == null) {
        \\                counter = 0;
        \\            }
        \\            counter++;
        \\            return counter;
        \\        }
        \\        set;
        \\    }
        \\    public static String test() {
        \\        Integer first = counter;
        \\        Integer second = counter;
        \\        Integer third = counter;
        \\        return String.valueOf(first) + ':' +
        \\            String.valueOf(second) + ':' + String.valueOf(third);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StaticPropertyIncrementProbe", "test", "1:2:3");
}

test "E2E: instance property getter can update its backing value repeatedly" {
    const source =
        \\public class InstancePropertyIncrementProbe {
        \\    private Integer counter {
        \\        get {
        \\            if (counter == null) {
        \\                counter = 0;
        \\            }
        \\            counter++;
        \\            return counter;
        \\        }
        \\        set;
        \\    }
        \\    public static String test() {
        \\        InstancePropertyIncrementProbe probe = new InstancePropertyIncrementProbe();
        \\        Integer first = probe.counter;
        \\        Integer second = probe.counter;
        \\        Integer third = probe.counter;
        \\        return String.valueOf(first) + ':' +
        \\            String.valueOf(second) + ':' + String.valueOf(third);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InstancePropertyIncrementProbe", "test", "1:2:3");
}

test "E2E: instance property setter can assign through same property name" {
    const source =
        \\public class SelfAssigningPropertySetterProbe {
        \\    public String marker {
        \\        get {
        \\            return marker;
        \\        }
        \\        set {
        \\            this.marker = value;
        \\        }
        \\    }
        \\    public static String test() {
        \\        SelfAssigningPropertySetterProbe probe =
        \\            new SelfAssigningPropertySetterProbe();
        \\        probe.marker = 'stored';
        \\        return probe.marker;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SelfAssigningPropertySetterProbe", "test", "stored");
}

test "E2E: stub stored in inherited property is invoked from child method" {
    const source =
        \\public interface StubProvider {
        \\    Object handleMethodCall(
        \\        Object stubbedObject,
        \\        String stubbedMethodName,
        \\        Type returnType,
        \\        List<Type> paramTypes,
        \\        List<String> params,
        \\        List<Object> paramValues
        \\    );
        \\}
        \\public virtual class GatewayTarget {
        \\    public virtual void handleBeforeDelete(List<Object> triggerOld) {
        \\    }
        \\}
        \\public virtual class StubHolderBase {
        \\    public GatewayTarget gateway {
        \\        get {
        \\            if (gateway == null) {
        \\                gateway = new GatewayTarget();
        \\            }
        \\            return gateway;
        \\        }
        \\        set;
        \\    }
        \\}
        \\public class StubHolderChild extends StubHolderBase {
        \\    public void dispatch(List<Object> rows) {
        \\        gateway.handleBeforeDelete(rows);
        \\    }
        \\}
        \\public class InheritedStubProvider implements StubProvider {
        \\    public Map<String, Object> calls = new Map<String, Object>();
        \\    public Object handleMethodCall(
        \\        Object stubbedObject,
        \\        String stubbedMethodName,
        \\        Type returnType,
        \\        List<Type> paramTypes,
        \\        List<String> params,
        \\        List<Object> paramValues
        \\    ) {
        \\        calls.put(stubbedMethodName, paramValues[0]);
        \\        return null;
        \\    }
        \\}
        \\public class InheritedStubPropertyProbe {
        \\    public static Boolean test() {
        \\        StubHolderChild child = new StubHolderChild();
        \\        InheritedStubProvider provider = new InheritedStubProvider();
        \\        child.gateway = (GatewayTarget) Test.createStub(GatewayTarget.class, provider);
        \\        List<Object> rows = new List<Object>{ 'old' };
        \\        child.dispatch(rows);
        \\        return provider.calls.containsKey('handleBeforeDelete') &&
        \\            provider.calls.get('handleBeforeDelete') == rows;
        \\    }
        \\}
    ;
    try expect_entry_boolean(source, "InheritedStubPropertyProbe", "test", true);
}

test "E2E: overloaded constructor with Id invokes stubbed selector" {
    const source =
        \\public class SelectorTarget {
        \\    public virtual List<Account> getRows(String fieldName, Id recordId) {
        \\        return new List<Account>();
        \\    }
        \\    public virtual List<Account> getRowsByIds(List<Id> recordIds) {
        \\        return new List<Account>{ new Account(Name = 'wrong') };
        \\    }
        \\}
        \\public class SelectorHolder {
        \\    public SelectorTarget selector {
        \\        get {
        \\            if (selector == null) {
        \\                selector = new SelectorTarget();
        \\            }
        \\            return selector;
        \\        }
        \\        set;
        \\    }
        \\    public Integer count;
        \\    public SelectorHolder(Id recordId, SelectorTarget selector) {
        \\        this.selector = selector;
        \\        count = 0;
        \\        for (Account row : this.selector.getRows('AccountId', recordId)) {
        \\            count++;
        \\        }
        \\    }
        \\    public SelectorHolder(List<Id> recordIds, SelectorTarget selector) {
        \\        this.selector = selector;
        \\        count = 100;
        \\        for (Account row : this.selector.getRowsByIds(recordIds)) {
        \\            count++;
        \\        }
        \\    }
        \\}
        \\public class SelectorRecorder implements StubProvider {
        \\    public Object handleMethodCall(Object stubbedObject, String stubbedMethodName, Type returnType,
        \\        List<Type> paramTypes, List<String> params, List<Object> paramValues) {
        \\        switch on (stubbedMethodName) {
        \\            when 'getRows' {
        \\                return new List<Account>{ new Account(Name = 'A'), new Account(Name = 'B') };
        \\            }
        \\        }
        \\        return new List<Account>();
        \\    }
        \\}
        \\public class StubbedIdConstructorProbe {
        \\    public static String test() {
        \\        SelectorTarget selector = (SelectorTarget) Test.createStub(
        \\            SelectorTarget.class,
        \\            new SelectorRecorder()
        \\        );
        \\        SelectorHolder holder = new SelectorHolder('001000000000001', selector);
        \\        return String.valueOf(holder.count);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StubbedIdConstructorProbe", "test", "2");
}

test "E2E: inner StubProvider can back Test.createStub" {
    const source =
        \\public class InnerStubProviderProbe {
        \\    public virtual class SelectorTarget {
        \\        public virtual List<Account> getRows(String fieldName, Id recordId) {
        \\            return new List<Account>();
        \\        }
        \\    }
        \\    private class SelectorRecorder implements StubProvider {
        \\        public Object handleMethodCall(Object stubbedObject, String stubbedMethodName, Type returnType,
        \\            List<Type> paramTypes, List<String> params, List<Object> paramValues) {
        \\            switch on (stubbedMethodName) {
        \\                when 'getRows' {
        \\                    return new List<Account>{ new Account(Name = 'A'), new Account(Name = 'B') };
        \\                }
        \\            }
        \\            return new List<Account>();
        \\        }
        \\    }
        \\    public static String test() {
        \\        SelectorTarget selector = (SelectorTarget) Test.createStub(
        \\            SelectorTarget.class,
        \\            new SelectorRecorder()
        \\        );
        \\        Integer count = 0;
        \\        for (Account row : selector.getRows('AccountId', '001000000000001')) {
        \\            count++;
        \\        }
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InnerStubProviderProbe", "test", "2");
}

test "E2E: Test.createStub intercepts non-virtual selector method" {
    const source =
        \\public class NonVirtualSelectorTarget {
        \\    public List<Account> getRows(String fieldName, Id recordId) {
        \\        return new List<Account>();
        \\    }
        \\}
        \\public class NonVirtualStubProbe {
        \\    private class SelectorRecorder implements StubProvider {
        \\        public Object handleMethodCall(Object stubbedObject, String stubbedMethodName, Type returnType,
        \\            List<Type> paramTypes, List<String> params, List<Object> paramValues) {
        \\            switch on (stubbedMethodName) {
        \\                when 'getRows' {
        \\                    return new List<Account>{ new Account(Name = 'A'), new Account(Name = 'B') };
        \\                }
        \\            }
        \\            return new List<Account>();
        \\        }
        \\    }
        \\    public static String test() {
        \\        NonVirtualSelectorTarget selector = (NonVirtualSelectorTarget) Test.createStub(
        \\            NonVirtualSelectorTarget.class,
        \\            new SelectorRecorder()
        \\        );
        \\        Integer count = 0;
        \\        for (Account row : selector.getRows('AccountId', '001000000000001')) {
        \\            count++;
        \\        }
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NonVirtualStubProbe", "test", "2");
}

test "E2E: DTO list field initialized and copied through view constructor" {
    const source =
        \\public class MiniDonation {
        \\    public Account account;
        \\    public MiniDonation(Account account) {
        \\        this.account = account;
        \\    }
        \\}
        \\public class MiniDonations {
        \\    private List<MiniDonation> donations = new List<MiniDonation>();
        \\    public MiniDonations(List<Account> accounts) {
        \\        for (Account account : accounts) {
        \\            donations.add(new MiniDonation(account));
        \\        }
        \\    }
        \\    public List<MiniDonation> all() {
        \\        return donations;
        \\    }
        \\}
        \\public class MiniDonationDTO {
        \\    public Object account;
        \\    public MiniDonationDTO(MiniDonation donation) {
        \\        this.account = donation.account;
        \\    }
        \\}
        \\public class MiniDonationsDTO {
        \\    public List<MiniDonationDTO> donationDTOs = new List<MiniDonationDTO>();
        \\    public MiniDonationsDTO(MiniDonations donations) {
        \\        for (MiniDonation donation : donations.all()) {
        \\            donationDTOs.add(new MiniDonationDTO(donation));
        \\        }
        \\    }
        \\}
        \\public class MiniDonationView {
        \\    public Map<String, Object> account;
        \\    public MiniDonationView(MiniDonationDTO donationDTO) {
        \\        this.account = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(donationDTO.account));
        \\    }
        \\}
        \\public class MiniDonationsView {
        \\    public List<MiniDonationView> donations = new List<MiniDonationView>();
        \\    public MiniDonationsView(MiniDonationsDTO donationsDTO) {
        \\        for (MiniDonationDTO donationDTO : donationsDTO.donationDTOs) {
        \\            donations.add(new MiniDonationView(donationDTO));
        \\        }
        \\    }
        \\}
        \\public class DtoViewListProbe {
        \\    public static String test() {
        \\        MiniDonations donations = new MiniDonations(new List<Account>{
        \\            new Account(Name = 'A'),
        \\            new Account(Name = 'B')
        \\        });
        \\        MiniDonationsView view = new MiniDonationsView(new MiniDonationsDTO(donations));
        \\        return String.valueOf(view.donations.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DtoViewListProbe", "test", "2");
}

test "E2E: constructor private helper updates unqualified instance field" {
    const source =
        \\public class ConstructorHelperFieldProbe {
        \\    private List<Account> rows;
        \\    public ConstructorHelperFieldProbe() {
        \\        initialize();
        \\    }
        \\    private void initialize() {
        \\        if (rows == null) {
        \\            rows = new List<Account>();
        \\        }
        \\        rows.add(new Account(Name = 'A'));
        \\    }
        \\    public List<Account> getRows() {
        \\        return this.rows;
        \\    }
        \\    public static String test() {
        \\        ConstructorHelperFieldProbe probe = new ConstructorHelperFieldProbe();
        \\        return String.valueOf(probe.getRows().size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ConstructorHelperFieldProbe", "test", "1");
}

test "E2E: constructor stores parameter in field with same-named accessor method" {
    const source =
        \\public class SameNamedAccessorProbe {
        \\    private Opportunity opportunity;
        \\    public SameNamedAccessorProbe(Opportunity opportunity) {
        \\        this.opportunity = opportunity;
        \\    }
        \\    public Opportunity opportunity() {
        \\        return this.opportunity;
        \\    }
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        SameNamedAccessorProbe probe = new SameNamedAccessorProbe(opp);
        \\        return probe.opportunity().Id;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SameNamedAccessorProbe", "test", "006000000000001AAA");
}

test "E2E: constructor preserves SObject child relationship on stored field" {
    const source =
        \\public class StoredRelationshipProbe {
        \\    private Opportunity opportunity;
        \\    public StoredRelationshipProbe(Opportunity opportunity) {
        \\        this.opportunity = opportunity;
        \\    }
        \\    public Opportunity opportunity() {
        \\        return this.opportunity;
        \\    }
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        List<npe01__OppPayment__c> payments = new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false, npe01__Written_Off__c = false)
        \\        };
        \\        String parentJSON = JSON.serialize(opportunity);
        \\        String childJSON = '"npe01__OppPayment__r": {"totalSize": 1, "done": true,' +
        \\            '"records": ' + JSON.serialize(payments) + '}';
        \\        parentJSON = parentJSON.substring(0, parentJSON.length() - 1) + ',' + childJSON + '}';
        \\        opportunity = (Opportunity) JSON.deserialize(parentJSON, Opportunity.class);
        \\        StoredRelationshipProbe probe = new StoredRelationshipProbe(opportunity);
        \\        return String.valueOf(probe.opportunity().npe01__OppPayment__r.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StoredRelationshipProbe", "test", "1");
}

test "E2E: typed for loop preserves SObject child relationship" {
    const source =
        \\public class ForLoopRelationshipProbe {
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        SObject envelope = new SObject();
        \\        envelope.put('records', new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false),
        \\            new npe01__OppPayment__c(npe01__Paid__c = false)
        \\        });
        \\        opportunity.put('npe01__OppPayment__r', envelope);
        \\        List<Opportunity> opportunities = new List<Opportunity>{ opportunity };
        \\        Integer sizeValue = -1;
        \\        for (Opportunity row : opportunities) {
        \\            sizeValue = row.npe01__OppPayment__r.size();
        \\        }
        \\        return String.valueOf(sizeValue);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ForLoopRelationshipProbe", "test", "2");
}

test "E2E: constructor called from typed for loop preserves child relationship" {
    const source =
        \\public class LoopStoredRelationship {
        \\    private Opportunity opportunity;
        \\    public LoopStoredRelationship(Opportunity opportunity) {
        \\        this.opportunity = opportunity;
        \\    }
        \\    public Opportunity opportunity() {
        \\        return this.opportunity;
        \\    }
        \\}
        \\public class LoopConstructorRelationshipProbe {
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        SObject envelope = new SObject();
        \\        envelope.put('records', new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false),
        \\            new npe01__OppPayment__c(npe01__Paid__c = false)
        \\        });
        \\        opportunity.put('npe01__OppPayment__r', envelope);
        \\        List<Opportunity> opportunities = new List<Opportunity>{ opportunity };
        \\        List<LoopStoredRelationship> stored = new List<LoopStoredRelationship>();
        \\        for (Opportunity row : opportunities) {
        \\            stored.add(new LoopStoredRelationship(row));
        \\        }
        \\        return String.valueOf(stored[0].opportunity().npe01__OppPayment__r.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "LoopConstructorRelationshipProbe", "test", "2");
}

test "E2E: stubbed selector returns child relationship through aggregate" {
    const source =
        \\public class StubRelationshipSelector {
        \\    public List<Opportunity> getOpenDonations(String fieldName, Id recordId) {
        \\        return new List<Opportunity>();
        \\    }
        \\}
        \\public class StubRelationshipDonation {
        \\    private Opportunity opportunity;
        \\    private List<npe01__OppPayment__c> unpaidPayments;
        \\    public StubRelationshipDonation(Opportunity opportunity) {
        \\        this.opportunity = opportunity;
        \\        unpaidPayments = new List<npe01__OppPayment__c>();
        \\        for (npe01__OppPayment__c payment : opportunity.npe01__OppPayment__r) {
        \\            unpaidPayments.add(payment);
        \\        }
        \\    }
        \\    public List<npe01__OppPayment__c> unpaidPayments() {
        \\        return unpaidPayments;
        \\    }
        \\}
        \\public class StubRelationshipDonations {
        \\    private List<StubRelationshipDonation> donations = new List<StubRelationshipDonation>();
        \\    public StubRelationshipDonations(Id donorId, StubRelationshipSelector selector) {
        \\        for (Opportunity opportunity : selector.getOpenDonations('AccountId', donorId)) {
        \\            donations.add(new StubRelationshipDonation(opportunity));
        \\        }
        \\    }
        \\    public List<StubRelationshipDonation> all() {
        \\        return donations;
        \\    }
        \\}
        \\public class StubRelationshipRecorder implements StubProvider {
        \\    public Object handleMethodCall(Object stubbedObject, String stubbedMethodName, Type returnType,
        \\        List<Type> paramTypes, List<String> params, List<Object> paramValues) {
        \\        Opportunity opportunity = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        SObject envelope = new SObject();
        \\        envelope.put('records', new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false),
        \\            new npe01__OppPayment__c(npe01__Paid__c = false),
        \\            new npe01__OppPayment__c(npe01__Paid__c = false)
        \\        });
        \\        opportunity.put('npe01__OppPayment__r', envelope);
        \\        return new List<Opportunity>{ opportunity };
        \\    }
        \\}
        \\public class StubRelationshipAggregateProbe {
        \\    public static String test() {
        \\        StubRelationshipSelector selector = (StubRelationshipSelector) Test.createStub(
        \\            StubRelationshipSelector.class,
        \\            new StubRelationshipRecorder()
        \\        );
        \\        StubRelationshipDonations donations =
        \\            new StubRelationshipDonations('001000000000001', selector);
        \\        return String.valueOf(donations.all()[0].unpaidPayments().size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StubRelationshipAggregateProbe", "test", "3");
}

test "E2E: nested constructor overload ignores outer constructor hints" {
    const source =
        \\public class ConstructorHintDonation {
        \\    private Integer selected;
        \\    public ConstructorHintDonation(Opportunity opportunity) {
        \\        selected = 7;
        \\    }
        \\    public ConstructorHintDonation(Id opportunityId) {
        \\        selected = 1;
        \\    }
        \\    public Integer selectedValue() {
        \\        return selected;
        \\    }
        \\}
        \\public class ConstructorHintAggregate {
        \\    private List<ConstructorHintDonation> donations =
        \\        new List<ConstructorHintDonation>();
        \\    public ConstructorHintAggregate(Id donorId, List<Opportunity> opportunities) {
        \\        for (Opportunity opportunity : opportunities) {
        \\            donations.add(new ConstructorHintDonation(opportunity));
        \\        }
        \\    }
        \\    public Integer selectedValue() {
        \\        return donations[0].selectedValue();
        \\    }
        \\}
        \\public class ConstructorHintLeakProbe {
        \\    public static String test() {
        \\        List<Opportunity> opportunities = new List<Opportunity>{
        \\            new Opportunity(Id = '006000000000001AAA', Name = 'Gift')
        \\        };
        \\        ConstructorHintAggregate aggregate =
        \\            new ConstructorHintAggregate('001000000000001AAA', opportunities);
        \\        return String.valueOf(aggregate.selectedValue());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ConstructorHintLeakProbe", "test", "7");
}

test "E2E: runtime override beats higher-scored ancestor method candidate" {
    const source =
        \\global abstract class OverrideDispatchBase {
        \\    global enum Action { BeforeDelete }
        \\    global abstract String run(
        \\        List<SObject> newlist,
        \\        List<SObject> oldlist,
        \\        Action triggerAction,
        \\        Schema.DescribeSObjectResult objResult
        \\    );
        \\}
        \\public class OverrideDispatchChild extends OverrideDispatchBase {
        \\    public override String run(
        \\        List<SObject> rds,
        \\        List<SObject> oldRds,
        \\        OverrideDispatchBase.Action triggerAction,
        \\        Schema.DescribeSObjectResult objResult
        \\    ) {
        \\        return 'child:' + String.valueOf(oldRds.size()) + ':' +
        \\            String.valueOf(triggerAction);
        \\    }
        \\}
        \\public class OverrideDispatchProbe {
        \\    public static String test() {
        \\        OverrideDispatchChild child = new OverrideDispatchChild();
        \\        List<SObject> oldRows = new List<SObject>{ new Account(Name = 'Acme') };
        \\        return child.run(
        \\            null,
        \\            oldRows,
        \\            OverrideDispatchBase.Action.BeforeDelete,
        \\            Account.SObjectType.getDescribe()
        \\        );
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OverrideDispatchProbe", "test", "child:1:BeforeDelete");
}

test "E2E: JSON deserialize resolves qualified inner class fields" {
    const source =
        \\public class QualifiedJsonOuter {
        \\    public class Child {
        \\        public String name;
        \\    }
        \\    public class Model {
        \\        public QualifiedJsonOuter.Child child;
        \\    }
        \\    public static String test() {
        \\        Model model = new Model();
        \\        model.child = new Child();
        \\        model.child.name = 'nested';
        \\        String body = JSON.serialize(model);
        \\        Model parsed = (Model) JSON.deserialize(body, Model.class);
        \\        return parsed.child.name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "QualifiedJsonOuter", "test", "nested");
}

test "E2E: list addAll preserves SObject fields through dedupe map" {
    const source =
        \\public class SoftCreditsAddAllProbe {
        \\    public class SoftCredit {
        \\        private OpportunityContactRole role;
        \\        public SoftCredit(OpportunityContactRole role) {
        \\            this.role = role;
        \\        }
        \\        private String roleName() {
        \\            return this.role.Role;
        \\        }
        \\        private Id contactId() {
        \\            return this.role.ContactId;
        \\        }
        \\        public Integer hash() {
        \\            return (roleName() + contactId()).hashCode();
        \\        }
        \\    }
        \\    public class SoftCredits {
        \\        private List<OpportunityContactRole> opportunityContactRoles =
        \\            new List<OpportunityContactRole>();
        \\        public SoftCredits(List<OpportunityContactRole> roles) {
        \\            this.opportunityContactRoles = deduplicate(roles);
        \\        }
        \\        public Integer size() {
        \\            return opportunityContactRoles.size();
        \\        }
        \\        public void addAll(List<OpportunityContactRole> moreRoles) {
        \\            this.opportunityContactRoles = deduplicate(moreRoles);
        \\        }
        \\        private List<OpportunityContactRole> deduplicate(
        \\            List<OpportunityContactRole> moreRoles
        \\        ) {
        \\            List<OpportunityContactRole> allRoles = new List<OpportunityContactRole>();
        \\            allRoles.addAll(opportunityContactRoles);
        \\            allRoles.addAll(moreRoles);
        \\            Map<Integer, OpportunityContactRole> byHash =
        \\                new Map<Integer, OpportunityContactRole>();
        \\            for (OpportunityContactRole row : allRoles) {
        \\                byHash.put(new SoftCredit(row).hash(), row);
        \\            }
        \\            return byHash.values();
        \\        }
        \\    }
        \\    public static String test() {
        \\        SoftCredits credits = new SoftCredits(new List<OpportunityContactRole>());
        \\        credits.addAll(new List<OpportunityContactRole>{
        \\            new OpportunityContactRole(Role = 'Influencer'),
        \\            new OpportunityContactRole(Role = 'Honoree'),
        \\            new OpportunityContactRole(Role = 'Household Member')
        \\        });
        \\        return String.valueOf(credits.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SoftCreditsAddAllProbe", "test", "3");
}

test "E2E: unsaved SObject map keys compare by populated fields" {
    const source =
        \\public class UnsavedSObjectMapKeyProbe {
        \\    public static String test() {
        \\        Map<SObject, String> byContact = new Map<SObject, String>();
        \\        byContact.put(
        \\            new Contact(FirstName = 'Ada', LastName = 'Lovelace'),
        \\            'matched'
        \\        );
        \\        SObject sameContact =
        \\            new Contact(LastName = 'Lovelace', FirstName = 'Ada');
        \\        SObject differentContact =
        \\            new Contact(FirstName = 'Ada', LastName = 'Byron');
        \\        return byContact.get(sameContact) + ':' +
        \\            String.valueOf(byContact.get(differentContact));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UnsavedSObjectMapKeyProbe", "test", "matched:null");
}

test "E2E: top-level class name wins over colliding inner class name" {
    const source =
        \\public class OuterWithNameCollision {
        \\    public class SoftCredit {
        \\        public String marker() {
        \\            return 'inner';
        \\        }
        \\    }
        \\}
        \\public class SoftCredit {
        \\    public String marker() {
        \\        return 'top';
        \\    }
        \\}
        \\public class TopLevelNameCollisionProbe {
        \\    public static String test() {
        \\        return new SoftCredit().marker();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TopLevelNameCollisionProbe", "test", "top");
}

test "E2E: Type values compare by class name" {
    const source =
        \\public class TypeEqualityProbe {
        \\    private static final Type ACCOUNT_TYPE = Account.class;
        \\    public static String test() {
        \\        Type other = Type.forName('Account');
        \\        return String.valueOf(ACCOUNT_TYPE == other) + ':' +
        \\            String.valueOf(ACCOUNT_TYPE != other);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TypeEqualityProbe", "test", "true:false");
}

test "E2E: String.format unescapes doubled single quotes" {
    const source =
        \\public class StringFormatSingleQuoteTest {
        \\    public static String test() {
        \\        return String.format(
        \\            'SELECT Id FROM Account WHERE Id > \'\'{0}\'\' LIMIT {1}',
        \\            new List<String>{ '001000000000001', '10' }
        \\        );
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StringFormatSingleQuoteTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "SELECT Id FROM Account WHERE Id > '001000000000001' LIMIT 10",
        result.value.string,
    );
}

test "E2E: EmailMessage display field selection prefers Subject when Name is absent" {
    const source =
        \\public class EmailMessageDisplayFieldTest {
        \\    private static String getDisplayFieldApiName(Schema.SObjectType sobjectType) {
        \\        if (sobjectType == Schema.User.SObjectType) {
        \\            return Schema.User.Username.toString();
        \\        }
        \\        List<String> educatedGuesses = new List<String>{
        \\            'Name',
        \\            'DeveloperName',
        \\            'ApiName',
        \\            'Title',
        \\            'Subject'
        \\        };
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
        \\        EmailMessage emailMessage = new EmailMessage(
        \\            ParentId = supportCase.Id,
        \\            Subject = 'Some subject'
        \\        );
        \\        insert emailMessage;
        \\        String displayField = getDisplayFieldApiName(emailMessage.Id.getSObjectType());
        \\        List<Id> recordIds = new List<Id>{ emailMessage.Id };
        \\        List<SObject> results = Database.query(
        \\            String.format(
        \\                'SELECT {0} FROM {1} WHERE Id IN :recordIds',
        \\                new List<Object>{ displayField, emailMessage.Id.getSObjectType() }
        \\            )
        \\        );
        \\        return displayField + ':' + (String) results.get(0).get(displayField);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "EmailMessageDisplayFieldTest", "test", "Subject:Some subject");
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
        \\    private static Map<Schema.SObjectType, List<ChainedHandlerBase>> executed =
        \\        new Map<Schema.SObjectType, List<ChainedHandlerBase>>();
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
        \\        return String.valueOf(
        \\            ChainedHandlerStore.getExecuted().get(Schema.LogEntryEvent__e.SObjectType).size()
        \\        ) +
        \\            '|' +
        \\            ChainedHandlerStore.getExecuted()
        \\                .get(Schema.LogEntryEvent__e.SObjectType)
        \\                .get(1)
        \\                .name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ChainedHandlerStoreTest", "test", "2|second");
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
        \\        HandlerExecutionChild child = (HandlerExecutionChild)
        \\            HandlerExecutionBase.getExecuted().get(0);
        \\        return child.executedOperation + '|' +
        \\            String.valueOf(child.executedTriggerNew.size()) + '|' +
        \\            String.valueOf(child.executedTriggerNew.get(0).get('Name'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "HandlerExecutionChildTest", "test", "before|2|first");
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
    try expect_entry_string(source, "NestedOverloadChildTest", "test", "2|true");
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
    try expect_entry_string(source, "OverloadDispatchChildTest", "test", "child-list|base-map");
}

test "E2E: Object-wrapped primitive values support null-safe toString" {
    const source =
        \\public class PrimitiveObjectToStringTest {
        \\    public static String test() {
        \\        Object boolValue = true;
        \\        Object intValue = 1;
        \\        Object doubleValue = 1.5;
        \\        return boolValue?.toString() +
        \\            '|' + intValue?.toString() +
        \\            '|' + doubleValue?.toString();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PrimitiveObjectToStringTest", "test", "true|1|1.5");
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
    try expect_entry_string(source, "InstallHandlerTest", "test", "1");
}

test "E2E: System.Test.testUninstall invokes uninstall handlers" {
    const source =
        \\global class PackageUninstallHook implements System.UninstallHandler {
        \\    global void onUninstall(System.UninstallContext uninstallContext) {
        \\        delete [SELECT Id FROM Account];
        \\    }
        \\}
        \\public class UninstallHandlerTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'Installed');
        \\        System.Test.testUninstall(new PackageUninstallHook());
        \\        return String.valueOf([SELECT Id FROM Account].size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UninstallHandlerTest", "test", "0");
}

test "E2E: SObject.getSObject resolves parent records from a reference field token" {
    const source =
        \\public class GetSObjectParentTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Contact contactRecord = new Contact(LastName = 'User', AccountId = accountRecord.Id);
        \\        insert contactRecord;
        \\        Contact queried = [
        \\            SELECT AccountId, Account.Name
        \\            FROM Contact
        \\            WHERE Id = :contactRecord.Id
        \\        ];
        \\        SObject parentRecord = queried.getSObject(Schema.Contact.AccountId);
        \\        return String.valueOf(parentRecord.get('Name'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "GetSObjectParentTest", "test", "Acme");
}

test "E2E: Map keyed by equivalent unsaved SObject resolves value" {
    const source =
        \\public class EquivalentSObjectMapKeyProbe {
        \\    public static String test() {
        \\        Contact stored = new Contact(
        \\            FirstName = 'Ada',
        \\            LastName = 'Lovelace',
        \\            MailingStreet = '100 Fake Blvd'
        \\        );
        \\        Contact lookup = new Contact(
        \\            FirstName = 'Ada',
        \\            LastName = 'Lovelace',
        \\            MailingStreet = '100 Fake Blvd'
        \\        );
        \\        Map<SObject, String> values = new Map<SObject, String>();
        \\        values.put(stored, 'matched');
        \\        return values.get(lookup);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "EquivalentSObjectMapKeyProbe", "test", "matched");
}

test "E2E: Map literal preserves distinct unsaved SObject keys" {
    const source =
        \\public class SObjectMapLiteralKeyProbe {
        \\    public static String test() {
        \\        Contact first = new Contact(FirstName = 'Ada', LastName = 'Lovelace');
        \\        Contact second = new Contact(FirstName = 'Grace', LastName = 'Hopper');
        \\        Contact equivalentFirst = new Contact(FirstName = 'Ada', LastName = 'Lovelace');
        \\        Map<SObject, String> values = new Map<SObject, String>{
        \\            first => 'first',
        \\            second => 'second'
        \\        };
        \\        return String.valueOf(values.size()) + ':' +
        \\            values.get(equivalentFirst) + ':' +
        \\            values.get(second);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SObjectMapLiteralKeyProbe", "test", "2:first:second");
}

test "E2E: SObject.getSObject string rejects foreign key field names" {
    const source =
        \\public class GetSObjectForeignKeyStringTest {
        \\    public static String test() {
        \\        Contact contactRecord = new Contact(LastName = 'User');
        \\        try {
        \\            contactRecord.getSObject('AccountId');
        \\            return 'missing';
        \\        } catch (SObjectException ex) {
        \\            return ex.getMessage();
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "GetSObjectForeignKeyStringTest",
        "test",
        "Invalid relationship AccountId for Contact",
    );
}

test "E2E: update clearing lookup field invalidates queried parent relationship" {
    const source =
        \\public class UpdateClearsLookupRelationshipTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Contact contactRecord = new Contact(
        \\            LastName = 'User',
        \\            Primary_Affiliation__c = accountRecord.Id
        \\        );
        \\        insert contactRecord;
        \\        Contact queried = [
        \\            SELECT Id, Primary_Affiliation__c, Primary_Affiliation__r.Name
        \\            FROM Contact
        \\            WHERE Id = :contactRecord.Id
        \\        ];
        \\        queried.Primary_Affiliation__c = null;
        \\        update queried;
        \\        Contact again = [
        \\            SELECT Id, Primary_Affiliation__c, Primary_Affiliation__r.Name
        \\            FROM Contact
        \\            WHERE Id = :contactRecord.Id
        \\        ];
        \\        return again.getSObject('Primary_Affiliation__r') == null
        \\            ? ''
        \\            : String.valueOf(again.getSObject('Primary_Affiliation__r').get('Name'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UpdateClearsLookupRelationshipTest", "test", "");
}

test "E2E: SObject.getSObject resolves unsaved relationship records assigned via __r" {
    const source =
        \\public class GetUnsavedParentTest {
        \\    public static String test() {
        \\        Session__c sessionRecord = new Session__c(
        \\            Experience__r = new Experience__c(Name = 'Hiking')
        \\        );
        \\        SObject parentRecord = sessionRecord.getSObject(Schema.Session__c.Experience__c);
        \\        return String.valueOf(parentRecord.get('Name'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "GetUnsavedParentTest", "test", "Hiking");
}

test "E2E: direct property access resolves unsaved relationship records assigned via __r" {
    const source =
        \\public class DirectUnsavedParentTest {
        \\    public static String test() {
        \\        Session__c sessionRecord = new Session__c(
        \\            Experience__r = new Experience__c(Name = 'Hiking')
        \\        );
        \\        return sessionRecord.Experience__r.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DirectUnsavedParentTest", "test", "Hiking");
}

test "E2E: member-held property access resolves unsaved relationships" {
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
        \\        Session__c sessionRecord = new Session__c(
        \\            Experience__r = new Experience__c(Name = 'Hiking')
        \\        );
        \\        return new MemberHeldUnsavedParentTest(sessionRecord).getName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MemberHeldUnsavedParentTest", "test", "Hiking");
}

test "E2E: member-held property access resolves unsaved custom fields" {
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
        \\        Session__c sessionRecord = new Session__c(
        \\            Experience__r = new Experience__c(
        \\                Name = 'Hiking',
        \\                Type__c = 'Adventure'
        \\            )
        \\        );
        \\        return new MemberHeldUnsavedCustomFieldTest(sessionRecord).getType();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MemberHeldUnsavedCustomFieldTest", "test", "Adventure");
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
        \\        Session__c sessionRecord = new Session__c(
        \\            Experience__r = new Experience__c(
        \\                Name = 'Hiking',
        \\                Type__c = 'Adventure'
        \\            )
        \\        );
        \\        return new RelatedInitializerReadTest(sessionRecord).build().Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "RelatedInitializerReadTest", "test", "Adventure");
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
    try expect_entry_string(source, "ChildParentSubqueryTest", "test", "Acme");
}

test "E2E: child relationship subquery applies literal where filters" {
    const source =
        \\public class ChildSubqueryWhereFilterTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        insert new Contact(LastName = 'Open', AccountId = accountRecord.Id, Title = 'Keep');
        \\        insert new Contact(LastName = 'Closed', AccountId = accountRecord.Id, Title = 'Drop');
        \\        Account queried = [
        \\            SELECT Id, (SELECT Id, LastName FROM Contacts WHERE Title = 'Keep' ORDER BY Id)
        \\            FROM Account
        \\            WHERE Id = :accountRecord.Id
        \\        ];
        \\        return String.valueOf(queried.Contacts.size()) + ':' + queried.Contacts[0].LastName;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ChildSubqueryWhereFilterTest", "test", "1:Open");
}

test "E2E: child relationship subquery ignores From inside field names" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_generic_rollup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class ChildSubqueryFromFieldNameTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Acme');
        \\        insert parentRecord;
        \\        insert new Child__c(Parent__c = parentRecord.Id, DaysFromStart__c = 2);
        \\        List<Child__c> partial = [
        \\            SELECT Id, DaysFromStart__c
        \\            FROM Child__c
        \\            WHERE Parent__c = :parentRecord.Id
        \\        ];
        \\        update partial;
        \\        Parent__c queried = [
        \\            SELECT Id, (SELECT Id, DaysFromStart__c FROM Children__r ORDER BY Id)
        \\            FROM Parent__c
        \\            WHERE Id = :parentRecord.Id
        \\        ];
        \\        return String.valueOf(queried.Children__r.size()) + ':' +
        \\            String.valueOf(queried.Children__r[0].DaysFromStart__c);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ChildSubqueryFromFieldNameTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:2", result.value.string);
}

test "E2E: custom child subquery resolves numeric relationship names case-insensitively" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_numeric_child_relationship_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class NumericChildRelationshipSubqueryTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Acme');
        \\        insert parentRecord;
        \\        insert new Child__c(
        \\            Parent__c = parentRecord.Id,
        \\            Name = 'First',
        \\            Index__c = 1
        \\        );
        \\        Map<Id, Child__c> childByParentId = new Map<Id, Child__c>();
        \\        for (Child__c childRecord : [
        \\            SELECT Id, Parent__c
        \\            FROM Child__c
        \\            WHERE Parent__c = :parentRecord.Id
        \\        ]) {
        \\            childByParentId.put(childRecord.Parent__c, childRecord);
        \\        }
        \\        Parent__c queried = [
        \\            SELECT Id, (SELECT Id, Parent__c, Index__c FROM APTasks1__r)
        \\            FROM Parent__c
        \\            WHERE Id IN :childByParentId.keySet()
        \\        ];
        \\        return String.valueOf(queried.APTasks1__r.size());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "NumericChildRelationshipSubqueryTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: before delete trigger creates dependent records through child subquery" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_numeric_child_relationship_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class BeforeDeleteDependentWork {
        \\    public static void handle(List<Work__c> oldRows) {
        \\        Set<Id> controllerIds = new Set<Id>();
        \\        for (Work__c row : oldRows) {
        \\            if (row.Child__c != null) controllerIds.add(row.Child__c);
        \\        }
        \\        Map<Id, Child__c> childByParentId = new Map<Id, Child__c>();
        \\        for (Child__c childRecord : [
        \\            SELECT Id, Parent__c, TaskIndex__c
        \\            FROM Child__c
        \\            WHERE Id IN :controllerIds
        \\        ]) {
        \\            childByParentId.put(childRecord.Parent__c, childRecord);
        \\        }
        \\        for (Parent__c parentRecord : [
        \\            SELECT Id, (
        \\                SELECT Id, Parent__c, TaskIndex__c, Controller__c
        \\                FROM APTasks1__r
        \\            )
        \\            FROM Parent__c
        \\            WHERE Id IN :childByParentId.keySet()
        \\        ]) {
        \\            Child__c controller = childByParentId.get(parentRecord.Id);
        \\            createDependent(parentRecord.APTasks1__r, controller.TaskIndex__c);
        \\        }
        \\    }
        \\    private static void createDependent(List<Child__c> children, Decimal removedIndex) {
        \\        Set<Id> closed = new Set<Id>();
        \\        for (Child__c childRecord : children) {
        \\            if (childRecord.TaskIndex__c == removedIndex) closed.add(childRecord.Id);
        \\        }
        \\        List<Work__c> rows = new List<Work__c>();
        \\        for (Child__c childRecord : [
        \\            SELECT Id
        \\            FROM Child__c
        \\            WHERE Controller__c IN :closed
        \\        ]) {
        \\            rows.add(new Work__c(Name = 'Generated', Child__c = childRecord.Id));
        \\        }
        \\        Database.DMLOptions options = new Database.DMLOptions();
        \\        options.EmailHeader.triggerUserEmail = true;
        \\        Database.insert(rows, options);
        \\    }
        \\}
        \\trigger BeforeDeleteDependentWorkTrigger on Work__c (before delete) {
        \\    BeforeDeleteDependentWork.handle(Trigger.old);
        \\}
        \\public class BeforeDeleteDependentWorkTest {
        \\    public static String test() {
        \\        Parent__c parentRecord = new Parent__c(Name = 'Parent');
        \\        insert parentRecord;
        \\        Child__c first = new Child__c(
        \\            Parent__c = parentRecord.Id,
        \\            Name = 'First',
        \\            TaskIndex__c = 0
        \\        );
        \\        insert first;
        \\        Child__c second = new Child__c(
        \\            Parent__c = parentRecord.Id,
        \\            Name = 'Second',
        \\            Controller__c = first.Id,
        \\            TaskIndex__c = 1
        \\        );
        \\        insert second;
        \\        Work__c work = new Work__c(Name = 'Original', Child__c = first.Id);
        \\        insert work;
        \\        delete work;
        \\        return String.valueOf([
        \\            SELECT COUNT()
        \\            FROM Work__c
        \\            WHERE Child__c = :second.Id
        \\        ]);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "BeforeDeleteDependentWorkTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: Task lookup delete query with trigger oldMap keySet preserves nonmatching tasks" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_activity_lookup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\trigger TemplateDeleteProbeTrigger on Template__c (before delete) {
        \\    Database.delete([
        \\        SELECT Id
        \\        FROM Task
        \\        WHERE Template__c IN :Trigger.oldMap.keySet()
        \\        AND IsClosed = FALSE
        \\        AND IsDeleted = FALSE
        \\    ]);
        \\}
        \\public class TemplateDeleteProbeTest {
        \\    public static String test() {
        \\        Template__c first = new Template__c(Name = 'First');
        \\        Template__c second = new Template__c(Name = 'Second');
        \\        insert new List<Template__c>{ first, second };
        \\        insert new Task(Subject = 'Keep', Template__c = second.Id);
        \\        delete first;
        \\        Integer activeSecond = [
        \\            SELECT COUNT()
        \\            FROM Task
        \\            WHERE Template__c = :second.Id
        \\        ];
        \\        Integer allSecond = [
        \\            SELECT COUNT()
        \\            FROM Task
        \\            WHERE Template__c = :second.Id
        \\            ALL ROWS
        \\        ];
        \\        return String.valueOf(activeSecond) + ':' + String.valueOf(allSecond);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TemplateDeleteProbeTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:1", result.value.string);
}

test "E2E: Task lookup delete query with map parameter keySet preserves nonmatching tasks" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_activity_lookup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class TemplateDeleteProbeHandler {
        \\    public static void handle(Map<Id, Template__c> oldRowsById) {
        \\        Database.delete([
        \\            SELECT Id
        \\            FROM Task
        \\            WHERE Template__c IN :oldRowsById.keyset()
        \\            AND IsClosed = FALSE
        \\            AND IsDeleted = FALSE
        \\        ]);
        \\    }
        \\}
        \\trigger TemplateDeleteProbeTrigger on Template__c (before delete) {
        \\    TemplateDeleteProbeHandler.handle(Trigger.oldMap);
        \\}
        \\public class TemplateDeleteProbeTest {
        \\    public static String test() {
        \\        Template__c first = new Template__c(Name = 'First');
        \\        Template__c second = new Template__c(Name = 'Second');
        \\        insert new List<Template__c>{ first, second };
        \\        insert new Task(Subject = 'Keep', Template__c = second.Id);
        \\        delete first;
        \\        Integer activeSecond = [
        \\            SELECT COUNT()
        \\            FROM Task
        \\            WHERE Template__c = :second.Id
        \\        ];
        \\        Integer allSecond = [
        \\            SELECT COUNT()
        \\            FROM Task
        \\            WHERE Template__c = :second.Id
        \\            ALL ROWS
        \\        ];
        \\        return String.valueOf(activeSecond) + ':' + String.valueOf(allSecond);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TemplateDeleteProbeTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:1", result.value.string);
}

test "E2E: TaskAPTask lookup delete query preserves nonmatching tasks" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_activity_task_ap_task_lookup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class TemplateDeleteProbeHandler {
        \\    public static void handle(Map<Id, Template__c> oldRowsById) {
        \\        Database.delete([
        \\            SELECT Id
        \\            FROM Task
        \\            WHERE TaskAPTask__c IN :oldRowsById.keyset()
        \\            AND IsClosed = FALSE
        \\            AND IsDeleted = FALSE
        \\        ]);
        \\    }
        \\}
        \\trigger TemplateDeleteProbeTrigger on Template__c (before delete) {
        \\    TemplateDeleteProbeHandler.handle(Trigger.oldMap);
        \\}
        \\public class TemplateDeleteProbeTest {
        \\    public static String test() {
        \\        Template__c first = new Template__c(Name = 'First');
        \\        Template__c second = new Template__c(Name = 'Second');
        \\        insert new List<Template__c>{ first, second };
        \\        insert new Task(Subject = 'Keep', TaskAPTask__c = second.Id);
        \\        delete first;
        \\        Integer activeSecond = [
        \\            SELECT COUNT()
        \\            FROM Task
        \\            WHERE TaskAPTask__c = :second.Id
        \\        ];
        \\        Integer allSecond = [
        \\            SELECT COUNT()
        \\            FROM Task
        \\            WHERE TaskAPTask__c = :second.Id
        \\            ALL ROWS
        \\        ];
        \\        return String.valueOf(activeSecond) + ':' + String.valueOf(allSecond);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "TemplateDeleteProbeTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:1", result.value.string);
}

test "E2E: Activity child subquery hydrates Task computed fields" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try write_activity_task_ap_task_lookup_metadata_fixture(tmp_dir.dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class ActivityChildSubqueryComputedFieldTest {
        \\    public static String test() {
        \\        Template__c templateRecord = new Template__c(Name = 'Template');
        \\        insert templateRecord;
        \\        insert new Task(
        \\            Subject = 'Done',
        \\            Status = 'Completed',
        \\            TaskAPTask__c = templateRecord.Id
        \\        );
        \\        Template__c queried = [
        \\            SELECT Id, (SELECT Id, IsClosed FROM Tasks__r)
        \\            FROM Template__c
        \\            WHERE Id = :templateRecord.Id
        \\        ];
        \\        return String.valueOf(queried.Tasks__r.size()) + ':' +
        \\            String.valueOf(queried.Tasks__r[0].IsClosed);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ActivityChildSubqueryComputedFieldTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:true", result.value.string);
}

test "E2E: hard-deleted Task remains non-undeletable in recycle bin tombstone" {
    const source =
        \\public class HardDeletedTaskTombstoneTest {
        \\    public static String test() {
        \\        Task taskRecord = new Task(Subject = 'Delete');
        \\        insert taskRecord;
        \\        delete taskRecord;
        \\        Database.emptyRecycleBin(taskRecord);
        \\        Integer allRows = [
        \\            SELECT COUNT()
        \\            FROM Task
        \\            WHERE Id = :taskRecord.Id
        \\            ALL ROWS
        \\        ];
        \\        String caught = 'none';
        \\        try {
        \\            undelete taskRecord;
        \\        } catch (DmlException e) {
        \\            caught = 'dml';
        \\        }
        \\        return String.valueOf(allRows) + ':' + caught;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "HardDeletedTaskTombstoneTest", "test", "1:dml");
}

test "E2E: Case and Contract inserts populate auto-number fields" {
    const source =
        \\public class AutoNumberInsertProbe {
        \\    public static String test() {
        \\        Case c = new Case(Origin = 'Email', Status = 'New');
        \\        insert c;
        \\        Account a = new Account(Name = 'Acme');
        \\        insert a;
        \\        Contract contractRecord = new Contract(
        \\            AccountId = a.Id,
        \\            StartDate = Date.today(),
        \\            ContractTerm = 1
        \\        );
        \\        insert contractRecord;
        \\        return String.valueOf(c.CaseNumber != null) + ':' +
        \\            String.valueOf(contractRecord.ContractNumber != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AutoNumberInsertProbe", "test", "true:true");
}

test "E2E: Date plus integer shifts by days" {
    const source =
        \\public class DateIntegerArithmeticTest {
        \\    public static String test() {
        \\        Date startDate = Date.newInstance(2026, 5, 1);
        \\        Date nextDate = startDate + 2;
        \\        Date previousDate = nextDate - 1;
        \\        return String.valueOf(nextDate.daysBetween(previousDate)) + ':' +
        \\            String.valueOf(startDate.daysBetween(nextDate));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DateIntegerArithmeticTest", "test", "-1:2");
}

test "E2E: SOQL ORDER BY Id uses stored SObject ids" {
    const source =
        \\public class OrderByIdStoredFieldTest {
        \\    public static String test() {
        \\        Contact c1 = new Contact(LastName = 'First');
        \\        Contact c2 = new Contact(LastName = 'Second');
        \\        insert new List<Contact>{ c1, c2 };
        \\        c1.Title = 'Updated';
        \\        update c1;
        \\        List<Contact> rows = [SELECT Id, LastName FROM Contact ORDER BY Id];
        \\        return rows[0].Id + ':' + rows[0].LastName + '|' +
        \\            rows[1].Id + ':' + rows[1].LastName;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "OrderByIdStoredFieldTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "003000000000000001:First|003000000000000002:Second",
        result.value.string,
    );
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
    try expect_entry_string(source, "TopLevelCustomChildParentQueryTest", "test", "Acme");
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
    try expect_entry_string(source, "SoqlParentRefTest", "test", "1");
}

test "E2E: SOQL IN bind accepts map keySet call expressions" {
    const source =
        \\public class SoqlInMapKeySetProbe {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Map<Id, Account> recordsById = new Map<Id, Account>();
        \\        recordsById.put(accountRecord.Id, accountRecord);
        \\        Integer matched = [
        \\            SELECT COUNT()
        \\            FROM Account
        \\            WHERE Id IN :recordsById.keyset()
        \\        ];
        \\        return String.valueOf(matched);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SoqlInMapKeySetProbe", "test", "1");
}

test "E2E: SOQL IN bind accepts map keySet call expressions from parameters" {
    const source =
        \\public class SoqlInMapKeySetParamProbe {
        \\    public static Integer countMatches(Map<Id, Account> recordsById) {
        \\        return [
        \\            SELECT COUNT()
        \\            FROM Account
        \\            WHERE Id IN :recordsById.keyset()
        \\        ];
        \\    }
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Map<Id, Account> recordsById = new Map<Id, Account>();
        \\        recordsById.put(accountRecord.Id, accountRecord);
        \\        return String.valueOf(countMatches(recordsById));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SoqlInMapKeySetParamProbe", "test", "1");
}

test "E2E: DML delete accepts SOQL query results filtered by IN bind" {
    const source =
        \\public class DeleteQueryInBindProbe {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Contact contactRecord = new Contact(
        \\            LastName = 'Tester',
        \\            AccountId = accountRecord.Id
        \\        );
        \\        insert contactRecord;
        \\        Set<Id> accountIds = new Set<Id>{ accountRecord.Id };
        \\        delete [
        \\            SELECT Id
        \\            FROM Contact
        \\            WHERE AccountId IN :accountIds
        \\        ];
        \\        return String.valueOf([SELECT COUNT() FROM Contact]);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DeleteQueryInBindProbe", "test", "0");
}

test "E2E: Trigger.operationType switches inside helper methods" {
    const source =
        \\public class TriggerOperationSwitchHelper {
        \\    public static Integer beforeDeletes = 0;
        \\    public static void handle(System.TriggerOperation op) {
        \\        switch on op {
        \\            when BEFORE_DELETE {
        \\                beforeDeletes++;
        \\            }
        \\            when else {
        \\            }
        \\        }
        \\    }
        \\}
        \\trigger TriggerOperationSwitchProbeTrigger on Account (before delete) {
        \\    TriggerOperationSwitchHelper.handle(Trigger.operationType);
        \\}
        \\public class TriggerOperationSwitchProbe {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        delete accountRecord;
        \\        return String.valueOf(TriggerOperationSwitchHelper.beforeDeletes);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TriggerOperationSwitchProbe", "test", "1");
}

test "E2E: before delete trigger can Database.insert records with DmlOptions" {
    const source =
        \\public class BeforeDeleteDmlOptionsProbe {
        \\    public static void createContacts(List<Account> oldRows) {
        \\        List<Contact> contacts = new List<Contact>();
        \\        for (Account row : oldRows) {
        \\            contacts.add(new Contact(LastName = 'Generated'));
        \\        }
        \\        Database.DMLOptions options = new Database.DMLOptions();
        \\        options.EmailHeader.triggerUserEmail = true;
        \\        Database.insert(contacts, options);
        \\    }
        \\}
        \\trigger BeforeDeleteDmlOptionsProbeTrigger on Account (before delete) {
        \\    BeforeDeleteDmlOptionsProbe.createContacts(Trigger.old);
        \\}
        \\public class BeforeDeleteDmlOptionsProbeTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        delete accountRecord;
        \\        return String.valueOf([SELECT COUNT() FROM Contact]);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "BeforeDeleteDmlOptionsProbeTest", "test", "1");
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

test "E2E: SOQL empty string comparison matches missing text fields" {
    const source =
        \\public class SoqlEmptyStringNullProbe {
        \\    public static String test() {
        \\        insert new Account(Name = 'Unset Type');
        \\        insert new Account(Name = 'Household', npe01__SYSTEM_AccountType__c = 'Household');
        \\        List<Account> literalMatches = [
        \\            SELECT Id FROM Account WHERE npe01__SYSTEM_AccountType__c = ''
        \\        ];
        \\        String emptyValue = '';
        \\        List<Account> bindMatches = [
        \\            SELECT Id FROM Account WHERE npe01__SYSTEM_AccountType__c = :emptyValue
        \\        ];
        \\        return String.valueOf(literalMatches.size()) + ':' + String.valueOf(bindMatches.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SoqlEmptyStringNullProbe", "test", "1:1");
}

test "E2E: SOQL WHERE with null bind variable matches null values only" {
    const source =
        \\public class DbNullBindTest {
        \\    public static String test() {
        \\        insert new List<Account>{
        \\            new Account(Name = 'No Type'),
        \\            new Account(Name = 'Acme', Type = 'A'),
        \\            new Account(Name = 'Beta', Type = 'B')
        \\        };
        \\        String type = null;
        \\        String whereClause = 'WHERE Type = :type';
        \\        Integer count = Database.countQuery(
        \\            'SELECT count() FROM Account ' + whereClause
        \\        );
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DbNullBindTest", "test", "1");
}

test "E2E: SOQL WHERE Id equals null bind returns no rows" {
    const source =
        \\public class IdNullBindTest {
        \\    public static String test() {
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        Id selectedId = null;
        \\        List<Account> rows = [SELECT Id FROM Account WHERE Id = :selectedId];
        \\        return String.valueOf(rows.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "IdNullBindTest", "test", "0");
}

test "E2E: empty SOQL assigned to typed List stays an empty list" {
    const source =
        \\public class EmptyTypedListSoqlTest {
        \\    public static String test() {
        \\        List<Account> rows = [SELECT Id FROM Account WHERE Name = 'missing'];
        \\        return String.valueOf(rows.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "EmptyTypedListSoqlTest", "test", "0");
}

test "E2E: SOQL IN bind evaluates instance property getter" {
    const source =
        \\public class GetterBindQueryTest {
        \\    private Id accountId;
        \\    private Set<Id> selectedIds {
        \\        get {
        \\            return new Set<Id>{ accountId };
        \\        }
        \\    }
        \\    public String run() {
        \\        Account a = new Account(Name = 'A');
        \\        insert a;
        \\        accountId = a.Id;
        \\        List<Account> rows = [SELECT Id FROM Account WHERE Id IN :selectedIds];
        \\        return String.valueOf(rows.size());
        \\    }
        \\    public static String test() {
        \\        return new GetterBindQueryTest().run();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "GetterBindQueryTest", "test", "1");
}

test "E2E: Task IsClosed is computed from Status" {
    const source =
        \\public class TaskIsClosedTest {
        \\    public static String test() {
        \\        Task t = new Task(Subject = 'Call', Status = 'Completed');
        \\        Boolean direct = t.IsClosed;
        \\        insert t;
        \\        Task refreshed = [SELECT Id, IsClosed FROM Task WHERE Id = :t.Id];
        \\        return String.valueOf(direct) + ':' + String.valueOf(refreshed.IsClosed);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TaskIsClosedTest", "test", "true:true");
}

test "E2E: TaskStatus queries return default and closed statuses" {
    const source =
        \\public class TaskStatusQueryTest {
        \\    public static String test() {
        \\        TaskStatus openStatus = [SELECT MasterLabel FROM TaskStatus WHERE IsDefault = true LIMIT 1];
        \\        TaskStatus closedStatus = [SELECT MasterLabel FROM TaskStatus WHERE IsClosed = true LIMIT 1];
        \\        return openStatus.MasterLabel + ':' + closedStatus.MasterLabel;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TaskStatusQueryTest", "test", "Not Started:Completed");
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
    try expect_entry_string(source, "DbCountBindTest", "test", "2");
}

test "E2E: SOQL NOT IN empty bind collection matches records" {
    const source =
        \\public class NotInEmptyBindTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        Set<String> excluded = new Set<String>();
        \\        Integer count = Database.countQuery(
        \\            'SELECT count() FROM Account WHERE Type NOT IN :excluded'
        \\        );
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NotInEmptyBindTest", "test", "1");
}

test "E2E: managed package opportunity payment suppression defaults false in SOQL" {
    const source =
        \\public class PackageOppPaymentSuppressionDefaultTest {
        \\    public static String test() {
        \\        insert new Opportunity(
        \\            Name = 'Gift',
        \\            StageName = 'Closed Won',
        \\            CloseDate = Date.today(),
        \\            Amount = 100
        \\        );
        \\        Integer count = Database.countQuery(
        \\            'SELECT count() FROM Opportunity WHERE npe01__Do_Not_Automatically_Create_Payment__c = false'
        \\        );
        \\        return String.valueOf(count);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackageOppPaymentSuppressionDefaultTest", "test", "1");
}

test "E2E: managed package RD2 status mapper mock fields bypass compatibility shortcut" {
    const source =
        \\public class RD2_StatusMapper {
        \\    public interface Gateway {
        \\        List<RecurringDonationStatusMapping__mdt> getRecords();
        \\    }
        \\
        \\    private Gateway gateway {
        \\        get {
        \\            if (gateway == null) {
        \\                gateway = new EmptyGateway();
        \\            }
        \\            return gateway;
        \\        }
        \\        set;
        \\    }
        \\
        \\    private Map<String, String> statusLabelByValue {
        \\        get {
        \\            if (statusLabelByValue == null) {
        \\                statusLabelByValue = new Map<String, String>{ 'Active' => 'Active' };
        \\            }
        \\            return statusLabelByValue;
        \\        }
        \\        set;
        \\    }
        \\
        \\    public String getState(String status) {
        \\        Map<String, String> stateByStatus = new Map<String, String>();
        \\        for (String key : statusLabelByValue.keySet()) {
        \\            stateByStatus.put(key, null);
        \\        }
        \\        for (RecurringDonationStatusMapping__mdt record : gateway.getRecords()) {
        \\            if (stateByStatus.containsKey(record.Status__c)) {
        \\                stateByStatus.put(record.Status__c, record.State__c);
        \\            }
        \\        }
        \\        return stateByStatus.get(status);
        \\    }
        \\
        \\    private class EmptyGateway implements Gateway {
        \\        public List<RecurringDonationStatusMapping__mdt> getRecords() {
        \\            return new List<RecurringDonationStatusMapping__mdt>();
        \\        }
        \\    }
        \\
        \\    private class TestGateway implements Gateway {
        \\        private List<RecurringDonationStatusMapping__mdt> records =
        \\            new List<RecurringDonationStatusMapping__mdt>();
        \\
        \\        public TestGateway withRecord(RecurringDonationStatusMapping__mdt record) {
        \\            records.add(record);
        \\            return this;
        \\        }
        \\
        \\        public List<RecurringDonationStatusMapping__mdt> getRecords() {
        \\            return records;
        \\        }
        \\    }
        \\
        \\    public static String test() {
        \\        RD2_StatusMapper mapper = new RD2_StatusMapper();
        \\        mapper.gateway = new TestGateway().withRecord(
        \\            new RecurringDonationStatusMapping__mdt(
        \\                Status__c = 'Canceled',
        \\                State__c = 'Closed'
        \\            )
        \\        );
        \\        mapper.statusLabelByValue = new Map<String, String>{ 'Canceled' => 'Canceled' };
        \\        return mapper.getState('Canceled');
        \\    }
        \\}
    ;
    try expect_entry_string(source, "RD2_StatusMapper", "test", "Closed");
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
    try expect_entry_string(source, "Caller", "test", "9");
}

test "E2E: static sobject Id field access passes concrete id to parameter" {
    const source =
        \\public class StaticSObjectIdProbe {
        \\    static Account organizationAcct;
        \\    public static String test() {
        \\        organizationAcct = new Account(Name = 'Org');
        \\        insert organizationAcct;
        \\        return takeId(organizationAcct.Id) + '|' +
        \\            takeId(StaticSObjectIdProbe.organizationAcct.Id);
        \\    }
        \\    static String takeId(Id acctId) {
        \\        return acctId.left(3);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StaticSObjectIdProbe", "test", "001|001");
}

test "E2E: SObjectType fields token exposes field name" {
    const source =
        \\public class SObjectTypeFieldsTokenNameProbe {
        \\    public static String test() {
        \\        return String.valueOf(Opportunity.Id) + ':' +
        \\            String.valueOf(OpportunityContactRole.ContactId) + ':' +
        \\            String.valueOf(npe01__OppPayment__c.npe01__Opportunity__c) + ':' +
        \\            String.valueOf(Opportunity.SObjectType) + ':' +
        \\            SObjectType.Opportunity.fields.AccountId.Name + ':' +
        \\            SObjectType.Opportunity.fields.Primary_Contact__c.Name;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SObjectTypeFieldsTokenNameProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Id:ContactId:npe01__Opportunity__c:Opportunity:AccountId:Primary_Contact__c",
        result.value.string,
    );
}

test "E2E: assigning relationship sobject preserves relationship and foreign key" {
    const source =
        \\public class RelationshipAssignmentProbe {
        \\    public static String test() {
        \\        Account account = new Account(Id = '001000000000001AAA', npe01__SYSTEM_AccountType__c = 'Household');
        \\        Contact contact = new Contact(Id = '003000000000001AAA');
        \\        contact.Account = account;
        \\        return contact.Account.npe01__SYSTEM_AccountType__c + ':' + contact.AccountId;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "RelationshipAssignmentProbe",
        "test",
        "Household:001000000000001AAA",
    );
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
    try expect_entry_string(source, "SchemaPicklistTest", "test", "2");
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
    try expect_entry_string(source, "CaseFieldTest", "test", "hello");
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
    try expect_entry_string(source, "NullBindMethodTest", "test", "0");
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
    try expect_entry_string(source, "ControllerTest", "test", "10");
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
    var eval = try evaluator.Evaluator.init(alloc, std.testing.io);
    try eval.load_decls(decls);
    const val = try eval.call_method("Outer", "myMethod", &.{});
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

    // Verify callMethod handles Database.countQuery correctly without inner class interaction
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
    try expect_entry_string(source, "Caller3", "test", "0");
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
    try expect_entry_string(source, "Caller2", "test", "1");
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
    try expect_entry_string(source, "NetTest", "test", "ok");
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

test "resetForTest re-runs static initializers for later test methods" {
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

test "runTestSuite keeps repo-root metadata loading scoped to the requested repo" {
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
        .sub_path = "repos/app-a/force-app/main/default/objects/Widget__c/" ++
            "Widget__c.object-meta.xml",
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
        .sub_path = "repos/app-b/force-app/main/default/objects/Widget__c/fields/" ++
            "Required_Text__c.field-meta.xml",
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
    var suite = try run_test_suite(alloc, std.testing.io, &.{repo_a_path}, &_null_writer.writer);
    defer suite.deinit();

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
        \\        ref.getParameters().put('b', '2,0');
        \\        ref.getParameters().put('c', '3');
        \\        return ref.getUrl();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PageReferenceParamProbe",
        "run",
        "/flow/ns/testFlow?a=1&b=2%2C0&c=3",
    );
}

test "E2E: Page namespace member returns PageReference" {
    const source =
        \\public class PageNamespaceProbe {
        \\    public static String run() {
        \\        PageReference ref = Page.ContactMerge;
        \\        ref.getParameters().put('srch', 'test');
        \\        return ref.getUrl() + ':' + String.valueOf(ref.getParameters().get('srch'));
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PageNamespaceProbe",
        "run",
        "/apex/ContactMerge?srch=test:test",
    );
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

test "typed catch does not catch unrelated exception" {
    const source =
        \\public class TypedCatchUnrelatedExceptionProbe {
        \\    public class CustomException extends Exception {}
        \\    public static String test() {
        \\        try {
        \\            try {
        \\                throw new CustomException('custom');
        \\            } catch (AuraHandledException ex) {
        \\                return 'wrong:' + ex.getMessage();
        \\            }
        \\        } catch (Exception ex) {
        \\            return ex.getMessage();
        \\        }
        \\        return 'missing';
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TypedCatchUnrelatedExceptionProbe", "test", "custom");
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
        "Class.ConstructedStackTraceTopLevelTest.test: line 3, column 1\n" ++
            "AnonymousBlock: line 1, column 1",
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
        "Class.ConstructedStackTraceCtorTest.Holder.<init>: line 5, column 1\n" ++
            "Class.ConstructedStackTraceCtorTest.wrapper: line 12, column 1\n" ++
            "AnonymousBlock: line 1, column 1",
        result.value.string,
    );
}

test "E2E: replaceAll can collapse ignored constructed stack trace frames to empty" {
    const source =
        \\public class StackTraceCleanupProbe {
        \\    public static String test() {
        \\        return new DmlException()
        \\            .getStackTraceString()
        \\            .replaceAll('(StackTraceCleanupProbe)\\..+?column 1', '')
        \\            .trim();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StackTraceCleanupProbe", "test", "");
}

test "E2E: replaceAll stack trace cleanup fast path preserves remaining frames" {
    const source =
        \\public class StackTraceCleanupFastPathProbe {
        \\    public static String test() {
        \\        String stackTrace =
        \\            'Class.IgnoredLogger.entry: line 1, column 1\n' +
        \\            'Class.RealCaller.run: line 2, column 1\n' +
        \\            'Class.IgnoredBuilder.build: line 3, column 1';
        \\        return stackTrace
        \\            .replaceAll('(IgnoredLogger|IgnoredBuilder)\\..+?column 1', '')
        \\            .trim();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StackTraceCleanupFastPathProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Class.\nClass.RealCaller.run: line 2, column 1\nClass.",
        result.value.string,
    );
}

test "E2E: replaceAll data mask fast path preserves card and SSN replacements" {
    const source =
        \\public class DataMaskReplaceAllFastPathProbe {
        \\    public static String test() {
        \\        String ssnPattern = '(^|[^0-9A-Za-z])(\\d{3})[- ]?(\\d{2})[- ]?(\\d{4})(?=[^0-9A-Za-z]|$)';
        \\        String visaPattern = '(^|[^0-9])(4\\d{3})([- ]?)\\d{4}\\3\\d{4}\\3(\\d{4})(?!\\d)';
        \\        String mastercardPattern = '(^|[^0-9])(5[1-5]\\d{2}|222[1-9]|22[3-9]\\d|2[3-6]\\d{2}|27[01]\\d|2720)([- ]?)\\d{4}\\3\\d{4}\\3(\\d{4})(?!\\d)';
        \\        String amexPattern = '(^|[^0-9A-Za-z])(3[47]\\d{2})([- ]?)\\d{6}\\3(\\d{5})(?=[^0-9A-Za-z]|$)';
        \\        String input = 'SSN 123-45-6789, Visa 4111-1111-1111-1111, MC 5555 5555 5555 4444, Amex 3714 496353 98431, skip abc123456789 and 4111-1111 1111-1111';
        \\        return input
        \\            .replaceAll(ssnPattern, '$1XXX-XX-$4')
        \\            .replaceAll(visaPattern, '$1****-****-****-$4')
        \\            .replaceAll(mastercardPattern, '$1****-****-****-$4')
        \\            .replaceAll(amexPattern, '$1****-******-$4');
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DataMaskReplaceAllFastPathProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "SSN XXX-XX-6789, Visa ****-****-****-1111, MC ****-****-****-4444, Amex ****-******-98431, skip abc123456789 and 4111-1111 1111-1111",
        result.value.string,
    );
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
        \\        User u = [
        \\            SELECT Id, FirstName, LastName, Email
        \\            FROM User
        \\            WHERE Id = :UserInfo.getUserId()
        \\        ];
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
    try expect_entry_string(source, "CDLTest", "test", "CAUGHT");
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
        \\        List<ContentDocument> docs = [
        \\            SELECT Id, Title, LatestPublishedVersionId
        \\            FROM ContentDocument
        \\            LIMIT 1
        \\        ];
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
    try expect_entry_string(source, "CDLRefTest", "test", "1");
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
        \\        for (Schema.SObjectField field :
        \\            Schema.User.SObjectType.getDescribe().fields.getMap().values()
        \\        ) {
        \\            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
        \\            FieldSchema schema = new FieldSchema();
        \\            schema.localApiName = fieldDescribe.getLocalName();
        \\            fields.put(fieldDescribe.getLocalName(), schema);
        \\        }
        \\        return String.valueOf(fields.containsKey('Name')) +
        \\            ':' + fields.get('Name').localApiName +
        \\            ':' + String.valueOf(fields.containsKey('Username'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DescribeFieldLocalNameTest", "test", "true:Name:true");
}

test "E2E: DescribeSObjectResult.getLocalName keeps namespaced API name" {
    const source =
        \\public class DescribeSObjectLocalNameTest {
        \\    public static String test() {
        \\        return Schema.SObjectType.npe01__OppPayment__c
        \\            .getDescribe()
        \\            .getLocalName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DescribeSObjectLocalNameTest", "test", "npe01__OppPayment__c");
}

test "E2E: SObjectType token supports lowercase member and value equality" {
    const source =
        \\public class SObjectTypeLowercaseMemberTest {
        \\    public static String test() {
        \\        Schema.SObjectType left = npe01__OppPayment__c.sObjectType;
        \\        Schema.SObjectType right = Schema.SObjectType.npe01__OppPayment__c;
        \\        return String.valueOf(left == right) + ':' +
        \\            String.valueOf(left.getSObjectType() == right) + ':' +
        \\            left.getLocalName();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "SObjectTypeLowercaseMemberTest",
        "test",
        "true:true:npe01__OppPayment__c",
    );
}

test "E2E: SObjectType argument coerces to DescribeSObjectResult parameter" {
    const source =
        \\public class DescribeSObjectArgCoercionTest {
        \\    public static String label(Schema.DescribeSObjectResult describeObj) {
        \\        return describeObj.getLocalName();
        \\    }
        \\    public static String test() {
        \\        return label(Schema.Sobjecttype.npe4__Relationship__c);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "DescribeSObjectArgCoercionTest",
        "test",
        "npe4__Relationship__c",
    );
}

test "E2E: DescribeSObjectResult fields map includes common User fields" {
    const source =
        \\public class UserDescribeFieldsTest {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields =
        \\            Schema.User.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('Username')) +
        \\            ':' + fields.get('Username').getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UserDescribeFieldsTest", "test", "true:Username");
}

test "E2E: describe field map includes observed managed custom fields" {
    const source =
        \\public class ObservedManagedFieldDescribeTest {
        \\    public static String test() {
        \\        insert new npe4__Relationship__c(
        \\            npe4__Contact__c = '003000000000001',
        \\            npe4__Description__c = 'notes'
        \\        );
        \\        Map<String, Schema.SObjectField> fields =
        \\            npe4__Relationship__c.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('npe4__Description__c')) +
        \\            ':' + fields.get('npe4__Description__c').getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "ObservedManagedFieldDescribeTest",
        "test",
        "true:npe4__Description__c",
    );
}

test "E2E: packaged relationship describe includes syncable fields" {
    const source =
        \\public class PackagedRelationshipDescribeProbe {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields =
        \\            npe4__Relationship__c.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('npe4__Status__c')) +
        \\            ':' + String.valueOf(fields.containsKey('npe4__Description__c'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackagedRelationshipDescribeProbe", "test", "true:true");
}

test "E2E: DescribeFieldResult recognizes non-name fallback fields" {
    const source =
        \\public class EmailMessageDescribeFieldTest {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> fields =
        \\            Schema.EmailMessage.SObjectType.getDescribe().fields.getMap();
        \\        return String.valueOf(fields.containsKey('Subject')) +
        \\            ':' + String.valueOf(
        \\                Schema.EmailMessage.Subject.getDescribe().isNameField()
        \\            );
        \\    }
        \\}
    ;
    try expect_entry_string(source, "EmailMessageDescribeFieldTest", "test", "true:false");
}

test "E2E: implicit standard Name fields are treated as required" {
    const source =
        \\public class StandardNameFieldRequirementTest {
        \\    public static String test() {
        \\        List<String> requiredFields = new List<String>();
        \\        SObject record = Schema.Campaign.SObjectType.newSObject(null, true);
        \\        for (Schema.SObjectField field :
        \\            Schema.Campaign.SObjectType.getDescribe().fields.getMap().values()
        \\        ) {
        \\            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
        \\            if (fieldDescribe.isCreateable() && !fieldDescribe.isNillable()) {
        \\                requiredFields.add(fieldDescribe.getName());
        \\                if (fieldDescribe.getType() == Schema.DisplayType.STRING) {
        \\                    record.put(fieldDescribe.getName(), fieldDescribe.getName() + ' value');
        \\                }
        \\            }
        \\        }
        \\        return String.valueOf(requiredFields.contains('Name')) +
        \\            ':' + System.JSON.serializePretty(record);
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
        \\        Map<String, Schema.FieldSet> byType =
        \\            Schema.SObjectType.Thing__c.fieldSets.getMap();
        \\        Map<String, Schema.FieldSet> byDescribe =
        \\            Schema.SObjectType.Thing__c.getDescribe().fieldSets.getMap();
        \\        Schema.FieldSet fieldSet = byType.get('Related_List_Defaults');
        \\        Schema.FieldSet describedFieldSet = byDescribe.get('Related_List_Defaults');
        \\        List<Schema.FieldSetMember> members = fieldSet.getFields();
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

test "E2E: fieldSets support direct field access by API name" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c/fieldSets");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/fieldSets/Direct_Access.fieldSet-meta.xml",
        .data =
        \\<FieldSet xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Direct_Access</fullName>
        \\    <label>Direct Access</label>
        \\    <displayedFields>
        \\        <field>Name</field>
        \\    </displayedFields>
        \\</FieldSet>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class FieldSetDirectAccessTest {
        \\    public static String test() {
        \\        Schema.FieldSet fieldSet = Schema.SObjectType.Thing__c.fieldSets.Direct_Access;
        \\        return fieldSet.getFields()[0].getFieldPath();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "FieldSetDirectAccessTest",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Name", result.value.string);
}

test "E2E: SObjectType record type info methods delegate to describe metadata" {
    const alloc = std.testing.allocator;
    const source =
        \\public class SObjectTypeRecordTypeInfoTest {
        \\    public static String test() {
        \\        Map<Id, Schema.RecordTypeInfo> byId =
        \\            Schema.SObjectType.Account.getRecordTypeInfosById();
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

    try std.testing.expectEqualStrings("true:3:Master", result.value.string);
}

test "E2E: Schema custom object getSObjectType supports describe key prefix" {
    const alloc = std.testing.allocator;
    const source =
        \\public class SchemaCustomObjectTokenProbe {
        \\    public static String test() {
        \\        return Schema.Widget__c.getSObjectType().getDescribe().getKeyPrefix()
        \\            + ':' + Schema.Widget__c.getDescribe().getName();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "SchemaCustomObjectTokenProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("aLA:Widget__c", result.value.string);
}

test "E2E: cached DescribeSObjectResult record type info survives selective map clears" {
    const alloc = std.testing.allocator;
    const source =
        \\public class CachedDescribeRecordTypeInfoProbe {
        \\    private static Map<String, Schema.DescribeSObjectResult> cached =
        \\        new Map<String, Schema.DescribeSObjectResult>();
        \\    private static Map<String, List<Schema.RecordTypeInfo>> nonMasterInfos =
        \\        new Map<String, List<Schema.RecordTypeInfo>>();
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

    try std.testing.expectEqualStrings("2:3", result.value.string);
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
        \\        return String.valueOf(matches.size()) +
        \\            ':' + String.valueOf(stripped.size()) +
        \\            ':' + String.valueOf(stripped.get(0).Id == row.Id);
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

test "E2E: Search.query always returns an outer result list" {
    const source =
        \\public class SearchQueryOuterListTest {
        \\    public static String test() {
        \\        List<List<SObject>> rows = Search.query('FIND {NoMatch}');
        \\        return String.valueOf(rows.size()) + ':' +
        \\            String.valueOf(rows[0].size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SearchQueryOuterListTest", "test", "1:0");
}

test "E2E: inner class resolves outer enum values" {
    const source =
        \\public class OuterEnumAccessTest {
        \\    public enum Mode { One, Two }
        \\    public class Inner {
        \\        private Mode selected;
        \\        public Inner choose() {
        \\            selected = Mode.Two;
        \\            return this;
        \\        }
        \\        public String value() {
        \\            return selected.name();
        \\        }
        \\    }
        \\    public static String test() {
        \\        return new Inner().choose().value();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OuterEnumAccessTest", "test", "Two");
}

test "E2E: inner class assigns and compares outer enum values" {
    const source =
        \\public class OuterEnumCompareTest {
        \\    public enum Operator { EQUALS, IN_SET }
        \\    public class FieldExpression {
        \\        private Operator operant;
        \\        public FieldExpression inSet() {
        \\            operant = Operator.IN_SET;
        \\            return this;
        \\        }
        \\        public Boolean matches() {
        \\            return operant == Operator.IN_SET;
        \\        }
        \\    }
        \\    public static String test() {
        \\        return String.valueOf(new FieldExpression().inSet().matches());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OuterEnumCompareTest", "test", "true");
}

test "E2E: inner instance method does not shadow outer static overload with different arity" {
    const source =
        \\public class OuterStaticArityDispatchTest {
        \\    public static Boolean matches(List<Boolean> values, String mode) {
        \\        return values.size() == 1 && values[0] && mode == 'AND';
        \\    }
        \\    public class Inner {
        \\        public Boolean matches(Account record) {
        \\            return matches(new List<Boolean>{ true }, 'AND');
        \\        }
        \\    }
        \\    public static String test() {
        \\        return String.valueOf(new Inner().matches(new Account(Name = 'Acme')));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "OuterStaticArityDispatchTest", "test", "true");
}

test "E2E: same-named inner class constructor chaining stays in qualified class" {
    const source =
        \\public class FirstOuter {
        \\    public class Builder {
        \\        public String value;
        \\        public Builder(String value) {
        \\            this.value = 'wrong:' + value;
        \\        }
        \\    }
        \\}
        \\public class SecondOuter {
        \\    public class Builder {
        \\        public String value;
        \\        public Builder(String value) {
        \\            this(value, null);
        \\        }
        \\        public Builder(String value, Object unused) {
        \\            this.value = 'right:' + value;
        \\        }
        \\    }
        \\}
        \\public class QualifiedInnerConstructorChainTest {
        \\    public static String test() {
        \\        return new SecondOuter.Builder('ok').value;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "QualifiedInnerConstructorChainTest", "test", "right:ok");
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
        \\        return String.valueOf(inlineMaxLength) +
        \\            ':' + String.valueOf(tokenMaxLength) +
        \\            ':' + truncatedValue;
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
        \\        return String.valueOf(
        \\            Schema.Thing__c.OrganizationId__c.getDescribe().getSoapType()
        \\        ) + ':' + String.valueOf(
        \\            Schema.Thing__c.OrganizationId__c.getDescribe().getLength()
        \\        );
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
        \\        Schema.FieldSet fieldSet = Schema.SObjectType.Thing__c
        \\            .fieldSets.getMap().get('Related_List_Defaults');
        \\        return fieldSet == null
        \\            ? null
        \\            : new VisualEditor.DataRow(fieldSet.getLabel(), fieldSet.getName());
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
        \\        return (String) row.getLabel()
        \\            + ':' + String.valueOf(rows.size())
        \\            + ':' + (String) rows.get(0).getValue();
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
        \\        Schema.FieldSetMember member = Schema.SObjectType.Child__c
        \\            .fieldSets.getMap()
        \\            .get('Related_List_Defaults')
        \\            .getFields()
        \\            .get(0);
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

test "E2E: lookup metadata rejects ids with the wrong object prefix" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/TaskTemplate__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/TaskTemplate__c/fields/Parent_Task__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent_Task__c</fullName>
        \\    <label>Parent Task</label>
        \\    <referenceTo>TaskTemplate__c</referenceTo>
        \\    <relationshipName>ChildTasks</relationshipName>
        \\    <type>Lookup</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class LookupWrongPrefixProbe {
        \\    public static String test() {
        \\        TaskTemplate__c parent = new TaskTemplate__c(Name = 'Parent');
        \\        insert parent;
        \\        TaskTemplate__c child = new TaskTemplate__c(Name = 'Child', Parent_Task__c = parent.Id);
        \\        insert child;
        \\        child.Parent_Task__c = '001000000000001AAA';
        \\        try {
        \\            update child;
        \\            return 'no exception';
        \\        } catch (DmlException ex) {
        \\            return ex.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "LookupWrongPrefixProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "FIELD_INTEGRITY_EXCEPTION: Parent_Task__c: id value of incorrect type: 001000000000001AAA",
        result.value.string,
    );
}

test "E2E: lookup metadata rejects missing ids when target records exist" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Child__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Child__c/fields/Parent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Parent__c</fullName>
        \\    <label>Parent</label>
        \\    <referenceTo>Parent__c</referenceTo>
        \\    <relationshipName>Children</relationshipName>
        \\    <type>Lookup</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class LookupMissingTargetProbe {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(Name = 'Parent');
        \\        insert parent;
        \\        Child__c child = new Child__c(Name = 'Child', Parent__c = parent.Id);
        \\        insert child;
        \\        Child__c invalid = new Child__c(Name = 'Invalid', Parent__c = parent.Id.substring(0, 15) + '999');
        \\        try {
        \\            insert invalid;
        \\            return 'no exception';
        \\        } catch (DmlException ex) {
        \\            return ex.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "LookupMissingTargetProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(
        u8,
        result.value.string,
        "INVALID_CROSS_REFERENCE_KEY",
    ) != null);
}

test "E2E: getPopulatedFieldsAsMap excludes selected null fields" {
    const source =
        \\public class PopulatedNullFieldQueryTest {
        \\    public static String test() {
        \\        Account record = new Account(Name = 'Acme');
        \\        insert record;
        \\        Account queried = [SELECT Name, Type FROM Account WHERE Id = :record.Id];
        \\        Map<String, Object> populated = queried.getPopulatedFieldsAsMap();
        \\        return String.valueOf(populated.containsKey('Type')) +
        \\            ':' + String.valueOf(populated.containsKey('Name'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PopulatedNullFieldQueryTest", "test", "false:true");
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
        \\        for (Schema.FieldSetMember member :
        \\            Schema.SObjectType.Thing__c.fieldSets.getMap()
        \\                .get('Notification_Defaults').getFields()
        \\        ) {
        \\            fieldNames.add(member.getFieldPath());
        \\        }
        \\        String query = 'SELECT ' + String.join(fieldNames, ', ') +
        \\            ' FROM Thing__c WHERE Id = :thing.Id';
        \\        Thing__c queried = ((List<Thing__c>) Database.query(query)).get(0);
        \\        Map<String, Object> populated = queried.getPopulatedFieldsAsMap();
        \\        return String.valueOf(populated.containsKey('MaxChildScore__c')) +
        \\            ':' + String.valueOf(populated.containsKey('Name'));
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
        \\        for (Schema.FieldSetMember member :
        \\            Schema.SObjectType.Parent__c.fieldSets.getMap()
        \\                .get('Notification_Defaults').getFields()
        \\        ) {
        \\            fieldNames.add(member.getFieldPath());
        \\        }
        \\        String query = 'SELECT ' + String.join(fieldNames, ', ') +
        \\            ' FROM Parent__c WHERE Id = :parentRecord.Id';
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
        \\        Schema.ApexClass apexClassRecord = new Schema.ApexClass(
        \\            Name = 'ExampleClass',
        \\            Body = 'public class ExampleClass {}'
        \\        );
        \\        apexClassRecord.put(
        \\            Schema.ApexClass.LastModifiedDate,
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
        \\        List<Schema.ApexClass> typedRecords = new List<Schema.ApexClass>{ apexClassRecord };
        \\        List<SObject> metadataRecords = typedRecords;
        \\        SObject metadataRecord = metadataRecords.get(0);
        \\        String body = (String) metadataRecord.get(Schema.ApexClass.Body);
        \\        Boolean modified =
        \\            ((Datetime) metadataRecord.get(Schema.ApexClass.LastModifiedDate))
        \\                > Datetime.newInstance(2026, 3, 1, 0, 0, 0);
        \\        return body + ':' + String.valueOf(modified);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "ApexMetadataListAccessTest",
        "test",
        "public class ExampleClass {}:true",
    );
}

test "E2E: Apex metadata describe is accessible by default" {
    const source =
        \\public class ApexMetadataDescribeAccessTest {
        \\    public static String test() {
        \\        return String.valueOf(
        \\            Schema.ApexClass.SObjectType.getDescribe().isAccessible()
        \\        ) + ':' + String.valueOf(
        \\            Schema.ApexTrigger.SObjectType.getDescribe().isAccessible()
        \\        );
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ApexMetadataDescribeAccessTest", "test", "true:true");
}

test "E2E: JSON round-trip through SObject.class preserves Apex metadata fields" {
    const source =
        \\public class SObjectJsonRoundTripTest {
        \\    public static String test() {
        \\        Schema.ApexClass originalRecord = new Schema.ApexClass(
        \\            Name = 'ExampleClass',
        \\            Body = 'public class ExampleClass {}'
        \\        );
        \\        String serialized = JSON.serialize(originalRecord);
        \\        Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(serialized);
        \\        fields.put('LastModifiedDate', Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        SObject roundTripped = (SObject) JSON.deserialize(
        \\            JSON.serialize(fields),
        \\            SObject.class
        \\        );
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
        \\        Schema.ApexClass originalRecord = new Schema.ApexClass(
        \\            Name = 'ExampleClass',
        \\            Body = 'public class ExampleClass {}'
        \\        );
        \\        Map<String, Object> fields = (Map<String, Object>)
        \\            JSON.deserializeUntyped(JSON.serialize(originalRecord));
        \\        fields.put('LastModifiedDate', Datetime.newInstance(2026, 4, 1, 0, 0, 0));
        \\        Schema.ApexClass castedRecord = (Schema.ApexClass) JSON.deserialize(
        \\            JSON.serialize(fields),
        \\            SObject.class
        \\        );
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
    try expect_entry_string(source, "JsonFieldTokenFallbackTest", "test", "Description");
}

test "E2E: JSON deserialize unwraps relationship records and normalizes standard field types" {
    const source =
        \\public class JsonRelationshipRoundTripTest {
        \\    public static String test() {
        \\        String json =
        \\            '[{"attributes":{"type":"Account"},' +
        \\            '"Id":"001000000000001AAA","Name":"Acme",' +
        \\            '"NumberOfEmployees":"7",' +
        \\            '"Contacts":{"totalSize":"2","done":"true","records":[' +
        \\            '{"attributes":{"type":"Contact"},' +
        \\            '"Id":"003000000000001AAA","DoNotCall":"true"},' +
        \\            '{"attributes":{"type":"Contact"},' +
        \\            '"Id":"003000000000002AAA","DoNotCall":"false"}]}}]';
        \\        SObject accountRecord = ((List<SObject>) JSON.deserialize(json, List<SObject>.class))[0];
        \\        List<SObject> contacts = accountRecord.getSObjects('Contacts');
        \\        return String.valueOf(accountRecord.get('NumberOfEmployees')) + ':' +
        \\            String.valueOf(contacts.size()) + ':' +
        \\            String.valueOf(contacts[0].Id) + ':' +
        \\            String.valueOf((Boolean) contacts[0].get('DoNotCall'));
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonRelationshipRoundTripTest",
        "test",
        "7:2:003000000000001AAA:true",
    );
}

test "E2E: JSON deserialize unwraps relationship records for typed child access" {
    const source =
        \\public class JsonTypedRelationshipRoundTripTest {
        \\    public static String test() {
        \\        String json =
        \\            '[{"attributes":{"type":"Account"},' +
        \\            '"Id":"001000000000001AAA","Name":"Acme",' +
        \\            '"Contacts":{"totalSize":"2","done":"true","records":[' +
        \\            '{"attributes":{"type":"Contact"},' +
        \\            '"Id":"003000000000001AAA"},' +
        \\            '{"attributes":{"type":"Contact"},' +
        \\            '"Id":"003000000000002AAA"}]}}]';
        \\        Account accountRecord = ((List<Account>) JSON.deserialize(json, List<Account>.class))[0];
        \\        return String.valueOf(accountRecord.Contacts == null) + ':' +
        \\            String.valueOf(accountRecord.Contacts == null
        \\                ? null
        \\                : accountRecord.Contacts.size()) + ':' +
        \\            String.valueOf(accountRecord.Contacts == null ||
        \\                accountRecord.Contacts.size() == 0
        \\                    ? null
        \\                    : accountRecord.Contacts[0].Id);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonTypedRelationshipRoundTripTest",
        "test",
        "false:2:003000000000001AAA",
    );
}

test "E2E: JSON deserialize keeps nested parent relationship SObjects" {
    const source =
        \\public class JsonParentRelationshipRoundTripTest {
        \\    public static String test() {
        \\        Contact contactRecord = new Contact(LastName = 'Smith');
        \\        Account accountRecord = new Account(
        \\            Id = '001000000000001AAA',
        \\            Name = 'Acme'
        \\        );
        \\        String serializedContact = JSON.serialize(contactRecord);
        \\        String combined = serializedContact.left(serializedContact.length() - 1) +
        \\            ',"Account":' + JSON.serialize(accountRecord) + '}';
        \\        SObject parsed = (SObject) JSON.deserialize(combined, SObject.class);
        \\        Contact typed = (Contact) parsed;
        \\        return String.valueOf(parsed.get('Account') instanceof SObject) + ':' +
        \\            String.valueOf(parsed.getSObject('Account').get('Name')) + ':' +
        \\            typed.Account.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonParentRelationshipRoundTripTest",
        "test",
        "true:Acme:Acme",
    );
}

test "E2E: JSON relationship records without attributes infer child SObject type" {
    const source =
        \\public class JsonInferredRelationshipRecordTypeTest {
        \\    public static String test() {
        \\        String json =
        \\            '{"Id":"006000000000001AAA","Name":"Gift",' +
        \\            '"pkg__Payment__r":{"totalSize":1,"done":true,"records":[' +
        \\            '{"Id":"a2f000000000001AAA","pkg__Paid__c":false,' +
        \\            '"pkg__Opportunity__c":"006000000000001AAA"}]}}';
        \\        Opportunity opportunity = (Opportunity) JSON.deserialize(json, Opportunity.class);
        \\        return String.valueOf(opportunity.pkg__Payment__r.size()) + ':' +
        \\            opportunity.pkg__Payment__r[0].getSObjectType().getDescribe().getName() + ':' +
        \\            String.valueOf(opportunity.pkg__Payment__r[0].pkg__Paid__c);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonInferredRelationshipRecordTypeTest",
        "test",
        "1:pkg__Payment__c:false",
    );
}

test "E2E: JSON child relationship injected into serialized SObject is preserved" {
    const source =
        \\public class JsonInjectedRelationshipProbe {
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(
        \\            Id = '006000000000001AAA',
        \\            Name = 'Gift',
        \\            StageName = 'Open',
        \\            CloseDate = Date.today()
        \\        );
        \\        List<npe01__OppPayment__c> payments = new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(
        \\                npe01__Paid__c = false,
        \\                npe01__Written_Off__c = false,
        \\                npe01__Opportunity__c = opportunity.Id
        \\            )
        \\        };
        \\        String parentJSON = JSON.serialize(opportunity);
        \\        String childJSON = '"npe01__OppPayment__r": {"totalSize": 1, "done": true,' +
        \\            '"records": ' + JSON.serialize(payments) + '}';
        \\        parentJSON = parentJSON.substring(0, parentJSON.length() - 1) + ',' + childJSON + '}';
        \\        Opportunity hydrated = (Opportunity) JSON.deserialize(parentJSON, Opportunity.class);
        \\        return String.valueOf(hydrated.npe01__OppPayment__r.size()) + ':' +
        \\            hydrated.npe01__OppPayment__r[0].getSObjectType().getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonInjectedRelationshipProbe",
        "test",
        "1:npe01__OppPayment__c",
    );
}

test "E2E: SObject list index assignment preserves injected child relationships" {
    const source =
        \\public class JsonRelationshipListAssignmentProbe {
        \\    public static String test() {
        \\        List<Opportunity> opportunities = new List<Opportunity>{
        \\            new Opportunity(Id = '006000000000001AAA', Name = 'A'),
        \\            new Opportunity(Id = '006000000000002AAA', Name = 'B')
        \\        };
        \\        List<npe01__OppPayment__c> payments = new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false)
        \\        };
        \\        String parentJSON = JSON.serialize(opportunities[0]);
        \\        String childJSON = '"npe01__OppPayment__r": {"totalSize": 1, "done": true,' +
        \\            '"records": ' + JSON.serialize(payments) + '}';
        \\        parentJSON = parentJSON.substring(0, parentJSON.length() - 1) + ',' + childJSON + '}';
        \\        opportunities[0] = (Opportunity) JSON.deserialize(parentJSON, Opportunity.class);
        \\        npe01__OppPayment__c payment = opportunities[0].npe01__OppPayment__r[0];
        \\        return String.valueOf(opportunities[0].npe01__OppPayment__r.size()) + ':' +
        \\            String.valueOf(opportunities[1].npe01__OppPayment__r.size()) + ':' +
        \\            String.valueOf(payment.npe01__Paid__c || payment.npe01__Written_Off__c);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "JsonRelationshipListAssignmentProbe", "test", "1:0:false");
}

test "E2E: injected payment child relationship filters unpaid payments" {
    const source =
        \\public class JsonRelationshipPaymentFilterProbe {
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(
        \\            Id = '006000000000001AAA',
        \\            Name = 'Gift'
        \\        );
        \\        List<npe01__OppPayment__c> payments = new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(
        \\                npe01__Paid__c = false,
        \\                npe01__Written_Off__c = false,
        \\                npe01__Opportunity__c = opportunity.Id
        \\            ),
        \\            new npe01__OppPayment__c(
        \\                npe01__Paid__c = false,
        \\                npe01__Written_Off__c = false,
        \\                npe01__Opportunity__c = opportunity.Id
        \\            )
        \\        };
        \\        String parentJSON = JSON.serialize(opportunity);
        \\        String childJSON = '"npe01__OppPayment__r": {"totalSize": 2, "done": true,' +
        \\            '"records": ' + JSON.serialize(payments) + '}';
        \\        parentJSON = parentJSON.substring(0, parentJSON.length() - 1) + ',' + childJSON + '}';
        \\        Opportunity hydrated = (Opportunity) JSON.deserialize(parentJSON, Opportunity.class);
        \\        List<npe01__OppPayment__c> unpaid = new List<npe01__OppPayment__c>();
        \\        for (npe01__OppPayment__c payment : hydrated.npe01__OppPayment__r) {
        \\            if (payment.npe01__Paid__c || payment.npe01__Written_Off__c) {
        \\                continue;
        \\            }
        \\            unpaid.add(payment);
        \\        }
        \\        List<Object> untyped = unpaid;
        \\        return String.valueOf(hydrated.npe01__OppPayment__r.size()) + ':' +
        \\            String.valueOf(unpaid.size()) + ':' +
        \\            String.valueOf(untyped.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "JsonRelationshipPaymentFilterProbe", "test", "2:2:2");
}

test "E2E: injected child relationship isEmpty reflects records" {
    const source =
        \\public class JsonRelationshipIsEmptyProbe {
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        List<npe01__OppPayment__c> payments = new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false, npe01__Written_Off__c = false)
        \\        };
        \\        String parentJSON = JSON.serialize(opportunity);
        \\        String childJSON = '"npe01__OppPayment__r": {"totalSize": 1, "done": true,' +
        \\            '"records": ' + JSON.serialize(payments) + '}';
        \\        parentJSON = parentJSON.substring(0, parentJSON.length() - 1) + ',' + childJSON + '}';
        \\        opportunity = (Opportunity) JSON.deserialize(parentJSON, Opportunity.class);
        \\        return String.valueOf(opportunity.npe01__OppPayment__r.isEmpty()) + ':' +
        \\            String.valueOf(opportunity.npe01__OppPayment__r.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "JsonRelationshipIsEmptyProbe", "test", "false:1");
}

test "E2E: direct child relationship field unwraps records envelope" {
    const source =
        \\public class RelationshipEnvelopeFieldProbe {
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        SObject envelope = new SObject();
        \\        envelope.put('records', new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false),
        \\            new npe01__OppPayment__c(npe01__Paid__c = false)
        \\        });
        \\        opportunity.put('npe01__OppPayment__r', envelope);
        \\        return String.valueOf(opportunity.npe01__OppPayment__r.size()) + ':' +
        \\            String.valueOf(opportunity.npe01__OppPayment__r.isEmpty());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "RelationshipEnvelopeFieldProbe", "test", "2:false");
}

test "E2E: SObject child relationship list survives DTO view conversion" {
    const source =
        \\public class RelationshipDonation {
        \\    private List<npe01__OppPayment__c> unpaidPayments;
        \\    private Opportunity opportunity;
        \\    public RelationshipDonation(Opportunity opportunity) {
        \\        this.opportunity = opportunity;
        \\        unpaidPayments = new List<npe01__OppPayment__c>();
        \\        for (npe01__OppPayment__c payment : opportunity.npe01__OppPayment__r) {
        \\            if (payment.npe01__Paid__c || payment.npe01__Written_Off__c) {
        \\                continue;
        \\            }
        \\            unpaidPayments.add(payment);
        \\        }
        \\    }
        \\    public List<npe01__OppPayment__c> unpaidPayments() {
        \\        return this.unpaidPayments;
        \\    }
        \\}
        \\public class RelationshipDonationDTO {
        \\    public List<Object> unpaidPayments;
        \\    public RelationshipDonationDTO(RelationshipDonation donation) {
        \\        this.unpaidPayments = donation.unpaidPayments();
        \\    }
        \\}
        \\public class RelationshipDonationView {
        \\    public List<Map<String, Object>> unpaidPayments;
        \\    public RelationshipDonationView(RelationshipDonationDTO dto) {
        \\        this.unpaidPayments = new List<Map<String, Object>>();
        \\        for (Object payment : dto.unpaidPayments) {
        \\            Map<String, Object> untyped =
        \\                (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(payment));
        \\            this.unpaidPayments.add(untyped);
        \\        }
        \\    }
        \\}
        \\public class RelationshipDonationViewProbe {
        \\    public static String test() {
        \\        Opportunity opportunity = new Opportunity(Id = '006000000000001AAA', Name = 'Gift');
        \\        List<npe01__OppPayment__c> payments = new List<npe01__OppPayment__c>{
        \\            new npe01__OppPayment__c(npe01__Paid__c = false, npe01__Written_Off__c = false),
        \\            new npe01__OppPayment__c(npe01__Paid__c = false, npe01__Written_Off__c = false)
        \\        };
        \\        String parentJSON = JSON.serialize(opportunity);
        \\        String childJSON = '"npe01__OppPayment__r": {"totalSize": 2, "done": true,' +
        \\            '"records": ' + JSON.serialize(payments) + '}';
        \\        parentJSON = parentJSON.substring(0, parentJSON.length() - 1) + ',' + childJSON + '}';
        \\        opportunity = (Opportunity) JSON.deserialize(parentJSON, Opportunity.class);
        \\        RelationshipDonationView view =
        \\            new RelationshipDonationView(new RelationshipDonationDTO(new RelationshipDonation(opportunity)));
        \\        return String.valueOf(view.unpaidPayments.size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "RelationshipDonationViewProbe", "test", "2");
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
        \\        String jsonInput =
        \\            '[{ "first_name": "Abel", ' +
        \\            '"last_name": "Maclead", ' +
        \\            '"email": "a.m@demo.org" }]';
        \\        List<Contact> csvContacts = (List<Contact>) new DataWeaveScriptResource.csvToContacts()
        \\            .execute(new Map<String, Object>{ 'records' => csvInput })
        \\            .getValue();
        \\        List<Contact> jsonContacts = (List<Contact>) new DataWeaveScriptResource.jsonToContacts()
        \\            .execute(new Map<String, Object>{ 'records' => jsonInput })
        \\            .getValue();
        \\        List<CsvData> rows = (List<CsvData>) new DataWeaveScriptResource.csvToApexObject()
        \\            .execute(new Map<String, Object>{ 'records' => csvInput })
        \\            .getValue();
        \\        return String.valueOf(csvContacts.size()) +
        \\            ':' + csvContacts[0].FirstName + ':' +
        \\            jsonContacts[0].Email + ':' + rows[0].LastName;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "DataWeaveObjectConversionTest",
        "test",
        "1:Abel:a.m@demo.org:Maclead",
    );
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
    try expect_entry_string(source, "DataWeaveDateFormatTest", "test", "true");
}

test "E2E: JSON deserialize normalizes standard read-only datetime fields" {
    const source =
        \\public class JsonReadonlyDatetimeProbe {
        \\    public static String test() {
        \\        String json =
        \\            '{"attributes":{"type":"Account"},' +
        \\            '"LastReferencedDate":"2020-01-07T23:30:00.000Z"}';
        \\        Account accountRecord = (Account) JSON.deserialize(json, Account.class);
        \\        Datetime expected = Datetime.newInstanceGmt(2020, 1, 7, 23, 30, 0);
        \\        return String.valueOf(expected == accountRecord.LastReferencedDate) + ':' +
        \\            String.valueOf(accountRecord.LastReferencedDate);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonReadonlyDatetimeProbe",
        "test",
        "true:2020-01-07T23:30:00Z",
    );
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

    try std.testing.expectEqualStrings(
        "001000000000001AAA:" ++
            "{\"attributes\":{\"type\":\"Account\"}," ++
            "\"Id\":\"001000000000001AAA\",\"Name\":\"Acme\"}",
        result.value.string,
    );
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
        \\        List<Map<Schema.SObjectField, Object>> expected =
        \\            new List<Map<Schema.SObjectField, Object>>{
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
        \\        return String.valueOf(sObjectMatches(actual[0], expected[0])) +
        \\            ':' +
        \\            String.valueOf(sObjectMatches(actual[1], expected[1]));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TokenKeyedSObjectMatchProbe", "test", "true:true");
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
        \\        Map<String, Schema.SObjectField> fields =
        \\            Group.SObjectType.getDescribe().fields.getMap();
        \\        Schema.SObjectField idField = fields.get('Id');
        \\        Schema.SObjectField nameField = fields.get('Name');
        \\
        \\        List<Map<Schema.SObjectField, Object>> expected =
        \\            new List<Map<Schema.SObjectField, Object>>{
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
        \\        return String.valueOf(sObjectMatches(groups[0], expected[0])) +
        \\            ':' +
        \\            String.valueOf(sObjectMatches(groups[1], expected[1]));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TokenKeyedGroupMatchProbe", "test", "true:true");
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
    try expect_entry_string(source, "BooleanGetterBackingFieldProbe", "test", "true");
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
    try expect_entry_string(source, "GetterMethodDispatchProbeCaller", "test", "ok");
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
        \\                List<Map<Schema.SObjectField, Object>> toMatches =
        \\                    new List<Map<Schema.SObjectField, Object>>();
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
        \\    private static Boolean sObjectMatches(
        \\        SObject sobj,
        \\        Map<Schema.SObjectField, Object> toMatch
        \\    ) {
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
        \\        Map<String, Schema.SObjectField> fields =
        \\            Group.SObjectType.getDescribe().fields.getMap();
        \\        Schema.SObjectField idField = fields.get('Id');
        \\        Schema.SObjectField nameField = fields.get('Name');
        \\        List<Map<Schema.SObjectField, Object>> expected =
        \\            new List<Map<Schema.SObjectField, Object>>{
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
    try expect_entry_string(source, "OrderedTokenKeyedSObjectListMatcherProbe", "test", "true");
}

test "E2E: global describe exposes Group sobject type" {
    const source =
        \\public class GlobalDescribeGroupProbe {
        \\    public static String test() {
        \\        Schema.SObjectType groupType = Schema.getGlobalDescribe().get('Group');
        \\        return String.valueOf(
        \\            groupType == null ? null : groupType.getDescribe().getName()
        \\        );
        \\    }
        \\}
    ;
    try expect_entry_string(source, "GlobalDescribeGroupProbe", "test", "Group");
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

    try std.testing.expectEqualStrings(
        "\"2019-01-01T12:00:00.000Z\"",
        result.value.string,
    );
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
        \\    public static SObject setReadOnlyField(
        \\        SObject record,
        \\        Schema.SObjectField field,
        \\        Object value
        \\    ) {
        \\        Map<String, Object> fields = (Map<String, Object>)
        \\            JSON.deserializeUntyped(JSON.serialize(record));
        \\        fields.put(field.toString(), value);
        \\        return (SObject) JSON.deserialize(JSON.serialize(fields), SObject.class);
        \\    }
        \\    public static String test() {
        \\        Schema.ApexClass apexClassRecord = new Schema.ApexClass(
        \\            Name = 'ExampleClass',
        \\            Body = 'public class ExampleClass {}'
        \\        );
        \\        apexClassRecord = (Schema.ApexClass) setReadOnlyField(
        \\            apexClassRecord,
        \\            Schema.ApexClass.LastModifiedDate,
        \\            Datetime.newInstance(2026, 4, 1, 0, 0, 0)
        \\        );
        \\        Thing__c record = new Thing__c(
        \\            Timestamp__c = Datetime.newInstance(2026, 3, 1, 0, 0, 0)
        \\        );
        \\        return String.valueOf(
        \\            ((Datetime) ((SObject) apexClassRecord)
        \\                .get(Schema.ApexClass.LastModifiedDate)) > record.Timestamp__c
        \\        );
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
    try expect_entry_string(source, "SelectorDispatchTest", "test", "mock");
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
        \\        return String.valueOf(EnumContainer.Kind.valueOf('Alpha')) +
        \\            ':' + String.valueOf(EnumContainer.Kind.values().size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InnerEnumValueOfTest", "test", "Alpha:2");
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
    try expect_entry_string(source, "InnerEnumSwitchTest", "test", "A:B");
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
    try expect_entry_string(source, "HttpHeaderRoundTripTest", "test", "1:2:false");
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
    try expect_entry_string(source, "RestHeaderRoundTripTest", "test", "1:2:0");
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
    try expect_entry_string(source, "RestRequestBodyNullTest", "test", "Argument cannot be null.");
}

test "E2E: RestContext request and response share assigned objects" {
    const source =
        \\public class RestContextSharedStateTest {
        \\    public static String test() {
        \\        RestContext.Request = new RestRequest();
        \\        RestContext.Response = new RestResponse();
        \\        RestContext.request.requestURI = '/services/apexrest/demo';
        \\        RestContext.response.statusCode = 204;
        \\        return RestContext.Request.requestURI
        \\            + ':' + String.valueOf(RestContext.Response.statusCode);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "RestContextSharedStateTest",
        "test",
        "/services/apexrest/demo:204",
    );
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
    try expect_entry_string(source, "RestResponseWrapperTest", "test", "202");
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
    try expect_entry_string(source, "RestResponseChildTest", "test", "206");
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
    try expect_entry_string(source, "RestContextSetupHelperTest", "test", "207");
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
    try expect_entry_string(source, "RouteStyleResponderTest", "test", "200:200:application/json");
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
    try expect_entry_string(source, "CurrentPageReferenceTest", "test", "/home");
}

test "E2E: Test.setCurrentPage installs ApexPages current page" {
    const source =
        \\public class SetCurrentPageReferenceTest {
        \\    public static String test() {
        \\        Test.setCurrentPage(Page.MyPanel);
        \\        ApexPages.currentPage().getParameters().put('panel', 'idPanel');
        \\        return System.currentPageReference().getUrl() + ':' +
        \\            String.valueOf(System.currentPageReference().getParameters().get('panel'));
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "SetCurrentPageReferenceTest",
        "test",
        "/apex/MyPanel?panel=idPanel:idPanel",
    );
}

test "E2E: Test.setCurrentPageReference installs ApexPages current page" {
    const source =
        \\public class SetCurrentPageReferenceAliasTest {
        \\    public static String test() {
        \\        PageReference pageRef = Page.ContactMerge;
        \\        String ids = '003000000000001,003000000000002';
        \\        pageRef.getParameters().put('mergeIds', ids);
        \\        Test.setCurrentPageReference(pageRef);
        \\        return System.currentPageReference().getUrl() + ':' +
        \\            String.valueOf(ApexPages.currentPage().getParameters().get('mergeIds'));
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "SetCurrentPageReferenceAliasTest",
        .entry_method = "test",
    });
    defer result.deinit();

    const expected =
        "/apex/ContactMerge?mergeIds=003000000000001%2C003000000000002" ++
        ":003000000000001,003000000000002";
    try std.testing.expectEqualStrings(expected, result.value.string);
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
    try expect_entry_integer(source, "EmptyDmlTest", "test", 0);
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
    try expect_entry_integer(source, "NonEmptyDmlTest", "test", 1);
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
    try expect_entry_integer(source, "EmptyDbDmlTest", "test", 0);
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
    try expect_entry_string(source, "SingleDbDmlTest", "test", "true:1:1");
}

test "E2E: Salesforce-style id strings satisfy instanceof Id" {
    const source =
        \\public class IdInstanceofTest {
        \\    public static String test() {
        \\        String userId = '005000000000000';
        \\        String queueId = '00G000000000000005';
        \\        return String.valueOf(userId instanceof Id) +
        \\            ':' + String.valueOf(queueId instanceof Id);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "IdInstanceofTest", "test", "true:true");
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
    try expect_entry_string(source, "StandardSetControllerSelectionTest", "test", "1:B");
}

test "E2E: ApexPages.Message preserves summary when added to page state" {
    const source =
        \\public class ApexPagesMessageSummaryTest {
        \\    public static String test() {
        \\        ApexPages.addMessage(
        \\            new ApexPages.Message(ApexPages.Severity.ERROR, 'Denied')
        \\        );
        \\        return ApexPages.getMessages().get(0).getSummary() +
        \\            ':' + ApexPages.getMessages().get(0).getSeverity();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ApexPagesMessageSummaryTest", "test", "Denied:ERROR");
}

test "E2E: ApexPages.Message string conversion exposes message text" {
    const source =
        \\public class ApexPagesMessageStringTest {
        \\    public static String test() {
        \\        ApexPages.Message msg = new ApexPages.Message(
        \\            ApexPages.Severity.ERROR,
        \\            'Denied'
        \\        );
        \\        return String.valueOf(msg) + ':' + msg.toString() + ':' + msg.getMessage();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ApexPagesMessageStringTest", "test", "Denied:Denied:Denied");
}

test "E2E: SObject field addError outside triggers appears in ApexPages messages" {
    const source =
        \\public class FieldAddErrorPageMessageProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Acme');
        \\        account.Name.addError('Name is required');
        \\        return String.valueOf(ApexPages.hasMessages(ApexPages.Severity.ERROR)) + ':' +
        \\            ApexPages.getMessages()[0].getSummary();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "FieldAddErrorPageMessageProbe",
        "test",
        "true:Name is required",
    );
}

test "E2E: Id.valueOf expands 15-char ids to 18-char ids" {
    const source =
        \\public class IdValueOfTest {
        \\    public static String test() {
        \\        return String.valueOf(Id.valueOf('005000000000000'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "IdValueOfTest", "test", "005000000000000AAA");
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
    try expect_entry_string(source, "InvalidIdValueOfTest", "test", "string-exception");
}

test "E2E: Id variable declaration rejects invalid string ids" {
    const source =
        \\public class InvalidIdDeclarationTest {
        \\    public static String test() {
        \\        try {
        \\            Id foo = 'foo';
        \\            return 'no-exception';
        \\        } catch (System.StringException e) {
        \\            return 'string-exception';
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InvalidIdDeclarationTest", "test", "string-exception");
}

test "E2E: Database.query result assigns to concrete SObject" {
    const source =
        \\public class DatabaseQueryAssignmentTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        String soql = 'SELECT Id, Name FROM Account LIMIT 1';
        \\        Account accountRecord;
        \\        accountRecord = Database.query(soql);
        \\        return accountRecord.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DatabaseQueryAssignmentTest", "test", "Acme");
}

test "E2E: custom equals and hashCode drive map lookup while strict equality stays identity" {
    const source =
        \\public class EqualityKey {
        \\    public List<Object> values;
        \\    public EqualityKey(List<Object> values) {
        \\        this.values = values;
        \\    }
        \\    public Boolean equals(Object other) {
        \\        EqualityKey that = other instanceof EqualityKey
        \\            ? (EqualityKey) other
        \\            : null;
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
    try expect_entry_string(source, "EqualityKeyProbe", "test", "true:false:ok:true");
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
    try expect_entry_string(source, "MapClearProbe", "test", "true:false:1:true");
}

test "E2E: String.valueOf respects override toString and List<Type>.toString" {
    const source =
        \\public class ValuePrinter {
        \\    public override String toString() {
        \\        return 'printer';
        \\    }
        \\}
        \\public class ValuePrinterProbe {
        \\    public static String test() {
        \\        return String.valueOf(new ValuePrinter()) +
        \\            ':' +
        \\            new List<Type>{ Integer.class, String.class }.toString();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ValuePrinterProbe", "test", "printer:(Integer, String)");
}

test "E2E: executeBatch uses QueryLocator records produced from SOQL literals" {
    const source =
        \\global class QueryLocatorScopeBatch implements Database.Batchable<SObject> {
        \\    public static Integer processed = 0;
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        return Database.getQueryLocator([
        \\            SELECT Id FROM Account WHERE Name = 'Keep'
        \\        ]);
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
    try expect_entry_integer(source, "QueryLocatorScopeBatchTest", "test", 1);
}

test "E2E: executeBatch does not mutate caller batch instance state" {
    const source =
        \\global class BatchInstanceIsolationProbe implements Database.Batchable<SObject>, Database.Stateful {
        \\    public Integer processed = 5;
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        return Database.getQueryLocator([SELECT Id FROM Account]);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        processed += scope.size();
        \\    }
        \\    global void finish(Database.BatchableContext bc) {}
        \\}
        \\public class BatchInstanceIsolationProbeTest {
        \\    public static Integer test() {
        \\        insert new Account(Name = 'A');
        \\        BatchInstanceIsolationProbe batch = new BatchInstanceIsolationProbe();
        \\        Database.executeBatch(batch);
        \\        return batch.processed;
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "BatchInstanceIsolationProbeTest", "test", 5);
}

test "E2E: QueryLocator captures instance field bind records at start time" {
    const source =
        \\global class BoundQueryLocatorBatch implements Database.Batchable<SObject> {
        \\    public static Integer processed = 0;
        \\    private List<Id> accountIds;
        \\    public BoundQueryLocatorBatch(List<Id> ids) {
        \\        accountIds = ids;
        \\    }
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        return Database.getQueryLocator(
        \\            'SELECT Id FROM Account WHERE Id =: accountIds'
        \\        );
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        processed = scope.size();
        \\    }
        \\    global void finish(Database.BatchableContext bc) {}
        \\}
        \\public class BoundQueryLocatorBatchTest {
        \\    public static Integer test() {
        \\        List<Account> accounts = new List<Account>{
        \\            new Account(Name = 'A'),
        \\            new Account(Name = 'B')
        \\        };
        \\        insert accounts;
        \\        List<Id> ids = new List<Id>(new Map<Id, Account>(accounts).keySet());
        \\        Database.executeBatch(new BoundQueryLocatorBatch(ids));
        \\        return BoundQueryLocatorBatch.processed;
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "BoundQueryLocatorBatchTest", "test", 2);
}

test "E2E: executeBatch skips execute for empty QueryLocator scope" {
    const source =
        \\global class EmptyQueryLocatorBatch implements Database.Batchable<SObject> {
        \\    public static Integer processed = 0;
        \\    public static Boolean finished = false;
        \\    global Database.QueryLocator start(Database.BatchableContext bc) {
        \\        return Database.getQueryLocator([
        \\            SELECT Id FROM Account WHERE Name = 'Missing'
        \\        ]);
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        processed++;
        \\    }
        \\    global void finish(Database.BatchableContext bc) {
        \\        finished = true;
        \\    }
        \\}
        \\public class EmptyQueryLocatorBatchTest {
        \\    public static String test() {
        \\        insert new Account(Name = 'Keep');
        \\        String jobId = Database.executeBatch(new EmptyQueryLocatorBatch());
        \\        AsyncApexJob job = [
        \\            SELECT JobItemsProcessed, TotalJobItems
        \\            FROM AsyncApexJob
        \\            WHERE Id = :jobId
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(EmptyQueryLocatorBatch.processed) +
        \\            ':' + String.valueOf(EmptyQueryLocatorBatch.finished) +
        \\            ':' + String.valueOf(job.JobItemsProcessed) +
        \\            ':' + String.valueOf(job.TotalJobItems);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "EmptyQueryLocatorBatchTest", "test", "0:true:0:0");
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
        \\        return Database.getQueryLocator([
        \\            SELECT Id
        \\            FROM Parent__c
        \\            WHERE TotalChildren__c = 0
        \\        ]);
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
        \\        return String.valueOf([
        \\            SELECT Id FROM Parent__c WHERE Id = :parent.Id
        \\        ].size());
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
    try expect_entry_string(source, "DeferredFinishBatchTest", "test", "queued:0");
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
        \\        public List<Database.DeleteResult> deleteRecords(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.deleteRecords(rows);
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
        \\        return Database.getQueryLocator([
        \\            SELECT Id
        \\            FROM Parent__c
        \\            WHERE RetentionDate__c <= :System.today()
        \\        ]);
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
        \\        Parent__c parent = new Parent__c(
        \\            Name = 'Parent',
        \\            RetentionDate__c = System.today().addDays(-1)
        \\        );
        \\        insert parent;
        \\        insert new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        Database.executeBatch(new WrappedHardDeleteBatch());
        \\        return String.valueOf([SELECT Id FROM Child__c].size())
        \\            + ':'
        \\            + String.valueOf([
        \\                SELECT Id
        \\                FROM Parent__c
        \\                WHERE Id = :parent.Id
        \\            ].size());
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
        \\        public List<Database.DeleteResult> deleteRecords(List<SObject> rows) {
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
        \\        CleanupGateway.getDatabase().deleteRecords(rows);
        \\        return String.valueOf([SELECT Id FROM Account].size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "WrapperDeleteProbe", "test", "0");
}

test "E2E: wrapper database instance can hard-delete queried rows" {
    const source =
        \\public class CleanupGateway {
        \\    public class Database {
        \\        public List<Database.DeleteResult> deleteRecords(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.deleteRecords(rows);
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
    try expect_entry_string(source, "WrapperHardDeleteProbe", "test", "0");
}

test "E2E: executeBatch can hard-delete rows through a wrapper database class" {
    const source =
        \\public class CleanupGateway {
        \\    public class Database {
        \\        public List<Database.DeleteResult> deleteRecords(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.deleteRecords(rows);
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
    try expect_entry_string(source, "WrappedDeleteBatchTest", "test", "0");
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
        \\        return String.valueOf(rows.size()) +
        \\            ':' + String.valueOf(deleteCount) +
        \\            ':' + String.valueOf(customCount);
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

test "E2E: aggregate query supports GROUP BY ROLLUP subtotals" {
    const source =
        \\public class AggregateRollupProbe {
        \\    public static String test() {
        \\        Account acct = new Account(Name = 'Acme');
        \\        insert acct;
        \\        insert new List<Task>{
        \\            new Task(Subject = 'Open', WhatId = acct.Id, Status = 'Not Started'),
        \\            new Task(Subject = 'Done', WhatId = acct.Id, Status = 'Completed')
        \\        };
        \\        Integer total = 0;
        \\        Integer closed = 0;
        \\        for (AggregateResult row : [
        \\            SELECT WhatId, IsClosed, COUNT(Id) cnt
        \\            FROM Task
        \\            WHERE WhatId = :acct.Id
        \\            GROUP BY ROLLUP(WhatId, IsClosed)
        \\        ]) {
        \\            if ((Id) row.get('WhatId') == acct.Id && row.get('IsClosed') == null) {
        \\                total = (Integer) row.get('cnt');
        \\            }
        \\            if ((Id) row.get('WhatId') == acct.Id && (Boolean) row.get('IsClosed') == true) {
        \\                closed = (Integer) row.get('cnt');
        \\            }
        \\        }
        \\        return String.valueOf(total) + ':' + String.valueOf(closed);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AggregateRollupProbe", "test", "2:1");
}

test "E2E: SOQL IN bind accepts colon without whitespace" {
    const source =
        \\public class InBindNoWhitespaceProbe {
        \\    public static String test() {
        \\        Account first = new Account(Name = 'First');
        \\        Account second = new Account(Name = 'Second');
        \\        insert new List<Account>{ first, second };
        \\        insert new List<Contact>{
        \\            new Contact(LastName = 'One', AccountId = first.Id),
        \\            new Contact(LastName = 'Two', AccountId = second.Id)
        \\        };
        \\        Set<Id> accountIds = new Set<Id>{ first.Id };
        \\        return String.valueOf([
        \\            SELECT Id
        \\            FROM Contact
        \\            WHERE AccountId IN: accountIds
        \\        ].size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InBindNoWhitespaceProbe", "test", "1");
}

test "E2E: SOQL missing field null inequality is false" {
    const source =
        \\public class MissingFieldNullInequalityProbe {
        \\    public static String test() {
        \\        insert new Account(Name = 'Acme');
        \\        Integer nonNullCount = [
        \\            SELECT Id
        \\            FROM Account
        \\            WHERE Custom_Lookup__c != null
        \\        ].size();
        \\        Integer nullCount = [
        \\            SELECT Id
        \\            FROM Account
        \\            WHERE Custom_Lookup__c = null
        \\        ].size();
        \\        return String.valueOf(nonNullCount) + ':' + String.valueOf(nullCount);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MissingFieldNullInequalityProbe", "test", "0:1");
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
        \\        String namespacePrefix = batchClassName.contains('.')
        \\            ? batchClassName.substringBefore('.')
        \\            : null;
        \\        String apexClassName = batchClassName.contains('.')
        \\            ? batchClassName.substringAfter('.')
        \\            : batchClassName;
        \\        String jobId = Database.executeBatch(new AsyncJobProbeBatch());
        \\        List<AsyncApexJob> jobs = [
        \\            SELECT Id, JobType, Status, CreatedBy.Name, JobItemsProcessed, TotalJobItems
        \\            FROM AsyncApexJob
        \\            WHERE
        \\                Id = :jobId
        \\                AND ApexClass.NamespacePrefix = :namespacePrefix
        \\                AND ApexClass.Name = :apexClassName
        \\        ];
        \\        AsyncApexJob job = jobs.get(0);
        \\        return String.valueOf(jobs.size()) +
        \\            ':' + job.JobType +
        \\            ':' + job.Status +
        \\            ':' + job.CreatedBy.Name +
        \\            ':' + String.valueOf(job.JobItemsProcessed) +
        \\            ':' + String.valueOf(job.TotalJobItems);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "AsyncJobProbeTest",
        "test",
        "1:BatchApex:Completed:Test User:1:1",
    );
}

test "E2E: batch finish queueable is not visible before stopTest" {
    const source =
        \\global class DeferredQueueable implements Queueable {
        \\    global void execute(QueueableContext qc) {}
        \\}
        \\global class DeferredBatch implements Database.Batchable<SObject> {
        \\    public static String state = 'initial';
        \\    global Iterable<SObject> start(Database.BatchableContext bc) {
        \\        return new List<SObject>{ new Account(Name = 'Acme') };
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        \\        DeferredBatch.state = 'executed';
        \\    }
        \\    global void finish(Database.BatchableContext bc) {
        \\        System.enqueueJob(new DeferredQueueable());
        \\    }
        \\}
        \\public class DeferredBatchTest {
        \\    public static String test() {
        \\        Test.startTest();
        \\        Id jobId = Database.executeBatch(new DeferredBatch());
        \\        Integer jobsBeforeStop = [
        \\            SELECT COUNT()
        \\            FROM AsyncApexJob
        \\        ];
        \\        String beforeStop = DeferredBatch.state + ':' + String.valueOf(jobsBeforeStop);
        \\        Test.stopTest();
        \\        return beforeStop + ':' + DeferredBatch.state;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DeferredBatchTest", "test", "executed:1:executed");
}

test "E2E: AsyncApexJob namespace prefix matches blank namespace filters" {
    const source =
        \\global class AsyncJobNamespaceProbeBatch implements Database.Batchable<SObject> {
        \\    global Iterable<SObject> start(Database.BatchableContext bc) {
        \\        return new List<SObject>();
        \\    }
        \\    global void execute(Database.BatchableContext bc, List<SObject> scope) {}
        \\    global void finish(Database.BatchableContext bc) {}
        \\}
        \\public class AsyncJobNamespaceProbeTest {
        \\    public static Integer test() {
        \\        Database.executeBatch(new AsyncJobNamespaceProbeBatch());
        \\        String namespacePrefix = '';
        \\        return [
        \\            SELECT Id
        \\            FROM AsyncApexJob
        \\            WHERE JobType = 'BatchApex'
        \\                AND ApexClass.Name = 'AsyncJobNamespaceProbeBatch'
        \\                AND ApexClass.NamespacePrefix = :namespacePrefix
        \\        ].size();
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "AsyncJobNamespaceProbeTest", "test", 1);
}

test "E2E: System.schedule creates queryable CronTrigger and AsyncApexJob records" {
    const source =
        \\global class CronProbeJob implements Schedulable {
        \\    global void execute(SchedulableContext sc) {}
        \\}
        \\public class CronTriggerProbeTest {
        \\    public static String test() {
        \\        System.schedule('Nightly Job', '0 0 23 ? * *', new CronProbeJob());
        \\        Set<String> jobNames = new Set<String>{ 'Nightly Job' };
        \\        List<CronTrigger> jobs = [
        \\            SELECT Id, CronExpression, CronJobDetail.Name
        \\            FROM CronTrigger
        \\            WHERE CronJobDetail.Name IN :jobNames
        \\                AND CronJobDetail.JobType = '7'
        \\        ];
        \\        List<AsyncApexJob> asyncJobs = [
        \\            SELECT Id, ApexClass.Name, JobType
        \\            FROM AsyncApexJob
        \\            WHERE JobType = 'ScheduledApex'
        \\        ];
        \\        System.abortJob(jobs[0].Id);
        \\        Integer remainingJobs = [
        \\            SELECT Id
        \\            FROM CronTrigger
        \\            WHERE CronJobDetail.Name IN :jobNames
        \\                AND CronJobDetail.JobType = '7'
        \\        ].size();
        \\        return String.valueOf(jobs.size()) + ':' +
        \\            jobs[0].CronJobDetail.Name + ':' + jobs[0].CronExpression + ':' +
        \\            String.valueOf(asyncJobs.size()) + ':' + asyncJobs[0].ApexClass.Name + ':' +
        \\            String.valueOf(remainingJobs);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CronTriggerProbeTest",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "1:Nightly Job:0 0 23 ? * *:1:CronProbeJob:0",
        result.value.string,
    );
}

test "E2E: executeBatch publishes BatchApexErrorEvent for raises-platform-events batches" {
    const source =
        \\trigger BatchFailureTrigger on BatchApexErrorEvent (after insert) {
        \\    List<Account> insertedAccounts = new List<Account>();
        \\    for (BatchApexErrorEvent evt : Trigger.new) {
        \\        insertedAccounts.add(new Account(
        \\            Name = evt.Phase + ':' + evt.ExceptionType + ':' + evt.Message
        \\        ));
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
        "EXECUTE:System.IllegalArgumentException:EXECUTE|" ++
            "FINISH:System.IllegalArgumentException:FINISH|" ++
            "START:System.IllegalArgumentException:START",
        result.value.string,
    );
}

test "E2E: singleton cleanup batch hard-deletes parent after child cleanup" {
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
        \\        public virtual List<Database.DeleteResult> deleteRecords(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public virtual List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.deleteRecords(rows);
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
        \\            WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE
        \\            AND Parent__r.RetentionDate__c != NULL
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
        \\                    WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE
        \\                    AND Parent__r.RetentionDate__c != NULL
        \\                ]);
        \\            }
        \\            when Parent__c parentRecord {
        \\                queryLocator = System.Database.getQueryLocator([
        \\                    SELECT Id
        \\                    FROM Parent__c
        \\                    WHERE (
        \\                        RetentionDate__c <= :RETENTION_END_DATE
        \\                        AND RetentionDate__c != NULL
        \\                    ) OR TotalChildren__c = 0
        \\                ]);
        \\            }
        \\        }
        \\        return queryLocator;
        \\    }
        \\}
        \\public class SingletonCleanupBatchTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(
        \\            Name = 'Parent',
        \\            RetentionDate__c = System.today().addDays(-1)
        \\        );
        \\        insert parent;
        \\        insert new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        Database.executeBatch(new SingletonCleanupBatch());
        \\        return String.valueOf([SELECT Id FROM Child__c].size())
        \\            + ':'
        \\            + String.valueOf([
        \\                SELECT Id
        \\                FROM Parent__c
        \\                WHERE Id = :parent.Id
        \\            ].size());
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
        \\        public virtual List<Database.DeleteResult> deleteRecords(List<SObject> rows) {
        \\            return System.Database.delete(rows);
        \\        }
        \\        public virtual List<Database.DeleteResult> hardDeleteRecords(List<SObject> rows) {
        \\            List<Database.DeleteResult> results = this.deleteRecords(rows);
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
    try expect_entry_string(source, "SingletonCleanupStoreProbe", "test", "0");
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
        \\            WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE
        \\            AND Parent__r.RetentionDate__c != NULL
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
        \\                    WHERE Parent__r.RetentionDate__c <= :RETENTION_END_DATE
        \\                    AND Parent__r.RetentionDate__c != NULL
        \\                ]);
        \\            }
        \\            when Parent__c parentRecord {
        \\                queryLocator = System.Database.getQueryLocator([
        \\                    SELECT Id
        \\                    FROM Parent__c
        \\                    WHERE (
        \\                        RetentionDate__c <= :RETENTION_END_DATE
        \\                        AND RetentionDate__c != NULL
        \\                    ) OR TotalChildren__c = 0
        \\                ]);
        \\            }
        \\        }
        \\        return queryLocator;
        \\    }
        \\}
        \\public class DirectCleanupBatchTest {
        \\    public static String test() {
        \\        Parent__c parent = new Parent__c(
        \\            Name = 'Parent',
        \\            RetentionDate__c = System.today().addDays(-1)
        \\        );
        \\        insert parent;
        \\        insert new Child__c(Parent__c = parent.Id, Status__c = 'Open');
        \\        Database.executeBatch(new DirectCleanupBatch());
        \\        return String.valueOf([SELECT Id FROM Child__c].size())
        \\            + ':'
        \\            + String.valueOf([
        \\                SELECT Id
        \\                FROM Parent__c
        \\                WHERE Id = :parent.Id
        \\            ].size());
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
    try expect_entry_string(source, "DefaultDatabaseAllOrNothingTest", "test", "threw");
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
    try expect_entry_string(
        source,
        "ListIndexOutOfBoundsTest",
        "test",
        "List index out of bounds: 0",
    );
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
    try expect_entry_string(source, "JsonFieldInitializerTest", "test", "ok");
}

test "E2E: JSON.deserialize restores typed map values" {
    const source =
        \\public class JsonTypedMapValueTest {
        \\    public class Summary {
        \\        public String batchId;
        \\        public Integer total;
        \\    }
        \\    public static String test() {
        \\        Summary summary = new Summary();
        \\        summary.batchId = '707000000000001';
        \\        summary.total = 2;
        \\        Map<String, Summary> original = new Map<String, Summary>{ 'run' => summary };
        \\        String payload = JSON.serialize(original);
        \\        Map<String, Summary> restored =
        \\            (Map<String, Summary>) JSON.deserialize(payload, Map<String, Summary>.class);
        \\        return restored.keySet().size() + ':' + restored.get('run').batchId + ':' +
        \\            String.valueOf(restored.get('run').total);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "JsonTypedMapValueTest", "test", "1:707000000000001:2");
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
    try expect_entry_string(source, "StaticSingletonFieldTest", "test", "ready");
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
    try expect_entry_string(source, "StaticInitCrossClassSingletonTest", "test", "ready");
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
        \\        Integer len = Schema.User.SObjectType
        \\            .getDescribe()
        \\            .fields.getMap()
        \\            .get('Id')
        \\            .getDescribe()
        \\            .getLength();
        \\        return user == null ? 'null' : String.valueOf(len > 0);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SchemaQualifiedSObjectTypeShadowTest", "test", "true");
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
    try expect_entry_string(
        source,
        "SchemaQualifiedSObjectTypeStandaloneAssignmentTest",
        "test",
        "User",
    );
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
    try expect_entry_string(source, "SwitchElseRuntimeTest", "test", "bad:Z");
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
        \\        return thrownException == null
        \\            ? 'missing'
        \\            : thrownException.getTypeName() + ':' + thrownException.getMessage();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "QualifiedExceptionCtorTest",
        "test",
        "System.IllegalArgumentException:bad",
    );
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
    try expect_entry_string(
        source,
        "InnerQualifiedExceptionSwitchTest",
        "test",
        "bad:THIS_IS_AN_INVALID_OPERATOR",
    );
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
    try expect_entry_string(
        source,
        "ConstructorExceptionPropagationTest",
        "test",
        "bad:THIS_IS_AN_INVALID_OPERATOR",
    );
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
    try expect_entry_string(source, "TestSetCreatedDateRuntimeTest", "test", "1:true:false");
}

test "E2E: SOQL LAST_N_DAYS filters CreatedDate" {
    const source =
        \\public class LastNDaysCreatedDateFilterTest {
        \\    public static Integer test() {
        \\        Account recentRecord = new Account(Name = 'Recent');
        \\        Account oldRecord = new Account(Name = 'Old');
        \\        insert new List<Account>{ recentRecord, oldRecord };
        \\        System.Test.setCreatedDate(oldRecord.Id, Datetime.now().addDays(-60));
        \\        return [SELECT count() FROM Account WHERE CreatedDate = LAST_N_DAYS:30];
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "LastNDaysCreatedDateFilterTest", "test", 1);
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
    try expect_entry_string(source, "InsertedLiveCreatedDateVisibilityTest", "test", "true:true");
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
    try expect_entry_string(source, "ForMultiInitRuntimeTest", "test", "6");
}

test "E2E: local multiple variable declarations define every name" {
    const source =
        \\public class LocalMultiDeclRuntimeTest {
        \\    public static String test() {
        \\        Id firstId, secondId;
        \\        Account accountRecord = new Account(Name = 'Acme');
        \\        insert accountRecord;
        \\        firstId = accountRecord.Id;
        \\        secondId = accountRecord.Id;
        \\        return String.valueOf(firstId != null) + ':' +
        \\            String.valueOf(secondId != null) + ':' +
        \\            String.valueOf(firstId == secondId);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "LocalMultiDeclRuntimeTest", "test", "true:true:true");
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
    try expect_entry_string(
        source,
        "TestSetCreatedDateOrderByTest",
        "test",
        "001000000000000002:Newer",
    );
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
    try expect_entry_string(source, "SplitEscapedPipeTest", "test", "2:true:false");
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
        \\        Contact queried = [
        \\            SELECT AccountId, Account.CreatedDate
        \\            FROM Contact
        \\            WHERE Id = :contactRecord.Id
        \\        ];
        \\        Datetime actual = (Datetime) queried.getSObject('Account').get('CreatedDate');
        \\        return String.valueOf(actual == target);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ParentCreatedDateMaterializationTest", "test", "true");
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
    try expect_entry_string(
        source,
        "OrganizationMetadataAccessTest",
        "test",
        "true:true:true:true:true",
    );
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
    try expect_entry_string(source, "ListOverloadForwarder", "test", "sobject:1");
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
    try expect_entry_string(source, "SObjectConstructorOverloadTest", "test", "record:event");
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
    try expect_entry_string(source, "NullCollectionOverloadTest", "test", "List:Map:Iterable");
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
    try expect_entry_string(source, "IterableIdOverloadTest", "test", "Iterable");
}

test "E2E: unsaved standard-object lists prefer List<SObject> overloads" {
    const source =
        \\public class StandardObjectListOverloadTest {
        \\    public String pick(Id recordId) { return 'Id'; }
        \\    public String pick(List<SObject> rows) {
        \\        return rows == null ? 'List:null' : 'List:' + String.valueOf(rows.size());
        \\    }
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
    try expect_entry_string(source, "StandardObjectListOverloadTest", "test", "List:2");
}

test "E2E: List.sort keeps strings before numbers for mixed Object values" {
    const source =
        \\public class MixedObjectSortTest {
        \\    public static String test() {
        \\        List<Object> values = new List<Object>{ 'some-tag', 'another-tag', 1 };
        \\        values.sort();
        \\        return String.valueOf(values.get(0))
        \\            + '|' + String.valueOf(values.get(1))
        \\            + '|' + String.valueOf(values.get(2));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MixedObjectSortTest", "test", "another-tag|some-tag|1");
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
    try expect_entry_string(source, "StringSortTest", "test", "another-tag|some-tag|1");
}

test "E2E: List.sort orders SObjects by regular fields instead of audit Ids" {
    const source =
        \\public class SObjectSortTest {
        \\    public static String test() {
        \\        List<Thing__c> values = new List<Thing__c>{
        \\            new Thing__c(Id = 'a000000000000002', Name = 'Beta', Rank__c = 2),
        \\            new Thing__c(Id = 'a000000000000001', Name = 'Alpha', Rank__c = 1)
        \\        };
        \\        values.sort();
        \\        return values[0].Name + ':' + values[1].Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SObjectSortTest", "test", "Alpha:Beta");
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
    try expect_entry_string(source, "FieldMapOverloadTest", "test", "matched");
}

test "E2E: Schema field token strings resolve describe map entries for put" {
    const source =
        \\public class FieldStringLookupTest {
        \\    public static String test() {
        \\        Map<String, Object> valuesByFieldName = new Map<String, Object>{
        \\            Schema.Account.Name.toString() => 'Acme'
        \\        };
        \\        Map<Schema.SObjectField, Object> resolvedFieldToValue =
        \\            new Map<Schema.SObjectField, Object>();
        \\        for (String fieldName : valuesByFieldName.keySet()) {
        \\            Schema.SObjectField field = Schema.Account.SObjectType
        \\                .getDescribe()
        \\                .fields.getMap()
        \\                .get(fieldName);
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
    try expect_entry_string(source, "FieldStringLookupTest", "test", "Acme");
}

test "E2E: describe-derived SObject field map keys stay distinct across multiple fields" {
    const source =
        \\public class DescribeDerivedFieldKeyTest {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectField> describeFields =
        \\            Schema.Account.SObjectType.getDescribe().fields.getMap();
        \\        Map<Schema.SObjectField, String> valuesByField = new Map<Schema.SObjectField, String>();
        \\        valuesByField.put(describeFields.get('Name'), 'name');
        \\        valuesByField.put(describeFields.get('OwnerId'), 'owner');
        \\        return valuesByField.size()
        \\            + ':' + valuesByField.get(describeFields.get('Name'))
        \\            + ':' + valuesByField.get(describeFields.get('OwnerId'));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DescribeDerivedFieldKeyTest", "test", "2:name:owner");
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
        \\            WHERE UserId = :System.UserInfo.getUserId()
        \\            AND RecordId IN :recordIds
        \\            AND HasDeleteAccess = TRUE
        \\        ];
        \\        return String.valueOf(accessRows.size())
        \\            + ':' + String.valueOf(accessRows.get(0).RecordId == account.Id);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UserRecordAccessDeleteQueryTest", "test", "1:true");
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
    try expect_entry_integer(source, "MultiHopParentWhereTest", "test", 1);
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
    try expect_entry_string(source, "DatabaseDmlOptionsTest", "test", "true:false:true:false");
}

test "E2E: partial DML static snapshot preserves shared object aliases" {
    const source =
        \\public class PartialDmlStaticAliasBox {
        \\    public Account value;
        \\}
        \\public class PartialDmlStaticAliasProbe {
        \\    public static Account shared;
        \\    public static PartialDmlStaticAliasBox box;
        \\    public static String test() {
        \\        shared = new Account(Name = 'before');
        \\        box = new PartialDmlStaticAliasBox();
        \\        box.value = shared;
        \\        List<Account> rows = new List<Account>{ new Account() };
        \\        List<Database.SaveResult> results = Database.insert(rows, false);
        \\        box.value.Name = 'after';
        \\        return String.valueOf(results[0].isSuccess()) + ':' +
        \\            shared.Name + ':' +
        \\            box.value.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PartialDmlStaticAliasProbe", "test", "false:after:after");
}

test "E2E: update uses reassigned SObject Id field" {
    const source =
        \\public class ReassignedIdUpdateTest {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'Existing');
        \\        insert a;
        \\        List<Account> updateRows = [SELECT Id, Name FROM Account WHERE Id = :a.Id];
        \\        updateRows[0].Id = '001000000009999';
        \\        updateRows[0].Name = 'Missing';
        \\        Database.SaveResult result = Database.update(updateRows[0], false);
        \\        Account stored = [SELECT Id, Name FROM Account WHERE Id = :a.Id];
        \\        return String.valueOf(result.isSuccess()) + ':' +
        \\            String.valueOf(result.getErrors().size()) + ':' +
        \\            stored.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ReassignedIdUpdateTest", "test", "false:1:Existing");
}

test "E2E: relaxed fixture mode still reports missing update rows in partial DML" {
    const source =
        \\public class RelaxedPartialUpdateProbe {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'Existing');
        \\        insert a;
        \\        List<Account> rows = new List<Account>{
        \\            new Account(Id = '001000000009999', Name = 'Missing'),
        \\            new Account(Id = a.Id, Name = 'Updated')
        \\        };
        \\        List<Database.SaveResult> results = Database.update(rows, false);
        \\        return String.valueOf(results[0].isSuccess()) + ':' +
        \\            String.valueOf(results[0].getErrors().size()) + ':' +
        \\            String.valueOf(results[1].isSuccess());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RelaxedPartialUpdateProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:1:true", result.value.string);
}

test "E2E: relaxed fixture mode still reports idless partial updates" {
    const source =
        \\public class RelaxedPartialIdlessUpdateProbe {
        \\    public static String test() {
        \\        Database.SaveResult result = Database.update(new Account(Name = 'Missing'), false);
        \\        return String.valueOf(result.isSuccess()) + ':' +
        \\            String.valueOf(result.getErrors().size()) + ':' +
        \\            result.getErrors()[0].getStatusCode().name();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RelaxedPartialIdlessUpdateProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:1:FIELD_CUSTOM_VALIDATION_EXCEPTION", result.value.string);
}

test "E2E: queried SObject update merges stored fields before after trigger" {
    const source =
        \\trigger SparseMirrorTrigger on Mirror__c (after update) {
        \\    for (Mirror__c row : Trigger.new) {
        \\        if (row.Peer__c != null && row.Name == 'changed') {
        \\            update new Mirror__c(Id = row.Peer__c, Name = row.Name);
        \\        }
        \\    }
        \\}
        \\public class SparseMirrorUpdateProbe {
        \\    public static String test() {
        \\        Mirror__c peer = new Mirror__c(Name = 'old');
        \\        insert peer;
        \\        Mirror__c source = new Mirror__c(Name = 'old', Peer__c = peer.Id);
        \\        insert source;
        \\        Mirror__c queried = [SELECT Id, Name FROM Mirror__c WHERE Id = :source.Id];
        \\        queried.Name = 'changed';
        \\        update queried;
        \\        return [SELECT Name FROM Mirror__c WHERE Id = :peer.Id].Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SparseMirrorUpdateProbe", "test", "changed");
}

test "E2E: packaged list custom setting active default is applied" {
    const source =
        \\public class PackagedListSettingDefaultProbe {
        \\    public static String test() {
        \\        insert new npe4__Relationship_Lookup__c(
        \\            Name = 'Friend',
        \\            npe4__Male__c = 'Brother'
        \\        );
        \\        Map<String, npe4__Relationship_Lookup__c> rows =
        \\            npe4__Relationship_Lookup__c.getAll();
        \\        return String.valueOf(rows.get('Friend').npe4__Active__c);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackagedListSettingDefaultProbe", "test", "true");
}

test "E2E: packaged relationship labels are available when metadata is absent" {
    const source =
        \\public class PackagedRelationshipLabelProbe {
        \\    public static String test() {
        \\        return 'Buddies-Friends'.split(System.Label.npe4.Relationship_Split)[1] +
        \\            System.Label.npe4.Relationship_Split +
        \\            System.Label.npe4.Male.split(',')[0] +
        \\            ':' +
        \\            System.Label.npe4.Female.split(',')[1];
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PackagedRelationshipLabelProbe", "test", "Friends-Male:Ms.");
}

test "E2E: relaxed fixture mode still reports missing delete rows in partial DML" {
    const source =
        \\public class RelaxedPartialDeleteProbe {
        \\    public static String test() {
        \\        Account a = new Account(Name = 'Existing');
        \\        insert a;
        \\        List<Account> rows = new List<Account>{
        \\            new Account(Id = '001000000009999'),
        \\            new Account(Id = a.Id)
        \\        };
        \\        List<Database.DeleteResult> results = Database.delete(rows, false);
        \\        return String.valueOf(results[0].isSuccess()) + ':' +
        \\            String.valueOf(results[0].getErrors().size()) + ':' +
        \\            String.valueOf(results[1].isSuccess()) + ':' +
        \\            String.valueOf([SELECT COUNT() FROM Account]);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "RelaxedPartialDeleteProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:1:true:0", result.value.string);
}

test "E2E: User query by ProfileId bind synthesizes active user" {
    const source =
        \\public class UserProfileIdBindProbe {
        \\    public static String test() {
        \\        Set<Id> profileIds = new Set<Id>{ '00e000000000999' };
        \\        List<User> users = [
        \\            SELECT Email, ProfileId
        \\            FROM User
        \\            WHERE ProfileId IN :profileIds
        \\            AND IsActive = TRUE
        \\        ];
        \\        return String.valueOf(users.size()) + ':' +
        \\            (users.isEmpty() ? '' : String.valueOf(users[0].ProfileId));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UserProfileIdBindProbe", "test", "1:00e000000000999");
}

test "E2E: constructed SObject exposes field default values" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Error__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Error__c/fields/Email_Sent__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Email_Sent__c</fullName>
        \\    <defaultValue>false</defaultValue>
        \\    <label>Email Sent</label>
        \\    <type>Checkbox</type>
        \\</CustomField>
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Error__c/fields/Posted_in_Chatter__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Posted_in_Chatter__c</fullName>
        \\    <defaultValue>false</defaultValue>
        \\    <label>Posted in Chatter</label>
        \\    <type>Checkbox</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class ConstructedFieldDefaultProbe {
        \\    public static String test() {
        \\        Error__c err = new Error__c();
        \\        return String.valueOf(err.Email_Sent__c) + ':' +
        \\            String.valueOf(err.Posted_in_Chatter__c);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "ConstructedFieldDefaultProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("false:false", result.value.string);
}

test "E2E: packaged relationship required contact is enforced" {
    const source =
        \\public class PackagedRelationshipRequiredProbe {
        \\    public static String test() {
        \\        try {
        \\            insert new npe4__Relationship__c(npe4__Type__c = 'Friend');
        \\            return 'no-error';
        \\        } catch (DmlException ex) {
        \\            Database.SaveResult result = Database.insert(
        \\                new npe4__Relationship__c(npe4__Type__c = 'Friend'),
        \\                false
        \\            );
        \\            return ex.getDmlFields(0)[0] + ':' +
        \\                String.valueOf(result.isSuccess()) + ':' +
        \\                result.getErrors()[0].getStatusCode().name();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackagedRelationshipRequiredProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("null:false:REQUIRED_FIELD_MISSING", result.value.string);
}

test "E2E: packaged relationship lookup requires name" {
    const source =
        \\public class PackagedRelationshipLookupRequiredProbe {
        \\    public static String test() {
        \\        try {
        \\            insert new npe4__Relationship_Lookup__c(
        \\                Name = null,
        \\                npe4__Male__c = null,
        \\                npe4__Female__c = null,
        \\                npe4__Neutral__c = null
        \\            );
        \\            return 'no-error';
        \\        } catch (DmlException ex) {
        \\            Database.SaveResult result = Database.insert(
        \\                new npe4__Relationship_Lookup__c(Name = 'Valid'),
        \\                false
        \\            );
        \\            return ex.getTypeName() + ':' +
        \\                String.valueOf(result.isSuccess()) + ':' +
        \\                result.getErrors().size();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackagedRelationshipLookupRequiredProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("System.DmlException:true:0", result.value.string);
}

test "E2E: packaged custom installment setting requires configured fields" {
    const source =
        \\public class PackagedCustomInstallmentRequiredProbe {
        \\    public static String test() {
        \\        try {
        \\            insert new npe03__Custom_Installment_Settings__c();
        \\            return 'inserted';
        \\        } catch (DmlException e) {
        \\            insert new npe03__Custom_Installment_Settings__c(
        \\                Name = 'TenDays',
        \\                npe03__Value__c = 10,
        \\                npe03__Increment__c = 'Days'
        \\            );
        \\            return 'missing:' + String.valueOf(npe03__Custom_Installment_Settings__c.getAll().size());
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackagedCustomInstallmentRequiredProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("missing:1", result.value.string);
}

test "E2E: packaged user rollup setting requires configured fields" {
    const source =
        \\public class PackagedUserRollupRequiredProbe {
        \\    public static String test() {
        \\        try {
        \\            upsert new npo02__User_Rollup_Field_Settings__c(Name = 'Rollup');
        \\            return 'upserted';
        \\        } catch (DmlException e) {
        \\            upsert new npo02__User_Rollup_Field_Settings__c(
        \\                Name = 'Rollup',
        \\                npo02__Object_Name__c = 'Contact',
        \\                npo02__Target_Field__c = 'Description',
        \\                npo02__Field_Action__c = 'SUM',
        \\                npo02__Source_Field__c = 'Amount'
        \\            );
        \\            return 'missing:' + String.valueOf(npo02__User_Rollup_Field_Settings__c.getAll().size());
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackagedUserRollupRequiredProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("missing:1", result.value.string);
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
    try expect_entry_string(source, "DatabaseNullListDmlTest", "test", "0:0");
}

test "E2E: Database partial DML reports required and delete status codes" {
    const source =
        \\public class DatabaseDmlStatusCodeProbe {
        \\    public static String test() {
        \\        Database.SaveResult insertResult = Database.insert(new Account(), false);
        \\        Account account = new Account(Name = 'Acme');
        \\        insert account;
        \\        Database.delete(account, false);
        \\        Database.DeleteResult deleteResult = Database.delete(account, false);
        \\        return String.valueOf(insertResult.getErrors().get(0).getStatusCode())
        \\            + ':' + String.valueOf(deleteResult.getErrors().get(0).getStatusCode());
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DatabaseDmlStatusCodeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "REQUIRED_FIELD_MISSING:UNKNOWN_EXCEPTION",
        result.value.string,
    );
}

test "E2E: Database partial DML rejects Opportunity missing required fields" {
    const source =
        \\public class OpportunityRequiredFieldsProbe {
        \\    public static String test() {
        \\        Database.SaveResult result = Database.insert(
        \\            new Opportunity(Name = 'Bad', StageName = 'Closed Won'),
        \\            false
        \\        );
        \\        return String.valueOf(result.isSuccess()) + ':' +
        \\            String.valueOf([SELECT COUNT() FROM Opportunity]) + ':' +
        \\            result.getErrors()[0].getStatusCode().name();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "OpportunityRequiredFieldsProbe",
        "test",
        "false:0:REQUIRED_FIELD_MISSING",
    );
}

test "E2E: Database partial DML rejects invalid RecordTypeId" {
    const source =
        \\public class InvalidRecordTypeDmlProbe {
        \\    public static String test() {
        \\        Database.SaveResult result = Database.insert(
        \\            new Opportunity(
        \\                Name = 'Bad',
        \\                StageName = 'Closed Won',
        \\                CloseDate = Date.today(),
        \\                RecordTypeId = '0120x00000QF099999'
        \\            ),
        \\            false
        \\        );
        \\        return String.valueOf(result.isSuccess()) + ':' +
        \\            String.valueOf([SELECT COUNT() FROM Opportunity]) + ':' +
        \\            result.getErrors()[0].getStatusCode().name();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "InvalidRecordTypeDmlProbe",
        "test",
        "false:0:INVALID_CROSS_REFERENCE_KEY",
    );
}

test "E2E: Database partial DML keeps row addError failures partial" {
    const source =
        \\trigger PartialAccountAddErrorTrigger on Account (before insert) {
        \\    for (Account row : Trigger.new) {
        \\        if (row.Name == 'Blocked') {
        \\            row.addError('blocked row');
        \\        }
        \\    }
        \\}
        \\public class PartialDmlRowAddErrorProbe {
        \\    public static String test() {
        \\        List<Account> rows = new List<Account>{
        \\            new Account(Name = 'Allowed'),
        \\            new Account(Name = 'Blocked')
        \\        };
        \\        List<Database.SaveResult> results = Database.insert(rows, false);
        \\        return String.valueOf(results[0].isSuccess()) + ':' +
        \\            String.valueOf(results[1].isSuccess()) + ':' +
        \\            String.valueOf([SELECT COUNT() FROM Account]);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PartialDmlRowAddErrorProbe", "test", "true:false:1");
}

test "E2E: DmlException exposes row messages and field names" {
    const source =
        \\public class DmlExceptionDetailsProbe {
        \\    public static String test() {
        \\        try {
        \\            insert new Account();
        \\        } catch (DmlException e) {
        \\            return String.valueOf(e.getNumDml())
        \\                + ':' + e.getDmlMessage(0)
        \\                + ':' + String.join(e.getDmlFieldNames(0), ',');
        \\        }
        \\        return 'no exception';
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DmlExceptionDetailsProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "1:Required fields are missing: [Name]:Name",
        result.value.string,
    );
}

test "E2E: after update addError rolls back stored fields" {
    const source =
        \\public class AfterUpdateRollbackFlag {
        \\    public static Boolean block = true;
        \\}
        \\trigger AccountRollbackTrigger on Account (after update) {
        \\    if (AfterUpdateRollbackFlag.block) {
        \\        for (Account row : Trigger.new) {
        \\            row.addError('blocked update');
        \\        }
        \\    }
        \\}
        \\public class AfterUpdateRollbackProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'before');
        \\        insert account;
        \\        account.Name = 'failed';
        \\        String caught = 'no';
        \\        try {
        \\            update account;
        \\        } catch (DmlException ex) {
        \\            caught = ex.getMessage();
        \\        }
        \\        String afterFailed = [SELECT Name FROM Account WHERE Id = :account.Id].Name;
        \\        AfterUpdateRollbackFlag.block = false;
        \\        account.Name = 'after';
        \\        update account;
        \\        String afterSuccess = [SELECT Name FROM Account WHERE Id = :account.Id].Name;
        \\        return caught + ':' + afterFailed + ':' + afterSuccess;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "AfterUpdateRollbackProbe",
        "test",
        "blocked update:before:after",
    );
}

test "E2E: Set instanceof respects generic element type" {
    const source =
        \\public class SetInstanceOfGenericProbe {
        \\    public static String test() {
        \\        Set<SObject> sobs = new Set<SObject>{ new Account() };
        \\        Set<Object> objs = new Set<Object>{ 'x' };
        \\        return String.valueOf(sobs instanceof Set<SObject>)
        \\            + ':' + String.valueOf(sobs instanceof Set<Object>)
        \\            + ':' + String.valueOf(objs instanceof Set<Object>);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SetInstanceOfGenericProbe", "test", "true:false:true");
}

test "E2E: collection casts reject non-collection values" {
    const source =
        \\public class CollectionCastTypeProbe {
        \\    public static String test() {
        \\        Object value = '006000000000001';
        \\        try {
        \\            Set<Id> ids = (Set<Id>) value;
        \\            return 'no exception:' + String.valueOf(ids);
        \\        } catch (System.TypeException ex) {
        \\            return ex.getMessage();
        \\        }
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "CollectionCastTypeProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Invalid conversion from runtime type String to Set<Id>",
        result.value.string,
    );
}

test "E2E: primitive casts reject incompatible object values" {
    const source =
        \\public class PrimitiveCastTypeProbe {
        \\    public static String test() {
        \\        Map<String, Object> values = new Map<String, Object>{
        \\            'String' => true,
        \\            'Boolean' => 'not-bool'
        \\        };
        \\        String result = '';
        \\        try {
        \\            String text = (String) values.get('String');
        \\            result += 'string-ok:' + text;
        \\        } catch (System.TypeException ex) {
        \\            result += 'string-type';
        \\        }
        \\        try {
        \\            Boolean flag = (Boolean) values.get('Boolean');
        \\            result += ':boolean-ok:' + String.valueOf(flag);
        \\        } catch (System.TypeException ex) {
        \\            result += ':boolean-type';
        \\        }
        \\        return result;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "PrimitiveCastTypeProbe",
        "test",
        "string-type:boolean-type",
    );
}

test "E2E: List String to List Id cast validates id strings" {
    const source =
        \\public class ListIdCastValidationProbe {
        \\    public static String test() {
        \\        try {
        \\            List<Id> ids = (List<Id>) 'blah'.split(',');
        \\            return 'no exception:' + String.valueOf(ids);
        \\        } catch (System.StringException ex) {
        \\            List<Id> ids = (List<Id>) '001000000000001'.split(',');
        \\            return String.valueOf(ids.size()) + ':' + String.valueOf(ids[0]);
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ListIdCastValidationProbe", "test", "1:001000000000001");
}

test "E2E: date range checkbox formulas evaluate OR ISBLANK AND TODAY" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/EventWindow__c/fields");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/EventWindow__c/fields/Active__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Active__c</fullName>
        \\    <formula>OR( ISBLANK( EndDate__c ), AND( EndDate__c &gt;= TODAY(), NOT( StartDate__c &gt; EndDate__c ) ) )</formula>
        \\    <type>Checkbox</type>
        \\</CustomField>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class DateRangeFormulaProbe {
        \\    public static String test() {
        \\        Date today = Date.today();
        \\        EventWindow__c current = new EventWindow__c(StartDate__c = today, EndDate__c = today.addMonths(1));
        \\        EventWindow__c openEnded = new EventWindow__c(StartDate__c = today, EndDate__c = null);
        \\        EventWindow__c expired = new EventWindow__c(StartDate__c = today.addMonths(-2), EndDate__c = today.addMonths(-1));
        \\        insert new List<EventWindow__c>{ current, openEnded, expired };
        \\        List<EventWindow__c> rows = [SELECT Active__c FROM EventWindow__c ORDER BY Id];
        \\        return String.valueOf(rows[0].Active__c) + ':' +
        \\            String.valueOf(rows[1].Active__c) + ':' +
        \\            String.valueOf(rows[2].Active__c);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "DateRangeFormulaProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("true:true:false", result.value.string);
}

test "E2E: collection casts allow concrete SObject lists as SObject lists" {
    const source =
        \\public class SObjectCollectionCastProbe {
        \\    public static String test() {
        \\        Object value = new List<Account>{ new Account(Name = 'Acme') };
        \\        List<SObject> rows = (List<SObject>) value;
        \\        return String.valueOf(rows.size()) + ':' + rows[0].getSObjectType().getDescribe().getName();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SObjectCollectionCastProbe", "test", "1:Account");
}

test "E2E: instanceof matches inner interface qualified name" {
    const source =
        \\public class InnerInterfaceInstanceofProbe implements IA {
        \\    public interface IA {}
        \\    public static String test() {
        \\        Object instance = new InnerInterfaceInstanceofProbe();
        \\        return String.valueOf(instance instanceof InnerInterfaceInstanceofProbe.IA);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InnerInterfaceInstanceofProbe", "test", "true");
}

test "E2E: standard address field describe exposes spaced label" {
    const source =
        \\public class StandardFieldLabelProbe {
        \\    public static String test() {
        \\        return Account.BillingCity.getDescribe().getLabel();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StandardFieldLabelProbe", "test", "Billing City");
}

test "E2E: managed package recurring donation stage label resolves" {
    const source =
        \\public class ManagedPackageLabelProbe {
        \\    public static String test() {
        \\        return System.Label.npe03.RecurringDonationStageName;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ManagedPackageLabelProbe", "test", "Pledged");
}

test "E2E: JSON-deserialized DML errors expose message status and fields" {
    const source =
        \\public class JsonDmlErrorAccessTest {
        \\    public static String test() {
        \\        Database.SaveResult result = (Database.SaveResult) JSON.deserialize(
        \\            '{"success":false,"errors":[' +
        \\                '{"message":"Could not save...",' +
        \\                '"statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION",' +
        \\                '"fields":["Name","Industry"]}' +
        \\            ']}',
        \\            Database.SaveResult.class
        \\        );
        \\        Database.Error errorRow = result.getErrors().get(0);
        \\        return String.valueOf(errorRow.getStatusCode())
        \\            + ':' + errorRow.getMessage()
        \\            + ':' + String.join(errorRow.getFields(), ',');
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
        \\            '{"success":false,"errors":[' +
        \\                '{"message":"Could not save...",' +
        \\                '"statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION",' +
        \\                '"fields":["Name"]}' +
        \\            ']}',
        \\            Database.SaveResult.class
        \\        );
        \\        return result.errors.get(0).getMessage()
        \\            + ':' + String.join(result.errors.get(0).getFields(), ',');
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "JsonDmlErrorDirectAccessTest",
        "test",
        "Could not save...:Name",
    );
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
        \\            public virtual List<Database.UndeleteResult> undeleteRecords(
        \\                List<SObject> records,
        \\                Boolean allOrNone
        \\            ) {
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
        \\        List<Database.UndeleteResult> results =
        \\            DataStore.getDatabase().undeleteRecords(rows, false);
        \\        List<Account> persisted = [SELECT Id, IsDeleted FROM Account WHERE Id IN :rows ALL ROWS];
        \\        return String.valueOf(results.size()) + '|' +
        \\            String.valueOf(results.get(0).isSuccess()) + '|' +
        \\            String.valueOf(results.get(1).isSuccess()) + '|' +
        \\            String.valueOf(persisted.get(0).IsDeleted) + '|' +
        \\            String.valueOf(persisted.get(1).IsDeleted);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PartialUndeleteOrderTest", "test", "2|true|false|false|false");
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
        \\            return String.valueOf(reservedValue == limitValue - 1)
        \\                + ':' + message.getHtmlBody()
        \\                + ':' + String.valueOf(Limits.getEmailInvocations());
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MessagingSingleEmailCapacityTest", "test", "true:hello:1");
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
    try expect_entry_string(source, "TypeForNameSObjectTest", "test", "Account");
}

test "E2E: fixture flow definition view selector test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogManagementDataSelector_Tests_Flow",
        "it_returns_matching_flow_definition_view_for_specified_flow_api_name",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture cached organization selector test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LoggerEngineDataSelector_Tests",
        "it_returns_cached_organization",
        &out.writer,
    );
    defer suite.deinit();

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

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests_FieldMappings",
        "it_should_use_field_mappings_on_logger_scenario_and_log_and_" ++
            "log_entry_when_mappings_have_been_configured",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture transaction limits builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_transaction_limits_fields_when_enabled_via_logger_parameter",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture auth session builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_run_authSession_query_when_enabled_via_logger_parameter",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture organization builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_run_organization_query_when_enabled_via_logger_parameter",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture user builder test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_run_user_query_when_enabled_via_logger_parameter",
        &out.writer,
    );
    defer suite.deinit();

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
    try expect_entry_string(source, "NameInSetQueryProbe", "test", "1:Some tag!");
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
        \\        List<Thing__c> rows = [
        \\            SELECT Id, Name, UniqueId__c
        \\            FROM Thing__c
        \\            WHERE UniqueId__c = 'txn-1'
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' + rows.get(0).Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ExternalIdUpsertProbe", "test", "1:updated");
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
    try expect_entry_string(source, "EqualityBindCollectionProbe", "test", "1:alpha");
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
    try expect_entry_string(source, "UserAliasQueryProbe", "test", "autoproc:AutomatedProcess");
}

test "E2E: fixture duplicate scenario guard test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LoggerScenarioHandler_Tests",
        "it_should_not_allow_duplicate_scenario_to_be_inserted",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture tag creation test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests",
        "it_should_create_tag_records_when_tagging_is_enabled",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture tag reuse test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests",
        "it_should_reuse_existing_tag_records",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture event-uuid upsert test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventHandler_Tests",
        "it_should_upsert_log_entries_when_event_uuid_is_populated",
        &out.writer,
    );
    defer suite.deinit();

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
        \\        List<Thing__c> saved = [
        \\            SELECT Id, Name, UniqueId__c
        \\            FROM Thing__c
        \\            WHERE UniqueId__c = 'created-1'
        \\        ];
        \\        return String.valueOf(saved.size())
        \\            + ':' + String.valueOf(rows.get(0).Id != null)
        \\            + ':' + saved.get(0).Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ExternalIdInsertProbe", "test", "1:true:Created");
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
    try expect_entry_string(source, "SwitchOnNewSObjectProbe", "test", "custom");
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
    try expect_entry_string(source, "SetToListProbe", "test", "1:Account");
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

test "E2E: FormulaEval enum namespace supports field access and values" {
    const source =
        \\global class FormulaEvalEnumProbe {
        \\    global static String test() {
        \\        return String.valueOf(FormulaEval.FormulaReturnType.Boolean) +
        \\            ':' + String.valueOf(FormulaEval.FormulaGlobal.values().size()) +
        \\            ':' + String.valueOf(Math.pow(2, 3));
        \\    }
        \\}
    ;
    try expect_entry_string(source, "FormulaEvalEnumProbe", "test", "Boolean:4:8.0");
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
    try expect_entry_string(
        source,
        "InaccessibleFieldsProbe",
        "test",
        "present|Name=true|Amount=true",
    );
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
    try expect_entry_string(source, "DescribeFieldOwnerProbe", "test", "Opportunity|true|true");
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
    try expect_entry_string(source, "GenericListTypeProbe", "test", "true:true:true");
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
    try expect_entry_string(source, "MapValuesSObjectTypeProbe", "test", "Account");
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
    try expect_entry_string(source, "ConcreteListTypeProbe", "test", "Account:true");
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
    try expect_entry_string(source, "DistinctUnsavedSetProbe", "test", "2:2");
}

test "E2E: inner database gateway upsert writes Ids back to original rows" {
    const source =
        \\public class DataGateway {
        \\    private static Database databaseInstance = new Database();
        \\    public static Database getDatabase() {
        \\        return databaseInstance;
        \\    }
        \\    public virtual class Database {
        \\        public virtual List<Database.UpsertResult> upsertRecords(
        \\            List<SObject> records,
        \\            Schema.SObjectField externalIdField
        \\        ) {
        \\            return System.Database.upsert(records, externalIdField);
        \\        }
        \\    }
        \\}
        \\public class DataGatewayUpsertProbe {
        \\    public static String test() {
        \\        List<Thing__c> rows = new List<Thing__c>{
        \\            new Thing__c(Name = 'created', UniqueId__c = 'txn-1')
        \\        };
        \\        List<SObject> copied = new List<SObject>(rows);
        \\        DataGateway.getDatabase().upsertRecords(copied, Schema.Thing__c.UniqueId__c);
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
        \\        public virtual List<Database.UpsertResult> upsertRecords(
        \\            List<SObject> records,
        \\            Schema.SObjectField externalIdField
        \\        ) {
        \\            return System.Database.upsert(records, externalIdField);
        \\        }
        \\    }
        \\    public static String test() {
        \\        List<Thing__c> rows = new List<Thing__c>{
        \\            new Thing__c(Name = 'created', UniqueId__c = 'txn-typed')
        \\        };
        \\        getDatabase().upsertRecords(rows, Schema.Thing__c.UniqueId__c);
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
        \\        List<SObject> rows = new List<SObject>{
        \\            new Thing__c(Name = 'created', UniqueId__c = 'txn-1')
        \\        };
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
        \\        List<Thing__c> rows = new List<Thing__c>{
        \\            new Thing__c(Name = 'created', UniqueId__c = 'txn-1')
        \\        };
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
        \\        List<SObject> rows = new List<SObject>{
        \\            new Thing__c(Name = 'created', UniqueId__c = 'txn-1')
        \\        };
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

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_user_fields_when_anonymous_mode_disabled",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture standard-object recordId test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_recordId_when_template_standard_object",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture custom-object recordId test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_recordId_when_custom_object",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null record overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_record_when_null",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null list overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_list_of_records_when_list_is_null",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null map overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_map_of_sobject_records_when_map_is_null",
        &out.writer,
    );
    defer suite.deinit();

    try std.testing.expectEqual(@as(u32, 1), suite.total);
    try std.testing.expectEqual(@as(u32, 1), suite.passed);
}

test "E2E: fixture null iterable overload test passes" {
    var fixture_paths = try SampleAppFixturePaths.init(std.testing.allocator, std.testing.io);
    defer fixture_paths.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var suite = try run_single_test(
        std.testing.allocator,
        std.testing.io,
        fixture_paths.slice(),
        "LogEntryEventBuilder_Tests",
        "it_should_set_record_fields_for_iterable_ids_when_null",
        &out.writer,
    );
    defer suite.deinit();

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
    try expect_entry_string(source, "TypeForNameEventTest", "test", "hello");
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
        \\        return String.valueOf(eventRecord.Id == null)
        \\            + ':' + String.valueOf(eventRecord.get('Id') == null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "PublishedPlatformEventIdTest", "test", "true:true");
}

test "E2E: Test event bus deliver fires change event triggers" {
    const source =
        \\trigger AccountChangeProbeTrigger on AccountChangeEvent(after insert) {
        \\    AccountChangeProbe.hit =
        \\        Trigger.new[0].ChangeEventHeader.getRecordIds().size();
        \\}
        \\public class AccountChangeProbe {
        \\    public static Integer hit = 0;
        \\    public static Integer test() {
        \\        Account acct = new Account(Name = 'Before');
        \\        insert acct;
        \\        Test.startTest();
        \\        acct.Name = 'After';
        \\        update acct;
        \\        Integer beforeStop = hit;
        \\        Test.stopTest();
        \\        return beforeStop * 10 + hit;
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "AccountChangeProbe", "test", 1);
}

test "E2E: synthetic AppMenuItem query exposes app order entries" {
    const source =
        \\public class AppMenuItemQueryTest {
        \\    public static String test() {
        \\        List<AppMenuItem> items = [SELECT ApplicationId, Name FROM AppMenuItem];
        \\        return String.valueOf(items.size())
        \\            + ':' + items[0].Name
        \\            + ':' + String.valueOf(items[0].ApplicationId != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AppMenuItemQueryTest", "test", "1:Sample_App:true");
}

test "E2E: AppLauncher AppMenu setOrgSortOrder is a supported no-op" {
    const source =
        \\public class AppLauncherAppMenuProbe {
        \\    public static String test() {
        \\        List<AppMenuItem> items = [SELECT ApplicationId, Name FROM AppMenuItem];
        \\        List<Id> ordered = new List<Id>{ items[0].ApplicationId };
        \\        AppLauncher.AppMenu.setOrgSortOrder(ordered);
        \\        return 'ok';
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AppLauncherAppMenuProbe", "test", "ok");
}

test "E2E: ParentJobResult enum values are available for finalizers" {
    const source =
        \\public class ParentJobResultEnumProbe {
        \\    public static String test() {
        \\        ParentJobResult result = ParentJobResult.UNHANDLED_EXCEPTION;
        \\        switch on result {
        \\            when UNHANDLED_EXCEPTION {
        \\                return result.name();
        \\            }
        \\            when else {
        \\                return 'other';
        \\            }
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ParentJobResultEnumProbe", "test", "UNHANDLED_EXCEPTION");
}

test "E2E: overloaded constructor uses declared local type for custom class arguments" {
    const source =
        \\public class ConstructorDeclaredTypeProbe {
        \\    public class Filter_Group__mdt_Fake {
        \\        public String MasterLabel;
        \\        public String DeveloperName;
        \\        public Filter_Group__mdt_Fake(String name) {
        \\            this.MasterLabel = name;
        \\            this.DeveloperName = name;
        \\        }
        \\    }
        \\    public class Wrapper {
        \\        public String recordName;
        \\        public String label;
        \\        public Wrapper(String label) {
        \\            this.label = label.trim();
        \\            this.recordName = label;
        \\        }
        \\        public Wrapper(Filter_Group__mdt_Fake groupRecord) {
        \\            this.label = groupRecord.MasterLabel;
        \\            this.recordName = groupRecord.DeveloperName;
        \\        }
        \\    }
        \\    public class Model {
        \\        public Wrapper filterGroup;
        \\        public List<String> rows;
        \\    }
        \\    public static String test() {
        \\        Map<String, Filter_Group__mdt_Fake> byId = new Map<String, Filter_Group__mdt_Fake>{
        \\            'a' => new Filter_Group__mdt_Fake('expected')
        \\        };
        \\        Model model = setup('a', byId);
        \\        return model.filterGroup.recordName + ':' + model.filterGroup.label;
        \\    }
        \\    private static Model setup(String filterGroupId, Map<String, Filter_Group__mdt_Fake> byId) {
        \\        Model model = createFilterGroupModel(filterGroupId, byId);
        \\        model.rows = new List<String>{ 'row' };
        \\        return model;
        \\    }
        \\    private static Model createFilterGroupModel(String filterGroupId, Map<String, Filter_Group__mdt_Fake> byId) {
        \\        Model model = new Model();
        \\        Filter_Group__mdt_Fake filterGroup = byId.get(filterGroupId);
        \\        model.filterGroup = new Wrapper(filterGroup);
        \\        return model;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ConstructorDeclaredTypeProbe", "test", "expected:expected");
}

test "E2E: overloaded constructor uses declared local type for typed null SObject arguments" {
    const source =
        \\public class ConstructorTypedNullSObjectProbe {
        \\    public class Wrapper {
        \\        public String branch;
        \\        public Account accountValue;
        \\        public Wrapper(Account accountRecord) {
        \\            this.branch = 'account';
        \\            this.accountValue = accountRecord;
        \\        }
        \\        public Wrapper(Contact contactRecord) {
        \\            this.branch = 'contact';
        \\        }
        \\        public Wrapper(String textValue) {
        \\            this.branch = 'string';
        \\        }
        \\    }
        \\    public static String test() {
        \\        Account accountRecord = null;
        \\        Wrapper wrapper = new Wrapper(accountRecord);
        \\        return wrapper.branch + ':' + String.valueOf(wrapper.accountValue == null);
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "ConstructorTypedNullSObjectProbe",
        "test",
        "account:true",
    );
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
    try expect_entry_integer(source, "IntegrationTest", "test", 1);
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
    try expect_entry_string(source, "UnknownFieldGetTest", "test", "ok");
}

test "E2E: SObject.get returns null for unmanaged metadata extension fields" {
    const source =
        \\public class CustomExtensionFieldGetTest {
        \\    public static String test() {
        \\        Contact c = new Contact(LastName = 'Probe');
        \\        Object household = c.get('npo02__Household__c');
        \\        Account a = new Account(Name = 'Acme');
        \\        Object packageValue = a.get('pkg__External_Field__c');
        \\        return String.valueOf(household == null) + ':' +
        \\            String.valueOf(packageValue == null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "CustomExtensionFieldGetTest", "test", "true:true");
}

test "E2E: global describe includes source-path custom objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "force-app/main/default/objects/Widget__c/fields");
    try tmp.dir.createDirPath(std.testing.io, "force-app/main/default/classes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "force-app/main/default/objects/Widget__c/fields/Amount__c.field-meta.xml",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fullName>Amount__c</fullName>
        \\    <label>Amount</label>
        \\    <inlineHelpText>Widget.Amount</inlineHelpText>
        \\    <defaultValue>42</defaultValue>
        \\    <type>Number</type>
        \\</CustomField>
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "force-app/main/default/classes/SourcePathFieldHintProbe.cls",
        .data =
        \\public class SourcePathFieldHintProbe {
        \\    public static void mark() {
        \\        Object ignored = Account.pkg__Managed_Field__c;
        \\    }
        \\}
        ,
    });
    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(source_path);

    const source =
        \\public class GlobalDescribeCustomObjectProbe {
        \\    public static String test() {
        \\        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        \\        Schema.DescribeSObjectResult describe = gd.get('widget__c').getDescribe();
        \\        Map<String, Schema.SObjectField> fields = describe.fields.getMap();
        \\        return String.valueOf(gd.containsKey('widget__c')) + ':' +
        \\            describe.getName() + ':' +
        \\            String.valueOf(Account.SObjectType.getDescribe().fields.getMap()
        \\                .keySet().contains('pkg__Managed_Field__c')) + ':' +
        \\            String.valueOf(fields.containsKey('pkg__Managed_Field__c')) + ':' +
        \\            fields.get('pkg__Managed_Field__c').getDescribe().getName() + ':' +
        \\            String.valueOf(fields.get('Amount__c').getDescribe().getDefaultValueFormula()) + ':' +
        \\            fields.get('Amount__c').getDescribe().getInlineHelpText();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "GlobalDescribeCustomObjectProbe",
        .entry_method = "test",
        .source_paths = &.{source_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "true:Widget__c:true:true:pkg__Managed_Field__c:42:Widget.Amount",
        result.value.string,
    );
}

test "E2E: legacy object metadata picklist values feed describe" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "objects/Thing__c");
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "objects/Thing__c/Thing__c.object",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
        \\    <fields>
        \\        <fullName>Status__c</fullName>
        \\        <label>Status</label>
        \\        <type>Picklist</type>
        \\        <valueSet>
        \\            <valueSetDefinition>
        \\                <value>
        \\                    <fullName>First</fullName>
        \\                    <default>true</default>
        \\                    <label>First</label>
        \\                </value>
        \\                <value>
        \\                    <fullName>Second</fullName>
        \\                    <default>false</default>
        \\                    <isActive>false</isActive>
        \\                    <label>Second</label>
        \\                </value>
        \\            </valueSetDefinition>
        \\        </valueSet>
        \\    </fields>
        \\    <fields>
        \\        <fullName>%%%NAMESPACE%%%Legacy_Status__c</fullName>
        \\        <label>Legacy Status</label>
        \\        <type>Picklist</type>
        \\        <valueSet>
        \\            <valueSetDefinition>
        \\                <value>
        \\                    <fullName>Enabled</fullName>
        \\                    <default>true</default>
        \\                    <label>Enabled</label>
        \\                </value>
        \\            </valueSetDefinition>
        \\        </valueSet>
        \\    </fields>
        \\</CustomObject>
        ,
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    const source =
        \\public class LegacyObjectPicklistProbe {
        \\    public static String test() {
        \\        Schema.SObjectField field =
        \\            Thing__c.Status__c;
        \\        Schema.DescribeFieldResult describe =
        \\            field.getDescribe();
        \\        List<Schema.PicklistEntry> values =
        \\            describe.getPicklistValues();
        \\        Schema.DescribeFieldResult legacyDescribe =
        \\            Thing__c.Legacy_Status__c.getDescribe();
        \\        return values.get(0).getValue() + ':' +
        \\            values.get(1).getValue() + ':' +
        \\            String.valueOf(values.get(1).isActive()) + ':' +
        \\            legacyDescribe.getPicklistValues().get(0).getValue();
        \\    }
        \\}
    ;
    const result = try run(alloc, std.testing.io, source, .{
        .entry_class = "LegacyObjectPicklistProbe",
        .entry_method = "test",
        .source_paths = &.{tmp_path},
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("First:Second:false:Enabled", result.value.string);
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
    try expect_entry_string(source, "InvalidJsonParseTest", "test", "ok");
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
    try expect_entry_string(source, "InvalidDecimalValueTest", "test", "ok");
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
    try expect_entry_string(source, "MixedNumericCompoundAssignTest", "test", "15");
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
    try expect_entry_string(source, "InvalidInnerEnumValueTest", "test", "ok");
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
        \\        Map<String, Schema.SObjectField> fieldsByName =
        \\            taskRecord.getSObjectType().getDescribe().fields.getMap();
        \\        return fieldsByName.get('ActivityDate').getDescribe().getType().name()
        \\            + ':' + fieldsByName.get('Priority').getDescribe().getType().name();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TaskDescribeFieldCoverageTest", "test", "DATE:PICKLIST");
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
    try expect_entry_string(source, "ApprovalLockStateTest", "test", "true:true:true:false");
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
    try expect_entry_string(source, "BusinessHoursDiffTest", "test", "Default:86400000");
}

test "E2E: BusinessHours default predicate query returns synthetic default" {
    const source =
        \\public class BusinessHoursDefaultPredicateTest {
        \\    public static String test() {
        \\        BusinessHours hours = [
        \\            SELECT Id, IsDefault
        \\            FROM BusinessHours
        \\            WHERE IsDefault = TRUE
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(hours.IsDefault) + ':' + hours.Id;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "BusinessHoursDefaultPredicateTest",
        "test",
        "true:01m000000000001AAA",
    );
}

test "E2E: TaskPriority queries return default and high priorities" {
    const source =
        \\public class TaskPriorityQueryTest {
        \\    public static String test() {
        \\        TaskPriority high = [
        \\            SELECT MasterLabel
        \\            FROM TaskPriority
        \\            WHERE IsHighPriority = TRUE
        \\            LIMIT 1
        \\        ];
        \\        TaskPriority normal = [
        \\            SELECT MasterLabel
        \\            FROM TaskPriority
        \\            WHERE IsDefault = TRUE
        \\            LIMIT 1
        \\        ];
        \\        return high.MasterLabel + ':' + normal.MasterLabel;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "TaskPriorityQueryTest", "test", "High:Normal");
}

test "E2E: SObjectType newSObject two-arg overload treats first arg as RecordTypeId" {
    const source =
        \\public class NewSObjectRecordTypeIdProbe {
        \\    public static String test() {
        \\        Id rtId = Task.SObjectType.getDescribe().getRecordTypeInfos()[0].getRecordTypeId();
        \\        Task t = (Task) Task.SObjectType.newSObject(rtId, true);
        \\        return String.valueOf(t.Id) + ':' + t.RecordTypeId + ':' + t.Status;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "NewSObjectRecordTypeIdProbe",
        "test",
        "null:012000000000003AAA:Not Started",
    );
}

test "E2E: RecordType SOQL mirrors describe record types for queried standard object" {
    const source =
        \\public class RecordTypeSoqlDescribeProbe {
        \\    public static String test() {
        \\        Integer countValue = [
        \\            SELECT COUNT()
        \\            FROM RecordType
        \\            WHERE SObjectType = 'Task' AND IsActive = TRUE
        \\        ];
        \\        List<RecordType> records = [
        \\            SELECT Id, Name
        \\            FROM RecordType
        \\            WHERE SObjectType = 'Task' AND IsActive = TRUE
        \\            ORDER BY Name ASC
        \\        ];
        \\        return String.valueOf(countValue) + ':' + records[0].Name + ':' + records[1].Name;
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "RecordTypeSoqlDescribeProbe",
        "test",
        "2:Default:Master",
    );
}

test "E2E: Report SOQL is a known standard object" {
    const source =
        \\public class ReportQueryKnownTypeTest {
        \\    public static Integer test() {
        \\        return [SELECT Id FROM Report WHERE DeveloperName = 'Missing_Report'].size();
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "ReportQueryKnownTypeTest", "test", 0);
}

test "E2E: FiscalYearSettings SOQL is a known standard object" {
    const source =
        \\public class FiscalYearSettingsQueryKnownTypeTest {
        \\    public static Integer test() {
        \\        return [
        \\            SELECT Id
        \\            FROM FiscalYearSettings
        \\            WHERE IsStandardYear = false
        \\        ].size();
        \\    }
        \\}
    ;
    try expect_entry_integer(source, "FiscalYearSettingsQueryKnownTypeTest", "test", 0);
}

test "E2E: Metadata CustomMetadata initializes values list" {
    const source =
        \\public class MetadataCustomMetadataProbe {
        \\    public static String test() {
        \\        Metadata.CustomMetadata record = new Metadata.CustomMetadata();
        \\        Metadata.CustomMetadataValue value = new Metadata.CustomMetadataValue();
        \\        value.field = 'Flag__c';
        \\        value.value = true;
        \\        record.values.add(value);
        \\        Metadata.DeployResult result = new Metadata.DeployResult();
        \\        result.status = Metadata.DeployStatus.Succeeded;
        \\        return String.valueOf(record.values.size()) + ':' + result.status.name();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "MetadataCustomMetadataProbe", "test", "1:Succeeded");
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
    try expect_entry_string(
        source,
        "SortExceptionPropagationTest",
        "test",
        "unsupported sort type",
    );
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
    try expect_entry_string(source, "InvocableResultRoundTripProbe", "test", "true:1");
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
    try expect_entry_string(source, "PopulatedFieldsErrorsHidingProbe", "test", "false:true");
}

test "E2E: SObject addError message escape overload preserves message" {
    const source =
        \\public class AddErrorEscapeOverloadProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Probe');
        \\        account.addError('blocked message', false);
        \\        Database.Error first = account.getErrors()[0];
        \\        return first.getMessage() + ':' + String.valueOf(first.getFields().size());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "AddErrorEscapeOverloadProbe", "test", "blocked message:0");
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
    try expect_entry_string(source, "SavepointDmlCounterProbe", "test", "0:1:2");
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
    try expect_entry_string(source, "InvocableActionFlowFailureProbe", "test", "2:false:1");
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
    try expect_entry_string(source, "MultiLevelParentChainProbe", "test", "GreatGrandParent");
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
    try expect_entry_integer(source, "SelfRefChildSubqueryProbe", "test", 2);
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
    try expect_entry_string(source, "QueryLocatorIteratorProbe", "test", "Acme:2");
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
        \\               first.getFields()[0];
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
    try expect_entry_string(source, "LocationBuiltinsProbe", "test", "28.635308,77.22496|inRange");
}

test "E2E: Schema describe stubs cover tabs and common standards" {
    // Anonymized probe: package UI utility code iterates
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
        \\        String caseCommentFound =
        \\            Schema.getGlobalDescribe().get('casecomment') != null ? 'Y' : 'N';
        \\        String contractFound =
        \\            Schema.getGlobalDescribe().get('contract') != null ? 'Y' : 'N';
        \\        String assetFound =
        \\            Schema.getGlobalDescribe().get('asset') != null ? 'Y' : 'N';
        \\        return 'tabs=' + tabCount
        \\            + '|cc=' + caseCommentFound
        \\            + '|co=' + contractFound
        \\            + '|as=' + assetFound;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "SchemaStubProbe", "test", "tabs=0|cc=Y|co=Y|as=Y");
}

test "E2E: User insert defaults IsActive to true and WHERE PermissionsX = TRUE matches" {
    // Anonymized probe: package @TestSetup code queries
    //   SELECT ... FROM Profile WHERE PermissionsModifyAllData = TRUE AND UserType = 'Standard'
    // and then inserts a User without setting IsActive, later asserting
    //   SELECT ... FROM User WHERE Email = 'x' AND IsActive = TRUE
    // Two bugs had to line up: (a) extractWhereFieldValue dropped bare
    // TRUE / FALSE tokens on the floor, so applyQueriedSyntheticProfileFlags
    // never saw the permission and the Profile WHERE predicate never matched
    // — we synthesized a Profile without the flag and matchesWhere filtered
    // it out. (b) User.IsActive was unset on a fresh insert, so the WHERE
    // IsActive=TRUE filter yielded no rows and the single-record assignment
    // threw "List has no rows for assignment to SObject".
    const source =
        \\public class UserDefaultsWhereProbe {
        \\    public static String test() {
        \\        Integer matchedProfiles = 0;
        \\        for (Profile p : [
        \\            SELECT Id, PermissionsModifyAllData
        \\            FROM Profile
        \\            WHERE PermissionsModifyAllData = TRUE
        \\            AND UserType = 'Standard'
        \\            LIMIT 1
        \\        ]) {
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
        \\        Integer activeMatches = [
        \\            SELECT COUNT()
        \\            FROM User
        \\            WHERE Email = 'probe@example.com'
        \\            AND IsActive = TRUE
        \\        ];
        \\        return 'profiles=' + matchedProfiles + '|activeUsers=' + activeMatches;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UserDefaultsWhereProbe", "test", "profiles=1|activeUsers=1");
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
    // Anonymized probe: trigger tests assert that a deleted
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
    try expect_entry_string(source, "CountAllRowsProbe", "test", "active=0|trashed=1|total=1");
}

test "E2E: AFTER_UNDELETE addError rolls back undelete and raises DmlException" {
    // Anonymized probe: package trigger code uses addError() in
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
    try expect_entry_string(source, "AfterUndeleteAddErrorProbe", "test", "blocked-by-trigger");
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
    try expect_entry_string(source, "SuperFieldVisibilityProbe", "test", "E|parent-set:child");
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
        "start-rethrow|innerCatch|rethrowFinally|outerCatch|" ++
            "start-nocatch|noCatchFinally|outerNoCatch:noCatchBoom",
        result.value.string,
    );
}

test "E2E: String.replaceFirst replaces only the first regex match" {
    const source =
        \\public class StringReplaceFirstProbe {
        \\    public static String test() {
        \\        return 'npsp__Field__c'.replaceFirst('npsp__', '') + ':' +
        \\            'abc123abc'.replaceFirst('[a-z]+', 'X');
        \\    }
        \\}
    ;
    try expect_entry_string(source, "StringReplaceFirstProbe", "test", "Field__c:X123abc");
}

test "E2E: URL base URL supports toExternalForm" {
    const source =
        \\public class UrlExternalFormProbe {
        \\    public static String test() {
        \\        return URL.getSalesforceBaseUrl().toExternalForm().replaceFirst('http:', 'https:');
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UrlExternalFormProbe", "test", "https://test.salesforce.com");
}

test "E2E: Url constructor exposes path" {
    const source =
        \\public class UrlPathProbe {
        \\    public static String test() {
        \\        return new Url('https://salesforce.com/testPath').getPath() + ':' +
        \\            String.valueOf(new Url('www.salesforce.com').getPath());
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UrlPathProbe", "test", "/testPath:null");
}

test "E2E: Contact update refreshes compound Name" {
    const source =
        \\public class ContactUpdateNameProbe {
        \\    public static String test() {
        \\        Contact c = new Contact(FirstName = 'c2', LastName = 'C2');
        \\        insert c;
        \\        Contact updateContact = [
        \\            SELECT Id, FirstName, LastName, Name
        \\            FROM Contact
        \\            WHERE Id = :c.Id
        \\            LIMIT 1
        \\        ];
        \\        updateContact.LastName = 'C1';
        \\        Database.upsert(new List<SObject>{ updateContact }, false);
        \\        Contact loaded = [
        \\            SELECT Id, FirstName, LastName, Name
        \\            FROM Contact
        \\            WHERE Id = :c.Id
        \\            LIMIT 1
        \\        ];
        \\        return loaded.LastName + ':' + loaded.Name;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ContactUpdateNameProbe", "test", "C1:c2 C1");
}

test "E2E: where-like build uses SOQL branch when groups are filterable" {
    const source =
        \\public class StaticWhereBuildProbe {
        \\    private List<GroupExpression> groups;
        \\    private String logicOperator = 'AND';
        \\    private Boolean isFilterable {
        \\        get {
        \\            if (isFilterable == null) {
        \\                isFilterable = true;
        \\                for (GroupExpression groupExp : groups) {
        \\                    if (!groupExp.isFilterable()) {
        \\                        isFilterable = false;
        \\                    }
        \\                }
        \\            }
        \\            return isFilterable;
        \\        }
        \\        set;
        \\    }
        \\    public StaticWhereBuildProbe() {
        \\        groups = new List<GroupExpression>();
        \\    }
        \\    public StaticWhereBuildProbe add(GroupExpression groupExp) {
        \\        groups.add(groupExp);
        \\        return this;
        \\    }
        \\    public String build() {
        \\        List<String> result = new List<String>();
        \\        Boolean filterable = isFilterable();
        \\        if (filterable) {
        \\            for (GroupExpression groupExp : groups) result.add(groupExp.toString());
        \\        } else {
        \\            for (GroupExpression groupExp : groups) result.add(groupExp.getSearchValue());
        \\        }
        \\        return String.join(result, ' ' + logicOperator + ' ');
        \\    }
        \\    public Boolean isFilterable() {
        \\        return isFilterable;
        \\    }
        \\    public class GroupExpression {
        \\        private List<FieldExpression> fieldExpressions;
        \\        private Boolean isFilterable {
        \\            get {
        \\                if (isFilterable == null) {
        \\                    isFilterable = true;
        \\                    for (FieldExpression fieldExp : fieldExpressions) {
        \\                        if (!fieldExp.isFilterable()) isFilterable = false;
        \\                    }
        \\                }
        \\                return isFilterable;
        \\            }
        \\            set;
        \\        }
        \\        public GroupExpression() {
        \\            fieldExpressions = new List<FieldExpression>();
        \\        }
        \\        public GroupExpression add(FieldExpression fieldExp) {
        \\            fieldExpressions.add(fieldExp);
        \\            return this;
        \\        }
        \\        public Boolean isFilterable() { return isFilterable; }
        \\        public override String toString() {
        \\            List<String> result = new List<String>();
        \\            for (FieldExpression fieldExp : fieldExpressions) result.add(fieldExp.toString());
        \\            return String.join(result, ' AND ');
        \\        }
        \\        public String getSearchValue() {
        \\            List<String> result = new List<String>();
        \\            for (FieldExpression fieldExp : fieldExpressions) {
        \\                result.add(fieldExp.getSearchValue());
        \\            }
        \\            return String.join(result, ' AND ') + '*';
        \\        }
        \\    }
        \\    public class FieldExpression {
        \\        private Schema.SObjectField sObjField;
        \\        private Object value;
        \\        public Boolean isFilterable {
        \\            get {
        \\                if (isFilterable == null) {
        \\                    isFilterable = sObjField.getDescribe().isFilterable();
        \\                }
        \\                return isFilterable;
        \\            }
        \\            set;
        \\        }
        \\        public FieldExpression(Schema.SObjectField sObjField) {
        \\            this.sObjField = sObjField;
        \\        }
        \\        public FieldExpression equals(Object value) {
        \\            this.value = value;
        \\            return this;
        \\        }
        \\        public Boolean isFilterable() { return isFilterable; }
        \\        public override String toString() {
        \\            return String.valueOf(sObjField) + ' = ' +
        \\                '\'' + String.valueOf(value) + '\'';
        \\        }
        \\        public String getSearchValue() { return String.valueOf(value); }
        \\    }
        \\    private static FieldExpression nameFieldExp =
        \\        new FieldExpression(Account.Name);
        \\    private static FieldExpression websiteFieldExp =
        \\        new FieldExpression(Account.Website);
        \\    static {
        \\        nameFieldExp.isFilterable = true;
        \\        websiteFieldExp.isFilterable = true;
        \\    }
        \\    public static String test() {
        \\        websiteFieldExp.isFilterable = true;
        \\        return new StaticWhereBuildProbe()
        \\            .add(new GroupExpression().add(nameFieldExp.equals('foo')))
        \\            .add(new GroupExpression().add(websiteFieldExp.equals('bar.com')))
        \\            .build();
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "StaticWhereBuildProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Name = 'foo' AND Website = 'bar.com'",
        result.value.string,
    );
}

test "E2E: where-like IN_SET operator renders through outer helper" {
    const source =
        \\public class WhereLikeInSetOperatorProbe {
        \\    public Enum Operator {
        \\        EQUALS,
        \\        NOT_EQUALS,
        \\        IN_SET
        \\    }
        \\    private static String operatorToString(Operator operant) {
        \\        String result = null;
        \\        if (operant == Operator.EQUALS) { result = '='; }
        \\        else if (operant == Operator.NOT_EQUALS) { result = '!='; }
        \\        else if (operant == Operator.IN_SET) { result = 'IN'; }
        \\        return result;
        \\    }
        \\    public class FieldExpression {
        \\        private Schema.SObjectField sObjField;
        \\        private Operator operant;
        \\        private Object value;
        \\        private Set<Object> values;
        \\        public FieldExpression(Schema.SObjectField sObjField) {
        \\            this.sObjField = sObjField;
        \\        }
        \\        public FieldExpression inSet(Object value) {
        \\            operant = Operator.IN_SET;
        \\            this.value = value;
        \\            this.values = getValues(value);
        \\            return this;
        \\        }
        \\        private Set<Object> getValues(Object value) {
        \\            Set<Object> values = new Set<Object>();
        \\            if (value instanceof Set<String>) {
        \\                for (String val : (Set<String>) value) {
        \\                    values.add(val == null ? null : val.toLowerCase());
        \\                }
        \\            }
        \\            return values;
        \\        }
        \\        public String getFieldPath() {
        \\            return String.valueOf(sObjField);
        \\        }
        \\        public override String toString() {
        \\            return getFieldPath() + ' ' + operatorToString(operant) + ' ' +
        \\                toLiteral(value);
        \\        }
        \\        private String toLiteral(Object value) {
        \\            if (operant == Operator.IN_SET) {
        \\                List<String> result = new List<String>();
        \\                for (Object val : values) {
        \\                    result.add(toLiteral(String.valueOf(val)));
        \\                }
        \\                return '(' + String.join(result, ', ') + ')';
        \\            }
        \\            return toLiteral((String) value);
        \\        }
        \\        private String toLiteral(String value) {
        \\            if (operant == Operator.IN_SET) {
        \\                return value == null ? 'null' : '\'' + String.escapeSingleQuotes(value) + '\'';
        \\            }
        \\            return String.isBlank(value) ? 'null' : '\'' + String.escapeSingleQuotes(value) + '\'';
        \\        }
        \\    }
        \\    public static String test() {
        \\        return new FieldExpression(Account.Name)
        \\            .inSet(new Set<String>{'foo', 'bar'})
        \\            .toString();
        \\    }
        \\}
    ;
    try expect_entry_string(
        source,
        "WhereLikeInSetOperatorProbe",
        "test",
        "Name IN ('foo', 'bar')",
    );
}

test "E2E: static foreign inner object preserves enum field mutation" {
    const source =
        \\public class WhereLikeForeignFieldProbe {
        \\    public Enum Operator {
        \\        EQUALS,
        \\        NOT_EQUALS,
        \\        IN_SET
        \\    }
        \\    private static String operatorToString(Operator operant) {
        \\        String result = null;
        \\        if (operant == Operator.EQUALS) { result = '='; }
        \\        else if (operant == Operator.NOT_EQUALS) { result = '!='; }
        \\        else if (operant == Operator.IN_SET) { result = 'IN'; }
        \\        return result;
        \\    }
        \\    public class FieldExpression {
        \\        private Schema.SObjectField sObjField;
        \\        private Operator operant;
        \\        private Object value;
        \\        private Set<Object> values;
        \\        public FieldExpression(Schema.SObjectField sObjField) {
        \\            this.sObjField = sObjField;
        \\        }
        \\        public FieldExpression inSet(Object value) {
        \\            operant = Operator.IN_SET;
        \\            this.value = value;
        \\            this.values = new Set<Object>();
        \\            values.add('foo');
        \\            values.add('bar');
        \\            return this;
        \\        }
        \\        public override String toString() {
        \\            return String.valueOf(sObjField) + ' ' + operatorToString(operant) +
        \\                ' ' + '(' + String.join(new List<String>{'foo'}, ', ') + ')';
        \\        }
        \\    }
        \\}
        \\public class ForeignFieldHolderProbe {
        \\    private static WhereLikeForeignFieldProbe.FieldExpression fieldExp =
        \\        new WhereLikeForeignFieldProbe.FieldExpression(Account.Name);
        \\    public static String test() {
        \\        return fieldExp.inSet(new Set<String>{'foo', 'bar'}).toString();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ForeignFieldHolderProbe", "test", "Name IN (foo)");
}

test "E2E: typed null local does not resolve to same-named inner class" {
    const source =
        \\public class InnerNameShadowProbe {
        \\    public class Holder {
        \\        public String value;
        \\    }
        \\    public static Object test() {
        \\        Holder holder = null;
        \\        return holder;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerNameShadowProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(result.value == .null_val);
}

test "E2E: typed null local field access does not become static inner member string" {
    const source =
        \\public class InnerFieldShadowProbe {
        \\    public class Holder {
        \\        public String value;
        \\    }
        \\    public static Object test() {
        \\        Holder holder = null;
        \\        return holder.value;
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "InnerFieldShadowProbe",
        .entry_method = "test",
    });
    defer result.deinit();

    try std.testing.expect(result.value == .null_val);
}

test "E2E: Matcher replaceAll and String escapeHtml4 sanitize html" {
    const source =
        \\public class HtmlEscapeProbe {
        \\    public static String test() {
        \\        Pattern strip = Pattern.compile('(?i)on[a-z]*=".*"');
        \\        String cleaned = strip.matcher('<img src=x onerror="alert(1)">').replaceAll('');
        \\        return cleaned.escapeHtml4();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "HtmlEscapeProbe", "test", "&lt;img src=x &gt;");
}

test "E2E: unqualified instance calls do not overwrite same-named typed locals" {
    const source =
        \\public class InstanceCallLocalShadowProbe {
        \\    private List<String> values;
        \\    private List<String> touch(List<String> input) {
        \\        return new List<String>();
        \\    }
        \\    private String runInstance() {
        \\        this.values = new List<String>{ 'field' };
        \\        List<String> result = new List<String>();
        \\        List<String> values = new List<String>{ 'local' };
        \\        List<String> ignored = touch(values);
        \\        result.addAll(values);
        \\        return String.valueOf(result.size()) + ':' + result.get(0);
        \\    }
        \\    public static String test() {
        \\        return new InstanceCallLocalShadowProbe().runInstance();
        \\    }
        \\}
    ;
    try expect_entry_string(source, "InstanceCallLocalShadowProbe", "test", "1:local");
}

test "E2E: user enum static values returns declared values" {
    const source =
        \\public class UserEnumValuesProbe {
        \\    public enum Mode { Alpha, Beta }
        \\    public static String test() {
        \\        List<String> names = new List<String>();
        \\        for (Mode value : Mode.values()) {
        \\            names.add(String.valueOf(value).toUpperCase());
        \\        }
        \\        return String.valueOf(names.size()) + ':' + names.get(0) + ':' + names.get(1);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "UserEnumValuesProbe", "test", "2:ALPHA:BETA");
}

test "E2E: recurring donation insert defaults legacy date established" {
    const source =
        \\public class RecurringDonationLegacyDateDefaultProbe {
        \\    public static String test() {
        \\        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
        \\            Name = 'RD',
        \\            npe03__Amount__c = 10,
        \\            npe03__Installment_Period__c = 'Monthly'
        \\        );
        \\        insert rd;
        \\        return String.valueOf(rd.npe03__Date_Established__c != null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "RecurringDonationLegacyDateDefaultProbe", "test", "true");
}

test "E2E: contact insert creates default managed package address from mailing fields" {
    const source =
        \\public class ContactAddressInsertProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'HH');
        \\        insert account;
        \\        Contact contact = new Contact(
        \\            LastName = 'Smith',
        \\            AccountId = account.Id,
        \\            MailingStreet = '123 Main',
        \\            MailingCity = 'Seattle',
        \\            MailingState = 'WA',
        \\            MailingPostalCode = '98101',
        \\            MailingCountry = 'United States',
        \\            Undeliverable_Address__c = true
        \\        );
        \\        insert contact;
        \\        Contact storedContact = [
        \\            SELECT Current_Address__c
        \\            FROM Contact
        \\            WHERE Id = :contact.Id
        \\        ];
        \\        Address__c address = [
        \\            SELECT Default_Address__c, Undeliverable__c
        \\            FROM Address__c
        \\            WHERE Id = :storedContact.Current_Address__c
        \\        ];
        \\        Account storedAccount = [
        \\            SELECT Undeliverable_Address__c
        \\            FROM Account
        \\            WHERE Id = :account.Id
        \\        ];
        \\        return String.valueOf(address.Default_Address__c) + ':' +
        \\            String.valueOf(address.Undeliverable__c) + ':' +
        \\            String.valueOf(storedAccount.Undeliverable_Address__c);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ContactAddressInsertProbe", "test", "true:true:true");
}

test "E2E: contact update creates managed package address from mailing fields" {
    const source =
        \\public class ContactAddressUpdateProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'HH');
        \\        insert account;
        \\        Contact contact = new Contact(LastName = 'Smith', AccountId = account.Id);
        \\        insert contact;
        \\        Contact updateContact = new Contact(
        \\            Id = contact.Id,
        \\            MailingStreet = '123 Main',
        \\            MailingCity = 'Seattle',
        \\            MailingState = 'WA',
        \\            MailingPostalCode = '98101',
        \\            MailingCountry = 'United States',
        \\            Undeliverable_Address__c = true
        \\        );
        \\        update updateContact;
        \\        Contact storedContact = [
        \\            SELECT Current_Address__c
        \\            FROM Contact
        \\            WHERE Id = :contact.Id
        \\        ];
        \\        Address__c address = [
        \\            SELECT Default_Address__c, Undeliverable__c
        \\            FROM Address__c
        \\            WHERE Id = :storedContact.Current_Address__c
        \\        ];
        \\        Account storedAccount = [
        \\            SELECT Undeliverable_Address__c
        \\            FROM Account
        \\            WHERE Id = :account.Id
        \\        ];
        \\        return String.valueOf(address.Default_Address__c) + ':' +
        \\            String.valueOf(address.Undeliverable__c) + ':' +
        \\            String.valueOf(storedAccount.Undeliverable_Address__c);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "ContactAddressUpdateProbe", "test", "true:true:true");
}

test "E2E: non-default managed package address insert does not sync household billing" {
    const source =
        \\public class NonDefaultAddressInsertProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'HH');
        \\        insert account;
        \\        Address__c address = new Address__c(
        \\            Household_Account__c = account.Id,
        \\            Default_Address__c = false,
        \\            MailingStreet__c = '123 Main',
        \\            MailingCity__c = 'Seattle'
        \\        );
        \\        insert address;
        \\        Account storedAccount = [
        \\            SELECT BillingStreet, BillingCity
        \\            FROM Account
        \\            WHERE Id = :account.Id
        \\        ];
        \\        return String.valueOf(storedAccount.BillingStreet == null) + ':' +
        \\            String.valueOf(storedAccount.BillingCity == null);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NonDefaultAddressInsertProbe", "test", "true:true");
}

test "E2E: declared Double values use decimal division" {
    const source =
        \\public class DeclaredDoubleDivisionProbe {
        \\    public Double percent { get; private set; }
        \\    public DeclaredDoubleDivisionProbe(Double input) {
        \\        percent = input;
        \\    }
        \\    public Double selectedTotal {
        \\        get {
        \\            Double total = 0;
        \\            total += percent / 100 * 200;
        \\            return total;
        \\        }
        \\        private set;
        \\    }
        \\    public static String test() {
        \\        DeclaredDoubleDivisionProbe probe = new DeclaredDoubleDivisionProbe(50);
        \\        return String.valueOf(probe.selectedTotal);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "DeclaredDoubleDivisionProbe", "test", "100.0");
}

test "E2E: managed package refund JSON remaining balance uses decimal value" {
    const source =
        \\public class PackageRefundProbe {
        \\    public class RefundView {
        \\        public Decimal remainingBalance;
        \\    }
        \\    public static String test() {
        \\        return processPaymentInfoResponse('{"remainingBalance":98421}');
        \\    }
        \\    private static String processPaymentInfoResponse(String body) {
        \\        RefundView refundView = new RefundView();
        \\        Map<String, Object> paymentInfo = (Map<String, Object>) JSON.deserializeUntyped(body);
        \\        Decimal remainingBalance = (Decimal) paymentInfo.get('remainingBalance');
        \\        refundView.remainingBalance = remainingBalance / 100;
        \\        return String.valueOf(refundView.remainingBalance);
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackageRefundProbe",
        "test",
        "984.21",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: package allocation fixed amount percent conversion" {
    const source =
        \\public class ManagedAllocationPercentProbe {
        \\    public class Allocation__c {
        \\        public Decimal Amount__c;
        \\        public Decimal Percent__c;
        \\        public Allocation__c(Decimal amount) {
        \\            Amount__c = amount;
        \\        }
        \\    }
        \\    public static String test() {
        \\        return copyFixedAmountAsPercent();
        \\    }
        \\    public static String copyFixedAmountAsPercent() {
        \\        Decimal sourceAmount = 100;
        \\        Allocation__c allocation = new Allocation__c(33);
        \\        Decimal allocationPercent = ((allocation.Amount__c != null) ? allocation.Amount__c : 0) / sourceAmount * 100;
        \\        allocation.Percent__c = allocationPercent;
        \\        return String.valueOf(allocation.Percent__c);
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "ManagedAllocationPercentProbe",
        "test",
        "33.0",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: managed package manage allocations save fills amount from percent" {
    const source =
        \\public class PackageManageAllocationsProbe {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Gift',
        \\            Amount = 8,
        \\            CloseDate = Date.today(),
        \\            StageName = 'Closed Won'
        \\        );
        \\        insert opp;
        \\        return saveClose(opp.Id);
        \\    }
        \\    public static String saveClose(Id oppId) {
        \\        Allocation__c allocation = new Allocation__c(
        \\            Opportunity__c = oppId,
        \\            Percent__c = 50
        \\        );
        \\        insert allocation;
        \\        Allocation__c stored = [
        \\            SELECT Amount__c
        \\            FROM Allocation__c
        \\            WHERE Id = :allocation.Id
        \\        ];
        \\        return String.valueOf(stored.Amount__c);
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackageManageAllocationsProbe",
        "test",
        "4",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: managed package parent amount update resizes percentage allocation" {
    const source =
        \\public class PackageAllocationParentResizeProbe {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Gift',
        \\            Amount = 8,
        \\            CloseDate = Date.today(),
        \\            StageName = 'Closed Won'
        \\        );
        \\        insert opp;
        \\        Allocation__c allocation = new Allocation__c(
        \\            Opportunity__c = opp.Id,
        \\            Percent__c = 50
        \\        );
        \\        insert allocation;
        \\        opp.Amount = 10;
        \\        update opp;
        \\        Allocation__c stored = [
        \\            SELECT Amount__c
        \\            FROM Allocation__c
        \\            WHERE Id = :allocation.Id
        \\        ];
        \\        return String.valueOf(stored.Amount__c);
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackageAllocationParentResizeProbe",
        "test",
        "5",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: managed package default payment allocation fills amount from parent" {
    const source =
        \\public class UTIL_CustomSettingsFacade {
        \\    public static Allocations_Settings__c allocationsSettings;
        \\}
        \\public class PackageDefaultPaymentAllocationProbe {
        \\    public static String test() {
        \\        General_Accounting_Unit__c defaultGau = new General_Accounting_Unit__c(Name = 'Default');
        \\        insert defaultGau;
        \\        UTIL_CustomSettingsFacade.allocationsSettings =
        \\            new Allocations_Settings__c(Default__c = defaultGau.Id);
        \\        npe01__OppPayment__c payment = new npe01__OppPayment__c(
        \\            npe01__Payment_Amount__c = 8
        \\        );
        \\        insert payment;
        \\        Allocation__c allocation = new Allocation__c(
        \\            Payment__c = payment.Id,
        \\            General_Accounting_Unit__c = defaultGau.Id
        \\        );
        \\        insert allocation;
        \\        Allocation__c stored = [
        \\            SELECT Amount__c, Percent__c
        \\            FROM Allocation__c
        \\            WHERE Id = :allocation.Id
        \\        ];
        \\        return String.valueOf(stored.Amount__c) + ':' + String.valueOf(stored.Percent__c);
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackageDefaultPaymentAllocationProbe",
        "test",
        "8:null",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: managed package payment allocations sync to opportunity allocations" {
    const source =
        \\public class UTIL_CustomSettingsFacade {
        \\    public static Allocations_Settings__c allocationsSettings;
        \\}
        \\public class PackagePaymentAllocationSyncProbe {
        \\    public static String test() {
        \\        General_Accounting_Unit__c defaultGau = new General_Accounting_Unit__c(Name = 'Default');
        \\        General_Accounting_Unit__c gauA = new General_Accounting_Unit__c(Name = 'A');
        \\        General_Accounting_Unit__c gauB = new General_Accounting_Unit__c(Name = 'B');
        \\        insert new List<General_Accounting_Unit__c>{ defaultGau, gauA, gauB };
        \\        UTIL_CustomSettingsFacade.allocationsSettings =
        \\            new Allocations_Settings__c(
        \\                Default__c = defaultGau.Id,
        \\                Payment_Allocations_Enabled__c = true
        \\            );
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Gift',
        \\            Amount = 1000,
        \\            CloseDate = Date.today(),
        \\            StageName = 'Open'
        \\        );
        \\        insert opp;
        \\        npe01__OppPayment__c payment = new npe01__OppPayment__c(
        \\            npe01__Opportunity__c = opp.Id,
        \\            npe01__Payment_Amount__c = 1000
        \\        );
        \\        insert payment;
        \\        insert new List<Allocation__c>{
        \\            new Allocation__c(Payment__c = payment.Id, Percent__c = 50, General_Accounting_Unit__c = gauA.Id),
        \\            new Allocation__c(Payment__c = payment.Id, Amount__c = 300, General_Accounting_Unit__c = gauB.Id)
        \\        };
        \\        List<Allocation__c> rows = [
        \\            SELECT Amount__c, General_Accounting_Unit__c, Opportunity__c
        \\            FROM Allocation__c
        \\            WHERE Opportunity__c = :opp.Id
        \\            ORDER BY Amount__c
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' +
        \\            String.valueOf(rows[0].Amount__c) + ':' + String.valueOf(rows[0].General_Accounting_Unit__c == defaultGau.Id) + ':' +
        \\            String.valueOf(rows[1].Amount__c) + ':' + String.valueOf(rows[1].General_Accounting_Unit__c == gauB.Id) + ':' +
        \\            String.valueOf(rows[2].Amount__c) + ':' + String.valueOf(rows[2].General_Accounting_Unit__c == gauA.Id);
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackagePaymentAllocationSyncProbe",
        "test",
        "3:200:true:300:true:500:true",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: managed package opportunity allocations sync to payment allocations" {
    const source =
        \\public class UTIL_CustomSettingsFacade {
        \\    public static Allocations_Settings__c allocationsSettings;
        \\}
        \\public class PackageOpportunityAllocationSyncProbe {
        \\    public static String test() {
        \\        General_Accounting_Unit__c defaultGau = new General_Accounting_Unit__c(Name = 'Default');
        \\        General_Accounting_Unit__c gauA = new General_Accounting_Unit__c(Name = 'A');
        \\        General_Accounting_Unit__c gauB = new General_Accounting_Unit__c(Name = 'B');
        \\        insert new List<General_Accounting_Unit__c>{ defaultGau, gauA, gauB };
        \\        UTIL_CustomSettingsFacade.allocationsSettings =
        \\            new Allocations_Settings__c(
        \\                Default__c = defaultGau.Id,
        \\                Payment_Allocations_Enabled__c = true
        \\            );
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Gift',
        \\            Amount = 1000,
        \\            CloseDate = Date.today(),
        \\            StageName = 'Open'
        \\        );
        \\        insert opp;
        \\        npe01__OppPayment__c payment = new npe01__OppPayment__c(
        \\            npe01__Opportunity__c = opp.Id,
        \\            npe01__Payment_Amount__c = 1000
        \\        );
        \\        insert payment;
        \\        insert new List<Allocation__c>{
        \\            new Allocation__c(Opportunity__c = opp.Id, Percent__c = 50, General_Accounting_Unit__c = gauA.Id),
        \\            new Allocation__c(Opportunity__c = opp.Id, Amount__c = 300, General_Accounting_Unit__c = gauB.Id)
        \\        };
        \\        List<Allocation__c> rows = [
        \\            SELECT Amount__c, General_Accounting_Unit__c, Payment__c
        \\            FROM Allocation__c
        \\            ORDER BY Opportunity__c NULLS LAST, Amount__c, General_Accounting_Unit__c
        \\        ];
        \\        return String.valueOf(rows.size()) + ':' +
        \\            String.valueOf(rows[0].Amount__c) + ':' + String.valueOf(rows[0].General_Accounting_Unit__c == defaultGau.Id) + ':' +
        \\            String.valueOf(rows[1].Amount__c) + ':' + String.valueOf(rows[1].General_Accounting_Unit__c == gauB.Id) + ':' +
        \\            String.valueOf(rows[2].Amount__c) + ':' + String.valueOf(rows[2].General_Accounting_Unit__c == gauA.Id) + ':' +
        \\            String.valueOf(rows[3].Amount__c) + ':' + String.valueOf(rows[3].General_Accounting_Unit__c == defaultGau.Id) + ':' +
        \\            String.valueOf(rows[4].Amount__c) + ':' + String.valueOf(rows[4].General_Accounting_Unit__c == gauB.Id) + ':' +
        \\            String.valueOf(rows[5].Amount__c) + ':' + String.valueOf(rows[5].General_Accounting_Unit__c == gauA.Id) + ':' +
        \\            String.valueOf(rows[3].Payment__c == payment.Id);
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackageOpportunityAllocationSyncProbe",
        "test",
        "6:200:true:300:true:500:true:200:true:300:true:500:true:true",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: managed package parent amount update rejects overallocated records" {
    const source =
        \\public class PackageAllocationParentOverallocatedProbe {
        \\    public static String test() {
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Gift',
        \\            Amount = 8,
        \\            CloseDate = Date.today(),
        \\            StageName = 'Closed Won'
        \\        );
        \\        insert opp;
        \\        insert new List<Allocation__c>{
        \\            new Allocation__c(Opportunity__c = opp.Id, Percent__c = 50),
        \\            new Allocation__c(Opportunity__c = opp.Id, Amount__c = 4)
        \\        };
        \\        opp.Amount = 1;
        \\        try {
        \\            update opp;
        \\            return 'missing';
        \\        } catch (DmlException ex) {
        \\            return 'blocked';
        \\        }
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackageAllocationParentOverallocatedProbe",
        "test",
        "blocked",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: managed package payment parent update ignores stale default allocation remainder" {
    const source =
        \\public class UTIL_CustomSettingsFacade {
        \\    public static Allocations_Settings__c allocationsSettings;
        \\}
        \\public class PackagePaymentParentResizeProbe {
        \\    public static String test() {
        \\        General_Accounting_Unit__c defaultGau = new General_Accounting_Unit__c(Name = 'Default');
        \\        insert defaultGau;
        \\        UTIL_CustomSettingsFacade.allocationsSettings =
        \\            new Allocations_Settings__c(Default__c = defaultGau.Id);
        \\        General_Accounting_Unit__c gau = new General_Accounting_Unit__c(Name = 'Specific');
        \\        insert gau;
        \\        npe01__OppPayment__c payment = new npe01__OppPayment__c(
        \\            npe01__Payment_Amount__c = 8
        \\        );
        \\        insert payment;
        \\        insert new List<Allocation__c>{
        \\            new Allocation__c(Payment__c = payment.Id, Percent__c = 50, General_Accounting_Unit__c = gau.Id),
        \\            new Allocation__c(Payment__c = payment.Id, Amount__c = 4, General_Accounting_Unit__c = gau.Id),
        \\            new Allocation__c(Payment__c = payment.Id, Amount__c = 1, General_Accounting_Unit__c = defaultGau.Id)
        \\        };
        \\        payment.npe01__Payment_Amount__c = 8;
        \\        update payment;
        \\        List<Allocation__c> defaults = [
        \\            SELECT Id
        \\            FROM Allocation__c
        \\            WHERE Payment__c = :payment.Id
        \\            AND General_Accounting_Unit__c = :defaultGau.Id
        \\        ];
        \\        return String.valueOf(defaults.size());
        \\    }
        \\}
    ;
    try expect_entry_string_with_options(
        source,
        "PackagePaymentParentResizeProbe",
        "test",
        "0",
        .{ .fixture_relaxed_exceptions = true },
    );
}

test "E2E: Boolean TRUE and FALSE static fields are Boolean values" {
    const source =
        \\public class BooleanStaticFieldProbe {
        \\    public static String test() {
        \\        return String.valueOf(Boolean.TRUE.equals(true)) + ':' +
        \\            String.valueOf(Boolean.FALSE.equals(false)) + ':' +
        \\            String.valueOf(Boolean.TRUE == true) + ':' +
        \\            String.valueOf(Boolean.FALSE == false);
        \\    }
        \\}
    ;
    try expect_entry_string(source, "BooleanStaticFieldProbe", "test", "true:true:true:true");
}

test "E2E: managed package contact with current address inherits address household account" {
    const source =
        \\public class PackageCurrentAddressAccountProbe {
        \\    public static String test() {
        \\        Account account = new Account(Name = 'Organization');
        \\        insert account;
        \\        Address__c address = new Address__c(
        \\            Household_Account__c = account.Id,
        \\            MailingStreet__c = '1 Main',
        \\            MailingCity__c = 'Seattle',
        \\            MailingState__c = 'WA',
        \\            MailingPostalCode__c = '98101',
        \\            MailingCountry__c = 'United States'
        \\        );
        \\        insert address;
        \\        Contact contact = new Contact(
        \\            LastName = 'Override',
        \\            Current_Address__c = address.Id,
        \\            is_Address_Override__c = true
        \\        );
        \\        insert contact;
        \\        return contact.AccountId == account.Id ? 'linked' : String.valueOf(contact.AccountId);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackageCurrentAddressAccountProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("linked", result.value.string);
}

test "E2E: null SObject Id field keeps Id overload in builder chains" {
    const source =
        \\public class NullSObjectIdOverloadProbe {
        \\    public class Builder {
        \\        public String chosen = '';
        \\        public Builder withAccount(String name) {
        \\            chosen += 'String>';
        \\            return withAccount(new Account(Name = name));
        \\        }
        \\        public Builder withAccount(Account account) {
        \\            chosen += 'Account>';
        \\            return withAccount(account.Id);
        \\        }
        \\        public Builder withAccount(Id accountId) {
        \\            chosen += 'Id>';
        \\            return this;
        \\        }
        \\    }
        \\    public static String test() {
        \\        Account account = new Account(Name = null);
        \\        Builder builder = new Builder().withAccount(account);
        \\        return String.valueOf(builder == null) + ':' + builder.chosen;
        \\    }
        \\}
    ;
    try expect_entry_string(source, "NullSObjectIdOverloadProbe", "test", "false:Account>Id>");
}

test "E2E: managed package recurring donation defaults planned installments to one" {
    const source =
        \\public class PackageRecurringDonationInstallmentsDefaultProbe {
        \\    public static String test() {
        \\        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
        \\            Name = 'RD',
        \\            RecurringType__c = 'Fixed'
        \\        );
        \\        insert rd;
        \\        return String.valueOf(rd.npe03__Installments__c);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackageRecurringDonationInstallmentsDefaultProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1", result.value.string);
}

test "E2E: package async recurring donation creates next Opportunity" {
    const source =
        \\public class RD2_OpportunityEvaluationService {}
        \\public class RD2_ScheduleService {
        \\    public static Date currentDate;
        \\}
        \\public class PackageAsyncRecurringDonationOpportunityProbe {
        \\    public static String test() {
        \\        insert new npe03__Recurring_Donations_Settings__c(
        \\            IsRecurringDonations2Enabled__c = true,
        \\            InstallmentOppFirstCreateMode__c = 'ASynchronous',
        \\            InstallmentOppStageName__c = 'Pledged'
        \\        );
        \\        RD2_ScheduleService.currentDate = Date.newInstance(2019, 9, 16);
        \\        Test.startTest();
        \\        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
        \\            Name = 'RD',
        \\            npe03__Amount__c = 20,
        \\            npe03__Date_Established__c = Date.newInstance(2019, 9, 15),
        \\            StartDate__c = Date.newInstance(2019, 9, 15),
        \\            Day_Of_Month__c = '17',
        \\            npe03__Next_Payment_Date__c = null
        \\        );
        \\        insert rd;
        \\        rd.RecurringType__c = 'Open';
        \\        update rd;
        \\        Integer jobsBeforeStop = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];
        \\        Test.stopTest();
        \\        Opportunity opp = [
        \\            SELECT CloseDate, StageName, npe03__Recurring_Donation__c
        \\            FROM Opportunity
        \\            WHERE npe03__Recurring_Donation__c = :rd.Id
        \\            LIMIT 1
        \\        ];
        \\        AsyncApexJob job = [
        \\            SELECT Status, NumberOfErrors
        \\            FROM AsyncApexJob
        \\            WHERE JobType = 'Queueable'
        \\            LIMIT 1
        \\        ];
        \\        return String.valueOf(jobsBeforeStop) + ':' +
        \\            String.valueOf(opp.CloseDate) + ':' +
        \\            opp.StageName + ':' +
        \\            String.valueOf(opp.npe03__Recurring_Donation__c == rd.Id) + ':' +
        \\            job.Status + ':' +
        \\            String.valueOf(job.NumberOfErrors);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackageAsyncRecurringDonationOpportunityProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1:2019-09-17:Pledged:true:Completed:0", result.value.string);
}

test "E2E: managed package TDTM disabled skips recurring donation rollup side effects" {
    const source =
        \\public class TDTM_TriggerHandler {
        \\    public static Boolean disableTDTM = false;
        \\}
        \\public class PackageTdtmDisabledRecurringDonationRollupProbe {
        \\    public static String test() {
        \\        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
        \\            Name = 'RD',
        \\            npe03__Amount__c = 10,
        \\            npe03__Date_Established__c = Date.newInstance(2020, 1, 1),
        \\            StartDate__c = Date.newInstance(2020, 1, 1)
        \\        );
        \\        insert rd;
        \\        Opportunity opp = new Opportunity(
        \\            Name = 'Gift',
        \\            Amount = 10,
        \\            CloseDate = Date.newInstance(2020, 1, 1),
        \\            StageName = 'Open',
        \\            npe03__Recurring_Donation__c = rd.Id
        \\        );
        \\        insert opp;
        \\        rd.npe03__Paid_Amount__c = null;
        \\        update rd;
        \\        TDTM_TriggerHandler.disableTDTM = true;
        \\        opp.StageName = 'Closed Won';
        \\        update opp;
        \\        TDTM_TriggerHandler.disableTDTM = false;
        \\        rd = [
        \\            SELECT npe03__Paid_Amount__c
        \\            FROM npe03__Recurring_Donation__c
        \\            WHERE Id = :rd.Id
        \\        ];
        \\        return String.valueOf(rd.npe03__Paid_Amount__c);
        \\    }
        \\}
    ;
    const result = try run(std.testing.allocator, std.testing.io, source, .{
        .entry_class = "PackageTdtmDisabledRecurringDonationRollupProbe",
        .entry_method = "test",
        .fixture_relaxed_exceptions = true,
    });
    defer result.deinit();

    try std.testing.expect(result.value == .null_val);
}
