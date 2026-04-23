//! position — LSP 位置 ↔ バイトオフセット変換ユーティリティ。
//!
//! LSP は 0-indexed line + UTF-16 character を使う。
//! ソースコードは UTF-8 バイト列。

const std = @import("std");
const lsp_types = @import("types.zig");
const parser_types = @import("../apex_parser/types.zig");

/// トークンリストから指定オフセット位置の identifier 名を返す。
pub fn identifierAtOffset(tokens: []const parser_types.Token, offset: u32) ?[]const u8 {
    for (tokens) |tok| {
        if (tok.kind == .identifier and
            offset >= tok.loc.offset and
            offset < tok.loc.offset + @as(u32, @intCast(tok.lexeme.len)))
        {
            return tok.lexeme;
        }
    }
    return null;
}

/// SourceLoc → LSP Range（開始位置のみ、終了位置は同一点）。
/// symbols.zig, workspace_symbol.zig, server.zig 等の共通ヘルパー。
pub fn locToRange(loc: parser_types.SourceLoc, source: []const u8) lsp_types.Range {
    const line = if (loc.line > 0) loc.line - 1 else 0;
    const char = loc.utf16Col(source);
    return .{
        .start = .{ .line = line, .character = char },
        .end = .{ .line = line, .character = char },
    };
}

/// LSP Position (0-indexed line, UTF-16 character) → バイトオフセット。
pub fn positionToOffset(source: []const u8, line: u32, character: u32) ?u32 {
    var current_line: u32 = 0;
    var i: u32 = 0;

    // 目的の行まで進む
    while (current_line < line) {
        if (i >= source.len) return null;
        if (source[i] == '\n') current_line += 1;
        i += 1;
    }

    // 行内で UTF-16 character 分進む
    var utf16_count: u32 = 0;
    while (utf16_count < character and i < source.len and source[i] != '\n') {
        const byte = source[i];
        const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (i + cp_len > source.len) break;
        const cp = std.unicode.utf8Decode(source[i..][0..cp_len]) catch {
            utf16_count += 1;
            i += 1;
            continue;
        };
        if (cp >= 0x10000) {
            utf16_count += 2;
        } else {
            utf16_count += 1;
        }
        i += cp_len;
    }

    return i;
}

/// バイトオフセット → LSP Position (0-indexed line, UTF-16 character)。
pub fn offsetToPosition(source: []const u8, offset: u32) lsp_types.Position {
    var line: u32 = 0;
    var line_start: u32 = 0;

    var i: u32 = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }

    // line_start..offset 間の UTF-16 character 数を計算
    var utf16_count: u32 = 0;
    var j: u32 = line_start;
    while (j < offset and j < source.len) {
        const byte = source[j];
        const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (j + cp_len > source.len) break;
        const cp = std.unicode.utf8Decode(source[j..][0..cp_len]) catch {
            utf16_count += 1;
            j += 1;
            continue;
        };
        if (cp >= 0x10000) {
            utf16_count += 2;
        } else {
            utf16_count += 1;
        }
        j += cp_len;
    }

    return .{ .line = line, .character = utf16_count };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "positionToOffset: first line, first char" {
    const source = "public class Foo {}";
    try std.testing.expectEqual(@as(?u32, 0), positionToOffset(source, 0, 0));
}

test "positionToOffset: second line" {
    const source = "line0\nline1\nline2";
    // line=1, char=0 → offset 6
    try std.testing.expectEqual(@as(?u32, 6), positionToOffset(source, 1, 0));
    // line=1, char=3 → offset 9
    try std.testing.expectEqual(@as(?u32, 9), positionToOffset(source, 1, 3));
}

test "positionToOffset: past end returns null" {
    const source = "abc";
    try std.testing.expectEqual(@as(?u32, null), positionToOffset(source, 5, 0));
}

test "offsetToPosition: roundtrip" {
    const source = "public class Foo {\n    void run() {}\n}";
    const pos = offsetToPosition(source, 23); // 'v' in void
    // line 1, after 4 spaces
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 4), pos.character);

    // roundtrip
    const offset = positionToOffset(source, pos.line, pos.character);
    try std.testing.expectEqual(@as(?u32, 23), offset);
}

// -- identifierAtOffset テスト --

const lexer = @import("../apex_parser/lexer.zig");

test "identifierAtOffset finds class name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, arena.allocator());
    // 'Foo' starts at offset 13
    try std.testing.expectEqualStrings("Foo", identifierAtOffset(tokens, 13).?);
    try std.testing.expectEqualStrings("Foo", identifierAtOffset(tokens, 14).?); // middle of 'Foo'
}

test "identifierAtOffset returns null on keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, arena.allocator());
    // offset 0 = 'public' (keyword, not identifier)
    try std.testing.expect(identifierAtOffset(tokens, 0) == null);
}

test "identifierAtOffset returns null between tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, arena.allocator());
    // offset 6 = space
    try std.testing.expect(identifierAtOffset(tokens, 6) == null);
}
