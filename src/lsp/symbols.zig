//! symbols — AST から LSP DocumentSymbol を生成する。

const std = @import("std");
const types = @import("types.zig");
const ast = @import("../apex_parser/ast.zig");
const parser_types = @import("../apex_parser/types.zig");
const position_mod = @import("position.zig");

const DocumentSymbol = types.DocumentSymbol;
const SymbolKind = types.SymbolKind;
const Range = types.Range;
const Position = types.Position;
const SourceLoc = parser_types.SourceLoc;

/// AST 宣言リストから DocumentSymbol 配列を生成する。
pub fn collect_symbols(decls: []const ast.Decl, source: []const u8, allocator: std.mem.Allocator) ![]DocumentSymbol {
    var result: std.ArrayList(DocumentSymbol) = .empty;
    for (decls) |decl| {
        try collect_decl(decl, source, allocator, &result);
    }
    return result.toOwnedSlice(allocator);
}

fn collect_class_decl(cd: anytype, source: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(DocumentSymbol)) anyerror!void {
    var children: std.ArrayList(DocumentSymbol) = .empty;
    for (cd.members) |member| {
        try collect_decl(member, source, allocator, &children);
    }
    try out.append(allocator, .{
        .name = cd.name,
        .kind = .class,
        .range = position_mod.loc_to_range(cd.loc, source),
        .selectionRange = position_mod.loc_to_range(cd.loc, source),
        .children = try children.toOwnedSlice(allocator),
    });
}

fn collect_enum_decl(ed: anytype, source: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(DocumentSymbol)) !void {
    var children: std.ArrayList(DocumentSymbol) = .empty;
    for (ed.values) |v| {
        try children.append(allocator, .{
            .name = v,
            .kind = .enum_member,
            .range = .{},
            .selectionRange = .{},
        });
    }
    try out.append(allocator, .{
        .name = ed.name,
        .kind = .@"enum",
        .range = position_mod.loc_to_range(ed.loc, source),
        .selectionRange = position_mod.loc_to_range(ed.loc, source),
        .children = try children.toOwnedSlice(allocator),
    });
}

fn collect_decl(decl: ast.Decl, source: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(DocumentSymbol)) !void {
    switch (decl) {
        .class_decl => |cd| try collect_class_decl(cd, source, allocator, out),
        .interface_decl => |id| {
            try out.append(allocator, .{
                .name = id.name,
                .kind = .interface,
                .range = position_mod.loc_to_range(id.loc, source),
                .selectionRange = position_mod.loc_to_range(id.loc, source),
            });
        },
        .enum_decl => |ed| try collect_enum_decl(ed, source, allocator, out),
        .method_decl => |md| {
            try out.append(allocator, .{
                .name = md.name,
                .kind = .method,
                .range = position_mod.loc_to_range(md.loc, source),
                .selectionRange = position_mod.loc_to_range(md.loc, source),
            });
        },
        .constructor_decl => |cd| {
            _ = cd;
            try out.append(allocator, .{
                .name = "<constructor>",
                .kind = .constructor,
            });
        },
        .field_decl => |fd| {
            const kind: SymbolKind = if (fd.modifiers.is_static and fd.modifiers.is_final) .constant else .field;
            try out.append(allocator, .{
                .name = fd.name,
                .kind = kind,
                .range = position_mod.loc_to_range(fd.loc, source),
                .selectionRange = position_mod.loc_to_range(fd.loc, source),
            });
        },
        .trigger_decl => |td| {
            try out.append(allocator, .{
                .name = td.name,
                .kind = .event,
                .range = position_mod.loc_to_range(td.loc, source),
                .selectionRange = position_mod.loc_to_range(td.loc, source),
            });
        },
        .static_init => {},
    }
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

/// テスト用: arena を返すことでライフタイム管理を呼び出し側に移す。
const TestResult = struct {
    symbols: []DocumentSymbol,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

fn parse_and_collect(source: []const u8) !TestResult {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();

    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const syms = try collect_symbols(decls, source, alloc);
    return .{ .symbols = syms, .arena = arena };
}

test "class with methods → class symbol with method children" {
    const source = "public class AccountService { public void process() {} private Integer count() { return 0; } }";
    var r = try parse_and_collect(source);
    defer r.deinit();

    const symbols = r.symbols;

    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqualStrings("AccountService", symbols[0].name);
    try std.testing.expectEqual(SymbolKind.class, symbols[0].kind);
    try std.testing.expectEqual(@as(usize, 2), symbols[0].children.len);
    try std.testing.expectEqualStrings("process", symbols[0].children[0].name);
    try std.testing.expectEqual(SymbolKind.method, symbols[0].children[0].kind);
    try std.testing.expectEqualStrings("count", symbols[0].children[1].name);
}

test "class with fields → field symbols" {
    const source = "public class Foo { public String name; private static final Integer MAX = 100; }";
    var r = try parse_and_collect(source);
    defer r.deinit();

    const children = r.symbols[0].children;

    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings("name", children[0].name);
    try std.testing.expectEqual(SymbolKind.field, children[0].kind);
    try std.testing.expectEqualStrings("MAX", children[1].name);
    try std.testing.expectEqual(SymbolKind.constant, children[1].kind);
}

test "enum → enum symbol with enum_member children" {
    const source = "public enum Season { SPRING, SUMMER, FALL, WINTER }";
    var r = try parse_and_collect(source);
    defer r.deinit();

    const symbols = r.symbols;

    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqualStrings("Season", symbols[0].name);
    try std.testing.expectEqual(SymbolKind.@"enum", symbols[0].kind);
    try std.testing.expectEqual(@as(usize, 4), symbols[0].children.len);
    try std.testing.expectEqualStrings("SPRING", symbols[0].children[0].name);
    try std.testing.expectEqual(SymbolKind.enum_member, symbols[0].children[0].kind);
}

test "interface → interface symbol" {
    const source = "public interface Runnable { void run(); }";
    var r = try parse_and_collect(source);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.symbols.len);
    try std.testing.expectEqualStrings("Runnable", r.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.interface, r.symbols[0].kind);
}

test "trigger → event symbol" {
    const source = "trigger AccountTrigger on Account (before insert, after update) { }";
    var r = try parse_and_collect(source);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.symbols.len);
    try std.testing.expectEqualStrings("AccountTrigger", r.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.event, r.symbols[0].kind);
}

test "position mapping: class on line 1" {
    const source = "public class Foo {}";
    var r = try parse_and_collect(source);
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 0), r.symbols[0].range.start.line);
}
