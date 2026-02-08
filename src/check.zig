const std = @import("std");
const model = @import("model.zig");
const config = @import("config.zig");

const soql_limit: u64 = 100;
const dml_limit: u64 = 150;
const trigger_batch_limit: u64 = 200;
const sync_cpu_budget_ms: u64 = 10_000;

const BoundOrigin = enum {
    unknown,
    literal,
    guard,
    query_limit,
    alias,
    trigger_batch,
};

const Bound = struct {
    max: ?u64,
    origin: BoundOrigin,
};

const LoopScope = struct {
    end_depth: i32,
    max_iterations: ?u64,
};

const LoopInfo = struct {
    max_iterations: ?u64,
};

const BoundUpdate = struct {
    name: []const u8,
    max: ?u64,
    origin: BoundOrigin,
};

const MethodMetrics = struct {
    soql: u64 = 0,
    dml: u64 = 0,
    json: u64 = 0,
    clone: u64 = 0,
    collection_alloc: u64 = 0,
    string_append: u64 = 0,

    fn add(self: *MethodMetrics, other: MethodMetrics) void {
        self.soql = satAdd(self.soql, other.soql);
        self.dml = satAdd(self.dml, other.dml);
        self.json = satAdd(self.json, other.json);
        self.clone = satAdd(self.clone, other.clone);
        self.collection_alloc = satAdd(self.collection_alloc, other.collection_alloc);
        self.string_append = satAdd(self.string_append, other.string_append);
    }
};

const ResolveState = enum {
    unresolved,
    resolving,
    resolved,
};

const MethodSummary = struct {
    direct: MethodMetrics = .{},
    total: MethodMetrics = .{},
    calls: std.ArrayListUnmanaged([]const u8) = .{},
    state: ResolveState = .unresolved,
};

const MethodScope = struct {
    name: []const u8,
    end_depth: i32,
};

pub fn run(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(model.Finding) {
    return runWithConfig(gpa, roots, config.Config.defaults());
}

pub fn runWithConfig(gpa: std.mem.Allocator, roots: []const []const u8, cfg: config.Config) !std.ArrayList(model.Finding) {
    var findings: std.ArrayList(model.Finding) = .empty;
    errdefer model.deinitFindings(gpa, &findings);

    for (roots) |root| {
        try scanPath(gpa, root, cfg, &findings);
    }

    return findings;
}

fn scanPath(gpa: std.mem.Allocator, path: []const u8, cfg: config.Config, findings: *std.ArrayList(model.Finding)) !void {
    scanDirectory(gpa, path, cfg, findings) catch |err| switch (err) {
        error.NotDir => {
            if (isApexSource(path)) {
                try scanFile(gpa, path, cfg, findings);
            }
        },
        else => return err,
    };
}

fn scanDirectory(gpa: std.mem.Allocator, root: []const u8, cfg: config.Config, findings: *std.ArrayList(model.Finding)) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isApexSource(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        defer gpa.free(joined);

        try scanFile(gpa, joined, cfg, findings);
    }
}

