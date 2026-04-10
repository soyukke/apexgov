//! definition — カーソル位置のシンボルの定義位置を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");

pub fn getDefinition(result: *const binder_mod.BindResult, source: []const u8, uri: []const u8, offset: u32) ?lsp_types.Location {
    const sym = binder_mod.symbolAtPosition(result, offset) orelse return null;
    const pos = position_mod.offsetToPosition(source, sym.loc.offset);
    return .{
        .uri = uri,
        .range = .{
            .start = pos,
            .end = .{ .line = pos.line, .character = pos.character + @as(u32, @intCast(sym.name.len)) },
        },
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

fn defAt(source: []const u8, offset: u32) !?lsp_types.Location {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);
    return getDefinition(&br, source, "file:///test.cls", offset);
}

test "variable use jumps to declaration" {
    const source = "public class Foo { public void run() { Integer x = 1; Integer y = x; } }";
    // 'x' の使用位置（'= x;' の x）を探す
    const use_offset = std.mem.lastIndexOf(u8, source, "x;").?;
    const loc = try defAt(source, @intCast(use_offset));
    try std.testing.expect(loc != null);
}

test "unknown symbol returns null" {
    const source = "public class Foo {}";
    const loc = try defAt(source, 6); // space
    try std.testing.expect(loc == null);
}
