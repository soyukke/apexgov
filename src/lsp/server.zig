//! server — LSP サーバーメインループ。
//!
//! JSON-RPC メッセージを受信し、メソッドに応じてハンドラにディスパッチする。
//! initialize / shutdown / exit ライフサイクルと
//! textDocument/didOpen, didChange, didClose → publishDiagnostics を処理する。

const std = @import("std");
const types = @import("types.zig");
const Transport = @import("transport.zig").Transport;
const DocumentStore = @import("document_store.zig").DocumentStore;
const symbols_mod = @import("symbols.zig");
const semantic_tokens_mod = @import("semantic_tokens.zig");
const governor_diags_mod = @import("governor_diagnostics.zig");
const folding_range_mod = @import("folding_range.zig");
const formatting_mod = @import("formatting.zig");
const workspace_symbol_mod = @import("workspace_symbol.zig");
const position_mod = @import("position.zig");
const hover_mod = @import("hover.zig");
const definition_mod = @import("definition.zig");
const references_mod = @import("references.zig");
const completion_mod = @import("completion.zig");
const signature_help_mod = @import("signature_help.zig");
const rename_mod = @import("rename.zig");
const document_highlight_mod = @import("document_highlight.zig");
const JsonValue = std.json.Value;
const JsonObjectMap = std.json.ObjectMap;

