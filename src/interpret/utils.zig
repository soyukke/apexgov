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
        return value_eql_cross_type(a, b, a_tag, b_tag);
    }

    return switch (a) {
        .boolean => |av| av == b.boolean,
        .integer => |av| av == b.integer,
        .long => |av| av == b.long,
        .double => |av| float_eql(av, b.double),
        .string => |av| blk: {
            if (std.ascii.eqlIgnoreCase(av, b.string)) break :blk true;
            // Normalize DateTime strings: "2016-09-15T16:51:41.000+0000" == "2016-09-15T16:51:41Z"
            const a_norm = normalize_date_time_str(av);
            const b_norm = normalize_date_time_str(b.string);
            break :blk std.ascii.eqlIgnoreCase(a_norm, b_norm);
        },
        .void_val => true,
        .null_val => true,
        .sobject => |av| value_eql_sobject(av, b.sobject),
        .list => |av| value_eql_list(av, b.list),
        .map => |av| value_eql_map(av, b.map),
        .set => |av| value_eql_set(av, b.set),
        .object => |av| value_eql_object(av, b.object),
    };
}

fn value_eql_cross_type(a: Value, b: Value, a_tag: anytype, b_tag: anytype) bool {
    if (numeric_as_f64(a)) |af| {
        if (numeric_as_f64(b)) |bf| return float_eql(af, bf);
    }
    if (a_tag == .object and b_tag == .string) {
        return value_eql_date_object_string(a.object, b.string);
    }
    if (a_tag == .string and b_tag == .object) {
        return value_eql_date_object_string(b.object, a.string);
    }
    return false;
}

fn float_eql(a: f64, b: f64) bool {
    if (a == b) return true;
    return @abs(a - b) <= 0.000000001;
}

fn value_eql_date_object_string(obj: *types.ObjectInstance, s: []const u8) bool {
    if (!is_date_like_object(obj)) return false;
    const v = obj.fields.get("value") orelse return false;
    if (v != .string) return false;
    const a_norm = normalize_date_time_str(v.string);
    const b_norm = normalize_date_time_str(s);
    return std.ascii.eqlIgnoreCase(a_norm, b_norm);
}

fn value_eql_sobject(a: *types.SObject, b: *types.SObject) bool {
    if (a.id != null and b.id != null) return std.ascii.eqlIgnoreCase(a.id.?, b.id.?);
    if (a == b) return true;
    if (!std.ascii.eqlIgnoreCase(a.type_name, b.type_name)) return false;
    for (a.fields.keys(), a.fields.values()) |k, v| {
        const bv = sobject_get(&b.fields, k) orelse Value.null_val;
        if (!value_eql(v, bv)) return false;
    }
    for (b.fields.keys(), b.fields.values()) |k, v| {
        if (sobject_get(&a.fields, k) == null and !value_eql(v, Value.null_val)) {
            return false;
        }
    }
    return true;
}

fn value_eql_list(a: *types.ListValue, b: *types.ListValue) bool {
    if (a == b) return true;
    if (a.items.items.len != b.items.items.len) return false;
    for (a.items.items, b.items.items) |a_item, b_item| {
        if (!value_eql(a_item, b_item)) return false;
    }
    return true;
}

fn value_eql_map(a: *types.MapValue, b: *types.MapValue) bool {
    if (a == b) return true;
    if (a.entries.count() != b.entries.count()) return false;
    for (a.entries.keys(), a.entries.values()) |k, v| {
        const bv = b.entries.get(k) orelse return false;
        if (!value_eql(v, bv)) return false;
    }
    return true;
}

fn value_eql_set(a: *types.SetValue, b: *types.SetValue) bool {
    if (a == b) return true;
    if (a.entries.count() != b.entries.count()) return false;
    for (a.entries.keys()) |k| {
        if (!b.entries.contains(k)) return false;
    }
    return true;
}

fn value_eql_object(a: *types.ObjectInstance, b: *types.ObjectInstance) bool {
    if (a == b) return true;
    if (is_named_type_object(a, b)) return object_name_fields_eql(a, b);
    if (is_date_like_object(a) and is_date_like_object(b)) return date_object_values_eql(a, b);
    if (is_s_object_field_object(a) and is_s_object_field_object(b)) {
        return s_object_field_objects_eql(a, b);
    }
    return false;
}

fn is_named_type_object(a: *types.ObjectInstance, b: *types.ObjectInstance) bool {
    return (std.ascii.eqlIgnoreCase(a.class_name, "Schema.SObjectType") and
        std.ascii.eqlIgnoreCase(b.class_name, "Schema.SObjectType")) or
        (std.ascii.eqlIgnoreCase(a.class_name, "Type") and
            std.ascii.eqlIgnoreCase(b.class_name, "Type"));
}

fn object_name_fields_eql(a: *types.ObjectInstance, b: *types.ObjectInstance) bool {
    const a_name = a.fields.get("name") orelse return false;
    const b_name = b.fields.get("name") orelse return false;
    return a_name == .string and b_name == .string and
        std.ascii.eqlIgnoreCase(a_name.string, b_name.string);
}

