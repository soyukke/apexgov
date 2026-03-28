//! call_graph — メソッド呼び出しグラフの構築と解決。
//!
//! 各メソッドの Governor 制限消費サマリー (`MethodSummary`) を構築し、
//! クロスクラス・間接呼び出しのメトリクスをカスケード伝播する。
//! 型の継承/インターフェース実装を考慮したメソッドマッチングにより、
//! ポリモーフィックな呼び出しも追跡する。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const scope_mod = @import("scope.zig");
const type_env_mod = @import("type_env.zig");
const bounds_mod = @import("bounds.zig");
const detectors = @import("detectors.zig");
const preprocessor = @import("preprocessor.zig");

const MethodSummary = types.MethodSummary;
const MethodScope = types.MethodScope;
const MethodDecl = types.MethodDecl;
const MethodCall = types.MethodCall;
const MethodMetrics = types.MethodMetrics;
const OwnerScope = types.OwnerScope;
const TypeRelations = types.TypeRelations;
const TypeDecl = types.TypeDecl;
const LoopScope = types.LoopScope;
const LoopInfo = types.LoopInfo;
const PendingLoopScopeStart = types.PendingLoopScopeStart;
const Bound = types.Bound;
const ApexFile = types.ApexFile;
const TypeBinding = types.TypeBinding;
const isIdentChar = utils.isIdentChar;
const isIdentStart = utils.isIdentStart;
const extractLeadingIdentifier = utils.extractLeadingIdentifier;
const satAdd = utils.satAdd;
const satAddU16 = utils.satAddU16;
const extractParameterTypePart = utils.extractParameterTypePart;
const appendCanonicalType = utils.appendCanonicalType;
const trimTrailingDelimiter = utils.trimTrailingDelimiter;
const equalsCanonicalType = utils.equalsCanonicalType;
const extractTypeFromNewExpression = utils.extractTypeFromNewExpression;
const stripCommentsPreserveLines = preprocessor.stripCommentsPreserveLines;
const parseMethodStart = parser.parseMethodStart;
const buildParamTypeSignature = parser.buildParamTypeSignature;
const countSignatureParams = parser.countSignatureParams;
const indexOfWordIgnoreCase = parser.indexOfWordIgnoreCase;
const registerTypeDecl = parser.registerTypeDecl;
const parseTypeDecl = parser.parseTypeDecl;
const maybeEnterOwnerScope = scope_mod.maybeEnterOwnerScope;
const popClosedOwners = scope_mod.popClosedOwners;
const popClosedScopes = scope_mod.popClosedScopes;
const updateBraceDepth = utils.updateBraceDepth;
const registerMethodParamTypes = type_env_mod.registerMethodParamTypes;
const applyLocalTypeUpdates = type_env_mod.applyLocalTypeUpdates;
const bindType = type_env_mod.bindType;
const parseTypedBinding = type_env_mod.parseTypedBinding;
const applyBoundUpdates = bounds_mod.applyBoundUpdates;
const inferLoopInfoAtLine = bounds_mod.inferLoopInfoAtLine;
const effectiveLoopUpperBound = bounds_mod.effectiveLoopUpperBound;
const collectDoWhileStartConditions = preprocessor.collectDoWhileStartConditions;
const isDoLoopStart = preprocessor.isDoLoopStart;

pub fn buildMethodSummaries(
    arena_allocator: std.mem.Allocator,
    files: []const ApexFile,
    type_relations: *const TypeRelations,
) !std.StringHashMap(MethodSummary) {
    var summaries = std.StringHashMap(MethodSummary).init(arena_allocator);

    for (files) |file| {
        try collectMethodNames(arena_allocator, file.content, &summaries);
    }
    for (files) |file| {
        try collectMethodDirectMetricsAndCalls(arena_allocator, file.content, &summaries, type_relations);
    }

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

pub fn collectTypeRelations(
    arena_allocator: std.mem.Allocator,
    files: []const ApexFile,
) !TypeRelations {
    var relations = TypeRelations{
        .extends_by_type = std.StringHashMap([]const u8).init(arena_allocator),
        .interfaces_by_type = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(arena_allocator),
    };

    for (files) |file| {
        try collectTypeRelationsFromContent(arena_allocator, file.content, &relations);
    }

    return relations;
}

fn collectTypeRelationsFromContent(
    arena_allocator: std.mem.Allocator,
    content: []const u8,
    relations: *TypeRelations,
) !void {
    const stripped_content = try stripCommentsPreserveLines(arena_allocator, content);
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        const decl = parseTypeDecl(trimmed) orelse continue;
        try registerTypeDecl(arena_allocator, relations, decl);
    }
}

