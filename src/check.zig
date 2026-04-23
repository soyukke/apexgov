//! check — Apex 静的解析のファサード。
//!
//! Governor 制限違反（ループ内 SOQL/DML/Callout 等）のヒューリスティック検出を行う。
//! 解析の実体は `check/` 配下のサブモジュールに分割されており、本ファイルは
//! 公開 API (`run`, `runWithConfig`) の再エクスポートとテストを提供する。

const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");
const config = @import("config.zig");

// Sub-modules
const types = @import("check/types.zig");
const preprocessor_mod = @import("check/preprocessor.zig");
const bounds_mod = @import("check/bounds.zig");
const call_graph_mod = @import("check/call_graph.zig");
const rules_mod = @import("check/rules.zig");
const file_collector = @import("check/file_collector.zig");
const scanner_mod = @import("check/scanner.zig");

// Re-export type names for test usage
const Bound = types.Bound;
const MethodSummary = types.MethodSummary;
const TypeRelations = types.TypeRelations;
const ApexFile = types.ApexFile;

// Re-export functions for internal test usage
const parseGuardUpperBound = bounds_mod.parseGuardUpperBound;
const inferLoopInfo = bounds_mod.inferLoopInfo;
const collectDoWhileStartConditions = preprocessor_mod.collectDoWhileStartConditions;
const computeCpuLimitN = rules_mod.computeCpuLimitN;
const estimateCpuTotalMs = rules_mod.estimateCpuTotalMs;

// Delegates
const collectApexFiles = file_collector.collectApexFiles;
const deinitApexFiles = file_collector.deinitApexFiles;
const collectTypeRelations = call_graph_mod.collectTypeRelations;
const buildMethodSummaries = call_graph_mod.buildMethodSummaries;
const scanContent = scanner_mod.scanContent;
const stripCommentsPreserveLines = preprocessor_mod.stripCommentsPreserveLines;

pub fn run(gpa: std.mem.Allocator, io: Io, roots: []const []const u8) !std.ArrayList(model.Finding) {
    return runWithConfig(gpa, io, roots, config.Config.defaults());
}

pub fn runWithConfig(gpa: std.mem.Allocator, io: Io, roots: []const []const u8, cfg: config.Config) !std.ArrayList(model.Finding) {
    var findings: std.ArrayList(model.Finding) = .empty;
    errdefer model.deinitFindings(gpa, &findings);

    var files = try collectApexFiles(gpa, io, roots);
    defer deinitApexFiles(gpa, &files);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // 各ファイルの stripped_content を事前計算（1回だけ strip）
    for (files.items) |*file| {
        file.stripped_content = try stripCommentsPreserveLines(arena_allocator, file.content);
    }

    var type_relations = try collectTypeRelations(arena_allocator, files.items);
    var build_result = try buildMethodSummaries(arena_allocator, files.items, &type_relations);

    for (files.items) |file| {
        try scanContent(
            gpa,
            file.path,
            file.stripped_content,
            cfg,
            &build_result.summaries,
            &build_result.name_index,
            &type_relations,
            &findings,
        );
    }

    return findings;
}

// --------------- Test helpers ---------------

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
    var findings: std.ArrayList(model.Finding) = .empty;
    errdefer model.deinitFindings(gpa, &findings);

    // Build ApexFile slice directly from in-memory sources (no file I/O).
    var files = try std.ArrayList(ApexFile).initCapacity(gpa, sources.len);
    defer files.deinit(gpa);
    for (sources) |src| {
        files.appendAssumeCapacity(.{ .path = src.name, .content = src.source });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    for (files.items) |*file| {
        file.stripped_content = try stripCommentsPreserveLines(arena_alloc, file.content);
    }

    var type_relations = try collectTypeRelations(arena_alloc, files.items);
    var build_result = try buildMethodSummaries(arena_alloc, files.items, &type_relations);

    for (files.items) |file| {
        try scanContent(gpa, file.path, file.stripped_content, cfg, &build_result.summaries, &build_result.name_index, &type_relations, &findings);
    }

    return findings;
}

fn findFindingByRule(findings: []const model.Finding, rule_id: []const u8) ?model.Finding {
    for (findings) |finding| {
        if (std.mem.eql(u8, finding.rule_id, rule_id)) return finding;
    }
    return null;
}

// --------------- Tests ---------------

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

test "block comment inside loop does not trigger DML finding" {
    const source =
        \\public with sharing class BlockCommentInlineService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 100) return;
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            /* update records[i]; */
        \\            records[i].Name = records[i].Name;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG003") == null);
}

