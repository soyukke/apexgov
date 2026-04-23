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
const MethodCall = types.MethodCall;
const MethodMetrics = types.MethodMetrics;
const OwnerScope = types.OwnerScope;
const TypeRelations = types.TypeRelations;
const LoopScope = types.LoopScope;
const PendingLoopScopeStart = types.PendingLoopScopeStart;
const Bound = types.Bound;
const ApexFile = types.ApexFile;
const MethodIndexEntry = types.MethodIndexEntry;
const MethodNameIndex = types.MethodNameIndex;
const is_ident_char = utils.is_ident_char;
const is_ident_start = utils.is_ident_start;
const sat_add = utils.sat_add;
const sat_add_u16 = utils.sat_add_u16;
const equals_canonical_type = utils.equals_canonical_type;
const extract_type_from_new_expression = utils.extract_type_from_new_expression;
const parse_method_start = parser.parse_method_start;
const build_param_type_signature = parser.build_param_type_signature;
const count_signature_params = parser.count_signature_params;
const register_type_decl = parser.register_type_decl;
const parse_type_decl = parser.parse_type_decl;
const maybe_enter_owner_scope = scope_mod.maybe_enter_owner_scope;
const pop_closed_owners = scope_mod.pop_closed_owners;
const pop_closed_scopes = scope_mod.pop_closed_scopes;
const update_brace_depth = utils.update_brace_depth;
const register_method_param_types = type_env_mod.register_method_param_types;
const apply_local_type_updates = type_env_mod.apply_local_type_updates;
const apply_bound_updates = bounds_mod.apply_bound_updates;
const infer_loop_info_at_line = bounds_mod.infer_loop_info_at_line;
const effective_loop_upper_bound = bounds_mod.effective_loop_upper_bound;
const collect_do_while_start_conditions = preprocessor.collect_do_while_start_conditions;
const collect_do_while_start_conditions_from_stripped = preprocessor.collect_do_while_start_conditions_from_stripped;
const is_do_loop_start = preprocessor.is_do_loop_start;

pub const BuildResult = struct {
    summaries: std.StringHashMap(MethodSummary),
    name_index: MethodNameIndex,
};

pub fn build_method_summaries(
    arena_allocator: std.mem.Allocator,
    files: []const ApexFile,
    type_relations: *const TypeRelations,
) !BuildResult {
    var summaries = std.StringHashMap(MethodSummary).init(arena_allocator);

    for (files) |file| {
        try collect_method_names(arena_allocator, file.stripped_content, &summaries);
    }

    // Phase 3a 完了後にインデックス構築（Phase 3b で使用）
    var name_index = try build_method_name_index(arena_allocator, &summaries);

    for (files) |file| {
        try collect_method_direct_metrics_and_calls(arena_allocator, file.stripped_content, &summaries, &name_index, type_relations);
    }

    // Phase 3b で新たに追加されたサマリーがあればインデックスを再構築
    name_index = try build_method_name_index(arena_allocator, &summaries);

    var keys: std.ArrayList([]const u8) = .empty;
    var it = summaries.iterator();
    while (it.next()) |entry| {
        try keys.append(arena_allocator, entry.key_ptr.*);
    }
    for (keys.items) |name| {
        _ = resolve_method_total(&summaries, name);
    }

    return .{ .summaries = summaries, .name_index = name_index };
}

fn build_method_name_index(
    arena_allocator: std.mem.Allocator,
    summaries: *std.StringHashMap(MethodSummary),
) !MethodNameIndex {
    var index = MethodNameIndex.init(arena_allocator);
    var it = summaries.iterator();
    while (it.next()) |entry| {
        const name = entry.value_ptr.name;
        const gop = try index.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(arena_allocator, .{
            .key = entry.key_ptr.*,
            .summary = entry.value_ptr,
        });
    }
    return index;
}

pub fn collect_type_relations(
    arena_allocator: std.mem.Allocator,
    files: []const ApexFile,
) !TypeRelations {
    var relations = TypeRelations{
        .extends_by_type = std.StringHashMap([]const u8).init(arena_allocator),
        .interfaces_by_type = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(arena_allocator),
    };

    for (files) |file| {
        try collect_type_relations_from_content(arena_allocator, file.stripped_content, &relations);
    }

    return relations;
}