fn collectMethodNames(
    arena_allocator: std.mem.Allocator,
    content: []const u8,
    summaries: *std.StringHashMap(MethodSummary),
) !void {
    const stripped_content = try stripCommentsPreserveLines(arena_allocator, content);
    var owner_scopes: std.ArrayList(OwnerScope) = .empty;
    defer owner_scopes.deinit(arena_allocator);

    var brace_depth: i32 = 0;
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');
    while (lines.next()) |raw| {
        const code_line = raw;
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        popClosedOwners(&owner_scopes, brace_depth);

        if (trimmed.len > 0) {
            try maybeEnterOwnerScope(arena_allocator, &owner_scopes, brace_depth, trimmed);
            if (owner_scopes.items.len > 0) {
                const owner = owner_scopes.items[owner_scopes.items.len - 1].name;
                if (parseMethodStart(trimmed)) |decl| {
                    _ = try ensureMethodSummary(arena_allocator, summaries, owner, decl.name, decl.params_raw);
                }
            }
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        popClosedOwners(&owner_scopes, brace_depth);
    }
}

fn collectMethodDirectMetricsAndCalls(
    arena_allocator: std.mem.Allocator,
    content: []const u8,
    summaries: *std.StringHashMap(MethodSummary),
    type_relations: *const TypeRelations,
) !void {
    const stripped_content = try stripCommentsPreserveLines(arena_allocator, content);
    var owner_scopes: std.ArrayList(OwnerScope) = .empty;
    defer owner_scopes.deinit(arena_allocator);

    var method_loop_scopes: std.ArrayList(LoopScope) = .empty;
    defer method_loop_scopes.deinit(arena_allocator);
    var pending_method_loop_scope: ?PendingLoopScopeStart = null;

    var method_bounds = std.StringHashMap(Bound).init(arena_allocator);
    var type_env = std.StringHashMap([]const u8).init(arena_allocator);
    var do_while_conditions = try collectDoWhileStartConditions(arena_allocator, content);

    var brace_depth: i32 = 0;
    var current_method: ?MethodScope = null;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');

    while (lines.next()) |raw| {
        line_no += 1;
        const code_line = raw;
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        popClosedOwners(&owner_scopes, brace_depth);

        var started_method = false;
        if (trimmed.len > 0) {
            try maybeEnterOwnerScope(arena_allocator, &owner_scopes, brace_depth, trimmed);
            const owner = if (owner_scopes.items.len == 0) null else owner_scopes.items[owner_scopes.items.len - 1].name;

            if (current_method == null and owner != null) {
                if (parseMethodStart(trimmed)) |decl| {
                    const summary = try ensureMethodSummary(
                        arena_allocator,
                        summaries,
                        owner.?,
                        decl.name,
                        decl.params_raw,
                    );
                    method_loop_scopes.clearRetainingCapacity();
                    method_bounds = std.StringHashMap(Bound).init(arena_allocator);
                    type_env = std.StringHashMap([]const u8).init(arena_allocator);
                    try registerMethodParamTypes(arena_allocator, &type_env, decl.params_raw);
                    current_method = .{
                        .owner = owner.?,
                        .name = summary.name,
                        .param_count = summary.param_count,
                        .param_signature = summary.param_signature,
                        .end_depth = brace_depth + 1,
                        .entered_body = std.mem.indexOfScalar(u8, trimmed, '{') != null,
                    };
                    pending_method_loop_scope = null;
                    started_method = true;
                }
            }

            if (!started_method) {
                if (current_method) |scope| {
                    popClosedScopes(&method_loop_scopes, brace_depth);
                    if (pending_method_loop_scope) |pending| {
                        if (trimmed[0] == '{' and brace_depth == pending.expected_depth) {
                            try method_loop_scopes.append(arena_allocator, .{
                                .end_depth = brace_depth + 1,
                                .max_iterations = pending.max_iterations,
                            });
                        }
                        pending_method_loop_scope = null;
                    }
                    try applyBoundUpdates(arena_allocator, &method_bounds, trimmed);
                    try applyLocalTypeUpdates(arena_allocator, &type_env, trimmed);
                    const local_loop_info = inferLoopInfoAtLine(
                        trimmed,
                        &method_bounds,
                        &do_while_conditions,
                        line_no,
                    );
                    const local_loop_multiplier = effectiveLoopUpperBound(method_loop_scopes.items, local_loop_info) orelse 1;

                    const summary = findMethodSummaryByOwnerNameSignature(
                        summaries,
                        scope.owner,
                        scope.name,
                        scope.param_signature,
                    ) orelse unreachable;
                    applyDirectLineMetrics(&summary.direct, trimmed, local_loop_multiplier, &type_env);
                    try recordCalledMethods(
                        arena_allocator,
                        &summary.calls,
                        summaries,
                        scope.owner,
                        scope.name,
                        trimmed,
                        &type_env,
                        type_relations,
                        local_loop_multiplier,
                    );

                    if (local_loop_info != null and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                        try method_loop_scopes.append(arena_allocator, .{
                            .end_depth = brace_depth + 1,
                            .max_iterations = local_loop_info.?.max_iterations,
                        });
                    } else if (local_loop_info != null and isDoLoopStart(trimmed)) {
                        pending_method_loop_scope = .{
                            .expected_depth = brace_depth,
                            .max_iterations = local_loop_info.?.max_iterations,
                        };
                    }
                }
            }
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        if (pending_method_loop_scope) |pending| {
            if (brace_depth < pending.expected_depth) pending_method_loop_scope = null;
        }
        if (current_method) |*scope| {
            popClosedScopes(&method_loop_scopes, brace_depth);
            if (!scope.entered_body and brace_depth >= scope.end_depth) {
                scope.entered_body = true;
            }
            if (scope.entered_body and brace_depth < scope.end_depth) {
                current_method = null;
                type_env = std.StringHashMap([]const u8).init(arena_allocator);
                pending_method_loop_scope = null;
            }
        }
        popClosedOwners(&owner_scopes, brace_depth);
    }
}

pub fn ensureMethodSummary(
    arena_allocator: std.mem.Allocator,
    summaries: *std.StringHashMap(MethodSummary),
    owner: []const u8,
    name: []const u8,
    params_raw: []const u8,
) !*MethodSummary {
    const param_signature = try buildParamTypeSignature(arena_allocator, params_raw);
    const param_count = countSignatureParams(param_signature);
    if (findMethodSummaryByOwnerNameSignature(summaries, owner, name, param_signature)) |existing| return existing;

    const owner_copy = try arena_allocator.dupe(u8, owner);
    const name_copy = try arena_allocator.dupe(u8, name);
    const signature_copy = try arena_allocator.dupe(u8, param_signature);
    const key = try formatMethodKey(arena_allocator, owner_copy, name_copy, signature_copy);
    try summaries.put(key, .{
        .owner = owner_copy,
        .name = name_copy,
        .param_count = param_count,
        .param_signature = signature_copy,
    });
    return summaries.getPtr(key).?;
}

fn findMethodSummaryByOwnerNameSignature(
    summaries: *std.StringHashMap(MethodSummary),
    owner: []const u8,
    name: []const u8,
    param_signature: []const u8,
) ?*MethodSummary {
    var it = summaries.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.owner, owner)) continue;
        if (!std.mem.eql(u8, entry.value_ptr.name, name)) continue;
        if (!std.mem.eql(u8, entry.value_ptr.param_signature, param_signature)) continue;
        return entry.value_ptr;
    }
    return null;
}

