//! env — 変数スコープ管理。
//!
//! リンクリスト形式のスコープチェーン。子スコープから親を辿って変数を解決する。

const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;

pub const Env = struct {
    bindings: std.StringArrayHashMapUnmanaged(Value) = .empty,
    declared_types: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    parent: ?*Env = null,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Env {
        return .{ .arena = arena };
    }

    pub fn child(self: *Env) !*Env {
        const c = try self.arena.create(Env);
        c.* = .{ .arena = self.arena, .parent = self };
        return c;
    }

    pub fn define(self: *Env, name: []const u8, value: Value) !void {
        try self.bindings.put(self.arena, name, value);
    }

    pub fn define_typed(self: *Env, name: []const u8, value: Value, declared_type: ?[]const u8) !void {
        try self.bindings.put(self.arena, name, value);
        if (declared_type) |type_name| {
            try self.declared_types.put(self.arena, name, type_name);
        }
    }

    pub fn get(self: *const Env, name: []const u8) ?Value {
        // Exact match first (fast path)
        if (self.bindings.get(name)) |v| return v;
        // Case-insensitive fallback (Apex identifiers are case-insensitive)
        for (self.bindings.keys(), self.bindings.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, name)) return v;
        }
        if (self.parent) |p| return p.get(name);
        return null;
    }

    pub fn has(self: *const Env, name: []const u8) bool {
        if (self.bindings.contains(name)) return true;
        for (self.bindings.keys()) |k| {
            if (std.ascii.eqlIgnoreCase(k, name)) return true;
        }
        if (self.parent) |p| return p.has(name);
        return false;
    }

    pub fn get_declared_type(self: *const Env, name: []const u8) ?[]const u8 {
        if (self.declared_types.get(name)) |t| return t;
        for (self.declared_types.keys(), self.declared_types.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, name)) return v;
        }
        if (self.parent) |p| return p.get_declared_type(name);
        return null;
    }

    pub fn set(self: *Env, name: []const u8, value: Value) !void {
        if (self.bindings.getIndex(name)) |idx| {
            self.bindings.values()[idx] = value;
            return;
        }
        // Case-insensitive fallback
        for (self.bindings.keys(), 0..) |k, idx| {
            if (std.ascii.eqlIgnoreCase(k, name)) {
                self.bindings.values()[idx] = value;
                return;
            }
        }
        if (self.parent) |p| return p.set(name, value);
        return error.UndefinedVariable;
    }
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "define and get variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    try env.define("x", .{ .integer = 42 });
    const val = env.get("x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 42), val.integer);
}

test "child scope shadows parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parent = Env.init(arena.allocator());
    try parent.define("x", .{ .integer = 1 });

    var c = try parent.child();
    try c.define("x", .{ .integer = 2 });

    try std.testing.expectEqual(@as(i64, 2), c.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parent.get("x").?.integer);
}

test "child scope reads parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parent = Env.init(arena.allocator());
    try parent.define("y", .{ .string = "hello" });

    const c = try parent.child();
    const val = c.get("y") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", val.string);
}

test "set updates parent binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parent = Env.init(arena.allocator());
    try parent.define("x", .{ .integer = 1 });

    var c = try parent.child();
    try c.set("x", .{ .integer = 99 });

    try std.testing.expectEqual(@as(i64, 99), parent.get("x").?.integer);
}

test "set undefined variable returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    try std.testing.expectError(error.UndefinedVariable, env.set("nope", .{ .integer = 1 }));
}

test "defineTyped stores declared type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    try env.define_typed("account", .null_val, "Account");

    try std.testing.expectEqualStrings("Account", env.get_declared_type("account").?);
}

test "has returns true for null-valued bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    try env.define("thing", .null_val);

    try std.testing.expect(env.has("thing"));
    try std.testing.expect(!env.has("missing"));
}
