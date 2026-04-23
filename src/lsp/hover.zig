//! hover — カーソル位置のシンボル情報を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");

pub fn get_hover(result: *const binder_mod.BindResult, source: []const u8, offset: u32, allocator: std.mem.Allocator) !?lsp_types.HoverResult {
    _ = source;
    const sym = binder_mod.symbol_at_position(result, offset) orelse return null;

    const text = try format_symbol(sym, allocator);
    return .{ .contents = .{ .kind = "markdown", .value = text } };
}

fn format_symbol(sym: *const binder_mod.Symbol, allocator: std.mem.Allocator) ![]const u8 {
    const kind_str = switch (sym.kind) {
        .class => "class",
        .interface => "interface",
        .enum_type => "enum",
        .enum_value => "enum value",
        .method => "method",
        .constructor => "constructor",
        .field => "field",
        .parameter => "parameter",
        .local_variable, .for_each_variable, .catch_variable => "variable",
        .trigger => "trigger",
    };
    if (sym.type_name) |t| {
        return std.fmt.allocPrint(allocator, "({s}) {s}: {s}", .{ kind_str, sym.name, t });
    }
    return std.fmt.allocPrint(allocator, "({s}) {s}", .{ kind_str, sym.name });
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

const TestHoverCtx = struct {
    arena: std.heap.ArenaAllocator,
    result: ?lsp_types.HoverResult,
    fn deinit(self: *TestHoverCtx) void {
        self.arena.deinit();
    }
};

fn hover_at(source: []const u8, name: []const u8) !TestHoverCtx {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const sym = blk: {
        for (br.symbols) |*s| {
            if (std.mem.eql(u8, s.name, name)) break :blk s;
        }
        break :blk null;
    };
    const offset = if (sym) |s| s.loc.offset else 0;
    const r = try get_hover(&br, source, offset, alloc);
    return .{ .arena = arena, .result = r };
}

test "hover on variable shows type" {
    var ctx = try hover_at("public class Foo { public void run() { Integer x = 1; } }", "x");
    defer ctx.deinit();

    try std.testing.expect(ctx.result != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.result.?.contents.value, "Integer") != null);
}

test "hover on method shows signature" {
    var ctx = try hover_at("public class Foo { public String getName() { return null; } }", "getName");
    defer ctx.deinit();

    try std.testing.expect(ctx.result != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.result.?.contents.value, "method") != null);
}

test "hover on class shows class info" {
    var ctx = try hover_at("public class Foo {}", "Foo");
    defer ctx.deinit();

    try std.testing.expect(ctx.result != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.result.?.contents.value, "class") != null);
}

test "hover on empty space returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);
    const result = try get_hover(&br, source, 6, alloc);
    try std.testing.expect(result == null);
}