fn formatMethodKey(
    arena_allocator: std.mem.Allocator,
    owner: []const u8,
    name: []const u8,
    param_signature: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(arena_allocator, "{s}.{s}/{s}", .{ owner, name, param_signature });
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
    for (summary.calls.items) |call| {
        const callee_total = resolveMethodTotal(summaries, call.callee_key);
        total.addScaled(callee_total, call.multiplier);
    }
    summary.total = total;
    summary.state = .resolved;
    return total;
}

fn applyDirectLineMetrics(
    metrics: *MethodMetrics,
    line: []const u8,
    multiplier: u64,
    type_env: *std.StringHashMap([]const u8),
) void {
    const weight = if (multiplier == 0) @as(u64, 1) else multiplier;
    if (detectors.containsSoql(line)) metrics.soql = satAdd(metrics.soql, weight);
    if (detectors.containsDml(line)) metrics.dml = satAdd(metrics.dml, weight);
    if (detectors.containsSosl(line)) metrics.sosl = satAdd(metrics.sosl, weight);
    if (detectors.containsCallout(line, type_env)) metrics.callout = satAdd(metrics.callout, weight);
    if (detectors.containsMessaging(line)) metrics.messaging = satAdd(metrics.messaging, weight);
    if (detectors.containsJsonWork(line)) metrics.json = satAdd(metrics.json, weight);
    if (detectors.containsCloneWork(line)) metrics.clone = satAdd(metrics.clone, weight);
    if (detectors.containsCollectionAlloc(line)) metrics.collection_alloc = satAdd(metrics.collection_alloc, weight);
    if (detectors.containsStringAppend(line)) metrics.string_append = satAdd(metrics.string_append, weight);
}

