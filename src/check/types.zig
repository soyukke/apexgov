//! types — 静的解析で共有されるデータ型定義。
//!
//! ループスコープ (`LoopScope`, `LoopInfo`)、メソッド解析 (`MethodSummary`,
//! `MethodDecl`, `MethodScope`)、型追跡 (`TypeBinding`, `TypeDecl`,
//! `TypeRelations`)、バウンド推論 (`Bound`, `BoundUpdate`) など、
//! 解析パイプライン全体で参照される構造体・列挙型を集約する。

const std = @import("std");
const utils = @import("utils.zig");

const sat_add = utils.sat_add;
const sat_mul = utils.sat_mul;

pub const BoundOrigin = enum {
    unknown,
    literal,
    guard,
    query_limit,
    alias,
    trigger_batch,
};

pub const Bound = struct {
    max: ?u64,
    origin: BoundOrigin,
};

pub const LoopScope = struct {
    end_depth: i32,
    max_iterations: ?u64,
};

pub const LoopInfo = struct {
    max_iterations: ?u64,
};

pub const PendingLoopScopeStart = struct {
    expected_depth: i32,
    max_iterations: ?u64,
};

pub const DoLoopStart = struct {
    start_line: usize,
    end_depth: i32,
};

pub const BoundUpdate = struct {
    name: []const u8,
    max: ?u64,
    origin: BoundOrigin,
};

pub const MethodMetrics = struct {
    soql: u64 = 0,
    dml: u64 = 0,
    sosl: u64 = 0,
    callout: u64 = 0,
    messaging: u64 = 0,
    json: u64 = 0,
    clone: u64 = 0,
    collection_alloc: u64 = 0,
    string_append: u64 = 0,

    pub fn add(self: *MethodMetrics, other: MethodMetrics) void {
        self.soql = sat_add(self.soql, other.soql);
        self.dml = sat_add(self.dml, other.dml);
        self.sosl = sat_add(self.sosl, other.sosl);
        self.callout = sat_add(self.callout, other.callout);
        self.messaging = sat_add(self.messaging, other.messaging);
        self.json = sat_add(self.json, other.json);
        self.clone = sat_add(self.clone, other.clone);
        self.collection_alloc = sat_add(self.collection_alloc, other.collection_alloc);
        self.string_append = sat_add(self.string_append, other.string_append);
    }

    pub fn add_scaled(self: *MethodMetrics, other: MethodMetrics, multiplier: u64) void {
        self.soql = sat_add(self.soql, sat_mul(other.soql, multiplier));
        self.dml = sat_add(self.dml, sat_mul(other.dml, multiplier));
        self.sosl = sat_add(self.sosl, sat_mul(other.sosl, multiplier));
        self.callout = sat_add(self.callout, sat_mul(other.callout, multiplier));
        self.messaging = sat_add(self.messaging, sat_mul(other.messaging, multiplier));
        self.json = sat_add(self.json, sat_mul(other.json, multiplier));
        self.clone = sat_add(self.clone, sat_mul(other.clone, multiplier));
        self.collection_alloc = sat_add(self.collection_alloc, sat_mul(other.collection_alloc, multiplier));
        self.string_append = sat_add(self.string_append, sat_mul(other.string_append, multiplier));
    }
};

pub const ResolveState = enum {
    unresolved,
    resolving,
    resolved,
};

pub const MethodCall = struct {
    callee_key: []const u8,
    multiplier: u64,
};

pub const MethodSummary = struct {
    owner: []const u8,
    name: []const u8,
    param_count: u16,
    param_signature: []const u8,
    direct: MethodMetrics = .{},
    total: MethodMetrics = .{},
    calls: std.ArrayListUnmanaged(MethodCall) = .empty,
    state: ResolveState = .unresolved,
};

pub const MethodScope = struct {
    owner: []const u8,
    name: []const u8,
    param_count: u16,
    param_signature: []const u8,
    end_depth: i32,
    entered_body: bool,
};

pub const MethodDecl = struct {
    name: []const u8,
    param_count: u16,
    params_raw: []const u8,
};

pub const TypeBinding = struct {
    name: []const u8,
    type_raw: []const u8,
};

pub const OwnerScope = struct {
    name: []const u8,
    end_depth: i32,
};

pub const TypeRelations = struct {
    extends_by_type: std.StringHashMap([]const u8),
    interfaces_by_type: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
};

pub const TypeDecl = struct {
    name: []const u8,
    extends_name: ?[]const u8,
    implements_raw: []const u8,
};

pub const ApexFile = struct {
    path: []const u8,
    content: []const u8,
    stripped_content: []const u8 = "",
};

pub const MethodIndexEntry = struct {
    key: []const u8,
    summary: *MethodSummary,
};

pub const MethodNameIndex = std.StringHashMap(std.ArrayListUnmanaged(MethodIndexEntry));