fn scanFile(gpa: std.mem.Allocator, path: []const u8, cfg: config.Config, findings: *std.ArrayList(model.Finding)) !void {
    const content = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    defer gpa.free(content);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var bounds = std.StringHashMap(Bound).init(arena_allocator);
    var method_summaries = try buildMethodSummaries(arena_allocator, content);

    var loop_scopes: std.ArrayList(LoopScope) = .empty;
    defer loop_scopes.deinit(gpa);

    var brace_depth: i32 = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw| {
        line_no += 1;

        popClosedScopes(&loop_scopes, brace_depth);

        const code_line = stripLineComment(raw);
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        if (trimmed.len == 0) {
            brace_depth = updateBraceDepth(brace_depth, code_line);
            popClosedScopes(&loop_scopes, brace_depth);
            continue;
        }

        try applyBoundUpdates(arena_allocator, &bounds, trimmed);

        const loop_info = if (isLoopStart(trimmed)) inferLoopInfo(trimmed, &bounds) else null;
        const loop_started = loop_info != null;
        const loop_level = loop_scopes.items.len;
        const in_loop = loop_started or loop_level > 0;
        const loop_upper_bound = effectiveLoopUpperBound(loop_scopes.items, loop_info);
        const call_metrics = if (in_loop)
            inferCalledMethodMetrics(trimmed, &method_summaries)
        else
            MethodMetrics{};

        if (loop_started and loop_level > 0) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG001",
                "Nested loop can burn CPU quickly",
                "Nested loops often amplify CPU usage and governor risk.",
                .warning,
                "cpu",
            );
        }

        const soql_count = satAdd(
            if (containsSoql(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.soql,
        );
        if (in_loop and soql_count > 0) {
            try appendGovernorFinding(
                gpa,
                findings,
                path,
                line_no,
                .soql,
                loop_upper_bound,
            );
            try appendCpuEstimateFinding(
                gpa,
                findings,
                path,
                line_no,
                "SOQL",
                satMul(cfg.cpu_model.soql_ms, soql_count),
                loop_upper_bound,
                cfg.cpu_model.base_ms,
            );
        }

        const dml_count = satAdd(
            if (containsDml(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.dml,
        );
        if (in_loop and dml_count > 0) {
            try appendGovernorFinding(
                gpa,
                findings,
                path,
                line_no,
                .dml,
                loop_upper_bound,
            );
            try appendCpuEstimateFinding(
                gpa,
                findings,
                path,
                line_no,
                "DML",
                satMul(cfg.cpu_model.dml_ms, dml_count),
                loop_upper_bound,
                cfg.cpu_model.base_ms,
            );
        }

        const json_count = satAdd(
            if (containsJsonWork(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.json,
        );
        if (in_loop and json_count > 0) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG004",
                "JSON processing inside loop",
                "Serialize/deserialize outside loops where possible.",
                .warning,
                "cpu",
            );
            try appendCpuEstimateFinding(
                gpa,
                findings,
                path,
                line_no,
                "JSON",
                satMul(cfg.cpu_model.json_ms, json_count),
                loop_upper_bound,
                cfg.cpu_model.base_ms,
            );
        }

        const clone_count = satAdd(
            if (containsCloneWork(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.clone,
        );
        if (in_loop and clone_count > 0) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG005",
                "Clone/deepClone inside loop",
                "Repeated cloning can increase heap and CPU cost.",
                .warning,
                "heap",
            );
            try appendCpuEstimateFinding(
                gpa,
                findings,
                path,
                line_no,
                "clone/deepClone",
                satMul(cfg.cpu_model.clone_ms, clone_count),
                loop_upper_bound,
                cfg.cpu_model.base_ms,
            );
        }

        const collection_alloc_count = satAdd(
            if (containsCollectionAlloc(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.collection_alloc,
        );
        if (in_loop and collection_alloc_count > 0) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG006",
                "Collection allocation inside loop",
                "Reuse collections or move allocation outside the loop.",
                .warning,
                "heap",
            );
        }

        const string_append_count = satAdd(
            if (containsStringAppend(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.string_append,
        );
        if (in_loop and string_append_count > 0) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG007",
                "String concatenation inside loop",
                "Prefer StringBuilder-style batching patterns to reduce CPU.",
                .info,
                "cpu",
            );
        }

        if (loop_started and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            try loop_scopes.append(gpa, .{
                .end_depth = brace_depth + 1,
                .max_iterations = loop_info.?.max_iterations,
            });
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        popClosedScopes(&loop_scopes, brace_depth);
    }
}

fn buildMethodSummaries(arena_allocator: std.mem.Allocator, content: []const u8) !std.StringHashMap(MethodSummary) {
    var summaries = std.StringHashMap(MethodSummary).init(arena_allocator);

    try collectMethodNames(arena_allocator, content, &summaries);
    try collectMethodDirectMetricsAndCalls(arena_allocator, content, &summaries);

    var keys: std.ArrayList([]const u8) = .empty;
    var it = summaries.iterator();
    while (it.next()) |entry| {
        try keys.append(arena_allocator, entry.key_ptr.*);
    }
    for (keys.items) |name| {
        _ = resolveMethodTotal(&summaries, name);
    }

    return summaries;
}

fn collectMethodNames(
    arena_allocator: std.mem.Allocator,
    content: []const u8,
    summaries: *std.StringHashMap(MethodSummary),
) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const code_line = stripLineComment(raw);
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        if (trimmed.len == 0) continue;
        const name = parseMethodStart(trimmed) orelse continue;
        _ = try ensureMethodSummary(arena_allocator, summaries, name);
    }
}

fn collectMethodDirectMetricsAndCalls(
    arena_allocator: std.mem.Allocator,
    content: []const u8,
    summaries: *std.StringHashMap(MethodSummary),
) !void {
    var brace_depth: i32 = 0;
    var current_method: ?MethodScope = null;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw| {
        const code_line = stripLineComment(raw);
        const trimmed = std.mem.trim(u8, code_line, " \t\r");

        var started_method = false;
        if (current_method == null and trimmed.len > 0) {
            if (parseMethodStart(trimmed)) |name| {
                if (summaries.getPtr(name) != null) {
                    current_method = .{
                        .name = name,
                        .end_depth = brace_depth + 1,
                    };
                    started_method = true;
                }
            }
        }

        if (!started_method) {
            if (current_method) |scope| {
                if (trimmed.len > 0) {
                    const summary = summaries.getPtr(scope.name) orelse unreachable;
                    applyDirectLineMetrics(&summary.direct, trimmed);
                    try recordCalledMethods(arena_allocator, &summary.calls, summaries, scope.name, trimmed);
                }
            }
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        if (current_method) |scope| {
            if (brace_depth < scope.end_depth) {
                current_method = null;
            }
        }
    }
}

fn ensureMethodSummary(
    arena_allocator: std.mem.Allocator,
    summaries: *std.StringHashMap(MethodSummary),
    name: []const u8,
) !*MethodSummary {
    if (summaries.getPtr(name)) |existing| return existing;
    const key = try arena_allocator.dupe(u8, name);
    try summaries.put(key, .{});
    return summaries.getPtr(key).?;
}

fn resolveMethodTotal(summaries: *std.StringHashMap(MethodSummary), name: []const u8) MethodMetrics {
    const summary = summaries.getPtr(name) orelse return .{};
    switch (summary.state) {
        .resolved => return summary.total,
        .resolving => return summary.direct,
        .unresolved => {},
    }

    summary.state = .resolving;
    var total = summary.direct;
    for (summary.calls.items) |callee| {
        const callee_total = resolveMethodTotal(summaries, callee);
        total.add(callee_total);
    }
    summary.total = total;
    summary.state = .resolved;
    return total;
}

fn parseMethodStart(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '(') == null) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return null;
    if (std.mem.indexOf(u8, trimmed, " class ") != null or
        std.mem.startsWith(u8, trimmed, "class "))
    {
        return null;
    }
    if (std.mem.startsWith(u8, trimmed, "if(") or
        std.mem.startsWith(u8, trimmed, "if ") or
        std.mem.startsWith(u8, trimmed, "for(") or
        std.mem.startsWith(u8, trimmed, "for ") or
        std.mem.startsWith(u8, trimmed, "while(") or
        std.mem.startsWith(u8, trimmed, "while ") or
        std.mem.startsWith(u8, trimmed, "switch(") or
        std.mem.startsWith(u8, trimmed, "switch ") or
        std.mem.startsWith(u8, trimmed, "catch(") or
        std.mem.startsWith(u8, trimmed, "catch ") or
        std.mem.startsWith(u8, trimmed, "else"))
    {
        return null;
    }

    const open_idx = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const left = std.mem.trim(u8, trimmed[0..open_idx], " \t");
    const name = extractLastIdentifier(left) orelse return null;
    if (isControlKeyword(name)) return null;
    return name;
}

