//! utils — インタープリター共通ヘルパー。
//!
//! Value 等値比較（Apex == セマンティクス）、型変換、文字列化。

const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;

/// Normalize DateTime string: strip ".000+0000" suffix → "Z"
fn normalize_date_time_str(s: []const u8) []const u8 {
    // "2016-09-15T16:51:41.000+0000" → "2016-09-15T16:51:41Z"
    if (s.len > 10 and std.mem.indexOf(u8, s, "T") != null) {
        if (std.mem.endsWith(u8, s, ".000+0000")) return s[0 .. s.len - 9];
        if (std.mem.endsWith(u8, s, ".000Z")) return s[0 .. s.len - 4];
        if (std.mem.endsWith(u8, s, "Z")) return s[0 .. s.len - 1];
    }
    return s;
}

fn format_json_date_time_str(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len <= 10 or std.mem.indexOf(u8, s, "T") == null) return s;
    if (std.mem.endsWith(u8, s, ".000Z")) return s;
    if (std.mem.endsWith(u8, s, ".000+0000")) {
        return std.fmt.allocPrint(arena, "{s}.000Z", .{s[0 .. s.len - 9]});
    }
    if (std.mem.endsWith(u8, s, "Z")) {
        return std.fmt.allocPrint(arena, "{s}.000Z", .{s[0 .. s.len - 1]});
    }
    return s;
}

fn numeric_as_f64(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .long => |i| @floatFromInt(i),
        .double => |d| d,
        else => null,
    };
}

