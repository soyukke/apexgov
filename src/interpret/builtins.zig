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
        // System.debug(msg) or System.debug(LoggingLevel, msg)
        const msg = if (args.len >= 2) try utils.coerceToString(args[1], ctx.arena) else if (args.len > 0) try utils.coerceToString(args[0], ctx.arena) else "";
        try ctx.stdout.appendSlice(ctx.arena, msg);
        try ctx.stdout.append(ctx.arena, '\n');
        return .void_val;
    }

    // String.escapeSingleQuotes
    if (std.ascii.eqlIgnoreCase(class_name, "String") and std.ascii.eqlIgnoreCase(method_name, "escapeSingleQuotes")) {
        if (args.len > 0 and args[0] == .string) return args[0];
        return Value{ .string = "" };
    }
    // String.join
    if (std.ascii.eqlIgnoreCase(class_name, "String") and std.ascii.eqlIgnoreCase(method_name, "join")) {
        if (args.len >= 2 and args[0] == .list and args[1] == .string) {
            var result: std.ArrayListUnmanaged(u8) = .empty;
            for (args[0].list.items.items, 0..) |item, idx| {
                if (idx > 0) try result.appendSlice(ctx.arena, args[1].string);
                const s = try utils.coerceToString(item, ctx.arena);
                try result.appendSlice(ctx.arena, s);
            }
            return Value{ .string = try result.toOwnedSlice(ctx.arena) };
        }
        return Value{ .string = "" };
    }
    // String.format
    if (std.ascii.eqlIgnoreCase(class_name, "String") and std.ascii.eqlIgnoreCase(method_name, "format")) {
        if (args.len > 0 and args[0] == .string) return args[0]; // simplified
        return Value{ .string = "" };
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

    // Decimal.valueOf
    if (std.ascii.eqlIgnoreCase(class_name, "Decimal")) {
        if (std.ascii.eqlIgnoreCase(method_name, "valueOf")) {
            if (args.len > 0) {
                return switch (args[0]) {
                    .string => |s| Value{ .double = std.fmt.parseFloat(f64, s) catch 0.0 },
                    .integer => |i| Value{ .double = @floatFromInt(i) },
                    .double => args[0],
                    else => Value{ .double = 0.0 },
                };
            }
            return Value{ .double = 0.0 };
        }
        return Value{ .double = 0.0 };
    }

    // Double.valueOf
    if (std.ascii.eqlIgnoreCase(class_name, "Double")) {
        if (std.ascii.eqlIgnoreCase(method_name, "valueOf")) {
            if (args.len > 0) {
                return switch (args[0]) {
                    .string => |s| Value{ .double = std.fmt.parseFloat(f64, s) catch 0.0 },
                    .integer => |i| Value{ .double = @floatFromInt(i) },
                    .double => args[0],
                    else => Value{ .double = 0.0 },
                };
            }
            return Value{ .double = 0.0 };
        }
        return Value{ .double = 0.0 };
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
            if (args.len > 0) return Value{ .string = try utils.toJson(args[0], ctx.arena) };
            return Value{ .string = "{}" };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "deserializeUntyped")) {
            // Return a Map from simple JSON string
            if (args.len > 0 and args[0] == .string) {
                const json_str = args[0].string;
                const map = try ctx.arena.create(types.MapValue);
                map.* = .{};
                // Very simple JSON key-value extraction
                var pos: usize = 0;
                while (pos < json_str.len) {
                    // Find next quoted key
                    const key_start_opt = std.mem.indexOfPos(u8, json_str, pos, "\"");
                    if (key_start_opt) |key_start| {
                        const key_end_opt = std.mem.indexOfPos(u8, json_str, key_start + 1, "\"");
                        if (key_end_opt) |key_end| {
                            const key = json_str[key_start + 1 .. key_end];
                            // Find colon after key
                            const colon_opt = std.mem.indexOfPos(u8, json_str, key_end + 1, ":");
                            if (colon_opt) |colon_pos| {
                                var val_start = colon_pos + 1;
                                while (val_start < json_str.len and (json_str[val_start] == ' ' or json_str[val_start] == '\t' or json_str[val_start] == '\n' or json_str[val_start] == '\r')) val_start += 1;
                                if (val_start < json_str.len) {
                                    if (json_str[val_start] == '"') {
                                        // String value
                                        if (std.mem.indexOfPos(u8, json_str, val_start + 1, "\"")) |val_end| {
                                            try map.entries.put(ctx.arena, key, Value{ .string = json_str[val_start + 1 .. val_end] });
                                            pos = val_end + 1;
                                            continue;
                                        }
                                    } else if (json_str[val_start] == '[') {
                                        // Array value - store as list
                                        const list = try ctx.arena.create(types.ListValue);
                                        list.* = .{};
                                        try map.entries.put(ctx.arena, key, Value{ .list = list });
                                        pos = val_start + 1;
                                        continue;
                                    } else {
                                        // Number or other value
                                        var val_end = val_start;
                                        while (val_end < json_str.len and json_str[val_end] != ',' and json_str[val_end] != '}' and json_str[val_end] != '\n') val_end += 1;
                                        const val_str = std.mem.trim(u8, json_str[val_start..val_end], " \t\r\n");
                                        if (std.fmt.parseInt(i64, val_str, 10)) |num| {
                                            try map.entries.put(ctx.arena, key, Value{ .integer = num });
                                        } else |_| {
                                            try map.entries.put(ctx.arena, key, Value{ .string = val_str });
                                        }
                                        pos = val_end;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                    pos += 1;
                }
                return Value{ .map = map };
            }
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "deserialize")) {
            // Return the deserialized value - simplified stub
            // JSON.deserialize(jsonString, Type) → return appropriate object
            if (args.len >= 2 and args[0] == .string) {
                // For now, return an SObject stub if it looks like it should be one
                const obj = try ctx.arena.create(types.SObject);
                obj.* = .{ .type_name = "Object" };
                return Value{ .sobject = obj };
            }
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

    // LoggingLevel
    if (std.ascii.eqlIgnoreCase(class_name, "LoggingLevel")) {
        return Value{ .string = method_name };
    }

    // System.currentTimeMillis / System.now
    if (std.ascii.eqlIgnoreCase(class_name, "System")) {
        if (std.ascii.eqlIgnoreCase(method_name, "currentTimeMillis")) return Value{ .integer = 1000 };
        if (std.ascii.eqlIgnoreCase(method_name, "now")) return Value{ .string = "2026-04-06T00:00:00Z" };
        if (std.ascii.eqlIgnoreCase(method_name, "today")) return Value{ .string = "2026-04-06" };
        if (std.ascii.eqlIgnoreCase(method_name, "runAs")) return .void_val;
        // enqueueJob is handled by the evaluator, not here
        // if (std.ascii.eqlIgnoreCase(method_name, "enqueueJob")) return Value.null_val;
    }

    // Quiddity
    if (std.ascii.eqlIgnoreCase(class_name, "Quiddity")) {
        return Value{ .string = method_name };
    }

    // Database methods
    if (std.ascii.eqlIgnoreCase(class_name, "Database")) {
        return dispatchDatabase(ctx, method_name, args);
    }

    // RestContext
    if (std.ascii.eqlIgnoreCase(class_name, "RestContext")) {
        if (std.ascii.eqlIgnoreCase(method_name, "request") or std.ascii.eqlIgnoreCase(method_name, "getRequest")) {
            const req = try ctx.arena.create(types.ObjectInstance);
            req.* = .{ .class_name = "RestRequest" };
            try req.fields.put(ctx.arena, "requestURI", Value{ .string = "/services/apexrest/test" });
            try req.fields.put(ctx.arena, "httpMethod", Value{ .string = "GET" });
            try req.fields.put(ctx.arena, "requestBody", Value.null_val);
            return Value{ .object = req };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "response") or std.ascii.eqlIgnoreCase(method_name, "getResponse")) {
            const resp = try ctx.arena.create(types.ObjectInstance);
            resp.* = .{ .class_name = "RestResponse" };
            try resp.fields.put(ctx.arena, "statusCode", Value{ .integer = 200 });
            try resp.fields.put(ctx.arena, "responseBody", Value.null_val);
            return Value{ .object = resp };
        }
        return Value.null_val;
    }

    // HttpResponse constructor-like stubs
    if (std.ascii.eqlIgnoreCase(class_name, "HttpResponse") or std.ascii.eqlIgnoreCase(class_name, "HttpRequest")) {
        const obj = try ctx.arena.create(types.ObjectInstance);
        obj.* = .{ .class_name = class_name };
        return Value{ .object = obj };
    }

    // Schema.getGlobalDescribe / describeSObjects
    if (std.ascii.eqlIgnoreCase(class_name, "Schema")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getGlobalDescribe")) {
            const map = try ctx.arena.create(types.MapValue);
            map.* = .{};
            // Populate common SObject types
            for ([_][]const u8{ "Account", "Contact", "Opportunity", "Task", "Lead", "Case", "User" }) |obj_name| {
                const desc = try createDescribeResult(ctx, obj_name);
                try map.entries.put(ctx.arena, obj_name, desc);
            }
            return Value{ .map = map };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "describeSObjects")) {
            // Returns a list of DescribeSObjectResult
            const list = try ctx.arena.create(types.ListValue);
            list.* = .{};
            if (args.len > 0 and args[0] == .list) {
                for (args[0].list.items.items) |item| {
                    const obj_name = if (item == .string) item.string else "Object";
                    const desc = try createDescribeResult(ctx, obj_name);
                    try list.items.append(ctx.arena, desc);
                }
            } else if (args.len > 0 and args[0] == .string) {
                const desc = try createDescribeResult(ctx, args[0].string);
                try list.items.append(ctx.arena, desc);
            }
            return Value{ .list = list };
        }
        return Value.null_val;
    }

    // Security.stripInaccessible
    if (std.ascii.eqlIgnoreCase(class_name, "Security")) {
        if (std.ascii.eqlIgnoreCase(method_name, "stripInaccessible")) {
            // Return an SObjectAccessDecision stub
            const obj = try ctx.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "SObjectAccessDecision" };
            // getRecords() returns the input list
            if (args.len >= 2) {
                try obj.fields.put(ctx.arena, "records", args[1]);
            } else if (args.len >= 1 and args[0] == .list) {
                try obj.fields.put(ctx.arena, "records", args[0]);
            }
            // getRemovedFields() returns empty map
            const rm_map = try ctx.arena.create(types.MapValue);
            rm_map.* = .{};
            try obj.fields.put(ctx.arena, "removedFields", Value{ .map = rm_map });
            return Value{ .object = obj };
        }
        return Value.null_val;
    }

    // AccessLevel enum
    if (std.ascii.eqlIgnoreCase(class_name, "AccessLevel")) {
        return Value{ .string = method_name };
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
            // Store first arg's value for round-trip (decrypt returns original)
            const val = if (args.len > 0 and args[0] == .object and args[0].object.fields.get("value") != null)
                args[0].object.fields.get("value").?
            else
                Value{ .string = "crypto-output" };
            try obj.fields.put(ctx.arena, "value", val);
            return Value{ .object = obj };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "encryptWithManagedIV") or
            std.ascii.eqlIgnoreCase(method_name, "decryptWithManagedIV") or
            std.ascii.eqlIgnoreCase(method_name, "encrypt") or
            std.ascii.eqlIgnoreCase(method_name, "decrypt"))
        {
            const obj = try ctx.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Blob" };
            // For decrypt, return the original data (first blob arg's value)
            const val = if (args.len > 0 and args[0] == .object and args[0].object.fields.get("value") != null)
                args[0].object.fields.get("value").?
            else
                Value{ .string = "encrypted-data" };
            try obj.fields.put(ctx.arena, "value", val);
            return Value{ .object = obj };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "verify") or
            std.ascii.eqlIgnoreCase(method_name, "verifyHMAC") or
            std.ascii.eqlIgnoreCase(method_name, "verifyMac"))
        {
            return Value{ .boolean = true }; // HMAC verification passes
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getRandomInteger") or
            std.ascii.eqlIgnoreCase(method_name, "getRandomLong"))
        {
            return Value{ .integer = 42 };
        }
        return Value.null_val;
    }

    // Blob
    if (std.ascii.eqlIgnoreCase(class_name, "Blob")) {
        if (std.ascii.eqlIgnoreCase(method_name, "valueOf")) {
            // Return a Blob object that stores the string and supports toString()
            if (args.len > 0 and args[0] == .string) {
                const blob = try ctx.arena.create(types.ObjectInstance);
                blob.* = .{ .class_name = "Blob" };
                try blob.fields.put(ctx.arena, "value", args[0]);
                return Value{ .object = blob };
            }
            const blob = try ctx.arena.create(types.ObjectInstance);
            blob.* = .{ .class_name = "Blob" };
            try blob.fields.put(ctx.arena, "value", Value{ .string = "" });
            return Value{ .object = blob };
        }
        return Value.null_val;
    }

    // EncodingUtil
    if (std.ascii.eqlIgnoreCase(class_name, "EncodingUtil")) {
        if (std.ascii.eqlIgnoreCase(method_name, "urlEncode") and args.len > 0 and args[0] == .string) {
            return args[0]; // return the input string (simplified)
        }
        if (std.ascii.eqlIgnoreCase(method_name, "base64Encode") and args.len > 0) {
            // For Blob input, get the value field
            if (args[0] == .object) {
                return args[0].object.fields.get("value") orelse Value{ .string = "" };
            }
            return Value{ .string = "base64encoded" };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "base64Decode") and args.len > 0 and args[0] == .string) {
            const blob = try ctx.arena.create(types.ObjectInstance);
            blob.* = .{ .class_name = "Blob" };
            try blob.fields.put(ctx.arena, "value", args[0]);
            return Value{ .object = blob };
        }
        if (args.len > 0 and args[0] == .string) return args[0];
        return Value{ .string = "" };
    }

    // Messaging
    if (std.ascii.eqlIgnoreCase(class_name, "Messaging")) {
        if (std.ascii.eqlIgnoreCase(method_name, "sendEmail")) {
            // Return list of SendEmailResult
            const list = try ctx.arena.create(types.ListValue);
            list.* = .{};
            const sr = try ctx.arena.create(types.ObjectInstance);
            sr.* = .{ .class_name = "Messaging.SendEmailResult" };
            try sr.fields.put(ctx.arena, "isSuccess", Value{ .boolean = true });
            try list.items.append(ctx.arena, Value{ .object = sr });
            return Value{ .list = list };
        }
        return .void_val;
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

    // CanTheUser — security permission checks (always return true in tests)
    if (std.ascii.eqlIgnoreCase(class_name, "CanTheUser")) {
        if (std.ascii.eqlIgnoreCase(method_name, "create") or
            std.ascii.eqlIgnoreCase(method_name, "read") or
            std.ascii.eqlIgnoreCase(method_name, "edit") or
            std.ascii.eqlIgnoreCase(method_name, "destroy") or
            std.ascii.eqlIgnoreCase(method_name, "crud") or
            std.ascii.eqlIgnoreCase(method_name, "flsAccessible") or
            std.ascii.eqlIgnoreCase(method_name, "flsUpdatable"))
        {
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "bulkFLSAccessible") or
            std.ascii.eqlIgnoreCase(method_name, "bulkFLSUpdatable") or
            std.ascii.eqlIgnoreCase(method_name, "getFLSForFieldSet"))
        {
            const map = try ctx.arena.create(types.MapValue);
            map.* = .{};
            // If second arg is a set of field names, populate results
            if (args.len >= 2 and args[1] == .set) {
                for (args[1].set.entries.keys()) |field_name| {
                    // Standard fields are accessible, custom fields (__c) are not
                    const accessible = !std.mem.endsWith(u8, field_name, "__c");
                    try map.entries.put(ctx.arena, field_name, Value{ .boolean = accessible });
                }
            }
            return Value{ .map = map };
        }
        return Value{ .boolean = true };
    }

    // OrgShape
    if (std.ascii.eqlIgnoreCase(class_name, "OrgShape")) {
        if (std.ascii.eqlIgnoreCase(method_name, "isPlatformCacheEnabled")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isSandbox")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isAdvancedMultiCurrencyManagement")) return Value{ .boolean = false };
        if (std.ascii.eqlIgnoreCase(method_name, "isMultiCurrencyOrganization")) return Value{ .boolean = false };
        if (std.ascii.eqlIgnoreCase(method_name, "isSeeAllDataTrue")) return Value{ .boolean = false };
        return Value{ .boolean = false };
    }

    // Url.getOrgDomainUrl / Url.getSalesforceBaseUrl
    if (std.ascii.eqlIgnoreCase(class_name, "Url") or std.ascii.eqlIgnoreCase(class_name, "URL")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getOrgDomainUrl") or std.ascii.eqlIgnoreCase(method_name, "getSalesforceBaseUrl")) {
            const obj = try ctx.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Url" };
            try obj.fields.put(ctx.arena, "Host", Value{ .string = "test.salesforce.com" });
            try obj.fields.put(ctx.arena, "Protocol", Value{ .string = "https" });
            return Value{ .object = obj };
        }
        return Value.null_val;
    }

    // AccessType enum
    if (std.ascii.eqlIgnoreCase(class_name, "AccessType")) {
        return Value{ .string = method_name };
    }

    return null;
}

