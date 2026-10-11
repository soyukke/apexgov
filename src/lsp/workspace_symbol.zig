//! workspace_symbol — ワークスペース全体のシンボル検索。

const std = @import("std");
const lsp_types = @import("types.zig");
const ast = @import("../apex_parser/ast.zig");
const parser_types = @import("../apex_parser/types.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const position_mod = @import("position.zig");

pub const WorkspaceSymbol = struct {
    name: []const u8,
    kind: lsp_types.SymbolKind,
    uri: []const u8,
    range: lsp_types.Range,
};

/// 全ドキュメントからシンボルを収集し、query でフィルタする。
pub fn search(
    store: *DocumentStore,
    query: []const u8,
    allocator: std.mem.Allocator,
) ![]WorkspaceSymbol {
    var results: std.ArrayList(WorkspaceSymbol) = .empty;

    var it = store.documents.iterator();
    while (it.next()) |entry| {
        const doc = entry.value_ptr;
        const cached = try store.ensure_parsed(doc.uri) orelse continue;
        try collect_from_decls(cached.decls, doc.uri, doc.text, query, allocator, &results);
    }

    return results.toOwnedSlice(allocator);
}

/// collect_from_decls が再利用する呼び出しコンテキスト。
const CollectCtx = struct {
    uri: []const u8,
    source: []const u8,
    query: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(WorkspaceSymbol),
};

fn emit_symbol(
    ctx: CollectCtx,
    name: []const u8,
    kind: lsp_types.SymbolKind,
    loc: parser_types.SourceLoc,
) !void {
    if (!matches_query(name, ctx.query)) return;
    try ctx.out.append(ctx.allocator, .{
        .name = name,
        .kind = kind,
        .uri = ctx.uri,
        .range = position_mod.loc_to_range(loc, ctx.source),
    });
}

fn collect_from_decls(
    decls: []const ast.Decl,
    uri: []const u8,
    source: []const u8,
    query: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(WorkspaceSymbol),
) !void {
    const ctx = CollectCtx{
        .uri = uri,
        .source = source,
        .query = query,
        .allocator = allocator,
        .out = out,
    };
    for (decls) |decl| {
        switch (decl) {
            .class_decl => |cd| {
                try emit_symbol(ctx, cd.name, .class, cd.loc);
                try collect_from_decls(cd.members, uri, source, query, allocator, out);
            },
            .interface_decl => |id| try emit_symbol(ctx, id.name, .interface, id.loc),
            .enum_decl => |ed| try emit_symbol(ctx, ed.name, .@"enum", ed.loc),
            .method_decl => |md| try emit_symbol(ctx, md.name, .method, md.loc),
            .field_decl => |fd| try emit_symbol(ctx, fd.name, .field, fd.loc),
            .constructor_decl => |cd| {
                _ = cd;
                if (matches_query("<constructor>", query)) {
                    try out.append(allocator, .{
                        .name = "<constructor>",
                        .kind = .constructor,
                        .uri = uri,
                        .range = .{},
                    });
                }
            },
            .trigger_decl => |td| try emit_symbol(ctx, td.name, .event, td.loc),
            .static_init => {},
        }
    }
}

fn matches_query(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    // 大文字小文字無視の部分文字列マッチ
    return std.ascii.indexOfIgnoreCase(name, query) != null;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "finds class by name" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///a.cls", 1, "public class AccountService { public void process() {} }");
    const results = try search(&store, "Account", std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("AccountService", results[0].name);
}

test "finds method across documents" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///a.cls", 1, "public class Foo { public void doWork() {} }");
    try store.open("file:///b.cls", 1, "public class Bar { public void doTask() {} }");
    const results = try search(&store, "do", std.testing.allocator);
    defer std.testing.allocator.free(results);

    // doWork + doTask
    var count: usize = 0;
    for (results) |r| {
        if (std.mem.startsWith(u8, r.name, "do")) count += 1;
    }
    try std.testing.expect(count >= 2);
}

test "empty query returns all symbols" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///a.cls", 1, "public class Foo { Integer x; }");
    const results = try search(&store, "", std.testing.allocator);
    defer std.testing.allocator.free(results);

    // Foo + x
    try std.testing.expect(results.len >= 2);
}

test "partial match works" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///a.cls", 1, "public class MyClassName {}");
    const results = try search(&store, "class", std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("MyClassName", results[0].name);
}
