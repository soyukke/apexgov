//! builtins — Apex 標準ライブラリのビルトイン関数。
//!
//! System.debug, String メソッド, Integer.valueOf, TestFactory, Database 等。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const Value = types.Value;

pub const BuiltinContext = struct {
    arena: std.mem.Allocator,
    stdout: *std.ArrayListUnmanaged(u8),
};

/// 静的メソッド呼び出しを試行する。
pub fn dispatchStatic(ctx: *BuiltinContext, class_name: []const u8, method_name: []const u8, args: []const Value) !?Value {
    // System.debug
    if (std.ascii.eqlIgnoreCase(class_name, "System") and std.ascii.eqlIgnoreCase(method_name, "debug")) {
        const msg = if (args.len > 0) try utils.coerceToString(args[0], ctx.arena) else "";
        try ctx.stdout.appendSlice(ctx.arena, msg);
        try ctx.stdout.append(ctx.arena, '\n');
        return .void_val;
    }

    // String.valueOf
    if (std.ascii.eqlIgnoreCase(class_name, "String") and std.ascii.eqlIgnoreCase(method_name, "valueOf")) {
        if (args.len > 0) return Value{ .string = try utils.coerceToString(args[0], ctx.arena) };
        return Value{ .string = "null" };
    }
    // String.isBlank / isNotBlank
    if (std.ascii.eqlIgnoreCase(class_name, "String") and std.ascii.eqlIgnoreCase(method_name, "isBlank")) {
        if (args.len > 0) {
            if (args[0] == .null_val) return Value{ .boolean = true };
            if (args[0] == .string) return Value{ .boolean = std.mem.trim(u8, args[0].string, " \t\r\n").len == 0 };
        }
        return Value{ .boolean = true };
    }
    if (std.ascii.eqlIgnoreCase(class_name, "String") and std.ascii.eqlIgnoreCase(method_name, "isNotBlank")) {
        if (args.len > 0) {
            if (args[0] == .null_val) return Value{ .boolean = false };
            if (args[0] == .string) return Value{ .boolean = std.mem.trim(u8, args[0].string, " \t\r\n").len > 0 };
        }
        return Value{ .boolean = false };
    }

    // Integer.valueOf
    if (std.ascii.eqlIgnoreCase(class_name, "Integer") and std.ascii.eqlIgnoreCase(method_name, "valueOf")) {
        if (args.len > 0) {
            return switch (args[0]) {
                .string => |s| Value{ .integer = std.fmt.parseInt(i64, s, 10) catch 0 },
                .integer => args[0],
                else => Value.null_val,
            };
        }
        return Value.null_val;
    }

    // Date.today / Date.newInstance
    if (std.ascii.eqlIgnoreCase(class_name, "Date")) {
        if (std.ascii.eqlIgnoreCase(method_name, "today")) return Value{ .string = "2026-04-06" };
        if (std.ascii.eqlIgnoreCase(method_name, "newInstance")) return Value{ .string = "2026-01-01" };
        if (std.ascii.eqlIgnoreCase(method_name, "valueOf")) {
            if (args.len > 0 and args[0] == .string) return args[0];
            return Value{ .string = "2026-01-01" };
        }
        return Value{ .string = "2026-04-06" };
    }

    // DateTime
    if (std.ascii.eqlIgnoreCase(class_name, "DateTime")) {
        return Value{ .string = "2026-04-06T00:00:00Z" };
    }

    // JSON.serialize / deserialize
    if (std.ascii.eqlIgnoreCase(class_name, "JSON")) {
        if (std.ascii.eqlIgnoreCase(method_name, "serialize") or std.ascii.eqlIgnoreCase(method_name, "serializePretty")) {
            if (args.len > 0) return Value{ .string = try utils.coerceToString(args[0], ctx.arena) };
            return Value{ .string = "{}" };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "deserializeUntyped")) {
            return Value.null_val;
        }
        return Value.null_val;
    }

    // UserInfo
    if (std.ascii.eqlIgnoreCase(class_name, "UserInfo")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getUserId")) return Value{ .string = "005000000000001" };
        if (std.ascii.eqlIgnoreCase(method_name, "getProfileId")) return Value{ .string = "00e000000000001" };
        if (std.ascii.eqlIgnoreCase(method_name, "getName")) return Value{ .string = "Test User" };
        return Value{ .string = "" };
    }

    // Quiddity
    if (std.ascii.eqlIgnoreCase(class_name, "Quiddity")) {
        return Value{ .string = method_name };
    }

    // Database methods
    if (std.ascii.eqlIgnoreCase(class_name, "Database")) {
        return dispatchDatabase(ctx, method_name, args);
    }

    // HttpResponse constructor-like stubs
    if (std.ascii.eqlIgnoreCase(class_name, "HttpResponse") or std.ascii.eqlIgnoreCase(class_name, "HttpRequest")) {
        const obj = try ctx.arena.create(types.ObjectInstance);
        obj.* = .{ .class_name = class_name };
        return Value{ .object = obj };
    }

    // Schema.getGlobalDescribe
    if (std.ascii.eqlIgnoreCase(class_name, "Schema")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getGlobalDescribe")) {
            const map = try ctx.arena.create(types.MapValue);
            map.* = .{};
            return Value{ .map = map };
        }
        return Value.null_val;
    }

    // FeatureManagement
    if (std.ascii.eqlIgnoreCase(class_name, "FeatureManagement")) return .void_val;

    // Limits
    if (std.ascii.eqlIgnoreCase(class_name, "Limits")) return Value{ .integer = 0 };

    // Type.forName → return a type object stub
    if (std.ascii.eqlIgnoreCase(class_name, "Type") and std.ascii.eqlIgnoreCase(method_name, "forName")) {
        if (args.len > 0 and args[0] == .string) {
            const obj = try ctx.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Type" };
            try obj.fields.put(ctx.arena, "name", args[0]);
            return Value{ .object = obj };
        }
        return Value.null_val;
    }

    // Request.getCurrent
    if (std.ascii.eqlIgnoreCase(class_name, "Request")) {
        const obj = try ctx.arena.create(types.ObjectInstance);
        obj.* = .{ .class_name = "Request" };
        return Value{ .object = obj };
    }

    // Crypto
    if (std.ascii.eqlIgnoreCase(class_name, "Crypto")) {
        if (std.ascii.eqlIgnoreCase(method_name, "generateDigest") or
            std.ascii.eqlIgnoreCase(method_name, "generateMac") or
            std.ascii.eqlIgnoreCase(method_name, "sign") or
            std.ascii.eqlIgnoreCase(method_name, "generateAesKey"))
        {
            const obj = try ctx.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Blob" };
            return Value{ .object = obj };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "encryptWithManagedIV") or
            std.ascii.eqlIgnoreCase(method_name, "decryptWithManagedIV") or
            std.ascii.eqlIgnoreCase(method_name, "encrypt") or
            std.ascii.eqlIgnoreCase(method_name, "decrypt"))
        {
            const obj = try ctx.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Blob" };
            return Value{ .object = obj };
        }
        return Value.null_val;
    }

    // Blob
    if (std.ascii.eqlIgnoreCase(class_name, "Blob")) {
        if (std.ascii.eqlIgnoreCase(method_name, "valueOf")) return Value{ .string = "blob" };
        return Value.null_val;
    }

    // EncodingUtil
    if (std.ascii.eqlIgnoreCase(class_name, "EncodingUtil")) {
        return Value{ .string = "encoded" };
    }

    // EventBus
    if (std.ascii.eqlIgnoreCase(class_name, "EventBus")) {
        if (std.ascii.eqlIgnoreCase(method_name, "publish")) {
            const obj = try ctx.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Database.SaveResult" };
            try obj.fields.put(ctx.arena, "isSuccess", Value{ .boolean = true });
            return Value{ .object = obj };
        }
        return .void_val;
    }

    // Test.setMock, Test.isRunningTest, etc.
    if (std.ascii.eqlIgnoreCase(class_name, "Test")) {
        if (std.ascii.eqlIgnoreCase(method_name, "isRunningTest")) return Value{ .boolean = true };
        return .void_val;
    }

    // Cache.Org / Cache.Session
    if (std.ascii.eqlIgnoreCase(class_name, "Cache")) return .void_val;

    // Http
    if (std.ascii.eqlIgnoreCase(class_name, "Http")) {
        if (std.ascii.eqlIgnoreCase(method_name, "send")) {
            const resp = try ctx.arena.create(types.ObjectInstance);
            resp.* = .{ .class_name = "HttpResponse" };
            try resp.fields.put(ctx.arena, "statusCode", Value{ .integer = 200 });
            try resp.fields.put(ctx.arena, "body", Value{ .string = "{\"id\":\"001000000000001\"}" });
            return Value{ .object = resp };
        }
    }

    return null;
}

