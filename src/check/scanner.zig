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
    .{
        .field = "soql",
        .emit = .governor_with_cpu,
        .gov_kind = .soql,
        .cpu_label = "SOQL",
        .cpu_cost_field = "soql_ms",
    },
    .{
        .field = "dml",
        .emit = .governor_with_cpu,
        .gov_kind = .dml,
        .cpu_label = "DML",
        .cpu_cost_field = "dml_ms",
    },
    .{
        .field = "sosl",
        .emit = .governor_with_cpu,
        .gov_kind = .sosl,
        .cpu_label = "SOSL",
        .cpu_cost_field = "soql_ms",
    },
    // Governor only
    .{ .field = "callout", .emit = .governor_only, .gov_kind = .callout },
    .{ .field = "messaging", .emit = .governor_only, .gov_kind = .messaging },
    // Finding + CPU estimate
    .{
        .field = "json",
        .emit = .finding_with_cpu,
        .rule_id = "AG004",
        .title = "JSON processing inside loop",
        .message = "Serialize/deserialize outside loops where possible.",
        .severity = .warning,
        .category = "cpu",
        .cpu_label = "JSON",
        .cpu_cost_field = "json_ms",
    },
    .{
        .field = "clone",
        .emit = .finding_with_cpu,
        .rule_id = "AG005",
        .title = "Clone/deepClone inside loop",
        .message = "Repeated cloning can increase heap and CPU cost.",
        .severity = .warning,
        .category = "heap",
        .cpu_label = "clone/deepClone",
        .cpu_cost_field = "clone_ms",
    },
    // Finding only
    .{
        .field = "collection_alloc",
        .emit = .finding_only,
        .rule_id = "AG006",
        .title = "Collection allocation inside loop",
        .message = "Reuse collections or move allocation outside the loop.",
        .severity = .warning,
        .category = "heap",
    },
    .{
        .field = "string_append",
        .emit = .finding_only,
        .rule_id = "AG007",
        .title = "String concatenation inside loop",
        .message = "Prefer StringBuilder-style batching patterns to reduce CPU.",
        .severity = .info,
        .category = "cpu",
    },
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
/// rule_specs のディスパッチで共有するコンテキスト。
const RuleEmitCtx = struct {
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    loop_upper_bound: ?u64,
    cpu_model: config.CpuModel,
};

fn emit_generic_finding(ctx: RuleEmitCtx, comptime spec: RuleSpec) !void {
    try append_finding(
        ctx.gpa,
        ctx.findings,
        ctx.path,
        ctx.line_no,
        spec.rule_id,
        spec.title,
        spec.message,
        spec.severity,
        spec.category,
    );
}

fn emit_governor_for_spec(ctx: RuleEmitCtx, comptime spec: RuleSpec, count: u64) !void {
    try append_governor_finding(
        ctx.gpa,
        ctx.findings,
        ctx.path,
        ctx.line_no,
        spec.gov_kind,
        ctx.loop_upper_bound,
        count,
    );
}

