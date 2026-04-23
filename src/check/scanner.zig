//! scanner — メイン解析ループ。
//!
//! 前処理済みソースを1行ずつ走査し、スコープ追跡・ループ検出・
//! Governor 制限パターンマッチング・メソッド呼び出しグラフ構築を
//! オーケストレーションする。`scan_content` が解析のエントリポイント。

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
const PendingLoopScopeStart = types.PendingLoopScopeStart;
const OwnerScope = types.OwnerScope;
const Bound = types.Bound;
const MethodMetrics = types.MethodMetrics;
const TypeRelations = types.TypeRelations;

const update_brace_depth = utils.update_brace_depth;
const sat_add = utils.sat_add;
const sat_mul = utils.sat_mul;

const collect_do_while_start_conditions_from_stripped = preprocessor.collect_do_while_start_conditions_from_stripped;
const is_do_loop_start = preprocessor.is_do_loop_start;

const pop_closed_scopes = scope_mod.pop_closed_scopes;
const pop_closed_owners = scope_mod.pop_closed_owners;
const maybe_enter_owner_scope = scope_mod.maybe_enter_owner_scope;

const parse_method_start = parser.parse_method_start;

const register_method_param_types = type_env_mod.register_method_param_types;
const apply_local_type_updates = type_env_mod.apply_local_type_updates;

const apply_bound_updates = bounds_mod.apply_bound_updates;
const infer_loop_info_at_line = bounds_mod.infer_loop_info_at_line;
const effective_loop_upper_bound = bounds_mod.effective_loop_upper_bound;

const ensure_method_summary = call_graph.ensure_method_summary;
const infer_called_method_metrics = call_graph.infer_called_method_metrics;

const append_finding = rules.append_finding;
const append_governor_finding = rules.append_governor_finding;
const append_cpu_estimate_finding = rules.append_cpu_estimate_finding;

// ---------------------------------------------------------------------------
// ルール検出テーブル
// ---------------------------------------------------------------------------

/// ルール検出時の Finding 出力種別。
const EmitKind = enum {
    /// Governor 制限 Finding + CPU 見積もり Finding (AG002/AG003/AG008)
    governor_with_cpu,
    /// Governor 制限 Finding のみ (AG010/AG011)
    governor_only,
    /// 一般 Finding + CPU 見積もり Finding (AG004/AG005)
    finding_with_cpu,
    /// 一般 Finding のみ (AG006/AG007)
    finding_only,
};

/// テーブル駆動ルール検出の仕様。
/// `field` は MethodMetrics のフィールド名（comptime）で、`@field` によるアクセスに使用。
/// `cpu_cost_field` は CpuModel のフィールド名（comptime）。
const RuleSpec = struct {
    field: []const u8,
    emit: EmitKind,
    // Governor ルール用
    gov_kind: rules.GovernorKind = .soql,
    // 一般 Finding 用
    rule_id: []const u8 = "",
    title: []const u8 = "",
    message: []const u8 = "",
    severity: model.Severity = .warning,
    category: []const u8 = "",
    // CPU 見積もり用
    cpu_label: []const u8 = "",
    cpu_cost_field: []const u8 = "soql_ms",
};

/// AG002–AG011 のルール仕様テーブル（AG001 はネストループ検出で別処理）。
const rule_specs = [_]RuleSpec{
    // Governor + CPU estimate
    .{ .field = "soql", .emit = .governor_with_cpu, .gov_kind = .soql, .cpu_label = "SOQL", .cpu_cost_field = "soql_ms" },
    .{ .field = "dml", .emit = .governor_with_cpu, .gov_kind = .dml, .cpu_label = "DML", .cpu_cost_field = "dml_ms" },
    .{ .field = "sosl", .emit = .governor_with_cpu, .gov_kind = .sosl, .cpu_label = "SOSL", .cpu_cost_field = "soql_ms" },
    // Governor only
    .{ .field = "callout", .emit = .governor_only, .gov_kind = .callout },
    .{ .field = "messaging", .emit = .governor_only, .gov_kind = .messaging },
    // Finding + CPU estimate
    .{ .field = "json", .emit = .finding_with_cpu, .rule_id = "AG004", .title = "JSON processing inside loop", .message = "Serialize/deserialize outside loops where possible.", .severity = .warning, .category = "cpu", .cpu_label = "JSON", .cpu_cost_field = "json_ms" },
    .{ .field = "clone", .emit = .finding_with_cpu, .rule_id = "AG005", .title = "Clone/deepClone inside loop", .message = "Repeated cloning can increase heap and CPU cost.", .severity = .warning, .category = "heap", .cpu_label = "clone/deepClone", .cpu_cost_field = "clone_ms" },
    // Finding only
    .{ .field = "collection_alloc", .emit = .finding_only, .rule_id = "AG006", .title = "Collection allocation inside loop", .message = "Reuse collections or move allocation outside the loop.", .severity = .warning, .category = "heap" },
    .{ .field = "string_append", .emit = .finding_only, .rule_id = "AG007", .title = "String concatenation inside loop", .message = "Prefer StringBuilder-style batching patterns to reduce CPU.", .severity = .info, .category = "cpu" },
};