fn collect_type_relations_from_content(
    arena_allocator: std.mem.Allocator,
    stripped_content: []const u8,
    relations: *TypeRelations,
) !void {
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        const decl = parse_type_decl(trimmed) orelse continue;
        try register_type_decl(arena_allocator, relations, decl);
    }
}

fn collect_method_names(
    arena_allocator: std.mem.Allocator,
    stripped_content: []const u8,
    summaries: *std.StringHashMap(MethodSummary),
) !void {
    var owner_scopes: std.ArrayList(OwnerScope) = .empty;
    defer owner_scopes.deinit(arena_allocator);

    var brace_depth: i32 = 0;
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');
    while (lines.next()) |raw| {
        const code_line = raw;
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        pop_closed_owners(&owner_scopes, brace_depth);

        if (trimmed.len > 0) {
            try maybe_enter_owner_scope(arena_allocator, &owner_scopes, brace_depth, trimmed);
            if (owner_scopes.items.len > 0) {
                const owner = owner_scopes.items[owner_scopes.items.len - 1].name;
                if (parse_method_start(trimmed)) |decl| {
                    _ = try ensure_method_summary(arena_allocator, summaries, owner, decl.name, decl.params_raw);
                }
            }
        }

        brace_depth = update_brace_depth(brace_depth, code_line);
        pop_closed_owners(&owner_scopes, brace_depth);
    }
}

fn collect_method_direct_metrics_and_calls(
    arena_allocator: std.mem.Allocator,
    stripped_content: []const u8,
    summaries: *std.StringHashMap(MethodSummary),
    name_index: *const MethodNameIndex,
    type_relations: *const TypeRelations,
) !void {
    var owner_scopes: std.ArrayList(OwnerScope) = .empty;
    defer owner_scopes.deinit(arena_allocator);

    var method_loop_scopes: std.ArrayList(LoopScope) = .empty;
    defer method_loop_scopes.deinit(arena_allocator);

    var pending_method_loop_scope: ?PendingLoopScopeStart = null;

    var method_bounds = std.StringHashMap(Bound).init(arena_allocator);
    var type_env = std.StringHashMap([]const u8).init(arena_allocator);
    var do_while_conditions = try collect_do_while_start_conditions_from_stripped(arena_allocator, stripped_content);

    var brace_depth: i32 = 0;
    var current_method: ?MethodScope = null;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');

    while (lines.next()) |raw| {
        line_no += 1;
        const code_line = raw;
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        pop_closed_owners(&owner_scopes, brace_depth);

        var started_method = false;
        if (trimmed.len > 0) {
            try maybe_enter_owner_scope(arena_allocator, &owner_scopes, brace_depth, trimmed);
            const owner = if (owner_scopes.items.len == 0) null else owner_scopes.items[owner_scopes.items.len - 1].name;

            if (current_method == null and owner != null) {
                if (parse_method_start(trimmed)) |decl| {
                    const summary = try ensure_method_summary(
                        arena_allocator,
                        summaries,
                        owner.?,
                        decl.name,
                        decl.params_raw,
                    );
                    method_loop_scopes.clearRetainingCapacity();
                    method_bounds = std.StringHashMap(Bound).init(arena_allocator);
                    type_env = std.StringHashMap([]const u8).init(arena_allocator);
                    try register_method_param_types(arena_allocator, &type_env, decl.params_raw);
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
                    pop_closed_scopes(&method_loop_scopes, brace_depth);
                    if (pending_method_loop_scope) |pending| {
                        if (trimmed[0] == '{' and brace_depth == pending.expected_depth) {
                            try method_loop_scopes.append(arena_allocator, .{
                                .end_depth = brace_depth + 1,
                                .max_iterations = pending.max_iterations,
                            });
                        }
                        pending_method_loop_scope = null;
                    }
                    try apply_bound_updates(arena_allocator, &method_bounds, trimmed);
                    try apply_local_type_updates(arena_allocator, &type_env, trimmed);
                    const local_loop_info = infer_loop_info_at_line(
                        trimmed,
                        &method_bounds,
                        &do_while_conditions,
                        line_no,
                    );
                    const local_loop_multiplier = effective_loop_upper_bound(method_loop_scopes.items, local_loop_info) orelse 1;

                    const summary = find_method_summary_by_owner_name_signature(
                        summaries,
                        scope.owner,
                        scope.name,
                        scope.param_signature,
                    ) orelse unreachable;
                    apply_direct_line_metrics(&summary.direct, trimmed, local_loop_multiplier, &type_env);
                    try record_called_methods(
                        arena_allocator,
                        &summary.calls,
                        name_index,
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
                    } else if (local_loop_info != null and is_do_loop_start(trimmed)) {
                        pending_method_loop_scope = .{
                            .expected_depth = brace_depth,
                            .max_iterations = local_loop_info.?.max_iterations,
                        };
                    }
                }
            }
        }

        brace_depth = update_brace_depth(brace_depth, code_line);
        if (pending_method_loop_scope) |pending| {
            if (brace_depth < pending.expected_depth) pending_method_loop_scope = null;
        }
        if (current_method) |*scope| {
            pop_closed_scopes(&method_loop_scopes, brace_depth);
            if (!scope.entered_body and brace_depth >= scope.end_depth) {
                scope.entered_body = true;
            }
            if (scope.entered_body and brace_depth < scope.end_depth) {
                current_method = null;
                type_env = std.StringHashMap([]const u8).init(arena_allocator);
                pending_method_loop_scope = null;
            }
        }
        pop_closed_owners(&owner_scopes, brace_depth);
    }
}

