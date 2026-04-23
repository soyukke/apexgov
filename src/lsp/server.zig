//! server — LSP サーバーメインループ。
//!
//! JSON-RPC メッセージを受信し、メソッドに応じてハンドラにディスパッチする。
//! initialize / shutdown / exit ライフサイクルと
//! textDocument/didOpen, didChange, didClose → publishDiagnostics を処理する。

const std = @import("std");
const Io = std.Io;
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
const code_action_mod = @import("code_action.zig");
const code_lens_mod = @import("code_lens.zig");
const JsonValue = std.json.Value;
const JsonObjectMap = std.json.ObjectMap;

const sobject_schema = @import("sobject_schema.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: Io,
    transport: Transport,
    store: DocumentStore,
    custom_fields: sobject_schema.CustomFieldRegistry,
    workspace_root: ?[]const u8 = null,
    initialized: bool = false,
    shutdown_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, in_file: Io.File, out_file: Io.File) Server {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = Transport.init(allocator, io, in_file, out_file),
            .store = DocumentStore.init(allocator),
            .custom_fields = sobject_schema.CustomFieldRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.workspace_root) |wr| self.allocator.free(wr);
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
        } else if (std.mem.eql(u8, method, "textDocument/codeLens")) {
            try self.handleCodeLens(id, obj);
        } else if (std.mem.eql(u8, method, "workspace/executeCommand")) {
            try self.handleExecuteCommand(id, obj);
        } else {
            // 未対応リクエスト（id あり）にはエラーレスポンスを返す。
            // 通知（id なし）は無視して構わない。
            switch (id) {
                .none => {},
                .integer, .string => {
                    try self.transport.sendErrorResponse(self.allocator, id, -32601, "Method not found");
                },
            }
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
                        self.workspace_root = self.allocator.dupe(u8, ws_path) catch null;
                        self.custom_fields.loadFromWorkspace(self.io, ws_path) catch {};
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

        // 各変更を順番に適用
        for (changes_arr.items) |change_item| {
            const change_obj = switch (change_item) {
                .object => |o| o,
                else => continue,
            };
            const text = switch (change_obj.get("text") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            // range が存在すればインクリメンタル、なければ全文差し替え
            if (change_obj.get("range")) |range_val| {
                if (range_val == .object) {
                    const range = extractRange(range_val.object);
                    try self.store.applyIncrementalChange(uri, version, range, text);
                    continue;
                }
            }
            // Full replacement fallback
            try self.store.update(uri, version, text);
        }

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

        // Governor 制限違反診断を追加
        const gov_diags = governor_diags_mod.collect(self.allocator, uri, doc.text) catch &.{};
        defer {
            for (gov_diags) |d| {
                if (d.message.len > 0) self.allocator.free(d.message);
            }
            self.allocator.free(gov_diags);
        }
        for (gov_diags) |gd| {
            try diags.append(self.allocator, gd);
        }

        try self.transport.sendNotification(self.allocator, "textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = diags.items,
        });
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
        const cached = try self.store.ensureParsed(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const result = definition_mod.getDefinitionCrossFile(br, cached.tokens, doc.text, ctx.uri, ctx.offset, &self.store);
        try self.transport.sendResponse(self.allocator, id, result);
    }

    fn handleReferences(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extractPositionOffset(obj) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const cached = try self.store.ensureParsed(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensureBound(ctx.uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const locs = try references_mod.getReferencesCrossFile(br, cached.tokens, doc.text, ctx.uri, ctx.offset, true, &self.store, self.allocator);
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

        // リクエスト range を抽出
        const range_val = valGetObj(params, "range") orelse return;
        const range = extractRange(range_val);

        // Governor 制限診断を再計算
        const doc = self.store.get(uri) orelse return;
        const gov_diags = governor_diags_mod.collect(self.allocator, uri, doc.text) catch &.{};
        defer {
            for (gov_diags) |d| {
                if (d.message.len > 0) self.allocator.free(d.message);
            }
            self.allocator.free(gov_diags);
        }

        const actions = try code_action_mod.getCodeActions(gov_diags, range, self.allocator);
        defer self.allocator.free(actions);

        try self.transport.sendResponse(self.allocator, id, actions);
    }

    fn handleCodeLens(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse return;
        const td = valGetObj(params, "textDocument") orelse return;
        const uri = objGetStr(td, "uri") orelse return;

        const cached = try self.store.ensureParsed(uri) orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        const lenses = try code_lens_mod.getCodeLenses(cached.decls, doc.text, uri, self.allocator);
        defer self.allocator.free(lenses);

        try self.transport.sendResponse(self.allocator, id, lenses);
    }

    fn handleExecuteCommand(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = objGet(obj, "params") orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };
        const command = switch (valGet(params, "command") orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        }) {
            .string => |s| s,
            else => {
                try self.transport.sendResponse(self.allocator, id, null);
                return;
            },
        };
        const args = switch (valGet(params, "arguments") orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        }) {
            .array => |a| a.items,
            else => {
                try self.transport.sendResponse(self.allocator, id, null);
                return;
            },
        };

        if (std.mem.eql(u8, command, "apexgov.runTest")) {
            try self.executeRunTest(id, args);
        } else if (std.mem.eql(u8, command, "apexgov.runAllTests")) {
            try self.executeRunAllTests(id, args);
        } else {
            try self.transport.sendResponse(self.allocator, id, null);
        }
    }

    fn executeRunTest(self: *Server, id: types.RequestId, args: []const JsonValue) !void {
        // args: [uri, className, methodName]
        if (args.len < 3) {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        }
        const class_name = switch (args[1]) {
            .string => |s| s,
            else => {
                try self.transport.sendResponse(self.allocator, id, null);
                return;
            },
        };
        const method_name = switch (args[2]) {
            .string => |s| s,
            else => {
                try self.transport.sendResponse(self.allocator, id, null);
                return;
            },
        };

        const ws_root = self.workspace_root orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };

        try self.transport.sendResponse(self.allocator, id, null);
        try self.runTestAndNotify(ws_root, class_name, method_name);
    }

    fn executeRunAllTests(self: *Server, id: types.RequestId, args: []const JsonValue) !void {
        // args: [uri, className]
        if (args.len < 2) {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        }
        const class_name = switch (args[1]) {
            .string => |s| s,
            else => {
                try self.transport.sendResponse(self.allocator, id, null);
                return;
            },
        };

        const ws_root = self.workspace_root orelse {
            try self.transport.sendResponse(self.allocator, id, null);
            return;
        };

        try self.transport.sendResponse(self.allocator, id, null);
        try self.runTestAndNotify(ws_root, class_name, null);
    }

    fn runTestAndNotify(self: *Server, ws_root: []const u8, class_name: []const u8, method_name: ?[]const u8) !void {
        const interpret = @import("../interpret/root.zig");
        const sfdx_project = @import("sfdx_project.zig");

        // sfdx-project.json から packageDirectories を解決
        const pkg_dirs = try sfdx_project.resolvePackageDirs(self.allocator, self.io, ws_root);
        defer {
            for (pkg_dirs) |p| self.allocator.free(p);
            self.allocator.free(pkg_dirs);
        }

        // パッケージディレクトリ配下の .cls を含むサブディレクトリを探索
        // main/default/classes/ に加え tests/ 等も対象にする
        const sub_candidates = [_][]const u8{ "main/default/classes", "tests" };
        var all_dirs: std.ArrayList([]const u8) = .empty;
        defer {
            for (all_dirs.items) |p| self.allocator.free(p);
            all_dirs.deinit(self.allocator);
        }
        for (&sub_candidates) |sub| {
            const sub_dirs = try sfdx_project.resolveSubDirs(self.allocator, self.io, pkg_dirs, sub);
            defer self.allocator.free(sub_dirs);
            for (sub_dirs) |d| {
                try all_dirs.append(self.allocator, d);
            }
        }

        // サブディレクトリが見つかればそれを使い、無ければパッケージディレクトリ自体を使用
        const test_paths = if (all_dirs.items.len > 0) all_dirs.items else pkg_dirs;

        var test_allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer test_allocating.deinit();

        const suite = interpret.runSingleTest(
            self.allocator,
            self.io,
            test_paths,
            class_name,
            method_name,
            &test_allocating.writer,
        ) catch {
            try self.transport.sendNotification(self.allocator, "window/showMessage", types.ShowMessageParams{
                .type = .@"error",
                .message = "Test execution failed",
            });
            return;
        };

        // 失敗時は buf から [FAIL] 行を抽出して詳細メッセージを構築
        var failure_detail: []const u8 = "";
        if (suite.passed < suite.total) {
            // buf から [FAIL] 行を探す
            var lines = std.mem.splitScalar(u8, test_allocating.written(), '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "[FAIL] ")) {
                    // "[FAIL] Class#method: message" → "message" 部分を抽出
                    if (std.mem.indexOf(u8, line[7..], ": ")) |colon_pos| {
                        failure_detail = line[7 + colon_pos + 2 ..];
                    } else {
                        failure_detail = line[7..];
                    }
                    break;
                }
                if (std.mem.startsWith(u8, line, "[ERROR] ")) {
                    if (std.mem.indexOf(u8, line[8..], ": ")) |colon_pos| {
                        failure_detail = line[8 + colon_pos + 2 ..];
                    } else {
                        failure_detail = line[8..];
                    }
                    break;
                }
            }
        }

        // 結果メッセージを構築
        const msg = if (method_name) |mn| blk: {
            if (suite.passed < suite.total and failure_detail.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}#{s}: FAIL ({d}/{d} passed)\n{s}", .{
                    class_name, mn, suite.passed, suite.total, failure_detail,
                });
            }
            break :blk try std.fmt.allocPrint(self.allocator, "{s}#{s}: {s} ({d}/{d} passed)", .{
                class_name,
                mn,
                if (suite.passed == suite.total) "PASS" else "FAIL",
                suite.passed,
                suite.total,
            });
        } else blk: {
            if (suite.passed < suite.total and failure_detail.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}: {d}/{d} passed\n{s}", .{
                    class_name, suite.passed, suite.total, failure_detail,
                });
            }
            break :blk try std.fmt.allocPrint(self.allocator, "{s}: {d}/{d} passed", .{
                class_name,
                suite.passed,
                suite.total,
            });
        };
        defer self.allocator.free(msg);

        try self.transport.sendNotification(self.allocator, "window/showMessage", types.ShowMessageParams{
            .type = if (suite.passed == suite.total) .info else .@"error",
            .message = msg,
        });
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

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