fn isControlKeyword(word: []const u8) bool {
    return std.mem.eql(u8, word, "if") or
        std.mem.eql(u8, word, "for") or
        std.mem.eql(u8, word, "while") or
        std.mem.eql(u8, word, "switch") or
        std.mem.eql(u8, word, "catch") or
        std.mem.eql(u8, word, "return") or
        std.mem.eql(u8, word, "new");
}

fn applyDirectLineMetrics(metrics: *MethodMetrics, line: []const u8) void {
    if (containsSoql(line)) metrics.soql = satAdd(metrics.soql, 1);
    if (containsDml(line)) metrics.dml = satAdd(metrics.dml, 1);
    if (containsJsonWork(line)) metrics.json = satAdd(metrics.json, 1);
    if (containsCloneWork(line)) metrics.clone = satAdd(metrics.clone, 1);
    if (containsCollectionAlloc(line)) metrics.collection_alloc = satAdd(metrics.collection_alloc, 1);
    if (containsStringAppend(line)) metrics.string_append = satAdd(metrics.string_append, 1);
}

fn recordCalledMethods(
    arena_allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged([]const u8),
    summaries: *std.StringHashMap(MethodSummary),
    caller_name: []const u8,
    line: []const u8,
) !void {
    var it = summaries.iterator();
    while (it.next()) |entry| {
        const callee = entry.key_ptr.*;
        if (std.mem.eql(u8, callee, caller_name)) continue;
        if (!containsMethodCall(line, callee)) continue;
        try appendUniqueCall(arena_allocator, calls, callee);
    }
}

