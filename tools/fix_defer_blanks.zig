//! tools/fix_defer_blanks.zig — auto-insert blank line after defer statements.
//!
//! Usage: `zig run tools/fix_defer_blanks.zig -- <path1> [path2 ...]`
//!
//! Uses std.zig.Ast to find defer statements and insert a blank line after the
//! terminating `;` when the following token is on `defer_line + 1` and is not
//! another defer/errdefer or a closing brace.
//!
//! Ignores files that fail to parse and skips already-correct defer blocks.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;
const Ast = std.zig.Ast;

fn isCommentToken(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .doc_comment, .container_doc_comment => true,
        else => false,
    };
}

fn deferStatementEnd(tags: []const std.zig.Token.Tag, defer_index: usize) ?usize {
    var depth: i32 = 0;
    var index: usize = defer_index + 1;
    while (index < tags.len) : (index += 1) {
        switch (tags[index]) {
            .l_paren, .l_brace, .l_bracket => depth += 1,
            .r_paren, .r_brace, .r_bracket => depth -= 1,
            else => {},
        }
        if (depth == 0) {
            switch (tags[index]) {
                .semicolon => return index,
                .r_brace => {
                    if (index + 1 < tags.len) {
                        if (tags[index + 1] == .semicolon) return index + 1;
                        if (tags[index + 1] == .keyword_else) continue;
                    }
                    return index;
                },
                else => {},
            }
        } else if (depth < 0) {
            return null;
        }
    }
    return null;
}

const Insertion = struct {
    /// Line number (1-based) where the blank line should be inserted BEFORE.
    line_after: usize,
};

fn collectInsertions(gpa: mem.Allocator, tree: *const Ast, out: *std.ArrayList(Insertion)) !void {
    const tags = tree.tokens.items(.tag);
    var index: usize = 0;
    while (index < tags.len) : (index += 1) {
        if (tags[index] != .keyword_defer) continue;
        const semi = deferStatementEnd(tags, index) orelse continue;
        const semi_line = tree.tokenLocation(0, @intCast(semi)).line;

        var next_index = semi + 1;
        while (next_index < tags.len and isCommentToken(tags[next_index])) : (next_index += 1) {}
        if (next_index >= tags.len) break;
        const next_tag = tags[next_index];
        if (next_tag == .eof) continue;
        if (next_tag == .r_brace or next_tag == .keyword_errdefer or next_tag == .keyword_defer) continue;

        const next_line = tree.tokenLocation(0, @intCast(next_index)).line;
        if (next_line <= semi_line + 1) {
            // Insert a blank line BEFORE `next_line` (0-based: before index next_line - 1)
            try out.append(gpa, .{ .line_after = next_line });
        }
    }
}

fn fixFile(gpa: mem.Allocator, io: Io, cwd: Dir, path: []const u8) !bool {
    const bytes = cwd.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("skip {s}: {}\n", .{ path, err });
        return false;
    };
    defer gpa.free(bytes);

    const content_z = try gpa.dupeZ(u8, bytes);
    defer gpa.free(content_z);

    var tree = Ast.parse(gpa, content_z, .zig) catch |err| {
        std.debug.print("parse failed {s}: {}\n", .{ path, err });
        return false;
    };
    defer tree.deinit(gpa);

    var insertions: std.ArrayList(Insertion) = .empty;
    defer insertions.deinit(gpa);
    try collectInsertions(gpa, &tree, &insertions);
    if (insertions.items.len == 0) return false;

    // Split content by lines (preserving newlines), insert blanks, join.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            try lines.append(gpa, bytes[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < bytes.len) try lines.append(gpa, bytes[start..]);

    // Sort insertions descending so indexes don't shift during insertion.
    const Ctx = struct {
        fn gt(_: void, a: Insertion, b: Insertion) bool {
            return a.line_after > b.line_after;
        }
    };
    std.mem.sort(Insertion, insertions.items, {}, Ctx.gt);

    // `line_after` is the 0-based line index (from Ast.tokenLocation) of the
    // next non-comment token after the defer's `;`. We want to leave a blank
    // line immediately before that line, so we insert "\n" at `lines[line_after]`.
    for (insertions.items) |ins| {
        const idx = ins.line_after;
        if (idx > lines.items.len) continue;
        try lines.insert(gpa, idx, "\n");
    }

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(gpa);
    for (lines.items) |line| try out_buf.appendSlice(gpa, line);

    // Write back.
    try cwd.writeFile(io, .{ .sub_path = path, .data = out_buf.items });
    std.debug.print("fixed {s}: +{d} blank line(s)\n", .{ path, insertions.items.len });
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = Dir.cwd();

    var args_it = init.minimal.args.iterate();
    defer args_it.deinit();
    _ = args_it.next();

    var any: bool = false;
    while (args_it.next()) |arg| {
        any = true;
        _ = try fixFile(gpa, io, cwd, arg);
    }
    if (!any) {
        std.debug.print("usage: zig run tools/fix_defer_blanks.zig -- <path>...\n", .{});
    }
}
