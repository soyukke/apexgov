//! scanner — メイン解析ループ。
//!
//! 前処理済みソースを1行ずつ走査し、スコープ追跡・ループ検出・
//! Governor 制限パターンマッチング・メソッド呼び出しグラフ構築を
//! オーケストレーションする。`scanContent` が解析のエントリポイント。

const std = @import("std");
const model = @import("../model.zig");
const config = @import("../config.zig");
const types = @import("types.zig");
const utils = @import("utils.zig");
const preprocessor = @import("preprocessor.zig");
const detectors = @import("detectors.zig");
const scope_mod = @import("scope.zig");
const parser = @import("parser.zig");
const type_env_mod = @import("type_env.zig");
const bounds_mod = @import("bounds.zig");
const call_graph = @import("call_graph.zig");
const rules = @import("rules.zig");

const MethodSummary = types.MethodSummary;
const MethodScope = types.MethodScope;
const LoopScope = types.LoopScope;
const LoopInfo = types.LoopInfo;
const PendingLoopScopeStart = types.PendingLoopScopeStart;
const OwnerScope = types.OwnerScope;
const Bound = types.Bound;
const MethodMetrics = types.MethodMetrics;
const TypeRelations = types.TypeRelations;

const updateBraceDepth = utils.updateBraceDepth;
const satAdd = utils.satAdd;
const satMul = utils.satMul;

const stripCommentsPreserveLines = preprocessor.stripCommentsPreserveLines;
const collectDoWhileStartConditions = preprocessor.collectDoWhileStartConditions;
const isDoLoopStart = preprocessor.isDoLoopStart;

const popClosedScopes = scope_mod.popClosedScopes;
const popClosedOwners = scope_mod.popClosedOwners;
const maybeEnterOwnerScope = scope_mod.maybeEnterOwnerScope;

const parseMethodStart = parser.parseMethodStart;

const registerMethodParamTypes = type_env_mod.registerMethodParamTypes;
const applyLocalTypeUpdates = type_env_mod.applyLocalTypeUpdates;

const applyBoundUpdates = bounds_mod.applyBoundUpdates;
const inferLoopInfoAtLine = bounds_mod.inferLoopInfoAtLine;
const effectiveLoopUpperBound = bounds_mod.effectiveLoopUpperBound;

const ensureMethodSummary = call_graph.ensureMethodSummary;
const inferCalledMethodMetrics = call_graph.inferCalledMethodMetrics;

const appendFinding = rules.appendFinding;
const appendGovernorFinding = rules.appendGovernorFinding;
const appendCpuEstimateFinding = rules.appendCpuEstimateFinding;

