//! signature_help — メソッド呼び出し中の引数ヒントを返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const parser_types = @import("../apex_parser/types.zig");

const OpenParen = struct {
    method_end: u32,
    comma_count: u32,
};

const IdentifierRange = struct {
    start: u32,
    end: u32,
    name: []const u8,
};

fn find_enclosing_open_paren(source: []const u8, offset: u32) ?OpenParen {
    var paren_depth: i32 = 0;
    var comma_count: u32 = 0;
    var i: u32 = offset;
    while (i > 0) {
        i -= 1;
        const ch = source[i];
        if (ch == ')') {
            paren_depth += 1;
        } else if (ch == '(') {
            if (paren_depth == 0) return .{ .method_end = i, .comma_count = comma_count };
            paren_depth -= 1;
        } else if (ch == ',' and paren_depth == 0) {
            comma_count += 1;
        }
    }
    return null;
}

pub fn get_signature_help(
    result: *const binder_mod.BindResult,
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
) !?lsp_types.SignatureHelp {
    const open = find_enclosing_open_paren(source, offset) orelse return null;
    const ident = identifier_ending_at(source, open.method_end) orelse return null;

    // binder でシンボル解決
    const sym = binder_mod.symbol_at_position(result, ident.start) orelse return null;
    if (!is_callable(sym.kind)) return null;

    return try signature_for_symbol(result, sym, open.comma_count, allocator);
}

pub fn get_signature_help_cross_file(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) !?lsp_types.SignatureHelp {
    if (try get_signature_help(result, source, offset, allocator)) |local| return local;

    const open = find_enclosing_open_paren(source, offset) orelse return null;
    const ident = identifier_ending_at(source, open.method_end) orelse return null;
    const arg_count = position_mod.call_arg_count_at_offset(tokens, ident.start);

    if (position_mod.this_member_at_offset(tokens, ident.start)) |member| {
        if (binder_mod.resolve_current_class_member_with_arity(
            result,
            ident.start,
            member.member_name,
            arg_count,
        )) |sym| {
            if (!is_callable(sym.kind)) return null;
            return try signature_for_symbol(result, sym, open.comma_count, allocator);
        }
    }

    if (position_mod.qualified_member_at_offset(tokens, ident.start)) |member| {
        if (store.resolve_member_across_files_with_arity(
            member.receiver_name,
            member.member_name,
            uri,
            arg_count,
        )) |match| {
            const br = try store.ensure_bound(match.uri) orelse return null;
            if (!is_callable(match.symbol.kind)) return null;
            return try signature_for_symbol(br, &match.symbol, open.comma_count, allocator);
        }
    }

    if (binder_mod.resolve_current_class_member_with_arity(
        result,
        ident.start,
        ident.name,
        arg_count,
    )) |sym| {
        if (!is_callable(sym.kind)) return null;
        return try signature_for_symbol(result, sym, open.comma_count, allocator);
    }

    return null;
}

fn identifier_ending_at(source: []const u8, end: u32) ?IdentifierRange {
    var i = end;
    while (i > 0 and std.ascii.isWhitespace(source[i - 1])) i -= 1;
    const name_end = i;
    while (i > 0 and (std.ascii.isAlphanumeric(source[i - 1]) or source[i - 1] == '_')) {
        i -= 1;
    }
    if (i == name_end) return null;
    return .{ .start = i, .end = name_end, .name = source[i..name_end] };
}

fn is_callable(kind: binder_mod.SymbolKind) bool {
    return kind == .method or kind == .constructor;
}

fn signature_for_symbol(
    result: *const binder_mod.BindResult,
    sym: *const binder_mod.Symbol,
    active_parameter: u32,
    allocator: std.mem.Allocator,
) !lsp_types.SignatureHelp {
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
        .activeParameter = active_parameter,
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
    const result = try get_signature_help(&br, source, @intCast(call_pos), alloc);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.signatures.len > 0);
}

test "cross-file helper resolves later same-class member call" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class Foo {
        \\    public class Inner {
        \\        private void innerOnly() {}
        \\    }
        \\    public void run() {
        \\        helper('x');
        \\    }
        \\    private Integer helper(String label) { return 1; }
        \\}
    ;
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "helper('").? + "helper('".len);
    const result = try get_signature_help_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        offset,
        &store,
        arena.allocator(),
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.signatures.len);
    try std.testing.expect(
        std.mem.indexOf(u8, result.?.signatures[0].label, "helper") != null,
    );
    try std.testing.expectEqual(@as(usize, 1), result.?.signatures[0].parameters.len);
    try std.testing.expectEqualStrings("String label", result.?.signatures[0].parameters[0].label);
}

test "outside call returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const source = "public class Foo { public void run() {} }";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const result = try get_signature_help(&br, source, 0, alloc);
    try std.testing.expect(result == null);
}
