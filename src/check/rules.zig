//! rules — Governor 制限ルールの定数と Finding 生成。
//!
//! SOQL (100), DML (150), SOSL (20), Callout (100) 等の Governor 制限値を
//! 定義し、検出された違反パターンから `Finding` を組み立てて結果リストに追加する。
//! AG009 (CPU 見積もり) の推定ロジックもここに含まれる。

const std = @import("std");
const model = @import("../model.zig");
const utils = @import("utils.zig");

const sat_mul = utils.sat_mul;

pub const soql_limit: u64 = 100;
pub const dml_limit: u64 = 150;
pub const sosl_limit: u64 = 20;
pub const callout_limit: u64 = 100;
pub const messaging_send_limit: u64 = 10;
pub const sync_cpu_budget_ms: u64 = 10_000;

pub const GovernorKind = enum {
    soql,
    dml,
    sosl,
    callout,
    messaging,
};

pub fn append_cpu_estimate_finding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    operation_label: []const u8,
    per_iter_ms: u64,
    loop_upper_bound: ?u64,
    base_cost_ms: u64,
) !void {
    const n_limit = compute_cpu_limit_n(base_cost_ms, per_iter_ms);

    var message_buffer: [420]u8 = undefined;
    var severity: model.Severity = .info;
    const message = if (loop_upper_bound) |upper| blk: {
        const total = estimate_cpu_total_ms(base_cost_ms, upper, per_iter_ms) orelse std.math.maxInt(u64);
        if (total > sync_cpu_budget_ms) {
            severity = .err;
            break :blk try std.fmt.bufPrint(
                &message_buffer,
                "CPU estimate (heuristic): {d} + {d}*{d} ~= {d}ms. This likely exceeds sync CPU limit ({d}ms).",
                .{ base_cost_ms, upper, per_iter_ms, total, sync_cpu_budget_ms },
            );
        }
        const warn_threshold = (sync_cpu_budget_ms * 8) / 10;
        if (total >= warn_threshold) {
            severity = .warning;
        }
        break :blk try std.fmt.bufPrint(
            &message_buffer,
            "CPU estimate (heuristic): {d} + {d}*{d} ~= {d}ms. Limit risk starts around N>{d} (sync {d}ms).",
            .{ base_cost_ms, upper, per_iter_ms, total, n_limit, sync_cpu_budget_ms },
        );
    } else blk: {
        break :blk try std.fmt.bufPrint(
            &message_buffer,
            "CPU estimate (heuristic): {d} + N*{d}. Without loop bound N, safety is unknown. Limit risk starts around N>{d} (sync {d}ms).",
            .{ base_cost_ms, per_iter_ms, n_limit, sync_cpu_budget_ms },
        );
    };

    var title_buffer: [120]u8 = undefined;
    const title = try std.fmt.bufPrint(
        &title_buffer,
        "Estimated CPU for {s} in loop",
        .{operation_label},
    );

    try append_finding(
        gpa,
        findings,
        path,
        line_no,
        "AG009",
        title,
        message,
        severity,
        "cpu",
    );
}

pub fn compute_cpu_limit_n(base_cost_ms: u64, per_iter_ms: u64) u64 {
    if (per_iter_ms == 0) return std.math.maxInt(u64);
    if (sync_cpu_budget_ms <= base_cost_ms) return 0;
    return (sync_cpu_budget_ms - base_cost_ms) / per_iter_ms;
}

pub fn estimate_cpu_total_ms(base_cost_ms: u64, n: u64, per_iter_ms: u64) ?u64 {
    if (per_iter_ms == 0) return base_cost_ms;
    const mul = std.math.mul(u64, n, per_iter_ms) catch return null;
    return std.math.add(u64, base_cost_ms, mul) catch return null;
}

const GovernorMeta = struct {
    rule_id: []const u8,
    title: []const u8,
    op_label: []const u8,
    category: []const u8,
    limit: u64,
};

fn meta_for(kind: GovernorKind) GovernorMeta {
    return switch (kind) {
        .soql => .{ .rule_id = "AG002", .title = "SOQL executed inside loop", .op_label = "SOQL", .category = "governor", .limit = soql_limit },
        .dml => .{ .rule_id = "AG003", .title = "DML executed inside loop", .op_label = "DML", .category = "governor", .limit = dml_limit },
        .sosl => .{ .rule_id = "AG008", .title = "SOSL executed inside loop", .op_label = "SOSL", .category = "governor", .limit = sosl_limit },
        .callout => .{ .rule_id = "AG010", .title = "Callout executed inside loop", .op_label = "Callout", .category = "integration", .limit = callout_limit },
        .messaging => .{ .rule_id = "AG011", .title = "Messaging.sendEmail executed inside loop", .op_label = "Messaging send", .category = "messaging", .limit = messaging_send_limit },
    };
}

fn format_governor_message(
    buffer: []u8,
    meta: GovernorMeta,
    loop_upper_bound: ?u64,
    per_iter: u64,
    severity: *model.Severity,
) ![]u8 {
    if (loop_upper_bound) |upper| {
        const estimated_total = sat_mul(upper, per_iter);
        if (estimated_total > meta.limit) {
            severity.* = .err;
            return try std.fmt.bufPrint(
                buffer,
                "Loop upper bound <= {d}. {s} in loop may run up to {d} times ({d} per iteration) and exceed the transaction limit ({d}).",
                .{ upper, meta.op_label, estimated_total, per_iter, meta.limit },
            );
        }
        if (per_iter > 1) {
            return try std.fmt.bufPrint(
                buffer,
                "Loop upper bound <= {d}. {s} in loop may run up to {d} times ({d} per iteration), below transaction limit ({d}) for now but fragile under growth.",
                .{ upper, meta.op_label, estimated_total, per_iter, meta.limit },
            );
        }
        return try std.fmt.bufPrint(
            buffer,
            "Loop upper bound <= {d}. {s} in loop is below the transaction limit ({d}) now, but remains fragile under future growth.",
            .{ upper, meta.op_label, meta.limit },
        );
    }
    return try std.fmt.bufPrint(
        buffer,
        "Loop upper bound is dynamic/unknown. {s} in loop cannot be proven safe (estimated {d} per iteration). Add explicit cap checks (for example if (n > {d}) return).",
        .{ meta.op_label, per_iter, meta.limit },
    );
}

pub fn append_governor_finding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    kind: GovernorKind,
    loop_upper_bound: ?u64,
    operations_per_iteration: u64,
) !void {
    const meta = meta_for(kind);
    const per_iter = if (operations_per_iteration == 0) @as(u64, 1) else operations_per_iteration;
    var message_buffer: [520]u8 = undefined;
    var severity: model.Severity = .warning;
    const message = try format_governor_message(&message_buffer, meta, loop_upper_bound, per_iter, &severity);

    try append_finding(
        gpa,
        findings,
        path,
        line_no,
        meta.rule_id,
        meta.title,
        message,
        severity,
        meta.category,
    );
}

pub fn append_finding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    rule_id: []const u8,
    title: []const u8,
    message: []const u8,
    severity: model.Severity,
    category: []const u8,
) !void {
    try findings.append(gpa, .{
        .rule_id = rule_id,
        .title = try gpa.dupe(u8, title),
        .message = try gpa.dupe(u8, message),
        .severity = severity,
        .category = category,
        .file = try gpa.dupe(u8, path),
        .line = line_no,
    });
}
