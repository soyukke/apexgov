//! profile — デバッグログパーサー & CPU/Heap プロファイラー。
//!
//! Salesforce のデバッグログを解析し、CPU 時間・Heap 使用量を計測する。
//! マルチトランザクション分割、ベースライン比較によるリグレッション検出に対応。

const std = @import("std");
const Io = std.Io;
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
    transaction_index: u32 = 0,
    mode: []const u8 = "sync",
    cpu_ms: u32 = 0,
    heap_bytes: u64 = 0,
};

const BaselineDocument = struct {
    profiles: []const BaselineProfile = &.{},
};

pub fn run(gpa: std.mem.Allocator, io: Io, inputs: []const []const u8, cfg: config.Config) !std.ArrayList(model.ProfileResult) {
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |path| gpa.free(path);
        files.deinit(gpa);
    }

    for (inputs) |input| {
        try collect_logs(gpa, io, input, &files);
    }

    var results: std.ArrayList(model.ProfileResult) = .empty;
    errdefer model.deinit_profiles(gpa, &results);

    for (files.items) |path| {
        try parse_log_transactions(gpa, io, path, cfg, &results);
    }

    return results;
}

pub fn compare_with_baseline(
    gpa: std.mem.Allocator,
    io: Io,
    current: []const model.ProfileResult,
    baseline_path: ?[]const u8,
    threshold_percent: u8,
) !std.ArrayList(Regression) {
    var regressions: std.ArrayList(Regression) = .empty;
    errdefer deinit_regressions(gpa, &regressions);

    if (baseline_path == null) return regressions;

    const raw = try Io.Dir.cwd().readFileAlloc(io, baseline_path.?, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(raw);

    var parsed = try std.json.parseFromSlice(BaselineDocument, gpa, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    for (current) |curr| {
        const baseline = find_baseline(curr, parsed.value.profiles) orelse continue;

        const cpu_regressed = exceeds_percent(curr.cpu_ms, baseline.cpu_ms, threshold_percent);
        const heap_regressed = exceeds_percent(curr.heap_bytes, baseline.heap_bytes, threshold_percent);
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

pub fn deinit_regressions(gpa: std.mem.Allocator, regressions: *std.ArrayList(Regression)) void {
    for (regressions.items) |regression| {
        gpa.free(regression.source);
        gpa.free(regression.label);
    }
    regressions.deinit(gpa);
}

fn find_baseline(curr: model.ProfileResult, baseline_profiles: []const BaselineProfile) ?BaselineProfile {
    const curr_mode = if (curr.is_async) "async" else "sync";
    const curr_label_known = !is_unknown(curr.label);
    const curr_base = std.fs.path.basename(curr.source);

    for (baseline_profiles) |baseline| {
        if (!std.ascii.eqlIgnoreCase(curr_mode, baseline.mode)) continue;
        if (baseline.transaction_index != 0 and baseline.transaction_index != curr.transaction_index) continue;

        const baseline_label_known = !is_unknown(baseline.label);
        if (curr_label_known and baseline_label_known) {
            if (std.mem.eql(u8, curr.label, baseline.label)) return baseline;
            continue;
        }

        if (std.mem.eql(u8, curr_base, std.fs.path.basename(baseline.source))) return baseline;
    }

    return null;
}

fn is_unknown(label: []const u8) bool {
    return label.len == 0 or std.ascii.eqlIgnoreCase(label, "unknown");
}

fn exceeds_percent(current: u64, baseline: u64, threshold_percent: u8) bool {
    if (baseline == 0) return current > 0;

    const lhs: u128 = @as(u128, current) * 100;
    const rhs: u128 = @as(u128, baseline) * (100 + @as(u128, threshold_percent));
    return lhs > rhs;
}

fn collect_logs(gpa: std.mem.Allocator, io: Io, input: []const u8, files: *std.ArrayList([]const u8)) !void {
    collect_logs_in_directory(gpa, io, input, files) catch |err| switch (err) {
        error.NotDir => {
            try files.append(gpa, try gpa.dupe(u8, input));
        },
        else => return err,
    };
}

fn collect_logs_in_directory(gpa: std.mem.Allocator, io: Io, root: []const u8, files: *std.ArrayList([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!is_log_file(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        errdefer gpa.free(joined);

        try files.append(gpa, joined);
    }
}

const TransactionMetrics = struct {
    label: ?[]const u8 = null,
    cpu_max: u32 = 0,
    heap_max: u64 = 0,
    saw_metric: bool = false,
    is_async: bool = false,
};

fn parse_log_transactions(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    cfg: config.Config,
    results: *std.ArrayList(model.ProfileResult),
) !void {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024));
    defer gpa.free(content);

    var current = TransactionMetrics{};
    var tx_started = false;
    var tx_index: u32 = 0;
    errdefer if (current.label) |value| gpa.free(value);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (is_execution_started_line(line)) {
            if (tx_started) {
                try append_transaction_result(gpa, path, cfg, tx_index, &current, results);
            }
            tx_started = true;
            tx_index = tx_index + 1;
            current = .{};
        } else if (!tx_started and line_marks_transaction_activity(line)) {
            tx_started = true;
            tx_index = 1;
            current = .{};
        }

        if (!tx_started) continue;

        if (current.label == null and std.mem.indexOf(u8, line, "CODE_UNIT_STARTED|") != null) {
            current.label = try parse_code_unit_label(gpa, line);
        }
        if (contains_async_marker(line)) {
            current.is_async = true;
        }

        if (parse_limit_value(line, "Maximum CPU time:")) |value| {
            current.saw_metric = true;
            const parsed: u32 = @intCast(@min(value, std.math.maxInt(u32)));
            if (parsed > current.cpu_max) current.cpu_max = parsed;
        }
        if (parse_limit_value(line, "Maximum heap size:")) |value| {
            current.saw_metric = true;
            if (value > current.heap_max) current.heap_max = value;
        }
    }

    if (tx_started) {
        try append_transaction_result(gpa, path, cfg, tx_index, &current, results);
    }
}

fn append_transaction_result(
    gpa: std.mem.Allocator,
    path: []const u8,
    cfg: config.Config,
    tx_index: u32,
    tx: *TransactionMetrics,
    results: *std.ArrayList(model.ProfileResult),
) !void {
    defer {
        if (tx.label) |value| gpa.free(value);
        tx.* = .{};
    }

    if (!tx.saw_metric) return;

    const label_source = tx.label orelse "unknown";
    const label = try gpa.dupe(u8, label_source);
    errdefer gpa.free(label);

    const budget = if (tx.is_async) cfg.budget_async else cfg.budget_sync;
    try results.append(gpa, .{
        .source = try gpa.dupe(u8, path),
        .label = label,
        .transaction_index = tx_index,
        .is_async = tx.is_async,
        .cpu_ms = tx.cpu_max,
        .heap_bytes = tx.heap_max,
        .cpu_budget = budget.cpu_ms,
        .heap_budget = budget.heap_bytes,
    });
}

fn is_execution_started_line(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "EXECUTION_STARTED") != null;
}

fn line_marks_transaction_activity(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "CODE_UNIT_STARTED|") != null or
        parse_limit_value(line, "Maximum CPU time:") != null or
        parse_limit_value(line, "Maximum heap size:") != null;
}

fn parse_code_unit_label(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, line, '|');
    var last: []const u8 = "";
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len > 0) last = trimmed;
    }

    if (last.len == 0) return gpa.dupe(u8, "unknown");
    return gpa.dupe(u8, last);
}

