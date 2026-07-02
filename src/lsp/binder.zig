//! binder — AST ベースのスコープ解析 + シンボルテーブル構築。
//!
//! パース済み AST を走査し、全シンボル（クラス、メソッド、フィールド、変数等）と
//! 全参照（識別子の出現箇所）を収集する。
//! hover, definition, references, completion, rename 等の基盤。

const std = @import("std");
const ast = @import("../apex_parser/ast.zig");
const parser_types = @import("../apex_parser/types.zig");
const SourceLoc = parser_types.SourceLoc;
const TypeRef = parser_types.TypeRef;
const Token = parser_types.Token;
const TokenKind = parser_types.TokenKind;

pub const SymbolId = u32;
pub const ScopeId = u32;

pub const SymbolKind = enum {
    class,
    interface,
    enum_type,
    enum_value,
    method,
    constructor,
    field,
    parameter,
    local_variable,
    for_each_variable,
    catch_variable,
    trigger,
};

pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    kind: SymbolKind,
    type_name: ?[]const u8,
    loc: SourceLoc,
    end_offset: u32,
    param_count: ?u32,
    parent: ?SymbolId,
    scope_id: ScopeId,
};

pub const Reference = struct {
    offset: u32,
    end_offset: u32,
    symbol_id: SymbolId,
    is_definition: bool,
};

pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    symbol_ids: std.ArrayListUnmanaged(SymbolId),
};

pub const BindResult = struct {
    symbols: []Symbol,
    scopes: []Scope,
    references: []Reference,
};

/// AST を解析してシンボルテーブルと参照リストを構築する。
pub fn bind(
    decls: []const ast.Decl,
    tokens: []const Token,
    source: []const u8,
    allocator: std.mem.Allocator,
) !BindResult {
    _ = source;
    var b = Binder{
        .allocator = allocator,
        .tokens = tokens,
    };
    for (decls) |decl| {
        try b.bind_decl(decl, null, b.current_scope);
    }
    return .{
        .symbols = try b.symbols.toOwnedSlice(allocator),
        .scopes = try b.scopes.toOwnedSlice(allocator),
        .references = try b.sorted_references(),
    };
}

/// offset 位置にあるシンボルを探す（参照テーブルを線形探索）。
pub fn symbol_at_position(result: *const BindResult, offset: u32) ?*const Symbol {
    // references は offset 順にソート済み
    for (result.references) |ref| {
        if (offset >= ref.offset and offset < ref.end_offset) {
            return &result.symbols[ref.symbol_id];
        }
    }
    return null;
}

