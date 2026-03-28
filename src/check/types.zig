const std = @import("std");
const utils = @import("utils.zig");

const satAdd = utils.satAdd;
const satMul = utils.satMul;

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
        self.soql = satAdd(self.soql, other.soql);
        self.dml = satAdd(self.dml, other.dml);
        self.sosl = satAdd(self.sosl, other.sosl);
        self.callout = satAdd(self.callout, other.callout);
        self.messaging = satAdd(self.messaging, other.messaging);
        self.json = satAdd(self.json, other.json);
        self.clone = satAdd(self.clone, other.clone);
        self.collection_alloc = satAdd(self.collection_alloc, other.collection_alloc);
        self.string_append = satAdd(self.string_append, other.string_append);
    }

    pub fn addScaled(self: *MethodMetrics, other: MethodMetrics, multiplier: u64) void {
        self.soql = satAdd(self.soql, satMul(other.soql, multiplier));
        self.dml = satAdd(self.dml, satMul(other.dml, multiplier));
        self.sosl = satAdd(self.sosl, satMul(other.sosl, multiplier));
        self.callout = satAdd(self.callout, satMul(other.callout, multiplier));
        self.messaging = satAdd(self.messaging, satMul(other.messaging, multiplier));
        self.json = satAdd(self.json, satMul(other.json, multiplier));
        self.clone = satAdd(self.clone, satMul(other.clone, multiplier));
        self.collection_alloc = satAdd(self.collection_alloc, satMul(other.collection_alloc, multiplier));
        self.string_append = satAdd(self.string_append, satMul(other.string_append, multiplier));
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
    calls: std.ArrayListUnmanaged(MethodCall) = .{},
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
};
