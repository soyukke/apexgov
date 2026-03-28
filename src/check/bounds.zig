const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const preprocessor = @import("preprocessor.zig");

const Bound = types.Bound;
const BoundOrigin = types.BoundOrigin;
const BoundUpdate = types.BoundUpdate;
const LoopScope = types.LoopScope;
const LoopInfo = types.LoopInfo;
const extractLastIdentifier = utils.extractLastIdentifier;
const parseLeadingUnsigned = utils.parseLeadingUnsigned;
const trimTrailingDelimiter = utils.trimTrailingDelimiter;
const trimTrailingSemicolon = utils.trimTrailingSemicolon;
const indexOfCaseInsensitive = utils.indexOfCaseInsensitive;
const isIdentChar = utils.isIdentChar;
const containsExitStatement = utils.containsExitStatement;
const satAdd = utils.satAdd;
const startsWithIgnoreCase = utils.startsWithIgnoreCase;
const isLoopStart = preprocessor.isLoopStart;
const isDoLoopStart = preprocessor.isDoLoopStart;

const trigger_batch_limit: u64 = 200;

pub fn effectiveLoopUpperBound(scopes: []const LoopScope, current_loop: ?LoopInfo) ?u64 {
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

pub fn applyBoundUpdates(
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
    if (parseDerivedAssignmentBound(bounds, line)) |update| {
        try setBound(arena_allocator, bounds, update);
    }
    try applyGuardBounds(arena_allocator, bounds, line);
}

pub fn setBound(
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

fn parseDerivedAssignmentBound(bounds: *std.StringHashMap(Bound), line: []const u8) ?BoundUpdate {
    if (std.mem.startsWith(u8, line, "if")) return null;
    if (std.mem.startsWith(u8, line, "for")) return null;
    if (std.mem.startsWith(u8, line, "while")) return null;
    if (std.mem.indexOf(u8, line, "==") != null) return null;

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trimTrailingSemicolon(right);
    if (right.len == 0 or right[0] == '[') return null;

    const max = inferExpressionUpperBound(right, bounds) orelse return null;
    const name = extractLastIdentifier(left) orelse return null;
    return .{
        .name = name,
        .max = max,
        .origin = .alias,
    };
}

pub fn applyGuardBounds(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    line: []const u8,
) !void {
    const if_idx = indexOfIfKeyword(line) orelse return;
    if (!containsExitStatement(line)) return;

    const scoped = line[if_idx..];
    const open_idx = std.mem.indexOfScalar(u8, scoped, '(') orelse return;
    const close_idx = std.mem.lastIndexOfScalar(u8, scoped, ')') orelse return;
    if (close_idx <= open_idx) return;

    const condition = std.mem.trim(u8, scoped[(open_idx + 1)..close_idx], " \t");
    if (condition.len == 0) return;

    if (std.mem.indexOf(u8, condition, "||")) |_| {
        try applyGuardBoundsForOr(arena_allocator, bounds, condition);
        return;
    }

    try applyGuardBoundsForAnd(arena_allocator, bounds, condition);
}

fn applyGuardBoundsForAnd(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    condition: []const u8,
) !void {
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

fn applyGuardBoundsForOr(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    condition: []const u8,
) !void {
    var segments = std.mem.splitSequence(u8, condition, "||");
    while (segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t()");
        if (segment.len == 0) continue;
        const update = parseGuardUpperBound(segment) orelse continue;
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

pub fn parseGuardUpperBound(segment: []const u8) ?BoundUpdate {
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

pub fn inferLoopInfo(line: []const u8, bounds: *std.StringHashMap(Bound)) ?LoopInfo {
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

pub fn inferLoopInfoAtLine(
    line: []const u8,
    bounds: *std.StringHashMap(Bound),
    do_while_conditions: *std.AutoHashMap(usize, []const u8),
    line_no: usize,
) ?LoopInfo {
    if (!isLoopStart(line)) return null;
    if (isDoLoopStart(line)) {
        const cond = do_while_conditions.get(line_no) orelse return .{ .max_iterations = null };
        return .{
            .max_iterations = inferConditionUpperBound(cond, bounds),
        };
    }
    return inferLoopInfo(line, bounds);
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
    return inferExpressionUpperBound(rhs_raw, bounds);
}

fn parseMathMinLiteral(expr: []const u8) ?u64 {
    if (indexOfCaseInsensitive(expr, "math.min(") == null) return null;
    const comma_idx = std.mem.lastIndexOfScalar(u8, expr, ',') orelse return null;
    const right = std.mem.trim(u8, expr[(comma_idx + 1)..], " \t)");
    return parseLeadingUnsigned(right);
}

pub fn inferExpressionUpperBound(expr_raw: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    var expr = std.mem.trim(u8, expr_raw, " \t");
    expr = trimTrailingSemicolon(expr);
    if (expr.len == 0) return null;

    if (parseLeadingUnsigned(expr)) |literal| return literal;
    if (parseMathMinUpperBound(expr, bounds)) |value| return value;
    return parseAddSubUpperBound(expr, bounds);
}

fn parseMathMinUpperBound(expr: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    const min_idx = indexOfCaseInsensitive(expr, "math.min(") orelse return null;
    if (min_idx != 0) return null;
    const open_idx = std.mem.indexOfScalar(u8, expr, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, expr, ')') orelse return null;
    if (close_idx <= open_idx) return null;

    const inside = std.mem.trim(u8, expr[(open_idx + 1)..close_idx], " \t");
    var parts = std.mem.splitScalar(u8, inside, ',');
    const left_raw = std.mem.trim(u8, parts.next() orelse return null, " \t");
    const right_raw = std.mem.trim(u8, parts.next() orelse return null, " \t");
    if (parts.next() != null) return null;

    const left_max = inferExpressionUpperBound(left_raw, bounds) orelse return null;
    const right_max = inferExpressionUpperBound(right_raw, bounds) orelse return null;
    return @min(left_max, right_max);
}

fn parseAddSubUpperBound(expr: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    var i: usize = 0;
    var total: ?u64 = null;
    var next_is_add = true;
    while (i < expr.len) {
        while (i < expr.len and (expr[i] == ' ' or expr[i] == '\t')) : (i += 1) {}
        if (i >= expr.len) break;

        const term_start = i;
        while (i < expr.len and expr[i] != '+' and expr[i] != '-') : (i += 1) {}
        const term_raw = std.mem.trim(u8, expr[term_start..i], " \t");
        if (term_raw.len == 0) return null;

        const term_max = inferSimpleExpressionTermUpperBound(term_raw, bounds) orelse return null;
        if (total == null) {
            total = term_max;
        } else if (next_is_add) {
            total = satAdd(total.?, term_max);
        } else {
            total = if (total.? > term_max) total.? - term_max else 0;
        }

        if (i < expr.len) {
            next_is_add = expr[i] == '+';
            i += 1;
        }
    }
    return total;
}

fn inferSimpleExpressionTermUpperBound(term: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    if (parseLeadingUnsigned(term)) |literal| return literal;
    if (std.mem.lastIndexOf(u8, term, ".size()")) |size_idx| {
        const collection = std.mem.trim(u8, term[0..size_idx], " \t");
        return inferCollectionUpperBound(collection, bounds);
    }
    return lookupBoundMax(bounds, term);
}

pub fn inferCollectionUpperBound(expr_raw: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
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

pub fn lookupBoundMax(bounds: *std.StringHashMap(Bound), name_raw: []const u8) ?u64 {
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
