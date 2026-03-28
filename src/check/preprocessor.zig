//! preprocessor — ソースコードの前処理。
//!
//! 解析前にコメント（行コメント・ブロックコメント）を除去しつつ
//! 行番号を保持する `stripCommentsPreserveLines` と、do-while ループの
//! 条件式位置を事前収集する `collectDoWhileStartConditions` を提供する。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

const DoLoopStart = types.DoLoopStart;
const updateBraceDepth = utils.updateBraceDepth;
const startsWithIgnoreCase = utils.startsWithIgnoreCase;
const findMatchingParen = utils.findMatchingParen;

pub fn stripCommentsPreserveLines(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
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

pub fn collectDoWhileStartConditions(
    allocator: std.mem.Allocator,
    content: []const u8,
) !std.AutoHashMap(usize, []const u8) {
    const stripped_content = try stripCommentsPreserveLines(allocator, content);
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
        const code_line = raw;
        const trimmed = std.mem.trim(u8, code_line, " \t\r");

        if (trimmed.len > 0) {
            if (isDoLoopStart(trimmed)) {
                if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                    try do_stack.append(allocator, .{
                        .start_line = line_no,
                        .end_depth = brace_depth + 1,
                    });
                    pending_do_start = null;
                } else {
                    pending_do_start = .{
                        .start_line = line_no,
                        .end_depth = brace_depth,
                    };
                }
            } else if (pending_do_start) |pending| {
                if (trimmed[0] == '{' and pending.end_depth == brace_depth) {
                    try do_stack.append(allocator, .{
                        .start_line = pending.start_line,
                        .end_depth = brace_depth + 1,
                    });
                }
                pending_do_start = null;
            }

            if (try parseDoWhileTailCondition(allocator, trimmed)) |condition| {
                errdefer allocator.free(condition);
                if (do_stack.items.len > 0 and do_stack.items[do_stack.items.len - 1].end_depth == brace_depth) {
                    const do_start = do_stack.pop().?;
                    try out.put(do_start.start_line, condition);
                } else {
                    allocator.free(condition);
                }
            }
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        if (pending_do_start) |pending| {
            if (brace_depth < pending.end_depth) {
                pending_do_start = null;
            }
        }
        while (do_stack.items.len > 0 and do_stack.items[do_stack.items.len - 1].end_depth > brace_depth) {
            _ = do_stack.pop();
        }
    }

    return out;
}

pub fn isDoLoopStart(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (!startsWithIgnoreCase(trimmed, "do")) return false;
    if (trimmed.len == 2) return true;
    const next = trimmed[2];
    return next == ' ' or next == '\t' or next == '{';
}

pub fn parseDoWhileTailCondition(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 8 or trimmed[0] != '}') return null;

    trimmed = std.mem.trimLeft(u8, trimmed[1..], " \t");
    if (!startsWithIgnoreCase(trimmed, "while")) return null;
    if (trimmed.len > "while".len) {
        const next = trimmed["while".len];
        if (!(next == ' ' or next == '\t' or next == '(')) return null;
    }

    var rest = std.mem.trimLeft(u8, trimmed["while".len..], " \t");
    if (rest.len == 0 or rest[0] != '(') return null;

    const close = findMatchingParen(rest, 0) orelse return null;
    const after = std.mem.trim(u8, rest[(close + 1)..], " \t");
    if (after.len > 0 and !std.mem.eql(u8, after, ";")) return null;

    const cond = std.mem.trim(u8, rest[1..close], " \t");
    if (cond.len == 0) return null;
    return try allocator.dupe(u8, cond);
}

pub fn isLoopStart(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for (") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while (") or
        isDoLoopStart(line);
}
