//! rename — シンボルの一括リネーム。

const std = @import("std");
const lsp_types = @import("types.zig");
const binder_mod = @import("binder.zig");
const position_mod = @import("position.zig");
const references_mod = @import("references.zig");
const DocumentStore = @import("document_store.zig").DocumentStore;
const parser_types = @import("../apex_parser/types.zig");

pub fn get_rename_edits(
    result: *const binder_mod.BindResult,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    new_name: []const u8,
    allocator: std.mem.Allocator,
) !?lsp_types.WorkspaceEdit {
    const sym = binder_mod.symbol_at_position(result, offset) orelse return null;

    // キーワードや非リネーム可能なシンボルはスキップ
    if (sym.kind == .class or sym.kind == .interface or
        sym.kind == .enum_type or sym.kind == .trigger)
    {
        // トップレベル型のリネームも許可
    }

    const refs = try binder_mod.filter_references(result, sym.id, allocator);
    defer allocator.free(refs);

    var edits: std.ArrayList(lsp_types.TextEdit) = .empty;
    for (refs) |ref| {
        const start = position_mod.offset_to_position(source, ref.offset);
        const end = position_mod.offset_to_position(source, ref.end_offset);
        try edits.append(allocator, .{
            .range = .{ .start = start, .end = end },
            .newText = new_name,
        });
    }

    return .{
        .changes = .{
            .uri = uri,
            .edits = try edits.toOwnedSlice(allocator),
        },
    };
}

pub fn get_rename_edits_cross_file(
    result: *const binder_mod.BindResult,
    tokens: []const parser_types.Token,
    source: []const u8,
    uri: []const u8,
    offset: u32,
    new_name: []const u8,
    store: *DocumentStore,
    allocator: std.mem.Allocator,
) !?lsp_types.WorkspaceEdit {
    const refs = try references_mod.get_references_cross_file(
        result,
        tokens,
        source,
        uri,
        offset,
        true,
        store,
        allocator,
    );
    defer allocator.free(refs);

    if (refs.len == 0) return null;

    var groups: std.ArrayList(EditGroup) = .empty;
    defer groups.deinit(allocator);

    for (refs) |loc| {
        const idx = try group_index(&groups, loc.uri, allocator);
        try groups.items[idx].edits.append(allocator, .{
            .range = loc.range,
            .newText = new_name,
        });
    }

    if (groups.items.len == 1) {
        const edits = try groups.items[0].edits.toOwnedSlice(allocator);
        return .{
            .changes = .{
                .uri = groups.items[0].uri,
                .edits = edits,
            },
        };
    }

    const entries = try allocator.alloc(
        lsp_types.WorkspaceEdit.ChangeMap.ChangeEntry,
        groups.items.len,
    );
    for (groups.items, 0..) |*group, i| {
        entries[i] = .{
            .uri = group.uri,
            .edits = try group.edits.toOwnedSlice(allocator),
        };
    }
    return .{ .changes = .{ .entries = entries } };
}

const EditGroup = struct {
    uri: []const u8,
    edits: std.ArrayList(lsp_types.TextEdit) = .empty,
};

fn group_index(
    groups: *std.ArrayList(EditGroup),
    uri: []const u8,
    allocator: std.mem.Allocator,
) !usize {
    for (groups.items, 0..) |group, i| {
        if (std.mem.eql(u8, group.uri, uri)) return i;
    }
    try groups.append(allocator, .{ .uri = uri });
    return groups.items.len - 1;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer = @import("../apex_parser/lexer.zig");
const parser = @import("../apex_parser/parser.zig");

test "renames variable at all sites" {
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

    const edit = try get_rename_edits(
        &br,
        source,
        "file:///t.cls",
        sym.loc.offset,
        "newName",
        alloc,
    );
    try std.testing.expect(edit != null);
    try std.testing.expect(edit.?.changes != null);
    try std.testing.expectEqual(@as(usize, 2), edit.?.changes.?.edits.len);
}

test "unknown position returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const source = "public class Foo {}";
    const tokens = try lexer.tokenize(source, alloc);
    const decls = try parser.parse(tokens, alloc);
    const br = try binder_mod.bind(decls, tokens, source, alloc);

    const edit = try get_rename_edits(&br, source, "file:///t.cls", 6, "x", alloc);
    try std.testing.expect(edit == null);
}

test "cross-file rename includes member call forms" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    const foo_source =
        \\public class Foo {
        \\    public void run() {
        \\        helper();
        \\        this.helper();
        \\        Foo.helper();
        \\    }
        \\    private static void helper() {}
        \\}
    ;
    const caller_source =
        \\public class Caller {
        \\    public void run() {
        \\        Foo.helper();
        \\    }
        \\}
    ;
    try store.open("file:///Foo.cls", 1, foo_source);
    try store.open("file:///Caller.cls", 1, caller_source);
    const cached = try store.ensure_parsed("file:///Foo.cls") orelse unreachable;
    const br = try store.ensure_bound("file:///Foo.cls") orelse unreachable;
    _ = try store.ensure_bound("file:///Caller.cls");
    const offset: u32 = @intCast(std.mem.lastIndexOf(u8, foo_source, "helper").?);

    const edit = try get_rename_edits_cross_file(
        br,
        cached.tokens,
        foo_source,
        "file:///Foo.cls",
        offset,
        "renamedHelper",
        &store,
        std.testing.allocator,
    );
    try std.testing.expect(edit != null);
    defer free_workspace_edit(edit.?, std.testing.allocator);

    try std.testing.expect(edit.?.changes != null);

    const changes = edit.?.changes.?;
    try std.testing.expectEqual(@as(usize, 2), changes.entries.len);
    try std.testing.expectEqual(@as(usize, 4), edit_count_for_uri(changes, "file:///Foo.cls"));
    try std.testing.expectEqual(@as(usize, 1), edit_count_for_uri(changes, "file:///Caller.cls"));
}

fn free_workspace_edit(edit: lsp_types.WorkspaceEdit, allocator: std.mem.Allocator) void {
    const changes = edit.changes orelse return;
    if (changes.entries.len > 0) {
        for (changes.entries) |entry| allocator.free(entry.edits);
        allocator.free(changes.entries);
    } else {
        allocator.free(changes.edits);
    }
}

fn edit_count_for_uri(
    changes: lsp_types.WorkspaceEdit.ChangeMap,
    uri: []const u8,
) usize {
    if (changes.entries.len == 0) {
        if (std.mem.eql(u8, changes.uri, uri)) return changes.edits.len;
        return 0;
    }
    for (changes.entries) |entry| {
        if (std.mem.eql(u8, entry.uri, uri)) return entry.edits.len;
    }
    return 0;
}
