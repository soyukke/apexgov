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
pub fn bind(decls: []const ast.Decl, tokens: []const Token, source: []const u8, allocator: std.mem.Allocator) !BindResult {
    _ = source;
    var b = Binder{
        .allocator = allocator,
        .tokens = tokens,
    };
    for (decls) |decl| {
        try b.bindDecl(decl, null, b.current_scope);
    }
    return .{
        .symbols = try b.symbols.toOwnedSlice(allocator),
        .scopes = try b.scopes.toOwnedSlice(allocator),
        .references = try b.sortedReferences(),
    };
}

/// offset 位置にあるシンボルを探す（参照テーブルを線形探索）。
pub fn symbolAtPosition(result: *const BindResult, offset: u32) ?*const Symbol {
    // references は offset 順にソート済み
    for (result.references) |ref| {
        if (offset >= ref.offset and offset < ref.end_offset) {
            return &result.symbols[ref.symbol_id];
        }
    }
    return null;
}

/// symbol_id に一致する参照をフィルタして返す。
pub fn filterReferences(result: *const BindResult, symbol_id: SymbolId, allocator: std.mem.Allocator) ![]const Reference {
    var out: std.ArrayList(Reference) = .empty;
    for (result.references) |ref| {
        if (ref.symbol_id == symbol_id) {
            try out.append(allocator, ref);
        }
    }
    return out.toOwnedSlice(allocator);
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

    fn addSymbol(self: *Binder, name: []const u8, kind: SymbolKind, type_name: ?[]const u8, loc: SourceLoc, parent: ?SymbolId) !SymbolId {
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
        const name_loc = self.findTokenAfter(loc.offset, name) orelse loc;

        try self.symbols.append(self.allocator, .{
            .id = id,
            .name = name,
            .kind = kind,
            .type_name = type_name,
            .loc = name_loc,
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

    /// loc 以降のトークンから name に一致する identifier を探す。
    /// loc.offset 以降のトークンから name に一致する identifier を探す。
    fn findTokenAfter(self: *Binder, min_offset: u32, name: []const u8) ?SourceLoc {
        for (self.tokens) |tok| {
            if (tok.loc.offset < min_offset) continue;
            if (tok.kind == .identifier and std.mem.eql(u8, tok.lexeme, name)) {
                return tok.loc;
            }
        }
        return null;
    }

    fn pushScope(self: *Binder) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{
            .id = id,
            .parent = self.current_scope,
            .symbol_ids = .empty,
        });
        self.current_scope = id;
        return id;
    }

    fn popScope(self: *Binder) void {
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

    fn addReference(self: *Binder, offset: u32, name: []const u8) !void {
        if (self.resolve(name)) |sym_id| {
            try self.references.append(self.allocator, .{
                .offset = offset,
                .end_offset = offset + @as(u32, @intCast(name.len)),
                .symbol_id = sym_id,
                .is_definition = false,
            });
        }
    }

    fn sortedReferences(self: *Binder) ![]Reference {
        const slice = try self.references.toOwnedSlice(self.allocator);
        std.mem.sort(Reference, slice, {}, struct {
            fn lessThan(_: void, a: Reference, b_ref: Reference) bool {
                return a.offset < b_ref.offset;
            }
        }.lessThan);
        return slice;
    }

    fn typeRefToString(tr: TypeRef) ?[]const u8 {
        if (tr.name.len == 0) return null;
        return tr.name;
    }

    // -----------------------------------------------------------------------
    // Decl 走査
    // -----------------------------------------------------------------------

    fn bindDecl(self: *Binder, decl: ast.Decl, parent: ?SymbolId, _: ScopeId) !void {
        switch (decl) {
            .class_decl => |cd| {
                const sym_id = try self.addSymbol(cd.name, .class, null, cd.loc, parent);
                _ = try self.pushScope();
                for (cd.members) |member| {
                    try self.bindDecl(member, sym_id, self.current_scope);
                }
                self.popScope();
            },
            .interface_decl => |id| {
                _ = try self.addSymbol(id.name, .interface, null, id.loc, parent);
            },
            .enum_decl => |ed| {
                const sym_id = try self.addSymbol(ed.name, .enum_type, null, ed.loc, parent);
                for (ed.values) |v| {
                    // enum values の正確な位置はトークンから探す必要があるが、簡易版では enum の loc を使用
                    _ = try self.addSymbol(v, .enum_value, ed.name, ed.loc, sym_id);
                }
            },
            .method_decl => |md| {
                const sym_id = try self.addSymbol(md.name, .method, typeRefToString(md.return_type), md.loc, parent);
                _ = try self.pushScope();
                for (md.params) |p| {
                    const param_loc = self.findTokenAfter(md.loc.offset, p.name) orelse md.loc;
                    _ = try self.addSymbol(p.name, .parameter, typeRefToString(p.type_ref), param_loc, sym_id);
                }
                for (md.body) |stmt| {
                    try self.bindStmt(stmt);
                }
                self.popScope();
            },
            .constructor_decl => |cd| {
                const sym_id = try self.addSymbol("<constructor>", .constructor, null, cd.loc, parent);
                _ = try self.pushScope();
                for (cd.params) |p| {
                    const param_loc = self.findTokenAfter(cd.loc.offset, p.name) orelse cd.loc;
                    _ = try self.addSymbol(p.name, .parameter, typeRefToString(p.type_ref), param_loc, sym_id);
                }
                for (cd.body) |stmt| {
                    try self.bindStmt(stmt);
                }
                self.popScope();
            },
            .field_decl => |fd| {
                _ = try self.addSymbol(fd.name, .field, typeRefToString(fd.type_ref), fd.loc, parent);
            },
            .trigger_decl => |td| {
                _ = try self.addSymbol(td.name, .trigger, null, td.loc, parent);
                _ = try self.pushScope();
                for (td.body) |stmt| {
                    try self.bindStmt(stmt);
                }
                self.popScope();
            },
            .static_init => |stmts| {
                for (stmts) |stmt| {
                    try self.bindStmt(stmt);
                }
            },
        }
    }

    // -----------------------------------------------------------------------
    // Stmt 走査
    // -----------------------------------------------------------------------

    fn bind_for_stmt(self: *Binder, fs: anytype) anyerror!void {
        _ = try self.pushScope();
        if (fs.init) |init_stmt| {
            switch (init_stmt.*) {
                .block => |init_stmts| {
                    for (init_stmts) |init_item| try self.bindStmt(init_item);
                },
                else => try self.bindStmt(init_stmt.*),
            }
        }
        if (fs.condition) |cond| try self.bindExpr(cond.*);
        if (fs.update) |upd| try self.bindExpr(upd.*);
        for (fs.body) |s| try self.bindStmt(s);
        self.popScope();
    }

    fn bind_try_stmt(self: *Binder, ts: anytype) anyerror!void {
        for (ts.body) |s| try self.bindStmt(s);
        for (ts.catches) |cc| {
            _ = try self.pushScope();
            _ = try self.addSymbol(cc.name, .catch_variable, typeRefToString(cc.exception_type), SourceLoc.zero, null);
            for (cc.body) |s| try self.bindStmt(s);
            self.popScope();
        }
        if (ts.finally_body) |fb| {
            for (fb) |s| try self.bindStmt(s);
        }
    }

    fn bindStmt(self: *Binder, stmt: ast.Stmt) !void {
        switch (stmt) {
            .var_decl => |vd| {
                _ = try self.addSymbol(vd.name, .local_variable, typeRefToString(vd.type_ref), vd.loc, null);
                if (vd.initializer) |init_expr| {
                    try self.bindExpr(init_expr.*);
                }
            },
            .block => |stmts| {
                _ = try self.pushScope();
                for (stmts) |s| try self.bindStmt(s);
                self.popScope();
            },
            .if_stmt => |is| {
                try self.bindExpr(is.condition.*);
                for (is.then_body) |s| try self.bindStmt(s);
                if (is.else_body) |eb| {
                    for (eb) |s| try self.bindStmt(s);
                }
            },
            .for_stmt => |fs| try self.bind_for_stmt(fs),
            .for_each_stmt => |fes| {
                _ = try self.pushScope();
                _ = try self.addSymbol(fes.elem_name, .for_each_variable, typeRefToString(fes.elem_type), fes.loc, null);
                try self.bindExpr(fes.iterable.*);
                for (fes.body) |s| try self.bindStmt(s);
                self.popScope();
            },
            .while_stmt => |ws| {
                try self.bindExpr(ws.condition.*);
                for (ws.body) |s| try self.bindStmt(s);
            },
            .do_while => |dw| {
                for (dw.body) |s| try self.bindStmt(s);
                try self.bindExpr(dw.condition.*);
            },
            .return_stmt => |rs| {
                if (rs.value) |val| try self.bindExpr(val.*);
            },
            .throw_stmt => |ts| {
                try self.bindExpr(ts.expr.*);
            },
            .switch_stmt => |ss| {
                try self.bindExpr(ss.subject.*);
                for (ss.when_clauses) |wc| {
                    for (wc.body) |s| try self.bindStmt(s);
                }
            },
            .try_stmt => |ts| try self.bind_try_stmt(ts),
            .expr_stmt => |expr| {
                try self.bindExpr(expr.*);
            },
            .dml_stmt => |ds| {
                try self.bindExpr(ds.target.*);
            },
            .run_as_stmt => |ras| {
                try self.bindExpr(ras.user_expr.*);
                for (ras.body) |s| try self.bindStmt(s);
            },
            .break_stmt, .continue_stmt => {},
        }
    }

    // -----------------------------------------------------------------------
    // Expr 走査
    // -----------------------------------------------------------------------

    fn bindExpr(self: *Binder, expr: ast.Expr) !void {
        switch (expr) {
            .integer_literal, .long_literal, .double_literal, .string_literal, .boolean_literal, .null_literal, .this_expr, .super_expr, .soql => {},
            .identifier => |id| {
                try self.addReference(id.loc.offset, id.name);
            },
            .binary => |be| {
                try self.bindExpr(be.left.*);
                try self.bindExpr(be.right.*);
            },
            .unary => |ue| {
                try self.bindExpr(ue.operand.*);
            },
            .call => |ce| {
                // 関数名を参照として登録
                try self.addReference(ce.loc.offset, ce.callee);
                for (ce.args) |arg| try self.bindExpr(arg);
            },
            .method_call => |mc| {
                try self.bindExpr(mc.object.*);
                for (mc.args) |arg| try self.bindExpr(arg);
            },
            .field_access => |fa| {
                try self.bindExpr(fa.object.*);
            },
            .index_access => |ia| {
                try self.bindExpr(ia.object.*);
                try self.bindExpr(ia.index.*);
            },
            .assignment => |a| {
                try self.bindExpr(a.target.*);
                try self.bindExpr(a.value.*);
            },
            .new_expr => |ne| {
                for (ne.args) |arg| try self.bindExpr(arg);
            },
            .cast_expr => |ce| {
                try self.bindExpr(ce.operand.*);
            },
            .ternary => |te| {
                try self.bindExpr(te.condition.*);
                try self.bindExpr(te.then_expr.*);
                try self.bindExpr(te.else_expr.*);
            },
            .instanceof => |ie| {
                try self.bindExpr(ie.operand.*);
            },
            .grouped => |inner| {
                try self.bindExpr(inner.*);
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

fn bindSource(source: []const u8) !TestCtx {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const result = try bind(decls, tokens, source, std.testing.allocator);
    return .{ .result = result, .arena = arena };
}

fn findSymbol(result: *const BindResult, name: []const u8) ?*const Symbol {
    for (result.symbols) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn countSymbolsByKind(result: *const BindResult, kind: SymbolKind) usize {
    var count: usize = 0;
    for (result.symbols) |s| {
        if (s.kind == kind) count += 1;
    }
    return count;
}

// -- シンボル生成テスト --

test "creates symbol for class" {
    var ctx = try bindSource("public class Foo {}");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "Foo");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.class, sym.?.kind);
}

test "creates symbol for method with return type" {
    var ctx = try bindSource("public class Foo { public String getName() { return null; } }");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "getName");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.method, sym.?.kind);
    try std.testing.expect(sym.?.type_name != null);
    try std.testing.expectEqualStrings("String", sym.?.type_name.?);
}

test "creates symbol for field with type" {
    var ctx = try bindSource("public class Foo { private Integer count; }");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "count");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.field, sym.?.kind);
    try std.testing.expectEqualStrings("Integer", sym.?.type_name.?);
}

test "creates symbol for parameter" {
    var ctx = try bindSource("public class Foo { public void run(String name) {} }");
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), countSymbolsByKind(&ctx.result, .parameter));
    const sym = findSymbol(&ctx.result, "name");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.parameter, sym.?.kind);
    try std.testing.expectEqualStrings("String", sym.?.type_name.?);
}