fn recordCalledMethods(
    arena_allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged(MethodCall),
    summaries: *std.StringHashMap(MethodSummary),
    caller_owner: []const u8,
    caller_name: []const u8,
    line: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
    multiplier: u64,
) !void {
    var it = summaries.iterator();
    while (it.next()) |entry| {
        const callee_key = entry.key_ptr.*;
        const callee = entry.value_ptr.*;
        if (std.mem.eql(u8, callee.owner, caller_owner) and std.mem.eql(u8, callee.name, caller_name)) continue;
        if (!lineCallsMethod(
            line,
            caller_owner,
            callee.owner,
            callee.name,
            callee.param_count,
            callee.param_signature,
            type_env,
            type_relations,
        )) continue;
        try appendOrAccumulateCall(arena_allocator, calls, callee_key, multiplier);
    }
}

fn appendOrAccumulateCall(
    arena_allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged(MethodCall),
    callee_key: []const u8,
    multiplier: u64,
) !void {
    const weight = if (multiplier == 0) @as(u64, 1) else multiplier;
    for (calls.items) |*existing| {
        if (!std.mem.eql(u8, existing.callee_key, callee_key)) continue;
        existing.multiplier = satAdd(existing.multiplier, weight);
        return;
    }
    try calls.append(arena_allocator, .{
        .callee_key = callee_key,
        .multiplier = weight,
    });
}

pub fn inferCalledMethodMetrics(
    line: []const u8,
    current_owner: ?[]const u8,
    type_env: *std.StringHashMap([]const u8),
    summaries: *std.StringHashMap(MethodSummary),
    type_relations: *const TypeRelations,
) MethodMetrics {
    var metrics: MethodMetrics = .{};
    var it = summaries.iterator();
    while (it.next()) |entry| {
        const callee = entry.value_ptr.*;
        if (!lineCallsMethod(
            line,
            current_owner orelse "",
            callee.owner,
            callee.name,
            callee.param_count,
            callee.param_signature,
            type_env,
            type_relations,
        )) continue;
        metrics.add(entry.value_ptr.total);
    }
    return metrics;
}

