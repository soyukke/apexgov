//! code_lens — @IsTest / testMethod メソッドに Run Test CodeLens を生成する。

const std = @import("std");
const lsp_types = @import("types.zig");
const ast = @import("../apex_parser/ast.zig");
const position_mod = @import("position.zig");

const CodeLens = lsp_types.CodeLens;
const Command = lsp_types.Command;
const Range = lsp_types.Range;

/// テストメソッドかどうかを判定する。
/// - @IsTest / @isTest / @test アノテーション（case-insensitive）
/// - @isTest(SeeAllData=true) 等パラメータ付き
/// - testMethod 修飾子
fn is_test_method(md: *const ast.MethodDecl) bool {
    if (md.modifiers.is_test_method) return true;
    for (md.annotations) |ann| {
        if (std.ascii.eqlIgnoreCase(ann, "@isTest") or
            std.ascii.eqlIgnoreCase(ann, "@IsTest") or
            std.ascii.eqlIgnoreCase(ann, "@test"))
        {
            return true;
        }
        if (std.ascii.startsWithIgnoreCase(ann, "@isTest(") or
            std.ascii.startsWithIgnoreCase(ann, "@test("))
        {
            return true;
        }
    }
    return false;
}

/// AST 宣言リストから CodeLens 配列を生成する。
pub fn get_code_lenses(
    decls: []const ast.Decl,
    source: []const u8,
    uri: []const u8,
    allocator: std.mem.Allocator,
) ![]CodeLens {
    var result: std.ArrayList(CodeLens) = .empty;

    for (decls) |decl| {
        switch (decl) {
            .class_decl => |cd| {
                var has_test = false;

                for (cd.members) |member| {
                    switch (member) {
                        .method_decl => |md| {
                            if (is_test_method(md)) {
                                has_test = true;
                                const args = try allocator.alloc([]const u8, 3);
                                args[0] = uri;
                                args[1] = cd.name;
                                args[2] = md.name;
                                try result.append(allocator, .{
                                    .range = position_mod.loc_to_range(md.loc, source),
                                    .command = .{
                                        .title = "\u{25B6} Run Test (saved)",
                                        .command = "apexgov.runTest",
                                        .arguments = args,
                                    },
                                });
                            }
                        },
                        else => {},
                    }
                }

                if (has_test) {
                    const args = try allocator.alloc([]const u8, 2);
                    args[0] = uri;
                    args[1] = cd.name;
                    try result.append(allocator, .{
                        .range = position_mod.loc_to_range(cd.loc, source),
                        .command = .{
                            .title = "\u{25B6} Run All Tests (saved)",
                            .command = "apexgov.runAllTests",
                            .arguments = args,
                        },
                    });
                }
            },
            else => {},
        }
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

const TestResult = struct {
    lenses: []CodeLens,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

fn parse_and_get_lenses(source: []const u8) !TestResult {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const lenses = try get_code_lenses(decls, source, "file:///test.cls", alloc);
    return .{ .lenses = lenses, .arena = arena };
}

test "@IsTest メソッドに Run Test レンズ" {
    const source =
        \\@IsTest
        \\private class MyTest {
        \\    @IsTest
        \\    static void shouldPass() {
        \\        System.assert(true);
        \\    }
        \\}
    ;
    var r = try parse_and_get_lenses(source);
    defer r.deinit();

    // 1 per-method lens + 1 class-level lens = 2
    try std.testing.expectEqual(@as(usize, 2), r.lenses.len);

    // Per-method lens
    const method_lens = r.lenses[0];
    try std.testing.expectEqualStrings("apexgov.runTest", method_lens.command.?.command);
    try std.testing.expectEqualStrings("\u{25B6} Run Test (saved)", method_lens.command.?.title);
    const args = method_lens.command.?.arguments.?;
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("file:///test.cls", args[0]);
    try std.testing.expectEqualStrings("MyTest", args[1]);
    try std.testing.expectEqualStrings("shouldPass", args[2]);
}

test "テストなしクラスはレンズなし" {
    const source =
        \\public class AccountService {
        \\    public void process() {}
        \\}
    ;
    var r = try parse_and_get_lenses(source);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.lenses.len);
}

test "クラスレベル Run All Tests レンズ" {
    const source =
        \\@IsTest
        \\private class MyTest {
        \\    @IsTest
        \\    static void test1() {}
        \\    @IsTest
        \\    static void test2() {}
        \\}
    ;
    var r = try parse_and_get_lenses(source);
    defer r.deinit();

    // 2 per-method + 1 class-level = 3
    try std.testing.expectEqual(@as(usize, 3), r.lenses.len);

    // Last one should be Run All Tests
    const class_lens = r.lenses[2];
    try std.testing.expectEqualStrings("apexgov.runAllTests", class_lens.command.?.command);
    try std.testing.expectEqualStrings(
        "\u{25B6} Run All Tests (saved)",
        class_lens.command.?.title,
    );
    const args = class_lens.command.?.arguments.?;
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("MyTest", args[1]);
}

test "大文字小文字不問" {
    const source =
        \\@istest
        \\private class MyTest {
        \\    @istest
        \\    static void test1() {}
        \\    @ISTEST
        \\    static void test2() {}
        \\}
    ;
    var r = try parse_and_get_lenses(source);
    defer r.deinit();

    // 2 per-method + 1 class-level = 3
    try std.testing.expectEqual(@as(usize, 3), r.lenses.len);
}

test "パラメータ付き @isTest(SeeAllData=true)" {
    const source =
        \\@IsTest
        \\private class MyTest {
        \\    @IsTest(SeeAllData=true)
        \\    static void testWithData() {}
        \\}
    ;
    var r = try parse_and_get_lenses(source);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 2), r.lenses.len);
    try std.testing.expectEqualStrings("testWithData", r.lenses[0].command.?.arguments.?[2]);
}

test "testMethod 修飾子" {
    const source =
        \\@IsTest
        \\public class MyTest {
        \\    static testMethod void myTest() {
        \\        System.assert(true);
        \\    }
        \\}
    ;
    var r = try parse_and_get_lenses(source);
    defer r.deinit();

    // 1 per-method + 1 class-level = 2
    try std.testing.expectEqual(@as(usize, 2), r.lenses.len);
    try std.testing.expectEqualStrings("apexgov.runTest", r.lenses[0].command.?.command);
    try std.testing.expectEqualStrings("myTest", r.lenses[0].command.?.arguments.?[2]);
}

test "複数クラス" {
    const source =
        \\@IsTest
        \\private class TestA {
        \\    @IsTest
        \\    static void testA1() {}
        \\}
        \\@IsTest
        \\private class TestB {
        \\    @IsTest
        \\    static void testB1() {}
        \\    @IsTest
        \\    static void testB2() {}
        \\}
    ;
    var r = try parse_and_get_lenses(source);
    defer r.deinit();

    // TestA: 1 method + 1 class = 2
    // TestB: 2 methods + 1 class = 3
    // Total = 5
    try std.testing.expectEqual(@as(usize, 5), r.lenses.len);
}