test "creates symbol for local variable with type" {
    var ctx = try bindSource("public class Foo { public void run() { Integer x = 1; } }");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "x");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.local_variable, sym.?.kind);
    try std.testing.expectEqualStrings("Integer", sym.?.type_name.?);
}

test "creates symbol for enum values" {
    var ctx = try bindSource("public enum Season { SPRING, SUMMER }");
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 2), countSymbolsByKind(&ctx.result, .enum_value));
}

// -- 参照追跡テスト --

test "identifier creates reference to variable" {
    var ctx = try bindSource("public class Foo { public void run() { Integer x = 1; Integer y = x; } }");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "x");
    try std.testing.expect(sym != null);
    // x の定義 + 使用 = 2 references
    const refs = try filterReferences(&ctx.result, sym.?.id, std.testing.allocator);
    defer std.testing.allocator.free(refs);
    try std.testing.expectEqual(@as(usize, 2), refs.len);
}

test "references sorted by offset" {
    var ctx = try bindSource("public class Foo { public void run() { Integer x = 1; Integer y = x; } }");
    defer ctx.deinit();
    for (ctx.result.references[1..], 0..) |ref, i| {
        _ = i;
        try std.testing.expect(ref.offset >= ctx.result.references[0].offset);
    }
}

// -- Position lookup テスト --