fn createDescribeResult(ctx: *BuiltinContext, obj_name: []const u8) !Value {
    const desc = try ctx.arena.create(types.ObjectInstance);
    desc.* = .{ .class_name = "DescribeSObjectResult" };
    try desc.fields.put(ctx.arena, "name", Value{ .string = obj_name });
    try desc.fields.put(ctx.arena, "isAccessible", Value{ .boolean = true });
    try desc.fields.put(ctx.arena, "isCreateable", Value{ .boolean = true });
    try desc.fields.put(ctx.arena, "isUpdateable", Value{ .boolean = true });
    try desc.fields.put(ctx.arena, "isDeletable", Value{ .boolean = true });
    try desc.fields.put(ctx.arena, "isQueryable", Value{ .boolean = true });
    try desc.fields.put(ctx.arena, "isSearchable", Value{ .boolean = true });

    // Fields map
    const fields_map_obj = try ctx.arena.create(types.ObjectInstance);
    fields_map_obj.* = .{ .class_name = "FieldDescribeMap" };
    // Create a map with common fields
    const fields_kv = try ctx.arena.create(types.MapValue);
    fields_kv.* = .{};
    for ([_][]const u8{ "Id", "Name", "CreatedDate", "LastModifiedDate", "OwnerId", "IsDeleted" }) |field_name| {
        const fdr = try createFieldDescribeResult(ctx, field_name);
        try fields_kv.entries.put(ctx.arena, field_name, fdr);
    }
    try fields_map_obj.fields.put(ctx.arena, "map", Value{ .map = fields_kv });
    try desc.fields.put(ctx.arena, "fields", Value{ .object = fields_map_obj });

    return Value{ .object = desc };
}

