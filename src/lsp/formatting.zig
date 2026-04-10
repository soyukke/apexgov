//! formatting — トークン列ベースの簡易 Apex コードフォーマッター。
//!
//! インデント正規化を行い、全文置換の TextEdit を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const parser_types = @import("../apex_parser/types.zig");
const Token = parser_types.Token;
const TokenKind = parser_types.TokenKind;

pub const FormattingOptions = struct {
    tab_size: u32 = 4,
    insert_spaces: bool = true,
};

/// ソースコードをフォーマットし、結果のテキストを返す。
pub fn formatSource(tokens: []const Token, source: []const u8, opts: FormattingOptions, allocator: std.mem.Allocator) ![]const u8 {
    _ = tokens; // 将来的にトークン情報も活用

    var result: std.ArrayList(u8) = .empty;
    var indent_level: i32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;

    while (lines.next()) |raw_line| {
        if (!first) try result.append(allocator, '\n');
        first = false;

        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        // `}` で始まる行は先にインデント減
        if (trimmed.len > 0 and trimmed[0] == '}') {
            indent_level -= 1;
            if (indent_level < 0) indent_level = 0;
        }

        // 空行はそのまま出力
        if (trimmed.len == 0) continue;

        // インデント出力
        const spaces: usize = @intCast(indent_level * @as(i32, @intCast(opts.tab_size)));
        if (opts.insert_spaces) {
            for (0..spaces) |_| try result.append(allocator, ' ');
        } else {
            const tabs: usize = @intCast(indent_level);
            for (0..tabs) |_| try result.append(allocator, '\t');
        }

        try result.appendSlice(allocator, trimmed);

        // `{` で終わる行はインデント増
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '{') {
            indent_level += 1;
        }
    }

    // 末尾改行を追加
    if (result.items.len > 0) {
        try result.append(allocator, '\n');
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");

fn format(source: []const u8) ![]const u8 {
    const tokens = try lexer.tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    return formatSource(tokens, source, .{}, std.testing.allocator);
}

test "indents class body" {
    const source = "public class Foo {\nInteger x;\n}";
    const result = try format(source);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("public class Foo {\n    Integer x;\n}\n", result);
}

test "indents nested blocks" {
    const source = "public class Foo {\npublic void run() {\nreturn;\n}\n}";
    const result = try format(source);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("public class Foo {\n    public void run() {\n        return;\n    }\n}\n", result);
}

test "preserves string literal content" {
    const source = "public class Foo {\nString s = '  spaces  ';\n}";
    const result = try format(source);
    defer std.testing.allocator.free(result);

    // 文字列リテラルの中身はそのまま
    try std.testing.expect(std.mem.indexOf(u8, result, "'  spaces  '") != null);
}

test "empty document" {
    const result = try format("");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}
