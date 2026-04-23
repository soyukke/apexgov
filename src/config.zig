//! config — `apexgov.toml` 設定ファイルのパーサー。
//!
//! CPU/Heap バジェット上限、各操作のコスト係数 (`cpu.model`)、
//! CI リグレッション閾値などの設定を手書き TOML パーサーで読み込む。

const std = @import("std");
const Io = std.Io;

pub const Budget = struct {
    cpu_ms: u32,
    heap_bytes: u64,
};

pub const CpuModel = struct {
    base_ms: u64,
    soql_ms: u64,
    dml_ms: u64,
    json_ms: u64,
    clone_ms: u64,
};

pub const Ci = struct {
    fail_on_regression: bool,
    regression_percent: u8,
};

pub const Config = struct {
    budget_sync: Budget,
    budget_async: Budget,
    cpu_model: CpuModel,
    ci: Ci,
    include_tests: bool = false,

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
            .cpu_model = .{
                .base_ms = 500,
                .soql_ms = 35,
                .dml_ms = 25,
                .json_ms = 8,
                .clone_ms = 4,
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
    cpu_model,
    ci,
};

pub fn load(gpa: std.mem.Allocator, io: Io, path: ?[]const u8) !Config {
    if (path == null) return Config.defaults();

    const content = try Io.Dir.cwd().readFileAlloc(io, path.?, gpa, .limited(1024 * 1024));
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
            } else if (std.ascii.eqlIgnoreCase(name, "cpu.model")) {
                section = .cpu_model;
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
            .cpu_model => {
                if (std.ascii.eqlIgnoreCase(key, "base_ms")) {
                    cfg.cpu_model.base_ms = try parseUnsigned(u64, value);
                } else if (std.ascii.eqlIgnoreCase(key, "soql_ms")) {
                    cfg.cpu_model.soql_ms = try parseUnsigned(u64, value);
                } else if (std.ascii.eqlIgnoreCase(key, "dml_ms")) {
                    cfg.cpu_model.dml_ms = try parseUnsigned(u64, value);
                } else if (std.ascii.eqlIgnoreCase(key, "json_ms")) {
                    cfg.cpu_model.json_ms = try parseUnsigned(u64, value);
                } else if (std.ascii.eqlIgnoreCase(key, "clone_ms")) {
                    cfg.cpu_model.clone_ms = try parseUnsigned(u64, value);
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
        \\[cpu.model]
        \\base_ms = 600
        \\soql_ms = 40
        \\dml_ms = 30
        \\json_ms = 10
        \\clone_ms = 5
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
    try std.testing.expectEqual(@as(u64, 600), cfg.cpu_model.base_ms);
    try std.testing.expectEqual(@as(u64, 40), cfg.cpu_model.soql_ms);
    try std.testing.expectEqual(@as(u64, 30), cfg.cpu_model.dml_ms);
    try std.testing.expectEqual(@as(u64, 10), cfg.cpu_model.json_ms);
    try std.testing.expectEqual(@as(u64, 5), cfg.cpu_model.clone_ms);
    try std.testing.expect(!cfg.ci.fail_on_regression);
    try std.testing.expectEqual(@as(u8, 25), cfg.ci.regression_percent);
}
