//! utils — インタープリター共通ヘルパー。
//!
//! Value 等値比較（Apex == セマンティクス）、型変換、文字列化。

const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;

/// Apex == セマンティクスで値を比較する。
/// String は大文字小文字を区別しない。
pub fn valueEql(a: Value, b: Value) bool {
    const TagType = @typeInfo(Value).@"union".tag_type.?;
    const a_tag: TagType = a;
    const b_tag: TagType = b;

    if (a_tag == .null_val and b_tag == .null_val) return true;
    if (a_tag == .null_val or b_tag == .null_val) return false;

    if (a_tag != b_tag) {
        // integer/double cross-comparison
        if (a_tag == .integer and b_tag == .double) {
            return @as(f64, @floatFromInt(a.integer)) == b.double;
        }
        if (a_tag == .double and b_tag == .integer) {
            return a.double == @as(f64, @floatFromInt(b.integer));
        }
        return false;
    }

    return switch (a) {
        .boolean => |av| av == b.boolean,
        .integer => |av| av == b.integer,
        .double => |av| av == b.double,
        .string => |av| std.ascii.eqlIgnoreCase(av, b.string),
        .void_val => true,
        .null_val => true,
        .sobject => |av| {
            // Compare by Id if both have one
            if (av.id != null and b.sobject.id != null) return std.ascii.eqlIgnoreCase(av.id.?, b.sobject.id.?);
            return av == b.sobject; // pointer equality
        },
        .list => |av| {
            if (av == b.list) return true;
            // Deep equality: compare items
            if (av.items.items.len != b.list.items.items.len) return false;
            for (av.items.items, b.list.items.items) |a_item, b_item| {
                if (!valueEql(a_item, b_item)) return false;
            }
            return true;
        },
        .map => |av| {
            if (av == b.map) return true;
            // Deep equality: compare entries
            if (av.entries.count() != b.map.entries.count()) return false;
            for (av.entries.keys(), av.entries.values()) |k, v| {
                const bv = b.map.entries.get(k) orelse return false;
                if (!valueEql(v, bv)) return false;
            }
            return true;
        },
        .set => |av| {
            if (av == b.set) return true;
            // Deep equality: compare entries
            if (av.entries.count() != b.set.entries.count()) return false;
            for (av.entries.keys()) |k| {
                if (!b.set.entries.contains(k)) return false;
            }
            return true;
        },
        .object => |av| {
            if (av == b.object) return true;
            // Compare Schema.SObjectType and Type objects by name field
            if ((std.ascii.eqlIgnoreCase(av.class_name, "Schema.SObjectType") and
                std.ascii.eqlIgnoreCase(b.object.class_name, "Schema.SObjectType")) or
                (std.ascii.eqlIgnoreCase(av.class_name, "Type") and
                std.ascii.eqlIgnoreCase(b.object.class_name, "Type")))
            {
                const a_name = av.fields.get("name") orelse return false;
                const b_name = b.object.fields.get("name") orelse return false;
                if (a_name == .string and b_name == .string) return std.ascii.eqlIgnoreCase(a_name.string, b_name.string);
            }
            return false;
        },
    };
}

/// Value を文字列に変換する。
pub fn coerceToString(v: Value, arena: std.mem.Allocator) ![]const u8 {
    return switch (v) {
        .null_val => "null",
        .boolean => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .double => |d| try std.fmt.allocPrint(arena, "{d}", .{d}),
        .string => |s| s,
        .void_val => "void",
        .list => |l| try std.fmt.allocPrint(arena, "List[{d}]", .{l.items.items.len}),
        .map => |m| try std.fmt.allocPrint(arena, "Map[{d}]", .{m.entries.count()}),
        .set => |s2| try std.fmt.allocPrint(arena, "Set[{d}]", .{s2.entries.count()}),
        .sobject => |sob| try std.fmt.allocPrint(arena, "{s}({s})", .{ sob.type_name, sob.id orelse "null" }),
        .object => |obj| blk: {
            // Schema.SObjectType → return the "name" field (e.g. "Account")
            if (std.ascii.eqlIgnoreCase(obj.class_name, "Schema.SObjectType")) {
                if (obj.fields.get("name")) |n| {
                    if (n == .string) break :blk n.string;
                }
            }
            // SObjectField → return the "name" field
            if (std.ascii.eqlIgnoreCase(obj.class_name, "Schema.SObjectField") or
                std.ascii.eqlIgnoreCase(obj.class_name, "SObjectField"))
            {
                if (obj.fields.get("name")) |n| {
                    if (n == .string) break :blk n.string;
                }
            }
            // Blob → return the stored value
            if (std.ascii.eqlIgnoreCase(obj.class_name, "Blob")) {
                if (obj.fields.get("value")) |bv| {
                    if (bv == .string) break :blk bv.string;
                }
            }
            // Use simple name (after last dot) like Apex does
            const cn = obj.class_name;
            const simple = if (std.mem.lastIndexOfScalar(u8, cn, '.')) |di| cn[di + 1 ..] else cn;
            break :blk try std.fmt.allocPrint(arena, "{s}:[instance]", .{simple});
        },
    };
}