fn is_date_like_object(obj: *types.ObjectInstance) bool {
    return std.ascii.eqlIgnoreCase(obj.class_name, "Date") or
        std.ascii.eqlIgnoreCase(obj.class_name, "Datetime");
}

fn date_object_values_eql(a: *types.ObjectInstance, b: *types.ObjectInstance) bool {
    const a_val = a.fields.get("value") orelse return false;
    const b_val = b.fields.get("value") orelse return false;
    if (a_val != .string or b_val != .string) return false;
    const a_norm = normalize_date_time_str(a_val.string);
    const b_norm = normalize_date_time_str(b_val.string);
    return std.ascii.eqlIgnoreCase(a_norm, b_norm);
}

fn is_s_object_field_object(obj: *types.ObjectInstance) bool {
    return std.ascii.eqlIgnoreCase(obj.class_name, "Schema.SObjectField") or
        std.ascii.eqlIgnoreCase(obj.class_name, "SObjectField");
}

fn s_object_field_objects_eql(a: *types.ObjectInstance, b: *types.ObjectInstance) bool {
    const a_name = a.fields.get("fieldName") orelse a.fields.get("name") orelse return false;
    const b_name = b.fields.get("fieldName") orelse b.fields.get("name") orelse return false;
    if (a_name != .string or b_name != .string) return false;
    return s_object_field_object_types_eql(a, b) and
        std.ascii.eqlIgnoreCase(a_name.string, b_name.string);
}

fn s_object_field_object_types_eql(a: *types.ObjectInstance, b: *types.ObjectInstance) bool {
    const a_object_type = a.fields.get("objectType");
    const b_object_type = b.fields.get("objectType");
    if (a_object_type == null or b_object_type == null) return true;
    if (a_object_type.? != .string or b_object_type.? != .string) return false;
    return std.ascii.eqlIgnoreCase(a_object_type.?.string, b_object_type.?.string);
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
        .sobject => |sob| try std.fmt.allocPrint(
            arena,
            "{s}({s})",
            .{ sob.type_name, sob.id orelse "null" },
        ),
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
    // Date/Datetime/Time/Blob -> return the stored value string
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Date") or
        std.ascii.eqlIgnoreCase(obj.class_name, "Datetime") or
        std.ascii.eqlIgnoreCase(obj.class_name, "Time") or
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
        .string => |s| try json_string(arena, s),
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
                try buf.appendSlice(arena, try json_string(arena, k));
                try buf.append(arena, ':');
                try buf.appendSlice(arena, try to_json(val, arena));
            }
            try buf.append(arena, '}');
            break :blk try buf.toOwnedSlice(arena);
        },
        .set => "[]",
        .sobject => |sob| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(arena, '{');
            var first = true;
            if (!std.ascii.eqlIgnoreCase(sob.type_name, "Object")) {
                try buf.appendSlice(
                    arena,
                    try std.fmt.allocPrint(
                        arena,
                        "\"attributes\":{{\"type\":{s}}}",
                        .{try json_string(arena, sob.type_name)},
                    ),
                );
                first = false;
            }
            if (sob.id) |id| {
                if (!first) try buf.append(arena, ',');
                first = false;
                try buf.appendSlice(arena, "\"Id\":");
                try buf.appendSlice(arena, try json_string(arena, id));
            }
            for (sob.fields.keys(), sob.fields.values()) |k, val| {
                if (std.ascii.eqlIgnoreCase(k, "attributes")) continue;
                if (!std.ascii.eqlIgnoreCase(sob.type_name, "Object") and
                    std.ascii.eqlIgnoreCase(k, "Id")) continue;
                if (!first) try buf.append(arena, ',');
                first = false;
                try buf.appendSlice(arena, try json_string(arena, k));
                try buf.append(arena, ':');
                try buf.appendSlice(arena, try to_json(val, arena));
            }
            try buf.append(arena, '}');
            break :blk try buf.toOwnedSlice(arena);
        },
        .object => |obj| try object_to_json(obj, arena),
    };
}

