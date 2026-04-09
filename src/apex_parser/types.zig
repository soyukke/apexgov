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
    arrow,
    question,
    question_dot,
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
