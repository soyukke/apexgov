//! parser — apex_parser.parser への委譲。
//!
//! 後方互換のため残す。新規コードは apex_parser.parser を直接使うこと。

const apex_parser = @import("../apex_parser/parser.zig");

pub const parse = apex_parser.parse;
// apex_parser が snake_case 化されたので委譲名は parse_expr を参照する。
// interpret 内部では引き続き camelCase の `parseExpr` で呼ぶ。
pub const parseExpr = apex_parser.parse_expr;