fn dispatchDatabase(ctx: *BuiltinContext, method_name: []const u8, args: []const Value) !?Value {
    _ = args;
    // Database.insert / update / delete return SaveResult list
    if (std.ascii.eqlIgnoreCase(method_name, "insert") or
        std.ascii.eqlIgnoreCase(method_name, "update") or
        std.ascii.eqlIgnoreCase(method_name, "upsert") or
        std.ascii.eqlIgnoreCase(method_name, "delete"))
    {
        // Return a list with one successful SaveResult
        const list = try ctx.arena.create(types.ListValue);
        list.* = .{};
        const sr = try ctx.arena.create(types.ObjectInstance);
        sr.* = .{ .class_name = "Database.SaveResult" };
        try sr.fields.put(ctx.arena, "isSuccess", Value{ .boolean = true });
        try sr.fields.put(ctx.arena, "Id", Value{ .string = "001000000000001" });
        try list.items.append(ctx.arena, Value{ .object = sr });
        return Value{ .list = list };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "query")) {
        const list = try ctx.arena.create(types.ListValue);
        list.* = .{};
        return Value{ .list = list };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "countQuery")) {
        return Value{ .integer = 0 };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getQueryLocator")) {
        return Value.null_val;
    }
    return Value.null_val;
}

/// インスタンスメソッド呼び出しを試行する。
pub fn dispatchInstance(ctx: *BuiltinContext, receiver: Value, method_name: []const u8, args: []const Value) !?Value {
    switch (receiver) {
        .string => |s| return dispatchStringInstance(ctx, s, method_name, args),
        .list => |list| return dispatchListInstance(ctx, list, method_name, args),
        .map => |map| return dispatchMapInstance(ctx, map, method_name, args),
        .set => |set| return dispatchSetInstance(ctx, set, method_name, args),
        .object => |obj| return dispatchObjectInstance(ctx, obj, method_name, args),
        .sobject => |sob| return dispatchSObjectInstance(ctx, sob, method_name, args),
        else => return null,
    }
}