fn lineCallsMethod(
    line: []const u8,
    caller_owner: []const u8,
    callee_owner: []const u8,
    callee_name: []const u8,
    callee_param_count: u16,
    callee_param_signature: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
) bool {
    if (containsQualifiedMethodCall(
        line,
        callee_owner,
        callee_name,
        callee_param_count,
        callee_param_signature,
        type_env,
        type_relations,
    )) return true;
    if (std.mem.eql(u8, caller_owner, callee_owner) and containsBareMethodCall(
        line,
        callee_name,
        callee_param_count,
        callee_param_signature,
        type_env,
        type_relations,
    )) return true;
    if (std.mem.eql(u8, caller_owner, callee_owner) and containsQualifiedMethodCall(
        line,
        "this",
        callee_name,
        callee_param_count,
        callee_param_signature,
        type_env,
        type_relations,
    )) return true;
    if (containsTypedReceiverMethodCall(
        line,
        callee_owner,
        callee_name,
        callee_param_count,
        callee_param_signature,
        type_env,
        type_relations,
    )) return true;
    return false;
}

fn containsBareMethodCall(
    line: []const u8,
    method_name: []const u8,
    expected_param_count: u16,
    expected_param_signature: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
) bool {
    if (method_name.len == 0) return false;

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, method_name)) |idx| {
        const before_ok = idx == 0 or (!isIdentChar(line[idx - 1]) and line[idx - 1] != '.');
        var end = idx + method_name.len;
        while (end < line.len and (line[end] == ' ' or line[end] == '\t')) : (end += 1) {}
        const after_ok = end < line.len and line[end] == '(';
        if (before_ok and after_ok) {
            const arg_count = countCallArguments(line, end) orelse {
                start = idx + method_name.len;
                continue;
            };
            if (arg_count == expected_param_count and argumentsMatchParamSignature(
                line,
                end,
                expected_param_signature,
                type_env,
                type_relations,
            )) return true;
        }
        start = idx + method_name.len;
    }
    return false;
}

fn containsQualifiedMethodCall(
    line: []const u8,
    owner: []const u8,
    method_name: []const u8,
    expected_param_count: u16,
    expected_param_signature: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
) bool {
    if (owner.len == 0 or method_name.len == 0) return false;

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, owner)) |owner_idx| {
        const owner_before_ok = owner_idx == 0 or !isIdentChar(line[owner_idx - 1]);
        if (!owner_before_ok) {
            start = owner_idx + owner.len;
            continue;
        }

        var dot_idx = owner_idx + owner.len;
        while (dot_idx < line.len and (line[dot_idx] == ' ' or line[dot_idx] == '\t')) : (dot_idx += 1) {}
        if (dot_idx >= line.len or line[dot_idx] != '.') {
            start = owner_idx + owner.len;
            continue;
        }

        var method_idx = dot_idx + 1;
        while (method_idx < line.len and (line[method_idx] == ' ' or line[method_idx] == '\t')) : (method_idx += 1) {}
        if (method_idx + method_name.len > line.len) {
            start = owner_idx + owner.len;
            continue;
        }
        if (!std.mem.eql(u8, line[method_idx .. method_idx + method_name.len], method_name)) {
            start = owner_idx + owner.len;
            continue;
        }

        var open_idx = method_idx + method_name.len;
        while (open_idx < line.len and (line[open_idx] == ' ' or line[open_idx] == '\t')) : (open_idx += 1) {}
        if (open_idx < line.len and line[open_idx] == '(') {
            const arg_count = countCallArguments(line, open_idx) orelse {
                start = owner_idx + owner.len;
                continue;
            };
            if (arg_count == expected_param_count and argumentsMatchParamSignature(
                line,
                open_idx,
                expected_param_signature,
                type_env,
                type_relations,
            )) return true;
        }

        start = owner_idx + owner.len;
    }

    return false;
}

