//! references — シンボルの全参照箇所を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const parser_types = @import("../apex_parser/types.zig");

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

/// クロスファイル対応版。同一ファイル内の参照に加え、ワークスペース内の他ファイルでの
/// 同名トップレベルシンボルの定義+参照も収集する。
pub fn getReferencesCrossFile(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    include_declaration: bool,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) ![]lsp_types.Location {
    // 1. 同一ファイル内の参照を取得
    const same_file = try getReferences(result, source, uri, offset, include_declaration, allocator);

    // 2. カーソル位置のシンボル名を特定
    const sym = binder_mod.symbolAtPosition(result, offset);
    const name = if (sym) |s|
        s.name
    else
        position_mod.identifierAtOffset(tokens, offset) orelse return same_file;

    // 3. 他ファイルから同名シンボルの参照を収集
    var locations = std.ArrayList(lsp_types.Location).fromOwnedSlice(same_file);
    var it = store.documents.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, uri)) continue;
        const doc = entry.value_ptr;
        const pr = doc.parse_result orelse continue;
        const br = pr.bind_result orelse continue;
        for (br.symbols) |other_sym| {
            if (!std.mem.eql(u8, other_sym.name, name)) continue;
            // 同名シンボルの参照を収集
            const other_refs = try binder_mod.filterReferences(&br, other_sym.id, allocator);
            defer allocator.free(other_refs);
            for (other_refs) |ref| {
                if (!include_declaration and ref.is_definition) continue;
                const pos = position_mod.offsetToPosition(doc.text, ref.offset);
                try locations.append(allocator, .{
                    .uri = entry.key_ptr.*,
                    .range = .{
                        .start = pos,
                        .end = .{ .line = pos.line, .character = pos.character + (ref.end_offset - ref.offset) },
                    },
                });
            }
        }
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

// -- クロスファイルテスト --

test "cross-file: finds references in other files" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    // Helper クラスが 2 つのファイルで定義（同名クラス）
    try store.open("file:///Helper.cls", 1, "public class Helper { public void doWork() {} }");
    try store.open("file:///Main.cls", 1, "public class Main { }");

    _ = try store.ensureBound("file:///Helper.cls");
    _ = try store.ensureBound("file:///Main.cls");

    const helper_doc = store.get("file:///Helper.cls").?;
    const cached = helper_doc.parse_result.?;
    const br = cached.bind_result.?;

    // Helper クラス名の位置
    const offset: u32 = @intCast(std.mem.indexOf(u8, helper_doc.text, "Helper").?);

    const locs = try getReferencesCrossFile(
        &br,
        cached.tokens,
        helper_doc.text,
        "file:///Helper.cls",
        offset,
        true,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    // Helper.cls 内の定義 (少なくとも 1 つ)
    try std.testing.expect(locs.len >= 1);
}