pub fn ensure_method_summary(
    arena_allocator: std.mem.Allocator,
    summaries: *std.StringHashMap(MethodSummary),
    owner: []const u8,
    name: []const u8,
    params_raw: []const u8,
) !*MethodSummary {
    const param_signature = try build_param_type_signature(arena_allocator, params_raw);
    const param_count = count_signature_params(param_signature);
    if (find_method_summary_by_owner_name_signature(summaries, owner, name, param_signature)) |existing| return existing;

    const owner_copy = try arena_allocator.dupe(u8, owner);
    const name_copy = try arena_allocator.dupe(u8, name);
    const signature_copy = try arena_allocator.dupe(u8, param_signature);
    const key = try format_method_key(arena_allocator, owner_copy, name_copy, signature_copy);
    try summaries.put(key, .{
        .owner = owner_copy,
        .name = name_copy,
        .param_count = param_count,
        .param_signature = signature_copy,
    });
    return summaries.getPtr(key).?;
}

fn find_method_summary_by_owner_name_signature(
    summaries: *std.StringHashMap(MethodSummary),
    owner: []const u8,
    name: []const u8,
    param_signature: []const u8,
) ?*MethodSummary {
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}.{s}/{s}", .{ owner, name, param_signature }) catch return null;
    return summaries.getPtr(key);
}

fn format_method_key(
    arena_allocator: std.mem.Allocator,
    owner: []const u8,
    name: []const u8,
    param_signature: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(arena_allocator, "{s}.{s}/{s}", .{ owner, name, param_signature });
}

fn resolve_method_total(summaries: *std.StringHashMap(MethodSummary), name: []const u8) MethodMetrics {
    const summary = summaries.getPtr(name) orelse return .{};
    switch (summary.state) {
        .resolved => return summary.total,
        .resolving => return summary.direct,
        .unresolved => {},
    }

    summary.state = .resolving;
    var total = summary.direct;
    for (summary.calls.items) |call| {
        const callee_total = resolve_method_total(summaries, call.callee_key);
        total.add_scaled(callee_total, call.multiplier);
    }
    summary.total = total;
    summary.state = .resolved;
    return total;
}

fn apply_direct_line_metrics(
    metrics: *MethodMetrics,
    line: []const u8,
    multiplier: u64,
    type_env: *std.StringHashMap([]const u8),
) void {
    const weight = if (multiplier == 0) @as(u64, 1) else multiplier;
    if (detectors.contains_soql(line)) metrics.soql = sat_add(metrics.soql, weight);
    if (detectors.contains_dml(line)) metrics.dml = sat_add(metrics.dml, weight);
    if (detectors.contains_sosl(line)) metrics.sosl = sat_add(metrics.sosl, weight);
    if (detectors.contains_callout(line, type_env)) metrics.callout = sat_add(metrics.callout, weight);
    if (detectors.contains_messaging(line)) metrics.messaging = sat_add(metrics.messaging, weight);
    if (detectors.contains_json_work(line)) metrics.json = sat_add(metrics.json, weight);
    if (detectors.contains_clone_work(line)) metrics.clone = sat_add(metrics.clone, weight);
    if (detectors.contains_collection_alloc(line)) metrics.collection_alloc = sat_add(metrics.collection_alloc, weight);
    if (detectors.contains_string_append(line)) metrics.string_append = sat_add(metrics.string_append, weight);
}