/// symbol_id に一致する参照をフィルタして返す。
pub fn filter_references(
    result: *const BindResult,
    symbol_id: SymbolId,
    allocator: std.mem.Allocator,
) ![]const Reference {
    var out: std.ArrayList(Reference) = .empty;
    for (result.references) |ref| {
        if (ref.symbol_id == symbol_id) {
            try out.append(allocator, ref);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn resolve_current_class_member(
    result: *const BindResult,
    offset: u32,
    member_name: []const u8,
) ?*const Symbol {
    return resolve_current_class_member_with_arity(result, offset, member_name, null);
}

pub fn resolve_current_class_member_with_arity(
    result: *const BindResult,
    offset: u32,
    member_name: []const u8,
    arg_count: ?u32,
) ?*const Symbol {
    const owner_id = current_class_symbol_id(result, offset) orelse return null;
    for (result.symbols) |*sym| {
        if (sym.parent == null or sym.parent.? != owner_id) continue;
        if (!is_class_member(sym.kind)) continue;
        if (!std.mem.eql(u8, sym.name, member_name)) continue;
        if (!member_arity_matches(sym, arg_count)) continue;
        return sym;
    }
    return null;
}

pub fn current_class_symbol_id(
    result: *const BindResult,
    offset: u32,
) ?SymbolId {
    var owner_id: ?SymbolId = null;
    var owner_offset: u32 = 0;
    for (result.symbols) |sym| {
        if (sym.kind != .class and sym.kind != .interface) continue;
        if (sym.loc.offset > offset) continue;
        if (offset >= sym.end_offset) continue;
        if (owner_id == null or sym.loc.offset >= owner_offset) {
            owner_id = sym.id;
            owner_offset = sym.loc.offset;
        }
    }
    return owner_id;
}

fn is_class_member(kind: SymbolKind) bool {
    return switch (kind) {
        .method, .field, .constructor, .enum_value, .class, .interface, .enum_type => true,
        else => false,
    };
}

pub fn member_arity_matches(sym: *const Symbol, arg_count: ?u32) bool {
    const expected = arg_count orelse return true;
    const actual = sym.param_count orelse return true;
    return actual == expected;
}

// ---------------------------------------------------------------------------
// 内部: Binder
// ---------------------------------------------------------------------------

const Binder = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    references: std.ArrayListUnmanaged(Reference) = .empty,
    current_scope: ScopeId = 0,

    fn add_symbol(
        self: *Binder,
        name: []const u8,
        kind: SymbolKind,
        type_name: ?[]const u8,
        loc: SourceLoc,
        parent: ?SymbolId,
        end_offset: ?u32,
    ) !SymbolId {
        const id: SymbolId = @intCast(self.symbols.items.len);

        // スコープが無ければルートスコープを作成
        if (self.scopes.items.len == 0) {
            try self.scopes.append(self.allocator, .{
                .id = 0,
                .parent = null,
                .symbol_ids = .empty,
            });
        }

        // 名前の正確なトークン位置を探す（loc はしばしば宣言の先頭を指す）
        const name_loc = self.find_token_after(loc.offset, name) orelse loc;
        const name_end = name_loc.offset + @as(u32, @intCast(name.len));
        const symbol_end = if (end_offset) |end|
            if (end > name_end) end else name_end
        else
            name_end;

        try self.symbols.append(self.allocator, .{
            .id = id,
            .name = name,
            .kind = kind,
            .type_name = type_name,
            .loc = name_loc,
            .end_offset = symbol_end,
            .param_count = null,
            .parent = parent,
            .scope_id = self.current_scope,
        });

        // スコープにシンボルを登録
        if (self.current_scope < self.scopes.items.len) {
            try self.scopes.items[self.current_scope].symbol_ids.append(self.allocator, id);
        }

        // 定義参照を登録
        try self.references.append(self.allocator, .{
            .offset = name_loc.offset,
            .end_offset = name_loc.offset + @as(u32, @intCast(name.len)),
            .symbol_id = id,
            .is_definition = true,
        });

        return id;
    }

    fn add_declaration_symbol(
        self: *Binder,
        name: []const u8,
        kind: SymbolKind,
        type_name: ?[]const u8,
        loc: SourceLoc,
        parent: ?SymbolId,
    ) !SymbolId {
        return self.add_symbol(
            name,
            kind,
            type_name,
            loc,
            parent,
            self.declaration_end_offset(loc.offset),
        );
    }

    /// loc 以降のトークンから name に一致する identifier を探す。
    /// loc.offset 以降のトークンから name に一致する identifier を探す。
    fn find_token_after(self: *Binder, min_offset: u32, name: []const u8) ?SourceLoc {
        for (self.tokens) |tok| {
            if (tok.loc.offset < min_offset) continue;
            if (tok.kind == .identifier and std.mem.eql(u8, tok.lexeme, name)) {
                return tok.loc;
            }
        }
        return null;
    }

    fn declaration_end_offset(self: *const Binder, start_offset: u32) ?u32 {
        var depth: u32 = 0;
        var seen_open = false;
        for (self.tokens) |tok| {
            if (tok.loc.offset < start_offset) continue;
            if (tok.kind == .lbrace) {
                seen_open = true;
                depth += 1;
                continue;
            }
            if (!seen_open or tok.kind != .rbrace) continue;

            depth -= 1;
            if (depth == 0) {
                return tok.loc.offset + @as(u32, @intCast(tok.lexeme.len));
            }
        }
        return null;
    }

    fn push_scope(self: *Binder) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{
            .id = id,
            .parent = self.current_scope,
            .symbol_ids = .empty,
        });
        self.current_scope = id;
        return id;
    }

    fn pop_scope(self: *Binder) void {
        if (self.current_scope < self.scopes.items.len) {
            if (self.scopes.items[self.current_scope].parent) |p| {
                self.current_scope = p;
            }
        }
    }

    /// スコープチェーンで名前を解決する。
    fn resolve(self: *Binder, name: []const u8) ?SymbolId {
        var scope_id = self.current_scope;
        while (true) {
            if (scope_id < self.scopes.items.len) {
                const scope = &self.scopes.items[scope_id];
                // 逆順で探索（後に定義されたものが優先）
                var i = scope.symbol_ids.items.len;
                while (i > 0) {
                    i -= 1;
                    const sym_id = scope.symbol_ids.items[i];
                    if (sym_id < self.symbols.items.len) {
                        if (std.mem.eql(u8, self.symbols.items[sym_id].name, name)) {
                            return sym_id;
                        }
                    }
                }
                if (scope.parent) |p| {
                    scope_id = p;
                } else break;
            } else break;
        }
        return null;
    }

    fn add_reference(self: *Binder, offset: u32, name: []const u8) !void {
        if (self.resolve(name)) |sym_id| {
            try self.references.append(self.allocator, .{
                .offset = offset,
                .end_offset = offset + @as(u32, @intCast(name.len)),
                .symbol_id = sym_id,
                .is_definition = false,
            });
        }
    }

    fn sorted_references(self: *Binder) ![]Reference {
        const slice = try self.references.toOwnedSlice(self.allocator);
        std.mem.sort(Reference, slice, {}, struct {
            fn less_than(_: void, a: Reference, b_ref: Reference) bool {
                return a.offset < b_ref.offset;
            }
        }.less_than);
        return slice;
    }

    fn type_ref_to_string(tr: TypeRef) ?[]const u8 {
        if (tr.name.len == 0) return null;
        return tr.name;
    }

    // -----------------------------------------------------------------------
    // Decl 走査
    // -----------------------------------------------------------------------

    fn bind_params(self: *Binder, params: anytype, base_loc: SourceLoc, owner: SymbolId) !void {
        for (params) |p| {
            const param_loc = self.find_token_after(base_loc.offset, p.name) orelse base_loc;
            _ = try self.add_symbol(
                p.name,
                .parameter,
                type_ref_to_string(p.type_ref),
                param_loc,
                owner,
                null,
            );
        }
    }

    fn bind_body_scope(self: *Binder, body: []const ast.Stmt) !void {
        for (body) |stmt| {
            try self.bind_stmt(stmt);
        }
    }

    fn bind_method_like(
        self: *Binder,
        name: []const u8,
        kind: SymbolKind,
        return_type: ?[]const u8,
        loc: SourceLoc,
        params: anytype,
        body: []const ast.Stmt,
        parent: ?SymbolId,
    ) !void {
        const sym_id = try self.add_declaration_symbol(name, kind, return_type, loc, parent);
        self.symbols.items[sym_id].param_count = @intCast(params.len);
        _ = try self.push_scope();
        try self.bind_params(params, loc, sym_id);
        try self.bind_body_scope(body);
        self.pop_scope();
    }

    fn bind_decl(self: *Binder, decl: ast.Decl, parent: ?SymbolId, _: ScopeId) !void {
        switch (decl) {
            .class_decl => |cd| {
                const sym_id = try self.add_declaration_symbol(
                    cd.name,
                    .class,
                    null,
                    cd.loc,
                    parent,
                );
                _ = try self.push_scope();
                for (cd.members) |member| {
                    try self.bind_decl(member, sym_id, self.current_scope);
                }
                self.pop_scope();
            },
            .interface_decl => |id| {
                _ = try self.add_declaration_symbol(id.name, .interface, null, id.loc, parent);
            },
            .enum_decl => |ed| {
                const sym_id = try self.add_declaration_symbol(
                    ed.name,
                    .enum_type,
                    null,
                    ed.loc,
                    parent,
                );
                for (ed.values) |v| {
                    // enum values の正確な位置はトークンから探す必要があるが、簡易版では enum の loc を使用
                    _ = try self.add_symbol(v, .enum_value, ed.name, ed.loc, sym_id, null);
                }
            },
            .method_decl => |md| try self.bind_method_like(
                md.name,
                .method,
                type_ref_to_string(md.return_type),
                md.loc,
                md.params,
                md.body,
                parent,
            ),
            .constructor_decl => |cd| try self.bind_method_like(
                "<constructor>",
                .constructor,
                null,
                cd.loc,
                cd.params,
                cd.body,
                parent,
            ),
            .field_decl => |fd| {
                _ = try self.add_symbol(
                    fd.name,
                    .field,
                    type_ref_to_string(fd.type_ref),
                    fd.loc,
                    parent,
                    null,
                );
            },
            .trigger_decl => |td| {
                _ = try self.add_declaration_symbol(td.name, .trigger, null, td.loc, parent);
                _ = try self.push_scope();
                try self.bind_body_scope(td.body);
                self.pop_scope();
            },
            .static_init => |stmts| try self.bind_body_scope(stmts),
        }
    }

    // -----------------------------------------------------------------------
    // Stmt 走査
    // -----------------------------------------------------------------------

    fn bind_for_stmt(self: *Binder, fs: anytype) anyerror!void {
        _ = try self.push_scope();
        if (fs.init) |init_stmt| {
            switch (init_stmt.*) {
                .block => |init_stmts| {
                    for (init_stmts) |init_item| try self.bind_stmt(init_item);
                },
                else => try self.bind_stmt(init_stmt.*),
            }
        }
        if (fs.condition) |cond| try self.bind_expr(cond.*);
        if (fs.update) |upd| try self.bind_expr(upd.*);
        for (fs.body) |s| try self.bind_stmt(s);
        self.pop_scope();
    }

    fn bind_try_stmt(self: *Binder, ts: anytype) anyerror!void {
        for (ts.body) |s| try self.bind_stmt(s);
        for (ts.catches) |cc| {
            _ = try self.push_scope();
            _ = try self.add_symbol(
                cc.name,
                .catch_variable,
                type_ref_to_string(cc.exception_type),
                SourceLoc.zero,
                null,
                null,
            );
            for (cc.body) |s| try self.bind_stmt(s);
            self.pop_scope();
        }
        if (ts.finally_body) |fb| {
            for (fb) |s| try self.bind_stmt(s);
        }
    }

    fn bind_var_decl(self: *Binder, vd: anytype) !void {
        _ = try self.add_symbol(
            vd.name,
            .local_variable,
            type_ref_to_string(vd.type_ref),
            vd.loc,
            null,
            null,
        );
        if (vd.initializer) |init_expr| {
            try self.bind_expr(init_expr.*);
        }
    }

    fn bind_for_each_stmt(self: *Binder, fes: anytype) anyerror!void {
        _ = try self.push_scope();
        _ = try self.add_symbol(
            fes.elem_name,
            .for_each_variable,
            type_ref_to_string(fes.elem_type),
            fes.loc,
            null,
            null,
        );
        try self.bind_expr(fes.iterable.*);
        for (fes.body) |s| try self.bind_stmt(s);
        self.pop_scope();
    }

    fn bind_stmt(self: *Binder, stmt: ast.Stmt) !void {
        switch (stmt) {
            .var_decl => |vd| try self.bind_var_decl(vd),
            .block => |stmts| {
                _ = try self.push_scope();
                for (stmts) |s| try self.bind_stmt(s);
                self.pop_scope();
            },
            .if_stmt => |is| {
                try self.bind_expr(is.condition.*);
                for (is.then_body) |s| try self.bind_stmt(s);
                if (is.else_body) |eb| {
                    for (eb) |s| try self.bind_stmt(s);
                }
            },
            .for_stmt => |fs| try self.bind_for_stmt(fs),
            .for_each_stmt => |fes| try self.bind_for_each_stmt(fes),
            .while_stmt => |ws| {
                try self.bind_expr(ws.condition.*);
                for (ws.body) |s| try self.bind_stmt(s);
            },
            .do_while => |dw| {
                for (dw.body) |s| try self.bind_stmt(s);
                try self.bind_expr(dw.condition.*);
            },
            .return_stmt => |rs| {
                if (rs.value) |val| try self.bind_expr(val.*);
            },
            .throw_stmt => |ts| try self.bind_expr(ts.expr.*),
            .switch_stmt => |ss| {
                try self.bind_expr(ss.subject.*);
                for (ss.when_clauses) |wc| {
                    for (wc.body) |s| try self.bind_stmt(s);
                }
            },
            .try_stmt => |ts| try self.bind_try_stmt(ts),
            .expr_stmt => |expr| try self.bind_expr(expr.*),
            .dml_stmt => |ds| try self.bind_expr(ds.target.*),
            .run_as_stmt => |ras| {
                try self.bind_expr(ras.user_expr.*);
                for (ras.body) |s| try self.bind_stmt(s);
            },
            .break_stmt, .continue_stmt => {},
        }
    }

    // -----------------------------------------------------------------------
    // Expr 走査
    // -----------------------------------------------------------------------

    fn bind_expr(self: *Binder, expr: ast.Expr) !void {
        switch (expr) {
            .integer_literal,
            .long_literal,
            .double_literal,
            .string_literal,
            .boolean_literal,
            .null_literal,
            .this_expr,
            .super_expr,
            .soql,
            => {},
            .identifier => |id| {
                try self.add_reference(id.loc.offset, id.name);
            },
            .binary => |be| {
                try self.bind_expr(be.left.*);
                try self.bind_expr(be.right.*);
            },
            .unary => |ue| {
                try self.bind_expr(ue.operand.*);
            },
            .call => |ce| {
                // 関数名を参照として登録
                try self.add_reference(ce.loc.offset, ce.callee);
                for (ce.args) |arg| try self.bind_expr(arg);
            },
            .method_call => |mc| {
                try self.bind_expr(mc.object.*);
                for (mc.args) |arg| try self.bind_expr(arg);
            },
            .field_access => |fa| {
                try self.bind_expr(fa.object.*);
            },
            .index_access => |ia| {
                try self.bind_expr(ia.object.*);
                try self.bind_expr(ia.index.*);
            },
            .assignment => |a| {
                try self.bind_expr(a.target.*);
                try self.bind_expr(a.value.*);
            },
            .new_expr => |ne| {
                for (ne.args) |arg| try self.bind_expr(arg);
            },
            .cast_expr => |ce| {
                try self.bind_expr(ce.operand.*);
            },
            .ternary => |te| {
                try self.bind_expr(te.condition.*);
                try self.bind_expr(te.then_expr.*);
                try self.bind_expr(te.else_expr.*);
            },
            .instanceof => |ie| {
                try self.bind_expr(ie.operand.*);
            },
            .grouped => |inner| {
                try self.bind_expr(inner.*);
            },
        }
    }

    // -----------------------------------------------------------------------
    // Param 位置解決
    // -----------------------------------------------------------------------

};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

