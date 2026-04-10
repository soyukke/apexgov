//! document_store — 開いているドキュメントの管理。
//!
//! URI をキーにソーステキスト・バージョン・キャッシュ済み AST を保持する。
//! TextDocumentSyncKind.Full（全文差し替え）で動作。

const std = @import("std");
const apex_parser = @import("../apex_parser/root.zig");
const binder_mod = @import("binder.zig");

pub const Document = struct {
    uri: []const u8,
    version: i64,
    text: []const u8,
    /// キャッシュ済みパース結果。text 変更時にリセット。
    parse_result: ?CachedParse = null,
    /// AST 構築用 arena。テキスト更新時に破棄・再作成。
    arena: ?std.heap.ArenaAllocator = null,
};

pub const CachedParse = struct {
    decls: []apex_parser.Decl,
    diagnostics: []apex_parser.ParseDiagnostic,
    tokens: []apex_parser.Token,
    bind_result: ?binder_mod.BindResult = null,
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap(Document),

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap(Document).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.freeDocument(entry.value_ptr);
        }
        self.documents.deinit();
    }

    /// ドキュメントを開く（didOpen）。
    pub fn open(self: *DocumentStore, uri: []const u8, version: i64, text: []const u8) !void {
        // 既存エントリがあれば解放してから上書き
        if (self.documents.getPtr(uri)) |existing| {
            self.freeDocument(existing);
            _ = self.documents.remove(uri);
        }

        const uri_copy = try self.allocator.dupe(u8, uri);
        const text_copy = try self.allocator.dupe(u8, text);

        try self.documents.put(uri_copy, .{
            .uri = uri_copy,
            .version = version,
            .text = text_copy,
        });
    }

    /// ドキュメントを更新する（didChange, Full sync）。
    pub fn update(self: *DocumentStore, uri: []const u8, version: i64, text: []const u8) !void {
        if (self.documents.getPtr(uri)) |doc| {
            // 古い arena を破棄
            if (doc.arena) |*a| a.deinit();
            doc.arena = null;
            doc.parse_result = null;

            // 古いテキストを解放して新しいテキストに差し替え
            self.allocator.free(doc.text);
            doc.text = try self.allocator.dupe(u8, text);
            doc.version = version;
        }
    }

    /// ドキュメントを閉じる（didClose）。
    pub fn close(self: *DocumentStore, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            var doc = kv.value;
            self.freeDocument(&doc);
        }
    }

    /// ドキュメントを取得する。
    pub fn get(self: *DocumentStore, uri: []const u8) ?*Document {
        return self.documents.getPtr(uri);
    }

    /// ドキュメントを解析し、結果をキャッシュする。
    pub fn ensureParsed(self: *DocumentStore, uri: []const u8) !?*CachedParse {
        const doc = self.documents.getPtr(uri) orelse return null;
        if (doc.parse_result != null) return &doc.parse_result.?;

        // arena を作成
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const alloc = arena.allocator();

        const tokens = try apex_parser.tokenize(doc.text, alloc);
        const result = try apex_parser.parseWithDiagnostics(tokens, alloc);

        doc.parse_result = .{
            .decls = result.decls,
            .diagnostics = result.diagnostics,
            .tokens = tokens,
        };
        doc.arena = arena;

        return &doc.parse_result.?;
    }

    /// バインド結果をキャッシュして返す。ensureParsed を内部で呼ぶ。
    pub fn ensureBound(self: *DocumentStore, uri: []const u8) !?*binder_mod.BindResult {
        const cached = try self.ensureParsed(uri) orelse return null;
        if (cached.bind_result != null) return &cached.bind_result.?;

        const doc = self.documents.getPtr(uri) orelse return null;
        const alloc = if (doc.arena) |*a| a.allocator() else return null;

        cached.bind_result = try binder_mod.bind(cached.decls, cached.tokens, doc.text, alloc);
        return &cached.bind_result.?;
    }

    fn freeDocument(self: *DocumentStore, doc: *Document) void {
        if (doc.arena) |*a| a.deinit();
        self.allocator.free(doc.text);
        self.allocator.free(doc.uri);
    }
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "open, get, update, close" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///test.cls", 1, "public class Foo {}");
    const doc = store.get("file:///test.cls");
    try std.testing.expect(doc != null);
    try std.testing.expectEqualStrings("public class Foo {}", doc.?.text);

    try store.update("file:///test.cls", 2, "public class Bar {}");
    const doc2 = store.get("file:///test.cls");
    try std.testing.expectEqualStrings("public class Bar {}", doc2.?.text);
    try std.testing.expectEqual(@as(i64, 2), doc2.?.version);

    store.close("file:///test.cls");
    try std.testing.expect(store.get("file:///test.cls") == null);
}

test "ensureParsed caches parse result" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///test.cls", 1, "public class MyClass { public void run() {} }");
    const parsed = try store.ensureParsed("file:///test.cls");
    try std.testing.expect(parsed != null);
    try std.testing.expect(parsed.?.decls.len > 0);
}