fn parse_limit_value(line: []const u8, marker: []const u8) ?u64 {
    const marker_idx = std.mem.indexOf(u8, line, marker) orelse return null;
    var i = marker_idx + marker.len;

    while (i < line.len and !std.ascii.isDigit(line[i])) : (i += 1) {}
    const start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}

    if (start == i) return null;
    return std.fmt.parseUnsigned(u64, line[start..i], 10) catch null;
}

fn contains_async_marker(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "FUTURE_HANDLER") != null or
        std.mem.indexOf(u8, line, "QUEUEABLE") != null or
        std.mem.indexOf(u8, line, "BATCH_") != null or
        std.mem.indexOf(u8, line, "SCHEDULED") != null;
}

fn is_log_file(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".log");
}

test "parse_limit_value parses numeric prefix" {
    const line = "MAXIMUM LIMIT_USAGE_FOR_NS|(default)| Maximum CPU time: 1234 out of 10000";
    const parsed = parse_limit_value(line, "Maximum CPU time:") orelse unreachable;
    try std.testing.expectEqual(@as(u64, 1234), parsed);
}

test "exceeds_percent compares with threshold" {
    try std.testing.expect(exceeds_percent(116, 100, 15));
    try std.testing.expect(!exceeds_percent(115, 100, 15));
    try std.testing.expect(exceeds_percent(1, 0, 15));
    try std.testing.expect(!exceeds_percent(0, 0, 15));
}

test "run splits multi-transaction log file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const log =
        \\08:00:00.0 (1)|EXECUTION_STARTED
        \\08:00:00.0 (2)|CODE_UNIT_STARTED|[EXTERNAL]|MyService.run
        \\08:00:00.0 (3)|LIMIT_USAGE_FOR_NS|(default)|
        \\  Number of SOQL queries: 1 out of 100
        \\  Maximum CPU time: 1200 out of 10000
        \\  Maximum heap size: 3500 out of 6000000
        \\08:00:01.0 (4)|EXECUTION_FINISHED
        \\08:05:00.0 (5)|EXECUTION_STARTED
        \\08:05:00.0 (6)|CODE_UNIT_STARTED|[EXTERNAL]|MyQueue.execute
        \\08:05:00.0 (7)|QUEUEABLE
        \\08:05:00.0 (8)|LIMIT_USAGE_FOR_NS|(default)|
        \\  Maximum CPU time: 4200 out of 60000
        \\  Maximum heap size: 9100 out of 12000000
        \\08:05:01.0 (9)|EXECUTION_FINISHED
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "multi.log", .data = log });

    const log_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "multi.log" },
    );
    defer std.testing.allocator.free(log_path);

    const inputs = [_][]const u8{log_path};
    var profiles = try run(std.testing.allocator, std.testing.io, &inputs, config.Config.defaults());
    defer model.deinit_profiles(std.testing.allocator, &profiles);

    try std.testing.expectEqual(@as(usize, 2), profiles.items.len);
    try std.testing.expectEqual(@as(u32, 1), profiles.items[0].transaction_index);
    try std.testing.expectEqual(@as(u32, 2), profiles.items[1].transaction_index);
    try std.testing.expect(std.mem.eql(u8, profiles.items[0].label, "MyService.run"));
    try std.testing.expect(std.mem.eql(u8, profiles.items[1].label, "MyQueue.execute"));
    try std.testing.expectEqual(false, profiles.items[0].is_async);
    try std.testing.expectEqual(true, profiles.items[1].is_async);
    try std.testing.expectEqual(@as(u32, 1200), profiles.items[0].cpu_ms);
    try std.testing.expectEqual(@as(u32, 4200), profiles.items[1].cpu_ms);
}