fn containsTypedReceiverMethodCall(
    line: []const u8,
    callee_owner: []const u8,
    method_name: []const u8,
    expected_param_count: u16,
    expected_param_signature: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
) bool {
    if (callee_owner.len == 0 or method_name.len == 0) return false;

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, method_name)) |method_idx| {
        const method_before_ok = method_idx == 0 or !isIdentChar(line[method_idx - 1]);
        if (!method_before_ok) {
            start = method_idx + method_name.len;
            continue;
        }

        var dot_idx = method_idx;
        while (dot_idx > 0 and (line[dot_idx - 1] == ' ' or line[dot_idx - 1] == '\t')) : (dot_idx -= 1) {}
        if (dot_idx == 0 or line[dot_idx - 1] != '.') {
            start = method_idx + method_name.len;
            continue;
        }

        var receiver_end = dot_idx - 1;
        while (receiver_end > 0 and (line[receiver_end - 1] == ' ' or line[receiver_end - 1] == '\t')) : (receiver_end -= 1) {}
        var receiver_start = receiver_end;
        while (receiver_start > 0 and isIdentChar(line[receiver_start - 1])) : (receiver_start -= 1) {}
        if (receiver_start == receiver_end) {
            start = method_idx + method_name.len;
            continue;
        }
        const receiver = line[receiver_start..receiver_end];

        const bound_type = type_env.get(receiver) orelse {
            start = method_idx + method_name.len;
            continue;
        };
        if (!boundTypeMatchesOwner(bound_type, callee_owner, type_relations)) {
            start = method_idx + method_name.len;
            continue;
        }

        var open_idx = method_idx + method_name.len;
        while (open_idx < line.len and (line[open_idx] == ' ' or line[open_idx] == '\t')) : (open_idx += 1) {}
        if (open_idx >= line.len or line[open_idx] != '(') {
            start = method_idx + method_name.len;
            continue;
        }

        const arg_count = countCallArguments(line, open_idx) orelse {
            start = method_idx + method_name.len;
            continue;
        };
        if (arg_count == expected_param_count and argumentsMatchParamSignature(
            line,
            open_idx,
            expected_param_signature,
            type_env,
            type_relations,
        )) {
            return true;
        }

        start = method_idx + method_name.len;
    }

    return false;
}

fn boundTypeMatchesOwner(
    bound_type_raw: []const u8,
    owner: []const u8,
    type_relations: *const TypeRelations,
) bool {
    const primary = extractPrimaryTypeName(bound_type_raw) orelse return false;
    return typeSatisfiesConstraint(owner, primary, type_relations);
}

fn extractPrimaryTypeName(type_raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_raw, " \t");
    if (trimmed.len == 0) return null;

    var end: usize = 0;
    while (end < trimmed.len) : (end += 1) {
        const c = trimmed[end];
        if (c == '<' or c == '[') break;
        if (!(isIdentChar(c) or c == '.')) break;
    }
    if (end == 0) return null;

    const qualified = trimmed[0..end];
    if (std.mem.lastIndexOfScalar(u8, qualified, '.')) |dot_idx| {
        if (dot_idx + 1 >= qualified.len) return null;
        return qualified[(dot_idx + 1)..];
    }
    return qualified;
}

fn typeSatisfiesConstraint(
    candidate_type: []const u8,
    expected_type: []const u8,
    type_relations: *const TypeRelations,
) bool {
    return typeSatisfiesConstraintDepth(candidate_type, expected_type, type_relations, 0);
}

fn typeSatisfiesConstraintDepth(
    candidate_type: []const u8,
    expected_type: []const u8,
    type_relations: *const TypeRelations,
    depth: u8,
) bool {
    if (depth > 24) return false;
    if (std.mem.eql(u8, candidate_type, expected_type)) return true;

    if (type_relations.extends_by_type.get(candidate_type)) |parent| {
        if (typeSatisfiesConstraintDepth(parent, expected_type, type_relations, depth + 1)) {
            return true;
        }
    }

    if (type_relations.interfaces_by_type.get(candidate_type)) |interfaces| {
        for (interfaces.items) |iface| {
            if (typeSatisfiesConstraintDepth(iface, expected_type, type_relations, depth + 1)) {
                return true;
            }
        }
    }

    return false;
}

