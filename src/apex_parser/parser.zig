//! parser — 再帰下降パーサー。トークン列から AST を構築する。
//!
//! Pratt parsing で演算子優先度を処理。
//! Phase 1: 式、変数宣言、return、if/for/while、クラス/メソッド宣言。

const std = @import("std");
const types = @import("types.zig");
const ast = @import("ast.zig");
const Token = types.Token;
const TokenKind = types.TokenKind;
const TypeRef = types.TypeRef;
const SourceLoc = types.SourceLoc;

/// パース結果（AST + 診断情報）。
pub const ParseResult = struct {
    decls: []ast.Decl,
    diagnostics: []types.ParseDiagnostic,
};

pub fn parse(tokens: []const Token, arena: std.mem.Allocator) ![]ast.Decl {
    var p = Parser{ .tokens = tokens, .arena = arena };
    return p.parse_program();
}

/// 診断情報付きでパースする。LSP 向け。
pub fn parse_with_diagnostics(tokens: []const Token, arena: std.mem.Allocator) !ParseResult {
    var p = Parser{ .tokens = tokens, .arena = arena };
    const decls = try p.parse_program();
    return .{
        .decls = decls,
        .diagnostics = try p.diagnostics.toOwnedSlice(arena),
    };
}

pub fn parse_expr(tokens: []const Token, arena: std.mem.Allocator) !*ast.Expr {
    var p = Parser{ .tokens = tokens, .arena = arena };
    return p.expression();
}

