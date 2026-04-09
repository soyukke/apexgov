//! ast — apex_parser.ast への委譲。
//!
//! 後方互換のため残す。新規コードは apex_parser.ast を直接使うこと。

pub const apex_ast = @import("../apex_parser/ast.zig");

// 式
pub const Expr = apex_ast.Expr;
pub const Identifier = apex_ast.Identifier;
pub const BinaryOp = apex_ast.BinaryOp;
pub const UnaryOp = apex_ast.UnaryOp;
pub const BinaryExpr = apex_ast.BinaryExpr;
pub const UnaryExpr = apex_ast.UnaryExpr;
pub const CallExpr = apex_ast.CallExpr;
pub const MethodCallExpr = apex_ast.MethodCallExpr;
pub const FieldAccess = apex_ast.FieldAccess;
pub const IndexAccess = apex_ast.IndexAccess;
pub const Assignment = apex_ast.Assignment;
pub const AssignOp = apex_ast.AssignOp;
pub const NewExpr = apex_ast.NewExpr;
pub const CastExpr = apex_ast.CastExpr;
pub const TernaryExpr = apex_ast.TernaryExpr;
pub const InstanceofExpr = apex_ast.InstanceofExpr;
pub const SoqlExpr = apex_ast.SoqlExpr;

// 文
pub const Stmt = apex_ast.Stmt;
pub const RunAsStmt = apex_ast.RunAsStmt;
pub const VarDecl = apex_ast.VarDecl;
pub const IfStmt = apex_ast.IfStmt;
pub const ForStmt = apex_ast.ForStmt;
pub const ForEachStmt = apex_ast.ForEachStmt;
pub const WhileStmt = apex_ast.WhileStmt;
pub const DoWhileStmt = apex_ast.DoWhileStmt;
pub const ReturnStmt = apex_ast.ReturnStmt;
pub const SwitchStmt = apex_ast.SwitchStmt;
pub const WhenClause = apex_ast.WhenClause;
pub const WhenPattern = apex_ast.WhenPattern;
pub const TryStmt = apex_ast.TryStmt;
pub const CatchClause = apex_ast.CatchClause;
pub const ThrowStmt = apex_ast.ThrowStmt;
pub const DmlOp = apex_ast.DmlOp;
pub const DmlStmt = apex_ast.DmlStmt;

// 宣言
pub const Decl = apex_ast.Decl;
pub const Modifiers = apex_ast.Modifiers;
pub const SharingMode = apex_ast.SharingMode;
pub const ClassDecl = apex_ast.ClassDecl;
pub const InterfaceDecl = apex_ast.InterfaceDecl;
pub const EnumDecl = apex_ast.EnumDecl;
pub const Param = apex_ast.Param;
pub const MethodDecl = apex_ast.MethodDecl;
pub const ConstructorDecl = apex_ast.ConstructorDecl;
pub const FieldDecl = apex_ast.FieldDecl;
pub const TriggerEvent = apex_ast.TriggerEvent;
pub const TriggerDecl = apex_ast.TriggerDecl;
