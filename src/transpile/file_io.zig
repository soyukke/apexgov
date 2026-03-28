const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const ApexFile = types.ApexFile;

pub fn collectApexFiles(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(ApexFile) {
    var files: std.ArrayList(ApexFile) = .empty;
    errdefer deinitApexFiles(gpa, &files);

    for (roots) |r| {
        try collectPath(gpa, r, &files);
    }
    return files;
}

pub fn collectApexTriggerFiles(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(ApexFile) {
    var files: std.ArrayList(ApexFile) = .empty;
    errdefer deinitApexFiles(gpa, &files);

    for (roots) |r| {
        try collectTriggerPath(gpa, r, &files);
    }
    return files;
}

pub fn collectPath(gpa: std.mem.Allocator, path: []const u8, files: *std.ArrayList(ApexFile)) !void {
    collectDirectory(gpa, path, files) catch |err| switch (err) {
        error.NotDir => {
            if (util.isApexClassSource(path)) {
                try appendApexFile(gpa, files, path);
            }
        },
        else => return err,
    };
}

pub fn collectTriggerPath(gpa: std.mem.Allocator, path: []const u8, files: *std.ArrayList(ApexFile)) !void {
    collectTriggerDirectory(gpa, path, files) catch |err| switch (err) {
        error.NotDir => {
            if (util.isApexTriggerSource(path)) {
                try appendApexFile(gpa, files, path);
            }
        },
        else => return err,
    };
}

pub fn collectDirectory(gpa: std.mem.Allocator, r: []const u8, files: *std.ArrayList(ApexFile)) !void {
    var dir = try std.fs.cwd().openDir(r, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!util.isApexClassSource(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ r, entry.path });
        defer gpa.free(joined);
        try appendApexFile(gpa, files, joined);
    }
}

pub fn collectTriggerDirectory(gpa: std.mem.Allocator, r: []const u8, files: *std.ArrayList(ApexFile)) !void {
    var dir = try std.fs.cwd().openDir(r, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!util.isApexTriggerSource(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ r, entry.path });
        defer gpa.free(joined);
        try appendApexFile(gpa, files, joined);
    }
}

pub fn appendApexFile(gpa: std.mem.Allocator, files: *std.ArrayList(ApexFile), path: []const u8) !void {
    var content = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    errdefer gpa.free(content);

    content = try normalizeApexTemplateTokens(gpa, content);

    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    try files.append(gpa, .{
        .path = path_copy,
        .content = content,
    });
}

pub fn normalizeApexTemplateTokens(gpa: std.mem.Allocator, content: []u8) ![]u8 {
    const tokens = [_][]const u8{
        "%%%NAMESPACE%%%",
        "%%%NAMESPACED_RT%%%",
        "___NAMESPACE___",
        "___NAMESPACED_RT___",
    };

    var needs_rewrite = false;
    inline for (tokens) |token| {
        if (std.mem.indexOf(u8, content, token) != null) {
            needs_rewrite = true;
            break;
        }
    }
    if (!needs_rewrite) return content;

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(gpa);
    try normalized.ensureTotalCapacity(gpa, content.len);

    var cursor: usize = 0;
    while (cursor < content.len) {
        var matched = false;
        inline for (tokens) |token| {
            if (matched) break;
            if (std.mem.startsWith(u8, content[cursor..], token)) {
                cursor += token.len;
                matched = true;
            }
        }
        if (matched) continue;

        try normalized.append(gpa, content[cursor]);
        cursor += 1;
    }

    const rewritten = try normalized.toOwnedSlice(gpa);
    gpa.free(content);
    return rewritten;
}

pub fn deinitApexFiles(gpa: std.mem.Allocator, files: *std.ArrayList(ApexFile)) void {
    for (files.items) |file| {
        gpa.free(file.path);
        gpa.free(file.content);
    }
    files.deinit(gpa);
}

pub fn writeOutputFile(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            try std.fs.cwd().makePath(parent);
        }
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}
