//! rename — シンボルの一括リネーム。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");

pub fn get_rename_edits(
    result: *const binder_mod.BindResult,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    new_name: []const u8,
    allocator: std.mem.Allocator,
) !?lsp_types.WorkspaceEdit {
    const sym = binder_mod.symbol_at_position(result, offset) orelse return null;

    // キーワードや非リネーム可能なシンボルはスキップ
    if (sym.kind == .class or sym.kind == .interface or sym.kind == .enum_type or sym.kind == .trigger) {
        // トップレベル型のリネームも許可
    }

    const refs = try binder_mod.filter_references(result, sym.id, allocator);
    defer allocator.free(refs);

    var edits: std.ArrayList(lsp_types.TextEdit) = .empty;
    for (refs) |ref| {
        const start = position_mod.offset_to_position(source, ref.offset);
        const end = position_mod.offset_to_position(source, ref.end_offset);
        try edits.append(allocator, .{
            .range = .{ .start = start, .end = end },
            .newText = new_name,
        });
    }

    return .{
        .changes = .{
            .uri = uri,
            .edits = try edits.toOwnedSlice(allocator),
        },
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

test "renames variable at all sites" {
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

    const edit = try get_rename_edits(
        &br,
        source,
        "file:///t.cls",
        sym.loc.offset,
        "newName",
        alloc,
    );
    try std.testing.expect(edit != null);
    try std.testing.expect(edit.?.changes != null);
    try std.testing.expectEqual(@as(usize, 2), edit.?.changes.?.edits.len);
}

test "unknown position returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const edit = try get_rename_edits(&br, source, "file:///t.cls", 6, "x", alloc);
    try std.testing.expect(edit == null);
}