const TestCtx = struct {
    result: BindResult,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestCtx) void {
        std.testing.allocator.free(self.result.symbols);
        std.testing.allocator.free(self.result.references);
        for (self.result.scopes) |*s| {
            s.symbol_ids.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(self.result.scopes);
        self.arena.deinit();
    }
};

fn bind_source(source: []const u8) !TestCtx {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const result = try bind(decls, tokens, source, std.testing.allocator);
    return .{ .result = result, .arena = arena };
}

fn find_symbol(result: *const BindResult, name: []const u8) ?*const Symbol {
    for (result.symbols) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn count_symbols_by_kind(result: *const BindResult, kind: SymbolKind) usize {
    var count: usize = 0;
    for (result.symbols) |s| {
        if (s.kind == kind) count += 1;
    }
    return count;
}

// -- シンボル生成テスト --

test "creates symbol for class" {
    var ctx = try bind_source("public class Foo {}");
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "Foo");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.class, sym.?.kind);
}

test "creates symbol for method with return type" {
    var ctx = try bind_source("public class Foo { public String getName() { return null; } }");
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "getName");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.method, sym.?.kind);
    try std.testing.expect(sym.?.type_name != null);
    try std.testing.expectEqualStrings("String", sym.?.type_name.?);
}

test "creates symbol for field with type" {
    var ctx = try bind_source("public class Foo { private Integer count; }");
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "count");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.field, sym.?.kind);
    try std.testing.expectEqualStrings("Integer", sym.?.type_name.?);
}

