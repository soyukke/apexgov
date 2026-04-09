//! lexer — apex_parser.lexer への委譲。
//!
//! 後方互換のため残す。新規コードは apex_parser.lexer を直接使うこと。

const apex_lexer = @import("../apex_parser/lexer.zig");

pub const tokenize = apex_lexer.tokenize;
