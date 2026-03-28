//! detectors — Governor 制限に関連する操作のパターン検出。
//!
//! ソース行に SOQL (`[SELECT ...`), DML (`insert/update/delete/upsert`),
//! SOSL, HTTP Callout, Messaging, JSON 操作, clone, コレクション生成,
//! 文字列連結などの Governor 制限消費パターンが含まれるか判定する。

const std = @import("std");
const utils = @import("utils.zig");

const indexOfCaseInsensitive = utils.indexOfCaseInsensitive;
const containsAnyCaseInsensitive = utils.containsAnyCaseInsensitive;
const startsWithIgnoreCase = utils.startsWithIgnoreCase;
const extractLastIdentifier = utils.extractLastIdentifier;
const equalsCanonicalType = utils.equalsCanonicalType;

pub fn containsSoql(line: []const u8) bool {
    const needles = [_][]const u8{
        "[select ",
        "database.query(",
        "database.querywithbinds(",
        "database.countquery(",
        "database.getquerylocator(",
    };
    return containsAnyCaseInsensitive(line, &needles);
}

pub fn containsDml(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (startsWithIgnoreCase(trimmed, "insert ") or
        startsWithIgnoreCase(trimmed, "update ") or
        startsWithIgnoreCase(trimmed, "upsert ") or
        startsWithIgnoreCase(trimmed, "delete ") or
        startsWithIgnoreCase(trimmed, "undelete ") or
        startsWithIgnoreCase(trimmed, "merge "))
    {
        return true;
    }

    const db_dml_calls = [_][]const u8{
        "database.insert(",
        "database.update(",
        "database.upsert(",
        "database.delete(",
        "database.undelete(",
        "database.merge(",
        "database.emptyrecyclebin(",
        "database.convertlead(",
    };
    return containsAnyCaseInsensitive(line, &db_dml_calls);
}

pub fn containsSosl(line: []const u8) bool {
    const needles = [_][]const u8{
        "[find ",
        "search.query(",
    };
    return containsAnyCaseInsensitive(line, &needles);
}

pub fn containsCallout(line: []const u8, type_env: *std.StringHashMap([]const u8)) bool {
    const direct_needles = [_][]const u8{
        "http.send(",
        "webservicecallout.invoke(",
        "continuation.addhttprequest(",
    };
    if (containsAnyCaseInsensitive(line, &direct_needles)) return true;

    const send_idx = indexOfCaseInsensitive(line, ".send(") orelse return false;
    const receiver = extractLastIdentifier(std.mem.trimRight(u8, line[0..send_idx], " \t")) orelse return false;
    const bound_type = type_env.get(receiver) orelse return false;
    return equalsCanonicalType(bound_type, "Http");
}

pub fn containsMessaging(line: []const u8) bool {
    const needles = [_][]const u8{
        "messaging.sendemail(",
        "messaging.sendemailmessage(",
        "messaging.sendnotification(",
    };
    return containsAnyCaseInsensitive(line, &needles);
}

pub fn containsJsonWork(line: []const u8) bool {
    const needles = [_][]const u8{
        "json.serialize(",
        "json.serializepretty(",
        "json.deserialize(",
        "json.deserializeuntyped(",
        "json.deserializestrict(",
        "json.createparser(",
        "json.creategenerator(",
    };
    return containsAnyCaseInsensitive(line, &needles);
}

pub fn containsCloneWork(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ".clone(") != null or
        std.mem.indexOf(u8, line, ".deepClone(") != null;
}

pub fn containsCollectionAlloc(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "new List<") != null or
        std.mem.indexOf(u8, line, "new Map<") != null or
        std.mem.indexOf(u8, line, "new Set<") != null;
}

pub fn containsStringAppend(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "+=") != null and
        (std.mem.indexOf(u8, line, "\"") != null or
            std.mem.indexOf(u8, line, "String") != null);
}