fn appendUniqueCall(
    arena_allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged([]const u8),
    callee: []const u8,
) !void {
    for (calls.items) |existing| {
        if (std.mem.eql(u8, existing, callee)) return;
    }
    const name = try arena_allocator.dupe(u8, callee);
    try calls.append(arena_allocator, name);
}

fn inferCalledMethodMetrics(line: []const u8, summaries: *std.StringHashMap(MethodSummary)) MethodMetrics {
    var metrics: MethodMetrics = .{};
    var it = summaries.iterator();
    while (it.next()) |entry| {
        const method_name = entry.key_ptr.*;
        if (!containsMethodCall(line, method_name)) continue;
        metrics.add(entry.value_ptr.total);
    }
    return metrics;
}

fn containsMethodCall(line: []const u8, method_name: []const u8) bool {
    if (method_name.len == 0) return false;

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, method_name)) |idx| {
        const before_ok = idx == 0 or !isIdentChar(line[idx - 1]);
        var end = idx + method_name.len;
        while (end < line.len and (line[end] == ' ' or line[end] == '\t')) : (end += 1) {}
        const after_ok = end < line.len and line[end] == '(';
        if (before_ok and after_ok) return true;
        start = idx + method_name.len;
    }
    return false;
}

fn satAdd(a: u64, b: u64) u64 {
    return std.math.add(u64, a, b) catch std.math.maxInt(u64);
}

fn satMul(a: u64, b: u64) u64 {
    return std.math.mul(u64, a, b) catch std.math.maxInt(u64);
}