/// テスト用: パイプで Server を構築し、JSON-RPC メッセージを送受信するヘルパー。
const TestHarness = struct {
    server: Server,
    /// テストコードがここに書くと Server の in_file で読める
    client_writer: std.fs.File,
    /// Server が out_file に書いた内容をテストコードがここから読む
    client_reader: std.fs.File,

    fn init() TestHarness {
        const in_pipe = std.posix.pipe() catch unreachable;
        const out_pipe = std.posix.pipe() catch unreachable;
        return .{
            .server = Server.init(
                std.testing.allocator,
                .{ .handle = in_pipe[0] }, // server reads from in_pipe read end
                .{ .handle = out_pipe[1] }, // server writes to out_pipe write end
            ),
            .client_writer = .{ .handle = in_pipe[1] },
            .client_reader = .{ .handle = out_pipe[0] },
        };
    }

    fn deinit(self: *TestHarness) void {
        self.server.deinit();
        self.client_writer.close();
        self.client_reader.close();
    }

    /// JSON-RPC メッセージを Server に送信する。
    fn send(self: *TestHarness, body: []const u8) void {
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
        self.client_writer.writeAll(header) catch unreachable;
        self.client_writer.writeAll(body) catch unreachable;
    }

    /// Server のレスポンスを読み取る（Content-Length ヘッダをパースして本文を返す）。
    fn readResponse(self: *TestHarness) ![]u8 {
        // ヘッダを読む
        var header_buf: [256]u8 = undefined;
        var header_len: usize = 0;
        var content_length: ?usize = null;

        while (true) {
            var byte_buf: [1]u8 = undefined;
            const n = try self.client_reader.read(&byte_buf);
            if (n == 0) return error.EndOfStream;
            header_buf[header_len] = byte_buf[0];
            header_len += 1;

            // \r\n\r\n でヘッダ終端
            if (header_len >= 4 and
                header_buf[header_len - 4] == '\r' and
                header_buf[header_len - 3] == '\n' and
                header_buf[header_len - 2] == '\r' and
                header_buf[header_len - 1] == '\n')
            {
                const header_str = header_buf[0..header_len];
                // Content-Length を抽出
                if (std.mem.indexOf(u8, header_str, "Content-Length: ")) |idx| {
                    const start = idx + "Content-Length: ".len;
                    const end = std.mem.indexOfPos(u8, header_str, start, "\r\n") orelse header_len;
                    content_length = std.fmt.parseInt(usize, header_str[start..end], 10) catch null;
                }
                break;
            }
        }

        const cl = content_length orelse return error.EndOfStream;
        const body = try std.testing.allocator.alloc(u8, cl);
        var total: usize = 0;
        while (total < cl) {
            const n = try self.client_reader.read(body[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
        return body;
    }
};

test "integration: initialize returns capabilities" {
    var h = TestHarness.init();
    defer h.deinit();

    const req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":null}}
    ;
    h.send(req);

    const msg = try h.server.transport.readMessage() orelse unreachable;
    _ = try h.server.handleMessage(msg);

    const resp = try h.readResponse();
    defer std.testing.allocator.free(resp);

    // レスポンスに capabilities が含まれている
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"capabilities\"") != null);
    // incremental sync が宣言されている (value=2)
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"textDocumentSync\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"codeActionProvider\":true") != null);
}