test "creates symbol for parameter" {
    var ctx = try bind_source("public class Foo { public void run(String name) {} }");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 1), count_symbols_by_kind(&ctx.result, .parameter));
    const sym = find_symbol(&ctx.result, "name");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.parameter, sym.?.kind);
    try std.testing.expectEqualStrings("String", sym.?.type_name.?);
}

test "creates symbol for local variable with type" {
    var ctx = try bind_source("public class Foo { public void run() { Integer x = 1; } }");
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "x");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.local_variable, sym.?.kind);
    try std.testing.expectEqualStrings("Integer", sym.?.type_name.?);
}

test "creates symbol for enum values" {
    var ctx = try bind_source("public enum Season { SPRING, SUMMER }");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 2), count_symbols_by_kind(&ctx.result, .enum_value));
}

// -- 参照追跡テスト --

test "identifier creates reference to variable" {
    var ctx = try bind_source(
        "public class Foo { public void run() { Integer x = 1; Integer y = x; } }",
    );
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "x");
    try std.testing.expect(sym != null);
    // x の定義 + 使用 = 2 references
    const refs = try filter_references(&ctx.result, sym.?.id, std.testing.allocator);
    defer std.testing.allocator.free(refs);

    try std.testing.expectEqual(@as(usize, 2), refs.len);
}