fn appendCpuEstimateFinding(
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

fn computeCpuLimitN(base_cost_ms: u64, per_iter_ms: u64) u64 {
    if (per_iter_ms == 0) return std.math.maxInt(u64);
    if (sync_cpu_budget_ms <= base_cost_ms) return 0;
    return (sync_cpu_budget_ms - base_cost_ms) / per_iter_ms;
}

fn estimateCpuTotalMs(base_cost_ms: u64, n: u64, per_iter_ms: u64) ?u64 {
    if (per_iter_ms == 0) return base_cost_ms;
    const mul = std.math.mul(u64, n, per_iter_ms) catch return null;
    return std.math.add(u64, base_cost_ms, mul) catch return null;
}

const GovernorKind = enum {
    soql,
    dml,
};

fn appendGovernorFinding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    kind: GovernorKind,
    loop_upper_bound: ?u64,
) !void {
    const rule_id = switch (kind) {
        .soql => "AG002",
        .dml => "AG003",
    };
    const title = switch (kind) {
        .soql => "SOQL executed inside loop",
        .dml => "DML executed inside loop",
    };
    const limit = switch (kind) {
        .soql => soql_limit,
        .dml => dml_limit,
    };
    const op_label = switch (kind) {
        .soql => "SOQL",
        .dml => "DML",
    };

    var message_buffer: [400]u8 = undefined;
    var severity: model.Severity = .warning;

    const message = if (loop_upper_bound) |upper| blk: {
        if (upper > limit) {
            severity = .err;
            break :blk try std.fmt.bufPrint(
                &message_buffer,
                "Loop upper bound <= {d}. {s} in loop may run up to {d} times and exceed the transaction limit ({d}).",
                .{ upper, op_label, upper, limit },
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
            "Loop upper bound is dynamic/unknown. {s} in loop cannot be proven safe. Add explicit cap checks (for example if (n > {d}) return).",
            .{ op_label, limit },
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
        "governor",
    );
}

fn appendFinding(
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

fn popClosedScopes(scopes: *std.ArrayList(LoopScope), brace_depth: i32) void {
    while (scopes.items.len > 0 and scopes.items[scopes.items.len - 1].end_depth > brace_depth) {
        _ = scopes.pop();
    }
}

fn effectiveLoopUpperBound(scopes: []const LoopScope, current_loop: ?LoopInfo) ?u64 {
    var product: u128 = 1;
    for (scopes) |scope| {
        const max = scope.max_iterations orelse return null;
        product *= max;
        if (product > std.math.maxInt(u64)) return null;
    }
    if (current_loop) |loop| {
        const max = loop.max_iterations orelse return null;
        product *= max;
        if (product > std.math.maxInt(u64)) return null;
    }
    return @intCast(product);
}

fn applyBoundUpdates(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    line: []const u8,
) !void {
    if (parseLiteralAssignmentBound(line)) |update| {
        try setBound(arena_allocator, bounds, update);
    }
    if (parseSizeAliasBound(bounds, line)) |update| {
        try setBound(arena_allocator, bounds, update);
    }
    if (parseQueryLimitBound(line)) |update| {
        try setBound(arena_allocator, bounds, update);
    }
    try applyGuardBounds(arena_allocator, bounds, line);
}

fn setBound(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    update: BoundUpdate,
) !void {
    if (update.name.len == 0) return;
    if (bounds.getPtr(update.name)) |existing| {
        existing.* = mergeBound(existing.*, .{
            .max = update.max,
            .origin = update.origin,
        });
        return;
    }
    const key = try arena_allocator.dupe(u8, update.name);
    try bounds.put(key, .{
        .max = update.max,
        .origin = update.origin,
    });
}

fn mergeBound(current: Bound, incoming: Bound) Bound {
    if (incoming.max == null) return current;
    if (current.max == null) return incoming;
    if (incoming.max.? < current.max.?) return incoming;
    return current;
}

fn parseLiteralAssignmentBound(line: []const u8) ?BoundUpdate {
    if (std.mem.startsWith(u8, line, "if")) return null;
    if (std.mem.startsWith(u8, line, "for")) return null;
    if (std.mem.indexOf(u8, line, "==") != null) return null;

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trimTrailingDelimiter(right);

    if (right.len == 0) return null;
    if (right[0] == '[') return null;

    const value = parseLeadingUnsigned(right) orelse return null;
    const name = extractLastIdentifier(left) orelse return null;

    return .{
        .name = name,
        .max = value,
        .origin = .literal,
    };
}

fn parseSizeAliasBound(bounds: *std.StringHashMap(Bound), line: []const u8) ?BoundUpdate {
    if (std.mem.startsWith(u8, line, "if")) return null;
    if (std.mem.startsWith(u8, line, "for")) return null;
    if (std.mem.indexOf(u8, line, "==") != null) return null;

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trimTrailingDelimiter(right);

    const size_idx = std.mem.lastIndexOf(u8, right, ".size()") orelse return null;
    const collection_expr = std.mem.trim(u8, right[0..size_idx], " \t");
    const collection_max = inferCollectionUpperBound(collection_expr, bounds);
    const name = extractLastIdentifier(left) orelse return null;

    return .{
        .name = name,
        .max = collection_max,
        .origin = .alias,
    };
}

fn parseQueryLimitBound(line: []const u8) ?BoundUpdate {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    const right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    if (right.len == 0 or right[0] != '[') return null;
    if (indexOfCaseInsensitive(right, "select") == null) return null;

    const limit_idx = indexOfCaseInsensitive(right, "limit") orelse return null;
    const limit_raw = std.mem.trimLeft(u8, right[(limit_idx + 5)..], " \t");
    const limit = parseLeadingUnsigned(limit_raw) orelse return null;
    const name = extractLastIdentifier(left) orelse return null;

    return .{
        .name = name,
        .max = limit,
        .origin = .query_limit,
    };
}

fn applyGuardBounds(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    line: []const u8,
) !void {
    const if_idx = indexOfIfKeyword(line) orelse return;
    if (!containsExitStatement(line)) return;
    if (std.mem.indexOf(u8, line, "||") != null) return;

    const scoped = line[if_idx..];
    const open_idx = std.mem.indexOfScalar(u8, scoped, '(') orelse return;
    const close_idx = std.mem.lastIndexOfScalar(u8, scoped, ')') orelse return;
    if (close_idx <= open_idx) return;

    const condition = std.mem.trim(u8, scoped[(open_idx + 1)..close_idx], " \t");
    var has_any_bound = false;
    var validate_segments = std.mem.splitSequence(u8, condition, "&&");
    while (validate_segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) continue;
        _ = parseGuardUpperBound(segment) orelse return;
        has_any_bound = true;
    }
    if (!has_any_bound) return;

    var apply_segments = std.mem.splitSequence(u8, condition, "&&");
    while (apply_segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) continue;
        const update = parseGuardUpperBound(segment) orelse unreachable;
        try setBound(arena_allocator, bounds, update);
    }
}

fn indexOfIfKeyword(line: []const u8) ?usize {
    var i: usize = 0;
    while (i + 2 <= line.len) : (i += 1) {
        if (!std.mem.eql(u8, line[i .. i + 2], "if")) continue;
        const before_ok = i == 0 or !isIdentChar(line[i - 1]);
        if (!before_ok) continue;
        if (i + 2 >= line.len) return i;
        const next = line[i + 2];
        if (next == ' ' or next == '(') return i;
    }
    return null;
}

fn parseGuardUpperBound(segment: []const u8) ?BoundUpdate {
    if (parseGuardOp(segment, ">=")) |parsed| {
        const capped = if (parsed.value == 0) 0 else parsed.value - 1;
        return .{
            .name = parsed.name,
            .max = capped,
            .origin = .guard,
        };
    }
    if (parseGuardOp(segment, ">")) |parsed| {
        return .{
            .name = parsed.name,
            .max = parsed.value,
            .origin = .guard,
        };
    }
    return null;
}

fn parseGuardOp(segment: []const u8, op: []const u8) ?struct { name: []const u8, value: u64 } {
    const op_idx = std.mem.indexOf(u8, segment, op) orelse return null;
    const lhs_raw = std.mem.trim(u8, segment[0..op_idx], " \t");
    const rhs_raw = std.mem.trim(u8, segment[(op_idx + op.len)..], " \t");
    const value = parseLeadingUnsigned(rhs_raw) orelse return null;
    const name = extractBoundName(lhs_raw) orelse return null;
    return .{
        .name = name,
        .value = value,
    };
}

fn inferLoopInfo(line: []const u8, bounds: *std.StringHashMap(Bound)) ?LoopInfo {
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return .{ .max_iterations = null };
    const close_idx = std.mem.lastIndexOfScalar(u8, line, ')') orelse return .{ .max_iterations = null };
    if (close_idx <= open_idx) return .{ .max_iterations = null };

    const inside = std.mem.trim(u8, line[(open_idx + 1)..close_idx], " \t");
    if (std.mem.startsWith(u8, line, "for")) {
        if (std.mem.indexOfScalar(u8, inside, ':')) |colon_idx| {
            const iterable = std.mem.trim(u8, inside[(colon_idx + 1)..], " \t");
            return .{
                .max_iterations = inferCollectionUpperBound(iterable, bounds),
            };
        }
        var parts = std.mem.splitScalar(u8, inside, ';');
        _ = parts.next();
        const cond = parts.next() orelse return .{ .max_iterations = null };
        return .{
            .max_iterations = inferConditionUpperBound(cond, bounds),
        };
    }

    if (std.mem.startsWith(u8, line, "while")) {
        return .{
            .max_iterations = inferConditionUpperBound(inside, bounds),
        };
    }

    return .{ .max_iterations = null };
}

fn inferConditionUpperBound(cond: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    var best: ?u64 = null;
    var segments = std.mem.splitSequence(u8, cond, "&&");
    while (segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        const candidate = parseConditionUpperCandidate(segment, bounds) orelse continue;
        if (best == null or candidate < best.?) {
            best = candidate;
        }
    }
    return best;
}

fn parseConditionUpperCandidate(segment: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    if (parseConditionOp(segment, "<=", bounds)) |value| return value + 1;
    if (parseConditionOp(segment, "<", bounds)) |value| return value;
    return null;
}

fn parseConditionOp(segment: []const u8, op: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    const op_idx = std.mem.indexOf(u8, segment, op) orelse return null;
    const rhs_raw = std.mem.trim(u8, segment[(op_idx + op.len)..], " \t");

    if (parseLeadingUnsigned(rhs_raw)) |literal| return literal;

    if (parseMathMinLiteral(rhs_raw)) |literal| return literal;

    if (std.mem.lastIndexOf(u8, rhs_raw, ".size()")) |size_idx| {
        const collection = std.mem.trim(u8, rhs_raw[0..size_idx], " \t");
        return inferCollectionUpperBound(collection, bounds);
    }

    return lookupBoundMax(bounds, rhs_raw);
}

fn parseMathMinLiteral(expr: []const u8) ?u64 {
    if (indexOfCaseInsensitive(expr, "math.min(") == null) return null;
    const comma_idx = std.mem.lastIndexOfScalar(u8, expr, ',') orelse return null;
    const right = std.mem.trim(u8, expr[(comma_idx + 1)..], " \t)");
    return parseLeadingUnsigned(right);
}

fn inferCollectionUpperBound(expr_raw: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    var expr = std.mem.trim(u8, expr_raw, " \t");
    expr = trimTrailingDelimiter(expr);

    if (std.mem.eql(u8, expr, "Trigger.new") or std.mem.eql(u8, expr, "Trigger.old")) {
        return trigger_batch_limit;
    }

    if (std.mem.lastIndexOf(u8, expr, ".values()")) |idx| {
        expr = std.mem.trim(u8, expr[0..idx], " \t");
    } else if (std.mem.lastIndexOf(u8, expr, ".keySet()")) |idx| {
        expr = std.mem.trim(u8, expr[0..idx], " \t");
    }

    return lookupBoundMax(bounds, expr);
}

fn lookupBoundMax(bounds: *std.StringHashMap(Bound), name_raw: []const u8) ?u64 {
    const name = std.mem.trim(u8, name_raw, " \t");
    const bound = bounds.get(name) orelse return null;
    return bound.max;
}

fn extractBoundName(lhs_raw: []const u8) ?[]const u8 {
    const lhs = std.mem.trim(u8, lhs_raw, " \t");
    if (std.mem.lastIndexOf(u8, lhs, ".size()")) |size_idx| {
        return std.mem.trim(u8, lhs[0..size_idx], " \t");
    }
    return extractLastIdentifier(lhs);
}

fn extractLastIdentifier(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;

    var i = raw.len;
    while (i > 0 and !isIdentChar(raw[i - 1])) : (i -= 1) {}
    const end = i;
    if (end == 0) return null;
    while (i > 0 and isIdentChar(raw[i - 1])) : (i -= 1) {}
    if (i == end) return null;
    return raw[i..end];
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_';
}

fn containsExitStatement(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "return") != null or
        std.mem.indexOf(u8, line, "throw") != null;
}