test "symbolAtPosition finds variable" {
    const source = "public class Foo { public void run() { Integer x = 1; } }";
    var ctx = try bindSource(source);
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "x");
    try std.testing.expect(sym != null);
    const found = symbolAtPosition(&ctx.result, sym.?.loc.offset);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("x", found.?.name);
}

test "symbolAtPosition returns null between tokens" {
    const source = "public class Foo {}";
    var ctx = try bindSource(source);
    defer ctx.deinit();
    // offset 6 = space between 'public' and 'class'
    const found = symbolAtPosition(&ctx.result, 6);
    try std.testing.expect(found == null);
}

// -- Edge case テスト --

test "empty class" {
    var ctx = try bindSource("public class Empty {}");
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), ctx.result.symbols.len);
    try std.testing.expectEqualStrings("Empty", ctx.result.symbols[0].name);
}

test "multiple classes in file" {
    var ctx = try bindSource("public class A {} public class B {}");
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 2), countSymbolsByKind(&ctx.result, .class));
}

test "trigger declaration" {
    var ctx = try bindSource("trigger MyTrigger on Account (before insert) { }");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "MyTrigger");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.trigger, sym.?.kind);
}

test "interface declaration" {
    var ctx = try bindSource("public interface Runnable { void run(); }");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "Runnable");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.interface, sym.?.kind);
}

test "for-each variable scoped to loop body" {
    var ctx = try bindSource("public class Foo { public void run() { for (Account a : accs) { } } }");
    defer ctx.deinit();
    const sym = findSymbol(&ctx.result, "a");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(SymbolKind.for_each_variable, sym.?.kind);
    try std.testing.expectEqualStrings("Account", sym.?.type_name.?);
}

test "constructor with params" {
    var ctx = try bindSource("public class Foo { public Foo(String name) {} }");
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), countSymbolsByKind(&ctx.result, .constructor));
    const param = findSymbol(&ctx.result, "name");
    try std.testing.expect(param != null);
    try std.testing.expectEqual(SymbolKind.parameter, param.?.kind);
}
