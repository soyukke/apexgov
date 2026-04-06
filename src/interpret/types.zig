//! types — Apex インタープリターの共有型定義。
//!
//! Value（ランタイム値）、SourceLoc（ソース位置）、Token、AST で使う TypeRef 等を提供する。

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
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
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

// ---------------------------------------------------------------------------
// ランタイム値
// ---------------------------------------------------------------------------

pub const Value = union(enum) {
    null_val,
    boolean: bool,
    integer: i64,
    double: f64,
    string: []const u8,
    sobject: *SObject,
    list: *ListValue,
    map: *MapValue,
    set: *SetValue,
    object: *ObjectInstance,
    void_val,

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .null_val => false,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .double => |d| d != 0.0,
            .string => |s| s.len > 0,
            .void_val => false,
            else => true,
        };
    }
};

pub const SObject = struct {
    type_name: []const u8,
    fields: std.StringArrayHashMapUnmanaged(Value) = .empty,
    id: ?[]const u8 = null,
};

pub const ListValue = struct {
    items: std.ArrayListUnmanaged(Value) = .empty,
};

pub const MapValue = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
};

pub const SetValue = struct {
    entries: std.StringArrayHashMapUnmanaged(void) = .empty,
};

pub const ObjectInstance = struct {
    class_name: []const u8,
    fields: std.StringArrayHashMapUnmanaged(Value) = .empty,
};

// ---------------------------------------------------------------------------
// エラー
// ---------------------------------------------------------------------------

pub const ErrorKind = enum {
    null_pointer,
    type_mismatch,
    index_out_of_bounds,
    governor_limit,
    dml_error,
    unimplemented,
    user_exception,
    parse_error,
    name_error,
};

pub const RuntimeError = struct {
    message: []const u8,
    loc: SourceLoc,
    kind: ErrorKind,
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "Value.isNull" {
    const v: Value = .null_val;
    try std.testing.expect(v.isNull());
    const i: Value = .{ .integer = 42 };
    try std.testing.expect(!i.isNull());
}

test "Value.isTruthy" {
    const null_val: Value = .null_val;
    try std.testing.expect(!null_val.isTruthy());
    try std.testing.expect((Value{ .boolean = true }).isTruthy());
    try std.testing.expect(!(Value{ .boolean = false }).isTruthy());
    try std.testing.expect((Value{ .integer = 1 }).isTruthy());
    try std.testing.expect(!(Value{ .integer = 0 }).isTruthy());
    try std.testing.expect((Value{ .string = "hi" }).isTruthy());
    try std.testing.expect(!(Value{ .string = "" }).isTruthy());
}
