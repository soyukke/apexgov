//! env — 変数スコープ管理。
//!
//! リンクリスト形式のスコープチェーン。子スコープから親を辿って変数を解決する。

const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;

pub const Env = struct {
    bindings: std.StringArrayHashMapUnmanaged(Value) = .empty,
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

    pub fn get(self: *const Env, name: []const u8) ?Value {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    pub fn set(self: *Env, name: []const u8, value: Value) !void {
        if (self.bindings.getIndex(name)) |idx| {
            self.bindings.values()[idx] = value;
            return;
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
