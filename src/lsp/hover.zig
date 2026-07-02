//! hover — カーソル位置のシンボル情報を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const parser_types = @import("../apex_parser/types.zig");

pub fn get_hover(
    result: *const binder_mod.BindResult,
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
) !?lsp_types.HoverResult {
    const sym = binder_mod.symbol_at_position(result, offset) orelse return null;

    const text = try format_symbol(sym, source, allocator);
    return .{ .contents = .{ .kind = "markdown", .value = text } };
}

pub fn get_hover_cross_file(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) !?lsp_types.HoverResult {
    if (try get_hover(result, source, offset, allocator)) |local| return local;

    if (position_mod.qualified_member_at_offset(tokens, offset)) |member| {
        if (store.resolve_member_across_files(
            member.receiver_name,
            member.member_name,
            uri,
        )) |match| {
            return try hover_for_symbol(&match.symbol, match.source, allocator);
        }
    }

    const name = position_mod.identifier_at_offset(tokens, offset) orelse return null;
    const match = store.resolve_symbol_across_files(name, uri) orelse return null;
    return try hover_for_symbol(&match.symbol, match.source, allocator);
}

fn hover_for_symbol(
    sym: *const binder_mod.Symbol,
    source: []const u8,
    allocator: std.mem.Allocator,
) !lsp_types.HoverResult {
    const text = try format_symbol(sym, source, allocator);
    return .{ .contents = .{ .kind = "markdown", .value = text } };
}

fn format_symbol(
    sym: *const binder_mod.Symbol,
    source: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
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
    const signature = if (sym.type_name) |t|
        try std.fmt.allocPrint(allocator, "({s}) {s}: {s}", .{ kind_str, sym.name, t })
    else
        try std.fmt.allocPrint(allocator, "({s}) {s}", .{ kind_str, sym.name });

    const doc = try apex_doc_before(source, sym.loc.offset, allocator) orelse return signature;
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ signature, doc });
}

fn apex_doc_before(
    source: []const u8,
    offset: u32,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    if (offset == 0 or offset > source.len) return null;
    var start = line_start_before(source, offset);
    while (previous_line(source, start)) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r\n");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "@")) {
            start = line.start;
            continue;
        }
        break;
    }

    var i = start;
    while (i > 0 and std.ascii.isWhitespace(source[i - 1])) i -= 1;
    if (i < 2 or !std.mem.eql(u8, source[i - 2 .. i], "*/")) return null;
    const doc_start = std.mem.lastIndexOf(u8, source[0 .. i - 2], "/**") orelse return null;
    return try clean_apex_doc(source[doc_start + 3 .. i - 2], allocator);
}

fn clean_apex_doc(raw: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var out: std.ArrayList(u8) = .empty;
    while (lines.next()) |line| {
        var text = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, text, "*")) {
            text = std.mem.trim(u8, text[1..], " \t");
        }
        if (out.items.len == 0 and text.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try append_apex_doc_line(&out, allocator, text);
    }
    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) {
        _ = out.pop();
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn append_apex_doc_line(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    if (!std.mem.startsWith(u8, text, "@")) {
        try out.appendSlice(allocator, text);
        return;
    }

    const tag_end = for (text, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) break i;
    } else text.len;
    const tag = text[0..tag_end];
    const rest = std.mem.trim(u8, text[tag_end..], " \t");

    try append_doc_tag(out, allocator, tag);
    switch (classify_apex_doc_tag(tag)) {
        .param => try append_tag_rest(out, allocator, rest, append_param_doc_rest),
        .return_value => try append_tag_rest(out, allocator, rest, append_return_doc_rest),
        .throws_value => try append_tag_rest(out, allocator, rest, append_throws_doc_rest),
        else => {
            if (rest.len > 0) {
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, rest);
            }
        },
    }
}

const ApexDocTagKind = enum {
    description,
    param,
    return_value,
    throws_value,
    see,
    since,
    deprecated,
    example,
    group,
    author,
    version,
    unknown,
};