fn record_called_methods(
    arena_allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged(MethodCall),
    name_index: *const MethodNameIndex,
    caller_owner: []const u8,
    caller_name: []const u8,
    line: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
    multiplier: u64,
) !void {
    // 早期リターン: '(' がなければメソッド呼び出しは不可能
    if (std.mem.indexOfScalar(u8, line, '(') == null) return;

    // 行内の識別子候補を抽出し、逆引きインデックスで候補を絞る
    var candidates = extract_call_candidates(line);
    for (candidates.slice()) |candidate_name| {
        const entries = name_index.get(candidate_name) orelse continue;
        for (entries.items) |ie| {
            const callee = ie.summary.*;
            if (std.mem.eql(u8, callee.owner, caller_owner) and std.mem.eql(u8, callee.name, caller_name)) continue;
            if (!line_calls_method(
                line,
                caller_owner,
                callee.owner,
                callee.name,
                callee.param_count,
                callee.param_signature,
                type_env,
                type_relations,
            )) continue;
            try append_or_accumulate_call(arena_allocator, calls, ie.key, multiplier);
        }
    }
}

fn append_or_accumulate_call(
    arena_allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged(MethodCall),
    callee_key: []const u8,
    multiplier: u64,
) !void {
    const weight = if (multiplier == 0) @as(u64, 1) else multiplier;
    for (calls.items) |*existing| {
        if (!std.mem.eql(u8, existing.callee_key, callee_key)) continue;
        existing.multiplier = sat_add(existing.multiplier, weight);
        return;
    }
    try calls.append(arena_allocator, .{
        .callee_key = callee_key,
        .multiplier = weight,
    });
}

pub fn infer_called_method_metrics(
    line: []const u8,
    current_owner: ?[]const u8,
    type_env: *std.StringHashMap([]const u8),
    name_index: *const MethodNameIndex,
    type_relations: *const TypeRelations,
) MethodMetrics {
    var metrics: MethodMetrics = .{};
    // 早期リターン: '(' がなければメソッド呼び出しは不可能
    if (std.mem.indexOfScalar(u8, line, '(') == null) return metrics;

    var candidates = extract_call_candidates(line);
    for (candidates.slice()) |candidate_name| {
        const entries = name_index.get(candidate_name) orelse continue;
        for (entries.items) |ie| {
            const callee = ie.summary.*;
            if (!line_calls_method(
                line,
                current_owner orelse "",
                callee.owner,
                callee.name,
                callee.param_count,
                callee.param_signature,
                type_env,
                type_relations,
            )) continue;
            metrics.add(ie.summary.total);
        }
    }
    return metrics;
}

const MAX_CANDIDATES = 24;

