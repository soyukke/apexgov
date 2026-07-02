//! server — LSP サーバーメインループ。
//!
//! JSON-RPC メッセージを受信し、メソッドに応じてハンドラにディスパッチする。
//! initialize / shutdown / exit ライフサイクルと
//! textDocument/didOpen, didChange, didClose → publish_diagnostics を処理する。

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
const sfdx_project = @import("sfdx_project.zig");

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
            const msg = try self.transport.read_message() orelse break;
            const should_exit = try self.handle_message(msg);
            if (should_exit) break;
        }
    }

    fn handle_message(self: *Server, raw: []const u8) !bool {
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

        const id = extract_id(obj);
        return try self.dispatch_method(method, id, obj);
    }

    fn dispatch_method(
        self: *Server,
        method: []const u8,
        id: types.RequestId,
        obj: JsonObjectMap,
    ) !bool {
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handle_initialize(id, obj);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // no-op
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            try self.transport.send_response(self.allocator, id, null);
        } else if (std.mem.eql(u8, method, "exit")) {
            return true;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handle_did_open(obj);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handle_did_change(obj);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handle_did_close(obj);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try self.handle_document_symbol(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            try self.handle_semantic_tokens_full(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            try self.handle_folding_range(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            try self.handle_formatting(id, obj);
        } else if (std.mem.eql(u8, method, "workspace/symbol")) {
            try self.handle_workspace_symbol(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handle_hover(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handle_definition(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.handle_references(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handle_completion(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            try self.handle_signature_help(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            try self.handle_rename(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            try self.handle_document_highlight(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
            try self.handle_code_action(id, obj);
        } else if (std.mem.eql(u8, method, "textDocument/codeLens")) {
            try self.handle_code_lens(id, obj);
        } else if (std.mem.eql(u8, method, "workspace/executeCommand")) {
            try self.handle_execute_command(id, obj);
        } else {
            // 未対応リクエスト（id あり）にはエラーレスポンスを返す。
            // 通知（id なし）は無視して構わない。
            switch (id) {
                .none => {},
                .integer, .string => {
                    try self.transport.send_error_response(
                        self.allocator,
                        id,
                        -32601,
                        "Method not found",
                    );
                },
            }
        }

        return false;
    }

    fn handle_initialize(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        self.initialized = true;

        // rootUri からワークスペースのカスタムフィールドを読み込む
        if (obj_get(obj, "params")) |params| {
            var loaded_workspace = false;
            if (val_get(params, "rootUri")) |root_uri_val| {
                const root_uri = switch (root_uri_val) {
                    .string => |s| s,
                    else => null,
                };
                if (root_uri) |uri| {
                    loaded_workspace = self.load_workspace_from_uri(uri);
                }
            }
            if (!loaded_workspace) {
                if (val_get(params, "workspaceFolders")) |folders_val| {
                    if (folders_val == .array and folders_val.array.items.len > 0) {
                        const folder = folders_val.array.items[0];
                        if (folder == .object) {
                            if (obj_get_str(folder.object, "uri")) |uri| {
                                _ = self.load_workspace_from_uri(uri);
                            }
                        }
                    }
                }
            }
        }

        const result = types.InitializeResult{};
        try self.transport.send_response(self.allocator, id, result);
    }

    /// file:// URI をファイルパスに変換する。
    fn uri_to_path(uri: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, uri, "file:///")) return uri[7..];
        if (std.mem.startsWith(u8, uri, "file://")) return uri[7..];
        return null;
    }

    fn load_workspace_from_uri(self: *Server, uri: []const u8) bool {
        const ws_path = uri_to_path(uri) orelse return false;
        self.workspace_root = self.allocator.dupe(u8, ws_path) catch return false;
        self.custom_fields.load_from_workspace(self.io, ws_path) catch {};
        self.preload_workspace_sources(ws_path) catch {};
        return true;
    }

    fn preload_workspace_sources(self: *Server, ws_root: []const u8) !void {
        const pkg_dirs = try sfdx_project.resolve_package_dirs(
            self.allocator,
            self.io,
            ws_root,
        );
        defer {
            for (pkg_dirs) |p| self.allocator.free(p);
            self.allocator.free(pkg_dirs);
        }

        for (pkg_dirs) |pkg_dir| {
            try self.preload_apex_sources_under(pkg_dir);
        }
    }

    fn preload_apex_sources_under(self: *Server, root: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var walker = dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!is_apex_source_path(entry.basename)) continue;

            const full_path = std.fs.path.join(
                self.allocator,
                &.{ root, entry.path },
            ) catch continue;
            defer self.allocator.free(full_path);

            const uri = file_uri_from_path(self.allocator, full_path) catch continue;
            defer self.allocator.free(uri);

            if (self.store.get(uri) != null) continue;

            const content = std.Io.Dir.cwd().readFileAlloc(
                self.io,
                full_path,
                self.allocator,
                .limited(8 * 1024 * 1024),
            ) catch continue;
            defer self.allocator.free(content);

            self.store.open(uri, 0, content) catch continue;
        }
    }

    fn is_apex_source_path(path: []const u8) bool {
        return std.mem.endsWith(u8, path, ".cls") or
            std.mem.endsWith(u8, path, ".trigger");
    }

    fn file_uri_from_path(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        var uri: std.ArrayList(u8) = .empty;
        try uri.appendSlice(allocator, "file://");
        for (path) |c| {
            if (uri_char_needs_escape(c)) {
                try uri.append(allocator, '%');
                try uri.append(allocator, hex_digit(c >> 4));
                try uri.append(allocator, hex_digit(c & 0x0f));
            } else {
                try uri.append(allocator, c);
            }
        }
        return uri.toOwnedSlice(allocator);
    }

    fn uri_char_needs_escape(c: u8) bool {
        return c <= ' ' or c == '%' or c == '#' or c == '?' or c == '[' or c == ']';
    }

    fn hex_digit(v: u8) u8 {
        return if (v < 10) '0' + v else 'A' + (v - 10);
    }

    fn handle_did_open(self: *Server, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;
        const text = obj_get_str(td, "text") orelse return;
        const version = obj_get_int(td, "version") orelse 0;

        try self.store.open(uri, version, text);
        try self.publish_diagnostics(uri);
    }

    fn handle_did_change(self: *Server, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;
        const version = obj_get_int(td, "version") orelse 0;

        const changes_val = val_get(params, "contentChanges") orelse return;
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
                    const range = extract_range(range_val.object);
                    try self.store.apply_incremental_change(uri, version, range, text);
                    continue;
                }
            }
            // Full replacement fallback
            try self.store.update(uri, version, text);
        }

        try self.publish_diagnostics(uri);
    }

    fn handle_did_close(self: *Server, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;

        const diag_params = types.PublishDiagnosticsParams{ .uri = uri, .diagnostics = &.{} };
        try self.transport.send_notification(
            self.allocator,
            "textDocument/publishDiagnostics",
            diag_params,
        );

        self.store.close(uri);
    }

    fn publish_diagnostics(self: *Server, uri: []const u8) !void {
        const cached = try self.store.ensure_parsed(uri) orelse return;
        const doc = self.store.get(uri) orelse return;

        var diags: std.ArrayList(types.Diagnostic) = .empty;
        defer diags.deinit(self.allocator);

        for (cached.diagnostics) |pd| {
            try diags.append(self.allocator, .{
                .range = position_mod.loc_to_range(pd.loc, doc.text),
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

        const params = types.PublishDiagnosticsParams{ .uri = uri, .diagnostics = diags.items };
        try self.transport.send_notification(
            self.allocator,
            "textDocument/publishDiagnostics",
            params,
        );
    }

    fn handle_document_symbol(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;

        const cached = try self.store.ensure_parsed(uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        // symbols は ensure_parsed 内の arena で確保されているので doc が生きている間有効
        const syms = try symbols_mod.collect_symbols(cached.decls, doc.text, self.allocator);
        defer self.allocator.free(syms);

        try self.transport.send_response(self.allocator, id, syms);
    }

    fn handle_semantic_tokens_full(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;

        const cached = try self.store.ensure_parsed(uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        const data = try semantic_tokens_mod.encode(cached.tokens, doc.text, self.allocator);
        defer self.allocator.free(data);

        try self.transport.send_response(self.allocator, id, types.SemanticTokens{ .data = data });
    }

    fn handle_folding_range(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;

        const cached = try self.store.ensure_parsed(uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };

        const ranges = try folding_range_mod.get_folding_ranges(cached.tokens, self.allocator);
        defer self.allocator.free(ranges);

        try self.transport.send_response(self.allocator, id, ranges);
    }

    fn handle_formatting(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;

        const cached = try self.store.ensure_parsed(uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        const formatted = try formatting_mod.format_source(
            cached.tokens,
            doc.text,
            .{},
            self.allocator,
        );
        defer self.allocator.free(formatted);

        // 全文置換: end を十分大きな行番号に設定（LSP 仕様: ドキュメント末尾まで）
        const edits = [_]types.TextEdit{.{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = std.math.maxInt(u32), .character = 0 },
            },
            .newText = formatted,
        }};

        try self.transport.send_response(self.allocator, id, &edits);
    }

    fn handle_workspace_symbol(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const query = switch (val_get(params, "query") orelse return) {
            .string => |s| s,
            else => return,
        };

        const results = try workspace_symbol_mod.search(&self.store, query, self.allocator);
        defer self.allocator.free(results);

        try self.transport.send_response(self.allocator, id, results);
    }

    fn extract_position_offset(
        self: *Server,
        obj: JsonObjectMap,
    ) ?struct { uri: []const u8, offset: u32 } {
        const params = obj_get(obj, "params") orelse return null;
        const td = val_get_obj(params, "textDocument") orelse return null;
        const uri = obj_get_str(td, "uri") orelse return null;
        const pos_val = val_get_obj(params, "position") orelse return null;
        const line: u32 = @intCast(obj_get_int(pos_val, "line") orelse return null);
        const character: u32 = @intCast(obj_get_int(pos_val, "character") orelse return null);

        const doc = self.store.get(uri) orelse return null;
        const offset = position_mod.position_to_offset(
            doc.text,
            line,
            character,
        ) orelse return null;
        return .{ .uri = uri, .offset = offset };
    }

    fn handle_hover(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extract_position_offset(obj) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const cached = try self.store.ensure_parsed(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensure_bound(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const result = try hover_mod.get_hover_cross_file(
            br,
            cached.tokens,
            doc.text,
            ctx.uri,
            ctx.offset,
            &self.store,
            self.allocator,
        );
        try self.transport.send_response(self.allocator, id, result);
    }

    fn handle_definition(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extract_position_offset(obj) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const cached = try self.store.ensure_parsed(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensure_bound(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const result = definition_mod.get_definition_cross_file(
            br,
            cached.tokens,
            doc.text,
            ctx.uri,
            ctx.offset,
            &self.store,
        );
        try self.transport.send_response(self.allocator, id, result);
    }

    fn handle_references(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extract_position_offset(obj) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const cached = try self.store.ensure_parsed(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensure_bound(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const locs = try references_mod.get_references_cross_file(
            br,
            cached.tokens,
            doc.text,
            ctx.uri,
            ctx.offset,
            true,
            &self.store,
            self.allocator,
        );
        defer self.allocator.free(locs);

        try self.transport.send_response(self.allocator, id, locs);
    }

    fn handle_completion(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extract_position_offset(obj) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensure_bound(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const items = try completion_mod.get_completions(
            br,
            doc.text,
            ctx.offset,
            self.allocator,
            &self.custom_fields,
        );
        defer self.allocator.free(items);

        try self.transport.send_response(
            self.allocator,
            id,
            types.CompletionList{ .items = items },
        );
    }

    fn handle_signature_help(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extract_position_offset(obj) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const cached = try self.store.ensure_parsed(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensure_bound(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const result = try signature_help_mod.get_signature_help_cross_file(
            br,
            cached.tokens,
            doc.text,
            ctx.uri,
            ctx.offset,
            &self.store,
            self.allocator,
        );
        try self.transport.send_response(self.allocator, id, result);
    }

    fn handle_rename(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extract_position_offset(obj) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const params = obj_get(obj, "params") orelse return;
        const new_name = switch (val_get(params, "newName") orelse return) {
            .string => |s| s,
            else => return,
        };
        const br = try self.store.ensure_bound(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const cached = try self.store.ensure_parsed(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const edit = try rename_mod.get_rename_edits_cross_file(
            br,
            cached.tokens,
            doc.text,
            ctx.uri,
            ctx.offset,
            new_name,
            &self.store,
            self.allocator,
        );
        try self.transport.send_response(self.allocator, id, edit);
    }

    fn handle_document_highlight(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const ctx = self.extract_position_offset(obj) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const cached = try self.store.ensure_parsed(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const br = try self.store.ensure_bound(ctx.uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(ctx.uri) orelse return;
        const hl = try document_highlight_mod.get_highlights_cross_file(
            br,
            cached.tokens,
            doc.text,
            ctx.uri,
            ctx.offset,
            &self.store,
            self.allocator,
        );
        defer self.allocator.free(hl);

        try self.transport.send_response(self.allocator, id, hl);
    }

    fn handle_code_action(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;

        // リクエスト range を抽出
        const range_val = val_get_obj(params, "range") orelse return;
        const range = extract_range(range_val);

        // Governor 制限診断を再計算
        const doc = self.store.get(uri) orelse return;
        const gov_diags = governor_diags_mod.collect(self.allocator, uri, doc.text) catch &.{};
        defer {
            for (gov_diags) |d| {
                if (d.message.len > 0) self.allocator.free(d.message);
            }
            self.allocator.free(gov_diags);
        }

        const actions = try code_action_mod.get_code_actions(gov_diags, range, self.allocator);
        defer self.allocator.free(actions);

        try self.transport.send_response(self.allocator, id, actions);
    }

    fn handle_code_lens(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse return;
        const td = val_get_obj(params, "textDocument") orelse return;
        const uri = obj_get_str(td, "uri") orelse return;

        const cached = try self.store.ensure_parsed(uri) orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const doc = self.store.get(uri) orelse return;

        const lenses = try code_lens_mod.get_code_lenses(
            cached.decls,
            doc.text,
            uri,
            self.allocator,
        );
        defer self.allocator.free(lenses);

        try self.transport.send_response(self.allocator, id, lenses);
    }

    fn handle_execute_command(self: *Server, id: types.RequestId, obj: JsonObjectMap) !void {
        const params = obj_get(obj, "params") orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };
        const command = switch (val_get(params, "command") orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        }) {
            .string => |s| s,
            else => {
                try self.transport.send_response(self.allocator, id, null);
                return;
            },
        };
        const args = switch (val_get(params, "arguments") orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        }) {
            .array => |a| a.items,
            else => {
                try self.transport.send_response(self.allocator, id, null);
                return;
            },
        };

        if (std.mem.eql(u8, command, "apexgov.runTest")) {
            try self.execute_run_test(id, args);
        } else if (std.mem.eql(u8, command, "apexgov.runAllTests")) {
            try self.execute_run_all_tests(id, args);
        } else {
            try self.transport.send_response(self.allocator, id, null);
        }
    }

    fn execute_run_test(self: *Server, id: types.RequestId, args: []const JsonValue) !void {
        // args: [uri, className, methodName]
        if (args.len < 3) {
            try self.transport.send_response(self.allocator, id, null);
            return;
        }
        const class_name = switch (args[1]) {
            .string => |s| s,
            else => {
                try self.transport.send_response(self.allocator, id, null);
                return;
            },
        };
        const method_name = switch (args[2]) {
            .string => |s| s,
            else => {
                try self.transport.send_response(self.allocator, id, null);
                return;
            },
        };

        const ws_root = self.workspace_root orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };

        try self.transport.send_response(self.allocator, id, null);
        try self.run_test_and_notify(ws_root, class_name, method_name);
    }

    fn execute_run_all_tests(self: *Server, id: types.RequestId, args: []const JsonValue) !void {
        // args: [uri, className]
        if (args.len < 2) {
            try self.transport.send_response(self.allocator, id, null);
            return;
        }
        const class_name = switch (args[1]) {
            .string => |s| s,
            else => {
                try self.transport.send_response(self.allocator, id, null);
                return;
            },
        };

        const ws_root = self.workspace_root orelse {
            try self.transport.send_response(self.allocator, id, null);
            return;
        };

        try self.transport.send_response(self.allocator, id, null);
        try self.run_test_and_notify(ws_root, class_name, null);
    }

    const SUB_CANDIDATES = [_][]const u8{ "main/default/classes", "tests" };

    /// Collects candidate test directories under packageDirectories.
    /// Caller owns returned slices (both all_dirs entries and pkg_dirs).
    fn collect_test_paths(
        self: *Server,
        ws_root: []const u8,
        pkg_dirs: []const []const u8,
        all_dirs: *std.ArrayList([]const u8),
    ) !void {
        _ = ws_root;
        for (&SUB_CANDIDATES) |sub| {
            const sub_dirs = try sfdx_project.resolve_sub_dirs(
                self.allocator,
                self.io,
                pkg_dirs,
                sub,
            );
            defer self.allocator.free(sub_dirs);

            for (sub_dirs) |d| {
                try all_dirs.append(self.allocator, d);
            }
        }
    }

    fn run_test_and_notify(
        self: *Server,
        ws_root: []const u8,
        class_name: []const u8,
        method_name: ?[]const u8,
    ) !void {
        const interpret = @import("../interpret/root.zig");

        // sfdx-project.json から packageDirectories を解決
        const pkg_dirs = try sfdx_project.resolve_package_dirs(self.allocator, self.io, ws_root);
        defer {
            for (pkg_dirs) |p| self.allocator.free(p);
            self.allocator.free(pkg_dirs);
        }

        var all_dirs: std.ArrayList([]const u8) = .empty;
        defer {
            for (all_dirs.items) |p| self.allocator.free(p);
            all_dirs.deinit(self.allocator);
        }

        try self.collect_test_paths(ws_root, pkg_dirs, &all_dirs);

        // サブディレクトリが見つかればそれを使い、無ければパッケージディレクトリ自体を使用
        const test_paths = if (all_dirs.items.len > 0) all_dirs.items else pkg_dirs;

        var test_allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer test_allocating.deinit();

        var suite = interpret.run_single_test(
            self.allocator,
            self.io,
            test_paths,
            class_name,
            method_name,
            &test_allocating.writer,
        ) catch {
            try self.notify_test_execution_failed();
            return;
        };
        defer suite.deinit();

        try self.notify_test_result(class_name, method_name, suite, test_allocating.written());
    }

    fn notify_test_execution_failed(self: *Server) !void {
        const err_params = types.ShowMessageParams{
            .type = .@"error",
            .message = "Test execution failed",
        };
        try self.transport.send_notification(self.allocator, "window/showMessage", err_params);
    }

    fn notify_test_result(
        self: *Server,
        class_name: []const u8,
        method_name: ?[]const u8,
        suite: anytype,
        output: []const u8,
    ) !void {
        // 失敗時は buf から [FAIL] 行を抽出して詳細メッセージを構築
        const failure_detail = if (suite.passed < suite.total)
            extract_test_failure_detail(output)
        else
            "";

        // 結果メッセージを構築
        const msg = try format_test_result_message(
            self.allocator,
            class_name,
            method_name,
            suite.passed,
            suite.total,
            failure_detail,
        );
        defer self.allocator.free(msg);

        const result_params = types.ShowMessageParams{
            .type = if (suite.passed == suite.total) .info else .@"error",
            .message = msg,
        };
        try self.transport.send_notification(
            self.allocator,
            "window/showMessage",
            result_params,
        );
    }
};

fn extract_test_failure_detail(output: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "[FAIL] ")) {
            if (std.mem.indexOf(u8, line[7..], ": ")) |colon_pos| {
                return line[7 + colon_pos + 2 ..];
            }
            return line[7..];
        }
        if (std.mem.startsWith(u8, line, "[ERROR] ")) {
            if (std.mem.indexOf(u8, line[8..], ": ")) |colon_pos| {
                return line[8 + colon_pos + 2 ..];
            }
            return line[8..];
        }
    }
    return "";
}

fn format_test_result_message(
    gpa: std.mem.Allocator,
    class_name: []const u8,
    method_name: ?[]const u8,
    passed: u32,
    total: u32,
    failure_detail: []const u8,
) ![]u8 {
    if (method_name) |mn| {
        if (passed < total and failure_detail.len > 0) {
            return std.fmt.allocPrint(
                gpa,
                "{s}#{s}: FAIL ({d}/{d} passed)\n{s}",
                .{ class_name, mn, passed, total, failure_detail },
            );
        }
        return std.fmt.allocPrint(gpa, "{s}#{s}: {s} ({d}/{d} passed)", .{
            class_name,
            mn,
            if (passed == total) "PASS" else "FAIL",
            passed,
            total,
        });
    }
    if (passed < total and failure_detail.len > 0) {
        return std.fmt.allocPrint(
            gpa,
            "{s}: {d}/{d} passed\n{s}",
            .{ class_name, passed, total, failure_detail },
        );
    }
    return std.fmt.allocPrint(gpa, "{s}: {d}/{d} passed", .{ class_name, passed, total });
}

// ---------------------------------------------------------------------------
// JSON ヘルパー
// ---------------------------------------------------------------------------

fn extract_id(obj: JsonObjectMap) types.RequestId {
    return switch (obj.get("id") orelse return .none) {
        .integer => |v| .{ .integer = v },
        .string => |v| .{ .string = v },
        else => .none,
    };
}

fn obj_get(obj: JsonObjectMap, key: []const u8) ?JsonValue {
    return obj.get(key);
}

fn val_get(val: JsonValue, key: []const u8) ?JsonValue {
    return switch (val) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn val_get_obj(val: JsonValue, key: []const u8) ?JsonObjectMap {
    const v = val_get(val, key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn obj_get_str(obj: JsonObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn obj_get_int(obj: JsonObjectMap, key: []const u8) ?i64 {
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
    client_writer: Io.File,
    /// Server が out_file に書いた内容をテストコードがここから読む
    client_reader: Io.File,

    fn init() !TestHarness {
        const in_pipe = try Io.Threaded.pipe2(.{});
        errdefer close_fd(in_pipe[0]);
        errdefer close_fd(in_pipe[1]);

        const out_pipe = try Io.Threaded.pipe2(.{});
        errdefer close_fd(out_pipe[0]);
        errdefer close_fd(out_pipe[1]);

        const server_reader = pipe_file(in_pipe[0]);
        const client_writer = pipe_file(in_pipe[1]);
        const client_reader = pipe_file(out_pipe[0]);
        const server_writer = pipe_file(out_pipe[1]);

        return .{
            .server = Server.init(
                std.testing.allocator,
                std.testing.io,
                server_reader,
                server_writer,
            ),
            .client_writer = client_writer,
            .client_reader = client_reader,
        };
    }

    fn deinit(self: *TestHarness) void {
        self.server.deinit();
        self.server.transport.in_file.close(std.testing.io);
        self.server.transport.out_file.close(std.testing.io);
        self.client_writer.close(std.testing.io);
        self.client_reader.close(std.testing.io);
    }

    /// JSON-RPC メッセージを Server に送信する。
    fn send(self: *TestHarness, body: []const u8) void {
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "Content-Length: {d}\r\n\r\n",
            .{body.len},
        ) catch unreachable;
        self.client_writer.writeStreamingAll(std.testing.io, header) catch unreachable;
        self.client_writer.writeStreamingAll(std.testing.io, body) catch unreachable;
    }

    /// Server のレスポンスを読み取る（Content-Length ヘッダをパースして本文を返す）。
    fn read_response(self: *TestHarness) ![]u8 {
        // ヘッダを読む
        var header_buf: [256]u8 = undefined;
        var header_len: usize = 0;
        var content_length: ?usize = null;

        while (true) {
            var byte_buf: [1]u8 = undefined;
            const slices: [1][]u8 = .{&byte_buf};
            const n = try self.client_reader.readStreaming(std.testing.io, &slices);
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
            const slices: [1][]u8 = .{body[total..]};
            const n = try self.client_reader.readStreaming(std.testing.io, &slices);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
        return body;
    }
};

fn pipe_file(fd: std.posix.fd_t) Io.File {
    return .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
}

fn close_fd(fd: std.posix.fd_t) void {
    pipe_file(fd).close(std.testing.io);
}

test "integration: initialize returns capabilities" {
    var h = try TestHarness.init();
    defer h.deinit();

    const req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":null}}
    ;
    h.send(req);

    const msg = try h.server.transport.read_message() orelse unreachable;
    _ = try h.server.handle_message(msg);

    const resp = try h.read_response();
    defer std.testing.allocator.free(resp);

    // レスポンスに capabilities が含まれている
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"capabilities\"") != null);
    // incremental sync が宣言されている (value=2)
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"textDocumentSync\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"codeActionProvider\":true") != null);
}

test "integration: didOpen + codeAction returns quickfixes" {
    var h = try TestHarness.init();
    defer h.deinit();

    // 1. didOpen: ループ内 SOQL のあるコード
    const open_text =
        "public class Foo {\\n" ++
        "    public void run() {\\n" ++
        "        for (Integer i = 0; i < 10; i++) {\\n" ++
        "            List<Account> accs = [SELECT Id FROM Account];\\n" ++
        "        }\\n    }\\n}";
    const open_req =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///test.cls","languageId":"apex","version":1,
        \\  "text":"
    ++ open_text ++
        \\"}
        \\}}
    ;
    h.send(open_req);
    const msg1 = try h.server.transport.read_message() orelse unreachable;
    _ = try h.server.handle_message(msg1);

    // didOpen の publish_diagnostics 通知を読み捨て
    const diag_resp = try h.read_response();
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
    const msg2 = try h.server.transport.read_message() orelse unreachable;
    _ = try h.server.handle_message(msg2);

    const action_resp = try h.read_response();
    defer std.testing.allocator.free(action_resp);

    // SOQL 移動提案が含まれる
    try std.testing.expect(std.mem.indexOf(u8, action_resp, "SOQL") != null);
}

test "integration: incremental didChange updates document" {
    var h = try TestHarness.init();
    defer h.deinit();

    // 1. didOpen
    const open_req =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///inc.cls","languageId":"apex","version":1,
        \\  "text":"public class Foo {}"}
        \\}}
    ;
    h.send(open_req);
    const msg1 = try h.server.transport.read_message() orelse unreachable;
    _ = try h.server.handle_message(msg1);
    std.testing.allocator.free(try h.read_response()); // publish_diagnostics

    // 2. incremental didChange: "Foo" → "Bar"
    const range_json =
        \\{"range":{"start":{"line":0,"character":13},"end":{"line":0,"character":16}},"text":"Bar"}
    ;
    const change_req =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{
        \\  "textDocument":{"uri":"file:///inc.cls","version":2},
        \\  "contentChanges":[
    ++ range_json ++
        \\]
        \\}}
    ;
    h.send(change_req);
    const msg2 = try h.server.transport.read_message() orelse unreachable;
    _ = try h.server.handle_message(msg2);
    std.testing.allocator.free(try h.read_response()); // publish_diagnostics

    // ドキュメントが更新されている
    const doc = h.server.store.get("file:///inc.cls").?;
    try std.testing.expectEqualStrings("public class Bar {}", doc.text);
}

test "integration: cross-file definition" {
    var h = try TestHarness.init();
    defer h.deinit();

    // 1. Helper.cls を open
    const open_helper =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///Helper.cls","languageId":"apex","version":1,
        \\  "text":"public class Helper {}"}
        \\}}
    ;
    h.send(open_helper);
    _ = try h.server.handle_message((try h.server.transport.read_message()).?);
    std.testing.allocator.free(try h.read_response());

    // 2. Main.cls を open（Helper を参照）
    const open_main =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
        \\  "textDocument":{"uri":"file:///Main.cls","languageId":"apex","version":1,
        \\  "text":"public class Main { Helper h; }"}
        \\}}
    ;
    h.send(open_main);
    _ = try h.server.handle_message((try h.server.transport.read_message()).?);
    std.testing.allocator.free(try h.read_response());

    // Helper.cls を bind しておく
    _ = try h.server.store.ensure_bound("file:///Helper.cls");

    // 3. Main.cls の "Helper" 位置で definition リクエスト
    // "public class Main { Helper h; }" の "Helper" は character 20
    const def_req =
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{
        \\  "textDocument":{"uri":"file:///Main.cls"},
        \\  "position":{"line":0,"character":20}
        \\}}
    ;
    h.send(def_req);
    _ = try h.server.handle_message((try h.server.transport.read_message()).?);

    const def_resp = try h.read_response();
    defer std.testing.allocator.free(def_resp);

    // Helper.cls への定義ジャンプが返る
    try std.testing.expect(std.mem.indexOf(u8, def_resp, "Helper.cls") != null);
}

/// JSON ObjectMap から LSP Range を抽出する。
fn extract_range(range_obj: JsonObjectMap) types.Range {
    var range = types.Range{};
    if (range_obj.get("start")) |start_val| {
        if (start_val == .object) {
            const s = start_val.object;
            range.start.line = @intCast(obj_get_int(s, "line") orelse 0);
            range.start.character = @intCast(obj_get_int(s, "character") orelse 0);
        }
    }
    if (range_obj.get("end")) |end_val| {
        if (end_val == .object) {
            const e = end_val.object;
            range.end.line = @intCast(obj_get_int(e, "line") orelse 0);
            range.end.character = @intCast(obj_get_int(e, "character") orelse 0);
        }
    }
    return range;
}
