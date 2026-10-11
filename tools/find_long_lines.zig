//! scripts/find_long_lines.zig
//! 100 cols 超え行をファイル名:行番号:col 数:内容 で列挙するワンショット CLI。
//! 単独 `zig run scripts/find_long_lines.zig -- src` で実行。
//!
//! 判定ロジックは dotfiles/zig-tools/check_style.zig の lineTooLong と揃える:
//!   - utf8 codepoint 数で判定
//!   - `https://` を含む行はスキップ
//!   - raw string literal (`\\`) でインデントが空白のみなら文字列部分で判定

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

const max_file_bytes: usize = 16 * 1024 * 1024;

fn rawStringValue(line: []const u8) ?[]const u8 {
    const split = mem.indexOf(u8, line, "\\\\") orelse return null;
    const indent = line[0..split];
    for (indent) |c| if (c != ' ') return null;
    return line[split + 2 ..];
}

fn isLong(line: []const u8, limit: usize) bool {
    const n = std.unicode.utf8CountCodepoints(line) catch line.len;
    if (n <= limit) return false;
    if (mem.indexOf(u8, line, "https://") != null) return false;
    if (rawStringValue(line)) |body| {
        const bn = std.unicode.utf8CountCodepoints(body) catch body.len;
        if (bn <= limit) return false;
    }
    return true;
}

fn scanFile(
    allocator: mem.Allocator,
    io: Io,
    path: []const u8,
    limit: usize,
    out: File,
) !void {
    const cwd = Dir.cwd();
    const content = cwd.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &buf,
            "warn: cannot read {s}: {s}\n",
            .{ path, @errorName(err) },
        );
        try out.writeStreamingAll(io, msg);
        return;
    };
    defer allocator.free(content);

    var line_number: usize = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            var line = content[start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (isLong(line, limit)) {
                var buf: [4096]u8 = undefined;
                const n = std.unicode.utf8CountCodepoints(line) catch line.len;
                const msg = try std.fmt.bufPrint(
                    &buf,
                    "{s}:{d}:{d}\n",
                    .{ path, line_number, n },
                );
                try out.writeStreamingAll(io, msg);
            }
            line_number += 1;
            start = i + 1;
        }
    }
    if (start < content.len) {
        var line = content[start..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (isLong(line, limit)) {
            var buf: [4096]u8 = undefined;
            const n = std.unicode.utf8CountCodepoints(line) catch line.len;
            const msg = try std.fmt.bufPrint(
                &buf,
                "{s}:{d}:{d}\n",
                .{ path, line_number, n },
            );
            try out.writeStreamingAll(io, msg);
        }
    }
}

fn walkRoot(allocator: mem.Allocator, io: Io, root: []const u8, limit: usize, out: File) !void {
    const cwd = Dir.cwd();
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".zig")) continue;
        const joined = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(joined);
        try scanFile(allocator, io, joined, limit, out);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var limit: usize = 100;
    var root: []const u8 = "src";

    var it = init.minimal.args.iterate();
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        if (mem.eql(u8, arg, "--limit")) {
            const v = it.next() orelse return error.MissingValue;
            limit = try std.fmt.parseInt(usize, v, 10);
        } else {
            root = try allocator.dupe(u8, arg);
        }
    }

    const out = File.stdout();
    try walkRoot(allocator, io, root, limit, out);
}