test "references sorted by offset" {
    var ctx = try bind_source(
        "public class Foo { public void run() { Integer x = 1; Integer y = x; } }",
    );
    defer ctx.deinit();

    for (ctx.result.references[1..], 0..) |ref, i| {
        _ = i;
        try std.testing.expect(ref.offset >= ctx.result.references[0].offset);
    }
}

// -- Position lookup テスト --

test "symbol_at_position finds variable" {
    const source = "public class Foo { public void run() { Integer x = 1; } }";
    var ctx = try bind_source(source);
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "x");
    try std.testing.expect(sym != null);
    const found = symbol_at_position(&ctx.result, sym.?.loc.offset);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("x", found.?.name);
}

test "symbol_at_position returns null between tokens" {
    const source = "public class Foo {}";
    var ctx = try bind_source(source);
    defer ctx.deinit();
    // offset 6 = space between 'public' and 'class'
    const found = symbol_at_position(&ctx.result, 6);
    try std.testing.expect(found == null);
}

test "current class ignores closed inner class" {
    const source =
        \\public class Foo {
        \\    public class Inner {
        \\        private void innerOnly() {}
        \\    }
        \\    public void run() {
        \\        this.recordCount = 1;
        \\        helper();
        \\    }
        \\    private Integer recordCount;
        \\    private void helper() {}
        \\}
    ;
    var ctx = try bind_source(source);
    defer ctx.deinit();

    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "recordCount = 1").?);
    const owner_id = current_class_symbol_id(&ctx.result, offset) orelse unreachable;
    try std.testing.expectEqualStrings("Foo", ctx.result.symbols[owner_id].name);

    const field = resolve_current_class_member(&ctx.result, offset, "recordCount") orelse
        unreachable;
    try std.testing.expectEqual(SymbolKind.field, field.kind);
}

