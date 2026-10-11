//! Extract all camelCase fn_decl names from .zig files under src/.
//!
//! Prints one entry per line: `camel_name\tsnake_name\tpath`.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;
const Ast = std.zig.Ast;

fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (mem.eql(u8, name, "_")) return true;
    var prev_underscore = false;
    for (name, 0..) |c, i| {
        const is_lower = c >= 'a' and c <= 'z';
        const is_digit = c >= '0' and c <= '9';
        if (is_lower or is_digit) {
            prev_underscore = false;
            continue;
        }
        if (c == '_') {
            if (i == 0 or i + 1 == name.len or prev_underscore) return false;
            prev_underscore = true;
            continue;
        }
        return false;
    }
    return true;
}

fn toSnakeCase(gpa: mem.Allocator, name: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (name, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            if (i > 0) try buf.append(gpa, '_');
            try buf.append(gpa, c + ('a' - 'A'));
        } else {
            try buf.append(gpa, c);
        }
    }
    return buf.toOwnedSlice(gpa);
}

fn processFile(gpa: mem.Allocator, io: Io, cwd: Dir, path: []const u8, writer: anytype) !void {
    const bytes = cwd.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch return;
    defer gpa.free(bytes);

    const content_z = try gpa.dupeZ(u8, bytes);
    defer gpa.free(content_z);

    var tree = Ast.parse(gpa, content_z, .zig) catch return;
    defer tree.deinit(gpa);

    const tags = tree.nodes.items(.tag);
    var buf: [1]Ast.Node.Index = undefined;
    for (tags, 0..) |tag, node_usize| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @enumFromInt(node_usize);
        const fn_proto = tree.fullFnProto(&buf, node) orelse continue;
        if (fn_proto.extern_export_inline_token) |token| {
            if (tree.tokens.items(.tag)[token] == .keyword_extern) continue;
        }
        const name_token = fn_proto.name_token orelse continue;
        const name = tree.tokenSlice(name_token);
        if (isSnakeCase(name)) continue;
        const snake = try toSnakeCase(gpa, name);
        defer gpa.free(snake);
        try writer.print("{s}\t{s}\t{s}\n", .{ name, snake, path });
    }
}

fn walkRoot(gpa: mem.Allocator, io: Io, cwd: Dir, root: []const u8, writer: anytype) !void {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.path, ".zig")) continue;
        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        try paths.append(gpa, joined);
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (paths.items) |p| try processFile(gpa, io, cwd, p, writer);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = Dir.cwd();

    var buf: [8192]u8 = undefined;
    var state = File.stdout().writer(io, &buf);
    const w = &state.interface;

    try walkRoot(gpa, io, cwd, "src", w);
    try w.flush();
}
