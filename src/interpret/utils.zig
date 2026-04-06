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
        else => false, // reference types — for now, no deep equality
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
        else => "<object>",
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

test "coerceToString" {
    try std.testing.expectEqualStrings("null", try coerceToString(Value.null_val, std.testing.allocator));
    try std.testing.expectEqualStrings("true", try coerceToString(Value{ .boolean = true }, std.testing.allocator));
    try std.testing.expectEqualStrings("hello", try coerceToString(Value{ .string = "hello" }, std.testing.allocator));

    const s = try coerceToString(Value{ .integer = 42 }, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("42", s);
}