test "multiline block comment is ignored while real DML is still detected" {
    const source =
        \\public with sharing class BlockCommentMultilineService {
        \\    public static void run(List<Account> records) {
        \\        Integer n = records.size();
        \\        if (n > 120) return;
        \\        /*
        \\            debug memo:
        \\            update records[i];
        \\        */
        \\        for (Integer i = 0; i < n; i++) {
        \\            update records[i];
        \\        }
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

test "guard with OR still constrains bounded variable" {
    const source =
        \\public with sharing class OrGuardService {
        \\    public static void run(List<Account> records, Boolean bypass) {
        \\        Integer n = records.size();
        \\        if (n > 120 || bypass) return;
        \\        for (Integer i = 0; i < n; i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

test "assignment arithmetic upper bound is inferred from aliases" {
    const source =
        \\public with sharing class ArithmeticAliasBoundService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        Integer n = records.size() - 1;
        \\        for (Integer i = 0; i < n; i++) {
        \\            update records[i];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 119") != null);
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

test "typed receiver call resolves when variable is bound to new concrete helper" {
    const source =
        \\public interface Updater {
        \\    void apply(Account acc);
        \\}
        \\
        \\public with sharing class DmlUpdater implements Updater {
        \\    public void apply(Account acc) {
        \\        update acc;
        \\    }
        \\}
        \\
        \\public with sharing class TypedReceiverDispatchService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        Updater updater = new DmlUpdater();
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            updater.apply(records[i]);
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

test "typed receiver reassignment to concrete helper is reflected in call resolution" {
    const source =
        \\public interface Updater {
        \\    void apply(Account acc);
        \\}
        \\
        \\public with sharing class DmlUpdater implements Updater {
        \\    public void apply(Account acc) {
        \\        update acc;
        \\    }
        \\}
        \\
        \\public with sharing class TypedReceiverReassignService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        Updater updater = null;
        \\        updater = new DmlUpdater();
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            updater.apply(records[i]);
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
}

test "dynamic dispatch resolves through interface-typed helper parameter" {
    const source =
        \\public interface Updater {
        \\    void apply(Account acc);
        \\}
        \\
        \\public with sharing class DmlUpdater implements Updater {
        \\    public void apply(Account acc) {
        \\        update acc;
        \\    }
        \\}
        \\
        \\public with sharing class InterfaceDispatchThroughParamService {
        \\    public static void run(List<Account> records) {
        \\        if (records.size() > 120) return;
        \\        Updater updater = new DmlUpdater();
        \\        for (Integer i = 0; i < records.size(); i++) {
        \\            invoke(updater, records[i]);
        \\        }
        \\    }
        \\
        \\    private static void invoke(Updater updater, Account acc) {
        \\        updater.apply(acc);
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    const dml = findFindingByRule(findings.items, "AG003") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, dml.message, "Loop upper bound <= 120") != null);
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

// --------------- SOQL for ループ偽陽性テスト ---------------

test "SOQL for loop does not trigger AG002" {
    const source =
        \\public with sharing class SoqlForLoopService {
        \\    public static Integer countAccounts() {
        \\        Integer count = 0;
        \\        for (Account acct : [SELECT Name FROM Account]) {
        \\            count++;
        \\        }
        \\        return count;
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG002") == null);
    try std.testing.expect(findFindingByRule(findings.items, "AG009") == null);
}

test "nested SOQL for loop inside outer loop triggers AG002" {
    const source =
        \\public with sharing class NestedSoqlForService {
        \\    public static void run() {
        \\        for (Account acct : [SELECT Id FROM Account]) {
        \\            for (Contact c : [SELECT Id FROM Contact WHERE AccountId = :acct.Id]) {
        \\                System.debug(c);
        \\            }
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG002") != null);
}

test "regular SOQL in loop still triggers AG002" {
    const source =
        \\public with sharing class RegularSoqlInLoopService {
        \\    public static void run(List<Account> accounts) {
        \\        for (Account a : accounts) {
        \\            List<Contact> cs = [SELECT Id FROM Contact WHERE AccountId = :a.Id];
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG002") != null);
}

// --------------- @isTest 除外テスト ---------------

test "@isTest class findings are suppressed by default" {
    const source =
        \\@isTest
        \\public class MyTest {
        \\    @isTest
        \\    static void testMethod() {
        \\        for (Account a : [SELECT Id FROM Account]) {
        \\            for (Contact c : [SELECT Id FROM Contact]) {
        \\                System.debug(c);
        \\            }
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "@isTest class findings shown with include_tests" {
    const source =
        \\@isTest
        \\public class MyTest {
        \\    @isTest
        \\    static void testMethod() {
        \\        for (Account a : [SELECT Id FROM Account]) {
        \\            for (Contact c : [SELECT Id FROM Contact]) {
        \\                System.debug(c);
        \\            }
        \\        }
        \\    }
        \\}
    ;

    var cfg = config.Config.defaults();
    cfg.include_tests = true;
    var findings = try runCheckOnTempSource(std.testing.allocator, source, cfg);
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findings.items.len > 0);
}

test "non-test class still produces findings" {
    const source =
        \\public with sharing class ProductionCode {
        \\    public static void run(List<Account> accounts) {
        \\        for (Account a : accounts) {
        \\            update a;
        \\        }
        \\    }
        \\}
    ;

    var findings = try runCheckOnTempSource(std.testing.allocator, source, config.Config.defaults());
    defer model.deinitFindings(std.testing.allocator, &findings);

    try std.testing.expect(findFindingByRule(findings.items, "AG003") != null);
}
