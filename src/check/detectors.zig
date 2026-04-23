//! detectors — Governor 制限に関連する操作のパターン検出。
//!
//! ソース行に SOQL (`[SELECT ...`), DML (`insert/update/delete/upsert`),
//! SOSL, HTTP Callout, Messaging, JSON 操作, clone, コレクション生成,
//! 文字列連結などの Governor 制限消費パターンが含まれるか判定する。

const std = @import("std");
const utils = @import("utils.zig");

const index_of_case_insensitive = utils.index_of_case_insensitive;
const contains_any_case_insensitive = utils.contains_any_case_insensitive;
const starts_with_ignore_case = utils.starts_with_ignore_case;
const extract_last_identifier = utils.extract_last_identifier;
const equals_canonical_type = utils.equals_canonical_type;

pub fn contains_soql(line: []const u8) bool {
    const needles = [_][]const u8{
        "[select ",
        "database.query(",
        "database.querywithbinds(",
        "database.countquery(",
        "database.getquerylocator(",
    };
    return contains_any_case_insensitive(line, &needles);
}

pub fn contains_dml(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (starts_with_ignore_case(trimmed, "insert ") or
        starts_with_ignore_case(trimmed, "update ") or
        starts_with_ignore_case(trimmed, "upsert ") or
        starts_with_ignore_case(trimmed, "delete ") or
        starts_with_ignore_case(trimmed, "undelete ") or
        starts_with_ignore_case(trimmed, "merge "))
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
    return contains_any_case_insensitive(line, &db_dml_calls);
}

pub fn contains_sosl(line: []const u8) bool {
    const needles = [_][]const u8{
        "[find ",
        "search.query(",
    };
    return contains_any_case_insensitive(line, &needles);
}

pub fn contains_callout(line: []const u8, type_env: *std.StringHashMap([]const u8)) bool {
    const direct_needles = [_][]const u8{
        "http.send(",
        "webservicecallout.invoke(",
        "continuation.addhttprequest(",
    };
    if (contains_any_case_insensitive(line, &direct_needles)) return true;

    const send_idx = index_of_case_insensitive(line, ".send(") orelse return false;
    const receiver = extract_last_identifier(std.mem.trimEnd(u8, line[0..send_idx], " \t")) orelse return false;
    const bound_type = type_env.get(receiver) orelse return false;
    return equals_canonical_type(bound_type, "Http");
}

pub fn contains_messaging(line: []const u8) bool {
    const needles = [_][]const u8{
        "messaging.sendemail(",
        "messaging.sendemailmessage(",
        "messaging.sendnotification(",
    };
    return contains_any_case_insensitive(line, &needles);
}

pub fn contains_json_work(line: []const u8) bool {
    const needles = [_][]const u8{
        "json.serialize(",
        "json.serializepretty(",
        "json.deserialize(",
        "json.deserializeuntyped(",
        "json.deserializestrict(",
        "json.createparser(",
        "json.creategenerator(",
    };
    return contains_any_case_insensitive(line, &needles);
}

pub fn contains_clone_work(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ".clone(") != null or
        std.mem.indexOf(u8, line, ".deepClone(") != null;
}

pub fn contains_collection_alloc(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "new List<") != null or
        std.mem.indexOf(u8, line, "new Map<") != null or
        std.mem.indexOf(u8, line, "new Set<") != null;
}

pub fn contains_string_append(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "+=") != null and
        (std.mem.indexOf(u8, line, "\"") != null or
            std.mem.indexOf(u8, line, "String") != null);
}