/// Apex == セマンティクスで値を比較する。
/// String は大文字小文字を区別しない。
pub fn value_eql(a: Value, b: Value) bool {
    const TagType = @typeInfo(Value).@"union".tag_type.?;
    const a_tag: TagType = a;
    const b_tag: TagType = b;

    if (a_tag == .null_val and b_tag == .null_val) return true;
    if (a_tag == .null_val or b_tag == .null_val) return false;

    if (a_tag != b_tag) {
        // Numeric cross-comparison
        if (numeric_as_f64(a)) |af| {
            if (numeric_as_f64(b)) |bf| {
                return af == bf;
            }
        }
        // Date/DateTime object vs string cross-comparison
        if (a_tag == .object and b_tag == .string) {
            if (std.ascii.eqlIgnoreCase(a.object.class_name, "Date") or
                std.ascii.eqlIgnoreCase(a.object.class_name, "Datetime"))
            {
                if (a.object.fields.get("value")) |v| {
                    if (v == .string) {
                        const a_norm = normalize_date_time_str(v.string);
                        const b_norm = normalize_date_time_str(b.string);
                        return std.ascii.eqlIgnoreCase(a_norm, b_norm);
                    }
                }
            }
        }
        if (a_tag == .string and b_tag == .object) {
            if (std.ascii.eqlIgnoreCase(b.object.class_name, "Date") or
                std.ascii.eqlIgnoreCase(b.object.class_name, "Datetime"))
            {
                if (b.object.fields.get("value")) |v| {
                    if (v == .string) {
                        const a_norm = normalize_date_time_str(a.string);
                        const b_norm = normalize_date_time_str(v.string);
                        return std.ascii.eqlIgnoreCase(a_norm, b_norm);
                    }
                }
            }
        }
        return false;
    }

    return switch (a) {
        .boolean => |av| av == b.boolean,
        .integer => |av| av == b.integer,
        .long => |av| av == b.long,
        .double => |av| av == b.double,
        .string => |av| blk: {
            if (std.ascii.eqlIgnoreCase(av, b.string)) break :blk true;
            // Normalize DateTime strings: "2016-09-15T16:51:41.000+0000" == "2016-09-15T16:51:41Z"
            const a_norm = normalize_date_time_str(av);
            const b_norm = normalize_date_time_str(b.string);
            break :blk std.ascii.eqlIgnoreCase(a_norm, b_norm);
        },
        .void_val => true,
        .null_val => true,
        .sobject => |av| {
            // Compare by Id if both have one
            if (av.id != null and b.sobject.id != null) return std.ascii.eqlIgnoreCase(av.id.?, b.sobject.id.?);
            // Pointer equality first
            if (av == b.sobject) return true;
            // Deep equality: same type
            if (!std.ascii.eqlIgnoreCase(av.type_name, b.sobject.type_name)) return false;
            // Compare all fields from both sides — missing fields treated as null
            for (av.fields.keys(), av.fields.values()) |k, v| {
                const bv = sobject_get(&b.sobject.fields, k) orelse Value.null_val;
                if (!value_eql(v, bv)) return false;
            }
            // Check fields in b that are not in a
            for (b.sobject.fields.keys(), b.sobject.fields.values()) |k, v| {
                if (sobject_get(&av.fields, k) == null) {
                    if (!value_eql(v, Value.null_val)) return false;
                }
            }
            return true;
        },
        .list => |av| {
            if (av == b.list) return true;
            // Deep equality: compare items
            if (av.items.items.len != b.list.items.items.len) return false;
            for (av.items.items, b.list.items.items) |a_item, b_item| {
                if (!value_eql(a_item, b_item)) return false;
            }
            return true;
        },
        .map => |av| {
            if (av == b.map) return true;
            // Deep equality: compare entries
            if (av.entries.count() != b.map.entries.count()) return false;
            for (av.entries.keys(), av.entries.values()) |k, v| {
                const bv = b.map.entries.get(k) orelse return false;
                if (!value_eql(v, bv)) return false;
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
            // Compare Date/DateTime objects by their inner value string
            if ((std.ascii.eqlIgnoreCase(av.class_name, "Date") or std.ascii.eqlIgnoreCase(av.class_name, "Datetime")) and
                (std.ascii.eqlIgnoreCase(b.object.class_name, "Date") or std.ascii.eqlIgnoreCase(b.object.class_name, "Datetime")))
            {
                const a_val = av.fields.get("value") orelse return false;
                const b_val = b.object.fields.get("value") orelse return false;
                if (a_val == .string and b_val == .string) {
                    const a_norm = normalize_date_time_str(a_val.string);
                    const b_norm = normalize_date_time_str(b_val.string);
                    return std.ascii.eqlIgnoreCase(a_norm, b_norm);
                }
            }
            if ((std.ascii.eqlIgnoreCase(av.class_name, "Schema.SObjectField") or
                std.ascii.eqlIgnoreCase(av.class_name, "SObjectField")) and
                (std.ascii.eqlIgnoreCase(b.object.class_name, "Schema.SObjectField") or
                    std.ascii.eqlIgnoreCase(b.object.class_name, "SObjectField")))
            {
                const a_name = av.fields.get("fieldName") orelse av.fields.get("name") orelse return false;
                const b_name = b.object.fields.get("fieldName") orelse b.object.fields.get("name") orelse return false;
                if (a_name != .string or b_name != .string) return false;

                const same_object_type = blk: {
                    const a_object_type = av.fields.get("objectType");
                    const b_object_type = b.object.fields.get("objectType");
                    if (a_object_type == null or b_object_type == null) break :blk true;
                    if (a_object_type.? != .string or b_object_type.? != .string) break :blk false;
                    break :blk std.ascii.eqlIgnoreCase(a_object_type.?.string, b_object_type.?.string);
                };

                return same_object_type and std.ascii.eqlIgnoreCase(a_name.string, b_name.string);
            }
            return false;
        },
    };
}

/// Value を文字列に変換する。
pub fn coerce_to_string(v: Value, arena: std.mem.Allocator) ![]const u8 {
    return switch (v) {
        .null_val => "null",
        .boolean => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .long => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .double => |d| try format_apex_double(arena, d),
        .string => |s| s,
        .void_val => "void",
        .list => |l| try std.fmt.allocPrint(arena, "List[{d}]", .{l.items.items.len}),
        .map => |m| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(arena, "{");
            for (m.entries.keys(), m.entries.values(), 0..) |k, val, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try buf.appendSlice(arena, k);
                try buf.append(arena, '=');
                const vs = try coerce_to_string(val, arena);
                try buf.appendSlice(arena, vs);
            }
            try buf.appendSlice(arena, "}");
            break :blk buf.items;
        },
        .set => |s2| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(arena, "{");
            for (s2.entries.keys(), 0..) |k, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try buf.appendSlice(arena, k);
            }
            try buf.appendSlice(arena, "}");
            break :blk buf.items;
        },
        .sobject => |sob| try std.fmt.allocPrint(arena, "{s}({s})", .{ sob.type_name, sob.id orelse "null" }),
        .object => |obj| try coerce_object_to_string(obj, arena),
    };
}