const Parser = struct {
    tokens: []const Token,
    arena: std.mem.Allocator,
    pos: u32 = 0,
    diagnostics: std.ArrayListUnmanaged(types.ParseDiagnostic) = .empty,

    // -----------------------------------------------------------------------
    // トップレベル
    // -----------------------------------------------------------------------

    fn parse_program(self: *Parser) ![]ast.Decl {
        var decls: std.ArrayListUnmanaged(ast.Decl) = .empty;
        while (!self.at_end()) {
            // skip annotations at top level
            var annotations: std.ArrayListUnmanaged([]const u8) = .empty;
            while (self.check(.annotation)) {
                try annotations.append(self.arena, self.current().lexeme);
                self.pos += 1;
            }
            // skip modifiers before class/interface/enum
            const mods = self.parse_modifiers();

            if (self.check(.class_kw)) {
                try decls.append(self.arena, .{ .class_decl = try self.parse_class_decl(mods, try annotations.toOwnedSlice(self.arena)) });
            } else if (self.check(.interface_kw)) {
                try decls.append(
                    self.arena,
                    .{ .interface_decl = try self.parse_interface_decl(mods) },
                );
            } else if (self.check(.enum_kw)) {
                try decls.append(self.arena, .{ .enum_decl = try self.parse_enum_decl(mods) });
            } else if (self.check(.trigger_kw)) {
                try decls.append(self.arena, .{ .trigger_decl = try self.parse_trigger_decl() });
            } else {
                // skip unknown token
                self.pos += 1;
            }
        }
        return decls.toOwnedSlice(self.arena);
    }

    fn parse_class_decl(
        self: *Parser,
        mods: ast.Modifiers,
        annotations: [][]const u8,
    ) anyerror!*ast.ClassDecl {
        const loc = self.current_loc();
        self.pos += 1; // skip 'class'
        const name = try self.expect_identifier();

        // sharing mode was parsed as modifiers — detect from preceding tokens
        const sharing: ast.SharingMode = .inherited;
        if (mods.is_abstract) {
            // could be abstract class, sharing inherited
        }
        // We check sharing by looking at modifier tokens already consumed
        // For now, sharing is handled by modifiers parse detecting 'with sharing'

        var super_class: ?TypeRef = null;
        if (self.match_kind(.extends_kw)) {
            super_class = try self.parse_type_ref();
        }

        var interfaces: std.ArrayListUnmanaged(TypeRef) = .empty;
        if (self.match_kind(.implements_kw)) {
            try interfaces.append(self.arena, try self.parse_type_ref());
            while (self.match_kind(.comma)) {
                try interfaces.append(self.arena, try self.parse_type_ref());
            }
        }

        try self.expect(.lbrace);
        const members = try self.parse_class_body();
        try self.expect(.rbrace);

        const decl = try self.arena.create(ast.ClassDecl);
        decl.* = .{
            .name = name,
            .modifiers = mods,
            .sharing = sharing,
            .super_class = super_class,
            .interfaces = try interfaces.toOwnedSlice(self.arena),
            .members = members,
            .annotations = annotations,
            .loc = loc,
        };
        return decl;
    }

    fn parse_interface_decl(self: *Parser, mods: ast.Modifiers) !*ast.InterfaceDecl {
        const loc = self.current_loc();
        self.pos += 1; // skip 'interface'
        const name = try self.expect_identifier();

        var extends: std.ArrayListUnmanaged(TypeRef) = .empty;
        if (self.match_kind(.extends_kw)) {
            try extends.append(self.arena, try self.parse_type_ref());
            while (self.match_kind(.comma)) {
                try extends.append(self.arena, try self.parse_type_ref());
            }
        }

        try self.expect(.lbrace);
        // For now, skip interface body
        var depth: u32 = 1;
        while (!self.at_end() and depth > 0) {
            if (self.check(.lbrace)) depth += 1;
            if (self.check(.rbrace)) depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        if (self.check(.rbrace)) self.pos += 1;

        const decl = try self.arena.create(ast.InterfaceDecl);
        decl.* = .{
            .name = name,
            .modifiers = mods,
            .extends = try extends.toOwnedSlice(self.arena),
            .loc = loc,
        };
        return decl;
    }

    fn parse_enum_decl(self: *Parser, mods: ast.Modifiers) !*ast.EnumDecl {
        const loc = self.current_loc();
        self.pos += 1; // skip 'enum'
        const name = try self.expect_identifier();

        try self.expect(.lbrace);
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.at_end() and !self.check(.rbrace)) {
            if (self.check(.identifier)) {
                try values.append(self.arena, self.current().lexeme);
                self.pos += 1;
                _ = self.match_kind(.comma);
            } else {
                self.pos += 1;
            }
        }
        try self.expect(.rbrace);

        const decl = try self.arena.create(ast.EnumDecl);
        decl.* = .{
            .name = name,
            .modifiers = mods,
            .values = try values.toOwnedSlice(self.arena),
            .loc = loc,
        };
        return decl;
    }

    fn parse_trigger_decl(self: *Parser) !*ast.TriggerDecl {
        const loc = self.current_loc();
        self.pos += 1; // skip 'trigger'
        const name = try self.expect_identifier();

        // skip 'on'
        if (self.check(.identifier) and std.ascii.eqlIgnoreCase(self.current().lexeme, "on")) {
            self.pos += 1;
        }

        // object name
        const object_name = try self.expect_identifier();

        // parse event list: (before insert, after insert, ...)
        try self.expect(.lparen);
        var events: std.ArrayListUnmanaged(ast.TriggerEvent) = .empty;
        while (!self.at_end() and !self.check(.rparen)) {
            // Parse "before"/"after" + "insert"/"update"/"delete"/"undelete"
            if (self.check(.identifier)) {
                const timing = self.current().lexeme;
                self.pos += 1;
                // The DML keyword may be a keyword token or identifier
                const op_lexeme = if (!self.at_end()) self.current().lexeme else "";
                self.pos += 1;

                if (std.ascii.eqlIgnoreCase(timing, "before")) {
                    if (std.ascii.eqlIgnoreCase(op_lexeme, "insert")) {
                        try events.append(self.arena, .before_insert);
                    } else if (std.ascii.eqlIgnoreCase(op_lexeme, "update")) {
                        try events.append(self.arena, .before_update);
                    } else if (std.ascii.eqlIgnoreCase(op_lexeme, "delete")) {
                        try events.append(self.arena, .before_delete);
                    }
                } else if (std.ascii.eqlIgnoreCase(timing, "after")) {
                    if (std.ascii.eqlIgnoreCase(op_lexeme, "insert")) {
                        try events.append(self.arena, .after_insert);
                    } else if (std.ascii.eqlIgnoreCase(op_lexeme, "update")) {
                        try events.append(self.arena, .after_update);
                    } else if (std.ascii.eqlIgnoreCase(op_lexeme, "delete")) {
                        try events.append(self.arena, .after_delete);
                    } else if (std.ascii.eqlIgnoreCase(op_lexeme, "undelete")) {
                        try events.append(self.arena, .after_undelete);
                    }
                }
            } else {
                self.pos += 1;
            }
            _ = self.match_kind(.comma);
        }
        try self.expect(.rparen);

        // parse body { ... }
        try self.expect(.lbrace);
        const body = try self.parse_block();
        try self.expect(.rbrace);

        const decl = try self.arena.create(ast.TriggerDecl);
        decl.* = .{
            .name = name,
            .object_name = object_name,
            .events = try events.toOwnedSlice(self.arena),
            .body = body,
            .loc = loc,
        };
        return decl;
    }

    fn parse_class_body(self: *Parser) anyerror![]ast.Decl {
        var members: std.ArrayListUnmanaged(ast.Decl) = .empty;
        while (!self.at_end() and !self.check(.rbrace)) {
            var annotations: std.ArrayListUnmanaged([]const u8) = .empty;
            while (self.check(.annotation)) {
                const ann_lexeme = self.current().lexeme;
                self.pos += 1;
                // Capture annotation params like @IsTest(seeAllData=true)
                if (self.match_kind(.lparen)) {
                    // Build full annotation string with params
                    const param_start = self.pos;
                    var depth: u32 = 1;
                    while (!self.at_end() and depth > 0) {
                        if (self.check(.lparen)) depth += 1;
                        if (self.check(.rparen)) {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                        self.pos += 1;
                    }
                    const param_end = self.pos;
                    try self.expect(.rparen);
                    // Reconstruct annotation with params
                    var param_buf: std.ArrayListUnmanaged(u8) = .empty;
                    try param_buf.appendSlice(self.arena, ann_lexeme);
                    try param_buf.append(self.arena, '(');
                    for (self.tokens[param_start..param_end]) |tok| {
                        try param_buf.appendSlice(self.arena, tok.lexeme);
                    }
                    try param_buf.append(self.arena, ')');
                    try annotations.append(self.arena, param_buf.items);
                } else {
                    try annotations.append(self.arena, ann_lexeme);
                }
            }

            const mods = self.parse_modifiers();

            if (self.check(.class_kw)) {
                try members.append(self.arena, .{ .class_decl = try self.parse_class_decl(mods, try annotations.toOwnedSlice(self.arena)) });
            } else if (self.check(.interface_kw)) {
                try members.append(
                    self.arena,
                    .{ .interface_decl = try self.parse_interface_decl(mods) },
                );
            } else if (self.check(.enum_kw)) {
                try members.append(self.arena, .{ .enum_decl = try self.parse_enum_decl(mods) });
            } else if (self.check(.lbrace)) {
                // static initializer block — parse body
                self.pos += 1;
                const body = try self.parse_block();
                try self.expect(.rbrace);
                try members.append(self.arena, .{ .static_init = body });
            } else {
                // method or field: Type name ( ... ) { ... } or Type name ;/=
                const member = try self.parse_method_or_field(
                    mods,
                    try annotations.toOwnedSlice(self.arena),
                );
                try members.append(self.arena, member);
            }
        }
        return members.toOwnedSlice(self.arena);
    }

    fn parse_method_body(
        self: *Parser,
        mods: ast.Modifiers,
        type_ref: TypeRef,
        name: []const u8,
        annotations: [][]const u8,
        loc: SourceLoc,
    ) anyerror!ast.Decl {
        const params = try self.parse_params();
        try self.expect(.rparen);
        var body: []ast.Stmt = &.{};
        if (self.match_kind(.lbrace)) {
            body = try self.parse_block();
            try self.expect(.rbrace);
        } else {
            // abstract method or interface method
            _ = self.match_kind(.semicolon);
        }

        const decl = try self.arena.create(ast.MethodDecl);
        decl.* = .{
            .name = name,
            .modifiers = mods,
            .return_type = type_ref,
            .params = params,
            .body = body,
            .annotations = annotations,
            .loc = loc,
        };
        return .{ .method_decl = decl };
    }

    fn parse_property_accessors(self: *Parser, getter: *?[]ast.Stmt, setter: *?[]ast.Stmt) !void {
        while (!self.at_end() and !self.check(.rbrace)) {
            // Skip modifiers like 'private', 'public' before get/set
            while (self.check(.private_kw) or self.check(.public_kw) or self.check(.protected_kw)) {
                self.pos += 1;
            }
            if (!self.check(.identifier)) {
                self.pos += 1;
                continue;
            }
            const accessor = self.current().lexeme;
            self.pos += 1;
            if (std.ascii.eqlIgnoreCase(accessor, "get")) {
                if (self.match_kind(.lbrace)) {
                    getter.* = try self.parse_block();
                    try self.expect(.rbrace);
                } else {
                    _ = self.match_kind(.semicolon);
                }
            } else if (std.ascii.eqlIgnoreCase(accessor, "set")) {
                if (self.match_kind(.lbrace)) {
                    setter.* = try self.parse_block();
                    try self.expect(.rbrace);
                } else {
                    _ = self.match_kind(.semicolon);
                }
            }
        }
        try self.expect(.rbrace);
    }

    fn parse_field_initializer_and_tail(self: *Parser, initializer: *?*ast.Expr) !void {
        if (self.match_kind(.assign)) {
            initializer.* = try self.expression();
        }
        // Handle comma-separated field declarations: Type a, b, c;
        while (self.match_kind(.comma)) {
            _ = try self.expect_identifier();
            if (self.match_kind(.assign)) {
                _ = try self.expression();
            }
        }
        _ = self.match_kind(.semicolon);
    }

    fn parse_method_or_field(
        self: *Parser,
        mods: ast.Modifiers,
        annotations: [][]const u8,
    ) anyerror!ast.Decl {
        const loc = self.current_loc();

        // Check for constructor: ClassName(
        // We need to look ahead: if current is identifier and next is lparen, it's a constructor
        if (self.check(.identifier) and self.peek_kind(1) == .lparen) {
            return self.parse_constructor(mods, loc);
        }

        const type_ref = try self.parse_type_ref();

        // After type, if next is ( then it could be constructor with return type being class name
        if (self.check(.lparen)) {
            return self.parse_constructor(mods, loc);
        }

        // Method/field name — keywords like 'when', 'with' can be member names in Apex
        const name = try self.expect_identifier_or_keyword();

        // method: name followed by (
        if (self.match_kind(.lparen)) {
            return self.parse_method_body(mods, type_ref, name, annotations, loc);
        }

        // field or property
        var initializer: ?*ast.Expr = null;
        var getter_body: ?[]ast.Stmt = null;
        var setter_body: ?[]ast.Stmt = null;

        if (self.match_kind(.lbrace)) {
            try self.parse_property_accessors(&getter_body, &setter_body);
        } else {
            try self.parse_field_initializer_and_tail(&initializer);
        }

        const decl = try self.arena.create(ast.FieldDecl);
        decl.* = .{
            .name = name,
            .modifiers = mods,
            .type_ref = type_ref,
            .initializer = initializer,
            .getter_body = getter_body,
            .setter_body = setter_body,
            .loc = loc,
        };
        return .{ .field_decl = decl };
    }

    fn parse_constructor(self: *Parser, mods: ast.Modifiers, loc: SourceLoc) anyerror!ast.Decl {
        // skip constructor name (already positioned at it or past type)
        if (self.check(.identifier)) self.pos += 1;
        try self.expect(.lparen);
        const params = try self.parse_params();
        try self.expect(.rparen);
        try self.expect(.lbrace);
        const body = try self.parse_block();
        try self.expect(.rbrace);

        const decl = try self.arena.create(ast.ConstructorDecl);
        decl.* = .{
            .modifiers = mods,
            .params = params,
            .body = body,
            .loc = loc,
        };
        return .{ .constructor_decl = decl };
    }

    fn parse_params(self: *Parser) ![]ast.Param {
        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        if (self.check(.rparen)) return params.toOwnedSlice(self.arena);

        // Skip optional 'final' modifier on parameter
        _ = self.match_kind(.final_kw);
        try params.append(self.arena, .{
            .type_ref = try self.parse_type_ref(),
            .name = try self.expect_identifier(),
        });
        while (self.match_kind(.comma)) {
            _ = self.match_kind(.final_kw);
            try params.append(self.arena, .{
                .type_ref = try self.parse_type_ref(),
                .name = try self.expect_identifier(),
            });
        }
        return params.toOwnedSlice(self.arena);
    }

    // -----------------------------------------------------------------------
    // 文 (Statement)
    // -----------------------------------------------------------------------

    fn parse_block(self: *Parser) anyerror![]ast.Stmt {
        var stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        while (!self.at_end() and !self.check(.rbrace)) {
            try stmts.append(self.arena, try self.parse_stmt());
        }
        return stmts.toOwnedSlice(self.arena);
    }

    fn parse_stmt(self: *Parser) anyerror!ast.Stmt {
        const kind = self.current_kind();

        if (kind == .if_kw) return self.parse_if_stmt();
        if (kind == .for_kw) return self.parse_for_stmt();
        if (kind == .while_kw) return self.parse_while_stmt();
        if (kind == .do_kw) return self.parse_do_while_stmt();
        if (kind == .return_kw) return self.parse_return_stmt();
        if (kind == .break_kw) {
            self.pos += 1;
            _ = self.match_kind(.semicolon);
            return .break_stmt;
        }
        if (kind == .continue_kw) {
            self.pos += 1;
            _ = self.match_kind(.semicolon);
            return .continue_stmt;
        }
        if (kind == .switch_kw) return self.parse_switch_stmt();
        if (kind == .try_kw) return self.parse_try_stmt();
        if (kind == .throw_kw) return self.parse_throw_stmt();
        if (kind == .lbrace) return self.parse_block_stmt();

        // DML statements
        if (kind == .insert_kw or kind == .update_kw or kind == .upsert_kw or
            kind == .delete_kw or kind == .undelete_kw or kind == .merge_kw)
        {
            return self.parse_dml_stmt();
        }

        // 'final' local variable: final Type name = ...
        if (kind == .final_kw) {
            self.pos += 1; // skip 'final'
            if (self.looks_like_var_decl()) {
                return self.parse_var_decl_stmt();
            }
            // final not followed by var decl — treat as expression fallthrough
            self.pos -= 1;
        }

        // Variable declaration or expression statement
        // Heuristic: if it looks like Type name = ... or Type name ;
        if (self.looks_like_var_decl()) {
            return self.parse_var_decl_stmt();
        }

        // Expression statement
        const expr = try self.expression();

        // Handle System.runAs(user) { block } — scoped restricted user context
        if (self.check(.lbrace) and expr.* == .method_call) {
            const mc = expr.method_call;
            if (std.ascii.eqlIgnoreCase(mc.method, "runAs")) {
                self.pos += 1; // skip {
                const block_stmts = try self.parse_block();
                try self.expect(.rbrace);
                const run_as = try self.arena.create(ast.RunAsStmt);
                run_as.* = .{
                    .user_expr = if (mc.args.len > 0) &mc.args[0] else expr,
                    .body = block_stmts,
                };
                return .{ .run_as_stmt = run_as };
            }
        }

        _ = self.match_kind(.semicolon);
        return .{ .expr_stmt = expr };
    }

    fn parse_if_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'if'
        try self.expect(.lparen);
        const condition = try self.expression();
        try self.expect(.rparen);

        const then_body = try self.parse_single_or_block();

        var else_body: ?[]ast.Stmt = null;
        if (self.match_kind(.else_kw)) {
            else_body = try self.parse_single_or_block();
        }

        const stmt = try self.arena.create(ast.IfStmt);
        stmt.* = .{ .condition = condition, .then_body = then_body, .else_body = else_body, .loc = loc };
        return .{ .if_stmt = stmt };
    }

    fn parse_for_each_stmt(self: *Parser, loc: SourceLoc) !ast.Stmt {
        const elem_type = try self.parse_type_ref();
        const elem_name = try self.expect_identifier();
        try self.expect(.colon);
        const iterable = try self.expression();
        try self.expect(.rparen);
        const body = try self.parse_single_or_block();

        const stmt = try self.arena.create(ast.ForEachStmt);
        stmt.* = .{
            .elem_type = elem_type,
            .elem_name = elem_name,
            .iterable = iterable,
            .body = body,
            .loc = loc,
        };
        return .{ .for_each_stmt = stmt };
    }

    fn parse_for_var_decl_init(self: *Parser) !ast.Stmt {
        const type_ref = try self.parse_type_ref();
        var init_stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        while (true) {
            const decl_loc = self.current_loc();
            const name = try self.expect_identifier();
            var initializer: ?*ast.Expr = null;
            if (self.match_kind(.assign)) {
                initializer = try self.expression();
            }

            const decl = try self.arena.create(ast.VarDecl);
            decl.* = .{
                .type_ref = type_ref,
                .name = name,
                .initializer = initializer,
                .loc = decl_loc,
            };
            try init_stmts.append(self.arena, .{ .var_decl = decl });

            if (!self.match_kind(.comma)) break;
        }

        if (init_stmts.items.len == 1) return init_stmts.items[0];
        return .{ .block = try init_stmts.toOwnedSlice(self.arena) };
    }

    fn parse_for_init(self: *Parser) !?*ast.Stmt {
        if (self.check(.semicolon)) return null;
        const init_stmt = try self.arena.create(ast.Stmt);
        if (self.looks_like_var_decl()) {
            init_stmt.* = try self.parse_for_var_decl_init();
        } else {
            const expr = try self.expression();
            init_stmt.* = .{ .expr_stmt = expr };
        }
        return init_stmt;
    }

    fn parse_for_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'for'
        try self.expect(.lparen);

        // Detect for-each: Type name : expr
        if (self.looks_like_for_each()) return self.parse_for_each_stmt(loc);

        // Traditional for: init; condition; update
        const init = try self.parse_for_init();
        _ = self.match_kind(.semicolon);

        var condition: ?*ast.Expr = null;
        if (!self.check(.semicolon)) {
            condition = try self.expression();
        }
        _ = self.match_kind(.semicolon);

        var update: ?*ast.Expr = null;
        if (!self.check(.rparen)) {
            update = try self.expression();
        }
        try self.expect(.rparen);

        const body = try self.parse_single_or_block();

        const stmt = try self.arena.create(ast.ForStmt);
        stmt.* = .{
            .init = init,
            .condition = condition,
            .update = update,
            .body = body,
            .loc = loc,
        };
        return .{ .for_stmt = stmt };
    }

    fn parse_while_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'while'
        try self.expect(.lparen);
        const condition = try self.expression();
        try self.expect(.rparen);
        const body = try self.parse_single_or_block();

        const stmt = try self.arena.create(ast.WhileStmt);
        stmt.* = .{ .condition = condition, .body = body, .loc = loc };
        return .{ .while_stmt = stmt };
    }

    fn parse_do_while_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'do'
        try self.expect(.lbrace);
        const body = try self.parse_block();
        try self.expect(.rbrace);
        try self.expect(.while_kw);
        try self.expect(.lparen);
        const condition = try self.expression();
        try self.expect(.rparen);
        _ = self.match_kind(.semicolon);

        const stmt = try self.arena.create(ast.DoWhileStmt);
        stmt.* = .{ .body = body, .condition = condition, .loc = loc };
        return .{ .do_while = stmt };
    }

    fn parse_return_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'return'
        var value: ?*ast.Expr = null;
        if (!self.check(.semicolon) and !self.check(.rbrace)) {
            value = try self.expression();
        }
        _ = self.match_kind(.semicolon);

        const stmt = try self.arena.create(ast.ReturnStmt);
        stmt.* = .{ .value = value, .loc = loc };
        return .{ .return_stmt = stmt };
    }

    fn parse_switch_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'switch'

        // Apex: 'switch on expr { when ... }'
        // skip 'on' if present
        if (self.check(.identifier) and std.ascii.eqlIgnoreCase(self.current().lexeme, "on")) {
            self.pos += 1;
        }

        const subject = try self.expression();
        try self.expect(.lbrace);

        var clauses: std.ArrayListUnmanaged(ast.WhenClause) = .empty;
        while (!self.at_end() and !self.check(.rbrace)) {
            if (self.match_kind(.when_kw)) {
                if (self.check(.else_kw)) {
                    self.pos += 1;
                    try self.expect(.lbrace);
                    const body = try self.parse_block();
                    try self.expect(.rbrace);
                    try clauses.append(self.arena, .{ .pattern = .else_clause, .body = body });
                } else {
                    // when value1, value2 { ... }
                    // OR: when TypeName varName { ... } (type-binding pattern)
                    var values: std.ArrayListUnmanaged(ast.Expr) = .empty;
                    try values.append(self.arena, (try self.expression()).*);
                    // Type-binding pattern: when Ident Ident { — skip the variable name
                    if (self.check(.identifier) and self.peek_kind(1) == .lbrace) {
                        self.pos += 1; // skip variable name
                    } else {
                        while (self.match_kind(.comma)) {
                            try values.append(self.arena, (try self.expression()).*);
                        }
                    }
                    try self.expect(.lbrace);
                    const body = try self.parse_block();
                    try self.expect(.rbrace);
                    try clauses.append(self.arena, .{
                        .pattern = .{ .values = try values.toOwnedSlice(self.arena) },
                        .body = body,
                    });
                }
            } else {
                self.pos += 1; // skip unexpected
            }
        }
        try self.expect(.rbrace);

        const stmt = try self.arena.create(ast.SwitchStmt);
        stmt.* = .{ .subject = subject, .when_clauses = try clauses.toOwnedSlice(
            self.arena,
        ), .loc = loc };
        return .{ .switch_stmt = stmt };
    }

    fn parse_try_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'try'
        try self.expect(.lbrace);
        const body = try self.parse_block();
        try self.expect(.rbrace);

        var catches: std.ArrayListUnmanaged(ast.CatchClause) = .empty;
        while (self.match_kind(.catch_kw)) {
            try self.expect(.lparen);
            const exception_type = try self.parse_type_ref();
            const name = try self.expect_identifier();
            try self.expect(.rparen);
            try self.expect(.lbrace);
            const catch_body = try self.parse_block();
            try self.expect(.rbrace);
            try catches.append(self.arena, .{
                .exception_type = exception_type,
                .name = name,
                .body = catch_body,
            });
        }

        var finally_body: ?[]ast.Stmt = null;
        if (self.match_kind(.finally_kw)) {
            try self.expect(.lbrace);
            finally_body = try self.parse_block();
            try self.expect(.rbrace);
        }

        const stmt = try self.arena.create(ast.TryStmt);
        stmt.* = .{ .body = body, .catches = try catches.toOwnedSlice(
            self.arena,
        ), .finally_body = finally_body, .loc = loc };
        return .{ .try_stmt = stmt };
    }

    fn parse_throw_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        self.pos += 1; // skip 'throw'
        const expr = try self.expression();
        _ = self.match_kind(.semicolon);

        const stmt = try self.arena.create(ast.ThrowStmt);
        stmt.* = .{ .expr = expr, .loc = loc };
        return .{ .throw_stmt = stmt };
    }

    fn parse_dml_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        const op: ast.DmlOp = switch (self.current_kind()) {
            .insert_kw => .insert,
            .update_kw => .update,
            .upsert_kw => .upsert,
            .delete_kw => .delete,
            .undelete_kw => .undelete,
            .merge_kw => .merge,
            else => unreachable,
        };
        self.pos += 1;
        // Handle "insert as system/user expr" syntax
        var is_user_mode = false;
        if (self.check(.identifier) and std.ascii.eqlIgnoreCase(self.current().lexeme, "as")) {
            self.pos += 1; // skip 'as'
            if (self.check(.identifier)) {
                if (std.ascii.eqlIgnoreCase(self.current().lexeme, "user")) {
                    is_user_mode = true;
                }
                self.pos += 1; // skip 'system'/'user'
            }
        }
        const target = try self.expression();
        _ = self.match_kind(.semicolon);

        const stmt = try self.arena.create(ast.DmlStmt);
        stmt.* = .{ .op = op, .target = target, .is_user_mode = is_user_mode, .loc = loc };
        return .{ .dml_stmt = stmt };
    }

    fn parse_block_stmt(self: *Parser) !ast.Stmt {
        self.pos += 1; // skip {
        const stmts = try self.parse_block();
        try self.expect(.rbrace);
        return .{ .block = stmts };
    }

    fn parse_var_decl_stmt(self: *Parser) !ast.Stmt {
        const loc = self.current_loc();
        const type_ref = try self.parse_type_ref();
        const name = try self.expect_identifier();

        var initializer: ?*ast.Expr = null;
        if (self.match_kind(.assign)) {
            initializer = try self.expression();
        }
        _ = self.match_kind(.semicolon);

        const decl = try self.arena.create(ast.VarDecl);
        decl.* = .{ .type_ref = type_ref, .name = name, .initializer = initializer, .loc = loc };
        return .{ .var_decl = decl };
    }

    fn parse_single_or_block(self: *Parser) ![]ast.Stmt {
        if (self.match_kind(.lbrace)) {
            const stmts = try self.parse_block();
            try self.expect(.rbrace);
            return stmts;
        }
        var stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try stmts.append(self.arena, try self.parse_stmt());
        return stmts.toOwnedSlice(self.arena);
    }

    // -----------------------------------------------------------------------
    // 式 (Expression) — Pratt parsing
    // -----------------------------------------------------------------------

    fn expression(self: *Parser) anyerror!*ast.Expr {
        return self.parse_assignment();
    }

    fn parse_assignment(self: *Parser) !*ast.Expr {
        const expr = try self.parse_null_coalesce();

        const op: ?ast.AssignOp = switch (self.current_kind()) {
            .assign => .assign,
            .plus_assign => .plus_assign,
            .minus_assign => .minus_assign,
            .star_assign => .star_assign,
            .slash_assign => .slash_assign,
            .question_question_equal => .null_coalesce_assign,
            else => null,
        };
        if (op) |assign_op| {
            const loc = self.current_loc();
            self.pos += 1;
            const value = try self.parse_assignment(); // right-associative
            const node = try self.arena.create(ast.Assignment);
            node.* = .{ .target = expr, .op = assign_op, .value = value, .loc = loc };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .assignment = node };
            return result;
        }

        return expr;
    }

    /// Null-coalescing: a ?? b (right-associative, lower than ternary)
    fn parse_null_coalesce(self: *Parser) !*ast.Expr {
        var expr = try self.parse_ternary();
        while (self.match_kind(.question_question)) {
            const right = try self.parse_ternary();
            // Represent as ternary: (expr != null) ? expr : right
            // Build the condition: expr != null
            const null_node = try self.arena.create(ast.Expr);
            null_node.* = .null_literal;
            const cond_node = try self.arena.create(ast.BinaryExpr);
            cond_node.* = .{ .left = expr, .op = .neq, .right = null_node };
            const cond_expr = try self.arena.create(ast.Expr);
            cond_expr.* = .{ .binary = cond_node };
            const node = try self.arena.create(ast.TernaryExpr);
            node.* = .{ .condition = cond_expr, .then_expr = expr, .else_expr = right };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .ternary = node };
            expr = result;
        }
        return expr;
    }

    fn parse_ternary(self: *Parser) !*ast.Expr {
        const expr = try self.parse_or();

        if (self.match_kind(.question)) {
            const then_expr = try self.expression();
            try self.expect(.colon);
            const else_expr = try self.parse_ternary();
            const node = try self.arena.create(ast.TernaryExpr);
            node.* = .{ .condition = expr, .then_expr = then_expr, .else_expr = else_expr };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .ternary = node };
            return result;
        }

        return expr;
    }

    fn parse_or(self: *Parser) !*ast.Expr {
        var left = try self.parse_and();
        while (self.match_kind(.or_op)) {
            const right = try self.parse_and();
            left = try self.make_binary(left, .or_op, right);
        }
        return left;
    }

    fn parse_and(self: *Parser) !*ast.Expr {
        var left = try self.parse_bitwise_or();
        while (self.match_kind(.and_op)) {
            const right = try self.parse_bitwise_or();
            left = try self.make_binary(left, .and_op, right);
        }
        return left;
    }

    fn parse_bitwise_or(self: *Parser) !*ast.Expr {
        var left = try self.parse_bitwise_xor();
        while (self.match_kind(.pipe)) {
            const right = try self.parse_bitwise_xor();
            left = try self.make_binary(left, .bit_or, right);
        }
        return left;
    }

    fn parse_bitwise_xor(self: *Parser) !*ast.Expr {
        var left = try self.parse_bitwise_and();
        while (self.match_kind(.caret)) {
            const right = try self.parse_bitwise_and();
            left = try self.make_binary(left, .bit_xor, right);
        }
        return left;
    }

    fn parse_bitwise_and(self: *Parser) !*ast.Expr {
        var left = try self.parse_equality();
        while (self.match_kind(.ampersand)) {
            const right = try self.parse_equality();
            left = try self.make_binary(left, .bit_and, right);
        }
        return left;
    }

    fn parse_equality(self: *Parser) !*ast.Expr {
        var left = try self.parse_comparison();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.current_kind()) {
                .eq => .eq,
                .neq => .neq,
                .strict_eq => .strict_eq,
                .strict_neq => .strict_neq,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parse_comparison();
                left = try self.make_binary(left, binary_op, right);
            } else break;
        }
        return left;
    }

    fn parse_comparison(self: *Parser) !*ast.Expr {
        var left = try self.parse_shift();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.current_kind()) {
                .lt => .lt,
                .gt => .gt,
                .lte => .lte,
                .gte => .gte,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parse_shift();
                left = try self.make_binary(left, binary_op, right);
            } else break;
        }

        // instanceof
        if (self.match_kind(.instanceof_kw)) {
            const type_name = try self.parse_type_ref();
            const node = try self.arena.create(ast.InstanceofExpr);
            node.* = .{ .operand = left, .type_name = type_name };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .instanceof = node };
            return result;
        }

        return left;
    }

    /// Shift operators: << >> >>> — detected as consecutive < or > tokens
    fn parse_shift(self: *Parser) !*ast.Expr {
        var left = try self.parse_addition();
        while (true) {
            // << : two consecutive lt tokens
            if (self.check(.lt) and self.peek_kind(1) == .lt) {
                self.pos += 2;
                const right = try self.parse_addition();
                left = try self.make_binary(left, .mul, right); // reuse mul for shift in AST
                continue;
            }
            // >>> : three consecutive gt tokens
            if (self.check(.gt) and self.peek_kind(1) == .gt and self.peek_kind(2) == .gt) {
                self.pos += 3;
                const right = try self.parse_addition();
                left = try self.make_binary(left, .div, right); // reuse div for unsigned shift
                continue;
            }
            // >> : two consecutive gt tokens
            if (self.check(.gt) and self.peek_kind(1) == .gt) {
                self.pos += 2;
                const right = try self.parse_addition();
                left = try self.make_binary(left, .div, right); // reuse div for shift
                continue;
            }
            break;
        }
        return left;
    }

    fn parse_addition(self: *Parser) !*ast.Expr {
        var left = try self.parse_multiplication();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.current_kind()) {
                .plus => .add,
                .minus => .sub,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parse_multiplication();
                left = try self.make_binary(left, binary_op, right);
            } else break;
        }
        return left;
    }

    fn parse_multiplication(self: *Parser) !*ast.Expr {
        var left = try self.parse_unary();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.current_kind()) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parse_unary();
                left = try self.make_binary(left, binary_op, right);
            } else break;
        }
        return left;
    }

    fn parse_unary(self: *Parser) !*ast.Expr {
        if (self.match_kind(.minus)) {
            const operand = try self.parse_unary();
            const node = try self.arena.create(ast.UnaryExpr);
            node.* = .{ .op = .negate, .operand = operand };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .unary = node };
            return result;
        }
        // Unary plus: +expr — just parse the operand (no-op)
        if (self.match_kind(.plus)) {
            return self.parse_unary();
        }
        if (self.match_kind(.not_op)) {
            const operand = try self.parse_unary();
            const node = try self.arena.create(ast.UnaryExpr);
            node.* = .{ .op = .not, .operand = operand };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .unary = node };
            return result;
        }
        // Prefix ++ and -- → rewrite as x += 1 / x -= 1
        if (self.match_kind(.plus_plus)) {
            const operand = try self.parse_postfix();
            const one = try self.arena.create(ast.Expr);
            one.* = .{ .integer_literal = 1 };
            const node = try self.arena.create(ast.Assignment);
            node.* = .{ .target = operand, .op = .plus_assign, .value = one };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .assignment = node };
            return result;
        }
        if (self.match_kind(.minus_minus)) {
            const operand = try self.parse_postfix();
            const one = try self.arena.create(ast.Expr);
            one.* = .{ .integer_literal = 1 };
            const node = try self.arena.create(ast.Assignment);
            node.* = .{ .target = operand, .op = .minus_assign, .value = one };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .assignment = node };
            return result;
        }

        // Cast: (Type)expr — only if inside parens and looks like a type
        if (self.check(.lparen) and self.looks_like_cast()) {
            self.pos += 1; // skip (
            const target_type = try self.parse_type_ref();
            try self.expect(.rparen);
            const operand = try self.parse_unary();
            const node = try self.arena.create(ast.CastExpr);
            node.* = .{ .target_type = target_type, .operand = operand };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .cast_expr = node };
            return result;
        }

        return self.parse_postfix();
    }

    fn wrap_super_this_call(self: *Parser, expr: *ast.Expr) !*ast.Expr {
        const callee_name: []const u8 = if (expr.* == .super_expr) "super" else "this";
        const args = try self.parse_arg_list();
        try self.expect(.rparen);
        const node = try self.arena.create(ast.CallExpr);
        node.* = .{ .callee = callee_name, .args = args };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .call = node };
        return result;
    }

    fn parse_dot_chain(self: *Parser, expr: *ast.Expr, is_null_safe: bool) !*ast.Expr {
        const field_name = try self.expect_identifier_or_keyword();
        if (self.match_kind(.lparen)) {
            const args = try self.parse_arg_list();
            try self.expect(.rparen);
            const node = try self.arena.create(ast.MethodCallExpr);
            node.* = .{
                .object = expr,
                .method = field_name,
                .args = args,
                .null_safe = is_null_safe,
            };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .method_call = node };
            return result;
        }
        const node = try self.arena.create(ast.FieldAccess);
        node.* = .{ .object = expr, .field = field_name, .null_safe = is_null_safe };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .field_access = node };
        return result;
    }

    fn parse_index_access(self: *Parser, expr: *ast.Expr) !*ast.Expr {
        const index = try self.expression();
        try self.expect(.rbracket);
        const node = try self.arena.create(ast.IndexAccess);
        node.* = .{ .object = expr, .index = index };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .index_access = node };
        return result;
    }

    fn build_postfix_assign(self: *Parser, expr: *ast.Expr, op: ast.AssignOp) !*ast.Expr {
        const one = try self.arena.create(ast.Expr);
        one.* = .{ .integer_literal = 1 };
        const node = try self.arena.create(ast.Assignment);
        node.* = .{ .target = expr, .op = op, .value = one, .is_postfix = true };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .assignment = node };
        return result;
    }

    fn parse_postfix(self: *Parser) !*ast.Expr {
        var expr = try self.parse_primary();
        var chain_is_null_safe = false;

        // super(args) / this(args) → constructor delegation
        if ((expr.* == .super_expr or expr.* == .this_expr) and self.match_kind(.lparen)) {
            expr = try self.wrap_super_this_call(expr);
        }

        while (true) {
            const saw_question_dot = self.match_kind(.question_dot);
            const saw_dot = if (!saw_question_dot) self.match_kind(.dot) else false;
            if (saw_dot or saw_question_dot) {
                const is_null_safe = saw_question_dot or chain_is_null_safe;
                if (saw_question_dot) chain_is_null_safe = true;
                expr = try self.parse_dot_chain(expr, is_null_safe);
                continue;
            }
            if (self.match_kind(.lbracket)) {
                expr = try self.parse_index_access(expr);
                continue;
            }
            // Postfix ++ / -- → rewrite as x += 1 / x -= 1
            if (self.match_kind(.plus_plus)) {
                expr = try self.build_postfix_assign(expr, .plus_assign);
                continue;
            }
            if (self.match_kind(.minus_minus)) {
                expr = try self.build_postfix_assign(expr, .minus_assign);
                continue;
            }
            break;
        }

        return expr;
    }

    fn parse_integer_literal(self: *Parser) !*ast.Expr {
        const val = std.fmt.parseInt(i64, self.current().lexeme, 10) catch 0;
        self.pos += 1;
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .integer_literal = val };
        return result;
    }

    fn parse_long_literal(self: *Parser) !*ast.Expr {
        const lexeme = self.current().lexeme;
        const num_part = if (lexeme.len > 0 and
            (lexeme[lexeme.len - 1] == 'L' or lexeme[lexeme.len - 1] == 'l'))
            lexeme[0 .. lexeme.len - 1]
        else
            lexeme;
        const val = std.fmt.parseInt(i64, num_part, 10) catch 0;
        self.pos += 1;
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .long_literal = val };
        return result;
    }

    fn parse_double_literal(self: *Parser) !*ast.Expr {
        const val = std.fmt.parseFloat(f64, self.current().lexeme) catch 0.0;
        self.pos += 1;
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .double_literal = val };
        return result;
    }

    fn unescape_string_content(self: *Parser, quoted: []const u8) []const u8 {
        if (std.mem.indexOf(u8, quoted, "\\") == null) return quoted;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var ci: usize = 0;
        while (ci < quoted.len) : (ci += 1) {
            if (quoted[ci] == '\\' and ci + 1 < quoted.len) {
                ci += 1;
                switch (quoted[ci]) {
                    'n' => buf.append(self.arena, '\n') catch return quoted,
                    't' => buf.append(self.arena, '\t') catch return quoted,
                    'r' => buf.append(self.arena, '\r') catch return quoted,
                    '\\' => buf.append(self.arena, '\\') catch return quoted,
                    '\'' => buf.append(self.arena, '\'') catch return quoted,
                    '"' => buf.append(self.arena, '"') catch return quoted,
                    else => |ch| {
                        // Keep unknown escapes as-is (e.g., \s, \*)
                        buf.append(self.arena, '\\') catch return quoted;
                        buf.append(self.arena, ch) catch return quoted;
                    },
                }
            } else {
                buf.append(self.arena, quoted[ci]) catch return quoted;
            }
        }
        return buf.items;
    }

    fn parse_string_literal(self: *Parser) !*ast.Expr {
        const raw = self.current().lexeme;
        const quoted = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
        const content = self.unescape_string_content(quoted);
        self.pos += 1;
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .string_literal = content };
        return result;
    }

    fn parse_bare_expr(self: *Parser, payload: ast.Expr) !*ast.Expr {
        self.pos += 1;
        const result = try self.arena.create(ast.Expr);
        result.* = payload;
        return result;
    }

    fn parse_soql_literal(self: *Parser) !*ast.Expr {
        const raw = self.current().lexeme;
        const loc = self.current_loc();
        self.pos += 1;
        const node = try self.arena.create(ast.SoqlExpr);
        node.* = .{ .raw = raw, .loc = loc };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .soql = node };
        return result;
    }

    fn parse_grouped_expr(self: *Parser) !*ast.Expr {
        self.pos += 1;
        const inner = try self.expression();
        try self.expect(.rparen);
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .grouped = inner };
        return result;
    }

    fn build_generic_type_class(self: *Parser, name: []const u8, loc: SourceLoc) !*ast.Expr {
        // Build full type name including generics: e.g. "List<Contact>"
        var full_name_buf: std.ArrayListUnmanaged(u8) = .empty;
        try full_name_buf.appendSlice(self.arena, name);
        var depth: u32 = 0;
        while (!self.at_end()) {
            const lex = self.current().lexeme;
            if (self.check(.lt)) {
                depth += 1;
                try full_name_buf.append(self.arena, '<');
            } else if (self.check(.gt)) {
                depth -= 1;
                try full_name_buf.append(self.arena, '>');
                if (depth == 0) {
                    self.pos += 1;
                    break;
                }
            } else {
                try full_name_buf.appendSlice(self.arena, lex);
            }
            self.pos += 1;
        }
        if (self.match_kind(.dot)) {
            if (!self.match_kind(.class_kw)) _ = self.match_kind(.identifier);
        }
        const full_type_name = try full_name_buf.toOwnedSlice(self.arena);
        const type_obj = try self.arena.create(ast.NewExpr);
        type_obj.* = .{ .type_name = .{ .name = full_type_name }, .args = &.{}, .loc = loc };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .new_expr = type_obj };
        return result;
    }

    fn build_array_type_class(self: *Parser, name: []const u8, loc: SourceLoc) !*ast.Expr {
        self.pos += 2; // skip []
        if (self.match_kind(.dot)) {
            if (!self.match_kind(.class_kw)) _ = self.match_kind(.identifier);
        }
        const arr_name = try std.fmt.allocPrint(self.arena, "{s}[]", .{name});
        const type_obj = try self.arena.create(ast.NewExpr);
        type_obj.* = .{ .type_name = .{ .name = arr_name }, .args = &.{}, .loc = loc };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .new_expr = type_obj };
        return result;
    }

    fn parse_identifier_primary(self: *Parser) !*ast.Expr {
        const name = self.current().lexeme;
        const loc = self.current_loc();
        self.pos += 1;

        // Function call: name(args)
        if (self.match_kind(.lparen)) {
            const args = try self.parse_arg_list();
            try self.expect(.rparen);
            const node = try self.arena.create(ast.CallExpr);
            node.* = .{ .callee = name, .args = args, .loc = loc };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .call = node };
            return result;
        }

        // Handle Type<T>.class → type literal
        if (self.check(.lt) and self.looks_like_type_dot_class()) {
            return self.build_generic_type_class(name, loc);
        }

        // Handle Type[].class → array type literal
        if (self.check(.lbracket) and
            self.peek_kind(1) == .rbracket and
            self.peek_kind(2) == .dot)
        {
            return self.build_array_type_class(name, loc);
        }

        const result = try self.arena.create(ast.Expr);
        result.* = .{ .identifier = .{ .name = name, .loc = loc } };
        return result;
    }

    fn parse_primary(self: *Parser) anyerror!*ast.Expr {
        const kind = self.current_kind();
        switch (kind) {
            .integer_literal => return self.parse_integer_literal(),
            .long_literal => return self.parse_long_literal(),
            .double_literal => return self.parse_double_literal(),
            .string_literal => return self.parse_string_literal(),
            .true_kw => return self.parse_bare_expr(.{ .boolean_literal = true }),
            .false_kw => return self.parse_bare_expr(.{ .boolean_literal = false }),
            .null_kw => return self.parse_bare_expr(.null_literal),
            .this_kw => return self.parse_bare_expr(.this_expr),
            .super_kw => return self.parse_bare_expr(.super_expr),
            .soql_literal => return self.parse_soql_literal(),
            .new_kw => return self.parse_new_expr(),
            .lparen => return self.parse_grouped_expr(),
            .identifier, .trigger_kw => return self.parse_identifier_primary(),
            else => {
                // Unexpected token — create a null literal as fallback
                self.pos += 1;
                const result = try self.arena.create(ast.Expr);
                result.* = .null_literal;
                return result;
            },
        }
    }

    fn parse_new_expr(self: *Parser) !*ast.Expr {
        self.pos += 1; // skip 'new'
        const loc = self.current_loc();
        const type_name = try self.parse_type_ref();

        // Array size: new Type[size] — e.g. new String[0], new Account[n]
        if (self.match_kind(.lbracket)) return try self.parse_new_array_size(type_name, loc);

        var args: []ast.Expr = &.{};
        var is_brace_initializer = false;
        if (self.match_kind(.lparen)) {
            args = try self.parse_arg_list();
            try self.expect(.rparen);
        }

        // Brace initializer: new List<T>{ item1, item2 } or new Map<K,V>{ key => value, ... }
        if (self.match_kind(.lbrace)) {
            is_brace_initializer = true;
            args = try self.parse_new_brace_initializer_args();
            try self.expect(.rbrace);
        }

        const node = try self.arena.create(ast.NewExpr);
        node.* = .{
            .type_name = type_name,
            .args = args,
            .is_brace_initializer = is_brace_initializer,
            .loc = loc,
        };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .new_expr = node };
        return result;
    }

    fn parse_new_array_size(self: *Parser, type_name: types.TypeRef, loc: SourceLoc) !*ast.Expr {
        const size_expr = try self.expression();
        try self.expect(.rbracket);
        var arr_args: std.ArrayListUnmanaged(ast.Expr) = .empty;
        try arr_args.append(self.arena, size_expr.*);
        const node = try self.arena.create(ast.NewExpr);
        node.* = .{
            .type_name = type_name,
            .args = try arr_args.toOwnedSlice(self.arena),
            .loc = loc,
        };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .new_expr = node };
        return result;
    }

    fn parse_new_brace_initializer_args(self: *Parser) ![]ast.Expr {
        var brace_args: std.ArrayListUnmanaged(ast.Expr) = .empty;
        if (self.check(.rbrace)) return try brace_args.toOwnedSlice(self.arena);
        const first_expr = try self.expression();
        if (self.match_kind(.arrow)) {
            // Map literal: key => value pairs
            try self.append_map_pair_expr(&brace_args, first_expr, try self.expression());
            while (self.match_kind(.comma)) {
                if (self.check(.rbrace)) break;
                const k = try self.expression();
                _ = self.match_kind(.arrow);
                const v = try self.expression();
                try self.append_map_pair_expr(&brace_args, k, v);
            }
        } else {
            try brace_args.append(self.arena, first_expr.*);
            while (self.match_kind(.comma)) {
                if (self.check(.rbrace)) break;
                try brace_args.append(self.arena, (try self.expression()).*);
            }
        }
        return try brace_args.toOwnedSlice(self.arena);
    }

    fn append_map_pair_expr(
        self: *Parser,
        brace_args: *std.ArrayListUnmanaged(ast.Expr),
        key: *ast.Expr,
        value: *ast.Expr,
    ) !void {
        const asgn = try self.arena.create(ast.Assignment);
        asgn.* = .{ .target = key, .op = .assign, .value = value };
        const pair = try self.arena.create(ast.Expr);
        pair.* = .{ .assignment = asgn };
        try brace_args.append(self.arena, pair.*);
    }

    fn parse_arg_list(self: *Parser) ![]ast.Expr {
        var args: std.ArrayListUnmanaged(ast.Expr) = .empty;
        if (self.check(.rparen)) return args.toOwnedSlice(self.arena);

        try args.append(self.arena, (try self.expression()).*);
        while (self.match_kind(.comma)) {
            try args.append(self.arena, (try self.expression()).*);
        }
        return args.toOwnedSlice(self.arena);
    }

    // -----------------------------------------------------------------------
    // 型参照
    // -----------------------------------------------------------------------

    fn parse_type_ref(self: *Parser) !TypeRef {
        if (self.check(.void_kw)) {
            self.pos += 1;
            return .{ .name = "void" };
        }
        const name = try self.expect_identifier();

        // Handle dotted names: System.Type, Messaging.inboundEmail.BinaryAttachment
        var full_name = name;
        while (self.check(.dot) and self.peek_kind(1) == .identifier) {
            self.pos += 1; // skip dot
            const next_part = self.current().lexeme;
            self.pos += 1;
            full_name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ full_name, next_part });
        }

        // Generic params: <T, U>
        if (self.match_kind(.lt)) {
            var params: std.ArrayListUnmanaged(TypeRef) = .empty;
            try params.append(self.arena, try self.parse_type_ref());
            while (self.match_kind(.comma)) {
                try params.append(self.arena, try self.parse_type_ref());
            }
            // skip '>' — might need to handle >> for nested generics
            if (self.check(.gt)) {
                self.pos += 1;
            } else if (self.check(.gte)) {
                // >> case: consume one > and leave one
                // Rewrite token — just advance for now
                self.pos += 1;
            }
            return .{ .name = full_name, .params = try params.toOwnedSlice(self.arena) };
        }

        // Array notation: Type[] (only if followed immediately by ])
        if (self.check(.lbracket) and self.peek_kind(1) == .rbracket) {
            self.pos += 2; // skip [ ]
            const params = try self.arena.alloc(TypeRef, 1);
            params[0] = .{ .name = full_name };
            return .{ .name = "List", .params = params };
        }

        return .{ .name = full_name };
    }

    // -----------------------------------------------------------------------
    // ヒューリスティック
    // -----------------------------------------------------------------------

    /// Variable declaration looks like: Type name (= ...) ;
    fn looks_like_var_decl(self: *Parser) bool {
        // Save position
        const saved = self.pos;
        defer self.pos = saved;

        // Try to skip type (including generic params)
        if (!self.check(.identifier) and !self.check(.void_kw)) return false;
        self.pos += 1;

        // skip dotted name (multi-level: A.B.C)
        while (self.check(.dot) and self.peek_kind(1) == .identifier) {
            self.pos += 2;
        }

        // skip generic params
        if (self.check(.lt)) {
            var depth: u32 = 0;
            while (!self.at_end()) {
                if (self.check(.lt)) depth += 1;
                if (self.check(.gt)) {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos += 1;
                        break;
                    }
                }
                self.pos += 1;
            }
        }

        // skip []
        if (self.check(.lbracket) and self.peek_kind(1) == .rbracket) {
            self.pos += 2;
        }

        // Should be followed by an identifier (the variable name)
        return self.check(.identifier);
    }

    fn looks_like_for_each(self: *Parser) bool {
        // Scan forward in the parenthesized section to find ':'
        const saved = self.pos;
        defer self.pos = saved;

        var depth: u32 = 0;
        while (!self.at_end()) {
            const k = self.current_kind();
            if (k == .lparen) depth += 1;
            if (k == .rparen) {
                if (depth == 0) return false;
                depth -= 1;
            }
            if (k == .colon and depth == 0) return true;
            if (k == .semicolon) return false; // traditional for
            self.pos += 1;
        }
        return false;
    }

    /// Check if we're looking at Ident<...>.class pattern (type literal expression)
    fn looks_like_type_dot_class(self: *Parser) bool {
        const saved = self.pos;
        defer self.pos = saved;

        if (!self.check(.lt)) return false;
        var depth: u32 = 0;
        while (!self.at_end()) {
            if (self.check(.lt)) depth += 1;
            if (self.check(.gt)) {
                depth -= 1;
                if (depth == 0) {
                    self.pos += 1;
                    // Check for .class
                    if (self.check(.dot)) {
                        self.pos += 1;
                        if (self.check(.class_kw) or
                            (self.check(.identifier) and std.ascii.eqlIgnoreCase(self.current().lexeme, "class")))
                        {
                            return true;
                        }
                    }
                    return false;
                }
            }
            if (self.check(.semicolon) or self.check(.rparen)) return false;
            // comma at depth 0 means we're not in generics; inside <...> commas are param
            // separators
            if (self.check(.comma) and depth == 0) return false;
            self.pos += 1;
        }
        return false;
    }

    fn looks_like_cast(self: *Parser) bool {
        // (Type)expr — check if after ( there's a type reference followed by )
        const saved = self.pos;
        defer self.pos = saved;

        if (!self.check(.lparen)) return false;
        self.pos += 1; // skip (

        if (!self.check(.identifier)) return false;
        self.pos += 1;

        // skip dotted name (multi-level: A.B.C)
        while (self.check(.dot) and self.peek_kind(1) == .identifier) {
            self.pos += 2;
        }

        // skip generic params: <T, U, ...>
        if (self.check(.lt)) {
            var depth: u32 = 0;
            while (!self.at_end()) {
                if (self.check(.lt)) depth += 1;
                if (self.check(.gt)) {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos += 1;
                        break;
                    }
                }
                self.pos += 1;
            }
        }

        // skip []
        if (self.check(.lbracket) and self.peek_kind(1) == .rbracket) {
            self.pos += 2;
        }

        if (!self.check(.rparen)) return false;
        // After ')' must come an expression-start token, not an operator / ';' / '{'
        // to distinguish (Type)expr cast from (expr) grouping
        const after_rparen = self.peek_kind(1);
        return after_rparen == .identifier or after_rparen == .integer_literal or
            after_rparen == .double_literal or after_rparen == .long_literal or
            after_rparen == .string_literal or after_rparen == .true_kw or
            after_rparen == .false_kw or after_rparen == .null_kw or
            after_rparen == .this_kw or after_rparen == .super_kw or
            after_rparen == .new_kw or after_rparen == .lparen or
            after_rparen == .not_op or after_rparen == .minus or
            after_rparen == .plus_plus or after_rparen == .minus_minus or
            after_rparen == .soql_literal or after_rparen == .trigger_kw;
    }

    // -----------------------------------------------------------------------
    // ヘルパー
    // -----------------------------------------------------------------------

    fn make_binary(self: *Parser, left: *ast.Expr, op: ast.BinaryOp, right: *ast.Expr) !*ast.Expr {
        const node = try self.arena.create(ast.BinaryExpr);
        node.* = .{ .left = left, .op = op, .right = right };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .binary = node };
        return result;
    }

    fn parse_modifiers(self: *Parser) ast.Modifiers {
        var mods = ast.Modifiers{};
        while (true) {
            switch (self.current_kind()) {
                .public_kw => mods.is_public = true,
                .private_kw => mods.is_private = true,
                .protected_kw => mods.is_protected = true,
                .global_kw => mods.is_global = true,
                .static_kw => mods.is_static = true,
                .final_kw => mods.is_final = true,
                .abstract_kw => mods.is_abstract = true,
                .virtual_kw => mods.is_virtual = true,
                .override_kw => mods.is_override = true,
                .transient_kw => mods.is_transient = true,
                .with_kw, .without_kw, .sharing_kw => {
                    // skip sharing-related keywords
                    self.pos += 1;
                    continue;
                },
                .identifier => {
                    // Apex 追加修飾子: webservice, testMethod, inherited (sharing)
                    const lex = self.current().lexeme;
                    if (std.ascii.eqlIgnoreCase(lex, "testmethod")) {
                        mods.is_test_method = true;
                        self.pos += 1;
                        continue;
                    }
                    if (std.ascii.eqlIgnoreCase(lex, "webservice") or
                        std.ascii.eqlIgnoreCase(lex, "inherited"))
                    {
                        self.pos += 1;
                        continue;
                    }
                    return mods;
                },
                else => return mods,
            }
            self.pos += 1;
        }
    }

    fn expect(self: *Parser, kind: TokenKind) !void {
        if (self.check(kind)) {
            self.pos += 1;
            return;
        }
        // 診断を記録して続行
        try self.add_diagnostic(self.current_loc(), kind);
    }

    fn expect_identifier(self: *Parser) ![]const u8 {
        if (self.check(.identifier)) {
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        // Fallback: use current token's lexeme
        if (!self.at_end()) {
            try self.add_diagnostic(self.current_loc(), .identifier);
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        try self.add_diagnostic(self.current_loc(), .identifier);
        return "_unknown";
    }

    /// ドットの後に来る識別子を期待するが、Apex ではキーワードも
    /// フィールド名として使える（例: Trigger.new, Account.class）。
    fn expect_identifier_or_keyword(self: *Parser) ![]const u8 {
        if (self.check(.identifier)) {
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        // Apex ではキーワードもフィールド/メソッド名として出現しうる
        const kind = self.current_kind();
        if (kind != .eof and kind != .semicolon and kind != .lbrace and
            kind != .rbrace and kind != .lparen and kind != .rparen and
            kind != .lbracket and kind != .rbracket and kind != .comma and
            kind != .dot and kind != .question_dot and kind != .assign and
            kind != .plus_assign and kind != .minus_assign and kind != .star_assign and
            kind != .slash_assign and kind != .soql_literal and kind != .string_literal and
            kind != .integer_literal and kind != .double_literal and kind != .long_literal and
            kind != .annotation)
        {
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        // 本当に識別子が必要な場合は通常の expect_identifier にフォールバック
        return self.expect_identifier();
    }

    fn add_diagnostic(self: *Parser, loc: SourceLoc, expected: TokenKind) !void {
        const got_name = if (!self.at_end()) @tagName(self.current().kind) else "end of file";
        const msg = try std.fmt.allocPrint(self.arena, "expected {s}, got {s}", .{
            @tagName(expected),
            got_name,
        });
        try self.diagnostics.append(self.arena, .{
            .message = msg,
            .loc = loc,
        });
    }

    fn match_kind(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn check(self: *const Parser, kind: TokenKind) bool {
        return self.current_kind() == kind;
    }

    fn current_kind(self: *const Parser) TokenKind {
        if (self.pos >= self.tokens.len) return .eof;
        return self.tokens[self.pos].kind;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn current_loc(self: *const Parser) SourceLoc {
        if (self.pos >= self.tokens.len) return .zero;
        return self.tokens[self.pos].loc;
    }

    fn peek_kind(self: *const Parser, offset: u32) TokenKind {
        const idx = self.pos + offset;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx].kind;
    }

    fn at_end(self: *const Parser) bool {
        return self.pos >= self.tokens.len or self.tokens[self.pos].kind == .eof;
    }
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("lexer.zig");

test "parse variable declaration with binary expression" {
    const tokens = try lexer.tokenize("Integer x = 1 + 2;", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Parse as a statement sequence (no class wrapper)
    var p = Parser{ .tokens = tokens, .arena = arena.allocator() };
    const stmt = try p.parse_stmt();

    try std.testing.expect(stmt == .var_decl);
    try std.testing.expectEqualStrings("x", stmt.var_decl.name);
    try std.testing.expectEqualStrings("Integer", stmt.var_decl.type_ref.name);
    try std.testing.expect(stmt.var_decl.initializer != null);
    try std.testing.expect(stmt.var_decl.initializer.?.* == .binary);
}

test "parse return statement with string literal" {
    const tokens = try lexer.tokenize("return 'hello';", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser{ .tokens = tokens, .arena = arena.allocator() };
    const stmt = try p.parse_stmt();

    try std.testing.expect(stmt == .return_stmt);
    try std.testing.expect(stmt.return_stmt.value != null);
    try std.testing.expect(stmt.return_stmt.value.?.* == .string_literal);
    try std.testing.expectEqualStrings("hello", stmt.return_stmt.value.?.string_literal);
}

test "parse simple class declaration" {
    const source =
        \\public class Hello {
        \\    public static String greet() {
        \\        return 'world';
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decls = try parse(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expect(decls[0] == .class_decl);
    try std.testing.expectEqualStrings("Hello", decls[0].class_decl.name);
    try std.testing.expectEqual(@as(usize, 1), decls[0].class_decl.members.len);
    try std.testing.expect(decls[0].class_decl.members[0] == .method_decl);
    try std.testing.expectEqualStrings("greet", decls[0].class_decl.members[0].method_decl.name);
}

test "parse if statement" {
    const tokens = try lexer.tokenize("if (x > 0) { return x; }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser{ .tokens = tokens, .arena = arena.allocator() };
    const stmt = try p.parse_stmt();
    try std.testing.expect(stmt == .if_stmt);
    try std.testing.expect(stmt.if_stmt.condition.* == .binary);
    try std.testing.expectEqual(@as(usize, 1), stmt.if_stmt.then_body.len);
}

test "parse DML statement" {
    const tokens = try lexer.tokenize("insert acc;", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser{ .tokens = tokens, .arena = arena.allocator() };
    const stmt = try p.parse_stmt();
    try std.testing.expect(stmt == .dml_stmt);
    try std.testing.expectEqual(ast.DmlOp.insert, stmt.dml_stmt.op);
}

test "parse expression with method call chain" {
    const tokens = try lexer.tokenize("a.b.c(1, 2)", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parse_expr(tokens, arena.allocator());
    try std.testing.expect(expr.* == .method_call);
    try std.testing.expectEqualStrings("c", expr.method_call.method);
}

test "parse switch on statement" {
    const source =
        \\switch on x {
        \\    when 1 { return 'one'; }
        \\    when else { return 'other'; }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser{ .tokens = tokens, .arena = arena.allocator() };
    const stmt = try p.parse_stmt();
    try std.testing.expect(stmt == .switch_stmt);
    try std.testing.expectEqual(@as(usize, 2), stmt.switch_stmt.when_clauses.len);
}

// ---------------------------------------------------------------------------
// 誤検知テスト — 有効な Apex コードが 0 diagnostic であることを保証
// ---------------------------------------------------------------------------

test "no diagnostics: Trigger.new field access" {
    const source =
        \\public class MyTriggerHandler {
        \\    public void run() {
        \\        List<Account> accs = Trigger.new;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), result.decls.len);
}

test "no diagnostics: for-each over Trigger.new" {
    const source =
        \\public class MyHandler {
        \\    public void run() {
        \\        for (Account acc : Trigger.new) {
        \\            acc.Name = 'test';
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: Account.class type literal" {
    const source =
        \\public class TypeTest {
        \\    public void run() {
        \\        Type t = Account.class;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: switch on with type-binding when clause" {
    const source =
        \\public class SwitchTest {
        \\    public void run(SObject record) {
        \\        switch on record {
        \\            when Account acc {
        \\                System.debug(acc.Name);
        \\            }
        \\            when Contact c {
        \\                System.debug(c.LastName);
        \\            }
        \\            when null {
        \\                System.debug('null');
        \\            }
        \\            when else {
        \\                System.debug('other');
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    // switch 文に 4 つの when 句
    try std.testing.expectEqual(@as(usize, 1), result.decls.len);
    const class_decl = result.decls[0].class_decl;
    const method = class_decl.members[0].method_decl;
    try std.testing.expect(method.body[0] == .switch_stmt);
    try std.testing.expectEqual(@as(usize, 4), method.body[0].switch_stmt.when_clauses.len);
}

test "no diagnostics: this() constructor delegation" {
    const source =
        \\public class MyClass {
        \\    private String name;
        \\    public MyClass() {
        \\        this('default');
        \\    }
        \\    public MyClass(String name) {
        \\        this.name = name;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: this() with multiple args" {
    const source =
        \\public class MyClass {
        \\    public MyClass() {
        \\        this('default', 0);
        \\    }
        \\    public MyClass(String name, Integer count) {
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: final parameter modifier" {
    const source =
        \\public class FinalTest {
        \\    public void run(final String name) {
        \\        System.debug(name);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: webservice modifier" {
    const source =
        \\global class MyWebService {
        \\    webservice static String echo(String input) {
        \\        return input;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: testMethod modifier" {
    const source =
        \\@IsTest
        \\public class MyTest {
        \\    static testMethod void myTest() {
        \\        System.assert(true);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "testMethod modifier sets is_test_method in Modifiers" {
    const source =
        \\@IsTest
        \\public class MyTest {
        \\    static testMethod void myTest() {
        \\        System.assert(true);
        \\    }
        \\    public static void helper() {}
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), result.decls.len);

    const class_decl = result.decls[0].class_decl;
    // First member: testMethod → is_test_method = true
    const test_method = class_decl.members[0].method_decl;
    try std.testing.expect(test_method.modifiers.is_test_method);
    // Second member: helper → is_test_method = false
    const helper = class_decl.members[1].method_decl;
    try std.testing.expect(!helper.modifiers.is_test_method);
}

test "no diagnostics: final local variable" {
    const source =
        \\public class FinalLocal {
        \\    public void run() {
        \\        final String name = 'test';
        \\        final List<Account> accs = new List<Account>();
        \\        System.debug(name);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: comprehensive real-world Apex" {
    const source =
        \\public with sharing class AccountService {
        \\    public String Name { get; set; }
        \\    public Integer Count { get; private set; }
        \\
        \\    public AccountService() {
        \\        this('default');
        \\    }
        \\
        \\    public AccountService(String name) {
        \\        this.Name = name;
        \\    }
        \\
        \\    @AuraEnabled(cacheable=true)
        \\    public static List<Account> getAccounts() {
        \\        return [SELECT Id, Name FROM Account LIMIT 10];
        \\    }
        \\
        \\    public void process(SObject record) {
        \\        switch on record {
        \\            when Account acc {
        \\                System.debug(acc.Name);
        \\            }
        \\            when null {
        \\                System.debug('null');
        \\            }
        \\            when else {
        \\                System.debug('other');
        \\            }
        \\        }
        \\
        \\        Type t = Account.class;
        \\
        \\        String result = record != null ? 'yes' : 'no';
        \\
        \\        List<Account> accounts = [SELECT Id FROM Account];
        \\        try {
        \\            update accounts;
        \\        } catch (DmlException e) {
        \\            System.debug(e.getMessage());
        \\        } finally {
        \\            System.debug('done');
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: null-coalescing operator ??" {
    const source =
        \\public class NullCoalesce {
        \\    public void run() {
        \\        String name = inputName ?? 'default';
        \\        Integer count = a ?? b ?? 0;
        \\        Object val = record.Field__c ?? fallbackValue;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: multi-level dotted type name" {
    const source =
        \\public class DottedType {
        \\    public void run() {
        \\        Messaging.inboundEmail.BinaryAttachment att;
        \\        List<Invocable.Action.Result> results;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: multi-level dotted type in catch" {
    const source =
        \\public class CatchDotted {
        \\    public void run() {
        \\        try {
        \\            System.debug('test');
        \\        } catch (Cache.Org.OrgCacheException e) {
        \\            System.debug(e);
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: for-init multiple variable declarations" {
    const source =
        \\public class ForMultiVar {
        \\    public void run() {
        \\        List<String> items = new List<String>();
        \\        for (Integer i = 0, size = items.size(); i < size; i++) {
        \\            System.debug(items[i]);
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: bitwise AND operator" {
    const source =
        \\public class BitwiseTest {
        \\    public void run() {
        \\        if (System.Test.isRunningTest() & hasRecords()) {
        \\            System.debug('ok');
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: inherited sharing" {
    const source =
        \\public inherited sharing class SecureService {
        \\    public void run() {
        \\        System.debug('test');
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: inherited sharing inner class" {
    const source =
        \\public class Outer {
        \\    public inherited sharing class Inner {
        \\        public void run() {
        \\            System.debug('test');
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: unary plus in method args" {
    const source =
        \\public class UnaryPlus {
        \\    public void run() {
        \\        Date d = Date.today().addYears(+1);
        \\        Date d2 = dt.addYears(+0);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: dot-prefixed decimal literal" {
    const source =
        \\public class DotDecimal {
        \\    public void run() {
        \\        Decimal d = (amount * percent * .01).setScale(2);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: generic type .class in args" {
    const source =
        \\public class TypeLiteral {
        \\    public void run() {
        \\        Object obj = JSON.deserialize(response, Map<String, Object>.class);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: switch on parenthesized expression" {
    const source =
        \\global class C {
        \\    void run() {
        \\        switch on (cleanActionText) {
        \\            when 'a' {
        \\                System.debug('a');
        \\            }
        \\            when else {
        \\                System.debug('b');
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: new Type[0] array size" {
    const source =
        \\public class ArraySize {
        \\    public void run() {
        \\        Contact[] contacts = new Contact[0];
        \\        String[] names = new String[0];
        \\        Address__c[] addrs = new Address__c[0];
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: <> not-equal operator" {
    const source =
        \\public class NotEqual {
        \\    public void run() {
        \\        if (status <> 'Closed') {
        \\            System.debug('open');
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: comma-separated field declarations" {
    const source =
        \\public class MultiField {
        \\    private Id filterGroupId1, filterGroupId2, filterGroupId3;
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: when and with as method names" {
    const source =
        \\public class KeywordMethods {
        \\    public Object when(Object val) {
        \\        return val;
        \\    }
        \\    public KeywordMethods with(List<String> items) {
        \\        return this;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: array type .class literal" {
    const source =
        \\public class ArrayClass {
        \\    public void run() {
        \\        Object obj = (String[])JSON.deserialize(data, String[].class);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: SOQL with line comment containing quote" {
    const source =
        \\public class SoqlComment {
        \\    public void run() {
        \\        List<Object> results = [
        \\            SELECT
        \\                LastModifiedBy, // This is NOT a lookup :'(
        \\                Name
        \\            FROM FlowDefinitionView
        \\        ];
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: new Type[size] array initialization" {
    const source =
        \\public class ArrayInit {
        \\    public void run() {
        \\        Map<Id, Contact[]> m = new Map<Id, Contact[]>();
        \\        m.put(acc.Id, new Contact[0]);
        \\        String[] names = new String[10];
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: .class in method arguments" {
    const source =
        \\public class ClassLiteral {
        \\    public void run() {
        \\        Object stub = Test.createStub(UnitOfWork.class, mock);
        \\        mocks.mockVoidMethod(this, 'registerNew', new List<Type> {SObject.class, Schema.sObjectField.class}, new List<Object> {record, field});
        \\        String name = TDTM_RunnableMutableMock.class.getName();
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: Describe with SObjectType and List args" {
    const source =
        \\public class DescribeTest {
        \\    public void run() {
        \\        Describer.describe(Hoge__c.SObjectType, new List<String>{'Name', 'Id'});
        \\        Schema.DescribeSObjectResult result = Hoge__c.SObjectType.getDescribe();
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: bitwise shift and XOR operators" {
    const source =
        \\public class BitwiseOps {
        \\    public void run() {
        \\        Integer a = 1 << 3;
        \\        Integer b = val >>> 8;
        \\        Integer c = (crc ^ byteVal) & 255;
        \\        Integer d = hex.mid(i << 1, 2);
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: double literal with d suffix" {
    const source =
        \\public class DoubleSuffix {
        \\    public void run() {
        \\        Type t = Double.class;
        \\        Object o = Argument.getType(42.0d);
        \\        Double d = 3.14D;
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: multiline method call args" {
    const source =
        \\public class MultiLine {
        \\    public void run() {
        \\        Describe.Hoge(
        \\            fuga,
        \\            hoge
        \\        );
        \\        SomeClass.method(
        \\            arg1,
        \\            arg2,
        \\            arg3
        \\        );
        \\        Map<String, Object> result = Service.execute(
        \\            param1,
        \\            param2
        \\        );
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: extreme multiline formatting" {
    const source =
        \\public class Extreme {
        \\    public void run() {
        \\        Describe
        \\            .Hoge(
        \\                fuga
        \\                ,
        \\                hoge
        \\            );
        \\        String
        \\            result
        \\            =
        \\            SomeService
        \\                .getInstance()
        \\                .execute(
        \\                    param1
        \\                    ,
        \\                    param2
        \\                );
        \\        if (
        \\            a
        \\            ==
        \\            b
        \\        ) {
        \\            System.debug(
        \\                'hello'
        \\            );
        \\        }
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: Schema describe patterns" {
    const source =
        \\public class SchemaDescribe {
        \\    public void run() {
        \\        Schema.DescribeSObjectResult result = Account.SObjectType.getDescribe();
        \\        Map<String, Schema.SObjectField> fields = result.fields.getMap();
        \\        Schema.DescribeFieldResult dfr = Schema.SObjectType.Account.fields.Name.getDescribe();
        \\        List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: class literal in various positions" {
    const source =
        \\public class ClassLiteralPos {
        \\    public void run() {
        \\        Type t1 = Account.class;
        \\        String name1 = Account.class.getName();
        \\        String name2 = Schema.SObjectType.class.getName();
        \\        Type t2 = Foo.Bar.class;
        \\        System.assertEquals(
        \\            Account.class,
        \\            Argument.getType(acc)
        \\        );
        \\        mocks.verify(
        \\            SObject.class,
        \\            Schema.SObjectField.class
        \\        );
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "no diagnostics: method call with class literal arg and newlines" {
    const source =
        \\public class ClassArgNewline {
        \\    public void run() {
        \\        Describer.describe(
        \\            Account.class,
        \\            new List<String>{'Name'}
        \\        );
        \\        Describer.describe(
        \\            Hoge__c.SObjectType,
        \\            new List<Schema.DescribeFieldResult>()
        \\        );
        \\        mocks.mockVoidMethod(
        \\            this,
        \\            'methodName',
        \\            new List<Type> {
        \\                SObject.class,
        \\                Schema.SObjectField.class,
        \\                SObject.class
        \\            },
        \\            new List<Object> {
        \\                record,
        \\                field,
        \\                parent
        \\            }
        \\        );
        \\    }
        \\}
    ;
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse_with_diagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
