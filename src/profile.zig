const std = @import("std");
const model = @import("model.zig");
const config = @import("config.zig");

pub fn run(gpa: std.mem.Allocator, inputs: []const []const u8, cfg: config.Config) !std.ArrayList(model.ProfileResult) {
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |path| gpa.free(path);
        files.deinit(gpa);
    }

    for (inputs) |input| {
        try collectLogs(gpa, input, &files);
    }

    var results: std.ArrayList(model.ProfileResult) = .empty;
    errdefer model.deinitProfiles(gpa, &results);

    for (files.items) |path| {
        const maybe_result = try parseLog(gpa, path, cfg);
        if (maybe_result) |result| {
            try results.append(gpa, result);
        }
    }

    return results;
}

fn collectLogs(gpa: std.mem.Allocator, input: []const u8, files: *std.ArrayList([]const u8)) !void {
    collectLogsInDirectory(gpa, input, files) catch |err| switch (err) {
        error.NotDir => {
            try files.append(gpa, try gpa.dupe(u8, input));
        },
        else => return err,
    };
}

fn collectLogsInDirectory(gpa: std.mem.Allocator, root: []const u8, files: *std.ArrayList([]const u8)) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isLogFile(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        errdefer gpa.free(joined);

        try files.append(gpa, joined);
    }
}

fn parseLog(gpa: std.mem.Allocator, path: []const u8, cfg: config.Config) !?model.ProfileResult {
    const content = try std.fs.cwd().readFileAlloc(gpa, path, 32 * 1024 * 1024);
    defer gpa.free(content);

    var label: ?[]const u8 = null;
    errdefer if (label) |value| gpa.free(value);

    var cpu_max: u32 = 0;
    var heap_max: u64 = 0;
    var saw_metric = false;
    var is_async = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (label == null and std.mem.indexOf(u8, line, "CODE_UNIT_STARTED|") != null) {
            label = try parseCodeUnitLabel(gpa, line);
        }
        if (containsAsyncMarker(line)) {
            is_async = true;
        }

        if (parseLimitValue(line, "Maximum CPU time:")) |value| {
            saw_metric = true;
            const parsed: u32 = @intCast(@min(value, std.math.maxInt(u32)));
            if (parsed > cpu_max) cpu_max = parsed;
        }
        if (parseLimitValue(line, "Maximum heap size:")) |value| {
            saw_metric = true;
            if (value > heap_max) heap_max = value;
        }
    }

    if (!saw_metric) return null;

    if (label == null) {
        label = try gpa.dupe(u8, "unknown");
    }

    const budget = if (is_async) cfg.budget_async else cfg.budget_sync;
    return .{
        .source = try gpa.dupe(u8, path),
        .label = label.?,
        .is_async = is_async,
        .cpu_ms = cpu_max,
        .heap_bytes = heap_max,
        .cpu_budget = budget.cpu_ms,
        .heap_budget = budget.heap_bytes,
    };
}

fn parseCodeUnitLabel(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, line, '|');
    var last: []const u8 = "";
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len > 0) last = trimmed;
    }

    if (last.len == 0) return gpa.dupe(u8, "unknown");
    return gpa.dupe(u8, last);
}

fn parseLimitValue(line: []const u8, marker: []const u8) ?u64 {
    const marker_idx = std.mem.indexOf(u8, line, marker) orelse return null;
    var i = marker_idx + marker.len;

    while (i < line.len and !std.ascii.isDigit(line[i])) : (i += 1) {}
    const start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}

    if (start == i) return null;
    return std.fmt.parseUnsigned(u64, line[start..i], 10) catch null;
}

fn containsAsyncMarker(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "FUTURE_HANDLER") != null or
        std.mem.indexOf(u8, line, "QUEUEABLE") != null or
        std.mem.indexOf(u8, line, "BATCH_") != null or
        std.mem.indexOf(u8, line, "SCHEDULED") != null;
}

fn isLogFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".log");
}

test "parseLimitValue parses numeric prefix" {
    const line = "MAXIMUM LIMIT_USAGE_FOR_NS|(default)| Maximum CPU time: 1234 out of 10000";
    const parsed = parseLimitValue(line, "Maximum CPU time:") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 1234), parsed);
}
