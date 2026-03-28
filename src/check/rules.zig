const std = @import("std");
const model = @import("../model.zig");
const utils = @import("utils.zig");

const satMul = utils.satMul;
const satAdd = utils.satAdd;

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

pub fn appendCpuEstimateFinding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    operation_label: []const u8,
    per_iter_ms: u64,
    loop_upper_bound: ?u64,
    base_cost_ms: u64,
) !void {
    const n_limit = computeCpuLimitN(base_cost_ms, per_iter_ms);

    var message_buffer: [420]u8 = undefined;
    var severity: model.Severity = .info;
    const message = if (loop_upper_bound) |upper| blk: {
        const total = estimateCpuTotalMs(base_cost_ms, upper, per_iter_ms) orelse std.math.maxInt(u64);
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

    try appendFinding(
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

pub fn computeCpuLimitN(base_cost_ms: u64, per_iter_ms: u64) u64 {
    if (per_iter_ms == 0) return std.math.maxInt(u64);
    if (sync_cpu_budget_ms <= base_cost_ms) return 0;
    return (sync_cpu_budget_ms - base_cost_ms) / per_iter_ms;
}

pub fn estimateCpuTotalMs(base_cost_ms: u64, n: u64, per_iter_ms: u64) ?u64 {
    if (per_iter_ms == 0) return base_cost_ms;
    const mul = std.math.mul(u64, n, per_iter_ms) catch return null;
    return std.math.add(u64, base_cost_ms, mul) catch return null;
}

pub fn appendGovernorFinding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    kind: GovernorKind,
    loop_upper_bound: ?u64,
    operations_per_iteration: u64,
) !void {
    const rule_id = switch (kind) {
        .soql => "AG002",
        .dml => "AG003",
        .sosl => "AG008",
        .callout => "AG010",
        .messaging => "AG011",
    };
    const title = switch (kind) {
        .soql => "SOQL executed inside loop",
        .dml => "DML executed inside loop",
        .sosl => "SOSL executed inside loop",
        .callout => "Callout executed inside loop",
        .messaging => "Messaging.sendEmail executed inside loop",
    };
    const limit = switch (kind) {
        .soql => soql_limit,
        .dml => dml_limit,
        .sosl => sosl_limit,
        .callout => callout_limit,
        .messaging => messaging_send_limit,
    };
    const op_label = switch (kind) {
        .soql => "SOQL",
        .dml => "DML",
        .sosl => "SOSL",
        .callout => "Callout",
        .messaging => "Messaging send",
    };
    const category = switch (kind) {
        .callout => "integration",
        .messaging => "messaging",
        else => "governor",
    };

    const per_iter = if (operations_per_iteration == 0) @as(u64, 1) else operations_per_iteration;
    var message_buffer: [520]u8 = undefined;
    var severity: model.Severity = .warning;

    const message = if (loop_upper_bound) |upper| blk: {
        const estimated_total = satMul(upper, per_iter);
        if (estimated_total > limit) {
            severity = .err;
            break :blk try std.fmt.bufPrint(
                &message_buffer,
                "Loop upper bound <= {d}. {s} in loop may run up to {d} times ({d} per iteration) and exceed the transaction limit ({d}).",
                .{ upper, op_label, estimated_total, per_iter, limit },
            );
        }
        if (per_iter > 1) {
            break :blk try std.fmt.bufPrint(
                &message_buffer,
                "Loop upper bound <= {d}. {s} in loop may run up to {d} times ({d} per iteration), below transaction limit ({d}) for now but fragile under growth.",
                .{ upper, op_label, estimated_total, per_iter, limit },
            );
        }
        break :blk try std.fmt.bufPrint(
            &message_buffer,
            "Loop upper bound <= {d}. {s} in loop is below the transaction limit ({d}) now, but remains fragile under future growth.",
            .{ upper, op_label, limit },
        );
    } else blk: {
        break :blk try std.fmt.bufPrint(
            &message_buffer,
            "Loop upper bound is dynamic/unknown. {s} in loop cannot be proven safe (estimated {d} per iteration). Add explicit cap checks (for example if (n > {d}) return).",
            .{ op_label, per_iter, limit },
        );
    };

    try appendFinding(
        gpa,
        findings,
        path,
        line_no,
        rule_id,
        title,
        message,
        severity,
        category,
    );
}

pub fn appendFinding(
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
