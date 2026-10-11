//! document_highlight — 同一シンボルの出現箇所をハイライトする。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const references_mod = @import("references.zig");
const definition_mod = @import("definition.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const parser_types = @import("../apex_parser/types.zig");

pub fn get_highlights(
    result: *const binder_mod.BindResult,
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
) ![]lsp_types.DocumentHighlight {
    const sym = binder_mod.symbol_at_position(result, offset) orelse return &.{};
    const refs = try binder_mod.filter_references(result, sym.id, allocator);
    defer allocator.free(refs);

    var highlights: std.ArrayList(lsp_types.DocumentHighlight) = .empty;
    for (refs) |ref| {
        const start = position_mod.offset_to_position(source, ref.offset);
        const end = position_mod.offset_to_position(source, ref.end_offset);
        try highlights.append(allocator, .{
            .range = .{ .start = start, .end = end },
            .kind = if (ref.is_definition) .write else .read,
        });
    }
    return highlights.toOwnedSlice(allocator);
}

pub fn get_highlights_cross_file(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) ![]lsp_types.DocumentHighlight {
    const refs = try references_mod.get_references_cross_file(
        result,
        tokens,
        source,
        uri,
        offset,
        true,
        store,
        allocator,
    );
    defer allocator.free(refs);

    if (refs.len == 0) return &.{};

    const def = definition_mod.get_definition_cross_file(
        result,
        tokens,
        source,
        uri,
        offset,
        store,
    );

    var highlights: std.ArrayList(lsp_types.DocumentHighlight) = .empty;
    for (refs) |loc| {
        if (!std.mem.eql(u8, loc.uri, uri)) continue;
        try highlights.append(allocator, .{
            .range = loc.range,
            .kind = if (def != null and same_location(loc, def.?)) .write else .read,
        });
    }
    return highlights.toOwnedSlice(allocator);
}

fn same_location(a: lsp_types.Location, b: lsp_types.Location) bool {
    return std.mem.eql(u8, a.uri, b.uri) and
        a.range.start.line == b.range.start.line and
        a.range.start.character == b.range.start.character and
        a.range.end.line == b.range.end.line and
        a.range.end.character == b.range.end.character;
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

    const hl = try get_highlights(&br, source, sym.loc.offset, alloc);
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

    const hl = try get_highlights(&br, source, sym.loc.offset, alloc);
    // 最初の highlight は定義（write）
    var has_write = false;
    for (hl) |h| {
        if (h.kind == .write) has_write = true;
    }
    try std.testing.expect(has_write);
}

test "cross-file highlights later same-class method calls in current document" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class Foo {
        \\    public void run() {
        \\        helper('a');
        \\        this.helper('b');
        \\    }
        \\    private static Integer helper(String label) { return 1; }
        \\}
    ;
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "helper('a')").?);
    const highlights = try get_highlights_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        offset,
        &store,
        arena.allocator(),
    );

    try std.testing.expectEqual(@as(usize, 3), highlights.len);
    var has_write = false;
    for (highlights) |h| {
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

    const hl = try get_highlights(&br, source, 6, alloc);
    try std.testing.expectEqual(@as(usize, 0), hl.len);
}
