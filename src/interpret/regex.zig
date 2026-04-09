//! regex — 軽量バックトラッキング正規表現エンジン。
//!
//! Java/Apex 互換の正規表現パターンをマッチング。
//! 外部依存なしの単一ファイルライブラリとして利用可能。
//!
//! サポートする構文:
//!   - リテラル文字
//!   - `.` (任意文字、\n 以外)
//!   - `\d` `\D` `\w` `\W` `\s` `\S` (文字クラスショートカット)
//!   - `[abc]` `[a-z]` `[^0-9]` (文字クラス、範囲、否定)
//!   - `*` `+` `?` `{n}` `{n,m}` (量詞、greedy)
//!   - `(...)` (キャプチャグループ)
//!   - `|` (alternation、グループ内)
//!   - `\\` (エスケープ)

const std = @import("std");

// ---------------------------------------------------------------------------
// 公開型
// ---------------------------------------------------------------------------

/// キャプチャグループまたはマッチ全体の位置情報。
pub const Span = struct {
    start: usize,
    end: usize,

    /// マッチした部分文字列を取得。
    pub fn slice(self: Span, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
};

/// 1つのマッチ結果。group(0) がマッチ全体、group(1)〜がキャプチャグループ。
pub const Match = struct {
    groups: [max_groups]?Span = .{null} ** max_groups,

    /// グループ n のスパンを取得。0 はマッチ全体。
    pub fn group(self: *const Match, n: usize) ?Span {
        if (n >= max_groups) return null;
        return self.groups[n];
    }

    /// グループ n の部分文字列を取得。
    pub fn groupSlice(self: *const Match, n: usize, input: []const u8) ?[]const u8 {
        if (self.group(n)) |span| return span.slice(input);
        return null;
    }

    /// キャプチャグループ数（group(0) を含む）。
    pub fn groupCount(self: *const Match) usize {
        var count: usize = 0;
        for (self.groups) |g| {
            if (g != null) count += 1 else break;
        }
        return count;
    }
};

pub const max_groups = 16;

// ---------------------------------------------------------------------------
// 公開 API
// ---------------------------------------------------------------------------

/// パターンをプリプロセス（Java double-escape の解決）し、入力文字列から
/// 全ての非重複マッチを見つけて返す。
///
/// `pattern` は Java/Apex 形式のエスケープ（`\\d` → `\d`）を含むことを想定。
/// 結果は `Match` のスライスとして返される（arena に確保）。
pub fn findAll(arena: std.mem.Allocator, pattern: []const u8, input: []const u8) ![]Match {
    const pat = try preprocessPattern(arena, pattern);
    var result: std.ArrayListUnmanaged(Match) = .empty;

    var search_start: usize = 0;
    while (search_start <= input.len) {
        var best_end: ?usize = null;
        var best_start: usize = search_start;
        var best_groups: [max_groups]?Span = .{null} ** max_groups;

        var pos = search_start;
        while (pos <= input.len) : (pos += 1) {
            var groups: [max_groups]?Span = .{null} ** max_groups;
            if (matchAt(pat, 0, input, pos, &groups, 0)) |end_pos| {
                best_end = end_pos;
                best_start = pos;
                best_groups = groups;
                break;
            }
        }

        if (best_end) |end_pos| {
            var m = Match{};
            const match_start = if (best_groups[0]) |g| g.start else best_start;
            m.groups[0] = .{ .start = match_start, .end = end_pos };
            for (1..max_groups) |i| {
                m.groups[i] = best_groups[i];
            }
            try result.append(arena, m);
            search_start = if (end_pos > match_start) end_pos else match_start + 1;
        } else break;
    }
    return result.items;
}

/// 入力文字列の先頭からパターン全体がマッチするか判定。
pub fn matches(arena: std.mem.Allocator, pattern: []const u8, input: []const u8) !bool {
    const pat = try preprocessPattern(arena, pattern);
    var groups: [max_groups]?Span = .{null} ** max_groups;
    if (matchAt(pat, 0, input, 0, &groups, 0)) |end| {
        return end == input.len;
    }
    return false;
}

/// 最初のマッチを1つだけ返す。見つからなければ null。
pub fn findFirst(arena: std.mem.Allocator, pattern: []const u8, input: []const u8) !?Match {
    const all = try findAll(arena, pattern, input);
    if (all.len > 0) return all[0];
    return null;
}

// ---------------------------------------------------------------------------
// パターンプリプロセッサ
// ---------------------------------------------------------------------------

/// Java/Apex の二重エスケープ（`\\d` → `\d`）を解決。
fn preprocessPattern(arena: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            const next = pattern[i + 1];
            if (next == '\\') {
                if (i + 2 < pattern.len and isRegexEscapeChar(pattern[i + 2])) {
                    i += 1;
                    try clean.append(arena, '\\');
                    try clean.append(arena, pattern[i + 1]);
                    i += 1;
                } else {
                    try clean.append(arena, '\\');
                    i += 1;
                }
            } else {
                try clean.append(arena, '\\');
                try clean.append(arena, next);
                i += 1;
            }
        } else {
            try clean.append(arena, pattern[i]);
        }
    }
    return clean.items;
}