fn countCallArguments(line: []const u8, open_paren_idx: usize) ?u16 {
    if (open_paren_idx >= line.len or line[open_paren_idx] != '(') return null;

    var count: u16 = 0;
    var has_token = false;
    var paren_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_single = false;
    var in_double = false;
    var i = open_paren_idx + 1;

    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (in_single) {
            if (c == '\'' and line[i - 1] != '\\') in_single = false;
            continue;
        }
        if (in_double) {
            if (c == '"' and line[i - 1] != '\\') in_double = false;
            continue;
        }

        switch (c) {
            '\'' => {
                in_single = true;
                has_token = true;
            },
            '"' => {
                in_double = true;
                has_token = true;
            },
            '(' => {
                paren_depth += 1;
                has_token = true;
            },
            ')' => {
                if (paren_depth == 0 and angle_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    if (has_token) count = satAddU16(count, 1);
                    return count;
                }
                if (paren_depth > 0) paren_depth -= 1;
            },
            '<' => {
                angle_depth += 1;
                has_token = true;
            },
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
                has_token = true;
            },
            '[' => {
                bracket_depth += 1;
                has_token = true;
            },
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
                has_token = true;
            },
            '{' => {
                brace_depth += 1;
                has_token = true;
            },
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
                has_token = true;
            },
            ',' => {
                if (paren_depth == 0 and angle_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    if (has_token) {
                        count = satAddU16(count, 1);
                        has_token = false;
                    }
                } else {
                    has_token = true;
                }
            },
            else => {
                if (!std.ascii.isWhitespace(c)) {
                    has_token = true;
                }
            },
        }
    }

    return null;
}

fn argumentsMatchParamSignature(
    line: []const u8,
    open_paren_idx: usize,
    expected_signature: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
) bool {
    if (open_paren_idx >= line.len or line[open_paren_idx] != '(') return false;

    var expected_iter = std.mem.splitScalar(u8, expected_signature, '|');
    var arg_start = open_paren_idx + 1;
    var paren_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_single = false;
    var in_double = false;

    var i = open_paren_idx + 1;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_single) {
            if (c == '\'' and line[i - 1] != '\\') in_single = false;
            continue;
        }
        if (in_double) {
            if (c == '"' and line[i - 1] != '\\') in_double = false;
            continue;
        }

        switch (c) {
            '\'' => {
                in_single = true;
            },
            '"' => {
                in_double = true;
            },
            '(' => {
                paren_depth += 1;
            },
            ')' => {
                if (paren_depth == 0 and angle_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    const segment = std.mem.trim(u8, line[arg_start..i], " \t");
                    if (segment.len == 0) {
                        return expected_signature.len == 0 or (expected_iter.next() == null and expected_signature.len == 0);
                    }
                    const expected = expected_iter.next() orelse return false;
                    if (!argumentExprMatchesType(segment, expected, type_env, type_relations)) return false;
                    return expected_iter.next() == null;
                }
                if (paren_depth > 0) paren_depth -= 1;
            },
            '<' => {
                angle_depth += 1;
            },
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '[' => {
                bracket_depth += 1;
            },
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => {
                brace_depth += 1;
            },
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            ',' => {
                if (paren_depth == 0 and angle_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    const segment = std.mem.trim(u8, line[arg_start..i], " \t");
                    const expected = expected_iter.next() orelse return false;
                    if (!argumentExprMatchesType(segment, expected, type_env, type_relations)) return false;
                    arg_start = i + 1;
                }
            },
            else => {},
        }
    }

    return false;
}

