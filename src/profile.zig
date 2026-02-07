const std = @import("std");
const model = @import("model.zig");
const config = @import("config.zig");

pub const Regression = struct {
    source: []const u8,
    label: []const u8,
    is_async: bool,
    cpu_current: u32,
    cpu_baseline: u32,
    heap_current: u64,
    heap_baseline: u64,
    cpu_regressed: bool,
    heap_regressed: bool,

    pub fn any(self: Regression) bool {
        return self.cpu_regressed or self.heap_regressed;
    }
};

const BaselineProfile = struct {
    source: []const u8 = "",
    label: []const u8 = "unknown",
    mode: []const u8 = "sync",
    cpu_ms: u32 = 0,
    heap_bytes: u64 = 0,
};

const BaselineDocument = struct {
    profiles: []const BaselineProfile = &.{},
};

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

pub fn compareWithBaseline(
    gpa: std.mem.Allocator,
    current: []const model.ProfileResult,
    baseline_path: ?[]const u8,
    threshold_percent: u8,
) !std.ArrayList(Regression) {
    var regressions: std.ArrayList(Regression) = .empty;
    errdefer deinitRegressions(gpa, &regressions);

    if (baseline_path == null) return regressions;

    const raw = try std.fs.cwd().readFileAlloc(gpa, baseline_path.?, 4 * 1024 * 1024);
    defer gpa.free(raw);

    var parsed = try std.json.parseFromSlice(BaselineDocument, gpa, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    for (current) |curr| {
        const baseline = findBaseline(curr, parsed.value.profiles) orelse continue;

        const cpu_regressed = exceedsPercent(curr.cpu_ms, baseline.cpu_ms, threshold_percent);
        const heap_regressed = exceedsPercent(curr.heap_bytes, baseline.heap_bytes, threshold_percent);
        if (!cpu_regressed and !heap_regressed) continue;

        try regressions.append(gpa, .{
            .source = try gpa.dupe(u8, curr.source),
            .label = try gpa.dupe(u8, curr.label),
            .is_async = curr.is_async,
            .cpu_current = curr.cpu_ms,
            .cpu_baseline = baseline.cpu_ms,
            .heap_current = curr.heap_bytes,
            .heap_baseline = baseline.heap_bytes,
            .cpu_regressed = cpu_regressed,
            .heap_regressed = heap_regressed,
        });
    }

    return regressions;
}

pub fn deinitRegressions(gpa: std.mem.Allocator, regressions: *std.ArrayList(Regression)) void {
    for (regressions.items) |regression| {
        gpa.free(regression.source);
        gpa.free(regression.label);
    }
    regressions.deinit(gpa);
}

fn findBaseline(curr: model.ProfileResult, baseline_profiles: []const BaselineProfile) ?BaselineProfile {
    const curr_mode = if (curr.is_async) "async" else "sync";
    const curr_label_known = !isUnknown(curr.label);
    const curr_base = std.fs.path.basename(curr.source);

    for (baseline_profiles) |baseline| {
        if (!std.ascii.eqlIgnoreCase(curr_mode, baseline.mode)) continue;

        const baseline_label_known = !isUnknown(baseline.label);
        if (curr_label_known and baseline_label_known) {
            if (std.mem.eql(u8, curr.label, baseline.label)) return baseline;
            continue;
        }

        if (std.mem.eql(u8, curr_base, std.fs.path.basename(baseline.source))) return baseline;
    }

    return null;
}

fn isUnknown(label: []const u8) bool {
    return label.len == 0 or std.ascii.eqlIgnoreCase(label, "unknown");
}

fn exceedsPercent(current: u64, baseline: u64, threshold_percent: u8) bool {
    if (baseline == 0) return current > 0;

    const lhs: u128 = @as(u128, current) * 100;
    const rhs: u128 = @as(u128, baseline) * (100 + @as(u128, threshold_percent));
    return lhs > rhs;
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

test "exceedsPercent compares with threshold" {
    try std.testing.expect(exceedsPercent(116, 100, 15));
    try std.testing.expect(!exceedsPercent(115, 100, 15));
    try std.testing.expect(exceedsPercent(1, 0, 15));
    try std.testing.expect(!exceedsPercent(0, 0, 15));
}

test "compareWithBaseline reports regression by label and mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const baseline_json =
        \\{
        \\  "profiles": [
        \\    {
        \\      "source": "old-sync.log",
        \\      "label": "MyService.run",
        \\      "mode": "sync",
        \\      "cpu_ms": 1000,
        \\      "heap_bytes": 2000
        \\    },
        \\    {
        \\      "source": "old-async.log",
        \\      "label": "MyQueue.execute",
        \\      "mode": "async",
        \\      "cpu_ms": 5000,
        \\      "heap_bytes": 7000
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "baseline.json", .data = baseline_json });

    const baseline_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "baseline.json" },
    );
    defer std.testing.allocator.free(baseline_path);

    const current = [_]model.ProfileResult{
        .{
            .source = "sync.log",
            .label = "MyService.run",
            .is_async = false,
            .cpu_ms = 1300,
            .heap_bytes = 2600,
            .cpu_budget = 8000,
            .heap_budget = 5000000,
        },
        .{
            .source = "async.log",
            .label = "MyQueue.execute",
            .is_async = true,
            .cpu_ms = 5200,
            .heap_bytes = 7100,
            .cpu_budget = 50000,
            .heap_budget = 10000000,
        },
    };

    var regressions = try compareWithBaseline(std.testing.allocator, &current, baseline_path, 15);
    defer deinitRegressions(std.testing.allocator, &regressions);

    try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
    try std.testing.expect(std.mem.eql(u8, regressions.items[0].label, "MyService.run"));
    try std.testing.expect(regressions.items[0].cpu_regressed);
    try std.testing.expect(regressions.items[0].heap_regressed);
}

test "compareWithBaseline returns empty when baseline path is null" {
    const current = [_]model.ProfileResult{
        .{
            .source = "sync.log",
            .label = "Example.run",
            .is_async = false,
            .cpu_ms = 1300,
            .heap_bytes = 2600,
            .cpu_budget = 8000,
            .heap_budget = 5000000,
        },
    };

    var regressions = try compareWithBaseline(std.testing.allocator, &current, null, 15);
    defer deinitRegressions(std.testing.allocator, &regressions);
    try std.testing.expectEqual(@as(usize, 0), regressions.items.len);
}

test "compareWithBaseline matches by basename when label is unknown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const baseline_json =
        \\{
        \\  "profiles": [
        \\    {
        \\      "source": "path/to/tx.log",
        \\      "label": "unknown",
        \\      "mode": "sync",
        \\      "cpu_ms": 2000,
        \\      "heap_bytes": 3000
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "baseline.json", .data = baseline_json });

    const baseline_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "baseline.json" },
    );
    defer std.testing.allocator.free(baseline_path);

    const current = [_]model.ProfileResult{
        .{
            .source = "another/path/tx.log",
            .label = "unknown",
            .is_async = false,
            .cpu_ms = 2500,
            .heap_bytes = 3400,
            .cpu_budget = 8000,
            .heap_budget = 5000000,
        },
    };

    var regressions = try compareWithBaseline(std.testing.allocator, &current, baseline_path, 15);
    defer deinitRegressions(std.testing.allocator, &regressions);

    try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
    try std.testing.expect(regressions.items[0].cpu_regressed);
}
