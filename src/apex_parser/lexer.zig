//! lexer — Apex ソーステキストをトークン列に変換する。
//!
//! Apex 固有: 単一引用符文字列リテラル `'hello'`、SOQL インライン `[SELECT ...]`、
//! DML キーワード (`insert`, `update` 等)、`switch on` 構文。
//! レキシムはソース文字列へのゼロコピースライス。

const std = @import("std");
const types = @import("types.zig");
const Token = types.Token;
const TokenKind = types.TokenKind;
const SourceLoc = types.SourceLoc;

pub fn tokenize(source: []const u8, arena: std.mem.Allocator) ![]Token {
    var lexer = Lexer{ .source = source, .arena = arena };
    return lexer.scan_all();
}

const Lexer = struct {
    source: []const u8,
    arena: std.mem.Allocator,
    pos: u32 = 0,
    line: u32 = 1,
    col: u32 = 1,

    fn scan_all(self: *Lexer) ![]Token {
        var tokens: std.ArrayListUnmanaged(Token) = .empty;
        while (true) {
            const tok = try self.next();
            try tokens.append(self.arena, tok);
            if (tok.kind == .eof) break;
        }
        return tokens.toOwnedSlice(self.arena);
    }

    fn next(self: *Lexer) !Token {
        self.skip_whitespace_and_comments();

        if (self.pos >= self.source.len) {
            return self.make_token(.eof, "");
        }

        const start = self.pos;
        const start_loc = self.loc();
        const c = self.source[self.pos];

        // 文字列リテラル (単一引用符)
        if (c == '\'') return self.scan_string(start, start_loc);

        // 数値リテラル
        if (std.ascii.isDigit(c)) return self.scan_number(start, start_loc);

        // 識別子・キーワード
        if (is_ident_start(c)) return self.scan_identifier(start, start_loc);

        // アノテーション
        if (c == '@') return self.scan_annotation(start, start_loc);

        // ドット始まり小数: .01, .5 etc.
        if (c == '.' and
            self.pos + 1 < self.source.len and
            std.ascii.isDigit(self.source[self.pos + 1]))
        {
            self.advance(); // skip '.'
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.advance();
            }
            return self.make_token_at(.double_literal, self.source[start..self.pos], start_loc);
        }

        // SOQL リテラル [SELECT ...]
        if (c == '[') {
            if (self.peek_soql()) return self.scan_soql(start, start_loc);
            self.advance();
            return self.make_token_at(.lbracket, self.source[start..self.pos], start_loc);
        }

        // 2文字・1文字演算子
        return self.scan_operator(start, start_loc);
    }

    fn scan_string(self: *Lexer, start: u32, start_loc: SourceLoc) !Token {
        self.advance(); // skip opening '
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '\\') {
                self.advance();
                if (self.pos < self.source.len) self.advance();
                continue;
            }
            if (self.source[self.pos] == '\'') {
                self.advance(); // skip closing '
                return self.make_token_at(.string_literal, self.source[start..self.pos], start_loc);
            }
            self.advance();
        }
        // 未終端文字列
        return self.make_token_at(.string_literal, self.source[start..self.pos], start_loc);
    }

    fn scan_number(self: *Lexer, start: u32, start_loc: SourceLoc) Token {
        var is_double = false;
        while (self.pos < self.source.len and
            (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '.'))
        {
            if (self.source[self.pos] == '.') {
                if (is_double) break; // second dot → stop
                is_double = true;
            }
            self.advance();
        }
        // long suffix (L/l)
        if (self.pos < self.source.len and
            (self.source[self.pos] == 'L' or self.source[self.pos] == 'l'))
        {
            self.advance();
            return self.make_token_at(.long_literal, self.source[start..self.pos], start_loc);
        }
        // double suffix (D/d)
        if (self.pos < self.source.len and
            (self.source[self.pos] == 'D' or self.source[self.pos] == 'd'))
        {
            self.advance();
            return self.make_token_at(.double_literal, self.source[start..self.pos], start_loc);
        }
        const kind: TokenKind = if (is_double) .double_literal else .integer_literal;
        return self.make_token_at(kind, self.source[start..self.pos], start_loc);
    }

    fn scan_identifier(self: *Lexer, start: u32, start_loc: SourceLoc) Token {
        while (self.pos < self.source.len and is_ident_cont(self.source[self.pos])) {
            self.advance();
        }
        const lexeme = self.source[start..self.pos];
        const kind = keyword_kind(lexeme) orelse .identifier;
        return self.make_token_at(kind, lexeme, start_loc);
    }

    fn scan_annotation(self: *Lexer, start: u32, start_loc: SourceLoc) Token {
        self.advance(); // skip @
        while (self.pos < self.source.len and is_ident_cont(self.source[self.pos])) {
            self.advance();
        }
        return self.make_token_at(.annotation, self.source[start..self.pos], start_loc);
    }

    fn peek_soql(self: *Lexer) bool {
        // Check if [ is followed by SELECT (case-insensitive), skipping whitespace including
        // newlines
        var i = self.pos + 1;
        while (i < self.source.len and (self.source[i] == ' ' or self.source[i] == '\t' or self.source[i] == '\n' or self.source[i] == '\r')) : (i += 1) {}
        if (i + 6 > self.source.len) return false;
        const word = self.source[i .. i + 6];
        if (std.ascii.eqlIgnoreCase(word, "select")) return true;
        // Check for FIND (4 chars followed by space or quote)
        if (i + 4 <= self.source.len) {
            const find_word = self.source[i .. i + 4];
            if (std.ascii.eqlIgnoreCase(find_word, "find") and
                (i + 4 >= self.source.len or self.source[i + 4] == ' ' or self.source[i + 4] == '\t' or self.source[i + 4] == '\n' or self.source[i + 4] == ':'))
            {
                return true;
            }
        }
        return false;
    }

    fn scan_soql(self: *Lexer, start: u32, start_loc: SourceLoc) Token {
        var depth: u32 = 0;
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '[') depth += 1;
            if (ch == ']') {
                depth -= 1;
                if (depth == 0) {
                    self.advance();
                    return self.make_token_at(
                        .soql_literal,
                        self.source[start..self.pos],
                        start_loc,
                    );
                }
            }
            // skip line comments inside SOQL (e.g. // comment with 'quotes')
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
                continue;
            }
            // skip block comments inside SOQL
            if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                self.advance();
                self.advance();
                while (self.pos + 1 < self.source.len) {
                    if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                        self.advance();
                        self.advance();
                        break;
                    }
                    self.advance();
                }
                continue;
            }
            // skip string literals inside SOQL
            if (ch == '\'') {
                self.advance();
                while (self.pos < self.source.len and self.source[self.pos] != '\'') {
                    if (self.source[self.pos] == '\\') self.advance();
                    self.advance();
                }
                if (self.pos < self.source.len) self.advance(); // closing '
                continue;
            }
            self.advance();
        }
        return self.make_token_at(.soql_literal, self.source[start..self.pos], start_loc);
    }

    fn emit_op(self: *Lexer, kind: TokenKind, start: u32, start_loc: SourceLoc) Token {
        return self.make_token_at(kind, self.source[start..self.pos], start_loc);
    }

    fn scan_plus(self: *Lexer, next_char: u8, start: u32, start_loc: SourceLoc) Token {
        if (next_char == '+') {
            self.advance();
            return self.emit_op(.plus_plus, start, start_loc);
        }
        if (next_char == '=') {
            self.advance();
            return self.emit_op(.plus_assign, start, start_loc);
        }
        return self.emit_op(.plus, start, start_loc);
    }

    fn scan_minus(self: *Lexer, next_char: u8, start: u32, start_loc: SourceLoc) Token {
        if (next_char == '-') {
            self.advance();
            return self.emit_op(.minus_minus, start, start_loc);
        }
        if (next_char == '=') {
            self.advance();
            return self.emit_op(.minus_assign, start, start_loc);
        }
        return self.emit_op(.minus, start, start_loc);
    }

    fn scan_eq(self: *Lexer, next_char: u8, start: u32, start_loc: SourceLoc) Token {
        if (next_char == '=') {
            self.advance();
            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                self.advance();
                return self.emit_op(.strict_eq, start, start_loc);
            }
            return self.emit_op(.eq, start, start_loc);
        }
        if (next_char == '>') {
            self.advance();
            return self.emit_op(.arrow, start, start_loc);
        }
        return self.emit_op(.assign, start, start_loc);
    }

    fn scan_bang(self: *Lexer, next_char: u8, start: u32, start_loc: SourceLoc) Token {
        if (next_char == '=') {
            self.advance();
            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                self.advance();
                return self.emit_op(.strict_neq, start, start_loc);
            }
            return self.emit_op(.neq, start, start_loc);
        }
        return self.emit_op(.not_op, start, start_loc);
    }

    fn scan_lt(self: *Lexer, next_char: u8, start: u32, start_loc: SourceLoc) Token {
        if (next_char == '=') {
            self.advance();
            return self.emit_op(.lte, start, start_loc);
        }
        if (next_char == '>') {
            self.advance();
            return self.emit_op(.neq, start, start_loc);
        }
        return self.emit_op(.lt, start, start_loc);
    }

    fn scan_gt(self: *Lexer, next_char: u8, start: u32, start_loc: SourceLoc) Token {
        if (next_char == '=') {
            self.advance();
            return self.emit_op(.gte, start, start_loc);
        }
        return self.emit_op(.gt, start, start_loc);
    }

    fn scan_question(self: *Lexer, next_char: u8, start: u32, start_loc: SourceLoc) Token {
        if (next_char == '?') {
            self.advance();
            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                self.advance();
                return self.emit_op(.question_question_equal, start, start_loc);
            }
            return self.emit_op(.question_question, start, start_loc);
        }
        if (next_char == '.') {
            self.advance();
            return self.emit_op(.question_dot, start, start_loc);
        }
        return self.emit_op(.question, start, start_loc);
    }

    fn scan_operator(self: *Lexer, start: u32, start_loc: SourceLoc) Token {
        const c = self.source[self.pos];
        self.advance();
        const next_char: u8 = if (self.pos < self.source.len) self.source[self.pos] else 0;

        return switch (c) {
            '+' => self.scan_plus(next_char, start, start_loc),
            '-' => self.scan_minus(next_char, start, start_loc),
            '*' => if (next_char == '=') blk: {
                self.advance();
                break :blk self.emit_op(.star_assign, start, start_loc);
            } else self.emit_op(.star, start, start_loc),
            '/' => if (next_char == '=') blk: {
                self.advance();
                break :blk self.emit_op(.slash_assign, start, start_loc);
            } else self.emit_op(.slash, start, start_loc),
            '%' => self.emit_op(.percent, start, start_loc),
            '=' => self.scan_eq(next_char, start, start_loc),
            '!' => self.scan_bang(next_char, start, start_loc),
            '<' => self.scan_lt(next_char, start, start_loc),
            '>' => self.scan_gt(next_char, start, start_loc),
            '&' => if (next_char == '&') blk: {
                self.advance();
                break :blk self.emit_op(.and_op, start, start_loc);
            } else self.emit_op(.ampersand, start, start_loc),
            '|' => if (next_char == '|') blk: {
                self.advance();
                break :blk self.emit_op(.or_op, start, start_loc);
            } else self.emit_op(.pipe, start, start_loc),
            '^' => self.emit_op(.caret, start, start_loc),
            '~' => self.emit_op(.not_op, start, start_loc),
            '(' => self.emit_op(.lparen, start, start_loc),
            ')' => self.emit_op(.rparen, start, start_loc),
            '{' => self.emit_op(.lbrace, start, start_loc),
            '}' => self.emit_op(.rbrace, start, start_loc),
            ']' => self.emit_op(.rbracket, start, start_loc),
            '.' => self.emit_op(.dot, start, start_loc),
            ',' => self.emit_op(.comma, start, start_loc),
            ';' => self.emit_op(.semicolon, start, start_loc),
            ':' => self.emit_op(.colon, start, start_loc),
            '?' => self.scan_question(next_char, start, start_loc),
            else => self.emit_op(.identifier, start, start_loc),
        };
    }

    fn skip_whitespace_and_comments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.advance();
                continue;
            }
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                self.col = 1;
                continue;
            }
            // 行コメント
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            // ブロックコメント
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                self.pos += 2;
                self.col += 2;
                while (self.pos + 1 < self.source.len) {
                    if (self.source[self.pos] == '\n') {
                        self.line += 1;
                        self.col = 1;
                        self.pos += 1;
                        continue;
                    }
                    if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                        self.pos += 2;
                        self.col += 2;
                        break;
                    }
                    self.pos += 1;
                    self.col += 1;
                }
                continue;
            }
            break;
        }
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
            self.col += 1;
        }
    }

    fn loc(self: *const Lexer) SourceLoc {
        return .{ .line = self.line, .col = self.col, .offset = self.pos };
    }

    fn make_token(self: *const Lexer, kind: TokenKind, lexeme: []const u8) Token {
        return .{ .kind = kind, .lexeme = lexeme, .loc = self.loc() };
    }

    fn make_token_at(
        _: *const Lexer,
        kind: TokenKind,
        lexeme: []const u8,
        token_loc: SourceLoc,
    ) Token {
        return .{ .kind = kind, .lexeme = lexeme, .loc = token_loc };
    }
};