fn argumentExprMatchesType(
    expr_raw: []const u8,
    expected_type: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
) bool {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    if (expr.len == 0) return false;

    if (std.mem.eql(u8, expr, "null")) return true;
    if (std.mem.eql(u8, expr, "true") or std.mem.eql(u8, expr, "false")) {
        return std.mem.eql(u8, expected_type, "Boolean");
    }
    if ((expr[0] == '\'' and expr[expr.len - 1] == '\'') or (expr[0] == '"' and expr[expr.len - 1] == '"')) {
        return std.mem.eql(u8, expected_type, "String");
    }
    if (looksNumericLiteral(expr)) {
        if (std.mem.indexOfScalar(u8, expr, '.')) |_| {
            return std.mem.eql(u8, expected_type, "Decimal") or
                std.mem.eql(u8, expected_type, "Double");
        }
        return std.mem.eql(u8, expected_type, "Integer") or
            std.mem.eql(u8, expected_type, "Long");
    }
    if (std.mem.startsWith(u8, expr, "new ")) {
        const type_raw = extractTypeFromNewExpression(expr[4..]) orelse return true;
        return isTypeAssignable(type_raw, expected_type, type_relations);
    }

    if (extractRootIdentifier(expr)) |root| {
        if (type_env.get(root)) |bound_type| {
            if (isIndexedAccess(expr)) {
                if (!isPureIndexedAccess(expr)) return true;
                if (extractListElementType(bound_type)) |element_type| {
                    return isTypeAssignable(element_type, expected_type, type_relations);
                }
                return false;
            }
            if (isSimpleIdentifier(expr)) {
                return isTypeAssignable(bound_type, expected_type, type_relations);
            }
        }
    }

    // Unknown expression types (variables, field accesses, calls) stay permissive.
    return true;
}

fn extractRootIdentifier(expr_raw: []const u8) ?[]const u8 {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    if (expr.len == 0) return null;
    if (!isIdentStart(expr[0])) return null;
    var end: usize = 1;
    while (end < expr.len and isIdentChar(expr[end])) : (end += 1) {}
    return expr[0..end];
}

fn isSimpleIdentifier(expr_raw: []const u8) bool {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    const root = extractRootIdentifier(expr) orelse return false;
    return root.len == expr.len;
}

fn isIndexedAccess(expr_raw: []const u8) bool {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    return std.mem.indexOfScalar(u8, expr, '[') != null;
}

fn isPureIndexedAccess(expr_raw: []const u8) bool {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    const close_idx = std.mem.lastIndexOfScalar(u8, expr, ']') orelse return false;
    const tail = std.mem.trim(u8, expr[(close_idx + 1)..], " \t");
    return tail.len == 0;
}

fn extractListElementType(type_raw: []const u8) ?[]const u8 {
    const canonical = std.mem.trim(u8, type_raw, " \t");
    const list_idx = std.mem.indexOf(u8, canonical, "List<") orelse return null;
    const start = list_idx + 5;
    if (canonical.len <= start) return null;
    if (canonical[canonical.len - 1] != '>') return null;
    const inner = canonical[start .. canonical.len - 1];
    if (inner.len == 0) return null;
    return inner;
}

fn isTypeAssignable(
    actual_type_raw: []const u8,
    expected_type_raw: []const u8,
    type_relations: *const TypeRelations,
) bool {
    if (equalsCanonicalType(actual_type_raw, expected_type_raw)) return true;
    if (isGenericLikeType(actual_type_raw) or isGenericLikeType(expected_type_raw)) return false;

    const actual_primary = extractPrimaryTypeName(actual_type_raw) orelse return false;
    const expected_primary = extractPrimaryTypeName(expected_type_raw) orelse return false;
    return typeSatisfiesConstraint(actual_primary, expected_primary, type_relations);
}

fn isGenericLikeType(type_raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, type_raw, '<') != null or
        std.mem.indexOfScalar(u8, type_raw, '[') != null;
}

fn looksNumericLiteral(expr: []const u8) bool {
    if (expr.len == 0) return false;
    var i: usize = 0;
    if (expr[0] == '-' and expr.len > 1) i = 1;
    var has_digit = false;
    var dot_count: u8 = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (std.ascii.isDigit(c)) {
            has_digit = true;
            continue;
        }
        if (c == '.') {
            dot_count += 1;
            if (dot_count > 1) return false;
            continue;
        }
        return false;
    }
    return has_digit;
}
