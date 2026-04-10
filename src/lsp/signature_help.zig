//! signature_help — メソッド呼び出し中の引数ヒントを返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const parser_types = @import("../apex_parser/types.zig");

pub fn getSignatureHelp(
    result: *const binder_mod.BindResult,
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
) !?lsp_types.SignatureHelp {
    // offset から逆方向に '(' を探す
    var paren_depth: i32 = 0;
    var comma_count: u32 = 0;
    var i: u32 = offset;
    var found_open: bool = false;
    var method_end: u32 = 0;

    while (i > 0) {
        i -= 1;
        const ch = source[i];
        if (ch == ')') {
            paren_depth += 1;
        } else if (ch == '(') {
            if (paren_depth == 0) {
                found_open = true;
                method_end = i;
                break;
            }
            paren_depth -= 1;
        } else if (ch == ',' and paren_depth == 0) {
            comma_count += 1;
        }
    }

    if (!found_open) return null;

    // '(' の直前のシンボルを探す
    var name_end = method_end;
    while (name_end > 0 and source[name_end - 1] == ' ') name_end -= 1;
    if (name_end == 0) return null;

    // binder でシンボル解決
    const sym = binder_mod.symbolAtPosition(result, name_end - 1) orelse return null;
    if (sym.kind != .method and sym.kind != .constructor) return null;

    // パラメータ情報を構築
    // method のパラメータシンボルを children から探す
    var params: std.ArrayList(lsp_types.ParameterInformation) = .empty;
    for (result.symbols) |s| {
        if (s.parent != null and s.parent.? == sym.id and s.kind == .parameter) {
            const label = if (s.type_name) |t|
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ t, s.name })
            else
                s.name;
            try params.append(allocator, .{ .label = label });
        }
    }

    const label = if (sym.type_name) |t|
        try std.fmt.allocPrint(allocator, "{s} {s}(...)", .{ t, sym.name })
    else
        try std.fmt.allocPrint(allocator, "{s}(...)", .{sym.name});

    const sigs = try allocator.alloc(lsp_types.SignatureInformation, 1);
    sigs[0] = .{
        .label = label,
        .parameters = try params.toOwnedSlice(allocator),
    };

    return .{
        .signatures = sigs,
        .activeSignature = 0,
        .activeParameter = comma_count,
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

test "inside method call shows params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "public class Foo { public void run(String name, Integer count) { run(); } }";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    // 'run(' の後にカーソル
    const call_pos = std.mem.indexOf(u8, source, "run();").? + 4; // after '('
    const result = try getSignatureHelp(&br, source, @intCast(call_pos), alloc);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.signatures.len > 0);
}

test "outside call returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "public class Foo { public void run() {} }";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const result = try getSignatureHelp(&br, source, 0, alloc);
    try std.testing.expect(result == null);
}
