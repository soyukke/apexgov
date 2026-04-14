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
    return p.parseProgram();
}

/// 診断情報付きでパースする。LSP 向け。
pub fn parseWithDiagnostics(tokens: []const Token, arena: std.mem.Allocator) !ParseResult {
    var p = Parser{ .tokens = tokens, .arena = arena };
    const decls = try p.parseProgram();
    return .{
        .decls = decls,
        .diagnostics = try p.diagnostics.toOwnedSlice(arena),
    };
}

pub fn parseExpr(tokens: []const Token, arena: std.mem.Allocator) !*ast.Expr {
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
            } else if (self.check(.trigger_kw)) {
                try decls.append(self.arena, .{ .trigger_decl = try self.parseTriggerDecl() });
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

    fn parseTriggerDecl(self: *Parser) !*ast.TriggerDecl {
        const loc = self.currentLoc();
        self.pos += 1; // skip 'trigger'
        const name = try self.expectIdentifier();

        // skip 'on'
        if (self.check(.identifier) and std.ascii.eqlIgnoreCase(self.current().lexeme, "on")) {
            self.pos += 1;
        }

        // object name
        const object_name = try self.expectIdentifier();

        // parse event list: (before insert, after insert, ...)
        try self.expect(.lparen);
        var events: std.ArrayListUnmanaged(ast.TriggerEvent) = .empty;
        while (!self.atEnd() and !self.check(.rparen)) {
            // Parse "before"/"after" + "insert"/"update"/"delete"/"undelete"
            if (self.check(.identifier)) {
                const timing = self.current().lexeme;
                self.pos += 1;
                // The DML keyword may be a keyword token or identifier
                const op_lexeme = if (!self.atEnd()) self.current().lexeme else "";
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
            _ = self.matchKind(.comma);
        }
        try self.expect(.rparen);

        // parse body { ... }
        try self.expect(.lbrace);
        const body = try self.parseBlock();
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

    fn parseClassBody(self: *Parser) anyerror![]ast.Decl {
        var members: std.ArrayListUnmanaged(ast.Decl) = .empty;
        while (!self.atEnd() and !self.check(.rbrace)) {
            var annotations: std.ArrayListUnmanaged([]const u8) = .empty;
            while (self.check(.annotation)) {
                const ann_lexeme = self.current().lexeme;
                self.pos += 1;
                // Capture annotation params like @IsTest(seeAllData=true)
                if (self.matchKind(.lparen)) {
                    // Build full annotation string with params
                    const param_start = self.pos;
                    var depth: u32 = 1;
                    while (!self.atEnd() and depth > 0) {
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

        // Method/field name — keywords like 'when', 'with' can be member names in Apex
        const name = try self.expectIdentifierOrKeyword();

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

        // field or property
        var initializer: ?*ast.Expr = null;
        var getter_body: ?[]ast.Stmt = null;
        var setter_body: ?[]ast.Stmt = null;

        if (self.matchKind(.lbrace)) {
            // Property declaration: Type name { get { ... } set { ... } }
            while (!self.atEnd() and !self.check(.rbrace)) {
                // Skip modifiers like 'private', 'public' before get/set
                while (self.check(.private_kw) or self.check(.public_kw) or self.check(.protected_kw)) {
                    self.pos += 1;
                }
                if (self.check(.identifier)) {
                    const accessor = self.current().lexeme;
                    self.pos += 1;
                    if (std.ascii.eqlIgnoreCase(accessor, "get")) {
                        if (self.matchKind(.lbrace)) {
                            getter_body = try self.parseBlock();
                            try self.expect(.rbrace);
                        } else {
                            _ = self.matchKind(.semicolon);
                        }
                    } else if (std.ascii.eqlIgnoreCase(accessor, "set")) {
                        if (self.matchKind(.lbrace)) {
                            setter_body = try self.parseBlock();
                            try self.expect(.rbrace);
                        } else {
                            _ = self.matchKind(.semicolon);
                        }
                    }
                } else {
                    // Skip unknown tokens
                    self.pos += 1;
                }
            }
            try self.expect(.rbrace);
        } else {
            if (self.matchKind(.assign)) {
                initializer = try self.expression();
            }
            // Handle comma-separated field declarations: Type a, b, c;
            while (self.matchKind(.comma)) {
                _ = try self.expectIdentifier();
                if (self.matchKind(.assign)) {
                    _ = try self.expression();
                }
            }
            _ = self.matchKind(.semicolon);
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

        // Skip optional 'final' modifier on parameter
        _ = self.matchKind(.final_kw);
        try params.append(self.arena, .{
            .type_ref = try self.parseTypeRef(),
            .name = try self.expectIdentifier(),
        });
        while (self.matchKind(.comma)) {
            _ = self.matchKind(.final_kw);
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
        if (kind == .break_kw) {
            self.pos += 1;
            _ = self.matchKind(.semicolon);
            return .break_stmt;
        }
        if (kind == .continue_kw) {
            self.pos += 1;
            _ = self.matchKind(.semicolon);
            return .continue_stmt;
        }
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

        // 'final' local variable: final Type name = ...
        if (kind == .final_kw) {
            self.pos += 1; // skip 'final'
            if (self.looksLikeVarDecl()) {
                return self.parseVarDeclStmt();
            }
            // final not followed by var decl — treat as expression fallthrough
            self.pos -= 1;
        }

        // Variable declaration or expression statement
        // Heuristic: if it looks like Type name = ... or Type name ;
        if (self.looksLikeVarDecl()) {
            return self.parseVarDeclStmt();
        }

        // Expression statement
        const expr = try self.expression();

        // Handle System.runAs(user) { block } — scoped restricted user context
        if (self.check(.lbrace) and expr.* == .method_call) {
            const mc = expr.method_call;
            if (std.ascii.eqlIgnoreCase(mc.method, "runAs")) {
                self.pos += 1; // skip {
                const block_stmts = try self.parseBlock();
                try self.expect(.rbrace);
                const run_as = try self.arena.create(ast.RunAsStmt);
                run_as.* = .{
                    .user_expr = if (mc.args.len > 0) &mc.args[0] else expr,
                    .body = block_stmts,
                };
                return .{ .run_as_stmt = run_as };
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
                // Handle multiple var decls: Integer i = 0, j = list.size()
                while (self.matchKind(.comma)) {
                    if (self.check(.identifier) and (self.peekKind(1) == .assign or self.peekKind(1) == .semicolon or self.peekKind(1) == .comma)) {
                        // name = expr or name;
                        _ = try self.expectIdentifier();
                        if (self.matchKind(.assign)) {
                            _ = try self.expression();
                        }
                    }
                }
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
                    // OR: when TypeName varName { ... } (type-binding pattern)
                    var values: std.ArrayListUnmanaged(ast.Expr) = .empty;
                    try values.append(self.arena, (try self.expression()).*);
                    // Type-binding pattern: when Ident Ident { — skip the variable name
                    if (self.check(.identifier) and self.peekKind(1) == .lbrace) {
                        self.pos += 1; // skip variable name
                    } else {
                        while (self.matchKind(.comma)) {
                            try values.append(self.arena, (try self.expression()).*);
                        }
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
        _ = self.matchKind(.semicolon);

        const stmt = try self.arena.create(ast.DmlStmt);
        stmt.* = .{ .op = op, .target = target, .is_user_mode = is_user_mode, .loc = loc };
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
        const expr = try self.parseNullCoalesce();

        const op: ?ast.AssignOp = switch (self.currentKind()) {
            .assign => .assign,
            .plus_assign => .plus_assign,
            .minus_assign => .minus_assign,
            .star_assign => .star_assign,
            .slash_assign => .slash_assign,
            .question_question_equal => .null_coalesce_assign,
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

    /// Null-coalescing: a ?? b (right-associative, lower than ternary)
    fn parseNullCoalesce(self: *Parser) !*ast.Expr {
        var expr = try self.parseTernary();
        while (self.matchKind(.question_question)) {
            const right = try self.parseTernary();
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
        var left = try self.parseBitwiseOr();
        while (self.matchKind(.and_op)) {
            const right = try self.parseBitwiseOr();
            left = try self.makeBinary(left, .and_op, right);
        }
        return left;
    }

    fn parseBitwiseOr(self: *Parser) !*ast.Expr {
        var left = try self.parseBitwiseXor();
        while (self.matchKind(.pipe)) {
            const right = try self.parseBitwiseXor();
            left = try self.makeBinary(left, .or_op, right);
        }
        return left;
    }

    fn parseBitwiseXor(self: *Parser) !*ast.Expr {
        var left = try self.parseBitwiseAnd();
        while (self.matchKind(.caret)) {
            const right = try self.parseBitwiseAnd();
            // XOR — reuse neq in AST for simplicity
            left = try self.makeBinary(left, .neq, right);
        }
        return left;
    }

    fn parseBitwiseAnd(self: *Parser) !*ast.Expr {
        var left = try self.parseEquality();
        while (self.matchKind(.ampersand)) {
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
        var left = try self.parseShift();
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
                const right = try self.parseShift();
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

    /// Shift operators: << >> >>> — detected as consecutive < or > tokens
    fn parseShift(self: *Parser) !*ast.Expr {
        var left = try self.parseAddition();
        while (true) {
            // << : two consecutive lt tokens
            if (self.check(.lt) and self.peekKind(1) == .lt) {
                self.pos += 2;
                const right = try self.parseAddition();
                left = try self.makeBinary(left, .mul, right); // reuse mul for shift in AST
                continue;
            }
            // >>> : three consecutive gt tokens
            if (self.check(.gt) and self.peekKind(1) == .gt and self.peekKind(2) == .gt) {
                self.pos += 3;
                const right = try self.parseAddition();
                left = try self.makeBinary(left, .div, right); // reuse div for unsigned shift
                continue;
            }
            // >> : two consecutive gt tokens
            if (self.check(.gt) and self.peekKind(1) == .gt) {
                self.pos += 2;
                const right = try self.parseAddition();
                left = try self.makeBinary(left, .div, right); // reuse div for shift
                continue;
            }
            break;
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
        // Unary plus: +expr — just parse the operand (no-op)
        if (self.matchKind(.plus)) {
            return self.parseUnary();
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

        // super(args) / this(args) → constructor delegation
        if ((expr.* == .super_expr or expr.* == .this_expr) and self.matchKind(.lparen)) {
            const callee_name: []const u8 = if (expr.* == .super_expr) "super" else "this";
            const args = try self.parseArgList();
            try self.expect(.rparen);
            const node = try self.arena.create(ast.CallExpr);
            node.* = .{ .callee = callee_name, .args = args };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .call = node };
            expr = result;
        }

        while (true) {
            const is_null_safe = self.check(.question_dot);
            if (self.matchKind(.dot) or self.matchKind(.question_dot)) {
                const field_name = try self.expectIdentifierOrKeyword();

                // method call: obj.method(args)
                if (self.matchKind(.lparen)) {
                    const args = try self.parseArgList();
                    try self.expect(.rparen);
                    const node = try self.arena.create(ast.MethodCallExpr);
                    node.* = .{ .object = expr, .method = field_name, .args = args, .null_safe = is_null_safe };
                    const result = try self.arena.create(ast.Expr);
                    result.* = .{ .method_call = node };
                    expr = result;
                } else {
                    const node = try self.arena.create(ast.FieldAccess);
                    node.* = .{ .object = expr, .field = field_name, .null_safe = is_null_safe };
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
            const quoted = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            // Process escape sequences
            const content = blk: {
                // Quick check: if no backslash, return as-is
                if (std.mem.indexOf(u8, quoted, "\\") == null) break :blk quoted;
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                var ci: usize = 0;
                while (ci < quoted.len) : (ci += 1) {
                    if (quoted[ci] == '\\' and ci + 1 < quoted.len) {
                        ci += 1;
                        switch (quoted[ci]) {
                            'n' => buf.append(self.arena, '\n') catch break :blk quoted,
                            't' => buf.append(self.arena, '\t') catch break :blk quoted,
                            'r' => buf.append(self.arena, '\r') catch break :blk quoted,
                            '\\' => buf.append(self.arena, '\\') catch break :blk quoted,
                            '\'' => buf.append(self.arena, '\'') catch break :blk quoted,
                            '"' => buf.append(self.arena, '"') catch break :blk quoted,
                            else => |ch| {
                                // Keep unknown escapes as-is (e.g., \s, \*)
                                buf.append(self.arena, '\\') catch break :blk quoted;
                                buf.append(self.arena, ch) catch break :blk quoted;
                            },
                        }
                    } else {
                        buf.append(self.arena, quoted[ci]) catch break :blk quoted;
                    }
                }
                break :blk buf.items;
            };
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

        // Identifier (or function call) — trigger_kw also acts as identifier in expression context
        if (kind == .identifier or kind == .trigger_kw) {
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

            // Handle Type<T>.class → type literal (common in JSON.deserialize calls)
            if (self.check(.lt) and self.looksLikeTypeDotClass()) {
                // Build full type name including generics: e.g. "List<Contact>"
                var full_name_buf: std.ArrayListUnmanaged(u8) = .empty;
                try full_name_buf.appendSlice(self.arena, name);
                var depth: u32 = 0;
                while (!self.atEnd()) {
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
                // Skip .class
                if (self.matchKind(.dot)) {
                    if (!self.matchKind(.class_kw)) {
                        _ = self.matchKind(.identifier);
                    }
                }
                const full_type_name = try full_name_buf.toOwnedSlice(self.arena);
                // Return the type name as a new_expr for type reference
                const type_obj = try self.arena.create(ast.NewExpr);
                type_obj.* = .{ .type_name = .{ .name = full_type_name }, .args = &.{}, .loc = loc };
                const result = try self.arena.create(ast.Expr);
                result.* = .{ .new_expr = type_obj };
                return result;
            }

            // Handle Type[].class → array type literal
            if (self.check(.lbracket) and self.peekKind(1) == .rbracket and self.peekKind(2) == .dot) {
                self.pos += 2; // skip []
                if (self.matchKind(.dot)) {
                    if (!self.matchKind(.class_kw)) {
                        _ = self.matchKind(.identifier);
                    }
                }
                const arr_name = try std.fmt.allocPrint(self.arena, "{s}[]", .{name});
                const type_obj = try self.arena.create(ast.NewExpr);
                type_obj.* = .{ .type_name = .{ .name = arr_name }, .args = &.{}, .loc = loc };
                const result = try self.arena.create(ast.Expr);
                result.* = .{ .new_expr = type_obj };
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

        // Array size: new Type[size] — e.g. new String[0], new Account[n]
        if (self.matchKind(.lbracket)) {
            const size_expr = try self.expression();
            try self.expect(.rbracket);
            var arr_args: std.ArrayListUnmanaged(ast.Expr) = .empty;
            try arr_args.append(self.arena, size_expr.*);
            const node = try self.arena.create(ast.NewExpr);
            node.* = .{ .type_name = type_name, .args = try arr_args.toOwnedSlice(self.arena), .loc = loc };
            const result = try self.arena.create(ast.Expr);
            result.* = .{ .new_expr = node };
            return result;
        }

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

        // Handle dotted names: System.Type, Messaging.inboundEmail.BinaryAttachment
        var full_name = name;
        while (self.check(.dot) and self.peekKind(1) == .identifier) {
            self.pos += 1; // skip dot
            const next_part = self.current().lexeme;
            self.pos += 1;
            full_name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ full_name, next_part });
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

        // Array notation: Type[] (only if followed immediately by ])
        if (self.check(.lbracket) and self.peekKind(1) == .rbracket) {
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
    fn looksLikeVarDecl(self: *Parser) bool {
        // Save position
        const saved = self.pos;
        defer self.pos = saved;

        // Try to skip type (including generic params)
        if (!self.check(.identifier) and !self.check(.void_kw)) return false;
        self.pos += 1;

        // skip dotted name (multi-level: A.B.C)
        while (self.check(.dot) and self.peekKind(1) == .identifier) {
            self.pos += 2;
        }

        // skip generic params
        if (self.check(.lt)) {
            var depth: u32 = 0;
            while (!self.atEnd()) {
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

    /// Check if we're looking at Ident<...>.class pattern (type literal expression)
    fn looksLikeTypeDotClass(self: *Parser) bool {
        const saved = self.pos;
        defer self.pos = saved;

        if (!self.check(.lt)) return false;
        var depth: u32 = 0;
        while (!self.atEnd()) {
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
            // comma at depth 0 means we're not in generics; inside <...> commas are param separators
            if (self.check(.comma) and depth == 0) return false;
            self.pos += 1;
        }
        return false;
    }

    fn looksLikeCast(self: *Parser) bool {
        // (Type)expr — check if after ( there's a type reference followed by )
        const saved = self.pos;
        defer self.pos = saved;

        if (!self.check(.lparen)) return false;
        self.pos += 1; // skip (

        if (!self.check(.identifier)) return false;
        self.pos += 1;

        // skip dotted name (multi-level: A.B.C)
        while (self.check(.dot) and self.peekKind(1) == .identifier) {
            self.pos += 2;
        }

        // skip generic params: <T, U, ...>
        if (self.check(.lt)) {
            var depth: u32 = 0;
            while (!self.atEnd()) {
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
        if (self.check(.lbracket) and self.peekKind(1) == .rbracket) {
            self.pos += 2;
        }

        if (!self.check(.rparen)) return false;
        // After ')' must come an expression-start token, not an operator / ';' / '{'
        // to distinguish (Type)expr cast from (expr) grouping
        const after_rparen = self.peekKind(1);
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
        try self.addDiagnostic(self.currentLoc(), kind);
    }

    fn expectIdentifier(self: *Parser) ![]const u8 {
        if (self.check(.identifier)) {
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        // Fallback: use current token's lexeme
        if (!self.atEnd()) {
            try self.addDiagnostic(self.currentLoc(), .identifier);
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        try self.addDiagnostic(self.currentLoc(), .identifier);
        return "_unknown";
    }

    /// ドットの後に来る識別子を期待するが、Apex ではキーワードも
    /// フィールド名として使える（例: Trigger.new, Account.class）。
    fn expectIdentifierOrKeyword(self: *Parser) ![]const u8 {
        if (self.check(.identifier)) {
            const name = self.current().lexeme;
            self.pos += 1;
            return name;
        }
        // Apex ではキーワードもフィールド/メソッド名として出現しうる
        const kind = self.currentKind();
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
        // 本当に識別子が必要な場合は通常の expectIdentifier にフォールバック
        return self.expectIdentifier();
    }

    fn addDiagnostic(self: *Parser, loc: SourceLoc, expected: TokenKind) !void {
        const got_name = if (!self.atEnd()) @tagName(self.current().kind) else "end of file";
        const msg = try std.fmt.allocPrint(self.arena, "expected {s}, got {s}", .{
            @tagName(expected),
            got_name,
        });
        try self.diagnostics.append(self.arena, .{
            .message = msg,
            .loc = loc,
        });
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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

    const result = try parseWithDiagnostics(tokens, arena.allocator());
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
    const result = try parseWithDiagnostics(tokens, arena.allocator());
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
    const result = try parseWithDiagnostics(tokens, arena.allocator());
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
    const result = try parseWithDiagnostics(tokens, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