fn classify_apex_doc_tag(tag: []const u8) ApexDocTagKind {
    const name = if (std.mem.startsWith(u8, tag, "@")) tag[1..] else tag;
    if (std.ascii.eqlIgnoreCase(name, "description")) return .description;
    if (std.ascii.eqlIgnoreCase(name, "param")) return .param;
    if (std.ascii.eqlIgnoreCase(name, "return") or
        std.ascii.eqlIgnoreCase(name, "returns"))
    {
        return .return_value;
    }
    if (std.ascii.eqlIgnoreCase(name, "throws") or
        std.ascii.eqlIgnoreCase(name, "exception"))
    {
        return .throws_value;
    }
    if (std.ascii.eqlIgnoreCase(name, "see")) return .see;
    if (std.ascii.eqlIgnoreCase(name, "since")) return .since;
    if (std.ascii.eqlIgnoreCase(name, "deprecated")) return .deprecated;
    if (std.ascii.eqlIgnoreCase(name, "example")) return .example;
    if (std.ascii.eqlIgnoreCase(name, "group")) return .group;
    if (std.ascii.eqlIgnoreCase(name, "author")) return .author;
    if (std.ascii.eqlIgnoreCase(name, "version")) return .version;
    return .unknown;
}

fn append_doc_tag(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    tag: []const u8,
) !void {
    try out.appendSlice(allocator, "**");
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, "**");
}

fn append_tag_rest(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rest: []const u8,
    comptime append_fn: fn (*std.ArrayList(u8), std.mem.Allocator, []const u8) anyerror!void,
) !void {
    if (rest.len == 0) return;
    try out.append(allocator, ' ');
    try append_fn(out, allocator, rest);
}

const BracedType = struct {
    type_name: []const u8,
    rest: []const u8,
};

fn consume_braced_type(rest: []const u8) ?BracedType {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (!std.mem.startsWith(u8, trimmed, "{")) return null;
    const close = std.mem.indexOfScalar(u8, trimmed, '}') orelse return null;
    if (close <= 1) return null;
    return .{
        .type_name = std.mem.trim(u8, trimmed[1..close], " \t"),
        .rest = std.mem.trim(u8, trimmed[close + 1 ..], " \t"),
    };
}

fn append_param_doc_rest(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rest: []const u8,
) !void {
    const parsed_type = consume_braced_type(rest);
    const param_text = if (parsed_type) |pt| pt.rest else rest;
    const param_rest = std.mem.trim(u8, param_text, " \t");
    const name_end = for (param_rest, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) break i;
    } else param_rest.len;
    if (name_end == 0) {
        try out.appendSlice(allocator, rest);
        return;
    }

    try out.append(allocator, '`');
    try out.appendSlice(allocator, param_rest[0..name_end]);
    try out.append(allocator, '`');

    if (parsed_type) |pt| {
        if (pt.type_name.len > 0) {
            try out.appendSlice(allocator, " (`");
            try out.appendSlice(allocator, pt.type_name);
            try out.appendSlice(allocator, "`)");
        }
    }

    const detail = std.mem.trim(u8, param_rest[name_end..], " \t");
    if (detail.len > 0) {
        try out.appendSlice(allocator, " - ");
        try out.appendSlice(allocator, detail);
    }
}

fn append_return_doc_rest(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rest: []const u8,
) !void {
    if (consume_braced_type(rest)) |parsed| {
        try out.append(allocator, '`');
        try out.appendSlice(allocator, parsed.type_name);
        try out.append(allocator, '`');
        if (parsed.rest.len > 0) {
            try out.appendSlice(allocator, " - ");
            try out.appendSlice(allocator, parsed.rest);
        }
        return;
    }
    try out.appendSlice(allocator, rest);
}

fn append_throws_doc_rest(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rest: []const u8,
) !void {
    if (consume_braced_type(rest)) |parsed| {
        try out.append(allocator, '`');
        try out.appendSlice(allocator, parsed.type_name);
        try out.append(allocator, '`');
        if (parsed.rest.len > 0) {
            try out.appendSlice(allocator, " - ");
            try out.appendSlice(allocator, parsed.rest);
        }
        return;
    }

    const trimmed = std.mem.trim(u8, rest, " \t");
    const name_end = for (trimmed, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) break i;
    } else trimmed.len;
    if (name_end == 0) return;

    try out.append(allocator, '`');
    try out.appendSlice(allocator, trimmed[0..name_end]);
    try out.append(allocator, '`');

    const detail = std.mem.trim(u8, trimmed[name_end..], " \t");
    if (detail.len > 0) {
        try out.appendSlice(allocator, " - ");
        try out.appendSlice(allocator, detail);
    }
}

