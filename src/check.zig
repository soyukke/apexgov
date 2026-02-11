const std = @import("std");
const model = @import("model.zig");
const config = @import("config.zig");

const soql_limit: u64 = 100;
const dml_limit: u64 = 150;
const sosl_limit: u64 = 20;
const callout_limit: u64 = 100;
const messaging_send_limit: u64 = 10;
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

const PendingLoopScopeStart = struct {
    expected_depth: i32,
    max_iterations: ?u64,
};

const DoLoopStart = struct {
    start_line: usize,
    end_depth: i32,
};

const BoundUpdate = struct {
    name: []const u8,
    max: ?u64,
    origin: BoundOrigin,
};

const MethodMetrics = struct {
    soql: u64 = 0,
    dml: u64 = 0,
    sosl: u64 = 0,
    callout: u64 = 0,
    messaging: u64 = 0,
    json: u64 = 0,
    clone: u64 = 0,
    collection_alloc: u64 = 0,
    string_append: u64 = 0,

    fn add(self: *MethodMetrics, other: MethodMetrics) void {
        self.soql = satAdd(self.soql, other.soql);
        self.dml = satAdd(self.dml, other.dml);
        self.sosl = satAdd(self.sosl, other.sosl);
        self.callout = satAdd(self.callout, other.callout);
        self.messaging = satAdd(self.messaging, other.messaging);
        self.json = satAdd(self.json, other.json);
        self.clone = satAdd(self.clone, other.clone);
        self.collection_alloc = satAdd(self.collection_alloc, other.collection_alloc);
        self.string_append = satAdd(self.string_append, other.string_append);
    }

    fn addScaled(self: *MethodMetrics, other: MethodMetrics, multiplier: u64) void {
        self.soql = satAdd(self.soql, satMul(other.soql, multiplier));
        self.dml = satAdd(self.dml, satMul(other.dml, multiplier));
        self.sosl = satAdd(self.sosl, satMul(other.sosl, multiplier));
        self.callout = satAdd(self.callout, satMul(other.callout, multiplier));
        self.messaging = satAdd(self.messaging, satMul(other.messaging, multiplier));
        self.json = satAdd(self.json, satMul(other.json, multiplier));
        self.clone = satAdd(self.clone, satMul(other.clone, multiplier));
        self.collection_alloc = satAdd(self.collection_alloc, satMul(other.collection_alloc, multiplier));
        self.string_append = satAdd(self.string_append, satMul(other.string_append, multiplier));
    }
};

const ResolveState = enum {
    unresolved,
    resolving,
    resolved,
};

const MethodCall = struct {
    callee_key: []const u8,
    multiplier: u64,
};

const MethodSummary = struct {
    owner: []const u8,
    name: []const u8,
    param_count: u16,
    param_signature: []const u8,
    direct: MethodMetrics = .{},
    total: MethodMetrics = .{},
    calls: std.ArrayListUnmanaged(MethodCall) = .{},
    state: ResolveState = .unresolved,
};

const MethodScope = struct {
    owner: []const u8,
    name: []const u8,
    param_count: u16,
    param_signature: []const u8,
    end_depth: i32,
    entered_body: bool,
};

const MethodDecl = struct {
    name: []const u8,
    param_count: u16,
    params_raw: []const u8,
};

const TypeBinding = struct {
    name: []const u8,
    type_raw: []const u8,
};

const OwnerScope = struct {
    name: []const u8,
    end_depth: i32,
};

const ApexFile = struct {
    path: []const u8,
    content: []const u8,
};

