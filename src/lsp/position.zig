//! position — LSP 位置 ↔ バイトオフセット変換ユーティリティ。
//!
//! LSP は 0-indexed line + UTF-16 character を使う。
//! ソースコードは UTF-8 バイト列。

const std = @import("std");
const lsp_types = @import("types.zig");
const parser_types = @import("../apex_parser/types.zig");

/// トークンリストから指定オフセット位置の identifier 名を返す。
pub fn identifier_at_offset(tokens: []const parser_types.Token, offset: u32) ?[]const u8 {
    for (tokens, 0..) |tok, i| {
        if (tok.kind == .identifier and identifier_token_contains(tokens, i, offset)) {
            return tok.lexeme;
        }
    }
    return null;
}

pub const QualifiedMember = struct {
    receiver_name: []const u8,
    member_name: []const u8,
};

pub const ThisMember = struct {
    member_name: []const u8,
};

fn identifier_token_contains(
    tokens: []const parser_types.Token,
    index: usize,
    offset: u32,
) bool {
    const tok = tokens[index];
    const start = tok.loc.offset;
    const end = start + @as(u32, @intCast(tok.lexeme.len));
    if (offset >= start and offset < end) return true;
    if (offset != end) return false;

    if (index + 1 >= tokens.len) return true;
    const next = tokens[index + 1];
    if (next.loc.offset != end) return next.kind == .lparen;
    return next.kind != .identifier;
}

/// `Receiver.member` の member 識別子上に offset がある場合、その左右の識別子を返す。
pub fn qualified_member_at_offset(
    tokens: []const parser_types.Token,
    offset: u32,
) ?QualifiedMember {
    for (tokens, 0..) |tok, i| {
        if (tok.kind != .identifier) continue;
        if (!identifier_token_contains(tokens, i, offset)) continue;

        if (i < 2) return null;
        const dot = tokens[i - 1];
        if (dot.kind != .dot and dot.kind != .question_dot) return null;
        const receiver = tokens[i - 2];
        if (receiver.kind != .identifier) return null;
        return .{ .receiver_name = receiver.lexeme, .member_name = tok.lexeme };
    }
    return null;
}

/// `this.member` の member 識別子上に offset がある場合、member 名を返す。
pub fn this_member_at_offset(
    tokens: []const parser_types.Token,
    offset: u32,
) ?ThisMember {
    for (tokens, 0..) |tok, i| {
        if (tok.kind != .identifier) continue;
        if (!identifier_token_contains(tokens, i, offset)) continue;

        if (i < 2) return null;
        const dot = tokens[i - 1];
        if (dot.kind != .dot and dot.kind != .question_dot) return null;
        const receiver = tokens[i - 2];
        if (receiver.kind != .this_kw) return null;
        return .{ .member_name = tok.lexeme };
    }
    return null;
}

pub fn call_arg_count_at_offset(
    tokens: []const parser_types.Token,
    offset: u32,
) ?u32 {
    for (tokens, 0..) |tok, i| {
        if (tok.kind != .identifier) continue;
        if (!identifier_token_contains(tokens, i, offset)) continue;
        return call_arg_count_at_token_index(tokens, i);
    }
    return null;
}

pub fn call_arg_count_at_token_index(
    tokens: []const parser_types.Token,
    index: usize,
) ?u32 {
    if (index + 1 >= tokens.len or tokens[index + 1].kind != .lparen) return null;

    return count_call_args_after_open_paren(tokens, index + 1);
}

const ArgCountState = struct {
    paren_depth: u32 = 0,
    brace_depth: u32 = 0,
    bracket_depth: u32 = 0,
    angle_depth: u32 = 0,
    comma_count: u32 = 0,
    has_arg_token: bool = false,

    fn mark_arg(self: *ArgCountState) void {
        if (self.paren_depth > 0) self.has_arg_token = true;
    }

    fn top_level_call_arg(self: ArgCountState) bool {
        return self.paren_depth == 1 and self.brace_depth == 0 and
            self.bracket_depth == 0 and self.angle_depth == 0;
    }

    fn finish(self: ArgCountState) u32 {
        return if (self.has_arg_token) self.comma_count + 1 else 0;
    }
};

fn count_call_args_after_open_paren(
    tokens: []const parser_types.Token,
    open_index: usize,
) ?u32 {
    var state = ArgCountState{};
    for (tokens[open_index..], open_index..) |tok, tok_index| {
        switch (tok.kind) {
            .lparen => handle_lparen(&state),
            .rparen => if (handle_rparen(&state)) |count| return count,
            .lbrace => handle_lbrace(&state),
            .rbrace => handle_rbrace(&state),
            .lbracket => handle_lbracket(&state),
            .rbracket => handle_rbracket(&state),
            .lt => handle_lt(&state, tokens, tok_index),
            .gt => handle_gt(&state),
            .comma => handle_comma(&state),
            .eof => return null,
            else => state.mark_arg(),
        }
    }
    return null;
}

