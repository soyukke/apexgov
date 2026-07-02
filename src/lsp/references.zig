//! references — シンボルの全参照箇所を返す。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const parser_types = @import("../apex_parser/types.zig");

pub fn get_references(
    result: *const binder_mod.BindResult,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    include_declaration: bool,
    allocator: std.mem.Allocator,
) ![]lsp_types.Location {
    const sym = binder_mod.symbol_at_position(result, offset) orelse return &.{};
    const refs = try binder_mod.filter_references(result, sym.id, allocator);
    defer allocator.free(refs);

    var locations: std.ArrayList(lsp_types.Location) = .empty;
    for (refs) |ref| {
        if (!include_declaration and ref.is_definition) continue;
        const pos = position_mod.offset_to_position(source, ref.offset);
        try locations.append(allocator, .{
            .uri = uri,
            .range = .{
                .start = pos,
                .end = .{
                    .line = pos.line,
                    .character = pos.character + (ref.end_offset - ref.offset),
                },
            },
        });
    }
    return locations.toOwnedSlice(allocator);
}

/// クロスファイル対応版。同一ファイル内の参照に加え、ワークスペース内の他ファイルでの
/// 同名トップレベルシンボルの定義+参照も収集する。
pub fn get_references_cross_file(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    include_declaration: bool,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) ![]lsp_types.Location {
    const target = try resolve_reference_target(
        result,
        tokens,
        source,
        uri,
        offset,
        store,
    ) orelse {
        return get_references(
            result,
            source,
            uri,
            offset,
            include_declaration,
            allocator,
        );
    };

    var locations: std.ArrayList(lsp_types.Location) = .empty;
    try append_bound_references(
        &locations,
        target.bind_result,
        target.source,
        target.uri,
        target.symbol.id,
        include_declaration,
        allocator,
    );

    try append_member_token_references(
        &locations,
        target,
        include_declaration,
        store,
        allocator,
    );

    try append_top_level_type_references(
        &locations,
        target,
        include_declaration,
        store,
        allocator,
    );
    return locations.toOwnedSlice(allocator);
}

const ReferenceTarget = struct {
    uri: []const u8,
    source: []const u8,
    tokens: []const parser_types.Token,
    bind_result: *const binder_mod.BindResult,
    symbol: binder_mod.Symbol,
};

fn resolve_reference_target(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    store: *DocumentStore,
) !?ReferenceTarget {
    if (binder_mod.symbol_at_position(result, offset)) |sym| {
        return .{
            .uri = uri,
            .source = source,
            .tokens = tokens,
            .bind_result = result,
            .symbol = sym.*,
        };
    }

    if (position_mod.this_member_at_offset(tokens, offset)) |member| {
        const arg_count = position_mod.call_arg_count_at_offset(tokens, offset);
        if (binder_mod.resolve_current_class_member_with_arity(
            result,
            offset,
            member.member_name,
            arg_count,
        )) |sym| {
            return .{
                .uri = uri,
                .source = source,
                .tokens = tokens,
                .bind_result = result,
                .symbol = sym.*,
            };
        }
    }

    if (position_mod.qualified_member_at_offset(tokens, offset)) |member| {
        const arg_count = position_mod.call_arg_count_at_offset(tokens, offset);
        if (store.resolve_member_across_files_with_arity(
            member.receiver_name,
            member.member_name,
            uri,
            arg_count,
        )) |match| {
            return try target_from_match(store, match);
        }
    }

    const name = position_mod.identifier_at_offset(tokens, offset) orelse return null;
    const arg_count = position_mod.call_arg_count_at_offset(tokens, offset);
    if (binder_mod.resolve_current_class_member_with_arity(result, offset, name, arg_count)) |sym| {
        return .{
            .uri = uri,
            .source = source,
            .tokens = tokens,
            .bind_result = result,
            .symbol = sym.*,
        };
    }

    if (store.resolve_symbol_across_files(name, uri)) |match| {
        return try target_from_match(store, match);
    }

    return null;
}

fn target_from_match(
    store: *DocumentStore,
    match: DocumentStore.SymbolMatch,
) !?ReferenceTarget {
    const cached = try store.ensure_parsed(match.uri) orelse return null;
    const br = try store.ensure_bound(match.uri) orelse return null;
    return .{
        .uri = match.uri,
        .source = match.source,
        .tokens = cached.tokens,
        .bind_result = br,
        .symbol = match.symbol,
    };
}