pub fn run(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(model.Finding) {
    return runWithConfig(gpa, roots, config.Config.defaults());
}

pub fn runWithConfig(gpa: std.mem.Allocator, roots: []const []const u8, cfg: config.Config) !std.ArrayList(model.Finding) {
    var findings: std.ArrayList(model.Finding) = .empty;
    errdefer model.deinitFindings(gpa, &findings);

    var files = try collectApexFiles(gpa, roots);
    defer deinitApexFiles(gpa, &files);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var method_summaries = try buildMethodSummaries(arena_allocator, files.items);

    for (files.items) |file| {
        try scanContent(
            gpa,
            file.path,
            file.content,
            cfg,
            &method_summaries,
            &findings,
        );
    }

    return findings;
}

fn collectApexFiles(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(ApexFile) {
    var files: std.ArrayList(ApexFile) = .empty;
    errdefer deinitApexFiles(gpa, &files);
    for (roots) |root| {
        try collectPath(gpa, root, &files);
    }
    return files;
}

fn collectPath(gpa: std.mem.Allocator, path: []const u8, files: *std.ArrayList(ApexFile)) !void {
    collectDirectory(gpa, path, files) catch |err| switch (err) {
        error.NotDir => {
            if (isApexSource(path)) {
                try appendApexFile(gpa, files, path);
            }
        },
        else => return err,
    };
}

fn collectDirectory(gpa: std.mem.Allocator, root: []const u8, files: *std.ArrayList(ApexFile)) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isApexSource(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        defer gpa.free(joined);

        try appendApexFile(gpa, files, joined);
    }
}

fn appendApexFile(gpa: std.mem.Allocator, files: *std.ArrayList(ApexFile), path: []const u8) !void {
    const content = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    errdefer gpa.free(content);

    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    try files.append(gpa, .{
        .path = path_copy,
        .content = content,
    });
}

fn deinitApexFiles(gpa: std.mem.Allocator, files: *std.ArrayList(ApexFile)) void {
    for (files.items) |file| {
        gpa.free(file.path);
        gpa.free(file.content);
    }
    files.deinit(gpa);
}

fn scanContent(
    gpa: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    cfg: config.Config,
    method_summaries: *std.StringHashMap(MethodSummary),
    findings: *std.ArrayList(model.Finding),
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var bounds = std.StringHashMap(Bound).init(arena_allocator);
    var type_env = std.StringHashMap([]const u8).init(arena_allocator);
    var current_method: ?MethodScope = null;
    var do_while_conditions = try collectDoWhileStartConditions(arena_allocator, content);

    var loop_scopes: std.ArrayList(LoopScope) = .empty;
    defer loop_scopes.deinit(gpa);
    var pending_loop_scope: ?PendingLoopScopeStart = null;
    var owner_scopes: std.ArrayList(OwnerScope) = .empty;
    defer owner_scopes.deinit(gpa);

    var brace_depth: i32 = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw| {
        line_no += 1;

        popClosedScopes(&loop_scopes, brace_depth);
        popClosedOwners(&owner_scopes, brace_depth);

        const code_line = stripLineComment(raw);
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
            inferCalledMethodMetrics(trimmed, current_owner, &type_env, method_summaries)
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
            if (containsSosl(trimmed)) @as(u64, 1) else @as(u64, 0),
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
            if (containsCallout(trimmed, &type_env)) @as(u64, 1) else @as(u64, 0),
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
            if (containsMessaging(trimmed)) @as(u64, 1) else @as(u64, 0),
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

fn buildMethodSummaries(arena_allocator: std.mem.Allocator, files: []const ApexFile) !std.StringHashMap(MethodSummary) {
    var summaries = std.StringHashMap(MethodSummary).init(arena_allocator);

    for (files) |file| {
        try collectMethodNames(arena_allocator, file.content, &summaries);
    }
    for (files) |file| {
        try collectMethodDirectMetricsAndCalls(arena_allocator, file.content, &summaries);
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

fn collectMethodNames(
    arena_allocator: std.mem.Allocator,
    content: []const u8,
    summaries: *std.StringHashMap(MethodSummary),
) !void {
    var owner_scopes: std.ArrayList(OwnerScope) = .empty;
    defer owner_scopes.deinit(arena_allocator);

    var brace_depth: i32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const code_line = stripLineComment(raw);
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
) !void {
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
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw| {
        line_no += 1;
        const code_line = stripLineComment(raw);
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

fn ensureMethodSummary(
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

fn parseMethodStart(line: []const u8) ?MethodDecl {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    const open_idx = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
        if (eq_idx < open_idx) return null;
    }
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

    const left = std.mem.trim(u8, trimmed[0..open_idx], " \t");
    const name = extractLastIdentifier(left) orelse return null;
    if (isControlKeyword(name)) return null;
    const params_raw = trimmed[(open_idx + 1)..close_idx];
    const param_count = countParameters(params_raw) orelse return null;
    return .{
        .name = name,
        .param_count = param_count,
        .params_raw = params_raw,
    };
}

fn countParameters(params_raw: []const u8) ?u16 {
    const params = std.mem.trim(u8, params_raw, " \t");
    if (params.len == 0) return 0;

    var count: u16 = 1;
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;

    for (params) |c| {
        switch (c) {
            '<' => {
                angle_depth += 1;
            },
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '(' => {
                paren_depth += 1;
            },
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
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
                if (angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    count = satAddU16(count, 1);
                }
            },
            else => {},
        }
    }

    return count;
}

fn buildParamTypeSignature(arena_allocator: std.mem.Allocator, params_raw: []const u8) ![]const u8 {
    const params = std.mem.trim(u8, params_raw, " \t");
    if (params.len == 0) return try arena_allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;

    var seg_start: usize = 0;
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var i: usize = 0;
    while (i <= params.len) : (i += 1) {
        const at_end = i == params.len;
        const c = if (at_end) ',' else params[i];

        if (!at_end) {
            switch (c) {
                '<' => {
                    angle_depth += 1;
                },
                '>' => {
                    if (angle_depth > 0) angle_depth -= 1;
                },
                '(' => {
                    paren_depth += 1;
                },
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
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
                else => {},
            }
        }

        if (c == ',' and angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            const segment = std.mem.trim(u8, params[seg_start..i], " \t");
            const type_part = extractParameterTypePart(segment);
            if (out.items.len > 0) try out.append(arena_allocator, '|');
            try appendCanonicalType(arena_allocator, &out, type_part);
            seg_start = i + 1;
        }
    }

    return try out.toOwnedSlice(arena_allocator);
}

fn countSignatureParams(signature: []const u8) u16 {
    if (signature.len == 0) return 0;
    var count: u16 = 1;
    for (signature) |c| {
        if (c == '|') count = satAddU16(count, 1);
    }
    return count;
}

fn extractParameterTypePart(segment_raw: []const u8) []const u8 {
    var segment = std.mem.trim(u8, segment_raw, " \t");
    if (segment.len == 0) return "?";

    while (std.mem.startsWith(u8, segment, "final ")) {
        segment = std.mem.trimLeft(u8, segment[6..], " \t");
    }

    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var i = segment.len;
    while (i > 0) {
        i -= 1;
        const c = segment[i];
        switch (c) {
            '>' => {
                angle_depth += 1;
            },
            '<' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            ')' => {
                paren_depth += 1;
            },
            '(' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            ']' => {
                bracket_depth += 1;
            },
            '[' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '}' => {
                brace_depth += 1;
            },
            '{' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            else => {},
        }
        if ((c == ' ' or c == '\t') and angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            const left = std.mem.trimRight(u8, segment[0..i], " \t");
            if (left.len == 0) return "?";
            return left;
        }
    }
    return "?";
}

fn appendCanonicalType(arena_allocator: std.mem.Allocator, out: *std.ArrayList(u8), type_part: []const u8) !void {
    if (type_part.len == 0) {
        try out.append(arena_allocator, '?');
        return;
    }
    const before_len = out.items.len;
    for (type_part) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        try out.append(arena_allocator, c);
    }
    if (out.items.len == before_len) {
        try out.append(arena_allocator, '?');
    }
}

fn registerMethodParamTypes(
    arena_allocator: std.mem.Allocator,
    type_env: *std.StringHashMap([]const u8),
    params_raw: []const u8,
) !void {
    const params = std.mem.trim(u8, params_raw, " \t");
    if (params.len == 0) return;

    var seg_start: usize = 0;
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var i: usize = 0;
    while (i <= params.len) : (i += 1) {
        const at_end = i == params.len;
        const c = if (at_end) ',' else params[i];

        if (!at_end) {
            switch (c) {
                '<' => {
                    angle_depth += 1;
                },
                '>' => {
                    if (angle_depth > 0) angle_depth -= 1;
                },
                '(' => {
                    paren_depth += 1;
                },
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
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
                else => {},
            }
        }

        if (c == ',' and angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            const segment = std.mem.trim(u8, params[seg_start..i], " \t");
            if (parseTypedBinding(segment)) |binding| {
                try bindType(arena_allocator, type_env, binding);
            }
            seg_start = i + 1;
        }
    }
}

fn applyLocalTypeUpdates(
    arena_allocator: std.mem.Allocator,
    type_env: *std.StringHashMap([]const u8),
    line: []const u8,
) !void {
    if (parseForEachBinding(line)) |binding| {
        try bindType(arena_allocator, type_env, binding);
        return;
    }
    if (parseForInitBinding(line)) |binding| {
        try bindType(arena_allocator, type_env, binding);
        return;
    }
    if (parseLocalTypedBinding(line)) |binding| {
        try bindType(arena_allocator, type_env, binding);
    }
}

fn parseForEachBinding(line: []const u8) ?TypeBinding {
    if (!std.mem.startsWith(u8, line, "for(") and !std.mem.startsWith(u8, line, "for (")) return null;
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    const inside = std.mem.trim(u8, line[(open_idx + 1)..close_idx], " \t");
    const colon_idx = std.mem.indexOfScalar(u8, inside, ':') orelse return null;
    const left = std.mem.trim(u8, inside[0..colon_idx], " \t");
    return parseTypedBinding(left);
}

fn parseForInitBinding(line: []const u8) ?TypeBinding {
    if (!std.mem.startsWith(u8, line, "for(") and !std.mem.startsWith(u8, line, "for (")) return null;
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    const inside = std.mem.trim(u8, line[(open_idx + 1)..close_idx], " \t");
    if (std.mem.indexOfScalar(u8, inside, ':') != null) return null;
    const semi_idx = std.mem.indexOfScalar(u8, inside, ';') orelse return null;
    const init = std.mem.trim(u8, inside[0..semi_idx], " \t");
    if (init.len == 0) return null;
    const eq_idx = std.mem.indexOfScalar(u8, init, '=') orelse init.len;
    const left = std.mem.trim(u8, init[0..eq_idx], " \t");
    return parseTypedBinding(left);
}

fn parseLocalTypedBinding(line: []const u8) ?TypeBinding {
    if (std.mem.startsWith(u8, line, "if(") or
        std.mem.startsWith(u8, line, "if ") or
        std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for ") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while ") or
        std.mem.startsWith(u8, line, "switch(") or
        std.mem.startsWith(u8, line, "switch ") or
        std.mem.startsWith(u8, line, "catch(") or
        std.mem.startsWith(u8, line, "catch ") or
        std.mem.startsWith(u8, line, "return") or
        std.mem.startsWith(u8, line, "throw") or
        std.mem.startsWith(u8, line, "insert ") or
        std.mem.startsWith(u8, line, "update ") or
        std.mem.startsWith(u8, line, "delete ") or
        std.mem.startsWith(u8, line, "upsert "))
    {
        return null;
    }

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse line.len;
    const semi_idx = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const end_idx = @min(eq_idx, semi_idx);
    if (end_idx == 0 or end_idx > line.len) return null;
    const left = std.mem.trim(u8, line[0..end_idx], " \t");
    if (left.len == 0) return null;
    return parseTypedBinding(left);
}

fn parseTypedBinding(segment_raw: []const u8) ?TypeBinding {
    const segment = std.mem.trim(u8, segment_raw, " \t");
    if (segment.len == 0) return null;
    const name = extractLastIdentifier(segment) orelse return null;
    if (!isIdentStart(name[0])) return null;

    var i = segment.len;
    while (i > 0 and !isIdentChar(segment[i - 1])) : (i -= 1) {}
    const end = i;
    if (end == 0) return null;
    while (i > 0 and isIdentChar(segment[i - 1])) : (i -= 1) {}
    const start = i;
    if (start == 0) return null;
    if (!std.ascii.isWhitespace(segment[start - 1])) return null;

    var type_part = std.mem.trimRight(u8, segment[0..start], " \t");
    type_part = stripLeadingTypeModifiers(type_part);
    if (type_part.len == 0) return null;

    return .{
        .name = name,
        .type_raw = type_part,
    };
}

fn stripLeadingTypeModifiers(raw: []const u8) []const u8 {
    var out = std.mem.trim(u8, raw, " \t");
    while (true) {
        if (std.mem.startsWith(u8, out, "final ")) {
            out = std.mem.trimLeft(u8, out[6..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "public ")) {
            out = std.mem.trimLeft(u8, out[7..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "private ")) {
            out = std.mem.trimLeft(u8, out[8..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "protected ")) {
            out = std.mem.trimLeft(u8, out[10..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "global ")) {
            out = std.mem.trimLeft(u8, out[7..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "static ")) {
            out = std.mem.trimLeft(u8, out[7..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "transient ")) {
            out = std.mem.trimLeft(u8, out[10..], " \t");
            continue;
        }
        break;
    }
    return out;
}

fn bindType(
    arena_allocator: std.mem.Allocator,
    type_env: *std.StringHashMap([]const u8),
    binding: TypeBinding,
) !void {
    const canonical = try canonicalizeType(arena_allocator, binding.type_raw);
    if (type_env.getPtr(binding.name)) |existing| {
        existing.* = canonical;
        return;
    }
    const key = try arena_allocator.dupe(u8, binding.name);
    try type_env.put(key, canonical);
}

fn canonicalizeType(arena_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const stripped = stripLeadingTypeModifiers(raw);
    try appendCanonicalType(arena_allocator, &out, stripped);
    return try out.toOwnedSlice(arena_allocator);
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

fn maybeEnterOwnerScope(
    allocator: std.mem.Allocator,
    scopes: *std.ArrayList(OwnerScope),
    brace_depth: i32,
    line: []const u8,
) !void {
    const owner = parseOwnerStart(line) orelse return;
    try scopes.append(allocator, .{
        .name = owner,
        .end_depth = brace_depth + 1,
    });
}

fn popClosedOwners(scopes: *std.ArrayList(OwnerScope), brace_depth: i32) void {
    while (scopes.items.len > 0 and scopes.items[scopes.items.len - 1].end_depth > brace_depth) {
        _ = scopes.pop();
    }
}

fn parseOwnerStart(line: []const u8) ?[]const u8 {
    return parseClassStart(line) orelse parseTriggerStart(line);
}

fn parseClassStart(line: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;

    var start: ?usize = null;
    if (std.mem.startsWith(u8, line, "class ")) {
        start = 6;
    } else if (std.mem.indexOf(u8, line, " class ")) |idx| {
        start = idx + 7;
    }
    const class_start = start orelse return null;
    const rest = std.mem.trimLeft(u8, line[class_start..], " \t");
    return extractLeadingIdentifier(rest);
}

fn parseTriggerStart(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "trigger ")) return null;
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;
    const rest = std.mem.trimLeft(u8, line[8..], " \t");
    return extractLeadingIdentifier(rest);
}

fn extractLeadingIdentifier(raw: []const u8) ?[]const u8 {
    if (raw.len == 0 or !isIdentChar(raw[0])) return null;
    var end: usize = 0;
    while (end < raw.len and isIdentChar(raw[end])) : (end += 1) {}
    if (end == 0) return null;
    return raw[0..end];
}

fn applyDirectLineMetrics(
    metrics: *MethodMetrics,
    line: []const u8,
    multiplier: u64,
    type_env: *std.StringHashMap([]const u8),
) void {
    const weight = if (multiplier == 0) @as(u64, 1) else multiplier;
    if (containsSoql(line)) metrics.soql = satAdd(metrics.soql, weight);
    if (containsDml(line)) metrics.dml = satAdd(metrics.dml, weight);
    if (containsSosl(line)) metrics.sosl = satAdd(metrics.sosl, weight);
    if (containsCallout(line, type_env)) metrics.callout = satAdd(metrics.callout, weight);
    if (containsMessaging(line)) metrics.messaging = satAdd(metrics.messaging, weight);
    if (containsJsonWork(line)) metrics.json = satAdd(metrics.json, weight);
    if (containsCloneWork(line)) metrics.clone = satAdd(metrics.clone, weight);
    if (containsCollectionAlloc(line)) metrics.collection_alloc = satAdd(metrics.collection_alloc, weight);
    if (containsStringAppend(line)) metrics.string_append = satAdd(metrics.string_append, weight);
}

fn recordCalledMethods(
    arena_allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged(MethodCall),
    summaries: *std.StringHashMap(MethodSummary),
    caller_owner: []const u8,
    caller_name: []const u8,
    line: []const u8,
    type_env: *std.StringHashMap([]const u8),
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

fn inferCalledMethodMetrics(
    line: []const u8,
    current_owner: ?[]const u8,
    type_env: *std.StringHashMap([]const u8),
    summaries: *std.StringHashMap(MethodSummary),
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
) bool {
    if (containsQualifiedMethodCall(line, callee_owner, callee_name, callee_param_count, callee_param_signature, type_env)) return true;
    if (std.mem.eql(u8, caller_owner, callee_owner) and containsBareMethodCall(line, callee_name, callee_param_count, callee_param_signature, type_env)) return true;
    if (std.mem.eql(u8, caller_owner, callee_owner) and containsQualifiedMethodCall(line, "this", callee_name, callee_param_count, callee_param_signature, type_env)) return true;
    return false;
}

fn containsBareMethodCall(
    line: []const u8,
    method_name: []const u8,
    expected_param_count: u16,
    expected_param_signature: []const u8,
    type_env: *std.StringHashMap([]const u8),
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
            if (arg_count == expected_param_count and argumentsMatchParamSignature(line, end, expected_param_signature, type_env)) return true;
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
            if (arg_count == expected_param_count and argumentsMatchParamSignature(line, open_idx, expected_param_signature, type_env)) return true;
        }

        start = owner_idx + owner.len;
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
                    if (!argumentExprMatchesType(segment, expected, type_env)) return false;
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
                    if (!argumentExprMatchesType(segment, expected, type_env)) return false;
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
        return equalsCanonicalType(type_raw, expected_type);
    }

    if (extractRootIdentifier(expr)) |root| {
        if (type_env.get(root)) |bound_type| {
            if (isIndexedAccess(expr)) {
                if (!isPureIndexedAccess(expr)) return true;
                if (extractListElementType(bound_type)) |element_type| {
                    return equalsCanonicalType(element_type, expected_type);
                }
                return false;
            }
            if (isSimpleIdentifier(expr)) {
                return equalsCanonicalType(bound_type, expected_type);
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

fn extractTypeFromNewExpression(expr_after_new_raw: []const u8) ?[]const u8 {
    const expr = std.mem.trimLeft(u8, expr_after_new_raw, " \t");
    if (expr.len == 0) return null;

    var angle_depth: i32 = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        switch (c) {
            '<' => {
                angle_depth += 1;
            },
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '(' => {
                if (angle_depth == 0) break;
            },
            '[' => {
                if (angle_depth == 0) break;
            },
            '{' => {
                if (angle_depth == 0) break;
            },
            else => {},
        }
    }
    if (i == 0) return null;
    return std.mem.trim(u8, expr[0..i], " \t");
}

fn equalsCanonicalType(raw_type: []const u8, canonical_type: []const u8) bool {
    var raw_i: usize = 0;
    var canon_i: usize = 0;
    while (raw_i < raw_type.len and canon_i < canonical_type.len) {
        while (raw_i < raw_type.len and std.ascii.isWhitespace(raw_type[raw_i])) : (raw_i += 1) {}
        if (raw_i >= raw_type.len) break;
        if (raw_type[raw_i] != canonical_type[canon_i]) return false;
        raw_i += 1;
        canon_i += 1;
    }
    while (raw_i < raw_type.len and std.ascii.isWhitespace(raw_type[raw_i])) : (raw_i += 1) {}
    return raw_i == raw_type.len and canon_i == canonical_type.len;
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

fn satAdd(a: u64, b: u64) u64 {
    return std.math.add(u64, a, b) catch std.math.maxInt(u64);
}

fn satMul(a: u64, b: u64) u64 {
    return std.math.mul(u64, a, b) catch std.math.maxInt(u64);
}

fn satAddU16(a: u16, b: u16) u16 {
    return std.math.add(u16, a, b) catch std.math.maxInt(u16);
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
    sosl,
    callout,
    messaging,
};

fn appendGovernorFinding(
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

fn inferLoopInfoAtLine(
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

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
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

fn collectDoWhileStartConditions(
    allocator: std.mem.Allocator,
    content: []const u8,
) !std.AutoHashMap(usize, []const u8) {
    var out = std.AutoHashMap(usize, []const u8).init(allocator);
    errdefer out.deinit();

    var do_stack: std.ArrayList(DoLoopStart) = .empty;
    defer do_stack.deinit(allocator);
    var pending_do_start: ?DoLoopStart = null;

    var brace_depth: i32 = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const code_line = stripLineComment(raw);
        const trimmed = std.mem.trim(u8, code_line, " \t\r");

        if (trimmed.len > 0) {
            if (isDoLoopStart(trimmed)) {
                if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                    try do_stack.append(allocator, .{
                        .start_line = line_no,
                        .end_depth = brace_depth + 1,
                    });
                    pending_do_start = null;
                } else {
                    pending_do_start = .{
                        .start_line = line_no,
                        .end_depth = brace_depth,
                    };
                }
            } else if (pending_do_start) |pending| {
                if (trimmed[0] == '{' and pending.end_depth == brace_depth) {
                    try do_stack.append(allocator, .{
                        .start_line = pending.start_line,
                        .end_depth = brace_depth + 1,
                    });
                }
                pending_do_start = null;
            }

            if (try parseDoWhileTailCondition(allocator, trimmed)) |condition| {
                errdefer allocator.free(condition);
                if (do_stack.items.len > 0 and do_stack.items[do_stack.items.len - 1].end_depth == brace_depth) {
                    const do_start = do_stack.pop().?;
                    try out.put(do_start.start_line, condition);
                } else {
                    allocator.free(condition);
                }
            }
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        if (pending_do_start) |pending| {
            if (brace_depth < pending.end_depth) {
                pending_do_start = null;
            }
        }
        while (do_stack.items.len > 0 and do_stack.items[do_stack.items.len - 1].end_depth > brace_depth) {
            _ = do_stack.pop();
        }
    }

    return out;
}

fn isDoLoopStart(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (!startsWithIgnoreCase(trimmed, "do")) return false;
    if (trimmed.len == 2) return true;
    const next = trimmed[2];
    return next == ' ' or next == '\t' or next == '{';
}

fn parseDoWhileTailCondition(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 8 or trimmed[0] != '}') return null;

    trimmed = std.mem.trimLeft(u8, trimmed[1..], " \t");
    if (!startsWithIgnoreCase(trimmed, "while")) return null;
    if (trimmed.len > "while".len) {
        const next = trimmed["while".len];
        if (!(next == ' ' or next == '\t' or next == '(')) return null;
    }

    var rest = std.mem.trimLeft(u8, trimmed["while".len..], " \t");
    if (rest.len == 0 or rest[0] != '(') return null;

    const close = findMatchingParen(rest, 0) orelse return null;
    const after = std.mem.trim(u8, rest[(close + 1)..], " \t");
    if (after.len > 0 and !std.mem.eql(u8, after, ";")) return null;

    const cond = std.mem.trim(u8, rest[1..close], " \t");
    if (cond.len == 0) return null;
    return try allocator.dupe(u8, cond);
}

fn findMatchingParen(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '(') return null;
    var depth: i32 = 0;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

fn isLoopStart(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for (") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while (") or
        isDoLoopStart(line);
}

fn containsSoql(line: []const u8) bool {
    const needles = [_][]const u8{
        "[select ",
        "database.query(",
        "database.querywithbinds(",
        "database.countquery(",
        "database.getquerylocator(",
    };
    return containsAnyCaseInsensitive(line, &needles);
}

fn containsDml(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (startsWithIgnoreCase(trimmed, "insert ") or
        startsWithIgnoreCase(trimmed, "update ") or
        startsWithIgnoreCase(trimmed, "upsert ") or
        startsWithIgnoreCase(trimmed, "delete ") or
        startsWithIgnoreCase(trimmed, "undelete ") or
        startsWithIgnoreCase(trimmed, "merge "))
    {
        return true;
    }

    const db_dml_calls = [_][]const u8{
        "database.insert(",
        "database.update(",
        "database.upsert(",
        "database.delete(",
        "database.undelete(",
        "database.merge(",
        "database.emptyrecyclebin(",
        "database.convertlead(",
    };
    return containsAnyCaseInsensitive(line, &db_dml_calls);
}

fn containsSosl(line: []const u8) bool {
    const needles = [_][]const u8{
        "[find ",
        "search.query(",
    };
    return containsAnyCaseInsensitive(line, &needles);
}

fn containsCallout(line: []const u8, type_env: *std.StringHashMap([]const u8)) bool {
    const direct_needles = [_][]const u8{
        "http.send(",
        "webservicecallout.invoke(",
        "continuation.addhttprequest(",
    };
    if (containsAnyCaseInsensitive(line, &direct_needles)) return true;

    const send_idx = indexOfCaseInsensitive(line, ".send(") orelse return false;
    const receiver = extractLastIdentifier(std.mem.trimRight(u8, line[0..send_idx], " \t")) orelse return false;
    const bound_type = type_env.get(receiver) orelse return false;
    return equalsCanonicalType(bound_type, "Http");
}

fn containsMessaging(line: []const u8) bool {
    const needles = [_][]const u8{
        "messaging.sendemail(",
        "messaging.sendemailmessage(",
        "messaging.sendnotification(",
    };
    return containsAnyCaseInsensitive(line, &needles);
}

fn containsJsonWork(line: []const u8) bool {
    const needles = [_][]const u8{
        "json.serialize(",
        "json.serializepretty(",
        "json.deserialize(",
        "json.deserializeuntyped(",
        "json.deserializestrict(",
        "json.createparser(",
        "json.creategenerator(",
    };
    return containsAnyCaseInsensitive(line, &needles);
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

fn containsAnyCaseInsensitive(line: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfCaseInsensitive(line, needle) != null) return true;
    }
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
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

test "collectDoWhileStartConditions links do line to tail condition" {
    const source =
        \\public with sharing class DoWhileMapService {
        \\    public static void run(List<Account> records) {
        \\        Integer i = 0;
        \\        Integer n = records.size();
        \\        do {
        \\            i += 1;
        \\        } while (i < n);
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mapped = try collectDoWhileStartConditions(allocator, source);
    const cond = mapped.get(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("i < n", cond);
}

test "collectDoWhileStartConditions supports do on separate line from brace" {
    const source =
        \\public with sharing class DoWhileSplitMapService {
        \\    public static void run(List<Account> records) {
        \\        Integer i = 0;
        \\        Integer n = records.size();
        \\        do
        \\        {
        \\            i += 1;
        \\        } while (i < n);
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mapped = try collectDoWhileStartConditions(allocator, source);
    const cond = mapped.get(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("i < n", cond);
}

test "do-while loop uses inferred guard bound for DML finding" {
    const source =
        \\public with sharing class DoWhileGuardService {
        \\    public static void run(List<Account> records) {
        \\        Integer n = records.size();
        \\        if (n > 120) return;
        \\        Integer i = 0;
        \\        do
        \\        {
        \\            update records[i];
        \\            i += 1;
        \\        } while (i < n);
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
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

test "Database.countQuery in loop is treated as SOQL" {
    const source =
        \\public with sharing class CountQueryLoopService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 90) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            Integer c = Database.countQuery('SELECT count() FROM Account');
        \\            if (c < 0) break;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const soql = findFindingByRule(findings.items, "AG002") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, soql.message, "Loop upper bound <= 90") != null);
}

test "Database.merge in loop is treated as DML" {
    const source =
        \\public with sharing class MergeLoopService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            Database.merge(records[i], new Account());
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

test "JSON.deserializeUntyped in loop is flagged as JSON work" {
    const source =
        \\public with sharing class JsonUntypedLoopService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 100) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped('{"a":1}');
        \\            String pretty = JSON.serializePretty(payload);
        \\            if (pretty == null) break;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const json = findFindingByRule(findings.items, "AG004") orelse return error.TestUnexpectedResult;
    try std.testing.expect(json.severity == .warning);
    const cpu = findFindingByRule(findings.items, "AG009") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, cpu.title, "JSON") != null);
}

test "SOSL in loop is flagged as AG008" {
    const source =
        \\public with sharing class SoslLoopService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 25) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            List<List<SObject>> result = [FIND 'Acme*' IN ALL FIELDS RETURNING Account(Id)];
        \\            if (result.isEmpty()) break;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const sosl = findFindingByRule(findings.items, "AG008") orelse return error.TestUnexpectedResult;
    try std.testing.expect(sosl.severity == .err);
    try std.testing.expect(std.mem.indexOf(u8, sosl.message, "Loop upper bound <= 25") != null);
}

test "Http send in loop is flagged as AG010" {
    const source =
        \\public with sharing class CalloutLoopService {
        \\    public static void run(List<Account> records) {
        \\        Http client = new Http();
        \\        HttpRequest req = new HttpRequest();
        \\        if (records.size() > 110) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            HttpResponse res = client.send(req);
        \\            if (res == null) break;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const callout = findFindingByRule(findings.items, "AG010") orelse return error.TestUnexpectedResult;
    try std.testing.expect(callout.severity == .err);
    try std.testing.expect(std.mem.indexOf(u8, callout.message, "Loop upper bound <= 110") != null);
}

test "Messaging.sendEmail in loop is flagged as AG011" {
    const source =
        \\public with sharing class MessagingLoopService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 12) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        \\            Messaging.sendEmail(new Messaging.SingleEmailMessage[] { m });
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const msg = findFindingByRule(findings.items, "AG011") orelse return error.TestUnexpectedResult;
    try std.testing.expect(msg.severity == .err);
    try std.testing.expect(std.mem.indexOf(u8, msg.message, "Loop upper bound <= 12") != null);
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

test "loop calling helper in another class is flagged" {
    const sources = [_]SourceFile{
        .{
            .name = "CrossFileCallerService.cls",
            .source =
            \\public with sharing class CrossFileCallerService {
            \\    public static void run(List<Account> records) {
            \\        Integer n = records.size();
            \\        if (n > 110) return;
            \\        for (Integer i = 0; i < n; i++) {
            \\            CrossFileDmlHelper.apply(records[i]);
            \\        }
            \\    }
            \\}
            ,
        },
        .{
            .name = "CrossFileDmlHelper.cls",
            .source =
            \\public with sharing class CrossFileDmlHelper {
            \\    public static void apply(Account acc) {
            \\        update acc;
            \\    }
            \\}
            ,
        },
    };

    var findings = try runCheckOnTempSources(std.testing.allocator, &sources, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 110") != null);
}

test "loop calling helper chain across classes propagates SOQL" {
    const sources = [_]SourceFile{
        .{
            .name = "CrossFileSoqlCaller.cls",
            .source =
            \\public with sharing class CrossFileSoqlCaller {
            \\    public static void run(List<Account> records) {
            \\        Integer n = records.size();
            \\        if (n > 70) return;
            \\        for (Integer i = 0; i < n; i++) {
            \\            CrossFileService.enrich(records[i].Id);
            \\        }
            \\    }
            \\}
            ,
        },
        .{
            .name = "CrossFileService.cls",
            .source =
            \\public with sharing class CrossFileService {
            \\    public static void enrich(Id accountId) {
            \\        CrossFileRepo.loadOne(accountId);
            \\    }
            \\}
            ,
        },
        .{
            .name = "CrossFileRepo.cls",
            .source =
            \\public with sharing class CrossFileRepo {
            \\    public static void loadOne(Id accountId) {
            \\        List<Account> one = [SELECT Id FROM Account WHERE Id = :accountId LIMIT 1];
            \\        if (!one.isEmpty()) {
            \\            one[0].Name = one[0].Name;
            \\        }
            \\    }
            \\}
            ,
        },
    };

    var findings = try runCheckOnTempSources(std.testing.allocator, &sources, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const soql = findFindingByRule(findings.items, "AG002") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, soql.message, "Loop upper bound <= 70") != null);
}

test "helper signature with brace on next line is summarized" {
    const source =
        \\public with sharing class SplitBraceHelperService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 100) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            applyOne(records[i]);
        \\        }
        \\    }
        \\
        \\    private static void applyOne(Account acc)
        \\    {
        \\        update acc;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 100") != null);
}

test "callee inner loop multiplies governor estimate" {
    const source =
        \\public with sharing class InnerLoopMultiplierService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 40) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            applyFive(records[i]);
        \\        }
        \\    }
        \\
        \\    private static void applyFive(Account acc) {
        \\        for (Integer j = 0; j < 5; j++) {
        \\            update acc;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(dml.severity == .err);
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "up to 200 times") != null);
}

test "callee looped helper call multiplies transitive DML" {
    const source =
        \\public with sharing class NestedHelperMultiplierService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 50) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            applyFourTimes(records[i]);
        \\        }
        \\    }
        \\
        \\    private static void applyFourTimes(Account acc) {
        \\        for (Integer j = 0; j < 4; j++) {
        \\            applyOne(acc);
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
    try std.testing.expect(dml.severity == .err);
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "up to 200 times") != null);
}

test "overloaded methods use arity to avoid false positive" {
    const source =
        \\public with sharing class OverloadPrecisionService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            touch(records[i]);
        \\        }
        \\    }
        \\
        \\    private static void touch(Account acc) {
        \\        acc.Name = acc.Name;
        \\    }
        \\
        \\    private static void touch(Account acc, Boolean write) {
        \\        update acc;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG003") == null);
}

test "overloaded methods match arity for positive detection" {
    const source =
        \\public with sharing class OverloadPositiveService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            touch(records[i], true);
        \\        }
        \\    }
        \\
        \\    private static void touch(Account acc) {
        \\        acc.Name = acc.Name;
        \\    }
        \\
        \\    private static void touch(Account acc, Boolean write) {
        \\        update acc;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

test "same arity overload uses argument type for negative case" {
    const source =
        \\public with sharing class SameArityOverloadNegativeService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            touch(new Account());
        \\        }
        \\    }
        \\
        \\    private static void touch(Account acc) {
        \\        acc.Name = acc.Name;
        \\    }
        \\
        \\    private static void touch(Contact con) {
        \\        update con;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG003") == null);
}

test "same arity overload uses argument type for positive case" {
    const source =
        \\public with sharing class SameArityOverloadPositiveService {
        \\    public static void run(List<Contact> records) {
        \\        if (records.size() > 120) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            touch(new Contact());
        \\        }
        \\    }
        \\
        \\    private static void touch(Account acc) {
        \\        acc.Name = acc.Name;
        \\    }
        \\
        \\    private static void touch(Contact con) {
        \\        update con;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

test "same arity overload uses local variable type for negative case" {
    const source =
        \\public with sharing class SameArityLocalVarNegativeService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            Account acc = new Account();
        \\            touch(acc);
        \\        }
        \\    }
        \\
        \\    private static void touch(Account acc) {
        \\        acc.Name = acc.Name;
        \\    }
        \\
        \\    private static void touch(Contact con) {
        \\        update con;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG003") == null);
}

test "same arity overload uses indexed collection element type for positive case" {
    const source =
        \\public with sharing class SameArityIndexedPositiveService {
        \\    public static void run(List<Contact> contacts) {
        \\        if (contacts.size() > 120) return;
        \\        for (Integer i = 0; i < contacts.size(); i++) {
        \\            touch(contacts[i]);
        \\        }
        \\    }
        \\
        \\    private static void touch(Account acc) {
        \\        acc.Name = acc.Name;
        \\    }
        \\
        \\    private static void touch(Contact con) {
        \\        update con;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

fn runCheckOnTempSource(
    gpa: std.mem.Allocator,
    source: []const u8,
    cfg: config.Config,
) !std.ArrayList(model.Finding) {
    const sources = [_]SourceFile{
        .{
            .name = "Case.cls",
            .source = source,
        },
    };
    return runCheckOnTempSources(gpa, &sources, cfg);
}

const SourceFile = struct {
    name: []const u8,
    source: []const u8,
};

fn runCheckOnTempSources(
    gpa: std.mem.Allocator,
    sources: []const SourceFile,
    cfg: config.Config,
) !std.ArrayList(model.Finding) {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (sources) |file| {
        try tmp.dir.writeFile(.{ .sub_path = file.name, .data = file.source });
    }

    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
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
