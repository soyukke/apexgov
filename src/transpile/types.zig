//! types — トランスパイラーの共有データ型。
//!
//! `Options` (トランスパイルオプション)、クラス情報、メソッド情報など、
//! トランスパイルパイプライン全体で共有される構造体を定義する。

const std = @import("std");

pub const Options = struct {
    input_paths: []const []const u8,
    out_dir: []const u8,
    package_name: []const u8 = "generated",
    overwrite: bool = false,
    strict: bool = false,
};

pub const UnsupportedDiagnostic = struct {
    source_path: []u8,
    method_name: []u8,
    line_no: usize,
    reason: []const u8,
    statement: []u8,
};

pub const Summary = struct {
    files_scanned: usize = 0,
    files_generated: usize = 0,
    methods_generated: usize = 0,
    unsupported_statements: usize = 0,
    unsupported_examples: std.ArrayList(UnsupportedDiagnostic) = .empty,

    pub fn deinit(self: *Summary, gpa: std.mem.Allocator) void {
        for (self.unsupported_examples.items) |entry| {
            gpa.free(entry.source_path);
            gpa.free(entry.method_name);
            gpa.free(entry.statement);
        }
        self.unsupported_examples.deinit(gpa);
    }
};

pub const ApexFile = struct {
    path: []u8,
    content: []u8,
};

pub const ParsedMethod = struct {
    name: []u8,
    java_return_type: []u8,
    java_parameters: []u8,
    is_static: bool,
    is_constructor: bool,
    is_test: bool,
    is_test_setup: bool = false,
    is_test_see_all_data: bool = false,
    body: []u8,
    start_line: usize,
};

pub const ParsedField = struct {
    declaration: []u8,
};

pub const InnerTypeKind = enum {
    class,
    interface,
    enum_type,
};

pub const TopLevelKind = enum {
    class,
    interface,
    enum_type,
};

pub const ParsedClass = struct {
    class_name: []u8,
    source_path: []u8,
    top_level_kind: TopLevelKind = .class,
    class_declaration_suffix: ?[]u8 = null,
    top_level_enum_constants: ?[]u8 = null,
    is_global: bool = false,
    fields: std.ArrayList(ParsedField) = .empty,
    methods: std.ArrayList(ParsedMethod) = .empty,

    pub fn deinit(self: *ParsedClass, gpa: std.mem.Allocator) void {
        gpa.free(self.class_name);
        gpa.free(self.source_path);
        if (self.class_declaration_suffix) |suffix| {
            gpa.free(suffix);
        }
        if (self.top_level_enum_constants) |constants| {
            gpa.free(constants);
        }
        for (self.fields.items) |field| {
            gpa.free(field.declaration);
        }
        self.fields.deinit(gpa);
        for (self.methods.items) |method| {
            gpa.free(method.name);
            gpa.free(method.java_return_type);
            gpa.free(method.java_parameters);
            gpa.free(method.body);
        }
        self.methods.deinit(gpa);
    }
};

pub const MethodSignature = struct {
    name: []u8,
    java_return_type: []u8,
    java_parameters: []u8,
    is_static: bool,
    is_constructor: bool,
};

pub const SwitchMode = enum {
    value,
    typed,
};

pub const ActiveSwitchContext = struct {
    body_depth: i32,
    subject_expr: []u8,
    mode: SwitchMode,
};

pub const UnsupportedLine = struct {
    method_name: []const u8,
    source_line: usize,
    reason: []const u8,
    statement: []u8,
};

pub const RenderedClass = struct {
    java: []u8,
    unsupported_statements: usize,
    unsupported_lines: std.ArrayList(UnsupportedLine) = .empty,

    pub fn deinit(self: *RenderedClass, gpa: std.mem.Allocator) void {
        gpa.free(self.java);
        for (self.unsupported_lines.items) |line| {
            gpa.free(line.statement);
        }
        self.unsupported_lines.deinit(gpa);
    }
};

pub const TriggerEvent = enum {
    before_insert,
    before_update,
    before_delete,
    after_insert,
    after_update,
    after_delete,
    after_undelete,
};

pub const TriggerRegistration = struct {
    source_path: []u8,
    sobject_type: []u8,
    handler_class: []u8,
    events: std.ArrayList(TriggerEvent) = .empty,

    pub fn deinit(self: *TriggerRegistration, gpa: std.mem.Allocator) void {
        gpa.free(self.source_path);
        gpa.free(self.sobject_type);
        gpa.free(self.handler_class);
        self.events.deinit(gpa);
    }
};