fn dispatchStringInstance(ctx: *BuiltinContext, s: []const u8, method_name: []const u8, args: []const Value) !?Value {
    _ = ctx;
    _ = args;
    if (std.ascii.eqlIgnoreCase(method_name, "length")) return Value{ .integer = @intCast(s.len) };
    return null; // Let evaluator handle more string methods
}

fn dispatchListInstance(ctx: *BuiltinContext, list: *types.ListValue, method_name: []const u8, args: []const Value) !?Value {
    if (std.ascii.eqlIgnoreCase(method_name, "add") and args.len > 0) {
        try list.items.append(ctx.arena, args[0]);
        return .void_val;
    }
    if (std.ascii.eqlIgnoreCase(method_name, "size")) return Value{ .integer = @intCast(list.items.items.len) };
    if (std.ascii.eqlIgnoreCase(method_name, "isEmpty")) return Value{ .boolean = list.items.items.len == 0 };
    return null;
}

fn dispatchMapInstance(ctx: *BuiltinContext, map: *types.MapValue, method_name: []const u8, args: []const Value) !?Value {
    if (std.ascii.eqlIgnoreCase(method_name, "put") and args.len >= 2) {
        const key = try utils.coerceToString(args[0], ctx.arena);
        try map.entries.put(ctx.arena, key, args[1]);
        return .void_val;
    }
    if (std.ascii.eqlIgnoreCase(method_name, "get") and args.len > 0) {
        const key = try utils.coerceToString(args[0], ctx.arena);
        return map.entries.get(key) orelse Value.null_val;
    }
    if (std.ascii.eqlIgnoreCase(method_name, "containsKey") and args.len > 0) {
        const key = try utils.coerceToString(args[0], ctx.arena);
        return Value{ .boolean = map.entries.contains(key) };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "size")) return Value{ .integer = @intCast(map.entries.count()) };
    if (std.ascii.eqlIgnoreCase(method_name, "isEmpty")) return Value{ .boolean = map.entries.count() == 0 };
    if (std.ascii.eqlIgnoreCase(method_name, "keySet")) {
        const set = try ctx.arena.create(types.SetValue);
        set.* = .{};
        for (map.entries.keys()) |key| try set.entries.put(ctx.arena, key, {});
        return Value{ .set = set };
    }
    return null;
}

fn dispatchSetInstance(ctx: *BuiltinContext, set: *types.SetValue, method_name: []const u8, args: []const Value) !?Value {
    if (std.ascii.eqlIgnoreCase(method_name, "add") and args.len > 0) {
        const key = try utils.coerceToString(args[0], ctx.arena);
        try set.entries.put(ctx.arena, key, {});
        return Value{ .boolean = true };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "contains") and args.len > 0) {
        const key = try utils.coerceToString(args[0], ctx.arena);
        return Value{ .boolean = set.entries.contains(key) };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "size")) return Value{ .integer = @intCast(set.entries.count()) };
    return null;
}