fn coerce_object_to_string(obj: *types.ObjectInstance, arena: std.mem.Allocator) ![]const u8 {
    // Schema.SObjectType -> return the "name" field (e.g. "Account")
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Schema.SObjectType")) {
        if (obj.fields.get("name")) |n| {
            if (n == .string) return n.string;
        }
    }
    // SObjectField -> return the "name" field
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Schema.SObjectField") or
        std.ascii.eqlIgnoreCase(obj.class_name, "SObjectField"))
    {
        if (obj.fields.get("name")) |n| {
            if (n == .string) return n.string;
        }
    }
    if (std.ascii.eqlIgnoreCase(obj.class_name, "DescribeFieldResult")) {
        if (obj.fields.get("fieldName")) |n| {
            if (n == .string) return n.string;
        }
        if (obj.fields.get("name")) |n| {
            if (n == .string) return n.string;
        }
    }
    // Date/Datetime/Blob -> return the stored value string
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Date") or
        std.ascii.eqlIgnoreCase(obj.class_name, "Datetime") or
        std.ascii.eqlIgnoreCase(obj.class_name, "Blob"))
    {
        if (obj.fields.get("value")) |bv| {
            if (bv == .string) return bv.string;
        }
    }
    // Type (from SomeClass.class) -> return the resolved class name so that
    // Map<Type, X> keys don't collapse to a single "Type:[instance]" slot.
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Type") or
        std.ascii.eqlIgnoreCase(obj.class_name, "System.Type"))
    {
        if (obj.fields.get("name")) |n| {
            if (n == .string) return n.string;
        }
    }
    // Use simple name (after last dot) like Apex does
    const cn = obj.class_name;
    const simple = if (std.mem.lastIndexOfScalar(u8, cn, '.')) |di| cn[di + 1 ..] else cn;
    return std.fmt.allocPrint(arena, "{s}:[instance]", .{simple});
}

/// Value を JSON 文字列に変換する。
pub fn to_json(v: Value, arena: std.mem.Allocator) ![]const u8 {
    return switch (v) {
        .null_val => "null",
        .boolean => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .long => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .double => |d| try std.fmt.allocPrint(arena, "{d}", .{d}),
        .string => |s| try std.fmt.allocPrint(arena, "\"{s}\"", .{s}),
        .void_val => "null",
        .list => |l| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(arena, '[');
            for (l.items.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(arena, ',');
                const item_json = try to_json(item, arena);
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
                try buf.appendSlice(arena, try to_json(val, arena));
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
                try buf.appendSlice(arena, try to_json(val, arena));
            }
            try buf.append(arena, '}');
            break :blk try buf.toOwnedSlice(arena);
        },
        .object => |obj| try object_to_json(obj, arena),
    };
}

/// `to_json` の ObjectInstance 分岐を抽出。Date / Datetime は
/// `"value"` 文字列をクオート (Datetime は ISO 正規化)、他は通常の
/// `{ "key": value, ... }` 形式で出力する。
/// `to_json` と相互再帰なので `anyerror!` で推論ループを断つ。
fn object_to_json(obj: *types.ObjectInstance, arena: std.mem.Allocator) anyerror![]const u8 {
    if ((std.ascii.eqlIgnoreCase(obj.class_name, "Date") or
        std.ascii.eqlIgnoreCase(obj.class_name, "Datetime")) and obj.fields.get("value") != null)
    {
        if (obj.fields.get("value")) |val| {
            if (val == .string) {
                const serialized = if (std.ascii.eqlIgnoreCase(obj.class_name, "Datetime"))
                    try format_json_date_time_str(arena, val.string)
                else
                    val.string;
                return try std.fmt.allocPrint(arena, "\"{s}\"", .{serialized});
            }
        }
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(arena, '{');
    var first = true;
    for (obj.fields.keys(), obj.fields.values()) |k, val| {
        if (!first) try buf.append(arena, ',');
        first = false;
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\"{s}\":", .{k}));
        try buf.appendSlice(arena, try to_json(val, arena));
    }
    try buf.append(arena, '}');
    return try buf.toOwnedSlice(arena);
}

/// Value を bool に変換する（Apex の暗黙変換）。
pub fn coerce_to_bool(v: Value) !bool {
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
    try std.testing.expect(value_eql(Value.null_val, Value.null_val));
}

test "valueEql: string case-insensitive" {
    try std.testing.expect(value_eql(Value{ .string = "Hello" }, Value{ .string = "hello" }));
    try std.testing.expect(value_eql(Value{ .string = "ABC" }, Value{ .string = "abc" }));
    try std.testing.expect(!value_eql(Value{ .string = "a" }, Value{ .string = "b" }));
}

