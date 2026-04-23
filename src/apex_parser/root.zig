//! apex_parser — Apex 言語パーサーライブラリ。
//!
//! Apex ソースコードをトークン化し、AST に変換する独立モジュール。
//! 外部依存なし（std のみ）。言語サーバー、リンター、フォーマッター等の基盤として利用可能。
//!
//! パイプライン: ソーステキスト → Lexer (トークン列) → Parser (AST)
//!
//! ## 使い方
//! ```zig
//! const apex_parser = @import("apex_parser");
//! const tokens = try apex_parser.lexer.tokenize(source, arena);
//! const decls = try apex_parser.parser.parse(tokens, arena);
//! ```

pub const types = @import("types.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

// 型の再エクスポート
pub const Token = types.Token;
pub const TokenKind = types.TokenKind;
pub const SourceLoc = types.SourceLoc;
pub const TypeRef = types.TypeRef;
pub const Span = types.Span;
pub const ParseDiagnostic = types.ParseDiagnostic;
pub const ParseSeverity = types.ParseSeverity;
pub const ParseResult = parser.ParseResult;
pub const Decl = ast.Decl;
pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;

/// ソースコードをトークン化する。
pub fn tokenize(source: []const u8, arena: @import("std").mem.Allocator) ![]Token {
    return lexer.tokenize(source, arena);
}

/// トークン列を AST に変換する。
pub fn parse(tokens: []const Token, arena: @import("std").mem.Allocator) ![]Decl {
    return parser.parse(tokens, arena);
}

/// 診断情報付きでパースする（LSP 向け）。
pub fn parse_with_diagnostics(
    tokens: []const Token,
    arena: @import("std").mem.Allocator,
) !ParseResult {
    return parser.parse_with_diagnostics(tokens, arena);
}

test {
    _ = types;
    _ = lexer;
    _ = ast;
    _ = parser;
}