fn parseLeadingUnsigned(raw: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or !std.ascii.isDigit(trimmed[0])) return null;

    var end: usize = 0;
    while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}
    return std.fmt.parseUnsigned(u64, trimmed[0..end], 10) catch null;
}

fn trimTrailingDelimiter(raw: []const u8) []const u8 {
    var out = std.mem.trim(u8, raw, " \t");
    while (out.len > 0 and (out[out.len - 1] == ';' or out[out.len - 1] == ')')) {
        out = std.mem.trimRight(u8, out[0 .. out.len - 1], " \t");
    }
    return out;
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn updateBraceDepth(current: i32, line: []const u8) i32 {
    var depth = current;
    depth += @intCast(countByte(line, '{'));
    depth -= @intCast(countByte(line, '}'));
    if (depth < 0) return 0;
    return depth;
}

fn countByte(buf: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (buf) |b| {
        if (b == needle) count += 1;
    }
    return count;
}

fn stripLineComment(raw: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, raw, "//") orelse return raw;
    return raw[0..idx];
}

fn isLoopStart(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for (") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while (");
}

fn containsSoql(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "[SELECT ") != null or
        std.mem.indexOf(u8, line, "[select ") != null or
        std.mem.indexOf(u8, line, "Database.query(") != null;
}

fn containsDml(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "insert ") or
        std.mem.startsWith(u8, trimmed, "update ") or
        std.mem.startsWith(u8, trimmed, "upsert ") or
        std.mem.startsWith(u8, trimmed, "delete ") or
        std.mem.indexOf(u8, line, "Database.insert(") != null or
        std.mem.indexOf(u8, line, "Database.update(") != null or
        std.mem.indexOf(u8, line, "Database.upsert(") != null or
        std.mem.indexOf(u8, line, "Database.delete(") != null;
}