// ---------------------------------------------------------------------------
// ルール検出ヘルパー
// ---------------------------------------------------------------------------

/// ファイル内容がテストクラス（クラス定義前に `@isTest` アノテーション）かどうかを判定する。
fn is_test_class(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        // @isTest アノテーションを検出（大文字小文字区別なし）
        if (trimmed[0] == '@') {
            const anno = std.mem.trim(u8, trimmed[1..], " \t");
            if (anno.len >= 6) {
                const prefix = anno[0..6];
                if (std.ascii.eqlIgnoreCase(prefix, "istest")) return true;
            }
        }
        // class/interface/trigger 宣言に到達したらアノテーション探索を終了
        if (contains_class_decl(trimmed)) return false;
    }
    return false;
}

fn contains_class_decl(line: []const u8) bool {
    const keywords = [_][]const u8{ "class ", "interface ", "trigger " };
    for (keywords) |kw| {
        if (std.mem.indexOf(u8, line, kw) != null) return true;
    }
    return false;
}

/// SOQL for ループ (`for (X : [SELECT ...])`) かどうかを判定する。
/// `Database.query()` 等は対象外（チャンク取得されないため）。
fn is_soql_for_loop(trimmed: []const u8) bool {
    const lower = blk: {
        var buf: [512]u8 = undefined;
        if (trimmed.len > buf.len) break :blk trimmed;
        for (trimmed, 0..) |c, i| {
            buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        break :blk buf[0..trimmed.len];
    };
    // "for" で始まり、":" の後に "[select" があるか
    if (!std.mem.startsWith(u8, lower, "for ") and !std.mem.startsWith(u8, lower, "for(")) return false;
    const colon_pos = std.mem.indexOfScalar(u8, lower, ':') orelse return false;
    const after_colon = lower[colon_pos + 1 ..];
    const after_trimmed = std.mem.trimStart(u8, after_colon, " \t");
    return std.mem.startsWith(u8, after_trimmed, "[select ");
}

/// 全検出器を実行し、各操作の直接検出カウント (0 or 1) を返す。
/// MethodMetrics と同じフィールド構造を再利用して `@field` アクセスを可能にする。
fn run_detectors(trimmed: []const u8, type_env: *std.StringHashMap([]const u8)) MethodMetrics {
    return .{
        .soql = if (detectors.contains_soql(trimmed)) 1 else 0,
        .dml = if (detectors.contains_dml(trimmed)) 1 else 0,
        .sosl = if (detectors.contains_sosl(trimmed)) 1 else 0,
        .callout = if (detectors.contains_callout(trimmed, type_env)) 1 else 0,
        .messaging = if (detectors.contains_messaging(trimmed)) 1 else 0,
        .json = if (detectors.contains_json_work(trimmed)) 1 else 0,
        .clone = if (detectors.contains_clone_work(trimmed)) 1 else 0,
        .collection_alloc = if (detectors.contains_collection_alloc(trimmed)) 1 else 0,
        .string_append = if (detectors.contains_string_append(trimmed)) 1 else 0,
    };
}

/// テーブル駆動でルール検出結果を Finding に変換する。
/// `inline for` により comptime 展開され、各ルールに最適化されたコードが生成される。
fn emit_rule_findings(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    direct: MethodMetrics,
    call_metrics: MethodMetrics,
    loop_upper_bound: ?u64,
    cpu_model: config.CpuModel,
) !void {
    inline for (rule_specs) |spec| {
        const count = sat_add(@field(direct, spec.field), @field(call_metrics, spec.field));
        if (count > 0) {
            switch (spec.emit) {
                .governor_with_cpu => {
                    try append_governor_finding(gpa, findings, path, line_no, spec.gov_kind, loop_upper_bound, count);
                    try append_cpu_estimate_finding(gpa, findings, path, line_no, spec.cpu_label, sat_mul(@field(cpu_model, spec.cpu_cost_field), count), loop_upper_bound, cpu_model.base_ms);
                },
                .governor_only => {
                    try append_governor_finding(gpa, findings, path, line_no, spec.gov_kind, loop_upper_bound, count);
                },
                .finding_with_cpu => {
                    try append_finding(gpa, findings, path, line_no, spec.rule_id, spec.title, spec.message, spec.severity, spec.category);
                    try append_cpu_estimate_finding(gpa, findings, path, line_no, spec.cpu_label, sat_mul(@field(cpu_model, spec.cpu_cost_field), count), loop_upper_bound, cpu_model.base_ms);
                },
                .finding_only => {
                    try append_finding(gpa, findings, path, line_no, spec.rule_id, spec.title, spec.message, spec.severity, spec.category);
                },
            }
        }
    }
}

// ---------------------------------------------------------------------------
// スコープ管理ヘルパー
// ---------------------------------------------------------------------------

/// メソッドスコープの終了判定と後処理。
/// brace_depth の変化後に呼び出し、メソッド本体を抜けた場合にスコープをクリアする。
fn check_method_scope_end(
    current_method: *?MethodScope,
    brace_depth: i32,
    type_env: *std.StringHashMap([]const u8),
    arena_allocator: std.mem.Allocator,
) void {
    if (current_method.*) |*scope| {
        if (!scope.entered_body and brace_depth >= scope.end_depth) {
            scope.entered_body = true;
        }
        if (scope.entered_body and brace_depth < scope.end_depth) {
            current_method.* = null;
            type_env.* = std.StringHashMap([]const u8).init(arena_allocator);
        }
    }
}

// ---------------------------------------------------------------------------
// メイン解析エントリポイント
// ---------------------------------------------------------------------------

pub fn scan_content(
    gpa: std.mem.Allocator,
    path: []const u8,
    stripped_content: []const u8,
    cfg: config.Config,
    method_summaries: *std.StringHashMap(MethodSummary),
    name_index: *const types.MethodNameIndex,
    type_relations: *const TypeRelations,
    findings: *std.ArrayList(model.Finding),
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    var bounds = std.StringHashMap(Bound).init(arena_allocator);
    var type_env = std.StringHashMap([]const u8).init(arena_allocator);
    var current_method: ?MethodScope = null;
    var do_while_conditions = try collect_do_while_start_conditions_from_stripped(arena_allocator, stripped_content);

    // @isTest クラスの findings をスキップ（method_summaries 登録は維持）
    const skip_test_findings = !cfg.include_tests and is_test_class(stripped_content);

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

        pop_closed_scopes(&loop_scopes, brace_depth);
        pop_closed_owners(&owner_scopes, brace_depth);

        const code_line = raw;
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        var started_method = false;
        if (trimmed.len > 0) {
            try maybe_enter_owner_scope(gpa, &owner_scopes, brace_depth, trimmed);
            if (current_method == null and owner_scopes.items.len > 0) {
                const owner = owner_scopes.items[owner_scopes.items.len - 1].name;
                if (parse_method_start(trimmed)) |decl| {
                    const summary = try ensure_method_summary(
                        arena_allocator,
                        method_summaries,
                        owner,
                        decl.name,
                        decl.params_raw,
                    );
                    type_env = std.StringHashMap([]const u8).init(arena_allocator);
                    try register_method_param_types(arena_allocator, &type_env, decl.params_raw);
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
                try apply_local_type_updates(arena_allocator, &type_env, trimmed);
            }
        }
        const current_owner = if (owner_scopes.items.len == 0) null else owner_scopes.items[owner_scopes.items.len - 1].name;
        if (trimmed.len == 0) {
            brace_depth = update_brace_depth(brace_depth, code_line);
            pop_closed_scopes(&loop_scopes, brace_depth);
            pop_closed_owners(&owner_scopes, brace_depth);
            if (pending_loop_scope) |pending| {
                if (brace_depth < pending.expected_depth) pending_loop_scope = null;
            }
            check_method_scope_end(&current_method, brace_depth, &type_env, arena_allocator);
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

        try apply_bound_updates(arena_allocator, &bounds, trimmed);

        const loop_info = infer_loop_info_at_line(trimmed, &bounds, &do_while_conditions, line_no);
        const loop_started = loop_info != null;
        const loop_level = loop_scopes.items.len;
        const in_loop = loop_started or loop_level > 0;

        // AG001: ネストされたループ検出（他ルールとパターンが異なるため個別処理）
        if (!skip_test_findings and loop_started and loop_level > 0) {
            try append_finding(
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

        // AG002–AG011: テーブル駆動ルール検出
        if (!skip_test_findings and in_loop) {
            const loop_upper_bound = effective_loop_upper_bound(loop_scopes.items, loop_info);
            const call_metrics = infer_called_method_metrics(trimmed, current_owner, &type_env, name_index, type_relations);
            var direct = run_detectors(trimmed, &type_env);

            // SOQL for ループ除外: `for (X : [SELECT ...])` のループ開始行では
            // iterable の SOQL はループ本体内の SOQL ではない（1回だけ発行される）。
            // ただしネスト（loop_level > 0）の場合は外側ループ内の SOQL なので除外しない。
            if (loop_started and direct.soql > 0 and loop_level == 0 and is_soql_for_loop(trimmed)) {
                direct.soql = 0;
            }

            try emit_rule_findings(gpa, findings, path, line_no, direct, call_metrics, loop_upper_bound, cfg.cpu_model);
        }

        if (loop_started and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            try loop_scopes.append(gpa, .{
                .end_depth = brace_depth + 1,
                .max_iterations = loop_info.?.max_iterations,
            });
        } else if (loop_started and is_do_loop_start(trimmed)) {
            pending_loop_scope = .{
                .expected_depth = brace_depth,
                .max_iterations = loop_info.?.max_iterations,
            };
        }

        brace_depth = update_brace_depth(brace_depth, code_line);
        pop_closed_scopes(&loop_scopes, brace_depth);
        pop_closed_owners(&owner_scopes, brace_depth);
        if (pending_loop_scope) |pending| {
            if (brace_depth < pending.expected_depth) pending_loop_scope = null;
        }
        check_method_scope_end(&current_method, brace_depth, &type_env, arena_allocator);
    }
}
