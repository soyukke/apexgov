//! code_action — Governor 違反に対するクイックフィックス提案。

const std = @import("std");
const lsp_types = @import("types.zig");

pub fn get_code_actions(
    diagnostics: []const lsp_types.Diagnostic,
    range: lsp_types.Range,
    allocator: std.mem.Allocator,
) ![]lsp_types.CodeAction {
    var actions: std.ArrayList(lsp_types.CodeAction) = .empty;

    for (diagnostics) |diag| {
        // range と重なる diagnostics のみ
        if (diag.range.start.line > range.end.line or diag.range.end.line < range.start.line) continue;

        const code = diag.code orelse continue;
        const source = diag.source orelse continue;
        if (!std.mem.eql(u8, source, "apexgov-governor")) continue;

        if (std.mem.eql(u8, code, "AG002")) {
            try actions.append(allocator, .{
                .title = "Move SOQL query before the loop",
                .kind = "quickfix",
            });
        } else if (std.mem.eql(u8, code, "AG003")) {
            try actions.append(allocator, .{
                .title = "Collect records and perform bulk DML after the loop",
                .kind = "quickfix",
            });
        } else if (std.mem.eql(u8, code, "AG010")) {
            try actions.append(allocator, .{
                .title = "Move HTTP callout before the loop",
                .kind = "quickfix",
            });
        }
    }

    return actions.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "SOQL in loop suggests extraction" {
    const diags = [_]lsp_types.Diagnostic{.{
        .range = .{ .start = .{ .line = 3, .character = 0 }, .end = .{ .line = 3, .character = 0 } },
        .severity = .warning,
        .code = "AG002",
        .source = "apexgov-governor",
        .message = "SOQL in loop",
    }};
    const actions = try get_code_actions(
        &diags,
        .{ .start = .{ .line = 3 }, .end = .{ .line = 3 } },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].title, "SOQL") != null);
}

test "DML in loop suggests bulk pattern" {
    const diags = [_]lsp_types.Diagnostic{.{
        .range = .{ .start = .{ .line = 5 }, .end = .{ .line = 5 } },
        .severity = .warning,
        .code = "AG003",
        .source = "apexgov-governor",
        .message = "DML in loop",
    }};
    const actions = try get_code_actions(
        &diags,
        .{ .start = .{ .line = 5 }, .end = .{ .line = 5 } },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].title, "bulk") != null);
}

test "clean code produces no actions" {
    const diags = [_]lsp_types.Diagnostic{};
    const actions = try get_code_actions(&diags, .{}, std.testing.allocator);
    defer std.testing.allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "HTTP callout in loop suggests extraction" {
    const diags = [_]lsp_types.Diagnostic{.{
        .range = .{ .start = .{ .line = 7 }, .end = .{ .line = 7 } },
        .severity = .warning,
        .code = "AG010",
        .source = "apexgov-governor",
        .message = "HTTP callout in loop",
    }};
    const actions = try get_code_actions(
        &diags,
        .{ .start = .{ .line = 7 }, .end = .{ .line = 7 } },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].title, "HTTP") != null);
}

test "diagnostics outside range are excluded" {
    const diags = [_]lsp_types.Diagnostic{
        .{
            .range = .{ .start = .{ .line = 3 }, .end = .{ .line = 3 } },
            .severity = .warning,
            .code = "AG002",
            .source = "apexgov-governor",
            .message = "SOQL in loop",
        },
        .{
            .range = .{ .start = .{ .line = 20 }, .end = .{ .line = 20 } },
            .severity = .warning,
            .code = "AG003",
            .source = "apexgov-governor",
            .message = "DML in loop",
        },
    };
    // range は line 3 のみ → AG002 だけマッチ
    const actions = try get_code_actions(
        &diags,
        .{ .start = .{ .line = 3 }, .end = .{ .line = 3 } },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].title, "SOQL") != null);
}

test "multiple diagnostics on same range produce multiple actions" {
    const diags = [_]lsp_types.Diagnostic{
        .{
            .range = .{ .start = .{ .line = 5 }, .end = .{ .line = 5 } },
            .severity = .warning,
            .code = "AG002",
            .source = "apexgov-governor",
            .message = "SOQL in loop",
        },
        .{
            .range = .{ .start = .{ .line = 6 }, .end = .{ .line = 6 } },
            .severity = .warning,
            .code = "AG003",
            .source = "apexgov-governor",
            .message = "DML in loop",
        },
    };
    const actions = try get_code_actions(
        &diags,
        .{ .start = .{ .line = 5 }, .end = .{ .line = 6 } },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 2), actions.len);
}

test "non-governor diagnostics are ignored" {
    const diags = [_]lsp_types.Diagnostic{.{
        .range = .{ .start = .{ .line = 1 }, .end = .{ .line = 1 } },
        .severity = .@"error",
        .code = "E001",
        .source = "apexgov",
        .message = "syntax error",
    }};
    const actions = try get_code_actions(
        &diags,
        .{ .start = .{ .line = 1 }, .end = .{ .line = 1 } },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}
