const std = @import("std");

pub const Budget = struct {
    cpu_ms: u32,
    heap_bytes: u64,
};

pub const Ci = struct {
    fail_on_regression: bool,
    regression_percent: u8,
};

pub const Config = struct {
    budget_sync: Budget,
    budget_async: Budget,
    ci: Ci,

    pub fn defaults() Config {
        return .{
            .budget_sync = .{
                .cpu_ms = 8_000,
                .heap_bytes = 5_000_000,
            },
            .budget_async = .{
                .cpu_ms = 50_000,
                .heap_bytes = 10_000_000,
            },
            .ci = .{
                .fail_on_regression = true,
                .regression_percent = 15,
            },
        };
    }
};

const Section = enum {
    none,
    budget_sync,
    budget_async,
    ci,
};

pub fn load(gpa: std.mem.Allocator, path: ?[]const u8) !Config {
    if (path == null) return Config.defaults();

    const content = try std.fs.cwd().readFileAlloc(gpa, path.?, 1024 * 1024);
    defer gpa.free(content);

    return parse(content);
}

pub fn parse(raw: []const u8) !Config {
    var cfg = Config.defaults();
    var section: Section = .none;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const no_comment = stripInlineComment(raw_line);
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = line[1 .. line.len - 1];
            if (std.ascii.eqlIgnoreCase(name, "budget.sync")) {
                section = .budget_sync;
            } else if (std.ascii.eqlIgnoreCase(name, "budget.async")) {
                section = .budget_async;
            } else if (std.ascii.eqlIgnoreCase(name, "ci")) {
                section = .ci;
            } else {
                section = .none;
            }
            continue;
        }

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t\r");
        var value = std.mem.trim(u8, line[(eq_idx + 1)..], " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        switch (section) {
            .budget_sync => {
                if (std.ascii.eqlIgnoreCase(key, "cpu_ms")) {
                    cfg.budget_sync.cpu_ms = try parseUnsigned(u32, value);
                } else if (std.ascii.eqlIgnoreCase(key, "heap_bytes")) {
                    cfg.budget_sync.heap_bytes = try parseUnsigned(u64, value);
                }
            },
            .budget_async => {
                if (std.ascii.eqlIgnoreCase(key, "cpu_ms")) {
                    cfg.budget_async.cpu_ms = try parseUnsigned(u32, value);
                } else if (std.ascii.eqlIgnoreCase(key, "heap_bytes")) {
                    cfg.budget_async.heap_bytes = try parseUnsigned(u64, value);
                }
            },
            .ci => {
                if (std.ascii.eqlIgnoreCase(key, "fail_on_regression")) {
                    cfg.ci.fail_on_regression = try parseBool(value);
                } else if (std.ascii.eqlIgnoreCase(key, "regression_percent")) {
                    cfg.ci.regression_percent = try parseUnsigned(u8, value);
                }
            },
            .none => {},
        }
    }

    return cfg;
}

fn stripInlineComment(raw: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, raw, '#') orelse return raw;
    return raw[0..idx];
}

fn parseBool(raw: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return error.InvalidBoolean;
}

fn parseUnsigned(comptime T: type, raw: []const u8) !T {
    return std.fmt.parseUnsigned(T, raw, 10);
}

test "parse config subset" {
    const text =
        \\[budget.sync]
        \\cpu_ms = 9000
        \\heap_bytes = 6000000
        \\
        \\[budget.async]
        \\cpu_ms = 45000
        \\heap_bytes = 12000000
        \\
        \\[ci]
        \\fail_on_regression = false
        \\regression_percent = 25
        \\
    ;

    const cfg = try parse(text);
    try std.testing.expectEqual(@as(u32, 9000), cfg.budget_sync.cpu_ms);
    try std.testing.expectEqual(@as(u64, 6000000), cfg.budget_sync.heap_bytes);
    try std.testing.expectEqual(@as(u32, 45000), cfg.budget_async.cpu_ms);
    try std.testing.expectEqual(@as(u64, 12000000), cfg.budget_async.heap_bytes);
    try std.testing.expect(!cfg.ci.fail_on_regression);
    try std.testing.expectEqual(@as(u8, 25), cfg.ci.regression_percent);
}