fn dispatchObjectInstance(ctx: *BuiltinContext, obj: *types.ObjectInstance, method_name: []const u8, args: []const Value) !?Value {
    // SaveResult / UpsertResult methods
    if (std.ascii.eqlIgnoreCase(method_name, "isSuccess") or std.ascii.eqlIgnoreCase(method_name, "isCreated")) {
        return obj.fields.get("isSuccess") orelse Value{ .boolean = true };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getId")) {
        return obj.fields.get("Id") orelse Value.null_val;
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getErrors")) {
        const list = try ctx.arena.create(types.ListValue);
        list.* = .{};
        return Value{ .list = list };
    }

    // HttpResponse methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "HttpResponse") or std.mem.startsWith(u8, obj.class_name, "Http")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getStatusCode")) {
            return obj.fields.get("statusCode") orelse Value{ .integer = 200 };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getBody")) {
            return obj.fields.get("body") orelse Value{ .string = "{}" };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "setStatusCode") and args.len > 0) {
            try obj.fields.put(ctx.arena, "statusCode", args[0]);
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "setBody") and args.len > 0) {
            try obj.fields.put(ctx.arena, "body", args[0]);
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "setMethod") or
            std.ascii.eqlIgnoreCase(method_name, "setEndpoint") or
            std.ascii.eqlIgnoreCase(method_name, "setHeader") or
            std.ascii.eqlIgnoreCase(method_name, "setTimeout"))
        {
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "send")) {
            const resp = try ctx.arena.create(types.ObjectInstance);
            resp.* = .{ .class_name = "HttpResponse" };
            try resp.fields.put(ctx.arena, "statusCode", Value{ .integer = 200 });
            try resp.fields.put(ctx.arena, "body", Value{ .string = "{\"id\":\"001000000000001\"}" });
            return Value{ .object = resp };
        }
    }

    // Date methods (stored as string)
    if (std.ascii.eqlIgnoreCase(method_name, "addDays") or std.ascii.eqlIgnoreCase(method_name, "addMonths")) {
        return obj.fields.get("value") orelse Value{ .string = "2026-04-20" };
    }

    // Type methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Type")) {
        if (std.ascii.eqlIgnoreCase(method_name, "newInstance")) {
            const inst = try ctx.arena.create(types.ObjectInstance);
            inst.* = .{ .class_name = if (obj.fields.get("name")) |n| n.string else "Object" };
            return Value{ .object = inst };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getName")) {
            return obj.fields.get("name") orelse Value{ .string = "Object" };
        }
    }

    // Request.getQuiddity
    if (std.ascii.eqlIgnoreCase(method_name, "getQuiddity")) {
        return Value{ .string = "RUNTEST" };
    }

    // Generic getter pattern
    if (std.mem.startsWith(u8, method_name, "get") and method_name.len > 3) {
        const field = method_name[3..];
        return obj.fields.get(field) orelse Value.null_val;
    }
    if (std.mem.startsWith(u8, method_name, "is") and method_name.len > 2) {
        const field = method_name;
        return obj.fields.get(field) orelse Value{ .boolean = false };
    }
    if (std.mem.startsWith(u8, method_name, "set") and method_name.len > 3 and args.len > 0) {
        const field = method_name[3..];
        try obj.fields.put(ctx.arena, field, args[0]);
        return .void_val;
    }

    return null;
}

fn dispatchSObjectInstance(ctx: *BuiltinContext, sob: *types.SObject, method_name: []const u8, args: []const Value) !?Value {
    if (std.ascii.eqlIgnoreCase(method_name, "getSObjectType")) {
        return Value{ .string = sob.type_name };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getSObjects") and args.len > 0 and args[0] == .string) {
        return sob.fields.get(args[0].string) orelse blk: {
            const list = try ctx.arena.create(types.ListValue);
            list.* = .{};
            break :blk Value{ .list = list };
        };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "get") and args.len > 0 and args[0] == .string) {
        return sob.fields.get(args[0].string) orelse Value.null_val;
    }
    if (std.ascii.eqlIgnoreCase(method_name, "put") and args.len >= 2 and args[0] == .string) {
        try sob.fields.put(ctx.arena, args[0].string, args[1]);
        return args[1];
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getPopulatedFieldsAsMap")) {
        const map = try ctx.arena.create(types.MapValue);
        map.* = .{};
        for (sob.fields.keys(), sob.fields.values()) |k, v| {
            try map.entries.put(ctx.arena, k, v);
        }
        return Value{ .map = map };
    }
    return null;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "System.debug captures output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    var ctx = BuiltinContext{ .arena = arena.allocator(), .stdout = &stdout };

    const result = try dispatchStatic(&ctx, "System", "debug", &.{Value{ .string = "hello" }});
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .void_val);
    try std.testing.expectEqualStrings("hello\n", stdout.items);
}

test "String.valueOf converts integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    var ctx = BuiltinContext{ .arena = arena.allocator(), .stdout = &stdout };

    const result = try dispatchStatic(&ctx, "String", "valueOf", &.{Value{ .integer = 42 }});
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("42", result.?.string);
}

test "String.length instance method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    var ctx = BuiltinContext{ .arena = arena.allocator(), .stdout = &stdout };

    const result = try dispatchInstance(&ctx, Value{ .string = "test" }, "length", &.{});
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 4), result.?.integer);
}