test "integration: didOpen + codeAction returns quickfixes" {
    var h = TestHarness.init();
    defer h.deinit();

    // 1. didOpen: ループ内 SOQL のあるコード
    const open_req =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///test.cls","languageId":"apex","version":1,
        \\  "text":"public class Foo {\n    public void run() {\n        for (Integer i = 0; i < 10; i++) {\n            List<Account> accs = [SELECT Id FROM Account];\n        }\n    }\n}"}
        \\}}
    ;
    h.send(open_req);
    const msg1 = try h.server.transport.readMessage() orelse unreachable;
    _ = try h.server.handleMessage(msg1);

    // didOpen の publishDiagnostics 通知を読み捨て
    const diag_resp = try h.readResponse();
    defer std.testing.allocator.free(diag_resp);

    // 2. codeAction リクエスト（line 3 に AG002 があるはず）
    const action_req =
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{
        \\  "textDocument":{"uri":"file:///test.cls"},
        \\  "range":{"start":{"line":3,"character":0},"end":{"line":3,"character":0}},
        \\  "context":{"diagnostics":[]}
        \\}}
    ;
    h.send(action_req);
    const msg2 = try h.server.transport.readMessage() orelse unreachable;
    _ = try h.server.handleMessage(msg2);

    const action_resp = try h.readResponse();
    defer std.testing.allocator.free(action_resp);

    // SOQL 移動提案が含まれる
    try std.testing.expect(std.mem.indexOf(u8, action_resp, "SOQL") != null);
}