fn handle_lparen(state: *ArgCountState) void {
    if (state.angle_depth == 0) {
        state.paren_depth += 1;
        if (state.paren_depth > 1) state.has_arg_token = true;
    } else {
        state.has_arg_token = true;
    }
}

fn handle_rparen(state: *ArgCountState) ?u32 {
    if (state.paren_depth == 0) return null;
    if (state.angle_depth == 0 and state.brace_depth == 0 and state.bracket_depth == 0) {
        if (state.paren_depth == 1) return state.finish();
        state.paren_depth -= 1;
    }
    state.has_arg_token = true;
    return null;
}

fn handle_lbrace(state: *ArgCountState) void {
    if (state.paren_depth > 0 and state.angle_depth == 0) state.brace_depth += 1;
    state.has_arg_token = true;
}

fn handle_rbrace(state: *ArgCountState) void {
    if (state.brace_depth > 0) state.brace_depth -= 1;
    state.has_arg_token = true;
}

fn handle_lbracket(state: *ArgCountState) void {
    if (state.paren_depth > 0 and state.angle_depth == 0) state.bracket_depth += 1;
    state.has_arg_token = true;
}

fn handle_rbracket(state: *ArgCountState) void {
    if (state.bracket_depth > 0) state.bracket_depth -= 1;
    state.has_arg_token = true;
}

fn handle_lt(
    state: *ArgCountState,
    tokens: []const parser_types.Token,
    tok_index: usize,
) void {
    if (state.paren_depth > 0 and state.brace_depth == 0 and state.bracket_depth == 0 and
        looks_like_type_argument_start(tokens, tok_index))
    {
        state.angle_depth += 1;
    }
    state.has_arg_token = true;
}

fn handle_gt(state: *ArgCountState) void {
    if (state.angle_depth > 0) state.angle_depth -= 1;
    state.has_arg_token = true;
}

fn handle_comma(state: *ArgCountState) void {
    if (state.top_level_call_arg()) {
        state.comma_count += 1;
    } else if (state.paren_depth > 0) {
        state.has_arg_token = true;
    }
}

fn looks_like_type_argument_start(tokens: []const parser_types.Token, lt_index: usize) bool {
    if (lt_index == 0) return false;
    const prev = tokens[lt_index - 1];
    if (prev.kind != .identifier and prev.kind != .gt) return false;

    var depth: u32 = 0;
    for (tokens[lt_index + 1 ..]) |tok| {
        switch (tok.kind) {
            .lt => depth += 1,
            .gt => {
                if (depth == 0) return true;
                depth -= 1;
            },
            .comma,
            .dot,
            .identifier,
            .lbracket,
            .rbracket,
            => {},
            else => return false,
        }
    }
    return false;
}

/// SourceLoc → LSP Range（開始位置のみ、終了位置は同一点）。
/// symbols.zig, workspace_symbol.zig, server.zig 等の共通ヘルパー。
pub fn loc_to_range(loc: parser_types.SourceLoc, source: []const u8) lsp_types.Range {
    const line = if (loc.line > 0) loc.line - 1 else 0;
    const char = loc.utf16_col(source);
    return .{
        .start = .{ .line = line, .character = char },
        .end = .{ .line = line, .character = char },
    };
}

/// LSP Position (0-indexed line, UTF-16 character) → バイトオフセット。
pub fn position_to_offset(source: []const u8, line: u32, character: u32) ?u32 {
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
pub fn offset_to_position(source: []const u8, offset: u32) lsp_types.Position {
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

test "position_to_offset: first line, first char" {
    const source = "public class Foo {}";
    try std.testing.expectEqual(@as(?u32, 0), position_to_offset(source, 0, 0));
}

test "position_to_offset: second line" {
    const source = "line0\nline1\nline2";
    // line=1, char=0 → offset 6
    try std.testing.expectEqual(@as(?u32, 6), position_to_offset(source, 1, 0));
    // line=1, char=3 → offset 9
    try std.testing.expectEqual(@as(?u32, 9), position_to_offset(source, 1, 3));
}

test "position_to_offset: past end returns null" {
    const source = "abc";
    try std.testing.expectEqual(@as(?u32, null), position_to_offset(source, 5, 0));
}

test "offset_to_position: roundtrip" {
    const source = "public class Foo {\n    void run() {}\n}";
    const pos = offset_to_position(source, 23); // 'v' in void
    // line 1, after 4 spaces
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 4), pos.character);

    // roundtrip
    const offset = position_to_offset(source, pos.line, pos.character);
    try std.testing.expectEqual(@as(?u32, 23), offset);
}

// -- identifier_at_offset テスト --

const lexer = @import("../apex_parser/lexer.zig");

