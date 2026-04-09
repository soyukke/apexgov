//! ast — Apex AST ノード定義。
//!
//! パーサーが生成し、下流のツール（エバリュエーター、リンター、LSP 等）が消費する。
//! 全ノードは arena アロケーション。SourceLoc でソース位置を追跡。

const types = @import("types.zig");
const SourceLoc = types.SourceLoc;
const TypeRef = types.TypeRef;
const TokenKind = types.TokenKind;

// ---------------------------------------------------------------------------
// 式 (Expression)
// ---------------------------------------------------------------------------

pub const Expr = union(enum) {
    integer_literal: i64,
    double_literal: f64,
    string_literal: []const u8,
    boolean_literal: bool,
    null_literal,
    identifier: Identifier,
    this_expr,
    super_expr,
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    call: *CallExpr,
    method_call: *MethodCallExpr,
    field_access: *FieldAccess,
    index_access: *IndexAccess,
    assignment: *Assignment,
    new_expr: *NewExpr,
    cast_expr: *CastExpr,
    ternary: *TernaryExpr,
    instanceof: *InstanceofExpr,
    soql: *SoqlExpr,
    grouped: *Expr,
};

pub const Identifier = struct {
    name: []const u8,
    loc: SourceLoc = .zero,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
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
};

pub const UnaryOp = enum {
    negate,
    not,
};

pub const BinaryExpr = struct {
    left: *Expr,
    op: BinaryOp,
    right: *Expr,
    loc: SourceLoc = .zero,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    loc: SourceLoc = .zero,
};

pub const CallExpr = struct {
    callee: []const u8,
    args: []Expr,
    loc: SourceLoc = .zero,
};

pub const MethodCallExpr = struct {
    object: *Expr,
    method: []const u8,
    args: []Expr,
    loc: SourceLoc = .zero,
    null_safe: bool = false,
};

pub const FieldAccess = struct {
    object: *Expr,
    field: []const u8,
    loc: SourceLoc = .zero,
    null_safe: bool = false,
};

pub const IndexAccess = struct {
    object: *Expr,
    index: *Expr,
    loc: SourceLoc = .zero,
};

pub const Assignment = struct {
    target: *Expr,
    op: AssignOp,
    value: *Expr,
    loc: SourceLoc = .zero,
};

pub const AssignOp = enum {
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
};

pub const NewExpr = struct {
    type_name: TypeRef,
    args: []Expr,
    loc: SourceLoc = .zero,
};

pub const CastExpr = struct {
    target_type: TypeRef,
    operand: *Expr,
    loc: SourceLoc = .zero,
};

pub const TernaryExpr = struct {
    condition: *Expr,
    then_expr: *Expr,
    else_expr: *Expr,
    loc: SourceLoc = .zero,
};

pub const InstanceofExpr = struct {
    operand: *Expr,
    type_name: TypeRef,
    loc: SourceLoc = .zero,
};

pub const SoqlExpr = struct {
    raw: []const u8,
    loc: SourceLoc = .zero,
};

// ---------------------------------------------------------------------------
// 文 (Statement)
// ---------------------------------------------------------------------------

pub const Stmt = union(enum) {
    expr_stmt: *Expr,
    var_decl: *VarDecl,
    block: []Stmt,
    if_stmt: *IfStmt,
    for_stmt: *ForStmt,
    for_each_stmt: *ForEachStmt,
    while_stmt: *WhileStmt,
    do_while: *DoWhileStmt,
    return_stmt: *ReturnStmt,
    break_stmt,
    continue_stmt,
    switch_stmt: *SwitchStmt,
    try_stmt: *TryStmt,
    throw_stmt: *ThrowStmt,
    dml_stmt: *DmlStmt,
    run_as_stmt: *RunAsStmt,
};

pub const RunAsStmt = struct {
    user_expr: *Expr,
    body: []Stmt,
    loc: SourceLoc = .zero,
};

pub const VarDecl = struct {
    type_ref: TypeRef,
    name: []const u8,
    initializer: ?*Expr = null,
    loc: SourceLoc = .zero,
};

pub const IfStmt = struct {
    condition: *Expr,
    then_body: []Stmt,
    else_body: ?[]Stmt = null,
    loc: SourceLoc = .zero,
};

pub const ForStmt = struct {
    init: ?*Stmt,
    condition: ?*Expr,
    update: ?*Expr,
    body: []Stmt,
    loc: SourceLoc = .zero,
};

