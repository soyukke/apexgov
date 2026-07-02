//! document_store — 開いているドキュメントの管理。
//!
//! URI をキーにソーステキスト・バージョン・キャッシュ済み AST を保持する。
//! TextDocumentSyncKind.Full（全文差し替え）で動作。

const std = @import("std");
const apex_parser = @import("../apex_parser/root.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const lsp_types = @import("types.zig");

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
            self.free_document(entry.value_ptr);
        }
        self.documents.deinit();
    }

    /// ドキュメントを開く（didOpen）。
    pub fn open(self: *DocumentStore, uri: []const u8, version: i64, text: []const u8) !void {
        // 既存エントリがあれば解放してから上書き
        if (self.documents.getPtr(uri)) |existing| {
            self.free_document(existing);
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
            self.invalidate_cache(doc);

            // 古いテキストを解放して新しいテキストに差し替え
            self.allocator.free(doc.text);
            doc.text = try self.allocator.dupe(u8, text);
            doc.version = version;
        }
    }

    /// インクリメンタル更新: range で指定された部分を text で置換する。
    pub fn apply_incremental_change(
        self: *DocumentStore,
        uri: []const u8,
        version: i64,
        range: lsp_types.Range,
        text: []const u8,
    ) !void {
        const doc = self.documents.getPtr(uri) orelse return;
        self.invalidate_cache(doc);

        const start_offset = position_mod.position_to_offset(
            doc.text,
            range.start.line,
            range.start.character,
        ) orelse return;
        const end_offset = position_mod.position_to_offset(
            doc.text,
            range.end.line,
            range.end.character,
        ) orelse return;

        // 新しいテキストを構築: [0..start_offset] + text + [end_offset..]
        const old = doc.text;
        const new_len = start_offset + text.len + (old.len - end_offset);
        const new_text = try self.allocator.alloc(u8, new_len);
        @memcpy(new_text[0..start_offset], old[0..start_offset]);
        @memcpy(new_text[start_offset..][0..text.len], text);
        @memcpy(new_text[start_offset + text.len ..], old[end_offset..]);

        self.allocator.free(old);
        doc.text = new_text;
        doc.version = version;
    }

    fn invalidate_cache(self: *DocumentStore, doc: *Document) void {
        _ = self;
        if (doc.arena) |*a| a.deinit();
        doc.arena = null;
        doc.parse_result = null;
    }

    /// ドキュメントを閉じる（didClose）。
    pub fn close(self: *DocumentStore, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            var doc = kv.value;
            self.free_document(&doc);
        }
    }

    /// ドキュメントを取得する。
    pub fn get(self: *DocumentStore, uri: []const u8) ?*Document {
        return self.documents.getPtr(uri);
    }

    /// ドキュメントを解析し、結果をキャッシュする。
    pub fn ensure_parsed(self: *DocumentStore, uri: []const u8) !?*CachedParse {
        const doc = self.documents.getPtr(uri) orelse return null;
        if (doc.parse_result != null) return &doc.parse_result.?;

        // arena を作成
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const alloc = arena.allocator();

        const tokens = try apex_parser.tokenize(doc.text, alloc);
        const result = try apex_parser.parse_with_diagnostics(tokens, alloc);

        doc.parse_result = .{
            .decls = result.decls,
            .diagnostics = result.diagnostics,
            .tokens = tokens,
        };
        doc.arena = arena;

        return &doc.parse_result.?;
    }

    /// バインド結果をキャッシュして返す。ensure_parsed を内部で呼ぶ。
    pub fn ensure_bound(self: *DocumentStore, uri: []const u8) !?*binder_mod.BindResult {
        const cached = try self.ensure_parsed(uri) orelse return null;
        if (cached.bind_result != null) return &cached.bind_result.?;

        const doc = self.documents.getPtr(uri) orelse return null;
        const alloc = if (doc.arena) |*a| a.allocator() else return null;

        cached.bind_result = try binder_mod.bind(cached.decls, cached.tokens, doc.text, alloc);
        return &cached.bind_result.?;
    }

    /// 指定名のトップレベルシンボルをワークスペース全体から検索する。
    /// exclude_uri のドキュメントはスキップする。
    pub const SymbolMatch = struct {
        uri: []const u8,
        symbol: binder_mod.Symbol,
        source: []const u8,
    };

    pub fn resolve_symbol_across_files(
        self: *DocumentStore,
        name: []const u8,
        exclude_uri: []const u8,
    ) ?SymbolMatch {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, exclude_uri)) continue;
            const doc = entry.value_ptr;
            const br = self.ensure_bound(doc.uri) catch continue orelse continue;
            for (br.symbols) |sym| {
                if (is_top_level_type(sym.kind) and std.mem.eql(u8, sym.name, name)) {
                    return .{
                        .uri = entry.key_ptr.*,
                        .symbol = sym,
                        .source = doc.text,
                    };
                }
            }
        }
        return null;
    }

    /// `Owner.member` 形式のメンバーをワークスペース全体から検索する。
    pub fn resolve_member_across_files(
        self: *DocumentStore,
        owner_name: []const u8,
        member_name: []const u8,
        preferred_uri: []const u8,
    ) ?SymbolMatch {
        if (self.resolve_member_in_doc(preferred_uri, owner_name, member_name)) |m| return m;

        var it = self.documents.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, preferred_uri)) continue;
            if (self.resolve_member_in_doc(entry.key_ptr.*, owner_name, member_name)) |m| return m;
        }
        return null;
    }

    fn resolve_member_in_doc(
        self: *DocumentStore,
        uri: []const u8,
        owner_name: []const u8,
        member_name: []const u8,
    ) ?SymbolMatch {
        const doc = self.documents.getPtr(uri) orelse return null;
        const br = (self.ensure_bound(doc.uri) catch return null) orelse return null;

        var owner_id: ?binder_mod.SymbolId = null;
        for (br.symbols) |sym| {
            if (is_top_level_type(sym.kind) and std.mem.eql(u8, sym.name, owner_name)) {
                owner_id = sym.id;
                break;
            }
        }
        const parent_id = owner_id orelse return null;

        for (br.symbols) |sym| {
            if (sym.parent == parent_id and std.mem.eql(u8, sym.name, member_name)) {
                return .{ .uri = doc.uri, .symbol = sym, .source = doc.text };
            }
        }
        return null;
    }

    fn is_top_level_type(kind: binder_mod.SymbolKind) bool {
        return switch (kind) {
            .class, .interface, .enum_type, .trigger => true,
            else => false,
        };
    }

    fn free_document(self: *DocumentStore, doc: *Document) void {
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

test "ensure_parsed caches parse result" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///test.cls", 1, "public class MyClass { public void run() {} }");
    const parsed = try store.ensure_parsed("file:///test.cls");
    try std.testing.expect(parsed != null);
    try std.testing.expect(parsed.?.decls.len > 0);
}