fn is_ident_start(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn is_ident_cont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn keyword_kind(lexeme: []const u8) ?TokenKind {
    const map = std.StaticStringMap(TokenKind).initComptime(.{
        .{ "if", .if_kw },
        .{ "else", .else_kw },
        .{ "for", .for_kw },
        .{ "while", .while_kw },
        .{ "do", .do_kw },
        .{ "return", .return_kw },
        .{ "break", .break_kw },
        .{ "continue", .continue_kw },
        .{ "switch", .switch_kw },
        .{ "when", .when_kw },
        .{ "try", .try_kw },
        .{ "catch", .catch_kw },
        .{ "finally", .finally_kw },
        .{ "throw", .throw_kw },
        .{ "class", .class_kw },
        .{ "interface", .interface_kw },
        .{ "enum", .enum_kw },
        .{ "trigger", .trigger_kw },
        .{ "extends", .extends_kw },
        .{ "implements", .implements_kw },
        .{ "public", .public_kw },
        .{ "private", .private_kw },
        .{ "protected", .protected_kw },
        .{ "global", .global_kw },
        .{ "static", .static_kw },
        .{ "final", .final_kw },
        .{ "abstract", .abstract_kw },
        .{ "virtual", .virtual_kw },
        .{ "override", .override_kw },
        .{ "transient", .transient_kw },
        .{ "with", .with_kw },
        .{ "without", .without_kw },
        .{ "sharing", .sharing_kw },
        .{ "new", .new_kw },
        .{ "this", .this_kw },
        .{ "super", .super_kw },
        .{ "instanceof", .instanceof_kw },
        .{ "void", .void_kw },
        .{ "insert", .insert_kw },
        .{ "update", .update_kw },
        .{ "upsert", .upsert_kw },
        .{ "delete", .delete_kw },
        .{ "undelete", .undelete_kw },
        .{ "merge", .merge_kw },
        .{ "true", .true_kw },
        .{ "false", .false_kw },
        .{ "null", .null_kw },
    });

    // Apex keywords are case-insensitive — check lower-case variant
    var buf: [32]u8 = undefined;
    if (lexeme.len > buf.len) return null;
    for (lexeme, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return map.get(buf[0..lexeme.len]);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "tokenize string literal" {
    const tokens = try tokenize("'hello world'", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.string_literal, tokens[0].kind);
    try std.testing.expectEqualStrings("'hello world'", tokens[0].lexeme);
    try std.testing.expectEqual(TokenKind.eof, tokens[1].kind);
}

test "tokenize integer arithmetic" {
    const tokens = try tokenize("123 + 456", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len); // 123, +, 456, eof
    try std.testing.expectEqual(TokenKind.integer_literal, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.plus, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.integer_literal, tokens[2].kind);
}

test "tokenize equality operators" {
    const tokens = try tokenize("x == y === z != w !== v", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.identifier, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.eq, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.identifier, tokens[2].kind);
    try std.testing.expectEqual(TokenKind.strict_eq, tokens[3].kind);
    try std.testing.expectEqual(TokenKind.identifier, tokens[4].kind);
    try std.testing.expectEqual(TokenKind.neq, tokens[5].kind);
    try std.testing.expectEqual(TokenKind.identifier, tokens[6].kind);
    try std.testing.expectEqual(TokenKind.strict_neq, tokens[7].kind);
}

test "tokenize SOQL literal" {
    const tokens = try tokenize("[SELECT Id FROM Account]", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.soql_literal, tokens[0].kind);
    try std.testing.expectEqualStrings("[SELECT Id FROM Account]", tokens[0].lexeme);
}

test "tokenize keywords case-insensitive" {
    const tokens = try tokenize("Public Static Void", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.public_kw, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.static_kw, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.void_kw, tokens[2].kind);
}

test "tokenize DML keywords" {
    const tokens = try tokenize("insert update delete", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.insert_kw, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.update_kw, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.delete_kw, tokens[2].kind);
}

test "tokenize comments are skipped" {
    const tokens = try tokenize("x // comment\n+ y /* block */ + z", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    // x + y + z eof = 6 tokens
    try std.testing.expectEqual(@as(usize, 6), tokens.len);
    try std.testing.expectEqual(TokenKind.identifier, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.plus, tokens[1].kind);
}

test "tokenize annotation" {
    const tokens = try tokenize("@IsTest", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.annotation, tokens[0].kind);
    try std.testing.expectEqualStrings("@IsTest", tokens[0].lexeme);
}

test "tokenize double literal" {
    const tokens = try tokenize("3.14", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.double_literal, tokens[0].kind);
    try std.testing.expectEqualStrings("3.14", tokens[0].lexeme);
}
