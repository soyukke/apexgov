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
    pub fn group_slice(self: *const Match, n: usize, input: []const u8) ?[]const u8 {
        if (self.group(n)) |span| return span.slice(input);
        return null;
    }

    /// キャプチャグループ数（group(0) を含む）。
    pub fn group_count(self: *const Match) usize {
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
pub fn find_all(arena: std.mem.Allocator, pattern: []const u8, input: []const u8) ![]Match {
    const pat = try preprocess_pattern(arena, pattern);
    var result: std.ArrayListUnmanaged(Match) = .empty;

    var search_start: usize = 0;
    while (search_start <= input.len) {
        var best_end: ?usize = null;
        var best_start: usize = search_start;
        var best_groups: [max_groups]?Span = .{null} ** max_groups;

        var pos = search_start;
        while (pos <= input.len) : (pos += 1) {
            var groups: [max_groups]?Span = .{null} ** max_groups;
            if (match_at(pat, 0, input, pos, &groups, 0, 0)) |end_pos| {
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
    const pat = try preprocess_pattern(arena, pattern);
    var groups: [max_groups]?Span = .{null} ** max_groups;
    if (match_at(pat, 0, input, 0, &groups, 0, 0)) |end| {
        return end == input.len;
    }
    return false;
}

/// パターンにマッチする全ての部分文字列を replacement で置換。
/// replacement 内の `$1`..`$9` はキャプチャグループに展開される。
pub fn replace_all(
    arena: std.mem.Allocator,
    pattern: []const u8,
    input: []const u8,
    replacement: []const u8,
) ![]const u8 {
    const all_matches = try find_all(arena, pattern, input);
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
            if (replacement[ri] == '$' and
                ri + 1 < replacement.len and
                replacement[ri + 1] >= '0' and
                replacement[ri + 1] <= '9')
            {
                const gidx: usize = replacement[ri + 1] - '0';
                ri += 1;
                if (m.group_slice(gidx, input)) |gs| {
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
fn preprocess_pattern(arena: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            const next = pattern[i + 1];
            if (next == '\\') {
                if (i + 2 < pattern.len and is_regex_escape_char(pattern[i + 2])) {
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

fn is_regex_escape_char(c: u8) bool {
    return switch (c) {
        's',
        'd',
        'w',
        'S',
        'D',
        'W',
        '*',
        '.',
        '+',
        '?',
        '(',
        ')',
        '[',
        ']',
        '{',
        '}',
        '|',
        '^',
        '$',
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// マッチングエンジン（バックトラッキング）
// ---------------------------------------------------------------------------

/// 再帰バックトラッキングマッチャー。マッチ成功時に入力終了位置を返す。
///
/// `group_base` is the capture-group index of the enclosing group, i.e. the offset that
/// applies to any `(` encountered while scanning `pat`. The top-level caller passes 0.
/// Without this offset, recursing on a sub-pattern would restart counting at 1 and
/// cause sibling/nested groups to collide on the same index.
fn match_at(
    pat: []const u8,
    pat_pos: usize,
    input: []const u8,
    input_pos: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    if (depth > 200) return null;
    const pp = pat_pos;
    if (pp >= pat.len) return input_pos;
    if (pat[pp] == '^' or pat[pp] == '$') {
        return match_anchor_at(pat, pp, input, input_pos, groups, depth, group_base);
    }
    if (pat[pp] == '(') {
        return match_group_at(pat, pp, input, input_pos, groups, depth, group_base);
    }
    if (is_backreference_token(pat, pp)) {
        return match_backreference_at(pat, pp, input, input_pos, groups, depth, group_base);
    }
    return match_quantified_atom_at(pat, pp, input, input_pos, groups, depth, group_base);
}

fn match_anchor_at(
    pat: []const u8,
    pp: usize,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    if (pat[pp] == '^') {
        if (ip != 0) return null;
        return match_at(pat, pp + 1, input, ip, groups, depth + 1, group_base);
    }
    if (ip != input.len) return null;
    return match_at(pat, pp + 1, input, ip, groups, depth + 1, group_base);
}

fn match_group_at(
    pat: []const u8,
    pp: usize,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    const group_end = find_group_end(pat, pp) orelse return null;
    const inner = pat[pp + 1 .. group_end];
    if (inner.len >= 2 and inner[0] == '?' and (inner[1] == '=' or inner[1] == '!')) {
        return match_lookahead_group(
            pat,
            group_end,
            inner[2..],
            input,
            ip,
            groups,
            depth,
            group_base,
            inner[1] == '=',
        );
    }
    if (inner.len >= 3 and
        inner[0] == '?' and
        inner[1] == '<' and
        (inner[2] == '=' or inner[2] == '!'))
    {
        return match_lookbehind_group(
            pat,
            group_end,
            inner[3..],
            input,
            ip,
            groups,
            depth,
            group_base,
            inner[2] == '=',
        );
    }
    return match_regular_group(pat, pp, group_end, inner, input, ip, groups, depth, group_base);
}

fn match_lookahead_group(
    pat: []const u8,
    group_end: usize,
    lookahead_pat: []const u8,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
    is_positive: bool,
) ?usize {
    const alternatives = split_alternatives(lookahead_pat);
    var matched = false;
    for (alternatives) |alt| {
        if (alt) |a| {
            if (match_at(a, 0, input, ip, groups, depth + 1, group_base) != null) {
                matched = true;
                break;
            }
        } else break;
    }
    if (is_positive != matched) return null;
    const rest_start = group_end + 1;
    if (rest_start >= pat.len) return ip;
    return match_at(pat, rest_start, input, ip, groups, depth + 1, group_base);
}

fn match_lookbehind_group(
    pat: []const u8,
    group_end: usize,
    lookbehind_pat: []const u8,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
    is_positive: bool,
) ?usize {
    const max_lb = lookbehind_max_len(lookbehind_pat);
    var matched = false;
    var lookbehind_len: usize = 0;
    const limit = @min(ip, max_lb);
    while (lookbehind_len <= limit) : (lookbehind_len += 1) {
        if (match_at(
            lookbehind_pat,
            0,
            input[ip - lookbehind_len .. ip],
            0,
            groups,
            depth + 1,
            group_base,
        )) |end_pos| {
            if (end_pos == lookbehind_len) {
                matched = true;
                break;
            }
        }
    }
    if (is_positive != matched) return null;
    const rest_start = group_end + 1;
    if (rest_start >= pat.len) return ip;
    return match_at(pat, rest_start, input, ip, groups, depth + 1, group_base);
}

fn match_regular_group(
    pat: []const u8,
    pp: usize,
    group_end: usize,
    inner: []const u8,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    const after = pat[group_end + 1 ..];
    const is_non_capturing = inner.len >= 2 and inner[0] == '?' and inner[1] == ':';
    const group_inner = if (is_non_capturing) inner[2..] else inner;
    const quant = parse_quantifier(after);
    const grp_idx: u8 = if (is_non_capturing) 0 else group_capture_index(pat, pp, group_base);
    const inner_base: u8 = if (is_non_capturing) group_base else grp_idx;
    const alternatives = split_alternatives(group_inner);
    const rest_start = group_end + 1 + quant.len;

    if (quant.min == 1 and quant.max == 1) {
        return match_single_group_alternative(
            pat,
            rest_start,
            alternatives,
            input,
            ip,
            groups,
            grp_idx,
            depth,
            group_base,
            inner_base,
        );
    }
    return match_quantified_group(
        pat,
        pp,
        group_end,
        rest_start,
        quant,
        input,
        ip,
        groups,
        grp_idx,
        depth,
        group_base,
        inner_base,
    );
}

fn group_capture_index(pat: []const u8, pp: usize, group_base: u8) u8 {
    var idx: u8 = group_base + 1;
    var gi: usize = 0;
    while (gi < pp) : (gi += 1) {
        if (pat[gi] == '\\') {
            gi += 1;
            continue;
        }
        if (pat[gi] != '(') continue;
        if (gi + 2 < pat.len and pat[gi + 1] == '?' and
            (pat[gi + 2] == '=' or pat[gi + 2] == '!' or pat[gi + 2] == ':' or pat[gi + 2] == '<'))
        {
            continue;
        }
        idx += 1;
    }
    return if (idx > max_groups - 1) max_groups - 1 else idx;
}

fn match_single_group_alternative(
    pat: []const u8,
    rest_start: usize,
    alternatives: [8]?[]const u8,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    grp_idx: u8,
    depth: u32,
    group_base: u8,
    inner_base: u8,
) ?usize {
    for (alternatives) |alt| {
        if (alt) |a| {
            if (match_single_group_alternative_at(
                pat,
                rest_start,
                a,
                input,
                ip,
                groups,
                grp_idx,
                depth,
                group_base,
                inner_base,
            )) |end| {
                return end;
            }
        } else break;
    }
    return null;
}

fn match_single_group_alternative_at(
    pat: []const u8,
    rest_start: usize,
    alternative: []const u8,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    grp_idx: u8,
    depth: u32,
    group_base: u8,
    inner_base: u8,
) ?usize {
    const initial_alt_end = match_at(
        alternative,
        0,
        input,
        ip,
        groups,
        depth + 1,
        inner_base,
    ) orelse return null;
    const greedy = greedy_atom_bounds(alternative);
    var alt_end: usize = initial_alt_end;
    while (true) {
        if (grp_idx > 0) groups.*[grp_idx] = .{ .start = ip, .end = alt_end };
        if (rest_start >= pat.len) return alt_end;
        if (match_at(pat, rest_start, input, alt_end, groups, depth + 1, group_base)) |final_end| {
            return final_end;
        }
        if (grp_idx > 0) groups.*[grp_idx] = null;
        if (alt_end <= ip) break;
        if (greedy) |g| {
            const min_end = ip + g.min;
            if (alt_end <= min_end) break;
            alt_end -= 1;
        } else {
            var next_end: usize = alt_end - 1;
            const sub_input = input[0..next_end];
            const sub_match = match_at(
                alternative,
                0,
                sub_input,
                ip,
                groups,
                depth + 1,
                inner_base,
            ) orelse break;
            next_end = sub_match;
            if (next_end == alt_end) {
                if (next_end == 0) break;
                next_end -= 1;
            }
            alt_end = next_end;
        }
    }
    return null;
}

fn is_backreference_token(pat: []const u8, pp: usize) bool {
    return pat[pp] == '\\' and pp + 1 < pat.len and pat[pp + 1] >= '1' and pat[pp + 1] <= '9';
}

fn match_backreference_at(
    pat: []const u8,
    pp: usize,
    input: []const u8,
    ip: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    const ref_idx: u8 = pat[pp + 1] - '0';
    const ref_span = groups.*[ref_idx] orelse return null;
    const ref_text = input[ref_span.start..ref_span.end];
    if (ip + ref_text.len > input.len) return null;
    if (!std.mem.eql(u8, input[ip .. ip + ref_text.len], ref_text)) return null;
    const rest_start = pp + 2;
    const new_ip = ip + ref_text.len;
    if (rest_start >= pat.len) return new_ip;
    return match_at(pat, rest_start, input, new_ip, groups, depth + 1, group_base);
}

fn match_quantified_atom_at(
    pat: []const u8,
    pp: usize,
    input: []const u8,
    input_pos: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    const atom_len = atom_length(pat, pp);
    if (atom_len == 0) return null;
    const quant = parse_quantifier(pat[pp + atom_len ..]);
    const rest_start = pp + atom_len + quant.len;

    var ip = input_pos;
    var count: usize = 0;
    var positions: [1001]usize = undefined;
    positions[0] = ip;
    while (count < quant.max and ip <= input.len) {
        if (!atom_matches(pat, pp, input, ip)) break;
        ip += 1;
        count += 1;
        if (count < positions.len) positions[count] = ip;
    }
    if (quant.greedy) {
        return match_greedy_atom_counts(
            pat,
            rest_start,
            input,
            positions,
            count,
            quant.min,
            groups,
            depth,
            group_base,
        );
    }
    return match_nongreedy_atom_counts(
        pat,
        rest_start,
        input,
        positions,
        count,
        quant.min,
        groups,
        depth,
        group_base,
    );
}

fn match_greedy_atom_counts(
    pat: []const u8,
    rest_start: usize,
    input: []const u8,
    positions: [1001]usize,
    count: usize,
    min_count: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    var try_count = count;
    while (true) {
        if (try_count >= min_count) {
            const try_ip = positions[@min(try_count, positions.len - 1)];
            if (rest_start >= pat.len) return try_ip;
            if (match_at(pat, rest_start, input, try_ip, groups, depth + 1, group_base)) |end| {
                return end;
            }
        }
        if (try_count == 0) break;
        try_count -= 1;
    }
    return null;
}

fn match_nongreedy_atom_counts(
    pat: []const u8,
    rest_start: usize,
    input: []const u8,
    positions: [1001]usize,
    count: usize,
    min_count: usize,
    groups: *[max_groups]?Span,
    depth: u32,
    group_base: u8,
) ?usize {
    var try_count = min_count;
    while (try_count <= count) : (try_count += 1) {
        const try_ip = positions[@min(try_count, positions.len - 1)];
        if (rest_start >= pat.len) return try_ip;
        if (match_at(pat, rest_start, input, try_ip, groups, depth + 1, group_base)) |end| {
            return end;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// アトムマッチング
// ---------------------------------------------------------------------------

fn atom_matches(pat: []const u8, pp: usize, input: []const u8, ip: usize) bool {
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
    if (pat[pp] == '[') return char_class_matches(pat, pp, c);
    return c == pat[pp];
}

/// Estimate the maximum number of characters a (fixed/bounded) lookbehind body can match.
/// Counts atoms with quantifier upper bounds; unbounded `*`/`+` cap at HARD_CAP.
/// Returns at most HARD_CAP to keep search cost predictable.
fn lookbehind_max_len(pat: []const u8) usize {
    const HARD_CAP: usize = 64;
    var total: usize = 0;
    var i: usize = 0;
    while (i < pat.len and total <= HARD_CAP) {
        if (pat[i] == '(') {
            const ge = find_group_end(pat, i) orelse return HARD_CAP;
            const inner_max = lookbehind_max_len(pat[i + 1 .. ge]);
            const q = parse_quantifier(pat[ge + 1 ..]);
            const reps: usize = if (q.max >= 1000) HARD_CAP else q.max;
            total +|= inner_max *| reps;
            i = ge + 1 + q.len;
            continue;
        }
        if (pat[i] == '|' or pat[i] == '^' or pat[i] == '$') {
            i += 1;
            continue;
        }
        const al = atom_length(pat, i);
        if (al == 0) {
            i += 1;
            continue;
        }
        const q = parse_quantifier(pat[i + al ..]);
        const reps: usize = if (q.max >= 1000) HARD_CAP else q.max;
        total +|= reps;
        i += al + q.len;
    }
    return @min(total, HARD_CAP);
}

fn atom_length(pat: []const u8, pp: usize) usize {
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

fn char_class_matches(pat: []const u8, pp: usize, c: u8) bool {
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

/// Inspect the body of a capturing group to decide whether any inner-match length
/// between `min` and the greedy maximum is valid. True only when the body is a
/// single atom followed by `*`, `+`, `?`, or `{n,m}` — the common `.*`, `\w+`,
/// `[abc]*` shapes that drive the fast shrink path in `matchAt`.
fn greedy_atom_bounds(pat: []const u8) ?struct { min: usize } {
    const al = atom_length(pat, 0);
    if (al == 0) return null;
    const quant_str = pat[al..];
    if (quant_str.len == 0) return null;
    const q = parse_quantifier(quant_str);
    // The atom + quantifier must be the entire body. Anything trailing invalidates
    // the assumption that every shorter length is a valid match.
    if (al + q.len != pat.len) return null;
    if (!q.greedy) return null;
    // `{n}` (fixed repetitions) doesn't allow shrinking below that exact length.
    if (q.min == q.max) return null;
    return .{ .min = q.min };
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

fn parse_quantifier(after: []const u8) Quantifier {
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

fn find_group_end(pat: []const u8, start: usize) ?usize {
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

fn split_alternatives(inner: []const u8) [8]?[]const u8 {
    var result: [8]?[]const u8 = .{null} ** 8;
    var count: usize = 0;
    var start: usize = 0;
    var depth: u32 = 0;
    var in_class: bool = false;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        // Skip escaped characters
        if (c == '\\' and i + 1 < inner.len) {
            i += 1;
            continue;
        }
        if (!in_class) {
            if (c == '[') {
                in_class = true;
                continue;
            }
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
        } else {
            if (c == ']') in_class = false;
        }
    }
    if (count < result.len) {
        result[count] = inner[start..];
    }
    return result;
}

fn match_quantified_group(
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
    group_base: u8,
    inner_base: u8,
) ?usize {
    const inner = pat[group_start + 1 .. group_end];
    var reps: [64]usize = undefined;
    var rep_count: usize = 0;
    var ip = start_ip;
    reps[0] = ip;
    while (rep_count < quant.max) {
        if (match_at(inner, 0, input, ip, groups, depth + 1, inner_base)) |end| {
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
                if (continue_quantified_group_match(
                    pat,
                    rest_start,
                    input,
                    try_ip,
                    reps[0..],
                    try_reps,
                    groups,
                    grp_idx,
                    depth + 1,
                    group_base,
                )) |end| return end;
            }
            if (try_reps == 0) break;
            try_reps -= 1;
        }
    } else {
        var try_reps = quant.min;
        while (try_reps <= rep_count) : (try_reps += 1) {
            const try_ip = reps[@min(try_reps, reps.len - 1)];
            if (continue_quantified_group_match(
                pat,
                rest_start,
                input,
                try_ip,
                reps[0..],
                try_reps,
                groups,
                grp_idx,
                depth + 1,
                group_base,
            )) |end| return end;
        }
    }
    return null;
}

fn continue_quantified_group_match(
    pat: []const u8,
    rest_start: usize,
    input: []const u8,
    try_ip: usize,
    reps: []const usize,
    try_reps: usize,
    groups: *[max_groups]?Span,
    grp_idx: u8,
    depth: u32,
    group_base: u8,
) ?usize {
    if (grp_idx > 0) {
        groups.*[grp_idx] = if (try_reps > 0)
            .{ .start = reps[try_reps - 1], .end = try_ip }
        else
            null;
    }
    if (rest_start >= pat.len) return try_ip;
    return match_at(pat, rest_start, input, try_ip, groups, depth, group_base);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "digit pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try find_all(arena.allocator(), "\\d+", "abc 123 def 456");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("123", result[0].group_slice(0, "abc 123 def 456").?);
    try std.testing.expectEqualStrings("456", result[1].group_slice(0, "abc 123 def 456").?);
}

test "capture groups" {
    const input = "user@host";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try find_all(arena.allocator(), "(\\w+)@(\\w+)", input);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("user@host", result[0].group_slice(0, input).?);
    try std.testing.expectEqualStrings("user", result[0].group_slice(1, input).?);
    try std.testing.expectEqualStrings("host", result[0].group_slice(2, input).?);
}

test "nested capture groups number correctly" {
    // Regression for a bug where inner capture groups silently overwrote the outer's
    // index, because the recursive matcher restarted group numbering from 1 on every
    // sub-pattern. Patterns like `((A) (B))` need group(1)=outer, group(2)=A, group(3)=B.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const input = "foo bar";
    const r = try find_all(a, "(([a-z]+) ([a-z]+))", input);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("foo bar", r[0].group_slice(0, input).?);
    try std.testing.expectEqualStrings("foo bar", r[0].group_slice(1, input).?);
    try std.testing.expectEqualStrings("foo", r[0].group_slice(2, input).?);
    try std.testing.expectEqualStrings("bar", r[0].group_slice(3, input).?);
}

test "greedy capture group backtracks to let the tail match" {
    // Regression: (.*)c on abc used to fail because the inner `.` atom greedily consumed
    // the trailing `c`, and the wrapping capture group never shrank its end. The engine
    // must reduce the group's end-position one char at a time so the rest-of-pattern gets
    // another chance.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expect(try matches(a, "a(.*)c", "abc"));
    try std.testing.expect(try matches(a, "a(.*)c", "abbc"));
    try std.testing.expect(try matches(a, "a (.*) c", "a bb c"));
    const input = "SELECT Name FROM Account";
    const r = try find_all(a, "SELECT (.*) FROM Account", input);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("Name", r[0].group_slice(1, input).?);
}

test "three-level nested captures preserve numbering" {
    // Mirrors the FormulaEvaluator compare-expression pattern which combines
    // (operand) (op) (operand) inside an outer group.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const input = "AAA ___ BBB";
    const r = try find_all(a, "(([A-Z]+) (_+) ([A-Z]+))", input);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("AAA ___ BBB", r[0].group_slice(1, input).?);
    try std.testing.expectEqualStrings("AAA", r[0].group_slice(2, input).?);
    try std.testing.expectEqualStrings("___", r[0].group_slice(3, input).?);
    try std.testing.expectEqualStrings("BBB", r[0].group_slice(4, input).?);
}

test "character class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try find_all(arena.allocator(), "[a-z]+", "Hello World");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("ello", result[0].group_slice(0, "Hello World").?);
    try std.testing.expectEqualStrings("orld", result[1].group_slice(0, "Hello World").?);
}

test "quantifier {n}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try find_all(arena.allocator(), "\\d{3}", "12 345 6789");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("345", result[0].group_slice(0, "12 345 6789").?);
    try std.testing.expectEqualStrings("678", result[1].group_slice(0, "12 345 6789").?);
}

test "alternation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try find_all(arena.allocator(), "(cat|dog)", "I have a cat and a dog");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("cat", result[0].group_slice(1, "I have a cat and a dog").?);
    try std.testing.expectEqualStrings("dog", result[1].group_slice(1, "I have a cat and a dog").?);
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
    const r1 = try find_all(a, pat, "(Some_Namespace)");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    const r2 = try find_all(a, pat, "(System Code)");
    try std.testing.expectEqual(@as(usize, 1), r2.len);
    const r3 = try find_all(a, pat, "Class.Foo.bar: line 1");
    try std.testing.expectEqual(@as(usize, 0), r3.len);
    const r4 = try find_all(a, pat, "()");
    try std.testing.expectEqual(@as(usize, 0), r4.len);
}

test "replaceAll with backreferences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    // Simple replacement without backreferences
    try std.testing.expectEqualStrings(
        "hello planet",
        try replace_all(a, "world", "hello world", "planet"),
    );
    // Backreference $1
    try std.testing.expectEqualStrings(
        "(abc) (def)",
        try replace_all(a, "(\\w+)", "abc def", "($1)"),
    );
    // SSN-like pattern: mask first two groups
    try std.testing.expectEqualStrings(
        "XXX-XX-1234",
        try replace_all(a, "(\\d{3})-(\\d{2})-(\\d{4})", "123-45-1234", "XXX-XX-$3"),
    );
    // No match → return original
    try std.testing.expectEqualStrings("hello", try replace_all(a, "\\d+", "hello", "NUM"));
}

test "replaceAll supports non-greedy quantifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "x<>b<>c",
        try replace_all(a, "a.+?z", "xa123zba456zc", "<>"),
    );
    try std.testing.expectEqualStrings(
        "\nClass.CallableLogger_Tests.test: line 10, column 1",
        try replace_all(
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

    const result = try find_all(arena.allocator(), "\\*\\s+@see\\s+(.*)", input);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("RestClient", result[0].group_slice(1, input).?);
    try std.testing.expectEqualStrings("ApiModel", result[1].group_slice(1, input).?);
}

test "positive lookahead (?=...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    // Match digits followed by a non-digit (without consuming the non-digit)
    const r1 = try find_all(a, "\\d+(?=[^0-9]|$)", "123abc");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("123", r1[0].group_slice(0, "123abc").?);
}

test "negative lookahead (?!...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    // Match digits NOT followed by more digits
    const r1 = try find_all(a, "\\d(?!\\d)", "1234a5b");
    try std.testing.expectEqual(@as(usize, 2), r1.len);
    try std.testing.expectEqualStrings("4", r1[0].group_slice(0, "1234a5b").?);
    try std.testing.expectEqualStrings("5", r1[1].group_slice(0, "1234a5b").?);
}

test "backreference \\1 in pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    // Match word repeated with same separator: "ab-cd-ef" where separators must be same
    const r1 = try find_all(a, "(\\d{4})([- ]?)\\d{4}\\2(\\d{4})", "1234-5678-9012");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("-", r1[0].group_slice(2, "1234-5678-9012").?);
    // Mixed separators should NOT match
    const r2 = try find_all(a, "(\\d{4})([- ])\\d{4}\\2(\\d{4})", "1234-5678 9012");
    try std.testing.expectEqual(@as(usize, 0), r2.len);
}

test "SSN regex replaceAll" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const ssn_pat = "(^|[^0-9A-Za-z])(\\d{3})[- ]?(\\d{2})[- ]?(\\d{4})(?=[^0-9A-Za-z]|$)";
    // Basic SSN: 123-45-6789 → XXX-XX-6789
    try std.testing.expectEqualStrings(
        "XXX-XX-6789",
        try replace_all(a, ssn_pat, "123-45-6789", "$1XXX-XX-$4"),
    );
    // SSN in context
    try std.testing.expectEqualStrings(
        "xyz XXX-XX-6789.",
        try replace_all(a, ssn_pat, "xyz 123-45-6789.", "$1XXX-XX-$4"),
    );
    // No dashes: 123456789 → XXX-XX-6789
    try std.testing.expectEqualStrings(
        "XXX-XX-6789",
        try replace_all(a, ssn_pat, "123456789", "$1XXX-XX-$4"),
    );
    // False positive: alphanumeric before → should NOT match
    try std.testing.expectEqualStrings(
        "abc123456789",
        try replace_all(a, ssn_pat, "abc123456789", "$1XXX-XX-$4"),
    );
}

test "negative lookbehind (?<!...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    // Match digits NOT preceded by another digit (similar to (?<!\d)\d+)
    const r1 = try find_all(a, "(?<!\\d)\\d+", "abc123def");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("123", r1[0].group_slice(0, "abc123def").?);
}

test "positive lookbehind (?<=...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    // Match a word preceded by "Mr "
    const r1 = try find_all(a, "(?<=Mr )\\w+", "Hello Mr Smith");
    try std.testing.expectEqual(@as(usize, 1), r1.len);
    try std.testing.expectEqualStrings("Smith", r1[0].group_slice(0, "Hello Mr Smith").?);
}

test "NebulaLogger SSN pattern (?<!\\d)...(?!\\d)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const ssn_pat = "(?<!\\d)(\\d{3})[- ]?(\\d{2})[- ]?(\\d{4})(?!\\d)";
    // Matches space-separated SSN
    try std.testing.expectEqualStrings(
        "Something my social is XXX-XX-9999 in case",
        try replace_all(a, ssn_pat, "Something my social is 400 11 9999 in case", "XXX-XX-$3"),
    );
    // Not preceded by digit, not followed by digit → NO match (false positive avoided)
    try std.testing.expectEqualStrings(
        "abc1234567890def",
        try replace_all(a, ssn_pat, "abc1234567890def", "XXX-XX-$3"),
    );
}