test "integration: incremental didChange updates document" {
    var h = TestHarness.init();
    defer h.deinit();

    // 1. didOpen
    const open_req =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///inc.cls","languageId":"apex","version":1,
        \\  "text":"public class Foo {}"}
        \\}}
    ;
    h.send(open_req);
    const msg1 = try h.server.transport.readMessage() orelse unreachable;
    _ = try h.server.handleMessage(msg1);
    std.testing.allocator.free(try h.readResponse()); // publishDiagnostics

    // 2. incremental didChange: "Foo" → "Bar"
    const change_req =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{
        \\  "textDocument":{"uri":"file:///inc.cls","version":2},
        \\  "contentChanges":[{"range":{"start":{"line":0,"character":13},"end":{"line":0,"character":16}},"text":"Bar"}]
        \\}}
    ;
    h.send(change_req);
    const msg2 = try h.server.transport.readMessage() orelse unreachable;
    _ = try h.server.handleMessage(msg2);
    std.testing.allocator.free(try h.readResponse()); // publishDiagnostics

    // ドキュメントが更新されている
    const doc = h.server.store.get("file:///inc.cls").?;
    try std.testing.expectEqualStrings("public class Bar {}", doc.text);
}

test "integration: cross-file definition" {
    var h = TestHarness.init();
    defer h.deinit();

    // 1. Helper.cls を open
    const open_helper =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///Helper.cls","languageId":"apex","version":1,
        \\  "text":"public class Helper {}"}
        \\}}
    ;
    h.send(open_helper);
    _ = try h.server.handleMessage((try h.server.transport.readMessage()).?);
    std.testing.allocator.free(try h.readResponse());

    // 2. Main.cls を open（Helper を参照）
    const open_main =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///Main.cls","languageId":"apex","version":1,
        \\  "text":"public class Main { Helper h; }"}
        \\}}
    ;
    h.send(open_main);
    _ = try h.server.handleMessage((try h.server.transport.readMessage()).?);
    std.testing.allocator.free(try h.readResponse());

    // Helper.cls を bind しておく
    _ = try h.server.store.ensureBound("file:///Helper.cls");

    // 3. Main.cls の "Helper" 位置で definition リクエスト
    // "public class Main { Helper h; }" の "Helper" は character 20
    const def_req =
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{
        \\  "textDocument":{"uri":"file:///Main.cls"},
        \\  "position":{"line":0,"character":20}
        \\}}
    ;
    h.send(def_req);
    _ = try h.server.handleMessage((try h.server.transport.readMessage()).?);

    const def_resp = try h.readResponse();
    defer std.testing.allocator.free(def_resp);

    // Helper.cls への定義ジャンプが返る
    try std.testing.expect(std.mem.indexOf(u8, def_resp, "Helper.cls") != null);
}

/// JSON ObjectMap から LSP Range を抽出する。
fn extractRange(range_obj: JsonObjectMap) types.Range {
    var range = types.Range{};
    if (range_obj.get("start")) |start_val| {
        if (start_val == .object) {
            const s = start_val.object;
            range.start.line = @intCast(objGetInt(s, "line") orelse 0);
            range.start.character = @intCast(objGetInt(s, "character") orelse 0);
        }
    }
    if (range_obj.get("end")) |end_val| {
        if (end_val == .object) {
            const e = end_val.object;
            range.end.line = @intCast(objGetInt(e, "line") orelse 0);
            range.end.character = @intCast(objGetInt(e, "character") orelse 0);
        }
    }
    return range;
}
