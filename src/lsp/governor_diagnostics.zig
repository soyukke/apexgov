//! governor_diagnostics — check/ モジュールの Governor 制限違反を LSP diagnostics に変換する。

const std = @import("std");
const lsp_types = @import("types.zig");
const model = @import("../model.zig");
const config = @import("../config.zig");
const check_scanner = @import("../check/scanner.zig");
const check_types = @import("../check/types.zig");
const preprocessor = @import("../check/preprocessor.zig");

/// 単一ファイルの Governor 制限違反を検出し、LSP Diagnostic に変換する。
pub fn collect(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
) ![]lsp_types.Diagnostic {
    var findings: std.ArrayList(model.Finding) = .empty;
    defer {
        for (findings.items) |f| {
            allocator.free(f.title);
            allocator.free(f.message);
            allocator.free(f.file);
        }
        findings.deinit(allocator);
    }

    // 単一ファイルモード: 空の method_summaries / type_relations / name_index
    var method_summaries = std.StringHashMap(check_types.MethodSummary).init(allocator);
    defer method_summaries.deinit();

    var name_index = check_types.MethodNameIndex.init(allocator);
    defer name_index.deinit();

    var extends = std.StringHashMap([]const u8).init(allocator);
    defer extends.deinit();

    var interfaces = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer interfaces.deinit();

    const type_relations = check_types.TypeRelations{
        .extends_by_type = extends,
        .interfaces_by_type = interfaces,
    };

    const stripped_content = try preprocessor.stripCommentsPreserveLines(allocator, content);
    defer allocator.free(stripped_content);

    try check_scanner.scanContent(
        allocator,
        path,
        stripped_content,
        config.Config.defaults(),
        &method_summaries,
        &name_index,
        &type_relations,
        &findings,
    );

    // Finding → LSP Diagnostic に変換
    var diags: std.ArrayList(lsp_types.Diagnostic) = .empty;
    for (findings.items) |f| {
        const line: u32 = if (f.line > 0) @intCast(f.line - 1) else 0;
        try diags.append(allocator, .{
            .range = .{
                .start = .{ .line = line, .character = 0 },
                .end = .{ .line = line, .character = 0 },
            },
            .severity = mapSeverity(f.severity),
            .code = f.rule_id,
            .source = "apexgov-governor",
            .message = try allocator.dupe(u8, f.message),
        });
    }

    return diags.toOwnedSlice(allocator);
}

fn mapSeverity(s: model.Severity) lsp_types.DiagnosticSeverity {
    return switch (s) {
        .err => .@"error",
        .warning => .warning,
        .info => .information,
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "SOQL in loop produces AG002 diagnostic" {
    const source =
        \\public class Foo {
        \\    public void run() {
        \\        for (Integer i = 0; i < 10; i++) {
        \\            List<Account> accs = [SELECT Id FROM Account];
        \\        }
        \\    }
        \\}
    ;
    const diags = try collect(std.testing.allocator, "Test.cls", source);
    defer {
        for (diags) |d| {
            if (d.message.len > 0) std.testing.allocator.free(d.message);
        }
        std.testing.allocator.free(diags);
    }

    // AG002 が含まれているか
    var found_ag002 = false;

    for (diags) |d| {
        if (d.code) |code| {
            if (std.mem.eql(u8, code, "AG002")) {
                found_ag002 = true;
                break;
            }
        }
    }
    try std.testing.expect(found_ag002);
}

test "DML in loop produces AG003 diagnostic" {
    const source =
        \\public class Foo {
        \\    public void run() {
        \\        for (Integer i = 0; i < 10; i++) {
        \\            insert new Account(Name='Test');
        \\        }
        \\    }
        \\}
    ;
    const diags = try collect(std.testing.allocator, "Test.cls", source);
    defer {
        for (diags) |d| {
            if (d.message.len > 0) std.testing.allocator.free(d.message);
        }
        std.testing.allocator.free(diags);
    }

    var found_ag003 = false;

    for (diags) |d| {
        if (d.code) |code| {
            if (std.mem.eql(u8, code, "AG003")) {
                found_ag003 = true;
                break;
            }
        }
    }
    try std.testing.expect(found_ag003);
}

test "clean code produces no governor diagnostics" {
    const source =
        \\public class Foo {
        \\    public void run() {
        \\        Integer x = 1 + 2;
        \\    }
        \\}
    ;
    const diags = try collect(std.testing.allocator, "Test.cls", source);
    defer {
        for (diags) |d| {
            if (d.message.len > 0) std.testing.allocator.free(d.message);
        }
        std.testing.allocator.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "severity mapping" {
    try std.testing.expectEqual(lsp_types.DiagnosticSeverity.@"error", mapSeverity(.err));
    try std.testing.expectEqual(lsp_types.DiagnosticSeverity.warning, mapSeverity(.warning));
    try std.testing.expectEqual(lsp_types.DiagnosticSeverity.information, mapSeverity(.info));
}