/// Value を JSON 文字列に変換する。
pub fn toJson(v: Value, arena: std.mem.Allocator) ![]const u8 {
    return switch (v) {
        .null_val => "null",
        .boolean => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .double => |d| try std.fmt.allocPrint(arena, "{d}", .{d}),
        .string => |s| try std.fmt.allocPrint(arena, "\"{s}\"", .{s}),
        .void_val => "null",
        .list => |l| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(arena, '[');
            for (l.items.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(arena, ',');
                const item_json = try toJson(item, arena);
                try buf.appendSlice(arena, item_json);
            }
            try buf.append(arena, ']');
            break :blk try buf.toOwnedSlice(arena);
        },
        .map => |m| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(arena, '{');
            for (m.entries.keys(), m.entries.values(), 0..) |k, val, idx| {
                if (idx > 0) try buf.append(arena, ',');
                try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\"{s}\":", .{k}));
                try buf.appendSlice(arena, try toJson(val, arena));
            }
            try buf.append(arena, '}');
            break :blk try buf.toOwnedSlice(arena);
        },
        .set => "[]",
        .sobject => |sob| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(arena, '{');
            // Always output attributes with type
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\"attributes\":{{\"type\":\"{s}\"}}", .{sob.type_name}));
            // Output Id if present
            if (sob.id) |id| {
                try buf.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"Id\":\"{s}\"", .{id}));
            }
            for (sob.fields.keys(), sob.fields.values()) |k, val| {
                // Skip internal attributes field and Id (already output)
                if (std.ascii.eqlIgnoreCase(k, "Id")) continue;
                try buf.append(arena, ',');
                try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\"{s}\":", .{k}));
                try buf.appendSlice(arena, try toJson(val, arena));
            }
            try buf.append(arena, '}');
            break :blk try buf.toOwnedSlice(arena);
        },
        .object => |obj| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(arena, '{');
            var first = true;
            for (obj.fields.keys(), obj.fields.values()) |k, val| {
                if (!first) try buf.append(arena, ',');
                first = false;
                try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\"{s}\":", .{k}));
                try buf.appendSlice(arena, try toJson(val, arena));
            }
            try buf.append(arena, '}');
            break :blk try buf.toOwnedSlice(arena);
        },
    };
}

/// Value を bool に変換する（Apex の暗黙変換）。
pub fn coerceToBool(v: Value) !bool {
    return switch (v) {
        .boolean => |b| b,
        .null_val => false,
        else => error.TypeMismatch,
    };
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "valueEql: null == null" {
    try std.testing.expect(valueEql(Value.null_val, Value.null_val));
}

test "valueEql: string case-insensitive" {
    try std.testing.expect(valueEql(Value{ .string = "Hello" }, Value{ .string = "hello" }));
    try std.testing.expect(valueEql(Value{ .string = "ABC" }, Value{ .string = "abc" }));
    try std.testing.expect(!valueEql(Value{ .string = "a" }, Value{ .string = "b" }));
}

test "valueEql: integer" {
    try std.testing.expect(valueEql(Value{ .integer = 42 }, Value{ .integer = 42 }));
    try std.testing.expect(!valueEql(Value{ .integer = 1 }, Value{ .integer = 2 }));
}

test "valueEql: integer/double cross" {
    try std.testing.expect(valueEql(Value{ .integer = 3 }, Value{ .double = 3.0 }));
    try std.testing.expect(!valueEql(Value{ .integer = 3 }, Value{ .double = 3.1 }));
}

test "valueEql: null != non-null" {
    try std.testing.expect(!valueEql(Value.null_val, Value{ .integer = 0 }));
    try std.testing.expect(!valueEql(Value{ .string = "" }, Value.null_val));
}

// ---------------------------------------------------------------------------
// SObject フィールドのケースインセンシティブアクセス
// ---------------------------------------------------------------------------

/// SObject フィールドをケースインセンシティブに取得する。
pub fn sobjectGet(fields: *const std.StringArrayHashMapUnmanaged(Value), name: []const u8) ?Value {
    // First try exact match (fast path)
    if (fields.get(name)) |v| return v;
    // Fallback: case-insensitive search
    for (fields.keys(), fields.values()) |k, v| {
        if (std.ascii.eqlIgnoreCase(k, name)) return v;
    }
    return null;
}

/// SObject フィールドをケースインセンシティブに設定する。
/// 既存のキーがある場合はそのキー名を維持し、値だけ更新する。
pub fn sobjectPut(fields: *std.StringArrayHashMapUnmanaged(Value), arena: std.mem.Allocator, name: []const u8, value: Value) !void {
    // Check if there's an existing key with different case
    var existing_key: ?[]const u8 = null;
    for (fields.keys()) |k| {
        if (std.ascii.eqlIgnoreCase(k, name)) {
            existing_key = k;
            break;
        }
    }
    if (existing_key) |ek| {
        try fields.put(arena, ek, value);
    } else {
        try fields.put(arena, name, value);
    }
}

test "coerceToString" {
    try std.testing.expectEqualStrings("null", try coerceToString(Value.null_val, std.testing.allocator));
    try std.testing.expectEqualStrings("true", try coerceToString(Value{ .boolean = true }, std.testing.allocator));
    try std.testing.expectEqualStrings("hello", try coerceToString(Value{ .string = "hello" }, std.testing.allocator));

    const s = try coerceToString(Value{ .integer = 42 }, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("42", s);
}
