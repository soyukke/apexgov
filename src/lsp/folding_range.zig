//! folding_range — トークン列から LSP FoldingRange を生成する。

const std = @import("std");
const lsp_types = @import("types.zig");
const parser_types = @import("../apex_parser/types.zig");
const Token = parser_types.Token;
const TokenKind = parser_types.TokenKind;

pub fn getFoldingRanges(tokens: []const Token, allocator: std.mem.Allocator) ![]lsp_types.FoldingRange {
    var ranges: std.ArrayList(lsp_types.FoldingRange) = .empty;
    var stack: std.ArrayList(u32) = .empty; // start line (0-indexed) のスタック
    defer stack.deinit(allocator);

    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        if (tok.kind == .lbrace) {
            const line = if (tok.loc.line > 0) tok.loc.line - 1 else 0;
            try stack.append(allocator, line);
        } else if (tok.kind == .rbrace) {
            if (stack.items.len > 0) {
                const start_line = stack.pop() orelse continue;
                const end_line: u32 = if (tok.loc.line > 0) tok.loc.line - 1 else 0;
                if (end_line > start_line) {
                    try ranges.append(allocator, .{
                        .startLine = start_line,
                        .endLine = end_line,
                    });
                }
            }
        }
    }

    return ranges.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");

fn tokenizeAndFold(source: []const u8) ![]lsp_types.FoldingRange {
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    return getFoldingRanges(tokens, std.testing.allocator);
}

test "class body is foldable" {
    const source = "public class Foo {\n    Integer x;\n}";
    const ranges = try tokenizeAndFold(source);
    defer std.testing.allocator.free(ranges);

    try std.testing.expectEqual(@as(usize, 1), ranges.len);
    try std.testing.expectEqual(@as(u32, 0), ranges[0].startLine);
    try std.testing.expectEqual(@as(u32, 2), ranges[0].endLine);
}

test "method body is foldable" {
    const source = "public class Foo {\n    public void run() {\n        return;\n    }\n}";
    const ranges = try tokenizeAndFold(source);
    defer std.testing.allocator.free(ranges);

    // 2 ranges: method body + class body
    try std.testing.expectEqual(@as(usize, 2), ranges.len);
}

test "single-line block not foldable" {
    const source = "public class Foo { Integer x; }";
    const ranges = try tokenizeAndFold(source);
    defer std.testing.allocator.free(ranges);

    try std.testing.expectEqual(@as(usize, 0), ranges.len);
}

test "nested blocks create nested ranges" {
    const source = "public class Foo {\n    public void run() {\n        if (true) {\n            return;\n        }\n    }\n}";
    const ranges = try tokenizeAndFold(source);
    defer std.testing.allocator.free(ranges);

    // 3 ranges: if block + method + class
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
}
