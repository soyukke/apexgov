//! preprocessor — ソースコードの前処理。
//!
//! 解析前にコメント（行コメント・ブロックコメント）を除去しつつ
//! 行番号を保持する `strip_comments_preserve_lines` と、do-while ループの
//! 条件式位置を事前収集する `collect_do_while_start_conditions` を提供する。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

const DoLoopStart = types.DoLoopStart;
const update_brace_depth = utils.update_brace_depth;
const starts_with_ignore_case = utils.starts_with_ignore_case;
const find_matching_paren = utils.find_matching_paren;

pub fn strip_comments_preserve_lines(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var in_block = false;
    while (i < content.len) {
        if (in_block) {
            if (i + 1 < content.len and content[i] == '*' and content[i + 1] == '/') {
                in_block = false;
                i += 2;
                continue;
            }
            if (content[i] == '\n') {
                try out.append(allocator, '\n');
            }
            i += 1;
            continue;
        }

        if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '*') {
            in_block = true;
            i += 2;
            continue;
        }

        if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '/') {
            i += 2;
            while (i < content.len and content[i] != '\n') : (i += 1) {}
            continue;
        }

        try out.append(allocator, content[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn collect_do_while_start_conditions(
    allocator: std.mem.Allocator,
    content: []const u8,
) !std.AutoHashMap(usize, []const u8) {
    const stripped_content = try strip_comments_preserve_lines(allocator, content);
    return collect_do_while_start_conditions_from_stripped(allocator, stripped_content);
}

pub fn collect_do_while_start_conditions_from_stripped(
    allocator: std.mem.Allocator,
    stripped_content: []const u8,
) !std.AutoHashMap(usize, []const u8) {
    var out = std.AutoHashMap(usize, []const u8).init(allocator);
    errdefer out.deinit();

    var do_stack: std.ArrayList(DoLoopStart) = .empty;
    defer do_stack.deinit(allocator);

    var pending_do_start: ?DoLoopStart = null;
    var brace_depth: i32 = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len > 0) {
            try process_do_while_non_empty_line(
                allocator,
                trimmed,
                line_no,
                brace_depth,
                &do_stack,
                &pending_do_start,
                &out,
            );
        }
        brace_depth = update_brace_depth(brace_depth, raw);
        if (pending_do_start) |pending| {
            if (brace_depth < pending.end_depth) pending_do_start = null;
        }
        while (do_stack.items.len > 0 and
            do_stack.items[do_stack.items.len - 1].end_depth > brace_depth)
        {
            _ = do_stack.pop();
        }
    }
    return out;
}

fn process_do_while_non_empty_line(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    line_no: usize,
    brace_depth: i32,
    do_stack: *std.ArrayList(DoLoopStart),
    pending_do_start: *?DoLoopStart,
    out: *std.AutoHashMap(usize, []const u8),
) !void {
    if (is_do_loop_start(trimmed)) {
        if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            try do_stack.append(allocator, .{
                .start_line = line_no,
                .end_depth = brace_depth + 1,
            });
            pending_do_start.* = null;
        } else {
            pending_do_start.* = .{
                .start_line = line_no,
                .end_depth = brace_depth,
            };
        }
    } else if (pending_do_start.*) |pending| {
        if (trimmed[0] == '{' and pending.end_depth == brace_depth) {
            try do_stack.append(allocator, .{
                .start_line = pending.start_line,
                .end_depth = brace_depth + 1,
            });
        }
        pending_do_start.* = null;
    }

    if (try parse_do_while_tail_condition(allocator, trimmed)) |condition| {
        errdefer allocator.free(condition);
        if (do_stack.items.len > 0 and
            do_stack.items[do_stack.items.len - 1].end_depth == brace_depth)
        {
            const do_start = do_stack.pop().?;
            try out.put(do_start.start_line, condition);
        } else {
            allocator.free(condition);
        }
    }
}

pub fn is_do_loop_start(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!starts_with_ignore_case(trimmed, "do")) return false;
    if (trimmed.len == 2) return true;
    const next = trimmed[2];
    return next == ' ' or next == '\t' or next == '{';
}

pub fn parse_do_while_tail_condition(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 8 or trimmed[0] != '}') return null;

    trimmed = std.mem.trimStart(u8, trimmed[1..], " \t");
    if (!starts_with_ignore_case(trimmed, "while")) return null;
    if (trimmed.len > "while".len) {
        const next = trimmed["while".len];
        if (!(next == ' ' or next == '\t' or next == '(')) return null;
    }

    var rest = std.mem.trimStart(u8, trimmed["while".len..], " \t");
    if (rest.len == 0 or rest[0] != '(') return null;

    const close = find_matching_paren(rest, 0) orelse return null;
    const after = std.mem.trim(u8, rest[(close + 1)..], " \t");
    if (after.len > 0 and !std.mem.eql(u8, after, ";")) return null;

    const cond = std.mem.trim(u8, rest[1..close], " \t");
    if (cond.len == 0) return null;
    return try allocator.dupe(u8, cond);
}

pub fn is_loop_start(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for (") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while (") or
        is_do_loop_start(line);
}
