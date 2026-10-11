//! types — Apex パーサーの共有型定義。
//!
//! SourceLoc（ソース位置）、Token、TokenKind、TypeRef を提供する。
//! ランタイム型 (Value 等) は含まない。

const std = @import("std");

// ---------------------------------------------------------------------------
// ソース位置
// ---------------------------------------------------------------------------

pub const SourceLoc = struct {
    line: u32 = 0,
    col: u32 = 0,
    offset: u32 = 0,

    pub const zero: SourceLoc = .{};

    /// byte 列 col を UTF-16 code unit オフセットに変換する。
    /// LSP は UTF-16 ベースの character を要求するため。
    pub fn utf16_col(self: SourceLoc, source: []const u8) u32 {
        // 該当行の先頭を見つける
        var line_start: u32 = self.offset;
        while (line_start > 0 and source[line_start - 1] != '\n') {
            line_start -= 1;
        }
        // line_start .. offset までの UTF-16 長を数える
        var utf16_units: u32 = 0;
        var i: u32 = line_start;
        while (i < self.offset and i < source.len) {
            const byte = source[i];
            const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            if (i + cp_len > source.len) break;
            const cp = std.unicode.utf8Decode(source[i..][0..cp_len]) catch {
                utf16_units += 1;
                i += 1;
                continue;
            };
            // BMP ではない場合 surrogate pair で 2 unit
            if (cp >= 0x10000) {
                utf16_units += 2;
            } else {
                utf16_units += 1;
            }
            i += cp_len;
        }
        return utf16_units;
    }
};

/// ソース範囲（開始位置 + 終了位置）。
pub const Span = struct {
    start: SourceLoc = .zero,
    end: SourceLoc = .zero,

    pub const zero: Span = .{};

    /// トークンから Span を作る。end は lexeme 末尾。
    pub fn from_token(tok: Token, source: []const u8) Span {
        const end_offset = tok.loc.offset + @as(u32, @intCast(tok.lexeme.len));
        // end の line/col を計算
        var line = tok.loc.line;
        var col = tok.loc.col;
        for (source[tok.loc.offset..@min(end_offset, @as(u32, @intCast(source.len)))]) |ch| {
            if (ch == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{
            .start = tok.loc,
            .end = .{ .line = line, .col = col, .offset = end_offset },
        };
    }
};

/// パーサー/レキサーが生成する診断情報。
pub const ParseDiagnostic = struct {
    message: []const u8,
    loc: SourceLoc = .zero,
    severity: ParseSeverity = .@"error",
};

pub const ParseSeverity = enum {
    @"error",
    warning,
    hint,
};

// ---------------------------------------------------------------------------
// トークン
// ---------------------------------------------------------------------------

pub const TokenKind = enum {
    // リテラル
    integer_literal,
    double_literal,
    string_literal,
    long_literal,
    true_kw,
    false_kw,
    null_kw,

    // 識別子
    identifier,

    // 制御キーワード
    if_kw,
    else_kw,
    for_kw,
    while_kw,
    do_kw,
    return_kw,
    break_kw,
    continue_kw,
    switch_kw,
    when_kw,
    try_kw,
    catch_kw,
    finally_kw,
    throw_kw,

    // 宣言キーワード
    class_kw,
    interface_kw,
    enum_kw,
    trigger_kw,
    extends_kw,
    implements_kw,
    public_kw,
    private_kw,
    protected_kw,
    global_kw,
    static_kw,
    final_kw,
    abstract_kw,
    virtual_kw,
    override_kw,
    transient_kw,
    with_kw,
    without_kw,
    sharing_kw,
    new_kw,
    this_kw,
    super_kw,
    instanceof_kw,
    void_kw,

    // DML キーワード
    insert_kw,
    update_kw,
    upsert_kw,
    delete_kw,
    undelete_kw,
    merge_kw,

    // アノテーション
    annotation,

    // 演算子
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    strict_eq,
    strict_neq,
    and_op,
    or_op,
    not_op,
    assign,
    plus_plus,
    minus_minus,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    ampersand_assign,
    caret_assign,
    pipe_assign,
    arrow,
    question,
    question_question,
    question_question_equal,
    question_dot,
    ampersand,
    caret,
    pipe,
    dot,
    comma,
    semicolon,
    colon,

    // 区切り文字
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,

    // 特殊
    soql_literal,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    loc: SourceLoc,
};

// ---------------------------------------------------------------------------
// 型参照 (AST 内で使用)
// ---------------------------------------------------------------------------

pub const TypeRef = struct {
    name: []const u8,
    params: []const TypeRef = &.{},
};