pub const ForEachStmt = struct {
    elem_type: TypeRef,
    elem_name: []const u8,
    iterable: *Expr,
    body: []Stmt,
    loc: SourceLoc = .zero,
};

pub const WhileStmt = struct {
    condition: *Expr,
    body: []Stmt,
    loc: SourceLoc = .zero,
};

pub const DoWhileStmt = struct {
    body: []Stmt,
    condition: *Expr,
    loc: SourceLoc = .zero,
};

pub const ReturnStmt = struct {
    value: ?*Expr = null,
    loc: SourceLoc = .zero,
};

pub const SwitchStmt = struct {
    subject: *Expr,
    when_clauses: []WhenClause,
    loc: SourceLoc = .zero,
};

pub const WhenClause = struct {
    pattern: WhenPattern,
    body: []Stmt,
};

pub const WhenPattern = union(enum) {
    values: []Expr,
    else_clause,
};

pub const TryStmt = struct {
    body: []Stmt,
    catches: []CatchClause,
    finally_body: ?[]Stmt = null,
    loc: SourceLoc = .zero,
};

pub const CatchClause = struct {
    exception_type: TypeRef,
    name: []const u8,
    body: []Stmt,
};

pub const ThrowStmt = struct {
    expr: *Expr,
    loc: SourceLoc = .zero,
};

pub const DmlOp = enum {
    insert,
    update,
    upsert,
    delete,
    undelete,
    merge,
};

pub const DmlStmt = struct {
    op: DmlOp,
    target: *Expr,
    is_user_mode: bool = false,
    loc: SourceLoc = .zero,
};

// ---------------------------------------------------------------------------
// 宣言 (Declaration)
// ---------------------------------------------------------------------------

pub const Decl = union(enum) {
    class_decl: *ClassDecl,
    interface_decl: *InterfaceDecl,
    enum_decl: *EnumDecl,
    method_decl: *MethodDecl,
    field_decl: *FieldDecl,
    constructor_decl: *ConstructorDecl,
    static_init: []Stmt,
    trigger_decl: *TriggerDecl,
};

pub const Modifiers = struct {
    is_public: bool = false,
    is_private: bool = false,
    is_protected: bool = false,
    is_global: bool = false,
    is_static: bool = false,
    is_final: bool = false,
    is_abstract: bool = false,
    is_virtual: bool = false,
    is_override: bool = false,
    is_transient: bool = false,
};

pub const SharingMode = enum {
    with_sharing,
    without_sharing,
    inherited,
};

pub const ClassDecl = struct {
    name: []const u8,
    modifiers: Modifiers = .{},
    sharing: SharingMode = .inherited,
    super_class: ?TypeRef = null,
    interfaces: []TypeRef = &.{},
    members: []Decl = &.{},
    annotations: [][]const u8 = &.{},
    loc: SourceLoc = .zero,
};

pub const InterfaceDecl = struct {
    name: []const u8,
    modifiers: Modifiers = .{},
    extends: []TypeRef = &.{},
    members: []Decl = &.{},
    loc: SourceLoc = .zero,
};

pub const EnumDecl = struct {
    name: []const u8,
    modifiers: Modifiers = .{},
    values: [][]const u8 = &.{},
    loc: SourceLoc = .zero,
};

pub const Param = struct {
    type_ref: TypeRef,
    name: []const u8,
};

pub const MethodDecl = struct {
    name: []const u8,
    modifiers: Modifiers = .{},
    return_type: TypeRef,
    params: []Param = &.{},
    body: []Stmt = &.{},
    annotations: [][]const u8 = &.{},
    loc: SourceLoc = .zero,
};

pub const ConstructorDecl = struct {
    modifiers: Modifiers = .{},
    params: []Param = &.{},
    body: []Stmt = &.{},
    loc: SourceLoc = .zero,
};

pub const FieldDecl = struct {
    name: []const u8,
    modifiers: Modifiers = .{},
    type_ref: TypeRef,
    initializer: ?*Expr = null,
    getter_body: ?[]Stmt = null,
    setter_body: ?[]Stmt = null,
    loc: SourceLoc = .zero,
};

pub const TriggerEvent = enum {
    before_insert,
    before_update,
    before_delete,
    after_insert,
    after_update,
    after_delete,
    after_undelete,
};

pub const TriggerDecl = struct {
    name: []const u8,
    object_name: []const u8,
    events: []TriggerEvent,
    body: []Stmt,
    loc: SourceLoc = .zero,
};