fn emit_cpu_for_spec(ctx: RuleEmitCtx, comptime spec: RuleSpec, count: u64) !void {
    try append_cpu_estimate_finding(
        ctx.gpa,
        ctx.findings,
        ctx.path,
        ctx.line_no,
        spec.cpu_label,
        sat_mul(@field(ctx.cpu_model, spec.cpu_cost_field), count),
        ctx.loop_upper_bound,
        ctx.cpu_model.base_ms,
    );
}

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
    const ctx = RuleEmitCtx{
        .gpa = gpa,
        .findings = findings,
        .path = path,
        .line_no = line_no,
        .loop_upper_bound = loop_upper_bound,
        .cpu_model = cpu_model,
    };
    inline for (rule_specs) |spec| {
        const count = sat_add(@field(direct, spec.field), @field(call_metrics, spec.field));
        if (count > 0) {
            switch (spec.emit) {
                .governor_with_cpu => {
                    try emit_governor_for_spec(ctx, spec, count);
                    try emit_cpu_for_spec(ctx, spec, count);
                },
                .governor_only => try emit_governor_for_spec(ctx, spec, count),
                .finding_with_cpu => {
                    try emit_generic_finding(ctx, spec);
                    try emit_cpu_for_spec(ctx, spec, count);
                },
                .finding_only => try emit_generic_finding(ctx, spec),
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

/// scan_content の実行状態を束ねる構造体。
const ScanState = struct {
    gpa: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    path: []const u8,
    cfg: config.Config,
    method_summaries: *std.StringHashMap(MethodSummary),
    name_index: *const types.MethodNameIndex,
    type_relations: *const TypeRelations,
    findings: *std.ArrayList(model.Finding),

    bounds: std.StringHashMap(Bound),
    type_env: std.StringHashMap([]const u8),
    do_while_conditions: std.AutoHashMap(usize, []const u8),
    current_method: ?MethodScope = null,

    loop_scopes: std.ArrayList(LoopScope) = .empty,
    owner_scopes: std.ArrayList(OwnerScope) = .empty,
    pending_loop_scope: ?PendingLoopScopeStart = null,

    brace_depth: i32 = 0,
    skip_test_findings: bool = false,
};

/// 方法開始の検出と type_env の初期化。
fn begin_method_if_present(state: *ScanState, trimmed: []const u8) !bool {
    if (state.current_method != null or state.owner_scopes.items.len == 0) return false;
    const owner = state.owner_scopes.items[state.owner_scopes.items.len - 1].name;
    const decl = parse_method_start(trimmed) orelse return false;

    const summary = try ensure_method_summary(
        state.arena_allocator,
        state.method_summaries,
        owner,
        decl.name,
        decl.params_raw,
    );
    state.type_env = std.StringHashMap([]const u8).init(state.arena_allocator);
    try register_method_param_types(state.arena_allocator, &state.type_env, decl.params_raw);
    state.current_method = .{
        .owner = owner,
        .name = summary.name,
        .param_count = summary.param_count,
        .param_signature = summary.param_signature,
        .end_depth = state.brace_depth + 1,
        .entered_body = std.mem.indexOfScalar(u8, trimmed, '{') != null,
    };
    return true;
}

/// 行開始時のスコープ処理: owner / method 進入と type_env 更新。
fn enter_line_scope(state: *ScanState, trimmed: []const u8) !void {
    if (trimmed.len == 0) return;
    try maybe_enter_owner_scope(state.gpa, &state.owner_scopes, state.brace_depth, trimmed);
    const started_method = try begin_method_if_present(state, trimmed);
    if (!started_method and state.current_method != null) {
        try apply_local_type_updates(state.arena_allocator, &state.type_env, trimmed);
    }
}

/// 行末の brace_depth 更新とクロージャ。空行・通常行で共通。
fn finalize_line(state: *ScanState, code_line: []const u8) void {
    state.brace_depth = update_brace_depth(state.brace_depth, code_line);
    pop_closed_scopes(&state.loop_scopes, state.brace_depth);
    pop_closed_owners(&state.owner_scopes, state.brace_depth);
    if (state.pending_loop_scope) |pending| {
        if (state.brace_depth < pending.expected_depth) state.pending_loop_scope = null;
    }
    check_method_scope_end(
        &state.current_method,
        state.brace_depth,
        &state.type_env,
        state.arena_allocator,
    );
}

fn register_pending_loop_if_entering_block(state: *ScanState, trimmed: []const u8) !void {
    const pending = state.pending_loop_scope orelse return;
    if (trimmed[0] == '{' and state.brace_depth == pending.expected_depth) {
        try state.loop_scopes.append(state.gpa, .{
            .end_depth = state.brace_depth + 1,
            .max_iterations = pending.max_iterations,
        });
    }
    state.pending_loop_scope = null;
}

fn emit_ag001_if_nested(
    state: *ScanState,
    line_no: usize,
    loop_started: bool,
    loop_level: usize,
) !void {
    if (state.skip_test_findings or !loop_started or loop_level == 0) return;
    try append_finding(
        state.gpa,
        state.findings,
        state.path,
        line_no,
        "AG001",
        "Nested loop can burn CPU quickly",
        "Nested loops often amplify CPU usage and governor risk.",
        .warning,
        "cpu",
    );
}

fn emit_ag002_to_ag011(
    state: *ScanState,
    trimmed: []const u8,
    line_no: usize,
    current_owner: ?[]const u8,
    loop_info: ?types.LoopInfo,
    loop_level: usize,
) !void {
    const loop_started = loop_info != null;
    const in_loop = loop_started or loop_level > 0;
    if (state.skip_test_findings or !in_loop) return;

    const loop_upper_bound = effective_loop_upper_bound(state.loop_scopes.items, loop_info);
    const call_metrics = infer_called_method_metrics(
        trimmed,
        current_owner,
        &state.type_env,
        state.name_index,
        state.type_relations,
    );
    var direct = run_detectors(trimmed, &state.type_env);

    // SOQL for ループ除外: `for (X : [SELECT ...])` のループ開始行では
    // iterable の SOQL はループ本体内の SOQL ではない（1回だけ発行される）。
    // ただしネスト（loop_level > 0）の場合は外側ループ内の SOQL なので除外しない。
    if (loop_started and direct.soql > 0 and loop_level == 0 and is_soql_for_loop(trimmed)) {
        direct.soql = 0;
    }

    try emit_rule_findings(
        state.gpa,
        state.findings,
        state.path,
        line_no,
        direct,
        call_metrics,
        loop_upper_bound,
        state.cfg.cpu_model,
    );
}

fn register_new_loop_scope(
    state: *ScanState,
    trimmed: []const u8,
    loop_info: ?types.LoopInfo,
) !void {
    const info = loop_info orelse return;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
        try state.loop_scopes.append(state.gpa, .{
            .end_depth = state.brace_depth + 1,
            .max_iterations = info.max_iterations,
        });
    } else if (is_do_loop_start(trimmed)) {
        state.pending_loop_scope = .{
            .expected_depth = state.brace_depth,
            .max_iterations = info.max_iterations,
        };
    }
}

fn process_line(state: *ScanState, code_line: []const u8, line_no: usize) !void {
    pop_closed_scopes(&state.loop_scopes, state.brace_depth);
    pop_closed_owners(&state.owner_scopes, state.brace_depth);

    const trimmed = std.mem.trim(u8, code_line, " \t\r");
    try enter_line_scope(state, trimmed);

    const current_owner = if (state.owner_scopes.items.len == 0)
        null
    else
        state.owner_scopes.items[state.owner_scopes.items.len - 1].name;

    if (trimmed.len == 0) {
        finalize_line(state, code_line);
        return;
    }

    try register_pending_loop_if_entering_block(state, trimmed);
    try apply_bound_updates(state.arena_allocator, &state.bounds, trimmed);

    const loop_info = infer_loop_info_at_line(
        trimmed,
        &state.bounds,
        &state.do_while_conditions,
        line_no,
    );
    const loop_level = state.loop_scopes.items.len;

    try emit_ag001_if_nested(state, line_no, loop_info != null, loop_level);
    try emit_ag002_to_ag011(state, trimmed, line_no, current_owner, loop_info, loop_level);
    try register_new_loop_scope(state, trimmed, loop_info);

    finalize_line(state, code_line);
}

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
    var state = ScanState{
        .gpa = gpa,
        .arena_allocator = arena_allocator,
        .path = path,
        .cfg = cfg,
        .method_summaries = method_summaries,
        .name_index = name_index,
        .type_relations = type_relations,
        .findings = findings,
        .bounds = std.StringHashMap(Bound).init(arena_allocator),
        .type_env = std.StringHashMap([]const u8).init(arena_allocator),
        .do_while_conditions = try collect_do_while_start_conditions_from_stripped(
            arena_allocator,
            stripped_content,
        ),
        .skip_test_findings = !cfg.include_tests and is_test_class(stripped_content),
    };
    defer state.loop_scopes.deinit(gpa);
    defer state.owner_scopes.deinit(gpa);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, stripped_content, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        try process_line(&state, raw, line_no);
    }
}
