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

// 型の再エクスポート
pub const Value = types.Value;
pub const RuntimeError = types.RuntimeError;

pub const Options = struct {
    entry_class: []const u8 = "",
    entry_method: []const u8 = "",
    args: []const Value = &.{},
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1. .cls ファイルを収集
    var files: std.ArrayListUnmanaged(SourceFile) = .empty;
    for (paths) |path| {
        try collectClsFiles(alloc, path, &files);
    }

    try writer.print("interpret: loaded {d} Apex source file(s)\n", .{files.items.len});

    // 2. 全ファイルをパース
    var eval = try evaluator.Evaluator.init(alloc);
    var parse_errors: u32 = 0;

    for (files.items) |file| {
        const tokens = lexer.tokenize(file.content, alloc) catch {
            parse_errors += 1;
            continue;
        };
        const decls = parser.parse(tokens, alloc) catch {
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
            const class_name = basename[0 .. basename.len - 4];
            eval.registerClassSource(class_name, file.content) catch {};
        }
    }

    try writer.print("interpret: registered {d} class(es), {d} trigger(s), {d} parse error(s)\n", .{ eval.classes.count(), eval.triggers.count(), parse_errors });

    // Run static initializer blocks after all classes are registered
    eval.runStaticInits();

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
            if (has_static_fields) try classes_with_statics.append(alloc, cd);
            if (has_static_init) try classes_with_static_inits.append(alloc, cd);
        }
    }

    // 3. @isTest メソッドを発見・実行
    var suite = TestSuiteResult{};
    var class_iter = eval.classes.iterator();
    while (class_iter.next()) |entry| {
        const class_name = entry.key_ptr.*;
        const class_decl = entry.value_ptr.*;

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

                    suite.total += 1;

                    // Reset store and assertions before each test
                    eval.resetForTest();
                    // Check for @isTest(SeeAllData=true) annotation
                    eval.see_all_data = false;
                    for (md.annotations) |ann| {
                        if (std.ascii.indexOfIgnoreCase(ann, "seealldata") != null and
                            std.ascii.indexOfIgnoreCase(ann, "true") != null)
                        {
                            eval.see_all_data = true;
                            break;
                        }
                    }
                    // Re-init static fields for classes that have them
                    for (classes_with_statics.items) |cd| {
                        eval.reInitClassStaticFields(cd);
                    }
                    // Run static init blocks for classes that have them
                    for (classes_with_static_inits.items) |cd| {
                        eval.runClassStaticInits(cd);
                    }

                    // Run @TestSetup if exists
                    if (test_setup_method) |setup| {
                        _ = eval.callMethod(class_name, setup.name, &.{}) catch {};
                    }

                    const result = eval.callMethod(class_name, md.name, &.{});
                    if (result) |_| {
                        // Check assertion failures
                        if (eval.assertion_failure) |msg| {
                            suite.failed += 1;
                            try suite.results.append(alloc, .{
                                .class_name = class_name,
                                .method_name = md.name,
                                .passed = false,
                                .failure_message = msg,
                            });
                            try writer.print("[FAIL] {s}#{s}: {s}\n", .{ class_name, md.name, msg });
                        } else {
                            suite.passed += 1;
                            try suite.results.append(alloc, .{
                                .class_name = class_name,
                                .method_name = md.name,
                                .passed = true,
                            });
                            try writer.print("[PASS] {s}#{s}\n", .{ class_name, md.name });
                        }
                    } else |err| {
                        suite.errors += 1;
                        // Include pending exception message if available
                        const exc_detail = if (eval.pending_exception) |pe| blk: {
                            if (pe == .object) {
                                if (pe.object.fields.get("message")) |msg| {
                                    if (msg == .string) break :blk msg.string;
                                }
                            }
                            break :blk "";
                        } else "";
                        const err_msg = if (exc_detail.len > 0)
                            try std.fmt.allocPrint(alloc, "{s}: {s}", .{ @errorName(err), exc_detail })
                        else
                            try std.fmt.allocPrint(alloc, "{s}", .{@errorName(err)});
                        try suite.results.append(alloc, .{
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

fn isTestMethod(md: *ast.MethodDecl) bool {
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