pub fn scanContent(
    gpa: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    cfg: config.Config,
    method_summaries: *std.StringHashMap(MethodSummary),
    type_relations: *const TypeRelations,
    findings: *std.ArrayList(model.Finding),
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var bounds = std.StringHashMap(Bound).init(arena_allocator);
    var type_env = std.StringHashMap([]const u8).init(arena_allocator);
    var current_method: ?MethodScope = null;
    var do_while_conditions = try collectDoWhileStartConditions(arena_allocator, content);
    const stripped_content = try stripCommentsPreserveLines(arena_allocator, content);

    var loop_scopes: std.ArrayList(LoopScope) = .empty;
    defer loop_scopes.deinit(gpa);
    var pending_loop_scope: ?PendingLoopScopeStart = null;
    var owner_scopes: std.ArrayList(OwnerScope) = .empty;
    defer owner_scopes.deinit(gpa);

    var brace_depth: i32 = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');

    while (lines.next()) |raw| {
        line_no += 1;

        popClosedScopes(&loop_scopes, brace_depth);
        popClosedOwners(&owner_scopes, brace_depth);

        const code_line = raw;
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        var started_method = false;
        if (trimmed.len > 0) {
            try maybeEnterOwnerScope(gpa, &owner_scopes, brace_depth, trimmed);
            if (current_method == null and owner_scopes.items.len > 0) {
                const owner = owner_scopes.items[owner_scopes.items.len - 1].name;
                if (parseMethodStart(trimmed)) |decl| {
                    const summary = try ensureMethodSummary(
                        arena_allocator,
                        method_summaries,
                        owner,
                        decl.name,
                        decl.params_raw,
                    );
                    type_env = std.StringHashMap([]const u8).init(arena_allocator);
                    try registerMethodParamTypes(arena_allocator, &type_env, decl.params_raw);
                    current_method = .{
                        .owner = owner,
                        .name = summary.name,
                        .param_count = summary.param_count,
                        .param_signature = summary.param_signature,
                        .end_depth = brace_depth + 1,
                        .entered_body = std.mem.indexOfScalar(u8, trimmed, '{') != null,
                    };
                    started_method = true;
                }
            }
            if (!started_method and current_method != null) {
                try applyLocalTypeUpdates(arena_allocator, &type_env, trimmed);
            }
        }
        const current_owner = if (owner_scopes.items.len == 0) null else owner_scopes.items[owner_scopes.items.len - 1].name;
        if (trimmed.len == 0) {
            brace_depth = updateBraceDepth(brace_depth, code_line);
            popClosedScopes(&loop_scopes, brace_depth);
            popClosedOwners(&owner_scopes, brace_depth);
            if (pending_loop_scope) |pending| {
                if (brace_depth < pending.expected_depth) pending_loop_scope = null;
            }
            if (current_method) |*scope| {
                if (!scope.entered_body and brace_depth >= scope.end_depth) {
                    scope.entered_body = true;
                }
                if (scope.entered_body and brace_depth < scope.end_depth) {
                    current_method = null;
                    type_env = std.StringHashMap([]const u8).init(arena_allocator);
                }
            }
            continue;
        }

        if (pending_loop_scope) |pending| {
            if (trimmed[0] == '{' and brace_depth == pending.expected_depth) {
                try loop_scopes.append(gpa, .{
                    .end_depth = brace_depth + 1,
                    .max_iterations = pending.max_iterations,
                });
            }
            pending_loop_scope = null;
        }

        try applyBoundUpdates(arena_allocator, &bounds, trimmed);

        const loop_info = inferLoopInfoAtLine(trimmed, &bounds, &do_while_conditions, line_no);
        const loop_started = loop_info != null;
        const loop_level = loop_scopes.items.len;
        const in_loop = loop_started or loop_level > 0;
        const loop_upper_bound = effectiveLoopUpperBound(loop_scopes.items, loop_info);
        const call_metrics = if (in_loop)
            inferCalledMethodMetrics(trimmed, current_owner, &type_env, method_summaries, type_relations)
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
            if (detectors.containsSoql(trimmed)) @as(u64, 1) else @as(u64, 0),
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
                soql_count,
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
            if (detectors.containsDml(trimmed)) @as(u64, 1) else @as(u64, 0),
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
                dml_count,
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

        const sosl_count = satAdd(
            if (detectors.containsSosl(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.sosl,
        );
        if (in_loop and sosl_count > 0) {
            try appendGovernorFinding(
                gpa,
                findings,
                path,
                line_no,
                .sosl,
                loop_upper_bound,
                sosl_count,
            );
            try appendCpuEstimateFinding(
                gpa,
                findings,
                path,
                line_no,
                "SOSL",
                satMul(cfg.cpu_model.soql_ms, sosl_count),
                loop_upper_bound,
                cfg.cpu_model.base_ms,
            );
        }

        const callout_count = satAdd(
            if (detectors.containsCallout(trimmed, &type_env)) @as(u64, 1) else @as(u64, 0),
            call_metrics.callout,
        );
        if (in_loop and callout_count > 0) {
            try appendGovernorFinding(
                gpa,
                findings,
                path,
                line_no,
                .callout,
                loop_upper_bound,
                callout_count,
            );
        }

        const messaging_count = satAdd(
            if (detectors.containsMessaging(trimmed)) @as(u64, 1) else @as(u64, 0),
            call_metrics.messaging,
        );
        if (in_loop and messaging_count > 0) {
            try appendGovernorFinding(
                gpa,
                findings,
                path,
                line_no,
                .messaging,
                loop_upper_bound,
                messaging_count,
            );
        }

        const json_count = satAdd(
            if (detectors.containsJsonWork(trimmed)) @as(u64, 1) else @as(u64, 0),
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
            if (detectors.containsCloneWork(trimmed)) @as(u64, 1) else @as(u64, 0),
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
            if (detectors.containsCollectionAlloc(trimmed)) @as(u64, 1) else @as(u64, 0),
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
            if (detectors.containsStringAppend(trimmed)) @as(u64, 1) else @as(u64, 0),
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
        } else if (loop_started and isDoLoopStart(trimmed)) {
            pending_loop_scope = .{
                .expected_depth = brace_depth,
                .max_iterations = loop_info.?.max_iterations,
            };
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        popClosedScopes(&loop_scopes, brace_depth);
        popClosedOwners(&owner_scopes, brace_depth);
        if (pending_loop_scope) |pending| {
            if (brace_depth < pending.expected_depth) pending_loop_scope = null;
        }
        if (current_method) |*scope| {
            if (!scope.entered_body and brace_depth >= scope.end_depth) {
                scope.entered_body = true;
            }
            if (scope.entered_body and brace_depth < scope.end_depth) {
                current_method = null;
                type_env = std.StringHashMap([]const u8).init(arena_allocator);
            }
        }
    }
}
