//! env — 変数スコープ管理。
//!
//! リンクリスト形式のスコープチェーン。子スコープから親を辿って変数を解決する。

const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;

pub const Env = struct {
    bindings: std.StringArrayHashMapUnmanaged(Value) = .empty,
    lower_binding_names: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    declared_types: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    lower_declared_type_names: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    parent: ?*Env = null,
    arena: std.mem.Allocator,
    this_value: ?Value = null,

    pub fn init(arena: std.mem.Allocator) Env {
        return .{ .arena = arena };
    }

    pub fn child(self: *Env) !*Env {
        const c = try self.arena.create(Env);
        c.* = .{ .arena = self.arena, .parent = self, .this_value = self.this_value };
        return c;
    }

    pub fn define(self: *Env, name: []const u8, value: Value) !void {
        try self.bindings.put(self.arena, name, value);
        try self.index_lower_name(&self.lower_binding_names, name);
        if (std.mem.eql(u8, name, "this")) self.this_value = value;
    }

    pub fn define_typed(
        self: *Env,
        name: []const u8,
        value: Value,
        declared_type: ?[]const u8,
    ) !void {
        try self.bindings.put(self.arena, name, value);
        try self.index_lower_name(&self.lower_binding_names, name);
        if (std.mem.eql(u8, name, "this")) self.this_value = value;
        if (declared_type) |type_name| {
            try self.declared_types.put(self.arena, name, type_name);
            try self.index_lower_name(&self.lower_declared_type_names, name);
        }
    }

    pub fn get(self: *const Env, name: []const u8) ?Value {
        // Exact match first (fast path)
        if (self.bindings.get(name)) |v| return v;
        if (self.get_binding_case_insensitive(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    pub fn get_exact(self: *const Env, name: []const u8) ?Value {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.get_exact(name);
        return null;
    }

    pub fn get_this(self: *const Env) ?Value {
        return self.this_value;
    }

    pub fn has(self: *const Env, name: []const u8) bool {
        if (self.bindings.contains(name)) return true;
        if (self.get_lower_index_name(&self.lower_binding_names, name)) |canonical| {
            if (self.bindings.contains(canonical)) return true;
        }
        if (self.parent) |p| return p.has(name);
        return false;
    }

    pub fn get_declared_type(self: *const Env, name: []const u8) ?[]const u8 {
        if (self.declared_types.get(name)) |t| return t;
        if (self.get_declared_type_case_insensitive(name)) |t| return t;
        if (self.parent) |p| return p.get_declared_type(name);
        return null;
    }

    pub fn has_local_declared_type(self: *const Env, name: []const u8) bool {
        if (self.declared_types.contains(name)) return true;
        const canonical = self.get_lower_index_name(
            &self.lower_declared_type_names,
            name,
        ) orelse return false;
        return self.declared_types.contains(canonical);
    }

    pub fn set(self: *Env, name: []const u8, value: Value) !void {
        if (self.bindings.getIndex(name)) |idx| {
            self.bindings.values()[idx] = value;
            if (std.mem.eql(u8, name, "this")) self.this_value = value;
            return;
        }
        if (self.get_lower_index_name(&self.lower_binding_names, name)) |canonical| {
            if (self.bindings.getIndex(canonical)) |idx| {
                self.bindings.values()[idx] = value;
                if (std.ascii.eqlIgnoreCase(name, "this")) self.this_value = value;
                return;
            }
        }
        if (self.parent) |p| return p.set(name, value);
        return error.UndefinedVariable;
    }

    fn index_lower_name(
        self: *Env,
        index: *std.StringArrayHashMapUnmanaged([]const u8),
        name: []const u8,
    ) !void {
        const allocate_lower = has_ascii_upper(name);
        const lower = if (allocate_lower)
            try std.ascii.allocLowerString(self.arena, name)
        else
            name;
        const gop = try index.getOrPut(self.arena, lower);
        if (gop.found_existing) {
            if (allocate_lower) self.arena.free(lower);
            return;
        }
        gop.value_ptr.* = name;
    }

    fn get_lower_index_name(
        self: *const Env,
        index: *const std.StringArrayHashMapUnmanaged([]const u8),
        name: []const u8,
    ) ?[]const u8 {
        if (!has_ascii_upper(name)) return index.get(name);

        var stack_buf: [128]u8 = undefined;
        const lower = if (name.len <= stack_buf.len)
            std.ascii.lowerString(stack_buf[0..name.len], name)
        else
            std.ascii.allocLowerString(self.arena, name) catch return null;
        defer if (name.len > stack_buf.len) self.arena.free(lower);

        return index.get(lower);
    }

    fn has_ascii_upper(name: []const u8) bool {
        for (name) |ch| {
            if (ch >= 'A' and ch <= 'Z') return true;
        }
        return false;
    }

    fn get_binding_case_insensitive(self: *const Env, name: []const u8) ?Value {
        const canonical = self.get_lower_index_name(&self.lower_binding_names, name) orelse return null;
        return self.bindings.get(canonical);
    }

    fn get_declared_type_case_insensitive(self: *const Env, name: []const u8) ?[]const u8 {
        const canonical = self.get_lower_index_name(
            &self.lower_declared_type_names,
            name,
        ) orelse return null;
        return self.declared_types.get(canonical);
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