test "compare_with_baseline reports regression by label and mode" {
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "baseline.json", .data = baseline_json });

    const baseline_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "baseline.json" },
    );
    defer std.testing.allocator.free(baseline_path);

    const current = [_]model.ProfileResult{
        .{
            .source = "sync.log",
            .label = "MyService.run",
            .transaction_index = 1,
            .is_async = false,
            .cpu_ms = 1300,
            .heap_bytes = 2600,
            .cpu_budget = 8000,
            .heap_budget = 5000000,
        },
        .{
            .source = "async.log",
            .label = "MyQueue.execute",
            .transaction_index = 1,
            .is_async = true,
            .cpu_ms = 5200,
            .heap_bytes = 7100,
            .cpu_budget = 50000,
            .heap_budget = 10000000,
        },
    };

    var regressions = try compare_with_baseline(std.testing.allocator, std.testing.io, &current, baseline_path, 15);
    defer deinit_regressions(std.testing.allocator, &regressions);

    try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
    try std.testing.expect(std.mem.eql(u8, regressions.items[0].label, "MyService.run"));
    try std.testing.expect(regressions.items[0].cpu_regressed);
    try std.testing.expect(regressions.items[0].heap_regressed);
}

test "compare_with_baseline can disambiguate by transaction index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const baseline_json =
        \\{
        \\  "profiles": [
        \\    {
        \\      "source": "tx.log",
        \\      "label": "MyService.run",
        \\      "transaction_index": 1,
        \\      "mode": "sync",
        \\      "cpu_ms": 1000,
        \\      "heap_bytes": 2000
        \\    },
        \\    {
        \\      "source": "tx.log",
        \\      "label": "MyService.run",
        \\      "transaction_index": 2,
        \\      "mode": "sync",
        \\      "cpu_ms": 2500,
        \\      "heap_bytes": 4000
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "baseline.json", .data = baseline_json });

    const baseline_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "baseline.json" },
    );
    defer std.testing.allocator.free(baseline_path);

    const current = [_]model.ProfileResult{
        .{
            .source = "tx.log",
            .label = "MyService.run",
            .transaction_index = 2,
            .is_async = false,
            .cpu_ms = 3000,
            .heap_bytes = 4300,
            .cpu_budget = 8000,
            .heap_budget = 5000000,
        },
    };

    var regressions = try compare_with_baseline(std.testing.allocator, std.testing.io, &current, baseline_path, 15);
    defer deinit_regressions(std.testing.allocator, &regressions);

    try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
    try std.testing.expectEqual(@as(u32, 3000), regressions.items[0].cpu_current);
    try std.testing.expectEqual(@as(u32, 2500), regressions.items[0].cpu_baseline);
}

test "compare_with_baseline returns empty when baseline path is null" {
    const current = [_]model.ProfileResult{
        .{
            .source = "sync.log",
            .label = "Example.run",
            .transaction_index = 1,
            .is_async = false,
            .cpu_ms = 1300,
            .heap_bytes = 2600,
            .cpu_budget = 8000,
            .heap_budget = 5000000,
        },
    };

    var regressions = try compare_with_baseline(std.testing.allocator, std.testing.io, &current, null, 15);
    defer deinit_regressions(std.testing.allocator, &regressions);

    try std.testing.expectEqual(@as(usize, 0), regressions.items.len);
}

test "compare_with_baseline matches by basename when label is unknown" {
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "baseline.json", .data = baseline_json });

    const baseline_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "baseline.json" },
    );
    defer std.testing.allocator.free(baseline_path);

    const current = [_]model.ProfileResult{
        .{
            .source = "another/path/tx.log",
            .label = "unknown",
            .transaction_index = 1,
            .is_async = false,
            .cpu_ms = 2500,
            .heap_bytes = 3400,
            .cpu_budget = 8000,
            .heap_budget = 5000000,
        },
    };

    var regressions = try compare_with_baseline(std.testing.allocator, std.testing.io, &current, baseline_path, 15);
    defer deinit_regressions(std.testing.allocator, &regressions);

    try std.testing.expectEqual(@as(usize, 1), regressions.items.len);
    try std.testing.expect(regressions.items[0].cpu_regressed);
}
