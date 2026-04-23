//! scripts/find_long_functions.zig
//! 70 行超えの関数を「ファイル:開始行:終了行:行数:名前(あれば)」で列挙する。
//! dotfiles/zig-tools/check_style.zig の checkFunctionLength と判定ロジックを揃える:
//! - `Ast.parse` で fn_decl を列挙
//! - ネストした関数がある場合は外側を skip (TigerBeetle 流)
//! - `function_line_limit` (既定 70) を超えた関数だけ出す

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Ast = std.zig.Ast;

const max_file_bytes: usize = 16 * 1024 * 1024;

const FnRange = struct {
    line_opening: usize,
    line_closing: usize,
    name_start_token: Ast.TokenIndex,
};

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

    const content_z = try allocator.dupeZ(u8, content);
    defer allocator.free(content_z);

    var tree = try Ast.parse(allocator, content_z, .zig);
    defer tree.deinit(allocator);

    var functions: std.ArrayListUnmanaged(FnRange) = .empty;
    defer functions.deinit(allocator);

    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    for (tags, datas, 0..) |tag, data, node_usize| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @enumFromInt(node_usize);
        const body_node = data.node_and_node[1];
        const token_opening = tree.firstToken(node);
        const token_closing = tree.lastToken(body_node);
        const line_opening = tree.tokenLocation(0, token_opening).line;
        const line_closing = tree.tokenLocation(0, token_closing).line;
        try functions.append(allocator, .{
            .line_opening = line_opening,
            .line_closing = line_closing,
            .name_start_token = token_opening,
        });
    }

    const Ctx = struct {
        fn lessThan(_: void, a: FnRange, b: FnRange) bool {
            if (a.line_opening != b.line_opening) return a.line_opening < b.line_opening;
            return a.line_closing < b.line_closing;
        }
    };
    std.mem.sort(FnRange, functions.items, {}, Ctx.lessThan);

    for (functions.items, 0..) |fn_range, i| {
        if (i + 1 < functions.items.len and
            functions.items[i + 1].line_opening <= fn_range.line_closing)
        {
            continue;
        }
        const length = fn_range.line_closing - fn_range.line_opening + 1;
        if (length <= limit) continue;

        // name token を大雑把に取り出す。fn キーワード直後の identifier を探す。
        var name: []const u8 = "<anonymous>";
        const token_tags = tree.tokens.items(.tag);
        var t: usize = fn_range.name_start_token;
        while (t < token_tags.len) : (t += 1) {
            if (token_tags[t] == .identifier) {
                name = tree.tokenSlice(@intCast(t));
                break;
            }
        }

        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &buf,
            "{s}:{d}:{d}:{d}:{s}\n",
            .{ path, fn_range.line_opening + 1, fn_range.line_closing + 1, length, name },
        );
        try out.writeStreamingAll(io, msg);
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

    var limit: usize = 70;
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
