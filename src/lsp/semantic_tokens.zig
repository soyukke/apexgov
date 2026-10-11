//! semantic_tokens — トークン列から LSP SemanticTokens を生成する。
//!
//! LSP の SemanticTokens は相対エンコードされた u32 配列:
//! [deltaLine, deltaStartChar, length, tokenType, tokenModifiers] × N

const std = @import("std");
const types = @import("types.zig");
const parser_types = @import("../apex_parser/types.zig");
const Token = parser_types.Token;
const TokenKind = parser_types.TokenKind;
const SourceLoc = parser_types.SourceLoc;

/// トークンタイプインデックス（types.zig の token_types 配列と一致）。
const TT = struct {
    const keyword: u32 = 0;
    const type_name: u32 = 1;
    const variable: u32 = 2;
    const string: u32 = 3;
    const number: u32 = 4;
    const operator: u32 = 5;
    const comment: u32 = 6;
    const function_name: u32 = 7;
    const decorator: u32 = 8;
};

/// トークン列を LSP SemanticTokens の data 配列にエンコードする。
pub fn encode(tokens: []const Token, source: []const u8, allocator: std.mem.Allocator) ![]u32 {
    var data: std.ArrayList(u32) = .empty;
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    for (tokens) |tok| {
        if (tok.kind == .eof) continue;

        const token_type = classify_token(tok) orelse continue;

        const line = if (tok.loc.line > 0) tok.loc.line - 1 else 0;
        const char = tok.loc.utf16_col(source);
        const length: u32 = @intCast(tok.lexeme.len);

        const delta_line = line - prev_line;
        const delta_char = if (delta_line == 0) char - prev_char else char;

        try data.append(allocator, delta_line);
        try data.append(allocator, delta_char);
        try data.append(allocator, length);
        try data.append(allocator, token_type);
        try data.append(allocator, 0); // modifiers

        prev_line = line;
        prev_char = char;
    }

    return data.toOwnedSlice(allocator);
}

fn classify_token(tok: Token) ?u32 {
    return switch (tok.kind) {
        // キーワード / 宣言 / 修飾子 / DML / リテラル
        .if_kw, .else_kw, .for_kw, .while_kw, .do_kw => TT.keyword,
        .return_kw, .break_kw, .continue_kw, .switch_kw, .when_kw => TT.keyword,
        .try_kw, .catch_kw, .finally_kw, .throw_kw, .new_kw => TT.keyword,
        .this_kw, .super_kw, .instanceof_kw, .void_kw => TT.keyword,
        .class_kw, .interface_kw, .enum_kw, .trigger_kw => TT.keyword,
        .extends_kw, .implements_kw => TT.keyword,
        .public_kw, .private_kw, .protected_kw, .global_kw => TT.keyword,
        .static_kw, .final_kw, .abstract_kw, .virtual_kw => TT.keyword,
        .override_kw, .transient_kw => TT.keyword,
        .with_kw, .without_kw, .sharing_kw => TT.keyword,
        .insert_kw, .update_kw, .upsert_kw => TT.keyword,
        .delete_kw, .undelete_kw, .merge_kw => TT.keyword,
        .true_kw, .false_kw, .null_kw => TT.keyword,
        .string_literal, .soql_literal => TT.string,
        .integer_literal, .double_literal, .long_literal => TT.number,

        // アノテーション
        .annotation => TT.decorator,

        // 演算子
        .plus, .minus, .star, .slash, .percent => TT.operator,
        .eq, .neq, .lt, .gt, .lte, .gte => TT.operator,
        .strict_eq, .strict_neq => TT.operator,
        .and_op, .or_op, .not_op => TT.operator,
        .assign, .plus_assign, .minus_assign => TT.operator,
        .star_assign, .slash_assign => TT.operator,
        .ampersand_assign, .caret_assign, .pipe_assign => TT.operator,
        .arrow, .question, .question_question => TT.operator,
        .question_question_equal, .question_dot => TT.operator,
        .ampersand, .caret, .pipe => TT.operator,

        // 識別子 — 今は全て variable として分類（型推論は Phase 2+）
        .identifier => TT.variable,

        // 区切り文字・その他は非ハイライト
        .dot, .comma, .semicolon, .colon => null,
        .lparen, .rparen, .lbrace, .rbrace => null,
        .lbracket, .rbracket => null,
        .plus_plus, .minus_minus, .eof => null,
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");

test "keyword tokens encoded correctly" {
    const source = "public class Foo";
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    const data = try encode(tokens, source, std.testing.allocator);
    defer std.testing.allocator.free(data);

    // 3 tokens: public(kw), class(kw), Foo(variable)
    // 各5要素 → 15 要素
    try std.testing.expectEqual(@as(usize, 15), data.len);

    // "public": deltaLine=0, deltaChar=0, len=6, type=keyword(0), mod=0
    try std.testing.expectEqual(@as(u32, 0), data[0]); // deltaLine
    try std.testing.expectEqual(@as(u32, 0), data[1]); // deltaChar
    try std.testing.expectEqual(@as(u32, 6), data[2]); // length
    try std.testing.expectEqual(TT.keyword, data[3]); // tokenType

    // "class": deltaLine=0, deltaChar=7, len=5, type=keyword(0)
    try std.testing.expectEqual(@as(u32, 0), data[5]); // deltaLine
    try std.testing.expectEqual(@as(u32, 7), data[6]); // deltaChar
    try std.testing.expectEqual(@as(u32, 5), data[7]); // length
    try std.testing.expectEqual(TT.keyword, data[8]);

    // "Foo": deltaLine=0, deltaChar=6, len=3, type=variable(2)
    try std.testing.expectEqual(@as(u32, 0), data[10]);
    try std.testing.expectEqual(@as(u32, 6), data[11]);
    try std.testing.expectEqual(@as(u32, 3), data[12]);
    try std.testing.expectEqual(TT.variable, data[13]);
}

test "multiline delta encoding" {
    const source = "public\nclass";
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    const data = try encode(tokens, source, std.testing.allocator);
    defer std.testing.allocator.free(data);

    // "public" on line 0, "class" on line 1
    try std.testing.expectEqual(@as(u32, 0), data[0]); // public: deltaLine=0
    try std.testing.expectEqual(@as(u32, 1), data[5]); // class: deltaLine=1
    try std.testing.expectEqual(@as(u32, 0), data[6]); // class: deltaChar=0 (new line)
}

test "string literal gets string type" {
    const source = "'hello'";
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    const data = try encode(tokens, source, std.testing.allocator);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqual(@as(usize, 5), data.len);
    try std.testing.expectEqual(TT.string, data[3]);
}

test "number literal gets number type" {
    const source = "42";
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    const data = try encode(tokens, source, std.testing.allocator);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqual(TT.number, data[3]);
}

test "annotation gets decorator type" {
    const source = "@isTest";
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    const data = try encode(tokens, source, std.testing.allocator);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqual(TT.decorator, data[3]);
}

test "semicolons and braces are skipped" {
    const source = "{ ; }";
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    const data = try encode(tokens, source, std.testing.allocator);
    defer std.testing.allocator.free(data);

    // All tokens are punctuation → no semantic tokens
    try std.testing.expectEqual(@as(usize, 0), data.len);
}