test "valueEql: integer" {
    try std.testing.expect(value_eql(Value{ .integer = 42 }, Value{ .integer = 42 }));
    try std.testing.expect(!value_eql(Value{ .integer = 1 }, Value{ .integer = 2 }));
}

test "valueEql: integer/double cross" {
    try std.testing.expect(value_eql(Value{ .integer = 3 }, Value{ .double = 3.0 }));
    try std.testing.expect(!value_eql(Value{ .integer = 3 }, Value{ .double = 3.1 }));
}

test "valueEql: null != non-null" {
    try std.testing.expect(!value_eql(Value.null_val, Value{ .integer = 0 }));
    try std.testing.expect(!value_eql(Value{ .string = "" }, Value.null_val));
}

// ---------------------------------------------------------------------------
// SObject フィールドのケースインセンシティブアクセス
// ---------------------------------------------------------------------------

/// SObject フィールドをケースインセンシティブに取得する。
pub fn sobject_get(fields: *const std.StringArrayHashMapUnmanaged(Value), name: []const u8) ?Value {
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
pub fn sobject_put(fields: *std.StringArrayHashMapUnmanaged(Value), arena: std.mem.Allocator, name: []const u8, value: Value) !void {
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

/// Apex の Double/Decimal を文字列化する。
/// Salesforce は 10.0 → "10.0", 3.14 → "3.14" のように常に小数点を含む。
pub fn format_apex_double(arena: std.mem.Allocator, d: f64) ![]const u8 {
    const s = try std.fmt.allocPrint(arena, "{d}", .{d});
    // 既に小数点があればそのまま
    if (std.mem.indexOf(u8, s, ".") != null) return s;
    // 整数値の場合は ".0" を付加 (Double セマンティクス: "1.0", "10.0")
    // Decimal / Integer 側は既に別パスで扱うためここでは変更しない。
    arena.free(s);
    return try std.fmt.allocPrint(arena, "{d}.0", .{d});
}

test "coerceToString" {
    try std.testing.expectEqualStrings("null", try coerce_to_string(Value.null_val, std.testing.allocator));
    try std.testing.expectEqualStrings("true", try coerce_to_string(Value{ .boolean = true }, std.testing.allocator));
    try std.testing.expectEqualStrings("hello", try coerce_to_string(Value{ .string = "hello" }, std.testing.allocator));

    const s = try coerce_to_string(Value{ .integer = 42 }, std.testing.allocator);
    defer std.testing.allocator.free(s);

    try std.testing.expectEqualStrings("42", s);
}

test "formatApexDouble" {
    const alloc = std.testing.allocator;

    const s1 = try format_apex_double(alloc, 10.0);
    defer alloc.free(s1);

    try std.testing.expectEqualStrings("10.0", s1);

    const s2 = try format_apex_double(alloc, 3.14);
    defer alloc.free(s2);

    try std.testing.expectEqualStrings("3.14", s2);

    const s3 = try format_apex_double(alloc, 0.0);
    defer alloc.free(s3);

    try std.testing.expectEqualStrings("0.0", s3);

    const s4 = try format_apex_double(alloc, 86.0);
    defer alloc.free(s4);

    try std.testing.expectEqualStrings("86.0", s4);
}

/// JSON 文字列のバランスチェック (braces/brackets が閉じているか、文字列リテラルが開いたままでないか)。
/// エスケープ (`\"`) を正しく考慮する。true = balanced, false = malformed / truncated。
pub fn is_json_balanced(json: []const u8) bool {
    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (in_str) {
            if (json[i] == '\\') {
                i += 1; // skip escaped char
            } else if (json[i] == '"') {
                in_str = false;
            }
        } else {
            if (json[i] == '"') in_str = true else if (json[i] == '{') brace_depth += 1 else if (json[i] == '}') brace_depth -= 1 else if (json[i] == '[') bracket_depth += 1 else if (json[i] == ']') bracket_depth -= 1;
        }
    }
    return brace_depth == 0 and bracket_depth == 0 and !in_str;
}

test "isJsonBalanced" {
    try std.testing.expect(is_json_balanced("{}"));
    try std.testing.expect(is_json_balanced("{\"key\":\"val\"}"));
    try std.testing.expect(is_json_balanced("{\"key\":\"val with \\\"quotes\\\"\"}"));
    try std.testing.expect(!is_json_balanced("{"));
    try std.testing.expect(!is_json_balanced("{\"key\":\"unterminated}"));
    try std.testing.expect(is_json_balanced("[]"));
    try std.testing.expect(!is_json_balanced("["));
}
