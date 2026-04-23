//! file_collector — ファイルシステムからの Apex ソース収集。
//!
//! 指定パス（ファイルまたはディレクトリ）を走査し、`.cls` / `.trigger`
//! 拡張子を持つ Apex ソースファイルを再帰的に収集する。

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const utils = @import("utils.zig");

const ApexFile = types.ApexFile;
const isApexSource = utils.isApexSource;

pub fn collectApexFiles(gpa: std.mem.Allocator, io: Io, roots: []const []const u8) !std.ArrayList(ApexFile) {
    var files: std.ArrayList(ApexFile) = .empty;
    errdefer deinitApexFiles(gpa, &files);
    for (roots) |root| {
        try collectPath(gpa, io, root, &files);
    }
    return files;
}

fn collectPath(gpa: std.mem.Allocator, io: Io, path: []const u8, files: *std.ArrayList(ApexFile)) !void {
    collectDirectory(gpa, io, path, files) catch |err| switch (err) {
        error.NotDir => {
            if (isApexSource(path)) {
                try appendApexFile(gpa, io, files, path);
            }
        },
        else => return err,
    };
}

fn collectDirectory(gpa: std.mem.Allocator, io: Io, root: []const u8, files: *std.ArrayList(ApexFile)) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isApexSource(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        defer gpa.free(joined);

        try appendApexFile(gpa, io, files, joined);
    }
}

fn appendApexFile(gpa: std.mem.Allocator, io: Io, files: *std.ArrayList(ApexFile), path: []const u8) !void {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    errdefer gpa.free(content);

    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    try files.append(gpa, .{
        .path = path_copy,
        .content = content,
    });
}

pub fn deinitApexFiles(gpa: std.mem.Allocator, files: *std.ArrayList(ApexFile)) void {
    for (files.items) |file| {
        gpa.free(file.path);
        gpa.free(file.content);
    }
    files.deinit(gpa);
}