fn createFieldDescribeResult(ctx: *BuiltinContext, field_name: []const u8) !Value {
    const fdr = try ctx.arena.create(types.ObjectInstance);
    fdr.* = .{ .class_name = "DescribeFieldResult" };
    try fdr.fields.put(ctx.arena, "name", Value{ .string = field_name });
    try fdr.fields.put(ctx.arena, "isAccessible", Value{ .boolean = true });
    try fdr.fields.put(ctx.arena, "isUpdateable", Value{ .boolean = true });
    try fdr.fields.put(ctx.arena, "isCreateable", Value{ .boolean = true });
    try fdr.fields.put(ctx.arena, "isFilterable", Value{ .boolean = true });
    return Value{ .object = fdr };
}

fn dispatchDatabase(ctx: *BuiltinContext, method_name: []const u8, args: []const Value) !?Value {
    // Database.insert / update / delete / upsert return SaveResult list
    if (std.ascii.eqlIgnoreCase(method_name, "insert") or
        std.ascii.eqlIgnoreCase(method_name, "update") or
        std.ascii.eqlIgnoreCase(method_name, "upsert") or
        std.ascii.eqlIgnoreCase(method_name, "delete"))
    {
        // Return a list of SaveResults matching the input records count
        const list = try ctx.arena.create(types.ListValue);
        list.* = .{};
        const count: usize = if (args.len > 0 and args[0] == .list) args[0].list.items.items.len else 1;
        for (0..count) |_| {
            const sr = try ctx.arena.create(types.ObjectInstance);
            sr.* = .{ .class_name = "Database.SaveResult" };
            try sr.fields.put(ctx.arena, "isSuccess", Value{ .boolean = true });
            try sr.fields.put(ctx.arena, "Id", Value{ .string = "001000000000001" });
            try list.items.append(ctx.arena, Value{ .object = sr });
        }
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
    if (std.ascii.eqlIgnoreCase(method_name, "setSavepoint")) {
        const sp = try ctx.arena.create(types.ObjectInstance);
        sp.* = .{ .class_name = "Database.SavePoint" };
        return Value{ .object = sp };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "rollback")) {
        return .void_val;
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
    // Exception methods
    if (std.ascii.eqlIgnoreCase(method_name, "getMessage")) {
        return obj.fields.get("message") orelse Value{ .string = "" };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getStackTraceString")) {
        return Value{ .string = "" };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getTypeName")) {
        return Value{ .string = obj.class_name };
    }
    // toString() - return the value field if it's a Blob, otherwise class name
    if (std.ascii.eqlIgnoreCase(method_name, "toString")) {
        return obj.fields.get("value") orelse Value{ .string = try utils.coerceToString(Value{ .object = obj }, ctx.arena) };
    }

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
        if (std.ascii.eqlIgnoreCase(method_name, "setStatus") and args.len > 0) {
            try obj.fields.put(ctx.arena, "status", args[0]);
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getStatus")) {
            return obj.fields.get("status") orelse Value{ .string = "OK" };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "setMethod") or
            std.ascii.eqlIgnoreCase(method_name, "setEndpoint") or
            std.ascii.eqlIgnoreCase(method_name, "setHeader") or
            std.ascii.eqlIgnoreCase(method_name, "setTimeout"))
        {
            // Store method and endpoint for later use
            if (std.ascii.eqlIgnoreCase(method_name, "setEndpoint") and args.len > 0) {
                try obj.fields.put(ctx.arena, "endpoint", args[0]);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "setMethod") and args.len > 0) {
                try obj.fields.put(ctx.arena, "method", args[0]);
            }
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
            const type_name = if (obj.fields.get("name")) |n| n.string else "Object";
            // If the type name starts with Map, return a Map
            if (std.ascii.startsWithIgnoreCase(type_name, "Map")) {
                const map = try ctx.arena.create(types.MapValue);
                map.* = .{};
                return Value{ .map = map };
            }
            // If the type name starts with List, return a List
            if (std.ascii.startsWithIgnoreCase(type_name, "List")) {
                const list = try ctx.arena.create(types.ListValue);
                list.* = .{};
                return Value{ .list = list };
            }
            // If the type name starts with Set, return a Set
            if (std.ascii.startsWithIgnoreCase(type_name, "Set")) {
                const set = try ctx.arena.create(types.SetValue);
                set.* = .{};
                return Value{ .set = set };
            }
            const inst = try ctx.arena.create(types.ObjectInstance);
            inst.* = .{ .class_name = type_name };
            return Value{ .object = inst };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getName")) {
            return obj.fields.get("name") orelse Value{ .string = "Object" };
        }
    }

    // Cache.Partition methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Cache.Partition")) {
        const cache_map = if (obj.fields.get("_cache")) |cm| if (cm == .map) cm.map else null else null;
        if (std.ascii.eqlIgnoreCase(method_name, "put") and args.len >= 2) {
            if (cache_map) |cm| {
                const key = try utils.coerceToString(args[0], ctx.arena);
                try cm.entries.put(ctx.arena, key, args[1]);
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "get") and args.len >= 1) {
            if (cache_map) |cm| {
                const key = try utils.coerceToString(args[0], ctx.arena);
                return cm.entries.get(key) orelse Value.null_val;
            }
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "contains") and args.len >= 1) {
            if (cache_map) |cm| {
                const key = try utils.coerceToString(args[0], ctx.arena);
                return Value{ .boolean = cm.entries.contains(key) };
            }
            return Value{ .boolean = false };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "remove") and args.len >= 1) {
            if (cache_map) |cm| {
                const key = try utils.coerceToString(args[0], ctx.arena);
                _ = cm.entries.orderedRemove(key);
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getKeys")) {
            const set = try ctx.arena.create(types.SetValue);
            set.* = .{};
            if (cache_map) |cm| {
                for (cm.entries.keys()) |key| {
                    try set.entries.put(ctx.arena, key, {});
                }
            }
            return Value{ .set = set };
        }
    }

    // Request.getQuiddity
    if (std.ascii.eqlIgnoreCase(method_name, "getQuiddity")) {
        return Value{ .string = "RUNTEST_SYNC" };
    }

    // DescribeSObjectResult methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "DescribeSObjectResult") or
        std.ascii.eqlIgnoreCase(obj.class_name, "Schema.DescribeSObjectResult"))
    {
        if (std.ascii.eqlIgnoreCase(method_name, "isAccessible")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isCreateable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isUpdateable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isDeletable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isQueryable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isSearchable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "getName")) {
            return obj.fields.get("name") orelse Value{ .string = "Object" };
        }
    }

    // FieldDescribeMap methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "FieldDescribeMap")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getMap")) {
            return obj.fields.get("map") orelse blk: {
                const m = try ctx.arena.create(types.MapValue);
                m.* = .{};
                break :blk Value{ .map = m };
            };
        }
    }

    // DescribeFieldResult methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "DescribeFieldResult")) {
        if (std.ascii.eqlIgnoreCase(method_name, "isAccessible")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isUpdateable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isCreateable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "isFilterable")) return Value{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(method_name, "getName")) {
            return obj.fields.get("name") orelse Value{ .string = "" };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getDescribe")) return Value{ .object = obj };
    }

    // SObjectField.getDescribe()
    if (std.ascii.eqlIgnoreCase(method_name, "getDescribe")) {
        if (std.ascii.eqlIgnoreCase(obj.class_name, "SObjectField") or
            std.ascii.eqlIgnoreCase(obj.class_name, "DescribeFieldResult"))
        {
            return Value{ .object = obj };
        }
        // For any object, return a DescribeSObjectResult stub
        const desc = try ctx.arena.create(types.ObjectInstance);
        desc.* = .{ .class_name = "DescribeSObjectResult" };
        try desc.fields.put(ctx.arena, "isAccessible", Value{ .boolean = true });
        try desc.fields.put(ctx.arena, "isCreateable", Value{ .boolean = true });
        try desc.fields.put(ctx.arena, "isUpdateable", Value{ .boolean = true });
        try desc.fields.put(ctx.arena, "isDeletable", Value{ .boolean = true });
        return Value{ .object = desc };
    }

    // Schema.SObjectType methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "Schema.SObjectType")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getDescribe")) {
            const name = if (obj.fields.get("name")) |n| n.string else "Object";
            return try createDescribeResult(ctx, name);
        }
        if (std.ascii.eqlIgnoreCase(method_name, "newSObject")) {
            const name = if (obj.fields.get("name")) |n| n.string else "SObject";
            const new_sob = try ctx.arena.create(types.SObject);
            new_sob.* = .{ .type_name = name };
            return Value{ .sobject = new_sob };
        }
    }

    // SObjectAccessDecision methods
    if (std.ascii.eqlIgnoreCase(obj.class_name, "SObjectAccessDecision")) {
        if (std.ascii.eqlIgnoreCase(method_name, "getRecords")) {
            return obj.fields.get("records") orelse blk: {
                const list = try ctx.arena.create(types.ListValue);
                list.* = .{};
                break :blk Value{ .list = list };
            };
        }
        if (std.ascii.eqlIgnoreCase(method_name, "getRemovedFields")) {
            return obj.fields.get("removedFields") orelse blk: {
                const m = try ctx.arena.create(types.MapValue);
                m.* = .{};
                break :blk Value{ .map = m };
            };
        }
    }

    // Generic getter pattern (case-insensitive field lookup)
    if (std.mem.startsWith(u8, method_name, "get") and method_name.len > 3) {
        const field = method_name[3..];
        // Try exact match first, then case-insensitive
        if (obj.fields.get(field)) |v| return v;
        for (obj.fields.keys(), obj.fields.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, field)) return v;
        }
        return Value.null_val;
    }
    if (std.mem.startsWith(u8, method_name, "is") and method_name.len > 2) {
        const field = method_name;
        if (obj.fields.get(field)) |v| return v;
        for (obj.fields.keys(), obj.fields.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, field)) return v;
        }
        return Value{ .boolean = false };
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
        // Return a Schema.SObjectType object that supports getDescribe()
        const sot = try ctx.arena.create(types.ObjectInstance);
        sot.* = .{ .class_name = "Schema.SObjectType" };
        try sot.fields.put(ctx.arena, "name", Value{ .string = sob.type_name });
        return Value{ .object = sot };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getDescribe")) {
        return try createDescribeResult(ctx, sob.type_name);
    }
    // clone / deepClone
    if (std.ascii.eqlIgnoreCase(method_name, "clone") or std.ascii.eqlIgnoreCase(method_name, "deepClone")) {
        const new_sob = try ctx.arena.create(types.SObject);
        new_sob.* = .{ .type_name = sob.type_name };
        for (sob.fields.keys(), sob.fields.values()) |k, v| {
            try new_sob.fields.put(ctx.arena, k, v);
        }
        // Deep clone preserves id; clone with no args may not
        if (std.ascii.eqlIgnoreCase(method_name, "clone")) {
            // clone(preserveId, isDeepClone, preserveReadonlyTimestamps, preserveAutonumber)
            const preserve_id = if (args.len > 0 and args[0] == .boolean) args[0].boolean else false;
            if (!preserve_id) {
                _ = new_sob.fields.orderedRemove("Id");
                new_sob.id = null;
            } else {
                new_sob.id = sob.id;
            }
        } else {
            new_sob.id = sob.id;
        }
        return Value{ .sobject = new_sob };
    }
    // addError
    if (std.ascii.eqlIgnoreCase(method_name, "addError")) {
        return .void_val;
    }
    if (std.ascii.eqlIgnoreCase(method_name, "getSObjects") and args.len > 0 and args[0] == .string) {
        return sob.fields.get(args[0].string) orelse blk: {
            const list = try ctx.arena.create(types.ListValue);
            list.* = .{};
            break :blk Value{ .list = list };
        };
    }
    if (std.ascii.eqlIgnoreCase(method_name, "get") and args.len > 0 and args[0] == .string) {
        // Case-insensitive field lookup
        for (sob.fields.keys(), sob.fields.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, args[0].string)) return v;
        }
        return Value.null_val;
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