const sobject_schema = @import("sobject_schema.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    store: DocumentStore,
    custom_fields: sobject_schema.CustomFieldRegistry,
    initialized: bool = false,
    shutdown_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator, in_file: std.fs.File, out_file: std.fs.File) Server {
        return .{
            .allocator = allocator,
            .transport = Transport.init(allocator, in_file, out_file),
            .store = DocumentStore.init(allocator),
            .custom_fields = sobject_schema.CustomFieldRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.custom_fields.deinit();
        self.store.deinit();
        self.transport.deinit();
    }

    /// メインループ。接続終了または exit 通知まで実行。
    pub fn run(self: *Server) !void {
        while (true) {
            const msg = try self.transport.readMessage() orelse break;
            const should_exit = try self.handleMessage(msg);
            if (should_exit) break;
        }
    }

    fn handleMessage(self: *Server, raw: []const u8) !bool {
        const parsed = std.json.parseFromSlice(JsonValue, self.allocator, raw, .{}) catch {
            return false;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };

        const method = switch (obj.get("method") orelse return false) {
            .string => |s| s,
            else => return false,
        };

        const id = extractId(obj);

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id, obj);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // no-op
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            try self.transport.sendResponse(self.allocator, id, null);
        } else if (std.mem.eql(u8, method, "exit")) {
            return true;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(obj);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(obj);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(obj);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try self.handleDocumentSymbol(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            try self.handleSemanticTokensFull(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            try self.handleFoldingRange(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            try self.handleFormatting(id, obj);
        } else if (std.mem.eql(u8, method, "workspace/symbol")) {
            try self.handleWorkspaceSymbol(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.handleReferences(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            try self.handleSignatureHelp(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            try self.handleRename(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            try self.handleDocumentHighlight(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
            try self.handleCodeAction(id, obj);
        }

        return false;
    }

    fn handleInitialize(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        self.initialized = true;

        // rootUri からワークスペースのカスタムフィールドを読み込む
        if (objGet(obj, "params")) |params| {
            if (valGet(params, "rootUri")) |root_uri_val| {
                const root_uri = switch (root_uri_val) {
                    .string => |s| s,
                    else => null,
                };
                if (root_uri) |uri| {
                    if (uriToPath(uri)) |ws_path| {
                        self.custom_fields.loadFromWorkspace(ws_path) catch {};
                    }
                }
            }
        }

        const result = types.InitializeResult{};
        try self.transport.sendResponse(self.allocator, id, result);
    }

    /// file:// URI をファイルパスに変換する。
    fn uriToPath(uri: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, uri, "file:///")) return uri[7..];
        if (std.mem.startsWith(u8, uri, "file://")) return uri[7..];
        return null;
    }

    fn handleDidOpen(self: *Server, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;
        const text = objGetStr(td, "text") orelse return;
        const version = objGetInt(td, "version") orelse 0;

        try self.store.open(uri, version, text);
        try self.publishDiagnostics(uri);
    }

    fn handleDidChange(self: *Server, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;
        const version = objGetInt(td, "version") orelse 0;

        const changes_val = valGet(params, "contentChanges") orelse return;
        const changes_arr = switch (changes_val) {
            .array => |a| a,
            else => return,
        };
        if (changes_arr.items.len == 0) return;

        const last = changes_arr.items[changes_arr.items.len - 1];
        const last_obj = switch (last) {
            .object => |o| o,
            else => return,
        };
        const text = switch (last_obj.get("text") orelse return) {
            .string => |s| s,
            else => return,
        };

        try self.store.update(uri, version, text);
        try self.publishDiagnostics(uri);
    }

    fn handleDidClose(self: *Server, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;

        try self.transport.sendNotification(self.allocator, "textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = &.{},
        });

        self.store.close(uri);
    }

    fn publishDiagnostics(self: *Server, uri: []const u8) !void {
        const cached = try self.store.ensureParsed(uri) orelse return;
        const doc = self.store.get(uri) orelse return;

        var diags: std.ArrayList(types.Diagnostic) = .empty;
        defer diags.deinit(self.allocator);

        for (cached.diagnostics) |pd| {
            try diags.append(self.allocator, .{
                .range = position_mod.locToRange(pd.loc, doc.text),
                .severity = .@"error",
                .source = "apexgov",
                .message = pd.message,
            });
        }

        // Governor 制限違反診断を追加（所有権を diags に移管）
        const gov_diags = governor_diags_mod.collect(self.allocator, uri, doc.text) catch &.{};
        for (gov_diags) |gd| {
            try diags.append(self.allocator, gd);
        }
        self.allocator.free(gov_diags);

        try self.transport.sendNotification(self.allocator, "textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = diags.items,
        });

        // governor diagnostics の message は diags.deinit 時に解放不要
        // （arena 上の一時文字列として扱われる）
    }

    fn handleDocumentSymbol(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;

        const cached = try self.store.ensureParsed(uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        // symbols は ensureParsed 内の arena で確保されているので doc が生きている間有効
        const syms = try symbols_mod.collectSymbols(cached.decls, doc.text, self.allocator);
        defer self.allocator.free(syms);

        try self.transport.sendResponse(self.allocator, id, syms);
    }

    fn handleSemanticTokensFull(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;

        const cached = try self.store.ensureParsed(uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        const data = try semantic_tokens_mod.encode(cached.tokens, doc.text, self.allocator);
        defer self.allocator.free(data);

        try self.transport.sendResponse(self.allocator, id, types.SemanticTokens{ .data = data });
    }

    fn handleFoldingRange(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;

        const cached = try self.store.ensureParsed(uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };

        const ranges = try folding_range_mod.getFoldingRanges(cached.tokens, self.allocator);
        defer self.allocator.free(ranges);

        try self.transport.sendResponse(self.allocator, id, ranges);
    }

    fn handleFormatting(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;

        const cached = try self.store.ensureParsed(uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        const formatted = try formatting_mod.formatSource(cached.tokens, doc.text, .{}, self.allocator);
        defer self.allocator.free(formatted);

        // 全文置換: end を十分大きな行番号に設定（LSP 仕様: ドキュメント末尾まで）
        const edits = [_]types.TextEdit{.{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = std.math.maxInt(u32), .character = 0 },
            },
            .newText = formatted,
        }};

        try self.transport.sendResponse(self.allocator, id, &edits);
    }

    fn handleWorkspaceSymbol(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const query = switch (valGet(params, "query") orelse return) {
            .string => |s| s,
            else => return,
        };

        const results = try workspace_symbol_mod.search(&self.store, query, self.allocator);
        defer self.allocator.free(results);

        try self.transport.sendResponse(self.allocator, id, results);
    }

    fn extractPositionOffset(self: *Server, obj: JsonObjectMap) ?struct { uri: []const u8, offset: u32 } {
        const params = objGet(obj, "params") orelse return null;
        const td = valGetObj(params, "textDocument") orelse return null;
        const uri = objGetStr(td, "uri") orelse return null;
        const pos_val = valGetObj(params, "position") orelse return null;
        const line: u32 = @intCast(objGetInt(pos_val, "line") orelse return null);
        const character: u32 = @intCast(objGetInt(pos_val, "character") orelse return null);

        const doc = self.store.get(uri) orelse return null;
        const offset = position_mod.positionToOffset(doc.text, line, character) orelse return null;
        return .{ .uri = uri, .offset = offset };
    }

    fn handleHover(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const result = try hover_mod.getHover(br, doc.text, ctx.offset, self.allocator);
        try self.transport.sendResponse(self.allocator, id, result);
    }

    fn handleDefinition(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const result = definition_mod.getDefinition(br, doc.text, ctx.uri, ctx.offset);
        try self.transport.sendResponse(self.allocator, id, result);
    }

    fn handleReferences(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const locs = try references_mod.getReferences(br, doc.text, ctx.uri, ctx.offset, true, self.allocator);
        defer self.allocator.free(locs);
        try self.transport.sendResponse(self.allocator, id, locs);
    }

    fn handleCompletion(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const items = try completion_mod.getCompletions(br, doc.text, ctx.offset, self.allocator, &self.custom_fields);
        defer self.allocator.free(items);
        try self.transport.sendResponse(self.allocator, id, types.CompletionList{ .items = items });
    }

    fn handleSignatureHelp(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const result = try signature_help_mod.getSignatureHelp(br, doc.text, ctx.offset, self.allocator);
        try self.transport.sendResponse(self.allocator, id, result);
    }

    fn handleRename(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const params = objGet(obj, "params") orelse return;
        const new_name = switch (valGet(params, "newName") orelse return) {
            .string => |s| s,
            else => return,
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const edit = try rename_mod.getRenameEdits(br, doc.text, ctx.uri, ctx.offset, new_name, self.allocator);
        try self.transport.sendResponse(self.allocator, id, edit);
    }

    fn handleDocumentHighlight(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const hl = try document_highlight_mod.getHighlights(br, doc.text, ctx.offset, self.allocator);
        defer self.allocator.free(hl);
        try self.transport.sendResponse(self.allocator, id, hl);
    }

    fn handleCodeAction(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;
        _ = uri;

        // ドキュメントの全 diagnostics を取得するため publishDiagnostics で送ったものを再利用
        // 簡易実装: 空のリクエスト range でコードアクションを返す
        const range_val = valGetObj(params, "range") orelse return;
        const start_val = valGetObj(.{ .object = range_val }, "start") orelse return;
        _ = start_val;

        // 簡易版: 空アクションを返す
        const actions: []const types.CodeAction = &.{};
        try self.transport.sendResponse(self.allocator, id, actions);
    }
};

// ---------------------------------------------------------------------------
// JSON ヘルパー
// ---------------------------------------------------------------------------

fn extractId(obj: JsonObjectMap) types.RequestId {
    return switch (obj.get("id") orelse return .none) {
        .integer => |v| .{ .integer = v },
        .string => |v| .{ .string = v },
        else => .none,
    };
}

fn objGet(obj: JsonObjectMap, key: []const u8) ?JsonValue {
    return obj.get(key);
}

fn valGet(val: JsonValue, key: []const u8) ?JsonValue {
    return switch (val) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn valGetObj(val: JsonValue, key: []const u8) ?JsonObjectMap {
    const v = valGet(val, key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn objGetStr(obj: JsonObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn objGetInt(obj: JsonObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}
