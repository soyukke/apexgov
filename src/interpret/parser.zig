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

pub fn parse(tokens: []const Token, arena: std.mem.Allocator) ![]ast.Decl {
    var p = Parser{ .tokens = tokens, .arena = arena };
    return p.parseProgram();
}

pub fn parseExpr(tokens: []const Token, arena: std.mem.Allocator) !*ast.Expr {
    var p = Parser{ .tokens = tokens, .arena = arena };
    return p.expression();
}

const Parser = struct {
    tokens: []const Token,
    arena: std.mem.Allocator,
    pos: u32 = 0,

    // -----------------------------------------------------------------------
    // トップレベル
    // -----------------------------------------------------------------------

    fn parseProgram(self: *Parser) ![]ast.Decl {
        var decls: std.ArrayListUnmanaged(ast.Decl) = .empty;
        while (!self.atEnd()) {
            // skip annotations at top level
            var annotations: std.ArrayListUnmanaged([]const u8) = .empty;
            while (self.check(.annotation)) {
                try annotations.append(self.arena, self.current().lexeme);
                self.pos += 1;
            }
            // skip modifiers before class/interface/enum
            const mods = self.parseModifiers();

            if (self.check(.class_kw)) {
                try decls.append(self.arena, .{ .class_decl = try self.parseClassDecl(mods, try annotations.toOwnedSlice(self.arena)) });
            } else if (self.check(.interface_kw)) {
                try decls.append(self.arena, .{ .interface_decl = try self.parseInterfaceDecl(mods) });
            } else if (self.check(.enum_kw)) {
                try decls.append(self.arena, .{ .enum_decl = try self.parseEnumDecl(mods) });
            } else {
                // skip unknown token
                self.pos += 1;
            }
        }
        return decls.toOwnedSlice(self.arena);
    }

    fn parseClassDecl(self: *Parser, mods: ast.Modifiers, annotations: [][]const u8) anyerror!*ast.ClassDecl {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'class'
        const name = try self.expectIdentifier();

        // sharing mode was parsed as modifiers — detect from preceding tokens
        const sharing: ast.SharingMode = .inherited;
        if (mods.is_abstract) {
            // could be abstract class, sharing inherited
        }
        // We check sharing by looking at modifier tokens already consumed
        // For now, sharing is handled by modifiers parse detecting 'with sharing'

        var super_class: ?TypeRef = null;
        if (self.matchKind(.extends_kw)) {
            super_class = try self.parseTypeRef();
        }

        var interfaces: std.ArrayListUnmanaged(TypeRef) = .empty;
        if (self.matchKind(.implements_kw)) {
            try interfaces.append(self.arena, try self.parseTypeRef());
            while (self.matchKind(.comma)) {
                try interfaces.append(self.arena, try self.parseTypeRef());
            }
        }

        try self.expect(.lbrace);
        const members = try self.parseClassBody();
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

    fn parseInterfaceDecl(self: *Parser, mods: ast.Modifiers) !*ast.InterfaceDecl {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'interface'
        const name = try self.expectIdentifier();

        var extends: std.ArrayListUnmanaged(TypeRef) = .empty;
        if (self.matchKind(.extends_kw)) {
            try extends.append(self.arena, try self.parseTypeRef());
            while (self.matchKind(.comma)) {
                try extends.append(self.arena, try self.parseTypeRef());
            }
        }

        try self.expect(.lbrace);
        // For now, skip interface body
        var depth: u32 = 1;
        while (!self.atEnd() and depth > 0) {
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

    fn parseEnumDecl(self: *Parser, mods: ast.Modifiers) !*ast.EnumDecl {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'enum'
        const name = try self.expectIdentifier();

        try self.expect(.lbrace);
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.atEnd() and !self.check(.rbrace)) {
            if (self.check(.identifier)) {
                try values.append(self.arena, self.current().lexeme);
                self.pos += 1;
                _ = self.matchKind(.comma);
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

    fn parseClassBody(self: *Parser) anyerror![]ast.Decl {
        var members: std.ArrayListUnmanaged(ast.Decl) = .empty;
        while (!self.atEnd() and !self.check(.rbrace)) {
            var annotations: std.ArrayListUnmanaged([]const u8) = .empty;
            while (self.check(.annotation)) {
                try annotations.append(self.arena, self.current().lexeme);
                self.pos += 1;
                // skip annotation params like @IsTest(seeAllData=true)
                if (self.matchKind(.lparen)) {
                    var depth: u32 = 1;
                    while (!self.atEnd() and depth > 0) {
                        if (self.check(.lparen)) depth += 1;
                        if (self.check(.rparen)) {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                        self.pos += 1;
                    }
                    try self.expect(.rparen);
                }
            }

            const mods = self.parseModifiers();

            if (self.check(.class_kw)) {
                try members.append(self.arena, .{ .class_decl = try self.parseClassDecl(mods, try annotations.toOwnedSlice(self.arena)) });
            } else if (self.check(.interface_kw)) {
                try members.append(self.arena, .{ .interface_decl = try self.parseInterfaceDecl(mods) });
            } else if (self.check(.enum_kw)) {
                try members.append(self.arena, .{ .enum_decl = try self.parseEnumDecl(mods) });
            } else if (self.check(.lbrace)) {
                // static initializer block — parse body
                self.pos += 1;
                const body = try self.parseBlock();
                try self.expect(.rbrace);
                try members.append(self.arena, .{ .static_init = body });
            } else {
                // method or field: Type name ( ... ) { ... } or Type name ;/=
                const member = try self.parseMethodOrField(mods, try annotations.toOwnedSlice(self.arena));
                try members.append(self.arena, member);
            }
        }
        return members.toOwnedSlice(self.arena);
    }

    fn parseMethodOrField(self: *Parser, mods: ast.Modifiers, annotations: [][]const u8) anyerror!ast.Decl {
        const loc = self.currentLoc();

        // Check for constructor: ClassName(
        // We need to look ahead: if current is identifier and next is lparen, it's a constructor
        if (self.check(.identifier) and self.peekKind(1) == .lparen) {
            return self.parseConstructor(mods, loc);
        }

        const type_ref = try self.parseTypeRef();

        // After type, if next is ( then it could be constructor with return type being class name
        if (self.check(.lparen)) {
            return self.parseConstructor(mods, loc);
        }

        const name = try self.expectIdentifier();

        // method: name followed by (
        if (self.matchKind(.lparen)) {
            const params = try self.parseParams();
            try self.expect(.rparen);
            var body: []ast.Stmt = &.{};
            if (self.matchKind(.lbrace)) {
                body = try self.parseBlock();
                try self.expect(.rbrace);
            } else {
                // abstract method or interface method
                _ = self.matchKind(.semicolon);
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

        // field
        var initializer: ?*ast.Expr = null;
        if (self.matchKind(.assign)) {
            initializer = try self.expression();
        }
        _ = self.matchKind(.semicolon);

        const decl = try self.arena.create(ast.FieldDecl);
        decl.* = .{
            .name = name,
            .modifiers = mods,
            .type_ref = type_ref,
            .initializer = initializer,
            .loc = loc,
        };
        return .{ .field_decl = decl };
    }

    fn parseConstructor(self: *Parser, mods: ast.Modifiers, loc: SourceLoc) anyerror!ast.Decl {
        // skip constructor name (already positioned at it or past type)
        if (self.check(.identifier)) self.pos += 1;
        try self.expect(.lparen);
        const params = try self.parseParams();
        try self.expect(.rparen);
        try self.expect(.lbrace);
        const body = try self.parseBlock();
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

    fn parseParams(self: *Parser) ![]ast.Param {
        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        if (self.check(.rparen)) return params.toOwnedSlice(self.arena);

        try params.append(self.arena, .{
            .type_ref = try self.parseTypeRef(),
            .name = try self.expectIdentifier(),
        });
        while (self.matchKind(.comma)) {
            try params.append(self.arena, .{
                .type_ref = try self.parseTypeRef(),
                .name = try self.expectIdentifier(),
            });
        }
        return params.toOwnedSlice(self.arena);
    }

    // -----------------------------------------------------------------------
    // 文 (Statement)
    // -----------------------------------------------------------------------

    fn parseBlock(self: *Parser) anyerror![]ast.Stmt {
        var stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        while (!self.atEnd() and !self.check(.rbrace)) {
            try stmts.append(self.arena, try self.parseStmt());
        }
        return stmts.toOwnedSlice(self.arena);
    }

    fn parseStmt(self: *Parser) anyerror!ast.Stmt {
        const kind = self.currentKind();

        if (kind == .if_kw) return self.parseIfStmt();
        if (kind == .for_kw) return self.parseForStmt();
        if (kind == .while_kw) return self.parseWhileStmt();
        if (kind == .do_kw) return self.parseDoWhileStmt();
        if (kind == .return_kw) return self.parseReturnStmt();
        if (kind == .break_kw) { self.pos += 1; _ = self.matchKind(.semicolon); return .break_stmt; }
        if (kind == .continue_kw) { self.pos += 1; _ = self.matchKind(.semicolon); return .continue_stmt; }
        if (kind == .switch_kw) return self.parseSwitchStmt();
        if (kind == .try_kw) return self.parseTryStmt();
        if (kind == .throw_kw) return self.parseThrowStmt();
        if (kind == .lbrace) return self.parseBlockStmt();

        // DML statements
        if (kind == .insert_kw or kind == .update_kw or kind == .upsert_kw or
            kind == .delete_kw or kind == .undelete_kw or kind == .merge_kw)
        {
            return self.parseDmlStmt();
        }

        // Variable declaration or expression statement
        // Heuristic: if it looks like Type name = ... or Type name ;
        if (self.looksLikeVarDecl()) {
            return self.parseVarDeclStmt();
        }

        // Expression statement
        const expr = try self.expression();

        // Handle System.runAs(user) { block } — treat as block execution
        if (self.check(.lbrace) and expr.* == .method_call) {
            const mc = expr.method_call;
            if (std.ascii.eqlIgnoreCase(mc.method, "runAs")) {
                self.pos += 1; // skip {
                const block_stmts = try self.parseBlock();
                try self.expect(.rbrace);
                return .{ .block = block_stmts };
            }
        }

        _ = self.matchKind(.semicolon);
        return .{ .expr_stmt = expr };
    }

    fn parseIfStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'if'
        try self.expect(.lparen);
        const condition = try self.expression();
        try self.expect(.rparen);

        const then_body = try self.parseSingleOrBlock();

        var else_body: ?[]ast.Stmt = null;
        if (self.matchKind(.else_kw)) {
            else_body = try self.parseSingleOrBlock();
        }

        const stmt = try self.arena.create(ast.IfStmt);
        stmt.* = .{ .condition = condition, .then_body = then_body, .else_body = else_body, .loc = loc };
        return .{ .if_stmt = stmt };
    }

    fn parseForStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'for'
        try self.expect(.lparen);

        // Detect for-each: Type name : expr
        if (self.looksLikeForEach()) {
            const elem_type = try self.parseTypeRef();
            const elem_name = try self.expectIdentifier();
            try self.expect(.colon);
            const iterable = try self.expression();
            try self.expect(.rparen);
            const body = try self.parseSingleOrBlock();

            const stmt = try self.arena.create(ast.ForEachStmt);
            stmt.* = .{ .elem_type = elem_type, .elem_name = elem_name, .iterable = iterable, .body = body, .loc = loc };
            return .{ .for_each_stmt = stmt };
        }

        // Traditional for: init; condition; update
        var init: ?*ast.Stmt = null;
        if (!self.check(.semicolon)) {
            const init_stmt = try self.arena.create(ast.Stmt);
            if (self.looksLikeVarDecl()) {
                init_stmt.* = try self.parseVarDeclStmt();
            } else {
                const expr = try self.expression();
                init_stmt.* = .{ .expr_stmt = expr };
            }
            init = init_stmt;
        }
        _ = self.matchKind(.semicolon);

        var condition: ?*ast.Expr = null;
        if (!self.check(.semicolon)) {
            condition = try self.expression();
        }
        _ = self.matchKind(.semicolon);

        var update: ?*ast.Expr = null;
        if (!self.check(.rparen)) {
            update = try self.expression();
        }
        try self.expect(.rparen);

        const body = try self.parseSingleOrBlock();

        const stmt = try self.arena.create(ast.ForStmt);
        stmt.* = .{ .init = init, .condition = condition, .update = update, .body = body, .loc = loc };
        return .{ .for_stmt = stmt };
    }

    fn parseWhileStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'while'
        try self.expect(.lparen);
        const condition = try self.expression();
        try self.expect(.rparen);
        const body = try self.parseSingleOrBlock();

        const stmt = try self.arena.create(ast.WhileStmt);
        stmt.* = .{ .condition = condition, .body = body, .loc = loc };
        return .{ .while_stmt = stmt };
    }

    fn parseDoWhileStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'do'
        try self.expect(.lbrace);
        const body = try self.parseBlock();
        try self.expect(.rbrace);
        try self.expect(.while_kw);
        try self.expect(.lparen);
        const condition = try self.expression();
        try self.expect(.rparen);
        _ = self.matchKind(.semicolon);

        const stmt = try self.arena.create(ast.DoWhileStmt);
        stmt.* = .{ .body = body, .condition = condition, .loc = loc };
        return .{ .do_while = stmt };
    }

    fn parseReturnStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'return'
        var value: ?*ast.Expr = null;
        if (!self.check(.semicolon) and !self.check(.rbrace)) {
            value = try self.expression();
        }
        _ = self.matchKind(.semicolon);

        const stmt = try self.arena.create(ast.ReturnStmt);
        stmt.* = .{ .value = value, .loc = loc };
        return .{ .return_stmt = stmt };
    }

    fn parseSwitchStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'switch'

        // Apex: 'switch on expr { when ... }'
        // skip 'on' if present
        if (self.check(.identifier) and std.ascii.eqlIgnoreCase(self.current().lexeme, "on")) {
            self.pos += 1;
        }

        const subject = try self.expression();
        try self.expect(.lbrace);

        var clauses: std.ArrayListUnmanaged(ast.WhenClause) = .empty;
        while (!self.atEnd() and !self.check(.rbrace)) {
            if (self.matchKind(.when_kw)) {
                if (self.check(.else_kw)) {
                    self.pos += 1;
                    try self.expect(.lbrace);
                    const body = try self.parseBlock();
                    try self.expect(.rbrace);
                    try clauses.append(self.arena, .{ .pattern = .else_clause, .body = body });
                } else {
                    // when value1, value2 { ... }
                    var values: std.ArrayListUnmanaged(ast.Expr) = .empty;
                    try values.append(self.arena, (try self.expression()).*);
                    while (self.matchKind(.comma)) {
                        try values.append(self.arena, (try self.expression()).*);
                    }
                    try self.expect(.lbrace);
                    const body = try self.parseBlock();
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
        stmt.* = .{ .subject = subject, .when_clauses = try clauses.toOwnedSlice(self.arena), .loc = loc };
        return .{ .switch_stmt = stmt };
    }

    fn parseTryStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'try'
        try self.expect(.lbrace);
        const body = try self.parseBlock();
        try self.expect(.rbrace);

        var catches: std.ArrayListUnmanaged(ast.CatchClause) = .empty;
        while (self.matchKind(.catch_kw)) {
            try self.expect(.lparen);
            const exception_type = try self.parseTypeRef();
            const name = try self.expectIdentifier();
            try self.expect(.rparen);
            try self.expect(.lbrace);
            const catch_body = try self.parseBlock();
            try self.expect(.rbrace);
            try catches.append(self.arena, .{
                .exception_type = exception_type,
                .name = name,
                .body = catch_body,
            });
        }

        var finally_body: ?[]ast.Stmt = null;
        if (self.matchKind(.finally_kw)) {
            try self.expect(.lbrace);
            finally_body = try self.parseBlock();
            try self.expect(.rbrace);
        }

        const stmt = try self.arena.create(ast.TryStmt);
        stmt.* = .{ .body = body, .catches = try catches.toOwnedSlice(self.arena), .finally_body = finally_body, .loc = loc };
        return .{ .try_stmt = stmt };
    }

    fn parseThrowStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'throw'
        const expr = try self.expression();
        _ = self.matchKind(.semicolon);

        const stmt = try self.arena.create(ast.ThrowStmt);
        stmt.* = .{ .expr = expr, .loc = loc };
        return .{ .throw_stmt = stmt };
    }

    fn parseDmlStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        const op: ast.DmlOp = switch (self.currentKind()) {
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
        if (self.check(.identifier) and std.ascii.eqlIgnoreCase(self.current().lexeme, "as")) {
            self.pos += 1; // skip 'as'
            if (self.check(.identifier) and (std.ascii.eqlIgnoreCase(self.current().lexeme, "system") or
                std.ascii.eqlIgnoreCase(self.current().lexeme, "user")))
            {
                self.pos += 1; // skip 'system'/'user'
            }
        }
        const target = try self.expression();
        _ = self.matchKind(.semicolon);

        const stmt = try self.arena.create(ast.DmlStmt);
        stmt.* = .{ .op = op, .target = target, .loc = loc };
        return .{ .dml_stmt = stmt };
    }

    fn parseBlockStmt(self: *Parser) !ast.Stmt {
        self.pos += 1; // skip {
        const stmts = try self.parseBlock();
        try self.expect(.rbrace);
        return .{ .block = stmts };
    }

    fn parseVarDeclStmt(self: *Parser) !ast.Stmt {
        const loc = self.currentLoc();
        const type_ref = try self.parseTypeRef();
        const name = try self.expectIdentifier();

        var initializer: ?*ast.Expr = null;
        if (self.matchKind(.assign)) {
            initializer = try self.expression();
        }
        _ = self.matchKind(.semicolon);

        const decl = try self.arena.create(ast.VarDecl);
        decl.* = .{ .type_ref = type_ref, .name = name, .initializer = initializer, .loc = loc };
        return .{ .var_decl = decl };
    }

    fn parseSingleOrBlock(self: *Parser) ![]ast.Stmt {
        if (self.matchKind(.lbrace)) {
            const stmts = try self.parseBlock();
            try self.expect(.rbrace);
            return stmts;
        }
        var stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try stmts.append(self.arena, try self.parseStmt());
        return stmts.toOwnedSlice(self.arena);
    }

    // -----------------------------------------------------------------------
    // 式 (Expression) — Pratt parsing
    // -----------------------------------------------------------------------

    fn expression(self: *Parser) anyerror!*ast.Expr {
        return self.parseAssignment();
    }

    fn parseAssignment(self: *Parser) !*ast.Expr {
        const expr = try self.parseTernary();

        const op: ?ast.AssignOp = switch (self.currentKind()) {
            .assign => .assign,
            .plus_assign => .plus_assign,
            .minus_assign => .minus_assign,
            .star_assign => .star_assign,
            .slash_assign => .slash_assign,
            else => null,
        };
        if (op) |assign_op| {
            const loc = self.currentLoc();
            self.pos += 1;
            const value = try self.parseAssignment(); // right-associative
            const node = try self.arena.create(ast.Assignment);
            node.* = .{ .target = expr, .op = assign_op, .value = value, .loc = loc };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .assignment = node };
            return result;
        }

        return expr;
    }

    fn parseTernary(self: *Parser) !*ast.Expr {
        const expr = try self.parseOr();

        if (self.matchKind(.question)) {
            const then_expr = try self.expression();
            try self.expect(.colon);
            const else_expr = try self.parseTernary();
            const node = try self.arena.create(ast.TernaryExpr);
            node.* = .{ .condition = expr, .then_expr = then_expr, .else_expr = else_expr };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .ternary = node };
            return result;
        }

        return expr;
    }

    fn parseOr(self: *Parser) !*ast.Expr {
        var left = try self.parseAnd();
        while (self.matchKind(.or_op)) {
            const right = try self.parseAnd();
            left = try self.makeBinary(left, .or_op, right);
        }
        return left;
    }

    fn parseAnd(self: *Parser) !*ast.Expr {
        var left = try self.parseEquality();
        while (self.matchKind(.and_op)) {
            const right = try self.parseEquality();
            left = try self.makeBinary(left, .and_op, right);
        }
        return left;
    }

    fn parseEquality(self: *Parser) !*ast.Expr {
        var left = try self.parseComparison();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.currentKind()) {
                .eq => .eq,
                .neq => .neq,
                .strict_eq => .strict_eq,
                .strict_neq => .strict_neq,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parseComparison();
                left = try self.makeBinary(left, binary_op, right);
            } else break;
        }
        return left;
    }

    fn parseComparison(self: *Parser) !*ast.Expr {
        var left = try self.parseAddition();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.currentKind()) {
                .lt => .lt,
                .gt => .gt,
                .lte => .lte,
                .gte => .gte,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parseAddition();
                left = try self.makeBinary(left, binary_op, right);
            } else break;
        }

        // instanceof
        if (self.matchKind(.instanceof_kw)) {
            const type_name = try self.parseTypeRef();
            const node = try self.arena.create(ast.InstanceofExpr);
            node.* = .{ .operand = left, .type_name = type_name };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .instanceof = node };
            return result;
        }

        return left;
    }

    fn parseAddition(self: *Parser) !*ast.Expr {
        var left = try self.parseMultiplication();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.currentKind()) {
                .plus => .add,
                .minus => .sub,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parseMultiplication();
                left = try self.makeBinary(left, binary_op, right);
            } else break;
        }
        return left;
    }

    fn parseMultiplication(self: *Parser) !*ast.Expr {
        var left = try self.parseUnary();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.currentKind()) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => null,
            };
            if (op) |binary_op| {
                self.pos += 1;
                const right = try self.parseUnary();
                left = try self.makeBinary(left, binary_op, right);
            } else break;
        }
        return left;
    }

    fn parseUnary(self: *Parser) !*ast.Expr {
        if (self.matchKind(.minus)) {
            const operand = try self.parseUnary();
            const node = try self.arena.create(ast.UnaryExpr);
            node.* = .{ .op = .negate, .operand = operand };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .unary = node };
            return result;
        }
        if (self.matchKind(.not_op)) {
            const operand = try self.parseUnary();
            const node = try self.arena.create(ast.UnaryExpr);
            node.* = .{ .op = .not, .operand = operand };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .unary = node };
            return result;
        }
        // Prefix ++ and -- → rewrite as x += 1 / x -= 1
        if (self.matchKind(.plus_plus)) {
            const operand = try self.parsePostfix();
            const one = try self.arena.create(ast.Expr);
            one.* = .{ .integer_literal = 1 };
            const node = try self.arena.create(ast.Assignment);
            node.* = .{ .target = operand, .op = .plus_assign, .value = one };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .assignment = node };
            return result;
        }
        if (self.matchKind(.minus_minus)) {
            const operand = try self.parsePostfix();
            const one = try self.arena.create(ast.Expr);
            one.* = .{ .integer_literal = 1 };
            const node = try self.arena.create(ast.Assignment);
            node.* = .{ .target = operand, .op = .minus_assign, .value = one };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .assignment = node };
            return result;
        }

        // Cast: (Type)expr — only if inside parens and looks like a type
        if (self.check(.lparen) and self.looksLikeCast()) {
            self.pos += 1; // skip (
            const target_type = try self.parseTypeRef();
            try self.expect(.rparen);
            const operand = try self.parseUnary();
            const node = try self.arena.create(ast.CastExpr);
            node.* = .{ .target_type = target_type, .operand = operand };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .cast_expr = node };
            return result;
        }

        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) !*ast.Expr {
        var expr = try self.parsePrimary();

        // super(args) → call to parent constructor
        if (expr.* == .super_expr and self.matchKind(.lparen)) {
            const args = try self.parseArgList();
            try self.expect(.rparen);
            const node = try self.arena.create(ast.CallExpr);
            node.* = .{ .callee = "super", .args = args };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .call = node };
            expr = result;
        }

        while (true) {
            if (self.matchKind(.dot) or self.matchKind(.question_dot)) {
                const field_name = try self.expectIdentifier();

                // method call: obj.method(args)
                if (self.matchKind(.lparen)) {
                    const args = try self.parseArgList();
                    try self.expect(.rparen);
                    const node = try self.arena.create(ast.MethodCallExpr);
                    node.* = .{ .object = expr, .method = field_name, .args = args };
                    const result = try self.arena.create(ast.Expr);
                    result.* = .{ .method_call = node };
                    expr = result;
                } else {
                    const node = try self.arena.create(ast.FieldAccess);
                    node.* = .{ .object = expr, .field = field_name };
                    const result = try self.arena.create(ast.Expr);
                    result.* = .{ .field_access = node };
                    expr = result;
                }
                continue;
            }
            if (self.matchKind(.lbracket)) {
                const index = try self.expression();
                try self.expect(.rbracket);
                const node = try self.arena.create(ast.IndexAccess);
                node.* = .{ .object = expr, .index = index };
                const result = try self.arena.create(ast.Expr);
                result.* = .{ .index_access = node };
                expr = result;
                continue;
            }
            // Postfix ++ and -- → rewrite as x += 1 / x -= 1
            if (self.matchKind(.plus_plus)) {
                const one = try self.arena.create(ast.Expr);
                one.* = .{ .integer_literal = 1 };
                const node = try self.arena.create(ast.Assignment);
                node.* = .{ .target = expr, .op = .plus_assign, .value = one };
                const result = try self.arena.create(ast.Expr);
                result.* = .{ .assignment = node };
                expr = result;
                continue;
            }
            if (self.matchKind(.minus_minus)) {
                const one = try self.arena.create(ast.Expr);
                one.* = .{ .integer_literal = 1 };
                const node = try self.arena.create(ast.Assignment);
                node.* = .{ .target = expr, .op = .minus_assign, .value = one };
                const result = try self.arena.create(ast.Expr);
                result.* = .{ .assignment = node };
                expr = result;
                continue;
            }
            break;
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) anyerror!*ast.Expr {
        const kind = self.currentKind();

        // Literals
        if (kind == .integer_literal) {
            const val = std.fmt.parseInt(i64, self.current().lexeme, 10) catch 0;
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .integer_literal = val };
            return result;
        }
        if (kind == .long_literal) {
            const lexeme = self.current().lexeme;
            const num_part = if (lexeme.len > 0 and (lexeme[lexeme.len - 1] == 'L' or lexeme[lexeme.len - 1] == 'l'))
                lexeme[0 .. lexeme.len - 1]
            else
                lexeme;
            const val = std.fmt.parseInt(i64, num_part, 10) catch 0;
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .integer_literal = val };
            return result;
        }
        if (kind == .double_literal) {
            const val = std.fmt.parseFloat(f64, self.current().lexeme) catch 0.0;
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .double_literal = val };
            return result;
        }
        if (kind == .string_literal) {
            const raw = self.current().lexeme;
            // strip quotes
            const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .string_literal = content };
            return result;
        }
        if (kind == .true_kw) {
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .boolean_literal = true };
            return result;
        }
        if (kind == .false_kw) {
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .boolean_literal = false };
            return result;
        }
        if (kind == .null_kw) {
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .null_literal;
            return result;
        }
        if (kind == .this_kw) {
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .this_expr;
            return result;
        }
        if (kind == .super_kw) {
            self.pos += 1;
            const result = try self.arena.create(ast.Expr);
            result.* = .super_expr;
            return result;
        }

        // SOQL literal
        if (kind == .soql_literal) {
            const raw = self.current().lexeme;
            const loc = self.currentLoc();
            self.pos += 1;
            const node = try self.arena.create(ast.SoqlExpr);
            node.* = .{ .raw = raw, .loc = loc };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .soql = node };
            return result;
        }

        // new expression
        if (kind == .new_kw) {
            return self.parseNewExpr();
        }

        // Grouped expression
        if (kind == .lparen) {
            self.pos += 1;
            const inner = try self.expression();
            try self.expect(.rparen);
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .grouped = inner };
            return result;
        }

        // Identifier (or function call)
        if (kind == .identifier) {
            const name = self.current().lexeme;
            const loc = self.currentLoc();
            self.pos += 1;

            // Function call: name(args)
            if (self.matchKind(.lparen)) {
                const args = try self.parseArgList();
                try self.expect(.rparen);
                const node = try self.arena.create(ast.CallExpr);
                node.* = .{ .callee = name, .args = args, .loc = loc };
                const result = try self.arena.create(ast.Expr);
                result.* = .{ .call = node };
                return result;
            }

            const result = try self.arena.create(ast.Expr);
            result.* = .{ .identifier = .{ .name = name, .loc = loc } };
            return result;
        }

        // Unexpected token — create a null literal as fallback
        self.pos += 1;
        const result = try self.arena.create(ast.Expr);
        result.* = .null_literal;
        return result;
    }

    fn parseNewExpr(self: *Parser) !*ast.Expr {
        self.pos += 1; // skip 'new'
        const loc = self.currentLoc();
        const type_name = try self.parseTypeRef();

        var args: []ast.Expr = &.{};
        if (self.matchKind(.lparen)) {
            args = try self.parseArgList();
            try self.expect(.rparen);
        }

        // Brace initializer: new List<T>{ item1, item2 } or new Map<K,V>{ key => value, ... }
        if (self.matchKind(.lbrace)) {
            var brace_args: std.ArrayListUnmanaged(ast.Expr) = .empty;
            if (!self.check(.rbrace)) {
                const first_expr = try self.expression();
                // Check if this is a map initializer with =>
                if (self.matchKind(.arrow)) {
                    // Map literal: key => value pairs
                    const first_val = try self.expression();
                    // Store as assignment: key = value
                    const asgn = try self.arena.create(ast.Assignment);
                    asgn.* = .{ .target = first_expr, .op = .assign, .value = first_val };
                    const pair = try self.arena.create(ast.Expr);
                    pair.* = .{ .assignment = asgn };
                    try brace_args.append(self.arena, pair.*);
                    while (self.matchKind(.comma)) {
                        if (self.check(.rbrace)) break;
                        const k = try self.expression();
                        _ = self.matchKind(.arrow);
                        const v = try self.expression();
                        const a2 = try self.arena.create(ast.Assignment);
                        a2.* = .{ .target = k, .op = .assign, .value = v };
                        const p2 = try self.arena.create(ast.Expr);
                        p2.* = .{ .assignment = a2 };
                        try brace_args.append(self.arena, p2.*);
                    }
                } else {
                    try brace_args.append(self.arena, first_expr.*);
                    while (self.matchKind(.comma)) {
                        if (self.check(.rbrace)) break;
                        try brace_args.append(self.arena, (try self.expression()).*);
                    }
                }
            }
            try self.expect(.rbrace);
            args = try brace_args.toOwnedSlice(self.arena);
        }

        const node = try self.arena.create(ast.NewExpr);
        node.* = .{ .type_name = type_name, .args = args, .loc = loc };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .new_expr = node };
        return result;
    }

    fn parseArgList(self: *Parser) ![]ast.Expr {
        var args: std.ArrayListUnmanaged(ast.Expr) = .empty;
        if (self.check(.rparen)) return args.toOwnedSlice(self.arena);

        try args.append(self.arena, (try self.expression()).*);
        while (self.matchKind(.comma)) {
            try args.append(self.arena, (try self.expression()).*);
        }
        return args.toOwnedSlice(self.arena);
    }

    // -----------------------------------------------------------------------
    // 型参照
    // -----------------------------------------------------------------------

    fn parseTypeRef(self: *Parser) !TypeRef {
        if (self.check(.void_kw)) {
            self.pos += 1;
            return .{ .name = "void" };
        }
        const name = try self.expectIdentifier();

        // Handle dotted names: System.Type
        var full_name = name;
        if (self.matchKind(.dot)) {
            if (self.check(.identifier)) {
                const second = self.current().lexeme;
                self.pos += 1;
                full_name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ name, second });
            }
        }

        // Generic params: <T, U>
        if (self.matchKind(.lt)) {
            var params: std.ArrayListUnmanaged(TypeRef) = .empty;
            try params.append(self.arena, try self.parseTypeRef());
            while (self.matchKind(.comma)) {
                try params.append(self.arena, try self.parseTypeRef());
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

        // Array notation: Type[]
        if (self.matchKind(.lbracket)) {
            if (self.matchKind(.rbracket)) {
                return .{ .name = "List", .params = &.{.{ .name = full_name }} };
            }
        }

        return .{ .name = full_name };
    }

    // -----------------------------------------------------------------------
    // ヒューリスティック
    // -----------------------------------------------------------------------

    /// Variable declaration looks like: Type name (= ...) ;
    fn looksLikeVarDecl(self: *Parser) bool {
        // Save position
        const saved = self.pos;
        defer self.pos = saved;

        // Try to skip type (including generic params)
        if (!self.check(.identifier) and !self.check(.void_kw)) return false;
        self.pos += 1;

        // skip dotted name
        if (self.matchKind(.dot)) {
            if (self.check(.identifier)) self.pos += 1;
        }

        // skip generic params
        if (self.check(.lt)) {
            var depth: u32 = 0;
            while (!self.atEnd()) {
                if (self.check(.lt)) depth += 1;
                if (self.check(.gt)) {
                    depth -= 1;
                    if (depth == 0) { self.pos += 1; break; }
                }
                self.pos += 1;
            }
        }

        // skip []
        if (self.check(.lbracket) and self.peekKind(1) == .rbracket) {
            self.pos += 2;
        }

        // Should be followed by an identifier (the variable name)
        return self.check(.identifier);
    }

    fn looksLikeForEach(self: *Parser) bool {
        // Scan forward in the parenthesized section to find ':'
        const saved = self.pos;
        defer self.pos = saved;

        var depth: u32 = 0;
        while (!self.atEnd()) {
            const k = self.currentKind();
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

    fn looksLikeCast(self: *Parser) bool {
        // (Type)expr — check if after ( there's an identifier followed by )
        const saved = self.pos;
        defer self.pos = saved;

        if (!self.check(.lparen)) return false;
        self.pos += 1; // skip (

        if (!self.check(.identifier)) return false;
        self.pos += 1;

        // skip dotted
        if (self.matchKind(.dot)) {
            if (self.check(.identifier)) self.pos += 1;
        }

        return self.check(.rparen);
    }

    // -----------------------------------------------------------------------
    // ヘルパー
    // -----------------------------------------------------------------------

    fn makeBinary(self: *Parser, left: *ast.Expr, op: ast.BinaryOp, right: *ast.Expr) !*ast.Expr {
        const node = try self.arena.create(ast.BinaryExpr);
        node.* = .{ .left = left, .op = op, .right = right };
        const result = try self.arena.create(ast.Expr);
        result.* = .{ .binary = node };
        return result;
    }

    fn parseModifiers(self: *Parser) ast.Modifiers {
        var mods = ast.Modifiers{};
        while (true) {
            switch (self.currentKind()) {
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
        // For robustness, don't crash — just skip
        return;
    }

    fn expectIdentifier(self: *Parser) ![]const u8 {
        if (self.check(.identifier)) {
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        // Fallback: use current token's lexeme
        if (!self.atEnd()) {
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        return "_unknown";
    }

    fn matchKind(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn check(self: *const Parser, kind: TokenKind) bool {
        return self.currentKind() == kind;
    }

    fn currentKind(self: *const Parser) TokenKind {
        if (self.pos >= self.tokens.len) return .eof;
        return self.tokens[self.pos].kind;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn currentLoc(self: *const Parser) SourceLoc {
        if (self.pos >= self.tokens.len) return .zero;
        return self.tokens[self.pos].loc;
    }

    fn peekKind(self: *const Parser, offset: u32) TokenKind {
        const idx = self.pos + offset;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx].kind;
    }

    fn atEnd(self: *const Parser) bool {
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
    const stmt = try p.parseStmt();

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
    const stmt = try p.parseStmt();

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
    const stmt = try p.parseStmt();
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
    const stmt = try p.parseStmt();
    try std.testing.expect(stmt == .dml_stmt);
    try std.testing.expectEqual(ast.DmlOp.insert, stmt.dml_stmt.op);
}

test "parse expression with method call chain" {
    const tokens = try lexer.tokenize("a.b.c(1, 2)", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseExpr(tokens, arena.allocator());
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
    const stmt = try p.parseStmt();
    try std.testing.expect(stmt == .switch_stmt);
    try std.testing.expectEqual(@as(usize, 2), stmt.switch_stmt.when_clauses.len);
}