fn append_bound_references(
    locations: *std.ArrayList(lsp_types.Location),
    result: *const binder_mod.BindResult,
    source: []const u8,
    uri: []const u8,
    symbol_id: binder_mod.SymbolId,
    include_declaration: bool,
    allocator: std.mem.Allocator,
) !void {
    const refs = try binder_mod.filter_references(result, symbol_id, allocator);
    defer allocator.free(refs);

    for (refs) |ref| {
        if (!include_declaration and ref.is_definition) continue;
        try append_location_unique(
            locations,
            location_for_range(uri, source, ref.offset, ref.end_offset),
            allocator,
        );
    }
}

fn append_top_level_type_references(
    locations: *std.ArrayList(lsp_types.Location),
    target: ReferenceTarget,
    include_declaration: bool,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) !void {
    if (!is_top_level_type(target.symbol.kind)) return;

    var it = store.documents.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, target.uri)) continue;
        const doc = entry.value_ptr;
        const pr = doc.parse_result orelse continue;
        const br = pr.bind_result orelse continue;
        for (br.symbols) |other_sym| {
            if (!binder_mod.names_equal(other_sym.name, target.symbol.name)) continue;
            try append_bound_references(
                locations,
                &br,
                doc.text,
                entry.key_ptr.*,
                other_sym.id,
                include_declaration,
                allocator,
            );
        }
    }
}

fn append_member_token_references(
    locations: *std.ArrayList(lsp_types.Location),
    target: ReferenceTarget,
    include_declaration: bool,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) !void {
    if (!is_class_member(target.symbol.kind)) return;
    const owner_id = target.symbol.parent orelse return;
    const owner_name = symbol_name(target.bind_result, owner_id) orelse return;

    var it = store.documents.iterator();
    while (it.next()) |entry| {
        const doc = entry.value_ptr;
        const cached = try store.ensure_parsed(doc.uri) orelse continue;
        const br = try store.ensure_bound(doc.uri) orelse continue;
        const owner_id_in_doc = owner_id_in_document(br, owner_name);
        const is_target_doc = std.mem.eql(u8, doc.uri, target.uri);
        try append_member_refs_in_doc(
            locations,
            doc.uri,
            doc.text,
            cached.tokens,
            br,
            target.symbol,
            owner_name,
            if (is_target_doc) owner_id else owner_id_in_doc,
            include_declaration,
            allocator,
        );
    }
}

fn append_member_refs_in_doc(
    locations: *std.ArrayList(lsp_types.Location),
    uri: []const u8,
    source: []const u8,
    tokens: []const parser_types.Token,
    result: *const binder_mod.BindResult,
    target_symbol: binder_mod.Symbol,
    owner_name: []const u8,
    owner_id: ?binder_mod.SymbolId,
    include_declaration: bool,
    allocator: std.mem.Allocator,
) !void {
    for (tokens, 0..) |tok, i| {
        if (tok.kind != .identifier) continue;
        if (!binder_mod.names_equal(tok.lexeme, target_symbol.name)) continue;

        const is_definition = tok.loc.offset == target_symbol.loc.offset;
        if (is_definition) {
            if (include_declaration) {
                try append_location_unique(
                    locations,
                    location_for_token(uri, source, tok),
                    allocator,
                );
            }
            continue;
        }

        if (is_method_like(target_symbol.kind) and !method_call_matches(tokens, i, target_symbol)) {
            continue;
        }
        if (is_qualified_member_reference(tokens, i, owner_name)) {
            try append_location_unique(
                locations,
                location_for_token(uri, source, tok),
                allocator,
            );
            continue;
        }

        if (owner_id) |id| {
            if (is_bare_member_reference(tokens, i) and
                binder_mod.current_class_symbol_id(result, tok.loc.offset) == id)
            {
                try append_location_unique(
                    locations,
                    location_for_token(uri, source, tok),
                    allocator,
                );
            }
        }
    }
}

fn is_qualified_member_reference(
    tokens: []const parser_types.Token,
    index: usize,
    owner_name: []const u8,
) bool {
    if (index < 2) return false;
    const dot = tokens[index - 1].kind;
    if (dot != .dot and dot != .question_dot) return false;
    const receiver = tokens[index - 2];
    if (receiver.kind == .this_kw) return true;
    return receiver.kind == .identifier and binder_mod.names_equal(receiver.lexeme, owner_name);
}

fn is_bare_member_reference(tokens: []const parser_types.Token, index: usize) bool {
    if (index > 0) {
        const prev = tokens[index - 1].kind;
        if (prev == .dot or prev == .question_dot) return false;
    }
    return true;
}

fn is_call_token(tokens: []const parser_types.Token, index: usize) bool {
    return index + 1 < tokens.len and tokens[index + 1].kind == .lparen;
}

