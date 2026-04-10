//! document_highlight — 同一シンボルの出現箇所をハイライトする。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");

pub fn getHighlights(
    result: *const binder_mod.BindResult,
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
) ![]lsp_types.DocumentHighlight {
    const sym = binder_mod.symbolAtPosition(result, offset) orelse return &.{};
    const refs = try binder_mod.filterReferences(result, sym.id, allocator);
    defer allocator.free(refs);

    var highlights: std.ArrayList(lsp_types.DocumentHighlight) = .empty;
    for (refs) |ref| {
        const start = position_mod.offsetToPosition(source, ref.offset);
        const end = position_mod.offsetToPosition(source, ref.end_offset);
        try highlights.append(allocator, .{
            .range = .{ .start = start, .end = end },
            .kind = if (ref.is_definition) .write else .read,
        });
    }
    return highlights.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

test "highlights all occurrences" {
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

    const hl = try getHighlights(&br, source, sym.loc.offset, alloc);
    try std.testing.expectEqual(@as(usize, 2), hl.len);
}

test "definition marked as write" {
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

    const hl = try getHighlights(&br, source, sym.loc.offset, alloc);
    // 最初の highlight は定義（write）
    var has_write = false;
    for (hl) |h| {
        if (h.kind == .write) has_write = true;
    }
    try std.testing.expect(has_write);
}

test "whitespace returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const hl = try getHighlights(&br, source, 6, alloc);
    try std.testing.expectEqual(@as(usize, 0), hl.len);
}