fn json_string(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(arena, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(arena, "\\\""),
            '\\' => try buf.appendSlice(arena, "\\\\"),
            '\n' => try buf.appendSlice(arena, "\\n"),
            '\r' => try buf.appendSlice(arena, "\\r"),
            '\t' => try buf.appendSlice(arena, "\\t"),
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1f => {
                try buf.appendSlice(arena, "\\u00");
                try buf.append(arena, "0123456789abcdef"[ch >> 4]);
                try buf.append(arena, "0123456789abcdef"[ch & 0x0f]);
            },
            else => try buf.append(arena, ch),
        }
    }
    try buf.append(arena, '"');
    return try buf.toOwnedSlice(arena);
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
                return try json_string(arena, serialized);
            }
        }
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(arena, '{');
    var first = true;
    for (obj.fields.keys(), obj.fields.values()) |k, val| {
        if (!first) try buf.append(arena, ',');
        first = false;
        try buf.appendSlice(arena, try json_string(arena, k));
        try buf.append(arena, ':');
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

test "sobject_get matches managed namespace prefixes" {
    var fields: std.StringArrayHashMapUnmanaged(Value) = .empty;
    defer fields.deinit(std.testing.allocator);

    try fields.put(
        std.testing.allocator,
        "Form_Template__c",
        Value{ .string = "a01000000000000001" },
    );
    try fields.put(
        std.testing.allocator,
        "demo__Relationship__r",
        Value{ .string = "parent" },
    );

    try std.testing.expectEqualStrings(
        "a01000000000000001",
        sobject_get(&fields, "pkg__Form_Template__c").?.string,
    );
    try std.testing.expectEqualStrings(
        "parent",
        sobject_get(&fields, "Relationship__r").?.string,
    );
}

test "sobject_put owns inserted field names" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const arena = arena_alloc.allocator();
    var fields: std.StringArrayHashMapUnmanaged(Value) = .empty;
    const dynamic_key = try std.testing.allocator.dupe(u8, "Transient__c");
    try sobject_put(&fields, arena, dynamic_key, Value{ .string = "kept" });
    std.testing.allocator.free(dynamic_key);

    try std.testing.expectEqualStrings(
        "kept",
        sobject_get(&fields, "Transient__c").?.string,
    );
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
    const stripped_name = strip_namespace_prefix(name);
    if (stripped_name.ptr != name.ptr) {
        if (fields.get(stripped_name)) |v| return v;
        for (fields.keys(), fields.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, stripped_name)) return v;
        }
    } else {
        for (fields.keys(), fields.values()) |k, v| {
            const stripped_key = strip_namespace_prefix(k);
            if (stripped_key.ptr != k.ptr and
                std.ascii.eqlIgnoreCase(stripped_key, name))
            {
                return v;
            }
        }
    }
    return null;
}

/// SObject フィールドをケースインセンシティブに設定する。
/// 既存のキーがある場合はそのキー名を維持し、値だけ更新する。
pub fn sobject_put(
    fields: *std.StringArrayHashMapUnmanaged(Value),
    arena: std.mem.Allocator,
    name: []const u8,
    value: Value,
) !void {
    // Check if there's an existing key with different case
    var existing_key: ?[]const u8 = null;
    const stripped_name = strip_namespace_prefix(name);
    for (fields.keys()) |k| {
        const stripped_key = strip_namespace_prefix(k);
        if (std.ascii.eqlIgnoreCase(k, name) or
            std.ascii.eqlIgnoreCase(stripped_key, stripped_name))
        {
            existing_key = k;
            break;
        }
    }
    if (existing_key) |ek| {
        try fields.put(arena, ek, value);
    } else {
        const owned_name = try arena.dupe(u8, name);
        try fields.put(arena, owned_name, value);
    }
}

fn strip_namespace_prefix(name: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, name, "__") orelse return name;
    if (sep == 0) return name;
    const rest_start = sep + 2;
    if (rest_start >= name.len) return name;
    if (!is_namespace_token(name[0..sep])) return name;

    const rest = name[rest_start..];
    if (std.mem.indexOf(u8, rest, "__") == null) return name;
    return rest;
}

fn is_namespace_token(token: []const u8) bool {
    if (token.len == 0) return false;
    if (!std.ascii.isAlphabetic(token[0])) return false;
    if (std.ascii.isUpper(token[0])) return false;
    for (token[1..]) |ch| {
        if (std.ascii.isUpper(ch)) return false;
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

test "strip_namespace_prefix does not strip local custom names" {
    try std.testing.expectEqualStrings(
        "Custom_Field__c",
        strip_namespace_prefix("Custom_Field__c"),
    );
    try std.testing.expectEqualStrings(
        "Custom_Object__r",
        strip_namespace_prefix("Custom_Object__r"),
    );
    try std.testing.expectEqualStrings(
        "RD2__Schedule_Field__c",
        strip_namespace_prefix("RD2__Schedule_Field__c"),
    );
    try std.testing.expectEqualStrings("Name", strip_namespace_prefix("Name"));
}

test "strip_namespace_prefix strips arbitrary managed namespaces" {
    try std.testing.expectEqualStrings(
        "Custom_Field__c",
        strip_namespace_prefix("pkg__Custom_Field__c"),
    );
    try std.testing.expectEqualStrings(
        "ChildRelationship__r",
        strip_namespace_prefix("pkg2__ChildRelationship__r"),
    );
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
    try std.testing.expectEqualStrings(
        "null",
        try coerce_to_string(Value.null_val, std.testing.allocator),
    );
    try std.testing.expectEqualStrings(
        "true",
        try coerce_to_string(Value{ .boolean = true }, std.testing.allocator),
    );
    try std.testing.expectEqualStrings(
        "hello",
        try coerce_to_string(Value{ .string = "hello" }, std.testing.allocator),
    );

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
            if (json[i] == '"') {
                in_str = true;
            } else if (json[i] == '{') {
                brace_depth += 1;
            } else if (json[i] == '}') {
                brace_depth -= 1;
            } else if (json[i] == '[') {
                bracket_depth += 1;
            } else if (json[i] == ']') {
                bracket_depth -= 1;
            }
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