fn method_call_matches(
    tokens: []const parser_types.Token,
    index: usize,
    target_symbol: binder_mod.Symbol,
) bool {
    if (!is_call_token(tokens, index)) return false;
    const arg_count = position_mod.call_arg_count_at_token_index(tokens, index);
    return binder_mod.member_arity_matches(&target_symbol, arg_count);
}

fn owner_id_in_document(
    result: *const binder_mod.BindResult,
    owner_name: []const u8,
) ?binder_mod.SymbolId {
    for (result.symbols) |sym| {
        if (is_top_level_type(sym.kind) and binder_mod.names_equal(sym.name, owner_name)) {
            return sym.id;
        }
    }
    return null;
}

fn symbol_name(
    result: *const binder_mod.BindResult,
    symbol_id: binder_mod.SymbolId,
) ?[]const u8 {
    if (symbol_id >= result.symbols.len) return null;
    return result.symbols[symbol_id].name;
}

fn is_top_level_type(kind: binder_mod.SymbolKind) bool {
    return switch (kind) {
        .class, .interface, .enum_type, .trigger => true,
        else => false,
    };
}

fn is_class_member(kind: binder_mod.SymbolKind) bool {
    return switch (kind) {
        .method, .field, .constructor, .enum_value, .class, .interface, .enum_type => true,
        else => false,
    };
}

fn is_method_like(kind: binder_mod.SymbolKind) bool {
    return switch (kind) {
        .method, .constructor => true,
        else => false,
    };
}

fn location_for_token(
    uri: []const u8,
    source: []const u8,
    tok: parser_types.Token,
) lsp_types.Location {
    return location_for_range(
        uri,
        source,
        tok.loc.offset,
        tok.loc.offset + @as(u32, @intCast(tok.lexeme.len)),
    );
}

fn location_for_range(
    uri: []const u8,
    source: []const u8,
    start_offset: u32,
    end_offset: u32,
) lsp_types.Location {
    const start = position_mod.offset_to_position(source, start_offset);
    const end = position_mod.offset_to_position(source, end_offset);
    return .{
        .uri = uri,
        .range = .{
            .start = start,
            .end = end,
        },
    };
}

fn append_location_unique(
    locations: *std.ArrayList(lsp_types.Location),
    loc: lsp_types.Location,
    allocator: std.mem.Allocator,
) !void {
    for (locations.items) |existing| {
        if (same_location(existing, loc)) return;
    }
    try locations.append(allocator, loc);
}

fn same_location(a: lsp_types.Location, b: lsp_types.Location) bool {
    return std.mem.eql(u8, a.uri, b.uri) and
        a.range.start.line == b.range.start.line and
        a.range.start.character == b.range.start.character and
        a.range.end.line == b.range.end.line and
        a.range.end.character == b.range.end.character;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

test "finds all uses of local variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const source = "public class Foo { public void run() { Integer x = 1; Integer y = x; } }";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    // 'x' の定義位置で検索
    const sym = blk: {
        for (br.symbols) |*s| {
            if (std.mem.eql(u8, s.name, "x")) break :blk s;
        }
        break :blk null;
    } orelse unreachable;

    const locs = try get_references(&br, source, "file:///t.cls", sym.loc.offset, true, alloc);
    try std.testing.expectEqual(@as(usize, 2), locs.len); // definition + usage
}

test "include_declaration=false excludes definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const source = "public class Foo { public void run() { Integer x = 1; Integer y = x; } }";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const sym = blk: {
        for (br.symbols) |*s| {
            if (std.mem.eql(u8, s.name, "x")) break :blk s;
        }
        break :blk null;
    } orelse unreachable;

    const locs = try get_references(&br, source, "file:///t.cls", sym.loc.offset, false, alloc);
    try std.testing.expectEqual(@as(usize, 1), locs.len); // usage only
}

// -- クロスファイルテスト --

test "cross-file: finds references in other files" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    // Helper クラスが 2 つのファイルで定義（同名クラス）
    try store.open("file:///Helper.cls", 1, "public class Helper { public void doWork() {} }");
    try store.open("file:///Main.cls", 1, "public class Main { }");

    _ = try store.ensure_bound("file:///Helper.cls");
    _ = try store.ensure_bound("file:///Main.cls");

    const helper_doc = store.get("file:///Helper.cls").?;
    const cached = helper_doc.parse_result.?;
    const br = cached.bind_result.?;

    // Helper クラス名の位置
    const offset: u32 = @intCast(std.mem.indexOf(u8, helper_doc.text, "Helper").?);

    const locs = try get_references_cross_file(
        &br,
        cached.tokens,
        helper_doc.text,
        "file:///Helper.cls",
        offset,
        true,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    // Helper.cls 内の定義 (少なくとも 1 つ)
    try std.testing.expect(locs.len >= 1);
}

