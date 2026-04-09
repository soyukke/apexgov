//! parser — apex_parser.parser への委譲。
//!
//! 後方互換のため残す。新規コードは apex_parser.parser を直接使うこと。

const apex_parser = @import("../apex_parser/parser.zig");

pub const parse = apex_parser.parse;
pub const parseExpr = apex_parser.parseExpr;