test "identifier_at_offset finds class name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, arena.allocator());
    // 'Foo' starts at offset 13
    try std.testing.expectEqualStrings("Foo", identifier_at_offset(tokens, 13).?);
    try std.testing.expectEqualStrings(
        "Foo",
        identifier_at_offset(tokens, 14).?,
    ); // middle of 'Foo'
}

test "identifier_at_offset returns null on keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, arena.allocator());
    // offset 0 = 'public' (keyword, not identifier)
    try std.testing.expect(identifier_at_offset(tokens, 0) == null);
}

test "identifier_at_offset returns null between tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, arena.allocator());
    // offset 6 = space
    try std.testing.expect(identifier_at_offset(tokens, 6) == null);
}

test "identifier_at_offset accepts token end before punctuation only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "Hoge.fuga(); Integer x = 1";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const fuga_end: u32 = @intCast(std.mem.indexOf(u8, source, "fuga").? + "fuga".len);
    const hoge_end: u32 = @intCast(std.mem.indexOf(u8, source, "Hoge").? + "Hoge".len);
    const x_end: u32 = @intCast(std.mem.indexOf(u8, source, "x =").? + "x".len);

    try std.testing.expectEqualStrings("fuga", identifier_at_offset(tokens, fuga_end).?);
    try std.testing.expectEqualStrings("Hoge", identifier_at_offset(tokens, hoge_end).?);
    try std.testing.expect(identifier_at_offset(tokens, x_end) == null);
}

test "qualified_member_at_offset finds member after dot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "SOQLRecipes.getRecords();";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "getRecords").?);
    const member = qualified_member_at_offset(tokens, offset);

    try std.testing.expect(member != null);
    try std.testing.expectEqualStrings("SOQLRecipes", member.?.receiver_name);
    try std.testing.expectEqualStrings("getRecords", member.?.member_name);
}

test "qualified_member_at_offset finds member at token end before call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "Hoge.fuga();";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "fuga").? + "fuga".len);
    const member = qualified_member_at_offset(tokens, offset);

    try std.testing.expect(member != null);
    try std.testing.expectEqualStrings("Hoge", member.?.receiver_name);
    try std.testing.expectEqualStrings("fuga", member.?.member_name);
    try std.testing.expectEqual(@as(?u32, 0), call_arg_count_at_offset(tokens, offset));
}

test "qualified_member_at_offset finds member at token end before spaced call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "UTIL_RecordTypes.getRecordTypeId (Opportunity.SObjectType, recordTypeName);";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const offset: u32 = @intCast(
        std.mem.indexOf(u8, source, "getRecordTypeId").? + "getRecordTypeId".len,
    );
    const member = qualified_member_at_offset(tokens, offset);

    try std.testing.expect(member != null);
    try std.testing.expectEqualStrings("UTIL_RecordTypes", member.?.receiver_name);
    try std.testing.expectEqualStrings("getRecordTypeId", member.?.member_name);
    try std.testing.expectEqual(@as(?u32, 2), call_arg_count_at_offset(tokens, offset));
}

test "qualified_member_at_offset ignores receiver identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "SOQLRecipes.getRecords();";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "SOQLRecipes").?);

    try std.testing.expect(qualified_member_at_offset(tokens, offset) == null);
}

test "this_member_at_offset finds member after this dot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "this.recordCount = 1;";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "recordCount").?);
    const member = this_member_at_offset(tokens, offset);

    try std.testing.expect(member != null);
    try std.testing.expectEqualStrings("recordCount", member.?.member_name);
}

test "call_arg_count_at_offset counts method arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "helper('a', nested(1, 2)); empty();";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const helper_offset: u32 = @intCast(std.mem.indexOf(u8, source, "helper").?);
    const empty_offset: u32 = @intCast(std.mem.indexOf(u8, source, "empty").?);

    try std.testing.expectEqual(@as(?u32, 2), call_arg_count_at_offset(tokens, helper_offset));
    try std.testing.expectEqual(@as(?u32, 0), call_arg_count_at_offset(tokens, empty_offset));
}

test "call_arg_count_at_offset ignores generic commas in map literal argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\RestRouteTestUtil.setupRestContext(
        \\    path,
        \\    uri,
        \\    new Map<String, String>{ 'expand' => '1' }
        \\);
    ;
    const tokens = try lexer.tokenize(source, arena.allocator());
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "setupRestContext").?);

    try std.testing.expectEqual(@as(?u32, 3), call_arg_count_at_offset(tokens, offset));
}

test "call_arg_count_at_offset ignores collection literal commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "helper(new List<String>{ 'a', 'b' }, second);";
    const tokens = try lexer.tokenize(source, arena.allocator());
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "helper").?);

    try std.testing.expectEqual(@as(?u32, 2), call_arg_count_at_offset(tokens, offset));
}
