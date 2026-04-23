//! bounds — ループ反復回数のバウンド推論。
//!
//! ループの反復上限をヒューリスティックに推定する。`Trigger.new` の
//! バッチサイズ (200)、`Limits.getLimitXxx()` によるガード条件、
//! コレクション `.size()` からのバウンド伝播などを解析し、
//! CPU 見積もり (AG009) の乗数として使用する。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const preprocessor = @import("preprocessor.zig");

const Bound = types.Bound;
const BoundUpdate = types.BoundUpdate;
const LoopScope = types.LoopScope;
const LoopInfo = types.LoopInfo;
const extract_last_identifier = utils.extract_last_identifier;
const parse_leading_unsigned = utils.parse_leading_unsigned;
const trim_trailing_delimiter = utils.trim_trailing_delimiter;
const trim_trailing_semicolon = utils.trim_trailing_semicolon;
const index_of_case_insensitive = utils.index_of_case_insensitive;
const is_ident_char = utils.is_ident_char;
const contains_exit_statement = utils.contains_exit_statement;
const sat_add = utils.sat_add;
const is_loop_start = preprocessor.is_loop_start;
const is_do_loop_start = preprocessor.is_do_loop_start;

const trigger_batch_limit: u64 = 200;

pub fn effective_loop_upper_bound(scopes: []const LoopScope, current_loop: ?LoopInfo) ?u64 {
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

pub fn apply_bound_updates(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    line: []const u8,
) !void {
    if (parse_literal_assignment_bound(line)) |update| {
        try set_bound(arena_allocator, bounds, update);
    }
    if (parse_size_alias_bound(bounds, line)) |update| {
        try set_bound(arena_allocator, bounds, update);
    }
    if (parse_query_limit_bound(line)) |update| {
        try set_bound(arena_allocator, bounds, update);
    }
    if (parse_derived_assignment_bound(bounds, line)) |update| {
        try set_bound(arena_allocator, bounds, update);
    }
    try apply_guard_bounds(arena_allocator, bounds, line);
}

pub fn set_bound(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    update: BoundUpdate,
) !void {
    if (update.name.len == 0) return;
    if (bounds.getPtr(update.name)) |existing| {
        existing.* = merge_bound(existing.*, .{
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

fn merge_bound(current: Bound, incoming: Bound) Bound {
    if (incoming.max == null) return current;
    if (current.max == null) return incoming;
    if (incoming.max.? < current.max.?) return incoming;
    return current;
}

fn parse_literal_assignment_bound(line: []const u8) ?BoundUpdate {
    if (std.mem.startsWith(u8, line, "if")) return null;
    if (std.mem.startsWith(u8, line, "for")) return null;
    if (std.mem.indexOf(u8, line, "==") != null) return null;

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trim_trailing_delimiter(right);

    if (right.len == 0) return null;
    if (right[0] == '[') return null;

    const value = parse_leading_unsigned(right) orelse return null;
    const name = extract_last_identifier(left) orelse return null;

    return .{
        .name = name,
        .max = value,
        .origin = .literal,
    };
}

fn parse_size_alias_bound(bounds: *std.StringHashMap(Bound), line: []const u8) ?BoundUpdate {
    if (std.mem.startsWith(u8, line, "if")) return null;
    if (std.mem.startsWith(u8, line, "for")) return null;
    if (std.mem.indexOf(u8, line, "==") != null) return null;

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trim_trailing_delimiter(right);

    const size_idx = std.mem.lastIndexOf(u8, right, ".size()") orelse return null;
    const collection_expr = std.mem.trim(u8, right[0..size_idx], " \t");
    const collection_max = infer_collection_upper_bound(collection_expr, bounds);
    const name = extract_last_identifier(left) orelse return null;

    return .{
        .name = name,
        .max = collection_max,
        .origin = .alias,
    };
}

fn parse_query_limit_bound(line: []const u8) ?BoundUpdate {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    const right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    if (right.len == 0 or right[0] != '[') return null;
    if (index_of_case_insensitive(right, "select") == null) return null;

    const limit_idx = index_of_case_insensitive(right, "limit") orelse return null;
    const limit_raw = std.mem.trimStart(u8, right[(limit_idx + 5)..], " \t");
    const limit = parse_leading_unsigned(limit_raw) orelse return null;
    const name = extract_last_identifier(left) orelse return null;

    return .{
        .name = name,
        .max = limit,
        .origin = .query_limit,
    };
}

fn parse_derived_assignment_bound(bounds: *std.StringHashMap(Bound), line: []const u8) ?BoundUpdate {
    if (std.mem.startsWith(u8, line, "if")) return null;
    if (std.mem.startsWith(u8, line, "for")) return null;
    if (std.mem.startsWith(u8, line, "while")) return null;
    if (std.mem.indexOf(u8, line, "==") != null) return null;

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trim_trailing_semicolon(right);
    if (right.len == 0 or right[0] == '[') return null;

    const max = infer_expression_upper_bound(right, bounds) orelse return null;
    const name = extract_last_identifier(left) orelse return null;
    return .{
        .name = name,
        .max = max,
        .origin = .alias,
    };
}

pub fn apply_guard_bounds(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    line: []const u8,
) !void {
    const if_idx = index_of_if_keyword(line) orelse return;
    if (!contains_exit_statement(line)) return;

    const scoped = line[if_idx..];
    const open_idx = std.mem.indexOfScalar(u8, scoped, '(') orelse return;
    const close_idx = std.mem.lastIndexOfScalar(u8, scoped, ')') orelse return;
    if (close_idx <= open_idx) return;

    const condition = std.mem.trim(u8, scoped[(open_idx + 1)..close_idx], " \t");
    if (condition.len == 0) return;

    if (std.mem.indexOf(u8, condition, "||")) |_| {
        try apply_guard_bounds_for_or(arena_allocator, bounds, condition);
        return;
    }

    try apply_guard_bounds_for_and(arena_allocator, bounds, condition);
}

fn apply_guard_bounds_for_and(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    condition: []const u8,
) !void {
    var has_any_bound = false;
    var validate_segments = std.mem.splitSequence(u8, condition, "&&");
    while (validate_segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) continue;
        _ = parse_guard_upper_bound(segment) orelse return;
        has_any_bound = true;
    }
    if (!has_any_bound) return;

    var apply_segments = std.mem.splitSequence(u8, condition, "&&");
    while (apply_segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) continue;
        const update = parse_guard_upper_bound(segment) orelse unreachable;
        try set_bound(arena_allocator, bounds, update);
    }
}

fn apply_guard_bounds_for_or(
    arena_allocator: std.mem.Allocator,
    bounds: *std.StringHashMap(Bound),
    condition: []const u8,
) !void {
    var segments = std.mem.splitSequence(u8, condition, "||");
    while (segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t()");
        if (segment.len == 0) continue;
        const update = parse_guard_upper_bound(segment) orelse continue;
        try set_bound(arena_allocator, bounds, update);
    }
}

fn index_of_if_keyword(line: []const u8) ?usize {
    var i: usize = 0;
    while (i + 2 <= line.len) : (i += 1) {
        if (!std.mem.eql(u8, line[i .. i + 2], "if")) continue;
        const before_ok = i == 0 or !is_ident_char(line[i - 1]);
        if (!before_ok) continue;
        if (i + 2 >= line.len) return i;
        const next = line[i + 2];
        if (next == ' ' or next == '(') return i;
    }
    return null;
}

pub fn parse_guard_upper_bound(segment: []const u8) ?BoundUpdate {
    if (parse_guard_op(segment, ">=")) |parsed| {
        const capped = if (parsed.value == 0) 0 else parsed.value - 1;
        return .{
            .name = parsed.name,
            .max = capped,
            .origin = .guard,
        };
    }
    if (parse_guard_op(segment, ">")) |parsed| {
        return .{
            .name = parsed.name,
            .max = parsed.value,
            .origin = .guard,
        };
    }
    return null;
}

fn parse_guard_op(segment: []const u8, op: []const u8) ?struct { name: []const u8, value: u64 } {
    const op_idx = std.mem.indexOf(u8, segment, op) orelse return null;
    const lhs_raw = std.mem.trim(u8, segment[0..op_idx], " \t");
    const rhs_raw = std.mem.trim(u8, segment[(op_idx + op.len)..], " \t");
    const value = parse_leading_unsigned(rhs_raw) orelse return null;
    const name = extract_bound_name(lhs_raw) orelse return null;
    return .{
        .name = name,
        .value = value,
    };
}

pub fn infer_loop_info(line: []const u8, bounds: *std.StringHashMap(Bound)) ?LoopInfo {
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return .{ .max_iterations = null };
    const close_idx = std.mem.lastIndexOfScalar(u8, line, ')') orelse return .{ .max_iterations = null };
    if (close_idx <= open_idx) return .{ .max_iterations = null };

    const inside = std.mem.trim(u8, line[(open_idx + 1)..close_idx], " \t");
    if (std.mem.startsWith(u8, line, "for")) {
        if (std.mem.indexOfScalar(u8, inside, ':')) |colon_idx| {
            const iterable = std.mem.trim(u8, inside[(colon_idx + 1)..], " \t");
            return .{
                .max_iterations = infer_collection_upper_bound(iterable, bounds),
            };
        }
        var parts = std.mem.splitScalar(u8, inside, ';');
        _ = parts.next();
        const cond = parts.next() orelse return .{ .max_iterations = null };
        return .{
            .max_iterations = infer_condition_upper_bound(cond, bounds),
        };
    }

    if (std.mem.startsWith(u8, line, "while")) {
        return .{
            .max_iterations = infer_condition_upper_bound(inside, bounds),
        };
    }

    return .{ .max_iterations = null };
}

pub fn infer_loop_info_at_line(
    line: []const u8,
    bounds: *std.StringHashMap(Bound),
    do_while_conditions: *std.AutoHashMap(usize, []const u8),
    line_no: usize,
) ?LoopInfo {
    if (!is_loop_start(line)) return null;
    if (is_do_loop_start(line)) {
        const cond = do_while_conditions.get(line_no) orelse return .{ .max_iterations = null };
        return .{
            .max_iterations = infer_condition_upper_bound(cond, bounds),
        };
    }
    return infer_loop_info(line, bounds);
}

fn infer_condition_upper_bound(cond: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    var best: ?u64 = null;
    var segments = std.mem.splitSequence(u8, cond, "&&");
    while (segments.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        const candidate = parse_condition_upper_candidate(segment, bounds) orelse continue;
        if (best == null or candidate < best.?) {
            best = candidate;
        }
    }
    return best;
}

fn parse_condition_upper_candidate(segment: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    if (parse_condition_op(segment, "<=", bounds)) |value| return value + 1;
    if (parse_condition_op(segment, "<", bounds)) |value| return value;
    return null;
}

fn parse_condition_op(segment: []const u8, op: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    const op_idx = std.mem.indexOf(u8, segment, op) orelse return null;
    const rhs_raw = std.mem.trim(u8, segment[(op_idx + op.len)..], " \t");
    return infer_expression_upper_bound(rhs_raw, bounds);
}

fn parse_math_min_literal(expr: []const u8) ?u64 {
    if (index_of_case_insensitive(expr, "math.min(") == null) return null;
    const comma_idx = std.mem.lastIndexOfScalar(u8, expr, ',') orelse return null;
    const right = std.mem.trim(u8, expr[(comma_idx + 1)..], " \t)");
    return parse_leading_unsigned(right);
}

pub fn infer_expression_upper_bound(expr_raw: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    var expr = std.mem.trim(u8, expr_raw, " \t");
    expr = trim_trailing_semicolon(expr);
    if (expr.len == 0) return null;

    if (parse_leading_unsigned(expr)) |literal| return literal;
    if (parse_math_min_upper_bound(expr, bounds)) |value| return value;
    return parse_add_sub_upper_bound(expr, bounds);
}

fn parse_math_min_upper_bound(expr: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    const min_idx = index_of_case_insensitive(expr, "math.min(") orelse return null;
    if (min_idx != 0) return null;
    const open_idx = std.mem.indexOfScalar(u8, expr, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, expr, ')') orelse return null;
    if (close_idx <= open_idx) return null;

    const inside = std.mem.trim(u8, expr[(open_idx + 1)..close_idx], " \t");
    var parts = std.mem.splitScalar(u8, inside, ',');
    const left_raw = std.mem.trim(u8, parts.next() orelse return null, " \t");
    const right_raw = std.mem.trim(u8, parts.next() orelse return null, " \t");
    if (parts.next() != null) return null;

    const left_max = infer_expression_upper_bound(left_raw, bounds) orelse return null;
    const right_max = infer_expression_upper_bound(right_raw, bounds) orelse return null;
    return @min(left_max, right_max);
}

fn parse_add_sub_upper_bound(expr: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
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

        const term_max = infer_simple_expression_term_upper_bound(term_raw, bounds) orelse return null;
        if (total == null) {
            total = term_max;
        } else if (next_is_add) {
            total = sat_add(total.?, term_max);
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

fn infer_simple_expression_term_upper_bound(term: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    if (parse_leading_unsigned(term)) |literal| return literal;
    if (std.mem.lastIndexOf(u8, term, ".size()")) |size_idx| {
        const collection = std.mem.trim(u8, term[0..size_idx], " \t");
        return infer_collection_upper_bound(collection, bounds);
    }
    return lookup_bound_max(bounds, term);
}

pub fn infer_collection_upper_bound(expr_raw: []const u8, bounds: *std.StringHashMap(Bound)) ?u64 {
    var expr = std.mem.trim(u8, expr_raw, " \t");
    expr = trim_trailing_delimiter(expr);

    if (std.mem.eql(u8, expr, "Trigger.new") or std.mem.eql(u8, expr, "Trigger.old")) {
        return trigger_batch_limit;
    }

    if (std.mem.lastIndexOf(u8, expr, ".values()")) |idx| {
        expr = std.mem.trim(u8, expr[0..idx], " \t");
    } else if (std.mem.lastIndexOf(u8, expr, ".keySet()")) |idx| {
        expr = std.mem.trim(u8, expr[0..idx], " \t");
    }

    return lookup_bound_max(bounds, expr);
}

pub fn lookup_bound_max(bounds: *std.StringHashMap(Bound), name_raw: []const u8) ?u64 {
    const name = std.mem.trim(u8, name_raw, " \t");
    const bound = bounds.get(name) orelse return null;
    return bound.max;
}

fn extract_bound_name(lhs_raw: []const u8) ?[]const u8 {
    const lhs = std.mem.trim(u8, lhs_raw, " \t");
    if (std.mem.lastIndexOf(u8, lhs, ".size()")) |size_idx| {
        return std.mem.trim(u8, lhs[0..size_idx], " \t");
    }
    return extract_last_identifier(lhs);
}
