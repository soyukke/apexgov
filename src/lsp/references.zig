//! references — シンボルの全参照箇所を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");

pub fn getReferences(
    result: *const binder_mod.BindResult,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    include_declaration: bool,
    allocator: std.mem.Allocator,
) ![]lsp_types.Location {
    const sym = binder_mod.symbolAtPosition(result, offset) orelse return &.{};
    const refs = try binder_mod.filterReferences(result, sym.id, allocator);
    defer allocator.free(refs);

    var locations: std.ArrayList(lsp_types.Location) = .empty;
    for (refs) |ref| {
        if (!include_declaration and ref.is_definition) continue;
        const pos = position_mod.offsetToPosition(source, ref.offset);
        try locations.append(allocator, .{
            .uri = uri,
            .range = .{
                .start = pos,
                .end = .{ .line = pos.line, .character = pos.character + (ref.end_offset - ref.offset) },
            },
        });
    }
    return locations.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

test "finds all uses of local variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "public class Foo { public void run() { Integer x = 1; Integer y = x; } }";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    // 'x' の定義位置で検索
    const sym = blk: {
        for (br.symbols) |*s| {
            if (std.mem.eql(u8, s.name, "x")) break :blk s;
        }
        break :blk null;
    } orelse unreachable;

    const locs = try getReferences(&br, source, "file:///t.cls", sym.loc.offset, true, alloc);
    try std.testing.expectEqual(@as(usize, 2), locs.len); // definition + usage
}

test "include_declaration=false excludes definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "public class Foo { public void run() { Integer x = 1; Integer y = x; } }";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const sym = blk: {
        for (br.symbols) |*s| {
            if (std.mem.eql(u8, s.name, "x")) break :blk s;
        }
        break :blk null;
    } orelse unreachable;

    const locs = try getReferences(&br, source, "file:///t.cls", sym.loc.offset, false, alloc);
    try std.testing.expectEqual(@as(usize, 1), locs.len); // usage only
}