// -- Edge case テスト --

test "empty class" {
    var ctx = try bind_source("public class Empty {}");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 1), ctx.result.symbols.len);
    try std.testing.expectEqualStrings("Empty", ctx.result.symbols[0].name);
}

test "multiple classes in file" {
    var ctx = try bind_source("public class A {} public class B {}");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 2), count_symbols_by_kind(&ctx.result, .class));
}

test "trigger declaration" {
    var ctx = try bind_source("trigger MyTrigger on Account (before insert) { }");
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "MyTrigger");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.trigger, sym.?.kind);
}

test "interface declaration" {
    var ctx = try bind_source("public interface Runnable { void run(); }");
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "Runnable");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.interface, sym.?.kind);
}

test "for-each variable scoped to loop body" {
    var ctx = try bind_source(
        "public class Foo { public void run() { for (Account a : accs) { } } }",
    );
    defer ctx.deinit();

    const sym = find_symbol(&ctx.result, "a");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.for_each_variable, sym.?.kind);
    try std.testing.expectEqualStrings("Account", sym.?.type_name.?);
}

test "constructor with params" {
    var ctx = try bind_source("public class Foo { public Foo(String name) {} }");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 1), count_symbols_by_kind(&ctx.result, .constructor));
    const param = find_symbol(&ctx.result, "name");
    try std.testing.expect(param != null);
    try std.testing.expectEqual(SymbolKind.parameter, param.?.kind);
}
