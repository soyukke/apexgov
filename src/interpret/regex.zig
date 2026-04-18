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

/// パターンにマッチする全ての部分文字列を replacement で置換。
/// replacement 内の `$1`..`$9` はキャプチャグループに展開される。
pub fn replaceAll(arena: std.mem.Allocator, pattern: []const u8, input: []const u8, replacement: []const u8) ![]const u8 {
    const all_matches = try findAll(arena, pattern, input);
    if (all_matches.len == 0) return input;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var last_end: usize = 0;

    for (all_matches) |m| {
        const span = m.group(0) orelse continue;
        // Append text before this match
        try result.appendSlice(arena, input[last_end..span.start]);
        // Expand replacement (handle $1..$9 backreferences)
        var ri: usize = 0;
        while (ri < replacement.len) : (ri += 1) {
            if (replacement[ri] == '$' and ri + 1 < replacement.len and replacement[ri + 1] >= '0' and replacement[ri + 1] <= '9') {
                const gidx: usize = replacement[ri + 1] - '0';
                ri += 1;
                if (m.groupSlice(gidx, input)) |gs| {
                    try result.appendSlice(arena, gs);
                }
            } else if (replacement[ri] == '\\' and ri + 1 < replacement.len) {
                // Escaped char in replacement (e.g., \\$ for literal $)
                ri += 1;
                try result.append(arena, replacement[ri]);
            } else {
                try result.append(arena, replacement[ri]);
            }
        }
        last_end = span.end;
    }
    // Append remaining text after last match
    try result.appendSlice(arena, input[last_end..]);
    return result.items;
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
        // ^ アンカー — 入力の先頭にのみマッチ
        if (pat[pp] == '^') {
            if (ip != 0) return null;
            return matchAt(pat, pp + 1, input, ip, groups, depth + 1);
        }
        // $ アンカー — 入力の末尾にのみマッチ
        if (pat[pp] == '$') {
            if (ip != input.len) return null;
            return matchAt(pat, pp + 1, input, ip, groups, depth + 1);
        }
        // グループ (キャプチャ、非キャプチャ、lookahead)
        if (pat[pp] == '(') {
            const group_end = findGroupEnd(pat, pp) orelse return null;
            const inner = pat[pp + 1 .. group_end];
            const after = pat[group_end + 1 ..];

            // Lookahead: (?=...) positive, (?!...) negative — zero-width assertion
            if (inner.len >= 2 and inner[0] == '?' and (inner[1] == '=' or inner[1] == '!')) {
                const is_positive = inner[1] == '=';
                const la_pat = inner[2..];
                const la_alts = splitAlternatives(la_pat);
                var la_matched = false;
                for (la_alts) |alt| {
                    if (alt) |a| {
                        if (matchAt(a, 0, input, ip, groups, depth + 1) != null) {
                            la_matched = true;
                            break;
                        }
                    } else break;
                }
                if (is_positive != la_matched) return null;
                // Zero-width: don't consume input, continue with rest
                const rest_start = group_end + 1;
                if (rest_start >= pat.len) return ip;
                return matchAt(pat, rest_start, input, ip, groups, depth + 1);
            }

            // Lookbehind: (?<=...) positive, (?<!...) negative — zero-width assertion
            // Bounded by the pattern's maximum possible match length (kept small for perf;
            // matches Java/JS behavior of restricting lookbehind to fixed/bounded width).
            if (inner.len >= 3 and inner[0] == '?' and inner[1] == '<' and (inner[2] == '=' or inner[2] == '!')) {
                const is_positive = inner[2] == '=';
                const lb_pat = inner[3..];
                const max_lb = lookbehindMaxLen(lb_pat);
                var lb_matched = false;
                var L: usize = 0;
                const limit = @min(ip, max_lb);
                while (L <= limit) : (L += 1) {
                    if (matchAt(lb_pat, 0, input[ip - L .. ip], 0, groups, depth + 1)) |end_pos| {
                        if (end_pos == L) {
                            lb_matched = true;
                            break;
                        }
                    }
                }
                if (is_positive != lb_matched) return null;
                const rest_start = group_end + 1;
                if (rest_start >= pat.len) return ip;
                return matchAt(pat, rest_start, input, ip, groups, depth + 1);
            }

            // Non-capturing group: (?:...)
            const is_non_capturing = inner.len >= 2 and inner[0] == '?' and inner[1] == ':';
            const group_inner = if (is_non_capturing) inner[2..] else inner;

            const quant = parseQuantifier(after);
            const grp_idx: u8 = if (is_non_capturing) 0 else blk: {
                var idx: u8 = 1;
                var gi: usize = 0;
                while (gi < pp) : (gi += 1) {
                    if (pat[gi] == '\\') {
                        gi += 1;
                        continue;
                    }
                    if (pat[gi] == '(') {
                        // Skip non-capturing groups (?...) and lookahead/lookbehind for index counting
                        if (gi + 2 < pat.len and pat[gi + 1] == '?' and (pat[gi + 2] == '=' or pat[gi + 2] == '!' or pat[gi + 2] == ':' or pat[gi + 2] == '<')) continue;
                        idx += 1;
                    }
                }
                break :blk if (idx > max_groups - 1) max_groups - 1 else idx;
            };
            const alternatives = splitAlternatives(group_inner);
            const rest_start = group_end + 1 + quant.len;

            if (quant.min == 1 and quant.max == 1) {
                for (alternatives) |alt| {
                    if (alt) |a| {
                        if (matchAt(a, 0, input, ip, groups, depth + 1)) |alt_end| {
                            if (grp_idx > 0) groups.*[grp_idx] = .{ .start = ip, .end = alt_end };
                            if (rest_start >= pat.len) return alt_end;
                            if (matchAt(pat, rest_start, input, alt_end, groups, depth + 1)) |final_end| {
                                return final_end;
                            }
                            if (grp_idx > 0) groups.*[grp_idx] = null;
                        }
                    } else break;
                }
                return null;
            }
            return matchQuantifiedGroup(pat, pp, group_end, rest_start, quant, input, ip, groups, grp_idx, depth);
        }

        // Backreference: \1..\9 — match the same text as captured by group N
        if (pat[pp] == '\\' and pp + 1 < pat.len and pat[pp + 1] >= '1' and pat[pp + 1] <= '9') {
            const ref_idx: u8 = pat[pp + 1] - '0';
            const ref_span = groups.*[ref_idx] orelse return null;
            const ref_text = input[ref_span.start..ref_span.end];
            if (ip + ref_text.len > input.len) return null;
            if (!std.mem.eql(u8, input[ip .. ip + ref_text.len], ref_text)) return null;
            const rest_start = pp + 2;
            const new_ip = ip + ref_text.len;
            if (rest_start >= pat.len) return new_ip;
            return matchAt(pat, rest_start, input, new_ip, groups, depth + 1);
        }

        // 単一アトム＋量詞
        const atom_len = atomLength(pat, pp);
        if (atom_len == 0) return null;
        const after_atom = pat[pp + atom_len ..];
        const quant = parseQuantifier(after_atom);
        const rest_start = pp + atom_len + quant.len;

        // Quantified atom match
        var count: usize = 0;
        var positions: [1001]usize = undefined;
        positions[0] = ip;
        while (count < quant.max and ip <= input.len) {
            if (!atomMatches(pat, pp, input, ip)) break;
            ip += 1;
            count += 1;
            if (count < positions.len) positions[count] = ip;
        }
        if (quant.greedy) {
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
        } else {
            var try_count = quant.min;
            while (try_count <= count) : (try_count += 1) {
                const try_ip = positions[@min(try_count, positions.len - 1)];
                if (rest_start >= pat.len) return try_ip;
                if (matchAt(pat, rest_start, input, try_ip, groups, depth + 1)) |end| return end;
            }
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

/// Estimate the maximum number of characters a (fixed/bounded) lookbehind body can match.
/// Counts atoms with quantifier upper bounds; unbounded `*`/`+` cap at HARD_CAP.
/// Returns at most HARD_CAP to keep search cost predictable.
fn lookbehindMaxLen(pat: []const u8) usize {
    const HARD_CAP: usize = 64;
    var total: usize = 0;
    var i: usize = 0;
    while (i < pat.len and total <= HARD_CAP) {
        if (pat[i] == '(') {
            const ge = findGroupEnd(pat, i) orelse return HARD_CAP;
            const inner_max = lookbehindMaxLen(pat[i + 1 .. ge]);
            const q = parseQuantifier(pat[ge + 1 ..]);
            const reps: usize = if (q.max >= 1000) HARD_CAP else q.max;
            total +|= inner_max *| reps;
            i = ge + 1 + q.len;
            continue;
        }
        if (pat[i] == '|' or pat[i] == '^' or pat[i] == '$') {
            i += 1;
            continue;
        }
        const al = atomLength(pat, i);
        if (al == 0) {
            i += 1;
            continue;
        }
        const q = parseQuantifier(pat[i + al ..]);
        const reps: usize = if (q.max >= 1000) HARD_CAP else q.max;
        total +|= reps;
        i += al + q.len;
    }
    return @min(total, HARD_CAP);
}

fn atomLength(pat: []const u8, pp: usize) usize {
    if (pp >= pat.len) return 0;
    if (pat[pp] == '\\' and pp + 1 < pat.len) {
        // Backreferences (\1..\9) are handled separately in matchAt, not as atoms
        if (pat[pp + 1] >= '1' and pat[pp + 1] <= '9') return 0;
        return 2;
    }
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

const Quantifier = struct {
    min: usize,
    max: usize,
    len: usize,
    greedy: bool = true,
};

fn parseQuantifier(after: []const u8) Quantifier {
    if (after.len == 0) return .{ .min = 1, .max = 1, .len = 0 };
    if (after[0] == '*') return .{
        .min = 0,
        .max = 1000,
        .len = if (after.len > 1 and after[1] == '?') 2 else 1,
        .greedy = !(after.len > 1 and after[1] == '?'),
    };
    if (after[0] == '+') return .{
        .min = 1,
        .max = 1000,
        .len = if (after.len > 1 and after[1] == '?') 2 else 1,
        .greedy = !(after.len > 1 and after[1] == '?'),
    };
    if (after[0] == '?') return .{
        .min = 0,
        .max = 1,
        .len = if (after.len > 1 and after[1] == '?') 2 else 1,
        .greedy = !(after.len > 1 and after[1] == '?'),
    };
    if (after[0] == '{') {
        var i: usize = 1;
        var n1: usize = 0;
        while (i < after.len and std.ascii.isDigit(after[i])) : (i += 1) {
            n1 = n1 * 10 + (after[i] - '0');
        }
        if (i < after.len and after[i] == '}') return .{
            .min = n1,
            .max = n1,
            .len = if (i + 1 < after.len and after[i + 1] == '?') i + 2 else i + 1,
            .greedy = !(i + 1 < after.len and after[i + 1] == '?'),
        };
        if (i < after.len and after[i] == ',') {
            i += 1;
            var n2: usize = 1000;
            if (i < after.len and std.ascii.isDigit(after[i])) {
                n2 = 0;
                while (i < after.len and std.ascii.isDigit(after[i])) : (i += 1) {
                    n2 = n2 * 10 + (after[i] - '0');
                }
            }
            if (i < after.len and after[i] == '}') return .{
                .min = n1,
                .max = n2,
                .len = if (i + 1 < after.len and after[i + 1] == '?') i + 2 else i + 1,
                .greedy = !(i + 1 < after.len and after[i + 1] == '?'),
            };
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
    if (quant.greedy) {
        var try_reps = rep_count;
        while (true) {
            if (try_reps >= quant.min) {
                const try_ip = reps[@min(try_reps, reps.len - 1)];
                if (grp_idx > 0) {
                    groups.*[grp_idx] = if (try_reps > 0)
                        .{ .start = reps[try_reps - 1], .end = try_ip }
                    else
                        null;
                }
                if (rest_start >= pat.len) return try_ip;
                if (matchAt(pat, rest_start, input, try_ip, groups, depth + 1)) |end| return end;
            }
            if (try_reps == 0) break;
            try_reps -= 1;
        }
    } else {
        var try_reps = quant.min;
        while (try_reps <= rep_count) : (try_reps += 1) {
            const try_ip = reps[@min(try_reps, reps.len - 1)];
            if (grp_idx > 0) {
                groups.*[grp_idx] = if (try_reps > 0)
                    .{ .start = reps[try_reps - 1], .end = try_ip }
                else
                    null;
            }
            if (rest_start >= pat.len) return try_ip;
            if (matchAt(pat, rest_start, input, try_ip, groups, depth + 1)) |end| return end;
        }
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

test "anchors ^ and $" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ^ and $ anchored pattern: match full string of parenthesized alphanumeric_
    const pat = "^\\([0-9A-Za-z_ ]+\\)$";
    const r1 = try findAll(a, pat, "(Some_Namespace)");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    const r2 = try findAll(a, pat, "(System Code)");
    try std.testing.expectEqual(@as(usize, 1), r2.len);
    const r3 = try findAll(a, pat, "Class.Foo.bar: line 1");
    try std.testing.expectEqual(@as(usize, 0), r3.len);
    const r4 = try findAll(a, pat, "()");
    try std.testing.expectEqual(@as(usize, 0), r4.len);
}

test "replaceAll with backreferences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Simple replacement without backreferences
    try std.testing.expectEqualStrings("hello planet", try replaceAll(a, "world", "hello world", "planet"));
    // Backreference $1
    try std.testing.expectEqualStrings("(abc) (def)", try replaceAll(a, "(\\w+)", "abc def", "($1)"));
    // SSN-like pattern: mask first two groups
    try std.testing.expectEqualStrings("XXX-XX-1234", try replaceAll(a, "(\\d{3})-(\\d{2})-(\\d{4})", "123-45-1234", "XXX-XX-$3"));
    // No match → return original
    try std.testing.expectEqualStrings("hello", try replaceAll(a, "\\d+", "hello", "NUM"));
}

test "replaceAll supports non-greedy quantifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("x<>b<>c", try replaceAll(a, "a.+?z", "xa123zba456zc", "<>"));
    try std.testing.expectEqualStrings(
        "\nClass.CallableLogger_Tests.test: line 10, column 1",
        try replaceAll(
            a,
            "(Class\\.Logger)\\..+?column 1",
            "Class.Logger.newEntry: line 2, column 1\nClass.CallableLogger_Tests.test: line 10, column 1",
            "",
        ),
    );
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

test "positive lookahead (?=...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Match digits followed by a non-digit (without consuming the non-digit)
    const r1 = try findAll(a, "\\d+(?=[^0-9]|$)", "123abc");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("123", r1[0].groupSlice(0, "123abc").?);
}

test "negative lookahead (?!...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Match digits NOT followed by more digits
    const r1 = try findAll(a, "\\d(?!\\d)", "1234a5b");
    try std.testing.expectEqual(@as(usize, 2), r1.len);
    try std.testing.expectEqualStrings("4", r1[0].groupSlice(0, "1234a5b").?);
    try std.testing.expectEqualStrings("5", r1[1].groupSlice(0, "1234a5b").?);
}

test "backreference \\1 in pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Match word repeated with same separator: "ab-cd-ef" where separators must be same
    const r1 = try findAll(a, "(\\d{4})([- ]?)\\d{4}\\2(\\d{4})", "1234-5678-9012");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("-", r1[0].groupSlice(2, "1234-5678-9012").?);
    // Mixed separators should NOT match
    const r2 = try findAll(a, "(\\d{4})([- ])\\d{4}\\2(\\d{4})", "1234-5678 9012");
    try std.testing.expectEqual(@as(usize, 0), r2.len);
}

test "SSN regex replaceAll" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ssn_pat = "(^|[^0-9A-Za-z])(\\d{3})[- ]?(\\d{2})[- ]?(\\d{4})(?=[^0-9A-Za-z]|$)";
    // Basic SSN: 123-45-6789 → XXX-XX-6789
    try std.testing.expectEqualStrings("XXX-XX-6789", try replaceAll(a, ssn_pat, "123-45-6789", "$1XXX-XX-$4"));
    // SSN in context
    try std.testing.expectEqualStrings("xyz XXX-XX-6789.", try replaceAll(a, ssn_pat, "xyz 123-45-6789.", "$1XXX-XX-$4"));
    // No dashes: 123456789 → XXX-XX-6789
    try std.testing.expectEqualStrings("XXX-XX-6789", try replaceAll(a, ssn_pat, "123456789", "$1XXX-XX-$4"));
    // False positive: alphanumeric before → should NOT match
    try std.testing.expectEqualStrings("abc123456789", try replaceAll(a, ssn_pat, "abc123456789", "$1XXX-XX-$4"));
}

test "negative lookbehind (?<!...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Match digits NOT preceded by another digit (similar to (?<!\d)\d+)
    const r1 = try findAll(a, "(?<!\\d)\\d+", "abc123def");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("123", r1[0].groupSlice(0, "abc123def").?);
}

test "positive lookbehind (?<=...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Match a word preceded by "Mr "
    const r1 = try findAll(a, "(?<=Mr )\\w+", "Hello Mr Smith");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("Smith", r1[0].groupSlice(0, "Hello Mr Smith").?);
}

test "NebulaLogger SSN pattern (?<!\\d)...(?!\\d)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ssn_pat = "(?<!\\d)(\\d{3})[- ]?(\\d{2})[- ]?(\\d{4})(?!\\d)";
    // Matches space-separated SSN
    try std.testing.expectEqualStrings(
        "Something my social is XXX-XX-9999 in case",
        try replaceAll(a, ssn_pat, "Something my social is 400 11 9999 in case", "XXX-XX-$3"),
    );
    // Not preceded by digit, not followed by digit → NO match (false positive avoided)
    try std.testing.expectEqualStrings(
        "abc1234567890def",
        try replaceAll(a, ssn_pat, "abc1234567890def", "XXX-XX-$3"),
    );
}