fn containsJsonWork(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "JSON.serialize(") != null or
        std.mem.indexOf(u8, line, "JSON.deserialize(") != null;
}

fn containsCloneWork(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ".clone(") != null or
        std.mem.indexOf(u8, line, ".deepClone(") != null;
}

fn containsCollectionAlloc(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "new List<") != null or
        std.mem.indexOf(u8, line, "new Map<") != null or
        std.mem.indexOf(u8, line, "new Set<") != null;
}

fn containsStringAppend(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "+=") != null and
        (std.mem.indexOf(u8, line, "\"") != null or
            std.mem.indexOf(u8, line, "String") != null);
}

fn isApexSource(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".cls") or
        std.ascii.eqlIgnoreCase(ext, ".trigger") or
        std.ascii.eqlIgnoreCase(ext, ".apex");
}

test "guard upper bound parses from return guard" {
    const update = parseGuardUpperBound("n > 200") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("n", update.name);
    try std.testing.expectEqual(@as(?u64, 200), update.max);
}

test "for condition uses inferred variable bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var bounds = std.StringHashMap(Bound).init(allocator);
    const key = try allocator.dupe(u8, "n");
    try bounds.put(key, .{ .max = 120, .origin = .guard });

    const loop = inferLoopInfo("for (Integer i = 0; i < n; i++) {", &bounds) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u64, 120), loop.max_iterations);
}

test "cpu estimate helpers" {
    try std.testing.expectEqual(@as(u64, 271), computeCpuLimitN(500, 35));
    try std.testing.expectEqual(@as(?u64, 4700), estimateCpuTotalMs(500, 120, 35));
}