test "resolve_symbol_across_files finds class in other file" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///Helper.cls", 1, "public class Helper { public void doWork() {} }");
    try store.open("file:///Main.cls", 1, "public class Main { }");

    // 両方をパース+バインド
    _ = try store.ensure_bound("file:///Helper.cls");
    _ = try store.ensure_bound("file:///Main.cls");

    // Main.cls から Helper を検索 → Helper.cls で見つかるはず
    const match = store.resolve_symbol_across_files("Helper", "file:///Main.cls");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("file:///Helper.cls", match.?.uri);
    try std.testing.expectEqualStrings("Helper", match.?.symbol.name);
}

test "resolve_member_across_files finds class method" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open(
        "file:///Helper.cls",
        1,
        "public class Helper { public static String doWork() { return null; } }",
    );
    try store.open("file:///Main.cls", 1, "public class Main { }");

    const match = store.resolve_member_across_files(
        "Helper",
        "doWork",
        "file:///Main.cls",
    );
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("file:///Helper.cls", match.?.uri);
    try std.testing.expectEqualStrings("doWork", match.?.symbol.name);
    try std.testing.expectEqualStrings("String", match.?.symbol.type_name.?);
}

test "resolve_symbol_across_files excludes current file" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///Foo.cls", 1, "public class Foo {}");
    _ = try store.ensure_bound("file:///Foo.cls");

    // 同じファイルを exclude → null
    const match = store.resolve_symbol_across_files("Foo", "file:///Foo.cls");
    try std.testing.expect(match == null);
}

test "resolve_symbol_across_files returns null for unknown symbol" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///A.cls", 1, "public class A {}");
    _ = try store.ensure_bound("file:///A.cls");

    const match = store.resolve_symbol_across_files("NonExistent", "file:///B.cls");
    try std.testing.expect(match == null);
}

// -- Incremental sync テスト --

test "apply_incremental_change: replace single word" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///t.cls", 1, "public class Foo {}");
    // "Foo" → "Bar" (line 0, char 13..16)
    try store.apply_incremental_change("file:///t.cls", 2, .{
        .start = .{ .line = 0, .character = 13 },
        .end = .{ .line = 0, .character = 16 },
    }, "Bar");

    const doc = store.get("file:///t.cls").?;
    try std.testing.expectEqualStrings("public class Bar {}", doc.text);
    try std.testing.expectEqual(@as(i64, 2), doc.version);
}

test "apply_incremental_change: insert text" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///t.cls", 1, "AB");
    // "AB" の A と B の間に "XY" を挿入 (range start == end → 挿入)
    try store.apply_incremental_change("file:///t.cls", 2, .{
        .start = .{ .line = 0, .character = 1 },
        .end = .{ .line = 0, .character = 1 },
    }, "XY");

    const doc = store.get("file:///t.cls").?;
    try std.testing.expectEqualStrings("AXYB", doc.text);
}

test "apply_incremental_change: delete text" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///t.cls", 1, "ABCDEF");
    // "BCD" を削除 (char 1..4, text="")
    try store.apply_incremental_change("file:///t.cls", 2, .{
        .start = .{ .line = 0, .character = 1 },
        .end = .{ .line = 0, .character = 4 },
    }, "");

    const doc = store.get("file:///t.cls").?;
    try std.testing.expectEqualStrings("AEF", doc.text);
}

test "apply_incremental_change: multi-line edit" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///t.cls", 1, "line0\nline1\nline2");
    // line1 全体を "replaced" に置換 (line 1, char 0 → line 1, char 5)
    try store.apply_incremental_change("file:///t.cls", 2, .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 5 },
    }, "replaced");

    const doc = store.get("file:///t.cls").?;
    try std.testing.expectEqualStrings("line0\nreplaced\nline2", doc.text);
}

test "apply_incremental_change: invalidates parse cache" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///t.cls", 1, "public class Foo {}");
    _ = try store.ensure_parsed("file:///t.cls");
    try std.testing.expect(store.get("file:///t.cls").?.parse_result != null);

    try store.apply_incremental_change("file:///t.cls", 2, .{
        .start = .{ .line = 0, .character = 13 },
        .end = .{ .line = 0, .character = 16 },
    }, "Bar");

    // キャッシュがクリアされている
    try std.testing.expect(store.get("file:///t.cls").?.parse_result == null);
}