test "same-file: finds bare same-class method references from definition" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class Foo {
        \\    public void run() {
        \\        helper();
        \\        this.helper();
        \\        Foo.helper();
        \\    }
        \\    private static void helper() {}
        \\}
    ;
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.lastIndexOf(u8, source, "helper").?);

    const locs = try get_references_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        offset,
        true,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    try std.testing.expectEqual(@as(usize, 4), locs.len);
}

test "same-file: finds same-class method references from bare call" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class CollectionUtils {
        \\    public void a() { getSobjectTypeFromList(null); }
        \\    public void b() { getSobjectTypeFromList(null); }
        \\    public void c() { getSobjectTypeFromList(null); }
        \\    private static String getSobjectTypeFromList(List<SObject> incomingList) {
        \\        return null;
        \\    }
        \\}
    ;
    try store.open("file:///CollectionUtils.cls", 1, source);
    const cached = try store.ensure_parsed("file:///CollectionUtils.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///CollectionUtils.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "getSobjectTypeFromList").?);

    const locs = try get_references_cross_file(
        br,
        cached.tokens,
        source,
        "file:///CollectionUtils.cls",
        offset,
        true,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    try std.testing.expectEqual(@as(usize, 4), locs.len);
}

test "cross-file: member references are case-insensitive" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const helper_source =
        \\public class CRLP_RollupCMT_TEST {
        \\    public static String generateRollup() { return null; }
        \\}
    ;
    const main_source =
        "public class Main { void run() { CRLP_RollupCMT_Test.generateRollup(); } }";
    try store.open("file:///CRLP_RollupCMT_TEST.cls", 1, helper_source);
    try store.open("file:///Main.cls", 1, main_source);
    const cached = try store.ensure_parsed("file:///CRLP_RollupCMT_TEST.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///CRLP_RollupCMT_TEST.cls") orelse unreachable;
    _ = try store.ensure_bound("file:///Main.cls");
    const offset: u32 = @intCast(std.mem.indexOf(u8, helper_source, "generateRollup").?);

    const locs = try get_references_cross_file(
        br,
        cached.tokens,
        helper_source,
        "file:///CRLP_RollupCMT_TEST.cls",
        offset,
        true,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    try std.testing.expectEqual(@as(usize, 2), locs.len);
}

test "same-file: include_declaration false excludes same-class method definition" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class Foo {
        \\    public void run() {
        \\        helper();
        \\        this.helper();
        \\    }
        \\    private static void helper() {}
        \\}
    ;
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.lastIndexOf(u8, source, "helper").?);

    const locs = try get_references_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        offset,
        false,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    try std.testing.expectEqual(@as(usize, 2), locs.len);
}

test "same-file: method references respect overload arity" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const source =
        \\public class Foo {
        \\    public void run() {
        \\        helper();
        \\        helper('x');
        \\    }
        \\    private static Integer helper() { return 0; }
        \\    private static Integer helper(String label) { return 1; }
        \\}
    ;
    try store.open("file:///Foo.cls", 1, source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "helper() {").?);

    const locs = try get_references_cross_file(
        br,
        cached.tokens,
        source,
        "file:///Foo.cls",
        offset,
        true,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    try std.testing.expectEqual(@as(usize, 2), locs.len);
}

test "cross-file: finds qualified class member references" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const helper_source = "public class Helper { public static void doWork() {} }";
    const main_source = "public class Main { public void run() { Helper.doWork(); } }";
    const other_source = "public class Other { public void run() { Helper.doWork(); } }";
    try store.open("file:///Helper.cls", 1, helper_source);
    try store.open("file:///Main.cls", 1, main_source);
    try store.open("file:///Other.cls", 1, other_source);
    const cached = try store.ensure_parsed("file:///Helper.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Helper.cls") orelse unreachable;
    _ = try store.ensure_bound("file:///Main.cls");
    _ = try store.ensure_bound("file:///Other.cls");
    const offset: u32 = @intCast(std.mem.indexOf(u8, helper_source, "doWork").?);

    const locs = try get_references_cross_file(
        br,
        cached.tokens,
        helper_source,
        "file:///Helper.cls",
        offset,
        true,
        &store,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(locs);

    try std.testing.expectEqual(@as(usize, 3), locs.len);
}