const CallCandidates = struct {
    items: [MAX_CANDIDATES][]const u8 = undefined,
    len: usize = 0,

    fn slice(self: *CallCandidates) []const []const u8 {
        return self.items[0..self.len];
    }

    fn add(self: *CallCandidates, name: []const u8) void {
        // 重複チェック
        for (self.items[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        if (self.len < MAX_CANDIDATES) {
            self.items[self.len] = name;
            self.len += 1;
        }
    }
};

/// 行内の `ident(` パターンからメソッド呼び出し候補名を抽出する。
/// ドット付きの `receiver.method(` の場合は method 部分を返す。
fn extract_call_candidates(line: []const u8) CallCandidates {
    var result = CallCandidates{};
    var i: usize = 0;
    while (i < line.len) {
        // 識別子の開始を探す
        if (!is_ident_start(line[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < line.len and is_ident_char(line[i])) : (i += 1) {}
        const ident = line[start..i];

        // 空白をスキップ
        var j = i;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}

        if (j < line.len and line[j] == '(') {
            // ident( パターン → メソッド呼び出し候補
            result.add(ident);
        } else if (j < line.len and line[j] == '.') {
            // ident. パターン → 次の識別子がメソッド名かもしれない
            // ident 自体はスキップ（receiver）
            i = j + 1;
        }
    }
    return result;
}

fn line_calls_method(
    line: []const u8,
    caller_owner: []const u8,
    callee_owner: []const u8,
    callee_name: []const u8,
    callee_param_count: u16,
    callee_param_signature: []const u8,
    type_env: *std.StringHashMap([]const u8),
    type_relations: *const TypeRelations,
) bool {
    if (contains_qualified_method_call(
        line,
        callee_owner,
        callee_name,
        callee_param_count,
        callee_param_signature,
        type_env,
        type_relations,
    )) return true;
    if (std.mem.eql(u8, caller_owner, callee_owner) and contains_bare_method_call(
        line,
        callee_name,
        callee_param_count,
        callee_param_signature,
        type_env,
        type_relations,
    )) return true;
    if (std.mem.eql(u8, caller_owner, callee_owner) and contains_qualified_method_call(
        line,
        "this",
        callee_name,
        callee_param_count,
        callee_param_signature,
        type_env,
        type_relations,
    )) return true;
    if (contains_typed_receiver_method_call(
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

fn contains_bare_method_call(
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
        const before_ok = idx == 0 or (!is_ident_char(line[idx - 1]) and line[idx - 1] != '.');
        var end = idx + method_name.len;
        while (end < line.len and (line[end] == ' ' or line[end] == '\t')) : (end += 1) {}
        const after_ok = end < line.len and line[end] == '(';
        if (before_ok and after_ok) {
            const arg_count = count_call_arguments(line, end) orelse {
                start = idx + method_name.len;
                continue;
            };
            if (arg_count == expected_param_count and arguments_match_param_signature(
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

fn contains_qualified_method_call(
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
        const owner_before_ok = owner_idx == 0 or !is_ident_char(line[owner_idx - 1]);
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
            const arg_count = count_call_arguments(line, open_idx) orelse {
                start = owner_idx + owner.len;
                continue;
            };
            if (arg_count == expected_param_count and arguments_match_param_signature(
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

fn contains_typed_receiver_method_call(
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
        const method_before_ok = method_idx == 0 or !is_ident_char(line[method_idx - 1]);
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
        while (receiver_start > 0 and is_ident_char(line[receiver_start - 1])) : (receiver_start -= 1) {}
        if (receiver_start == receiver_end) {
            start = method_idx + method_name.len;
            continue;
        }
        const receiver = line[receiver_start..receiver_end];

        const bound_type = type_env.get(receiver) orelse {
            start = method_idx + method_name.len;
            continue;
        };
        if (!bound_type_matches_owner(bound_type, callee_owner, type_relations)) {
            start = method_idx + method_name.len;
            continue;
        }

        var open_idx = method_idx + method_name.len;
        while (open_idx < line.len and (line[open_idx] == ' ' or line[open_idx] == '\t')) : (open_idx += 1) {}
        if (open_idx >= line.len or line[open_idx] != '(') {
            start = method_idx + method_name.len;
            continue;
        }

        const arg_count = count_call_arguments(line, open_idx) orelse {
            start = method_idx + method_name.len;
            continue;
        };
        if (arg_count == expected_param_count and arguments_match_param_signature(
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

fn bound_type_matches_owner(
    bound_type_raw: []const u8,
    owner: []const u8,
    type_relations: *const TypeRelations,
) bool {
    const primary = extract_primary_type_name(bound_type_raw) orelse return false;
    return type_satisfies_constraint(owner, primary, type_relations);
}

fn extract_primary_type_name(type_raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_raw, " \t");
    if (trimmed.len == 0) return null;

    var end: usize = 0;
    while (end < trimmed.len) : (end += 1) {
        const c = trimmed[end];
        if (c == '<' or c == '[') break;
        if (!(is_ident_char(c) or c == '.')) break;
    }
    if (end == 0) return null;

    const qualified = trimmed[0..end];
    if (std.mem.lastIndexOfScalar(u8, qualified, '.')) |dot_idx| {
        if (dot_idx + 1 >= qualified.len) return null;
        return qualified[(dot_idx + 1)..];
    }
    return qualified;
}

fn type_satisfies_constraint(
    candidate_type: []const u8,
    expected_type: []const u8,
    type_relations: *const TypeRelations,
) bool {
    return type_satisfies_constraint_depth(candidate_type, expected_type, type_relations, 0);
}

fn type_satisfies_constraint_depth(
    candidate_type: []const u8,
    expected_type: []const u8,
    type_relations: *const TypeRelations,
    depth: u8,
) bool {
    if (depth > 24) return false;
    if (std.mem.eql(u8, candidate_type, expected_type)) return true;

    if (type_relations.extends_by_type.get(candidate_type)) |parent| {
        if (type_satisfies_constraint_depth(parent, expected_type, type_relations, depth + 1)) {
            return true;
        }
    }

    if (type_relations.interfaces_by_type.get(candidate_type)) |interfaces| {
        for (interfaces.items) |iface| {
            if (type_satisfies_constraint_depth(iface, expected_type, type_relations, depth + 1)) {
                return true;
            }
        }
    }

    return false;
}

fn count_call_arguments(line: []const u8, open_paren_idx: usize) ?u16 {
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
                    if (has_token) count = sat_add_u16(count, 1);
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
                        count = sat_add_u16(count, 1);
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

fn arguments_match_param_signature(
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
                    if (!argument_expr_matches_type(segment, expected, type_env, type_relations)) return false;
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
                    if (!argument_expr_matches_type(segment, expected, type_env, type_relations)) return false;
                    arg_start = i + 1;
                }
            },
            else => {},
        }
    }

    return false;
}

fn argument_expr_matches_type(
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
    if (looks_numeric_literal(expr)) {
        if (std.mem.indexOfScalar(u8, expr, '.')) |_| {
            return std.mem.eql(u8, expected_type, "Decimal") or
                std.mem.eql(u8, expected_type, "Double");
        }
        return std.mem.eql(u8, expected_type, "Integer") or
            std.mem.eql(u8, expected_type, "Long");
    }
    if (std.mem.startsWith(u8, expr, "new ")) {
        const type_raw = extract_type_from_new_expression(expr[4..]) orelse return true;
        return is_type_assignable(type_raw, expected_type, type_relations);
    }

    if (extract_root_identifier(expr)) |root| {
        if (type_env.get(root)) |bound_type| {
            if (is_indexed_access(expr)) {
                if (!is_pure_indexed_access(expr)) return true;
                if (extract_list_element_type(bound_type)) |element_type| {
                    return is_type_assignable(element_type, expected_type, type_relations);
                }
                return false;
            }
            if (is_simple_identifier(expr)) {
                return is_type_assignable(bound_type, expected_type, type_relations);
            }
        }
    }

    // Unknown expression types (variables, field accesses, calls) stay permissive.
    return true;
}

fn extract_root_identifier(expr_raw: []const u8) ?[]const u8 {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    if (expr.len == 0) return null;
    if (!is_ident_start(expr[0])) return null;
    var end: usize = 1;
    while (end < expr.len and is_ident_char(expr[end])) : (end += 1) {}
    return expr[0..end];
}

fn is_simple_identifier(expr_raw: []const u8) bool {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    const root = extract_root_identifier(expr) orelse return false;
    return root.len == expr.len;
}

fn is_indexed_access(expr_raw: []const u8) bool {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    return std.mem.indexOfScalar(u8, expr, '[') != null;
}

fn is_pure_indexed_access(expr_raw: []const u8) bool {
    const expr = std.mem.trim(u8, expr_raw, " \t");
    const close_idx = std.mem.lastIndexOfScalar(u8, expr, ']') orelse return false;
    const tail = std.mem.trim(u8, expr[(close_idx + 1)..], " \t");
    return tail.len == 0;
}

fn extract_list_element_type(type_raw: []const u8) ?[]const u8 {
    const canonical = std.mem.trim(u8, type_raw, " \t");
    const list_idx = std.mem.indexOf(u8, canonical, "List<") orelse return null;
    const start = list_idx + 5;
    if (canonical.len <= start) return null;
    if (canonical[canonical.len - 1] != '>') return null;
    const inner = canonical[start .. canonical.len - 1];
    if (inner.len == 0) return null;
    return inner;
}

fn is_type_assignable(
    actual_type_raw: []const u8,
    expected_type_raw: []const u8,
    type_relations: *const TypeRelations,
) bool {
    if (equals_canonical_type(actual_type_raw, expected_type_raw)) return true;
    if (is_generic_like_type(actual_type_raw) or is_generic_like_type(expected_type_raw)) return false;

    const actual_primary = extract_primary_type_name(actual_type_raw) orelse return false;
    const expected_primary = extract_primary_type_name(expected_type_raw) orelse return false;
    return type_satisfies_constraint(actual_primary, expected_primary, type_relations);
}

fn is_generic_like_type(type_raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, type_raw, '<') != null or
        std.mem.indexOfScalar(u8, type_raw, '[') != null;
}

fn looks_numeric_literal(expr: []const u8) bool {
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