fn line_start_before(source: []const u8, offset: u32) usize {
    var i: usize = @intCast(offset);
    if (i > source.len) i = source.len;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

const PreviousLine = struct {
    start: usize,
    text: []const u8,
};

fn previous_line(source: []const u8, line_start: usize) ?PreviousLine {
    if (line_start == 0) return null;
    var end = line_start;
    if (end > 0 and source[end - 1] == '\n') end -= 1;
    var start = end;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    return .{ .start = start, .text = source[start..end] };
}

fn has_text(result: ?lsp_types.HoverResult, needle: []const u8) bool {
    if (result == null) return false;
    return std.mem.indexOf(u8, result.?.contents.value, needle) != null;
}

fn expect_hover_contains(source: []const u8, name: []const u8, needle: []const u8) !void {
    var ctx = try hover_at(source, name);
    defer ctx.deinit();

    try std.testing.expect(has_text(ctx.result, needle));
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
    var ctx = try hover_at(
        "public class Foo { public String getName() { return null; } }",
        "getName",
    );
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

test "hover includes ApexDoc for class" {
    try expect_hover_contains(
        \\/**
        \\ * Demonstrates a useful service.
        \\ */
        \\public class Foo {}
    , "Foo", "Demonstrates a useful service.");
}

test "hover includes ApexDoc before annotations" {
    try expect_hover_contains(
        \\public class Foo {
        \\    /**
        \\     * Returns account records.
        \\     */
        \\    @AuraEnabled
        \\    public static List<Account> getRecords() { return null; }
        \\}
    , "getRecords", "Returns account records.");
}

test "hover emphasizes ApexDoc tags" {
    try expect_hover_contains(
        \\public class Foo {
        \\    /**
        \\     * @description Returns account records.
        \\     * @param state selected state
        \\     * @return account rows
        \\     */
        \\    public static List<Account> getRecords(String state) { return null; }
        \\}
    , "getRecords", "**@description** Returns account records.");
    try expect_hover_contains(
        \\public class Foo {
        \\    /**
        \\     * @description Returns account records.
        \\     * @param state selected state
        \\     * @return account rows
        \\     */
        \\    public static List<Account> getRecords(String state) { return null; }
        \\}
    , "getRecords", "**@param** `state` - selected state");
    try expect_hover_contains(
        \\public class Foo {
        \\    /**
        \\     * @description Returns account records.
        \\     * @param state selected state
        \\     * @return account rows
        \\     */
        \\    public static List<Account> getRecords(String state) { return null; }
        \\}
    , "getRecords", "**@return** account rows");
}

test "hover formats Javadoc style ApexDoc tags" {
    var ctx = try hover_at(
        \\public class Foo {
        \\    /**
        \\     * @description Finds account records.
        \\     * @param {String} state selected state
        \\     * @returns {List<Account>} account rows
        \\     * @throws {QueryException} when account access is denied
        \\     * @see SOQLRecipes#getRecords
        \\     */
        \\    public static List<Account> getRecords(String state) { return null; }
        \\}
    , "getRecords");
    defer ctx.deinit();

    try std.testing.expect(has_text(
        ctx.result,
        "**@param** `state` (`String`) - selected state",
    ));
    try std.testing.expect(has_text(
        ctx.result,
        "**@returns** `List<Account>` - account rows",
    ));
    try std.testing.expect(has_text(
        ctx.result,
        "**@throws** `QueryException` - when account access is denied",
    ));
    try std.testing.expect(has_text(ctx.result, "**@see** SOQLRecipes#getRecords"));
}

test "hover resolves cross-file top-level class at call site" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const main_source = "public class Main { void run() { Helper.doWork(); } }";
    try store.open("file:///Helper.cls", 1,
        \\/**
        \\ * @description Useful helper.
        \\ */
        \\public class Helper { public static String doWork() { return null; } }
    );
    try store.open("file:///Main.cls", 1, main_source);

    const cached = try store.ensure_parsed("file:///Main.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Main.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.indexOf(u8, main_source, "Helper").?);
    const result = try get_hover_cross_file(
        br,
        cached.tokens,
        main_source,
        "file:///Main.cls",
        offset,
        &store,
        arena.allocator(),
    );

    try std.testing.expect(has_text(result, "**@description** Useful helper."));
}

test "hover resolves cross-file class member at call site" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const main_source = "public class Main { void run() { Helper.doWork(); } }";
    try store.open("file:///Helper.cls", 1,
        \\public class Helper {
        \\    /**
        \\     * @description Does useful work.
        \\     */
        \\    public static String doWork() { return null; }
        \\}
    );
    try store.open("file:///Main.cls", 1, main_source);

    const cached = try store.ensure_parsed("file:///Main.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Main.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.indexOf(u8, main_source, "doWork").?);
    const result = try get_hover_cross_file(
        br,
        cached.tokens,
        main_source,
        "file:///Main.cls",
        offset,
        &store,
        arena.allocator(),
    );

    try std.testing.expect(has_text(result, "(method) doWork: String"));
    try std.testing.expect(has_text(result, "**@description** Does useful work."));
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
