//! apex_stdlib — Apex 標準ライブラリの型・メソッド定義。
//!
//! String, List, Map, Set, Database, System 等の
//! メソッドシグネチャを提供する。ドット補完で使用。

const std = @import("std");

pub const MemberInfo = struct {
    name: []const u8,
    kind: MemberKind,
    return_type: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const MemberKind = enum {
    method,
    field,
};

pub const TypeDef = struct {
    name: []const u8,
    members: []const MemberInfo,
};

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

const string_members = [_]MemberInfo{
    .{ .name = "length", .kind = .method, .return_type = "Integer", .detail = "Integer length()" },
    .{ .name = "substring", .kind = .method, .return_type = "String", .detail = "String substring(Integer start)" },
    .{ .name = "toLowerCase", .kind = .method, .return_type = "String", .detail = "String toLowerCase()" },
    .{ .name = "toUpperCase", .kind = .method, .return_type = "String", .detail = "String toUpperCase()" },
    .{ .name = "trim", .kind = .method, .return_type = "String", .detail = "String trim()" },
    .{ .name = "contains", .kind = .method, .return_type = "Boolean", .detail = "Boolean contains(String str)" },
    .{ .name = "startsWith", .kind = .method, .return_type = "Boolean", .detail = "Boolean startsWith(String prefix)" },
    .{ .name = "endsWith", .kind = .method, .return_type = "Boolean", .detail = "Boolean endsWith(String suffix)" },
    .{ .name = "indexOf", .kind = .method, .return_type = "Integer", .detail = "Integer indexOf(String str)" },
    .{ .name = "replace", .kind = .method, .return_type = "String", .detail = "String replace(String target, String replacement)" },
    .{ .name = "split", .kind = .method, .return_type = "List", .detail = "List<String> split(String regex)" },
    .{ .name = "equals", .kind = .method, .return_type = "Boolean", .detail = "Boolean equals(Object obj)" },
    .{ .name = "equalsIgnoreCase", .kind = .method, .return_type = "Boolean", .detail = "Boolean equalsIgnoreCase(String str)" },
    .{ .name = "isBlank", .kind = .method, .return_type = "Boolean", .detail = "Boolean isBlank()" },
    .{ .name = "isEmpty", .kind = .method, .return_type = "Boolean", .detail = "Boolean isEmpty()" },
    .{ .name = "isNotBlank", .kind = .method, .return_type = "Boolean", .detail = "Boolean isNotBlank()" },
    .{ .name = "abbreviate", .kind = .method, .return_type = "String", .detail = "String abbreviate(Integer maxWidth)" },
    .{ .name = "capitalizeFirstLetter", .kind = .method, .return_type = "String", .detail = "String capitalizeFirstLetter()" },
    .{ .name = "charAt", .kind = .method, .return_type = "Integer", .detail = "Integer charAt(Integer index)" },
    .{ .name = "compareTo", .kind = .method, .return_type = "Integer", .detail = "Integer compareTo(String str)" },
    .{ .name = "left", .kind = .method, .return_type = "String", .detail = "String left(Integer len)" },
    .{ .name = "right", .kind = .method, .return_type = "String", .detail = "String right(Integer len)" },
    .{ .name = "removeEnd", .kind = .method, .return_type = "String", .detail = "String removeEnd(String suffix)" },
    .{ .name = "removeStart", .kind = .method, .return_type = "String", .detail = "String removeStart(String prefix)" },
};

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

const list_members = [_]MemberInfo{
    .{ .name = "add", .kind = .method, .return_type = null, .detail = "void add(Object element)" },
    .{ .name = "addAll", .kind = .method, .return_type = null, .detail = "void addAll(List<Object> elements)" },
    .{ .name = "clear", .kind = .method, .return_type = null, .detail = "void clear()" },
    .{ .name = "clone", .kind = .method, .return_type = "List", .detail = "List<Object> clone()" },
    .{ .name = "contains", .kind = .method, .return_type = "Boolean", .detail = "Boolean contains(Object element)" },
    .{ .name = "get", .kind = .method, .return_type = null, .detail = "Object get(Integer index)" },
    .{ .name = "indexOf", .kind = .method, .return_type = "Integer", .detail = "Integer indexOf(Object element)" },
    .{ .name = "isEmpty", .kind = .method, .return_type = "Boolean", .detail = "Boolean isEmpty()" },
    .{ .name = "remove", .kind = .method, .return_type = null, .detail = "Object remove(Integer index)" },
    .{ .name = "set", .kind = .method, .return_type = null, .detail = "void set(Integer index, Object element)" },
    .{ .name = "size", .kind = .method, .return_type = "Integer", .detail = "Integer size()" },
    .{ .name = "sort", .kind = .method, .return_type = null, .detail = "void sort()" },
};

// ---------------------------------------------------------------------------
// Map
// ---------------------------------------------------------------------------

const map_members = [_]MemberInfo{
    .{ .name = "clear", .kind = .method, .return_type = null, .detail = "void clear()" },
    .{ .name = "clone", .kind = .method, .return_type = "Map", .detail = "Map<K,V> clone()" },
    .{ .name = "containsKey", .kind = .method, .return_type = "Boolean", .detail = "Boolean containsKey(Object key)" },
    .{ .name = "get", .kind = .method, .return_type = null, .detail = "V get(Object key)" },
    .{ .name = "isEmpty", .kind = .method, .return_type = "Boolean", .detail = "Boolean isEmpty()" },
    .{ .name = "keySet", .kind = .method, .return_type = "Set", .detail = "Set<K> keySet()" },
    .{ .name = "put", .kind = .method, .return_type = null, .detail = "V put(K key, V value)" },
    .{ .name = "putAll", .kind = .method, .return_type = null, .detail = "void putAll(Map<K,V> m)" },
    .{ .name = "remove", .kind = .method, .return_type = null, .detail = "V remove(Object key)" },
    .{ .name = "size", .kind = .method, .return_type = "Integer", .detail = "Integer size()" },
    .{ .name = "values", .kind = .method, .return_type = "List", .detail = "List<V> values()" },
};

// ---------------------------------------------------------------------------
// Set
// ---------------------------------------------------------------------------

const set_members = [_]MemberInfo{
    .{ .name = "add", .kind = .method, .return_type = "Boolean", .detail = "Boolean add(Object element)" },
    .{ .name = "addAll", .kind = .method, .return_type = "Boolean", .detail = "Boolean addAll(Set<Object> elements)" },
    .{ .name = "clear", .kind = .method, .return_type = null, .detail = "void clear()" },
    .{ .name = "clone", .kind = .method, .return_type = "Set", .detail = "Set<Object> clone()" },
    .{ .name = "contains", .kind = .method, .return_type = "Boolean", .detail = "Boolean contains(Object element)" },
    .{ .name = "isEmpty", .kind = .method, .return_type = "Boolean", .detail = "Boolean isEmpty()" },
    .{ .name = "remove", .kind = .method, .return_type = "Boolean", .detail = "Boolean remove(Object element)" },
    .{ .name = "size", .kind = .method, .return_type = "Integer", .detail = "Integer size()" },
};

// ---------------------------------------------------------------------------
// System
// ---------------------------------------------------------------------------

const system_members = [_]MemberInfo{
    .{ .name = "debug", .kind = .method, .return_type = null, .detail = "void debug(Object msg)" },
    .{ .name = "assertEquals", .kind = .method, .return_type = null, .detail = "void assertEquals(Object expected, Object actual)" },
    .{ .name = "assertNotEquals", .kind = .method, .return_type = null, .detail = "void assertNotEquals(Object expected, Object actual)" },
    .{ .name = "assert", .kind = .method, .return_type = null, .detail = "void assert(Boolean condition)" },
    .{ .name = "currentTimeMillis", .kind = .method, .return_type = "Long", .detail = "Long currentTimeMillis()" },
    .{ .name = "now", .kind = .method, .return_type = "Datetime", .detail = "Datetime now()" },
    .{ .name = "today", .kind = .method, .return_type = "Date", .detail = "Date today()" },
    .{ .name = "runAs", .kind = .method, .return_type = null, .detail = "void runAs(User u)" },
};

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

const database_members = [_]MemberInfo{
    .{ .name = "insert", .kind = .method, .return_type = null, .detail = "Database.SaveResult[] insert(List<SObject> records)" },
    .{ .name = "update", .kind = .method, .return_type = null, .detail = "Database.SaveResult[] update(List<SObject> records)" },
    .{ .name = "delete", .kind = .method, .return_type = null, .detail = "Database.DeleteResult[] delete(List<SObject> records)" },
    .{ .name = "upsert", .kind = .method, .return_type = null, .detail = "Database.UpsertResult[] upsert(List<SObject> records)" },
    .{ .name = "query", .kind = .method, .return_type = "List", .detail = "List<SObject> query(String queryString)" },
    .{ .name = "countQuery", .kind = .method, .return_type = "Integer", .detail = "Integer countQuery(String queryString)" },
    .{ .name = "executeBatch", .kind = .method, .return_type = "Id", .detail = "Id executeBatch(Database.Batchable job)" },
    .{ .name = "getQueryLocator", .kind = .method, .return_type = null, .detail = "Database.QueryLocator getQueryLocator(String query)" },
    .{ .name = "setSavepoint", .kind = .method, .return_type = null, .detail = "Savepoint setSavepoint()" },
    .{ .name = "rollback", .kind = .method, .return_type = null, .detail = "void rollback(Savepoint sp)" },
};

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

const limits_members = [_]MemberInfo{
    .{ .name = "getDMLRows", .kind = .method, .return_type = "Integer", .detail = "Integer getDMLRows()" },
    .{ .name = "getDMLStatements", .kind = .method, .return_type = "Integer", .detail = "Integer getDMLStatements()" },
    .{ .name = "getLimitDMLRows", .kind = .method, .return_type = "Integer", .detail = "Integer getLimitDMLRows()" },
    .{ .name = "getLimitDMLStatements", .kind = .method, .return_type = "Integer", .detail = "Integer getLimitDMLStatements()" },
    .{ .name = "getQueries", .kind = .method, .return_type = "Integer", .detail = "Integer getQueries()" },
    .{ .name = "getLimitQueries", .kind = .method, .return_type = "Integer", .detail = "Integer getLimitQueries()" },
    .{ .name = "getCpuTime", .kind = .method, .return_type = "Integer", .detail = "Integer getCpuTime()" },
    .{ .name = "getLimitCpuTime", .kind = .method, .return_type = "Integer", .detail = "Integer getLimitCpuTime()" },
    .{ .name = "getHeapSize", .kind = .method, .return_type = "Integer", .detail = "Integer getHeapSize()" },
    .{ .name = "getLimitHeapSize", .kind = .method, .return_type = "Integer", .detail = "Integer getLimitHeapSize()" },
};

// ---------------------------------------------------------------------------
// カタログ
// ---------------------------------------------------------------------------

const all_types = [_]TypeDef{
    .{ .name = "String", .members = &string_members },
    .{ .name = "List", .members = &list_members },
    .{ .name = "Map", .members = &map_members },
    .{ .name = "Set", .members = &set_members },
    .{ .name = "System", .members = &system_members },
    .{ .name = "Database", .members = &database_members },
    .{ .name = "Limits", .members = &limits_members },
};

/// 型名からメンバー一覧を取得する。
pub fn get_members(type_name: []const u8) ?[]const MemberInfo {
    for (&all_types) |td| {
        if (std.ascii.eqlIgnoreCase(td.name, type_name)) {
            return td.members;
        }
    }
    return null;
}

/// 型名が Apex 標準ライブラリ型かどうか。
pub fn is_stdlib_type(type_name: []const u8) bool {
    return get_members(type_name) != null;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "String has length method" {
    const members = get_members("String");
    try std.testing.expect(members != null);
    var found = false;
    for (members.?) |m| {
        if (std.mem.eql(u8, m.name, "length")) {
            found = true;
            try std.testing.expectEqualStrings("Integer", m.return_type.?);
        }
    }
    try std.testing.expect(found);
}

test "List has add and size" {
    const members = get_members("List");
    try std.testing.expect(members != null);
    var has_add = false;
    var has_size = false;
    for (members.?) |m| {
        if (std.mem.eql(u8, m.name, "add")) has_add = true;
        if (std.mem.eql(u8, m.name, "size")) has_size = true;
    }
    try std.testing.expect(has_add);
    try std.testing.expect(has_size);
}

test "System has debug" {
    const members = get_members("System");
    try std.testing.expect(members != null);
    var found = false;
    for (members.?) |m| {
        if (std.mem.eql(u8, m.name, "debug")) found = true;
    }
    try std.testing.expect(found);
}

test "Database has query" {
    const members = get_members("Database");
    try std.testing.expect(members != null);
    var found = false;
    for (members.?) |m| {
        if (std.mem.eql(u8, m.name, "query")) found = true;
    }
    try std.testing.expect(found);
}

test "case-insensitive lookup" {
    try std.testing.expect(get_members("string") != null);
    try std.testing.expect(get_members("STRING") != null);
}

test "unknown type returns null" {
    try std.testing.expect(get_members("FooBar") == null);
}

test "is_stdlib_type" {
    try std.testing.expect(is_stdlib_type("String"));
    try std.testing.expect(is_stdlib_type("List"));
    try std.testing.expect(!is_stdlib_type("Account"));
}