fn isRegexEscapeChar(c: u8) bool {
    return switch (c) {
        's', 'd', 'w', 'S', 'D', 'W', '*', '.', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$' => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// マッチングエンジン（バックトラッキング）
// ---------------------------------------------------------------------------

/// 再帰バックトラッキングマッチャー。マッチ成功時に入力終了位置を返す。
fn matchAt(
    pat: []const u8,
    pat_pos: usize,
    input: []const u8,
    input_pos: usize,
    groups: *[max_groups]?Span,
    depth: u32,
) ?usize {
    if (depth > 200) return null;
    const pp = pat_pos;
    var ip = input_pos;

    while (pp < pat.len) {
        // キャプチャグループ
        if (pat[pp] == '(') {
            const group_end = findGroupEnd(pat, pp) orelse return null;
            const inner = pat[pp + 1 .. group_end];
            const after = pat[group_end + 1 ..];
            const quant = parseQuantifier(after);
            var grp_idx: u8 = 1;
            for (pat[0..pp]) |c| {
                if (c == '(') grp_idx += 1;
            }
            if (grp_idx > max_groups - 1) grp_idx = max_groups - 1;
            const alternatives = splitAlternatives(inner);
            const rest_start = group_end + 1 + quant.len;

            if (quant.min == 1 and quant.max == 1) {
                for (alternatives) |alt| {
                    if (alt) |a| {
                        if (matchAt(a, 0, input, ip, groups, depth + 1)) |alt_end| {
                            groups.*[grp_idx] = .{ .start = ip, .end = alt_end };
                            if (rest_start >= pat.len) return alt_end;
                            if (matchAt(pat, rest_start, input, alt_end, groups, depth + 1)) |final_end| {
                                return final_end;
                            }
                            groups.*[grp_idx] = null;
                        }
                    } else break;
                }
                return null;
            }
            return matchQuantifiedGroup(pat, pp, group_end, rest_start, quant, input, ip, groups, grp_idx, depth);
        }

        // 単一アトム＋量詞
        const atom_len = atomLength(pat, pp);
        if (atom_len == 0) return null;
        const after_atom = pat[pp + atom_len ..];
        const quant = parseQuantifier(after_atom);
        const rest_start = pp + atom_len + quant.len;

        // Greedy マッチ
        var count: usize = 0;
        var positions: [1001]usize = undefined;
        positions[0] = ip;
        while (count < quant.max and ip <= input.len) {
            if (!atomMatches(pat, pp, input, ip)) break;
            ip += 1;
            count += 1;
            if (count < positions.len) positions[count] = ip;
        }
        // バックトラック（max → min）
        var try_count = count;
        while (true) {
            if (try_count >= quant.min) {
                const try_ip = positions[@min(try_count, positions.len - 1)];
                if (rest_start >= pat.len) return try_ip;
                if (matchAt(pat, rest_start, input, try_ip, groups, depth + 1)) |end| return end;
            }
            if (try_count == 0) break;
            try_count -= 1;
        }
        return null;
    }
    return ip;
}

// ---------------------------------------------------------------------------
// アトムマッチング
// ---------------------------------------------------------------------------

fn atomMatches(pat: []const u8, pp: usize, input: []const u8, ip: usize) bool {
    if (ip >= input.len) return false;
    const c = input[ip];
    if (pat[pp] == '.') return c != '\n';
    if (pat[pp] == '\\' and pp + 1 < pat.len) {
        return switch (pat[pp + 1]) {
            'd' => std.ascii.isDigit(c),
            'D' => !std.ascii.isDigit(c),
            'w' => std.ascii.isAlphanumeric(c) or c == '_',
            'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
            's' => std.ascii.isWhitespace(c),
            'S' => !std.ascii.isWhitespace(c),
            else => c == pat[pp + 1],
        };
    }
    if (pat[pp] == '[') return charClassMatches(pat, pp, c);
    return c == pat[pp];
}

fn atomLength(pat: []const u8, pp: usize) usize {
    if (pp >= pat.len) return 0;
    if (pat[pp] == '\\' and pp + 1 < pat.len) return 2;
    if (pat[pp] == '[') {
        var i = pp + 1;
        if (i < pat.len and pat[i] == '^') i += 1;
        if (i < pat.len and pat[i] == ']') i += 1;
        while (i < pat.len and pat[i] != ']') : (i += 1) {}
        return if (i < pat.len) i + 1 - pp else 1;
    }
    return 1;
}

fn charClassMatches(pat: []const u8, pp: usize, c: u8) bool {
    var i = pp + 1;
    var negate = false;
    if (i < pat.len and pat[i] == '^') {
        negate = true;
        i += 1;
    }
    var matched = false;
    while (i < pat.len and pat[i] != ']') {
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            if (c >= pat[i] and c <= pat[i + 2]) matched = true;
            i += 3;
        } else if (pat[i] == '\\' and i + 1 < pat.len) {
            const m = switch (pat[i + 1]) {
                'd' => std.ascii.isDigit(c),
                'w' => std.ascii.isAlphanumeric(c) or c == '_',
                's' => std.ascii.isWhitespace(c),
                else => c == pat[i + 1],
            };
            if (m) matched = true;
            i += 2;
        } else {
            if (c == pat[i]) matched = true;
            i += 1;
        }
    }
    return if (negate) !matched else matched;
}

// ---------------------------------------------------------------------------
// 量詞パーサー
// ---------------------------------------------------------------------------

const Quantifier = struct { min: usize, max: usize, len: usize };

fn parseQuantifier(after: []const u8) Quantifier {
    if (after.len == 0) return .{ .min = 1, .max = 1, .len = 0 };
    if (after[0] == '*') return .{ .min = 0, .max = 1000, .len = 1 };
    if (after[0] == '+') return .{ .min = 1, .max = 1000, .len = 1 };
    if (after[0] == '?') return .{ .min = 0, .max = 1, .len = 1 };
    if (after[0] == '{') {
        var i: usize = 1;
        var n1: usize = 0;
        while (i < after.len and std.ascii.isDigit(after[i])) : (i += 1) {
            n1 = n1 * 10 + (after[i] - '0');
        }
        if (i < after.len and after[i] == '}') return .{ .min = n1, .max = n1, .len = i + 1 };
        if (i < after.len and after[i] == ',') {
            i += 1;
            var n2: usize = 1000;
            if (i < after.len and std.ascii.isDigit(after[i])) {
                n2 = 0;
                while (i < after.len and std.ascii.isDigit(after[i])) : (i += 1) {
                    n2 = n2 * 10 + (after[i] - '0');
                }
            }
            if (i < after.len and after[i] == '}') return .{ .min = n1, .max = n2, .len = i + 1 };
        }
    }
    return .{ .min = 1, .max = 1, .len = 0 };
}

// ---------------------------------------------------------------------------
// グループヘルパー
// ---------------------------------------------------------------------------

fn findGroupEnd(pat: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var i = start;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\') {
            i += 1;
            continue;
        }
        if (pat[i] == '(') depth += 1;
        if (pat[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn splitAlternatives(inner: []const u8) [8]?[]const u8 {
    var result: [8]?[]const u8 = .{null} ** 8;
    var count: usize = 0;
    var start: usize = 0;
    var depth: u32 = 0;
    for (inner, 0..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            if (depth > 0) depth -= 1;
        }
        if (c == '|' and depth == 0) {
            if (count < result.len) {
                result[count] = inner[start..i];
                count += 1;
            }
            start = i + 1;
        }
    }
    if (count < result.len) {
        result[count] = inner[start..];
    }
    return result;
}

fn matchQuantifiedGroup(
    pat: []const u8,
    group_start: usize,
    group_end: usize,
    rest_start: usize,
    quant: Quantifier,
    input: []const u8,
    start_ip: usize,
    groups: *[max_groups]?Span,
    grp_idx: u8,
    depth: u32,
) ?usize {
    const inner = pat[group_start + 1 .. group_end];
    var reps: [64]usize = undefined;
    var rep_count: usize = 0;
    var ip = start_ip;
    reps[0] = ip;
    while (rep_count < quant.max) {
        if (matchAt(inner, 0, input, ip, groups, depth + 1)) |end| {
            if (end == ip) break;
            ip = end;
            rep_count += 1;
            if (rep_count < reps.len) reps[rep_count] = ip;
        } else break;
    }
    var try_reps = rep_count;
    while (true) {
        if (try_reps >= quant.min) {
            const try_ip = reps[@min(try_reps, reps.len - 1)];
            if (try_reps > 0) groups.*[grp_idx] = .{ .start = reps[try_reps - 1], .end = try_ip };
            if (rest_start >= pat.len) return try_ip;
            if (matchAt(pat, rest_start, input, try_ip, groups, depth + 1)) |end| return end;
        }
        if (try_reps == 0) break;
        try_reps -= 1;
    }
    return null;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "digit pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findAll(arena.allocator(), "\\d+", "abc 123 def 456");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("123", result[0].groupSlice(0, "abc 123 def 456").?);
    try std.testing.expectEqualStrings("456", result[1].groupSlice(0, "abc 123 def 456").?);
}

test "capture groups" {
    const input = "user@host";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findAll(arena.allocator(), "(\\w+)@(\\w+)", input);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("user@host", result[0].groupSlice(0, input).?);
    try std.testing.expectEqualStrings("user", result[0].groupSlice(1, input).?);
    try std.testing.expectEqualStrings("host", result[0].groupSlice(2, input).?);
}

test "character class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findAll(arena.allocator(), "[a-z]+", "Hello World");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("ello", result[0].groupSlice(0, "Hello World").?);
    try std.testing.expectEqualStrings("orld", result[1].groupSlice(0, "Hello World").?);
}

test "quantifier {n}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findAll(arena.allocator(), "\\d{3}", "12 345 6789");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("345", result[0].groupSlice(0, "12 345 6789").?);
    try std.testing.expectEqualStrings("678", result[1].groupSlice(0, "12 345 6789").?);
}

test "alternation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findAll(arena.allocator(), "(cat|dog)", "I have a cat and a dog");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("cat", result[0].groupSlice(1, "I have a cat and a dog").?);
    try std.testing.expectEqualStrings("dog", result[1].groupSlice(1, "I have a cat and a dog").?);
}

test "matches full string" {
    var arena_m = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_m.deinit();
    const a = arena_m.allocator();
    try std.testing.expect(try matches(a, "\\d+", "12345"));
    try std.testing.expect(!try matches(a, "\\d+", "abc"));
    try std.testing.expect(!try matches(a, "\\d+", "12 34"));
}

test "javadoc @see pattern" {
    const input = " * @see RestClient\n * @see ApiModel\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findAll(arena.allocator(), "\\*\\s+@see\\s+(.*)", input);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("RestClient", result[0].groupSlice(1, input).?);
    try std.testing.expectEqualStrings("ApiModel", result[1].groupSlice(1, input).?);
}
