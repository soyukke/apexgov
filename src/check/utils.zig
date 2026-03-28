//! utils — 静的解析全体で使われる汎用ユーティリティ関数群。
//!
//! 識別子抽出、ブレース深さ追跡、飽和整数演算、型名正規化、
//! Apex 固有のリテラル・ソース判定など、複数サブモジュールから
//! 共通利用される低レベル操作を提供する。

const std = @import("std");

pub fn extractLastIdentifier(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;

    var i = raw.len;
    while (i > 0 and !isIdentChar(raw[i - 1])) : (i -= 1) {}
    const end = i;
    if (end == 0) return null;
    while (i > 0 and isIdentChar(raw[i - 1])) : (i -= 1) {}
    if (i == end) return null;
    return raw[i..end];
}

pub fn extractLeadingIdentifier(raw: []const u8) ?[]const u8 {
    if (raw.len == 0 or !isIdentChar(raw[0])) return null;
    var end: usize = 0;
    while (end < raw.len and isIdentChar(raw[end])) : (end += 1) {}
    if (end == 0) return null;
    return raw[0..end];
}

pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_';
}

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn containsExitStatement(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "return") != null or
        std.mem.indexOf(u8, line, "throw") != null;
}

pub fn parseLeadingUnsigned(raw: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or !std.ascii.isDigit(trimmed[0])) return null;

    var end: usize = 0;
    while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}
    return std.fmt.parseUnsigned(u64, trimmed[0..end], 10) catch null;
}

pub fn trimTrailingDelimiter(raw: []const u8) []const u8 {
    var out = std.mem.trim(u8, raw, " \t");
    while (out.len > 0 and (out[out.len - 1] == ';' or out[out.len - 1] == ')')) {
        out = std.mem.trimRight(u8, out[0 .. out.len - 1], " \t");
    }
    return out;
}

pub fn trimTrailingSemicolon(raw: []const u8) []const u8 {
    var out = std.mem.trim(u8, raw, " \t");
    while (out.len > 0 and out[out.len - 1] == ';') {
        out = std.mem.trimRight(u8, out[0 .. out.len - 1], " \t");
    }
    return out;
}

pub fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn updateBraceDepth(current: i32, line: []const u8) i32 {
    var depth = current;
    depth += @intCast(countByte(line, '{'));
    depth -= @intCast(countByte(line, '}'));
    if (depth < 0) return 0;
    return depth;
}

pub fn countByte(buf: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (buf) |b| {
        if (b == needle) count += 1;
    }
    return count;
}

pub fn satAdd(a: u64, b: u64) u64 {
    return std.math.add(u64, a, b) catch std.math.maxInt(u64);
}

pub fn satMul(a: u64, b: u64) u64 {
    return std.math.mul(u64, a, b) catch std.math.maxInt(u64);
}

pub fn satAddU16(a: u16, b: u16) u16 {
    return std.math.add(u16, a, b) catch std.math.maxInt(u16);
}

pub fn containsAnyCaseInsensitive(line: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfCaseInsensitive(line, needle) != null) return true;
    }
    return false;
}

pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

pub fn isControlKeyword(word: []const u8) bool {
    return std.mem.eql(u8, word, "if") or
        std.mem.eql(u8, word, "for") or
        std.mem.eql(u8, word, "while") or
        std.mem.eql(u8, word, "switch") or
        std.mem.eql(u8, word, "catch") or
        std.mem.eql(u8, word, "return") or
        std.mem.eql(u8, word, "new");
}

pub fn extractParameterTypePart(segment_raw: []const u8) []const u8 {
    var segment = std.mem.trim(u8, segment_raw, " \t");
    if (segment.len == 0) return "?";

    while (std.mem.startsWith(u8, segment, "final ")) {
        segment = std.mem.trimLeft(u8, segment[6..], " \t");
    }

    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var i = segment.len;
    while (i > 0) {
        i -= 1;
        const c = segment[i];
        switch (c) {
            '>' => {
                angle_depth += 1;
            },
            '<' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            ')' => {
                paren_depth += 1;
            },
            '(' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            ']' => {
                bracket_depth += 1;
            },
            '[' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '}' => {
                brace_depth += 1;
            },
            '{' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            else => {},
        }
        if ((c == ' ' or c == '\t') and angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            const left = std.mem.trimRight(u8, segment[0..i], " \t");
            if (left.len == 0) return "?";
            return left;
        }
    }
    return "?";
}

pub fn appendCanonicalType(arena_allocator: std.mem.Allocator, out: *std.ArrayList(u8), type_part: []const u8) !void {
    if (type_part.len == 0) {
        try out.append(arena_allocator, '?');
        return;
    }
    const before_len = out.items.len;
    for (type_part) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        try out.append(arena_allocator, c);
    }
    if (out.items.len == before_len) {
        try out.append(arena_allocator, '?');
    }
}

pub fn isApexSource(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".cls") or
        std.ascii.eqlIgnoreCase(ext, ".trigger") or
        std.ascii.eqlIgnoreCase(ext, ".apex");
}

pub fn findMatchingParen(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '(') return null;
    var depth: i32 = 0;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

pub fn equalsCanonicalType(raw_type: []const u8, canonical_type: []const u8) bool {
    var raw_i: usize = 0;
    var canon_i: usize = 0;
    while (raw_i < raw_type.len and canon_i < canonical_type.len) {
        while (raw_i < raw_type.len and std.ascii.isWhitespace(raw_type[raw_i])) : (raw_i += 1) {}
        if (raw_i >= raw_type.len) break;
        if (raw_type[raw_i] != canonical_type[canon_i]) return false;
        raw_i += 1;
        canon_i += 1;
    }
    while (raw_i < raw_type.len and std.ascii.isWhitespace(raw_type[raw_i])) : (raw_i += 1) {}
    return raw_i == raw_type.len and canon_i == canonical_type.len;
}

pub fn extractTypeFromNewExpression(expr_after_new_raw: []const u8) ?[]const u8 {
    const expr = std.mem.trimLeft(u8, expr_after_new_raw, " \t");
    if (expr.len == 0) return null;

    var angle_depth: i32 = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        switch (c) {
            '<' => {
                angle_depth += 1;
            },
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '(' => {
                if (angle_depth == 0) break;
            },
            '[' => {
                if (angle_depth == 0) break;
            },
            '{' => {
                if (angle_depth == 0) break;
            },
            else => {},
        }
    }
    if (i == 0) return null;
    return std.mem.trim(u8, expr[0..i], " \t");
}
