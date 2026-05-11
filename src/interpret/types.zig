//! types — Apex インタープリターの共有型定義。
//!
//! パーサー型 (SourceLoc, Token, TokenKind, TypeRef) は apex_parser モジュールから
//! 再エクスポートする。ランタイム型 (Value 等) はここで定義。

const std = @import("std");

// ---------------------------------------------------------------------------
// パーサー型の再エクスポート (apex_parser から)
// ---------------------------------------------------------------------------

const apex_parser_types = @import("../apex_parser/types.zig");

pub const SourceLoc = apex_parser_types.SourceLoc;
pub const TokenKind = apex_parser_types.TokenKind;
pub const Token = apex_parser_types.Token;
pub const TypeRef = apex_parser_types.TypeRef;

// ---------------------------------------------------------------------------
// ランタイム値
// ---------------------------------------------------------------------------

pub const Value = union(enum) {
    null_val,
    boolean: bool,
    integer: i64,
    long: i64,
    double: f64,
    string: []const u8,
    sobject: *SObject,
    list: *ListValue,
    map: *MapValue,
    set: *SetValue,
    object: *ObjectInstance,
    void_val,

    pub fn is_null(self: Value) bool {
        return self == .null_val;
    }

    pub fn is_truthy(self: Value) bool {
        return switch (self) {
            .null_val => false,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .long => |i| i != 0,
            .double => |d| d != 0.0,
            .string => |s| s.len > 0,
            .void_val => false,
            else => true,
        };
    }
};

pub const SObject = struct {
    type_name: []const u8,
    fields: std.StringArrayHashMapUnmanaged(Value) = .empty,
    id: ?[]const u8 = null,
    /// When true, accessing a field not in `fields` throws SObjectException
    /// (set by Security.stripInaccessible)
    is_stripped: bool = false,
    /// When true, SObject.isClone() returns true (set by .clone()/.deepClone())
    is_clone: bool = false,
};

pub const ListValue = struct {
    items: std.ArrayListUnmanaged(Value) = .empty,
    element_type: ?[]const u8 = null,
    /// True when the list was created via `new List<SObject>()` or
    /// `new List<Object>()` in user source — i.e. explicitly constructed as a
    /// generic SObject list. Real Apex returns null from `getSObjectType()`
    /// for such lists even if all added elements happen to be the same
    /// concrete SObjectType. Lists that acquire `element_type = "SObject"`
    /// indirectly (parameter coercion from an untyped origin, `Map<Id,
    /// SObject>.values()` piped through a generic parameter, …) leave this
    /// false and can still resolve to the element type.
    explicitly_generic: bool = false,
};

pub const MapValue = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    key_values: std.StringArrayHashMapUnmanaged(Value) = .empty,
    schema_field_owner: ?[]const u8 = null,
};

pub const SetValue = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    element_type: ?[]const u8 = null,
    map_key_owner: ?*MapValue = null,
};

pub const ObjectInstance = struct {
    class_name: []const u8,
    fields: std.StringArrayHashMapUnmanaged(Value) = .empty,
};

// ---------------------------------------------------------------------------
// エラー
// ---------------------------------------------------------------------------

pub const ErrorKind = enum {
    null_pointer,
    type_mismatch,
    index_out_of_bounds,
    governor_limit,
    dml_error,
    unimplemented,
    user_exception,
    parse_error,
    name_error,
};

pub const RuntimeError = struct {
    message: []const u8,
    loc: SourceLoc,
    kind: ErrorKind,
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "Value.isNull" {
    const v: Value = .null_val;
    try std.testing.expect(v.is_null());
    const i: Value = .{ .integer = 42 };
    try std.testing.expect(!i.is_null());
}

test "Value.isTruthy" {
    const null_val: Value = .null_val;
    try std.testing.expect(!null_val.is_truthy());
    try std.testing.expect((Value{ .boolean = true }).is_truthy());
    try std.testing.expect(!(Value{ .boolean = false }).is_truthy());
    try std.testing.expect((Value{ .integer = 1 }).is_truthy());
    try std.testing.expect(!(Value{ .integer = 0 }).is_truthy());
    try std.testing.expect((Value{ .string = "hi" }).is_truthy());
    try std.testing.expect(!(Value{ .string = "" }).is_truthy());
}