test "guarded loop yields bounded DML warning and cpu estimate" {
    const source =
        \\public with sharing class GuardedLoopService {
        \\    public static void run(List<Account> records) {
        \\        Integer n = records.size();
        \\        if (n > 120) return;
        \\        for (Integer i = 0; i < n; i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(dml.severity == .warning);
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);

    const cpu = findFindingByRule(findings.items, "AG009") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, cpu.message, "500 + 120*25") != null);
}

test "soql with bound 200 becomes governor error" {
    const source =
        \\public with sharing class ExceededGuardService {
        \\    public static void run(List<Account> records) {
        \\        Integer n = records.size();
        \\        if (n > 200) return;
        \\        for (Integer i = 0; i < n; i++) {
        \\            List<Account> one = [SELECT Id FROM Account WHERE Id = :records[i].Id LIMIT 1];
        \\            if (!one.isEmpty()) {
        \\                records[i].Name = one[0].Name;
        \\            }
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const soql = findFindingByRule(findings.items, "AG002") orelse return error.TestUnexpectedResult;
    try std.testing.expect(soql.severity == .err);
    try std.testing.expect(std.mem.indexOf(u8, soql.message, "Loop upper bound <= 200") != null);
}

test "cpu model config changes AG009 slope" {
    const source =
        \\public with sharing class TunedModelService {
        \\    public static void run(List<Account> records) {
        \\        Integer n = records.size();
        \\        if (n > 120) return;
        \\        for (Integer i = 0; i < n; i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var cfg = config.Config.defaults();
    cfg.cpu_model.base_ms = 450;
    cfg.cpu_model.dml_ms = 10;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, cfg);
    defer model.deinitFindings(std.testing.allocator, &findings);

    const cpu = findFindingByRule(findings.items, "AG009") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, cpu.message, "450 + 120*10") != null);
}

test "guard with non-bound conjunct is ignored for safety" {
    const source =
        \\public with sharing class ConditionalGuardService {
        \\    public static void run(List<Account> records, Boolean strictMode) {
        \\        Integer n = records.size();
        \\        if (n > 120 && strictMode) return;
        \\        for (Integer i = 0; i < n; i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "dynamic/unknown") != null);
}

test "math min loop bound is used" {
    const source =
        \\public with sharing class MathMinLoopService {
        \\    public static void run(List<Account> records) {
        \\        Integer n = records.size();
        \\        if (n > 500) return;
        \\        for (Integer i = 0; i < Math.min(n, 100); i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 100") != null);
}

test "size guard with >= sets inclusive cap" {
    const source =
        \\public with sharing class SizeGuardService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() >= 151) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 150") != null);
}

test "else-if guard on same line with brace is recognized" {
    const source =
        \\public with sharing class ElseIfGuardService {
        \\    public static void run(List<Account> records, Boolean bypass) {
        \\        Integer n = records.size();
        \\        if (bypass) {
        \\            return;
        \\        } else if (n > 140) return;
        \\        for (Integer i = 0; i < n; i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 140") != null);
}

test "loop calling helper with DML is flagged via method summary" {
    const source =
        \\public with sharing class HelperCallDmlService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            applyOne(records[i]);
        \\        }
        \\    }
        \\
        \\    private static void applyOne(Account acc) {
        \\        update acc;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

test "loop calling helper chain with SOQL is flagged transitively" {
    const source =
        \\public with sharing class HelperChainSoqlService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 80) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            enrich(records[i].Id);
        \\        }
        \\    }
        \\
        \\    private static void enrich(Id accountId) {
        \\        loadOne(accountId);
        \\    }
        \\
        \\    private static void loadOne(Id accountId) {
        \\        List<Account> one = [SELECT Id FROM Account WHERE Id = :accountId LIMIT 1];
        \\        if (!one.isEmpty()) {
        \\            one[0].Name = one[0].Name;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const soql = findFindingByRule(findings.items, "AG002") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, soql.message, "Loop upper bound <= 80") != null);
}

fn runCheckOnTempSource(
    gpa: std.mem.Allocator,
    source: []const u8,
    cfg: config.Config,
) !std.ArrayList(model.Finding) {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "Case.cls", .data = source });

    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "Case.cls" });
    defer gpa.free(path);

    const roots = [_][]const u8{path};
    return runWithConfig(gpa, &roots, cfg);
}

fn findFindingByRule(findings: []const model.Finding, rule_id: []const u8) ?model.Finding {
    for (findings) |finding| {
        if (std.mem.eql(u8, finding.rule_id, rule_id)) return finding;
    }
    return null;
}
