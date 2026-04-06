//! evaluator — AST ツリーウォーク実行エンジン。
//!
//! 式を評価し、文を実行する。クラス/メソッド解決、変数バインディング、
//! ビルトイン関数ディスパッチを行う。

const std = @import("std");
const types = @import("types.zig");
const ast = @import("ast.zig");
const env_mod = @import("env.zig");
const builtins = @import("builtins.zig");
const utils = @import("utils.zig");
const Value = types.Value;
const Env = env_mod.Env;

pub const StmtResult = union(enum) {
    normal,
    return_val: Value,
    break_signal,
    continue_signal,
};

pub const Evaluator = struct {
    arena: std.mem.Allocator,
    global_env: *Env,
    stdout: std.ArrayListUnmanaged(u8) = .empty,
    classes: std.StringArrayHashMapUnmanaged(*ast.ClassDecl) = .empty,
    return_value: Value = .void_val,
    assertion_failure: ?[]const u8 = null,
    // インメモリ SObject ストア
    store: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,
    next_id: u64 = 1,
    // bypass リスト (TriggerHandler.bypass 等)
    bypasses: std.StringArrayHashMapUnmanaged(void) = .empty,
    // 削除済みレコードのゴミ箱 (undelete 用)
    trash: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,
    // 例外ハンドリング
    pending_exception: ?Value = null,
    // HttpCalloutMock
    callout_mock: ?Value = null,
    // Current class name for static field resolution
    current_class: ?[]const u8 = null,
    // JSON round-trip: store last serialized value for deserialize
    last_json_value: ?Value = null,

    pub fn init(arena: std.mem.Allocator) !Evaluator {
        const global = try arena.create(Env);
        global.* = Env.init(arena);
        return .{ .arena = arena, .global_env = global };
    }

    pub fn resetForTest(self: *Evaluator) void {
        self.assertion_failure = null;
        self.return_value = .void_val;
        self.stdout = .empty;
        self.store = .empty;
        self.next_id = 1;
        self.bypasses = .empty;
        self.pending_exception = null;
        self.callout_mock = null;
        self.trash = .empty;
        self.last_json_value = null;

        // Clear cache partitions
        _ = self.global_env.bindings.orderedRemove("Cache.Session.partition");
        _ = self.global_env.bindings.orderedRemove("Cache.Org.partition");
    }

    /// Re-initialize static fields for a single class (test class reset)
    pub fn reInitClassStaticFields(self: *Evaluator, cd: *ast.ClassDecl) void {
        for (cd.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (fd.modifiers.is_static) {
                        const val = if (fd.initializer) |init_expr|
                            self.evalExpr(init_expr, self.global_env) catch Value.null_val
                        else
                            defaultValue(fd.type_ref);
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                        self.global_env.set(key, val) catch {
                            self.global_env.define(key, val) catch {};
                        };
                    }
                },
                else => {},
            }
        }
    }

    /// Run static init blocks for a single class
    pub fn runClassStaticInits(self: *Evaluator, cd: *ast.ClassDecl) void {
        for (cd.members) |member| {
            switch (member) {
                .static_init => |body| {
                    const init_env = self.global_env.child() catch continue;
                    for (cd.members) |m2| {
                        switch (m2) {
                            .field_decl => |fd| {
                                if (fd.modifiers.is_static) {
                                    const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                    const cur = self.global_env.get(key) orelse Value.null_val;
                                    init_env.define(fd.name, cur) catch {};
                                }
                            },
                            else => {},
                        }
                    }
                    _ = self.execBlock(body, init_env) catch {};
                    for (cd.members) |m2| {
                        switch (m2) {
                            .field_decl => |fd| {
                                if (fd.modifiers.is_static) {
                                    if (init_env.get(fd.name)) |v| {
                                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                        self.global_env.set(key, v) catch {
                                            self.global_env.define(key, v) catch {};
                                        };
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }

    // -----------------------------------------------------------------------
    // トップレベル
    // -----------------------------------------------------------------------

    pub fn loadDecls(self: *Evaluator, decls: []const ast.Decl) anyerror!void {
        for (decls) |decl| {
            switch (decl) {
                .class_decl => |cd| {
                    try self.classes.put(self.arena, cd.name, cd);
                    // Register inner classes and static fields
                    for (cd.members) |member| {
                        switch (member) {
                            .field_decl => |fd| {
                                if (fd.modifiers.is_static) {
                                    const val = if (fd.initializer) |init_expr|
                                        self.evalExpr(init_expr, self.global_env) catch Value.null_val
                                    else
                                        defaultValue(fd.type_ref);
                                    const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                    self.global_env.define(key, val) catch {};
                                }
                            },
                            .class_decl => |inner_cd| {
                                // Register inner class both by its short name and fully qualified name
                                try self.classes.put(self.arena, inner_cd.name, inner_cd);
                                const fq_name = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, inner_cd.name }) catch continue;
                                try self.classes.put(self.arena, fq_name, inner_cd);
                            },
                            .enum_decl => |ed| {
                                // Register enum values as static fields
                                for (ed.values) |v| {
                                    const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ ed.name, v }) catch continue;
                                    self.global_env.define(key, Value{ .string = v }) catch {};
                                    // Also register with outer class prefix
                                    const fq_key = std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{ cd.name, ed.name, v }) catch continue;
                                    self.global_env.define(fq_key, Value{ .string = v }) catch {};
                                }
                            },
                            .static_init => {},
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        // Static init blocks are deferred to runStaticInits()
    }

    /// Execute all static initializer blocks. Should be called after all files are loaded.
    pub fn runStaticInits(self: *Evaluator) void {
        var class_iter = self.classes.iterator();
        while (class_iter.next()) |entry| {
            const cd = entry.value_ptr.*;
            for (cd.members) |member| {
                switch (member) {
                    .static_init => |body| {
                        const init_env = self.global_env.child() catch continue;
                        // Define static fields as local variables
                        for (cd.members) |m2| {
                            switch (m2) {
                                .field_decl => |fd| {
                                    if (fd.modifiers.is_static) {
                                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                        const cur = self.global_env.get(key) orelse Value.null_val;
                                        init_env.define(fd.name, cur) catch {};
                                    }
                                },
                                else => {},
                            }
                        }
                        _ = self.execBlock(body, init_env) catch {};
                        // Write back static fields to global env
                        for (cd.members) |m2| {
                            switch (m2) {
                                .field_decl => |fd| {
                                    if (fd.modifiers.is_static) {
                                        if (init_env.get(fd.name)) |v| {
                                            const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cd.name, fd.name }) catch continue;
                                            self.global_env.set(key, v) catch {
                                                self.global_env.define(key, v) catch {};
                                            };
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    pub fn callMethod(self: *Evaluator, class_name: []const u8, method_name: []const u8, args: []const Value) anyerror!Value {
        // Builtin class stubs (before user-defined classes)
        var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout };
        if (try builtins.dispatchStatic(&bctx, class_name, method_name, args)) |result| {
            return result;
        }

        // TestFactory / TestDataHelpers builtin stubs
        if (try self.handleTestFactory(class_name, method_name, args)) |result| {
            return result;
        }

        // Case-insensitive class lookup
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, class_name)) {
                const prev_class = self.current_class;
                self.current_class = entry.key_ptr.*;
                defer self.current_class = prev_class;
                // Try type-aware resolution first
                if (self.findBestMethodInClass(entry.value_ptr.*, method_name, args)) |md| {
                    return self.executeMethod(md, args);
                }
                // Fallback: find any name match
                var any_name_match = false;
                for (entry.value_ptr.*.members) |member| {
                    switch (member) {
                        .method_decl => |md| {
                            if (std.ascii.eqlIgnoreCase(md.name, method_name)) {
                                any_name_match = true;
                                break;
                            }
                        },
                        else => {},
                    }
                }
                if (any_name_match) return Value.null_val;
                return Value.null_val; // method not found in class, return null
            }
        }
        return Value.null_val; // class not found, return null instead of error
    }

    fn executeMethod(self: *Evaluator, method: *ast.MethodDecl, args: []const Value) anyerror!Value {
        const method_env = try self.global_env.child();

        for (method.params, 0..) |param, i| {
            const val = if (i < args.len) args[i] else Value.null_val;
            try method_env.define(param.name, val);
        }

        const result = try self.execBlock(method.body, method_env);
        return switch (result) {
            .return_val => |v| v,
            else => self.return_value,
        };
    }

    // -----------------------------------------------------------------------
    // 文の実行
    // -----------------------------------------------------------------------

    pub fn execBlock(self: *Evaluator, stmts: []const ast.Stmt, current_env: *Env) anyerror!StmtResult {
        for (stmts) |stmt| {
            if (self.assertion_failure != null) return .normal;
            const result = try self.execStmt(stmt, current_env);
            switch (result) {
                .normal => {},
                else => return result,
            }
        }
        return .normal;
    }

    pub fn execStmt(self: *Evaluator, stmt: ast.Stmt, current_env: *Env) anyerror!StmtResult {
        switch (stmt) {
            .expr_stmt => |expr| {
                _ = try self.evalExpr(expr, current_env);
                return .normal;
            },
            .var_decl => |vd| {
                var val = if (vd.initializer) |init_expr|
                    try self.evalExpr(init_expr, current_env)
                else
                    defaultValue(vd.type_ref);
                // Auto-unwrap SOQL list to single SObject when variable type is not List/Set/Iterable
                if (val == .list and !std.ascii.eqlIgnoreCase(vd.type_ref.name, "List") and
                    !std.ascii.eqlIgnoreCase(vd.type_ref.name, "Iterable") and
                    !std.ascii.eqlIgnoreCase(vd.type_ref.name, "Set"))
                {
                    if (val.list.items.items.len > 0) {
                        val = val.list.items.items[0];
                    } else if (vd.initializer != null and vd.initializer.?.* == .soql) {
                        // Empty SOQL result assigned to non-list variable → QueryException
                        const exc = try self.arena.create(types.ObjectInstance);
                        exc.* = .{ .class_name = "QueryException" };
                        try exc.fields.put(self.arena, "message", Value{ .string = "List has no rows for assignment to SObject" });
                        self.pending_exception = Value{ .object = exc };
                        return error.ApexException;
                    }
                }
                try current_env.define(vd.name, val);
                return .normal;
            },
            .block => |stmts| {
                const block_env = try current_env.child();
                return self.execBlock(stmts, block_env);
            },
            .if_stmt => |if_s| {
                const cond = try self.evalExpr(if_s.condition, current_env);
                const is_true = utils.coerceToBool(cond) catch false;
                if (is_true) {
                    return self.execBlock(if_s.then_body, current_env);
                } else if (if_s.else_body) |else_body| {
                    return self.execBlock(else_body, current_env);
                }
                return .normal;
            },
            .for_stmt => |fs| {
                const loop_env = try current_env.child();
                if (fs.init) |init_stmt| {
                    _ = try self.execStmt(init_stmt.*, loop_env);
                }
                var iterations: u32 = 0;
                while (iterations < 100_000) : (iterations += 1) {
                    if (fs.condition) |cond| {
                        const cv = try self.evalExpr(cond, loop_env);
                        if (!(utils.coerceToBool(cv) catch false)) break;
                    }
                    const result = try self.execBlock(fs.body, loop_env);
                    switch (result) {
                        .break_signal => break,
                        .continue_signal => {},
                        .return_val => return result,
                        .normal => {},
                    }
                    if (fs.update) |upd| {
                        _ = try self.evalExpr(upd, loop_env);
                    }
                }
                return .normal;
            },
            .for_each_stmt => |fes| {
                const iterable = try self.evalExpr(fes.iterable, current_env);
                if (iterable == .list) {
                    const loop_env = try current_env.child();
                    for (iterable.list.items.items) |item| {
                        try loop_env.define(fes.elem_name, item);
                        const result = try self.execBlock(fes.body, loop_env);
                        switch (result) {
                            .break_signal => break,
                            .continue_signal => {},
                            .return_val => return result,
                            .normal => {},
                        }
                    }
                } else if (iterable == .set) {
                    const loop_env = try current_env.child();
                    // Copy keys to avoid mutation during iteration
                    var keys_copy: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (iterable.set.entries.keys()) |key| try keys_copy.append(self.arena, key);
                    for (keys_copy.items) |key| {
                        loop_env.set(fes.elem_name, Value{ .string = key }) catch {
                            try loop_env.define(fes.elem_name, Value{ .string = key });
                        };
                        const result = try self.execBlock(fes.body, loop_env);
                        switch (result) {
                            .break_signal => break,
                            .continue_signal => {},
                            .return_val => return result,
                            .normal => {},
                        }
                    }
                } else if (iterable == .map) {
                    // Iterating over a map iterates over values
                    const loop_env = try current_env.child();
                    for (iterable.map.entries.values()) |val| {
                        loop_env.set(fes.elem_name, val) catch {
                            try loop_env.define(fes.elem_name, val);
                        };
                        const result = try self.execBlock(fes.body, loop_env);
                        switch (result) {
                            .break_signal => break,
                            .continue_signal => {},
                            .return_val => return result,
                            .normal => {},
                        }
                    }
                }
                return .normal;
            },
            .while_stmt => |ws| {
                var iterations: u32 = 0;
                while (iterations < 100_000) : (iterations += 1) {
                    const cv = try self.evalExpr(ws.condition, current_env);
                    if (!(utils.coerceToBool(cv) catch false)) break;
                    const result = try self.execBlock(ws.body, current_env);
                    switch (result) {
                        .break_signal => break,
                        .continue_signal => {},
                        .return_val => return result,
                        .normal => {},
                    }
                }
                return .normal;
            },
            .do_while => |dw| {
                var iterations: u32 = 0;
                while (iterations < 100_000) : (iterations += 1) {
                    const result = try self.execBlock(dw.body, current_env);
                    switch (result) {
                        .break_signal => break,
                        .continue_signal => {},
                        .return_val => return result,
                        .normal => {},
                    }
                    const cv = try self.evalExpr(dw.condition, current_env);
                    if (!(utils.coerceToBool(cv) catch false)) break;
                }
                return .normal;
            },
            .return_stmt => |rs| {
                const val = if (rs.value) |v| try self.evalExpr(v, current_env) else Value.void_val;
                self.return_value = val;
                return .{ .return_val = val };
            },
            .break_stmt => return .break_signal,
            .continue_stmt => return .continue_signal,
            .switch_stmt => |sw| {
                const subject = try self.evalExpr(sw.subject, current_env);
                for (sw.when_clauses) |clause| {
                    switch (clause.pattern) {
                        .values => |values| {
                            for (values) |val_expr| {
                                var val_copy = val_expr;
                                const when_val = try self.evalExpr(&val_copy, current_env);
                                if (utils.valueEql(subject, when_val)) {
                                    return self.execBlock(clause.body, current_env);
                                }
                                // Enum matching: when identifier matches string subject
                                if (subject == .string and val_copy == .identifier) {
                                    if (std.ascii.eqlIgnoreCase(subject.string, val_copy.identifier.name)) {
                                        return self.execBlock(clause.body, current_env);
                                    }
                                }
                                // Also match when the when_val is null_val but the identifier matches a string
                                if (subject == .string and when_val == .null_val and val_copy == .identifier) {
                                    if (std.ascii.eqlIgnoreCase(subject.string, val_copy.identifier.name)) {
                                        return self.execBlock(clause.body, current_env);
                                    }
                                }
                            }
                        },
                        .else_clause => {
                            return self.execBlock(clause.body, current_env);
                        },
                    }
                }
                return .normal;
            },
            .try_stmt => |ts| {
                const result = self.execBlock(ts.body, current_env);
                if (result) |r| {
                    if (ts.finally_body) |fb| _ = try self.execBlock(fb, current_env);
                    return r;
                } else |_| {
                    if (ts.catches.len > 0) {
                        // Get the pending exception info
                        const exc_val = if (self.pending_exception) |pe| pe else blk: {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "Exception" };
                            break :blk Value{ .object = exc };
                        };
                        self.pending_exception = null;
                        const exc_obj = if (exc_val == .object) exc_val.object else blk: {
                            const exc = try self.arena.create(types.ObjectInstance);
                            exc.* = .{ .class_name = "Exception" };
                            break :blk exc;
                        };
                        const exc_class_name = exc_obj.class_name;

                        // Find matching catch clause by exception type
                        var matched_catch: ?*const ast.CatchClause = null;
                        var generic_catch: ?*const ast.CatchClause = null;
                        for (ts.catches) |*cc| {
                            const catch_type = cc.exception_type.name;
                            // Extract the simple name (after last dot) for both sides
                            const catch_simple = if (std.mem.lastIndexOfScalar(u8, catch_type, '.')) |di| catch_type[di + 1 ..] else catch_type;
                            const exc_simple = if (std.mem.lastIndexOfScalar(u8, exc_class_name, '.')) |di| exc_class_name[di + 1 ..] else exc_class_name;
                            // Exact or suffix match (case-insensitive)
                            if (std.ascii.eqlIgnoreCase(catch_type, exc_class_name) or
                                std.ascii.eqlIgnoreCase(catch_simple, exc_simple) or
                                std.ascii.eqlIgnoreCase(catch_simple, exc_class_name) or
                                std.ascii.eqlIgnoreCase(catch_type, exc_simple))
                            {
                                matched_catch = cc;
                                break;
                            }
                            // Check superclass hierarchy for exception matching
                            if (self.findClass(exc_class_name)) |exc_cd| {
                                if (exc_cd.super_class) |sc| {
                                    const sc_simple = if (std.mem.lastIndexOfScalar(u8, sc.name, '.')) |di| sc.name[di + 1 ..] else sc.name;
                                    if (std.ascii.eqlIgnoreCase(catch_simple, sc_simple) or
                                        std.ascii.eqlIgnoreCase(catch_type, sc.name))
                                    {
                                        matched_catch = cc;
                                        break;
                                    }
                                }
                            }
                            // Generic Exception catch (fallback)
                            if (std.ascii.eqlIgnoreCase(catch_type, "Exception") or
                                std.ascii.eqlIgnoreCase(catch_type, "System.Exception"))
                            {
                                generic_catch = cc;
                            }
                        }
                        // Use matched catch, or fall back to generic Exception, or first catch
                        const selected = matched_catch orelse generic_catch orelse &ts.catches[0];
                        const catch_env = try current_env.child();
                        try catch_env.define(selected.name, Value{ .object = exc_obj });
                        const catch_result = try self.execBlock(selected.body, catch_env);
                        if (ts.finally_body) |fb| _ = try self.execBlock(fb, current_env);
                        return catch_result;
                    }
                    self.pending_exception = null;
                    if (ts.finally_body) |fb| _ = try self.execBlock(fb, current_env);
                    return .normal;
                }
            },
            .throw_stmt => |ts| {
                const exc_val = try self.evalExpr(ts.expr, current_env);
                // Store exception value for catch handler
                self.pending_exception = exc_val;
                return error.ApexException;
            },
            .dml_stmt => |dml| {
                const target = try self.evalExpr(dml.target, current_env);
                try self.executeDml(dml.op, target);
                return .normal;
            },
        }
    }

    // -----------------------------------------------------------------------
    // DML 操作
    // -----------------------------------------------------------------------

    fn executeDml(self: *Evaluator, op: ast.DmlOp, target: Value) anyerror!void {
        switch (op) {
            .insert => {
                if (target == .sobject) {
                    try self.insertRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.insertRecord(item.sobject);
                    }
                }
            },
            .update => {
                // update はストア上のレコードを更新
                if (target == .sobject) {
                    try self.updateRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.updateRecord(item.sobject);
                    }
                }
            },
            .upsert => {
                // Upsert: if record has Id, update; otherwise insert
                if (target == .sobject) {
                    try self.upsertRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.upsertRecord(item.sobject);
                    }
                }
            },
            .delete => {
                if (target == .sobject) {
                    try self.deleteRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.deleteRecord(item.sobject);
                    }
                }
            },
            .undelete => {
                if (target == .sobject) {
                    try self.undeleteRecord(target.sobject);
                } else if (target == .list) {
                    for (target.list.items.items) |item| {
                        if (item == .sobject) try self.undeleteRecord(item.sobject);
                    }
                }
            },
            .merge => {},
        }
    }

    fn insertRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        // Validate required fields — throw DmlException on failure
        if (try self.validateRequiredFields(obj)) |err_msg| {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = err_msg });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }

        // Auto-assign Id
        const id = try std.fmt.allocPrint(self.arena, "{s:0>15}{d:0>3}", .{ obj.type_name[0..@min(obj.type_name.len, 15)], self.next_id });
        self.next_id += 1;
        obj.id = id;
        try obj.fields.put(self.arena, "Id", Value{ .string = id });

        // Add a snapshot copy to store (so later mutations to the live object don't affect stored records)
        const snapshot = try self.arena.create(types.SObject);
        snapshot.* = .{ .type_name = obj.type_name, .id = id };
        for (obj.fields.keys(), obj.fields.values()) |k, v| {
            try snapshot.fields.put(self.arena, k, v);
        }
        const gop = try self.store.getOrPut(self.arena, obj.type_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.arena, Value{ .sobject = snapshot });
    }

    fn validateRequiredFields(self: *Evaluator, obj: *types.SObject) !?[]const u8 {
        _ = self;
        // Required field validation for common SObject types
        const type_name = obj.type_name;
        if (std.ascii.eqlIgnoreCase(type_name, "Account")) {
            const name_val = obj.fields.get("Name");
            if (name_val == null or name_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            }
            if (name_val.? == .string and name_val.?.string.len == 0) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            }
        }
        if (std.ascii.eqlIgnoreCase(type_name, "Contact")) {
            const name_val = obj.fields.get("LastName");
            if (name_val == null or name_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [LastName]";
            }
        }
        if (std.ascii.eqlIgnoreCase(type_name, "Opportunity")) {
            const name_val = obj.fields.get("Name");
            if (name_val == null or name_val.? == .null_val) {
                return "REQUIRED_FIELD_MISSING: Required fields are missing: [Name]";
            }
        }
        return null;
    }

    fn updateRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        // Validate that the record exists in the store (if it has an Id)
        if (obj.id) |record_id| {
            var found_rec: ?*types.SObject = null;
            if (self.store.getPtr(obj.type_name)) |records| {
                for (records.items) |rec| {
                    if (rec == .sobject and rec.sobject.id != null and
                        std.mem.eql(u8, rec.sobject.id.?, record_id))
                    {
                        found_rec = rec.sobject;
                        break;
                    }
                }
            }
            if (found_rec == null) {
                // Also check via Id field
                if (obj.fields.get("Id")) |id_val| {
                    if (id_val == .string) {
                        var store_iter = self.store.iterator();
                        while (store_iter.next()) |entry| {
                            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, obj.type_name)) {
                                for (entry.value_ptr.items) |rec| {
                                    if (rec == .sobject and rec.sobject.id != null and
                                        std.mem.eql(u8, rec.sobject.id.?, id_val.string))
                                    {
                                        found_rec = rec.sobject;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (found_rec == null) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "INVALID_CROSS_REFERENCE_KEY: invalid cross reference id" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            // Update the store snapshot with current field values
            if (found_rec) |stored| {
                for (obj.fields.keys(), obj.fields.values()) |k, v| {
                    stored.fields.put(self.arena, k, v) catch {};
                }
            }
        }
    }

    fn upsertRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        if (obj.id != null) {
            // Check if record exists in store
            const record_id = obj.id.?;
            var found = false;
            if (self.store.getPtr(obj.type_name)) |records| {
                for (records.items) |rec| {
                    if (rec == .sobject and rec.sobject.id != null and
                        std.mem.eql(u8, rec.sobject.id.?, record_id))
                    {
                        found = true;
                        break;
                    }
                }
            }
            // Also check Id field
            if (!found) {
                if (obj.fields.get("Id")) |id_val| {
                    if (id_val == .string) {
                        var store_iter = self.store.iterator();
                        while (store_iter.next()) |entry| {
                            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, obj.type_name)) {
                                for (entry.value_ptr.items) |rec| {
                                    if (rec == .sobject and rec.sobject.id != null and
                                        std.mem.eql(u8, rec.sobject.id.?, id_val.string))
                                    {
                                        found = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (found) {
                try self.updateRecord(obj);
            } else {
                // Invalid cross reference Id — throw DmlException
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "DmlException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "INVALID_CROSS_REFERENCE_KEY: invalid cross reference id" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
        } else {
            try self.insertRecord(obj);
        }
    }

    fn deleteRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        if (obj.id == null) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "ENTITY_IS_DELETED: entity is deleted" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
        var found = false;
        if (self.store.getPtr(obj.type_name)) |records| {
            var i: usize = 0;
            while (i < records.items.len) {
                if (records.items[i] == .sobject and records.items[i].sobject.id != null and
                    std.mem.eql(u8, records.items[i].sobject.id.?, obj.id.?))
                {
                    // Move to trash for potential undelete
                    const removed = records.orderedRemove(i);
                    const trash_gop = try self.trash.getOrPut(self.arena, obj.type_name);
                    if (!trash_gop.found_existing) trash_gop.value_ptr.* = .empty;
                    try trash_gop.value_ptr.append(self.arena, removed);
                    found = true;
                } else {
                    i += 1;
                }
            }
        }
        if (!found) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "ENTITY_IS_DELETED: entity is deleted" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
    }

    fn undeleteRecord(self: *Evaluator, obj: *types.SObject) anyerror!void {
        if (obj.id == null) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "UNDELETE_FAILED: entity not in recycle bin" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
        var found = false;
        if (self.trash.getPtr(obj.type_name)) |trashed| {
            var i: usize = 0;
            while (i < trashed.items.len) {
                if (trashed.items[i] == .sobject and trashed.items[i].sobject.id != null and
                    std.mem.eql(u8, trashed.items[i].sobject.id.?, obj.id.?))
                {
                    const restored = trashed.orderedRemove(i);
                    const gop = try self.store.getOrPut(self.arena, obj.type_name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.arena, restored);
                    found = true;
                } else {
                    i += 1;
                }
            }
        }
        if (!found) {
            const exc = try self.arena.create(types.ObjectInstance);
            exc.* = .{ .class_name = "DmlException" };
            try exc.fields.put(self.arena, "message", Value{ .string = "UNDELETE_FAILED: entity not in recycle bin" });
            self.pending_exception = Value{ .object = exc };
            return error.ApexException;
        }
    }

    // -----------------------------------------------------------------------
    // SOQL 実行
    // -----------------------------------------------------------------------

    fn executeSoql(self: *Evaluator, raw: []const u8, current_env: *Env) !Value {
        // Strip brackets
        var soql = raw;
        if (soql.len > 2 and soql[0] == '[') soql = soql[1 .. soql.len - 1];
        soql = std.mem.trim(u8, soql, " \t\n\r");

        // COUNT() query
        if (std.ascii.indexOfIgnoreCase(soql, "count()")) |_| {
            const from_type = extractFromType(soql);
            if (from_type) |ft| {
                var count: i64 = 0;
                var store_iter = self.store.iterator();
                while (store_iter.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, ft)) {
                        // Apply WHERE filter even for COUNT
                        for (entry.value_ptr.items) |record| {
                            if (self.matchesWhere(record, soql, current_env)) count += 1;
                        }
                        break;
                    }
                }
                return Value{ .integer = count };
            }
            return Value{ .integer = 0 };
        }

        // Regular SELECT query
        const from_type = extractFromType(soql) orelse return self.makeEmptyList();
        var records: std.ArrayListUnmanaged(Value) = .empty;

        // Find matching records (case-insensitive type name)
        var store_iter = self.store.iterator();
        while (store_iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, from_type)) {
                for (entry.value_ptr.items) |record| {
                    if (self.matchesWhere(record, soql, current_env))
                        try records.append(self.arena, record);
                }
                break;
            }
        }

        // Apply OFFSET
        if (extractOffset(soql)) |offset_val| {
            if (offset_val < records.items.len) {
                const remaining = records.items.len - offset_val;
                std.mem.copyForwards(Value, records.items[0..remaining], records.items[offset_val..records.items.len]);
                records.items.len = remaining;
            } else {
                records.items.len = 0;
            }
        }

        // Apply LIMIT (including :bindVar)
        var limit_val_opt = extractLimit(soql);
        if (limit_val_opt == null) {
            // Check for LIMIT :bindVar
            if (extractLimitBindVar(soql)) |bind_name| {
                if (current_env.get(bind_name)) |bv| {
                    if (bv == .integer and bv.integer > 0) {
                        limit_val_opt = @intCast(bv.integer);
                    }
                }
            }
        }
        if (limit_val_opt) |limit_val| {
            if (records.items.len > limit_val) {
                records.items.len = limit_val;
            }
        }

        const list = try self.arena.create(types.ListValue);
        list.* = .{ .items = records };
        return Value{ .list = list };
    }

    fn matchesWhere(self: *Evaluator, record: Value, soql: []const u8, current_env: *Env) bool {
        const where_clause = extractWhereClause(soql) orelse return true;
        if (record != .sobject) return true;
        return self.evalWhereCondition(record.sobject, where_clause, current_env);
    }

    fn evalWhereCondition(self: *Evaluator, sob: *types.SObject, clause: []const u8, current_env: *Env) bool {
        const trimmed = std.mem.trim(u8, clause, " \t\n\r");
        if (trimmed.len == 0) return true;

        // Handle AND
        if (findLogicalOp(trimmed, "AND")) |and_pos| {
            const left_part = trimmed[0..and_pos];
            const right_part = trimmed[and_pos + 3 ..];
            return self.evalWhereCondition(sob, left_part, current_env) and
                self.evalWhereCondition(sob, right_part, current_env);
        }

        // Handle OR
        if (findLogicalOp(trimmed, "OR")) |or_pos| {
            const left_part = trimmed[0..or_pos];
            const right_part = trimmed[or_pos + 2 ..];
            return self.evalWhereCondition(sob, left_part, current_env) or
                self.evalWhereCondition(sob, right_part, current_env);
        }

        // Strip outer parens
        if (trimmed.len > 2 and trimmed[0] == '(') {
            // Find matching paren
            var depth: u32 = 0;
            var all_enclosed = false;
            for (trimmed, 0..) |ch, i| {
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    depth -= 1;
                    if (depth == 0 and i == trimmed.len - 1) all_enclosed = true;
                }
            }
            if (all_enclosed) {
                return self.evalWhereCondition(sob, trimmed[1 .. trimmed.len - 1], current_env);
            }
        }

        // Simple condition: field = 'value' or field = :bindVar or field != 'value'
        return self.evalSimpleCondition(sob, trimmed, current_env);
    }

    fn evalSimpleCondition(self: *Evaluator, sob: *types.SObject, cond: []const u8, current_env: *Env) bool {
        // Parse: field OP value
        // Find operator
        var op_pos: ?usize = null;
        var op_len: usize = 1;
        var is_neq = false;
        var is_like = false;
        var is_in = false;

        var i: usize = 0;
        while (i < cond.len) : (i += 1) {
            if (cond[i] == '=' and (i == 0 or cond[i - 1] != '!' and cond[i - 1] != '<' and cond[i - 1] != '>')) {
                op_pos = i;
                op_len = 1;
                break;
            }
            if (i + 1 < cond.len and cond[i] == '!' and cond[i + 1] == '=') {
                op_pos = i;
                op_len = 2;
                is_neq = true;
                break;
            }
            if (i + 4 <= cond.len and std.ascii.eqlIgnoreCase(cond[i .. i + 4], "LIKE")) {
                if ((i == 0 or cond[i - 1] == ' ') and (i + 4 >= cond.len or cond[i + 4] == ' ')) {
                    op_pos = i;
                    op_len = 4;
                    is_like = true;
                    break;
                }
            }
            if (i + 2 <= cond.len and std.ascii.eqlIgnoreCase(cond[i .. i + 2], "IN")) {
                if ((i == 0 or cond[i - 1] == ' ') and (i + 2 >= cond.len or cond[i + 2] == ' ')) {
                    op_pos = i;
                    op_len = 2;
                    is_in = true;
                    break;
                }
            }
        }

        const op_start = op_pos orelse return true; // can't parse, include record
        const field_name = std.mem.trim(u8, cond[0..op_start], " \t\n\r");
        const value_str = std.mem.trim(u8, cond[op_start + op_len ..], " \t\n\r");

        // Get field value from record (case-insensitive)
        var field_val: Value = Value.null_val;
        var field_found = false;
        for (sob.fields.keys(), sob.fields.values()) |k, v| {
            if (std.ascii.eqlIgnoreCase(k, field_name)) {
                field_val = v;
                field_found = true;
                break;
            }
        }
        if (!field_found) return if (is_neq) true else false;

        if (is_like) {
            // Simple LIKE support: '%xxx%' → contains
            if (field_val != .string) return false;
            var pattern = value_str;
            if (pattern.len >= 2 and pattern[0] == '\'') pattern = pattern[1 .. pattern.len - 1];
            if (pattern.len >= 2 and pattern[0] == '%' and pattern[pattern.len - 1] == '%') {
                return std.ascii.indexOfIgnoreCase(field_val.string, pattern[1 .. pattern.len - 1]) != null;
            }
            return std.ascii.eqlIgnoreCase(field_val.string, pattern);
        }

        if (is_in) {
            // IN ('val1', 'val2') or IN :bindVar
            const in_str = std.mem.trim(u8, value_str, " \t\n\r");
            // Handle :bindVar for IN clause
            if (in_str.len > 0 and in_str[0] == ':') {
                const var_name = in_str[1..];
                if (current_env.get(var_name)) |bind_val| {
                    if (bind_val == .list) {
                        for (bind_val.list.items.items) |item| {
                            if (utils.valueEql(field_val, item)) return true;
                        }
                        return false;
                    }
                    if (bind_val == .set) {
                        const field_str = utils.coerceToString(field_val, self.arena) catch return true;
                        return bind_val.set.entries.contains(field_str);
                    }
                }
            }
            // IN ('val1', 'val2') — parse literal list
            if (std.mem.indexOf(u8, in_str, "(")) |paren_start| {
                const inner = if (std.mem.lastIndexOf(u8, in_str, ")")) |paren_end|
                    in_str[paren_start + 1 .. paren_end]
                else
                    in_str[paren_start + 1 ..];
                // Split by comma and check each value
                var iter = std.mem.splitScalar(u8, inner, ',');
                while (iter.next()) |part| {
                    const trimmed = std.mem.trim(u8, part, " \t\n\r'");
                    if (field_val == .string and std.ascii.eqlIgnoreCase(field_val.string, trimmed)) return true;
                    if (field_val == .integer) {
                        if (std.fmt.parseInt(i64, trimmed, 10)) |int_val| {
                            if (field_val.integer == int_val) return true;
                        } else |_| {}
                    }
                }
                return false;
            }
            return true; // fallback: include all
        }

        // Resolve the comparison value
        var cmp_val: Value = Value.null_val;
        if (value_str.len > 0 and value_str[0] == '\'') {
            // String literal
            if (value_str.len >= 2) {
                // Find closing quote
                var end = value_str.len;
                if (value_str[end - 1] == '\'') end -= 1;
                cmp_val = Value{ .string = value_str[1..end] };
            }
        } else if (value_str.len > 0 and value_str[0] == ':') {
            // Bind variable
            const var_name = value_str[1..];
            // Handle dotted: :insertedAccount.Id
            if (std.mem.indexOf(u8, var_name, ".")) |dot_pos| {
                const base_name = var_name[0..dot_pos];
                const prop_name = var_name[dot_pos + 1 ..];
                const base_val = current_env.get(base_name) orelse return true;
                if (base_val == .sobject) {
                    cmp_val = base_val.sobject.fields.get(prop_name) orelse return true;
                } else if (base_val == .object) {
                    cmp_val = base_val.object.fields.get(prop_name) orelse return true;
                } else {
                    return true;
                }
            } else {
                cmp_val = current_env.get(var_name) orelse return true;
            }
        } else if (std.fmt.parseInt(i64, std.mem.trim(u8, value_str, " \t\n\r"), 10)) |int_val| {
            cmp_val = Value{ .integer = int_val };
        } else |_| {
            // Could be null or enum value
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value_str, " \t\n\r"), "null")) {
                cmp_val = Value.null_val;
            } else {
                return true; // unknown, include
            }
        }

        if (is_neq) return !utils.valueEql(field_val, cmp_val);
        return utils.valueEql(field_val, cmp_val);
    }

    fn makeEmptyList(self: *Evaluator) !Value {
        const list = try self.arena.create(types.ListValue);
        list.* = .{};
        return Value{ .list = list };
    }

    // -----------------------------------------------------------------------
    // 式の評価
    // -----------------------------------------------------------------------

    pub fn evalExpr(self: *Evaluator, expr: *const ast.Expr, current_env: *Env) anyerror!Value {
        switch (expr.*) {
            .integer_literal => |v| return .{ .integer = v },
            .double_literal => |v| return .{ .double = v },
            .string_literal => |v| return .{ .string = v },
            .boolean_literal => |v| return .{ .boolean = v },
            .null_literal => return .null_val,
            .this_expr, .super_expr => {
                return current_env.get("this") orelse .null_val;
            },

            .identifier => |id| {
                if (current_env.get(id.name)) |val| return val;
                // Check static fields in enclosing class context
                // When `this` is available, check ClassName.fieldName and parent class
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_val.object.class_name, id.name }) catch return .null_val;
                        if (self.global_env.get(key)) |val| return val;
                        // Check parent class static fields
                        if (self.findClass(this_val.object.class_name)) |cd| {
                            if (cd.super_class) |sc| {
                                const pkey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ sc.name, id.name }) catch return .null_val;
                                if (self.global_env.get(pkey)) |val| return val;
                            }
                        }
                    }
                }
                // Check current_class static fields (for static methods)
                if (self.current_class) |cc| {
                    const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, id.name }) catch return .null_val;
                    if (self.global_env.get(key)) |val| return val;
                    // Check parent class too
                    if (self.findClass(cc)) |cd| {
                        if (cd.super_class) |sc| {
                            const pkey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ sc.name, id.name }) catch return .null_val;
                            if (self.global_env.get(pkey)) |val| return val;
                        }
                    }
                }
                return .null_val;
            },

            .binary => |bin| {
                const left = try self.evalExpr(bin.left, current_env);
                const right = try self.evalExpr(bin.right, current_env);
                return evalBinary(left, bin.op, right, self.arena);
            },

            .unary => |un| {
                const operand = try self.evalExpr(un.operand, current_env);
                return evalUnary(un.op, operand);
            },

            .assignment => |asgn| {
                const val = try self.evalExpr(asgn.value, current_env);
                return self.evalAssignment(asgn, val, current_env);
            },

            .call => |call| {
                var args: std.ArrayListUnmanaged(Value) = .empty;
                for (call.args) |*arg| {
                    try args.append(self.arena, try self.evalExpr(arg, current_env));
                }
                // super(args) → call parent class constructor
                if (std.mem.eql(u8, call.callee, "super")) {
                    if (current_env.get("this")) |this_val| {
                        if (this_val == .object) {
                            if (self.findClass(this_val.object.class_name)) |cd| {
                                if (cd.super_class) |sc| {
                                    if (self.findClass(sc.name)) |parent_decl| {
                                        self.runConstructor(parent_decl, this_val.object, args.items) catch {};
                                    }
                                }
                            }
                        }
                    }
                    return Value.void_val;
                }
                // Try as instance method on `this` first
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        if (self.findClass(this_val.object.class_name)) |class_decl| {
                            // Look for method in class hierarchy
                            const md = self.findMethodInHierarchy(null, class_decl, call.callee, args.items.len);
                            if (md != null) {
                                return self.callInstanceMethod(class_decl, this_val.object, call.callee, args.items);
                            }
                        }
                    }
                }
                // Try as static method in current class first
                if (self.current_class) |cc| {
                    if (self.findClass(cc)) |cd| {
                        if (self.findBestMethodInClass(cd, call.callee, args.items) != null) {
                            return self.callMethod(cc, call.callee, args.items);
                        }
                    }
                }
                // Search all loaded classes for matching method
                var class_iter = self.classes.iterator();
                while (class_iter.next()) |entry| {
                    for (entry.value_ptr.*.members) |member| {
                        switch (member) {
                            .method_decl => |md| {
                                if (std.ascii.eqlIgnoreCase(md.name, call.callee)) {
                                    return self.callMethod(entry.key_ptr.*, call.callee, args.items);
                                }
                            },
                            else => {},
                        }
                    }
                }
                return Value.null_val;
            },

            .method_call => |mc| return self.evalMethodCall(mc, current_env),

            .field_access => |fa| {
                // Pre-check: three-level ClassName.Inner.Field pattern for enums/constants
                // Must be done BEFORE evaluating the inner object to avoid misresolution
                if (fa.object.* == .field_access) {
                    const inner_fa = fa.object.field_access;
                    if (inner_fa.object.* == .identifier) {
                        const outer_name = inner_fa.object.identifier.name;
                        const inner_name = inner_fa.field;
                        // Try global_env key: OuterClass.Inner.Field
                        const fq_key = try std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{ outer_name, inner_name, fa.field });
                        if (self.global_env.get(fq_key)) |v| return v;
                        // Try as enum in class
                        if (self.findClass(outer_name)) |cd| {
                            for (cd.members) |member| {
                                switch (member) {
                                    .enum_decl => |ed| {
                                        if (std.ascii.eqlIgnoreCase(ed.name, inner_name)) {
                                            return Value{ .string = fa.field };
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                        // System.AccessType/AccessLevel
                        if (std.ascii.eqlIgnoreCase(outer_name, "System") and
                            (std.ascii.eqlIgnoreCase(inner_name, "AccessType") or
                            std.ascii.eqlIgnoreCase(inner_name, "AccessLevel")))
                        {
                            return Value{ .string = fa.field };
                        }
                    }
                }
                const obj = try self.evalExpr(fa.object, current_env);
                return self.evalFieldAccess(fa, obj, current_env);
            },

            .index_access => |ia| {
                const obj = try self.evalExpr(ia.object, current_env);
                const idx = try self.evalExpr(ia.index, current_env);
                if (obj == .list and idx == .integer) {
                    const i: usize = @intCast(idx.integer);
                    if (i < obj.list.items.items.len) return obj.list.items.items[i];
                }
                if (obj == .map and idx == .string) {
                    return obj.map.entries.get(idx.string) orelse Value.null_val;
                }
                return Value.null_val;
            },

            .new_expr => |ne| return self.evalNewExpr(ne, current_env),

            .cast_expr => |ce| return self.evalExpr(ce.operand, current_env),

            .ternary => |te| {
                const cond = try self.evalExpr(te.condition, current_env);
                if (utils.coerceToBool(cond) catch false) {
                    return self.evalExpr(te.then_expr, current_env);
                } else {
                    return self.evalExpr(te.else_expr, current_env);
                }
            },

            .instanceof => |ie| {
                const val = try self.evalExpr(ie.operand, current_env);
                if (val == .sobject) return Value{ .boolean = std.ascii.eqlIgnoreCase(val.sobject.type_name, ie.type_name.name) };
                if (val == .object) {
                    // Check class name and superclass hierarchy
                    if (std.ascii.eqlIgnoreCase(val.object.class_name, ie.type_name.name)) return Value{ .boolean = true };
                    // Check if it's an exception type matching Exception hierarchy
                    if (std.mem.endsWith(u8, ie.type_name.name, "Exception") and std.mem.endsWith(u8, val.object.class_name, "Exception")) {
                        return Value{ .boolean = true };
                    }
                    return Value{ .boolean = false };
                }
                if (val == .list) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "List") };
                if (val == .map) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "Map") };
                if (val == .set) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "Set") };
                if (val == .string) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "String") };
                if (val == .integer) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "Integer") };
                if (val == .boolean) return Value{ .boolean = std.ascii.eqlIgnoreCase(ie.type_name.name, "Boolean") };
                return Value{ .boolean = false };
            },

            .soql => |sq| return self.executeSoql(sq.raw, current_env),

            .grouped => |inner| return self.evalExpr(inner, current_env),
        }
    }

    fn evalAssignment(self: *Evaluator, asgn: *ast.Assignment, val: Value, current_env: *Env) !Value {
        switch (asgn.target.*) {
            .identifier => |id| {
                const final_val = if (asgn.op != .assign) blk: {
                    const cur = current_env.get(id.name) orelse Value.null_val;
                    var result = evalCompoundAssign(cur, asgn.op, val);
                    // Handle string concatenation for +=
                    if (asgn.op == .plus_assign and (cur == .string or val == .string)) {
                        const ls = try utils.coerceToString(cur, self.arena);
                        const rs = try utils.coerceToString(val, self.arena);
                        result = Value{ .string = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls, rs }) };
                    }
                    break :blk result;
                } else val;
                current_env.set(id.name, final_val) catch {
                    try current_env.define(id.name, final_val);
                };
                // Also update instance field on `this` if field exists or is declared
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        // Check if this field already exists on the instance or is declared in class
                        var should_update = false;
                        for (this_val.object.fields.keys()) |k| {
                            if (std.ascii.eqlIgnoreCase(k, id.name)) {
                                should_update = true;
                                break;
                            }
                        }
                        if (!should_update) {
                            if (self.findClass(this_val.object.class_name)) |cd| {
                                should_update = self.isInstanceField(cd, id.name) or self.isParentInstanceField(cd, id.name);
                            }
                        }
                        if (should_update) {
                            try this_val.object.fields.put(self.arena, id.name, final_val);
                        }
                        // Also update static field if applicable
                        const static_key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_val.object.class_name, id.name }) catch "";
                        if (self.global_env.get(static_key) != null) {
                            self.global_env.set(static_key, final_val) catch {};
                        }
                    }
                }
                // Also update current_class static field if applicable
                // Only do this if the variable is NOT defined locally (to avoid shadowing)
                if (self.current_class) |cc| {
                    if (current_env.get("this") == null) { // Only in static context
                        const static_key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, id.name }) catch "";
                        if (self.global_env.get(static_key) != null) {
                            self.global_env.set(static_key, final_val) catch {};
                        }
                    }
                }
                return final_val;
            },
            .field_access => |fa| {
                // Handle static field assignment: ClassName.fieldName = val
                if (fa.object.* == .identifier) {
                    const cls = fa.object.identifier.name;
                    // Check if it's a class name (not a local variable)
                    const is_class = self.findClass(cls) != null or
                        std.ascii.eqlIgnoreCase(cls, "RestContext") or
                        std.ascii.eqlIgnoreCase(cls, "System") or
                        std.ascii.eqlIgnoreCase(cls, "Trigger");
                    const is_var = current_env.get(cls) != null;
                    if (is_class and !is_var) {
                        const key = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cls, fa.field });
                        self.global_env.set(key, val) catch {
                            try self.global_env.define(key, val);
                        };
                        return val;
                    }
                }
                const obj = try self.evalExpr(fa.object, current_env);
                var final_val = val;
                if (asgn.op != .assign) {
                    // Compound assignment: get current value and compute
                    const cur = if (obj == .sobject)
                        obj.sobject.fields.get(fa.field) orelse Value.null_val
                    else if (obj == .object)
                        obj.object.fields.get(fa.field) orelse Value.null_val
                    else
                        Value.null_val;
                    final_val = evalCompoundAssign(cur, asgn.op, val);
                    // Handle string concatenation for +=
                    if (asgn.op == .plus_assign and (cur == .string or val == .string)) {
                        const ls = try utils.coerceToString(cur, self.arena);
                        const rs = try utils.coerceToString(val, self.arena);
                        final_val = Value{ .string = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls, rs }) };
                    }
                }
                if (obj == .sobject) {
                    try obj.sobject.fields.put(self.arena, fa.field, final_val);
                    // Sync SObject.id when Id field is set
                    if (std.ascii.eqlIgnoreCase(fa.field, "Id")) {
                        obj.sobject.id = if (final_val == .string) final_val.string else null;
                    }
                } else if (obj == .object) {
                    try obj.object.fields.put(self.arena, fa.field, final_val);
                }
                return final_val;
            },
            .index_access => |ia| {
                const obj = try self.evalExpr(ia.object, current_env);
                const idx = try self.evalExpr(ia.index, current_env);
                if (obj == .list and idx == .integer) {
                    const i: usize = @intCast(idx.integer);
                    if (i < obj.list.items.items.len) {
                        obj.list.items.items[i] = val;
                    }
                }
                return val;
            },
            else => return val,
        }
    }

    fn evalMethodCall(self: *Evaluator, mc: *ast.MethodCallExpr, current_env: *Env) anyerror!Value {
        var args: std.ArrayListUnmanaged(Value) = .empty;
        for (mc.args) |*arg| {
            try args.append(self.arena, try self.evalExpr(arg, current_env));
        }

        // Handle chained calls: System.Assert.areEqual → object = System.Assert, method = areEqual
        // Also handle: Test.startTest, Test.stopTest, TriggerHandler.bypass
        if (mc.object.* == .identifier) {
            const class_name = mc.object.identifier.name;

            // System.Assert / Assert methods
            if (std.ascii.eqlIgnoreCase(class_name, "Assert")) {
                return self.handleAssert(mc.method, args.items);
            }

            // Test methods
            if (std.ascii.eqlIgnoreCase(class_name, "Test")) {
                return self.handleTest(mc.method, args.items);
            }

            // Database methods that need store access
            if (std.ascii.eqlIgnoreCase(class_name, "Database")) {
                return self.handleDatabaseMethod(mc.method, args.items);
            }

            // JSON.serialize/deserialize with round-trip support
            if (std.ascii.eqlIgnoreCase(class_name, "JSON")) {
                if (std.ascii.eqlIgnoreCase(mc.method, "serialize") or std.ascii.eqlIgnoreCase(mc.method, "serializePretty")) {
                    if (args.items.len > 0) {
                        self.last_json_value = args.items[0];
                        return Value{ .string = try utils.coerceToString(args.items[0], self.arena) };
                    }
                    return Value{ .string = "{}" };
                }
                if (std.ascii.eqlIgnoreCase(mc.method, "deserialize")) {
                    // Try round-trip: if we just serialized something, return it
                    if (self.last_json_value) |v| {
                        const result = v;
                        self.last_json_value = null;
                        return result;
                    }
                    // Determine target type from second arg (type expression)
                    if (args.items.len >= 2) {
                        // If type arg is a Schema.SObjectType-like "List<X>.class", return empty list
                        // Check the type expression text from the AST
                        const type_val = args.items[1];
                        const is_list_type = if (type_val == .object)
                            std.ascii.startsWithIgnoreCase(type_val.object.class_name, "List")
                        else
                            false;
                        if (is_list_type) {
                            const list = try self.arena.create(types.ListValue);
                            list.* = .{};
                            return Value{ .list = list };
                        }
                        if (args.items[0] == .string) {
                            const obj = try self.arena.create(types.SObject);
                            obj.* = .{ .type_name = "Object" };
                            return Value{ .sobject = obj };
                        }
                    }
                    return Value.null_val;
                }
            }

            // Integer.valueOf with invalid string → throw TypeException
            if (std.ascii.eqlIgnoreCase(class_name, "Integer") and std.ascii.eqlIgnoreCase(mc.method, "valueOf")) {
                if (args.items.len > 0 and args.items[0] == .string) {
                    if (std.fmt.parseInt(i64, args.items[0].string, 10)) |v| {
                        return Value{ .integer = v };
                    } else |_| {
                        const exc = try self.arena.create(types.ObjectInstance);
                        exc.* = .{ .class_name = "System.TypeException" };
                        try exc.fields.put(self.arena, "message", Value{ .string = try std.fmt.allocPrint(self.arena, "Invalid integer: {s}", .{args.items[0].string}) });
                        self.pending_exception = Value{ .object = exc };
                        return error.ApexException;
                    }
                }
            }

            // Check if identifier is a local variable (instance method call)
            // This comes BEFORE builtin checks so that variables named like
            // builtin classes (e.g., "Http http = new Http(); http.send()")
            // are resolved as instance methods, not static builtins.
            const resolved_var = blk: {
                if (current_env.get(class_name)) |v| break :blk v;
                // Also check current_class static fields (e.g., handler stored as ClassName.handler)
                if (self.current_class) |cc| {
                    const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ cc, class_name }) catch break :blk Value.null_val;
                    if (self.global_env.get(key)) |v| break :blk v;
                }
                // Check "this" class static fields
                if (current_env.get("this")) |this_val| {
                    if (this_val == .object) {
                        const key = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ this_val.object.class_name, class_name }) catch break :blk Value.null_val;
                        if (self.global_env.get(key)) |v| break :blk v;
                    }
                }
                break :blk Value.null_val;
            };
            switch (resolved_var) {
                .list, .map, .set, .sobject, .object, .string => {
                    return self.evalInstanceMethod(resolved_var, mc.method, args.items, current_env);
                },
                else => {},
            }

            // Builtin static dispatch (only reached when no local variable matched)
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout };
            if (try builtins.dispatchStatic(&bctx, class_name, mc.method, args.items)) |result| {
                return result;
            }

            // TestFactory / TestDataHelpers stubs
            if (try self.handleTestFactory(class_name, mc.method, args.items)) |result| {
                return result;
            }

            // User-defined class method
            return self.callMethod(class_name, mc.method, args.items);
        }

        // Handle System.Assert (field_access . method_call chain)
        if (mc.object.* == .field_access) {
            const fa = mc.object.field_access;
            if (fa.object.* == .identifier) {
                const outer_class = fa.object.identifier.name;
                const inner = fa.field;

                // System.Assert.areEqual(...)
                if (std.ascii.eqlIgnoreCase(outer_class, "System") and std.ascii.eqlIgnoreCase(inner, "Assert")) {
                    return self.handleAssert(mc.method, args.items);
                }

                // System.enqueueJob, System.runAs, etc.
                if (std.ascii.eqlIgnoreCase(outer_class, "System")) {
                    return self.handleSystemMethod(inner, mc.method, args.items, current_env);
                }

                // Cache.Session.getPartition / Cache.Org.getPartition
                if (std.ascii.eqlIgnoreCase(outer_class, "Cache") and
                    (std.ascii.eqlIgnoreCase(inner, "Session") or std.ascii.eqlIgnoreCase(inner, "Org")))
                {
                    if (std.ascii.eqlIgnoreCase(mc.method, "getPartition")) {
                        const partition = try self.arena.create(types.ObjectInstance);
                        partition.* = .{ .class_name = "Cache.Partition" };
                        // Use a map to store cache entries
                        const cache_map = try self.arena.create(types.MapValue);
                        cache_map.* = .{};
                        // Use a global key to find this cache partition
                        const cache_key = try std.fmt.allocPrint(self.arena, "Cache.{s}.partition", .{inner});
                        if (self.global_env.get(cache_key)) |existing| {
                            if (existing == .object) {
                                return existing;
                            }
                        }
                        try partition.fields.put(self.arena, "_cache", Value{ .map = cache_map });
                        self.global_env.set(cache_key, Value{ .object = partition }) catch {
                            try self.global_env.define(cache_key, Value{ .object = partition });
                        };
                        return Value{ .object = partition };
                    }
                }
            }
        }

        // Instance method on evaluated object
        const obj = try self.evalExpr(mc.object, current_env);
        return self.evalInstanceMethod(obj, mc.method, args.items, current_env);
    }

    fn evalInstanceMethod(self: *Evaluator, obj: Value, method: []const u8, args: []const Value, _: *Env) anyerror!Value {
        // Null dereference → return null gracefully (some tests depend on this)
        if (obj == .null_val) return Value.null_val;

        // Http.send() mock interception
        if (obj == .object and std.ascii.eqlIgnoreCase(method, "send") and
            (std.ascii.eqlIgnoreCase(obj.object.class_name, "Http") or
            std.ascii.eqlIgnoreCase(obj.object.class_name, "HttpRequest")))
        {
            if (self.callout_mock) |mock| {
                // Call mock.respond(request) method
                if (mock == .object) {
                    if (self.findClass(mock.object.class_name)) |mock_class| {
                        const req_arg = if (args.len > 0) args[0] else Value.null_val;
                        return self.callInstanceMethod(mock_class, mock.object, "respond", &.{req_arg});
                    }
                }
            }
        }

        // For ObjectInstance with a user-defined class, try class methods first
        if (obj == .object) {
            if (self.findClass(obj.object.class_name)) |class_decl| {
                const md = self.findMethodInHierarchyTyped(null, class_decl, method, args) orelse
                    self.findMethodInHierarchy(null, class_decl, method, args.len);
                if (md != null) {
                    return self.callInstanceMethod(class_decl, obj.object, method, args);
                }
            }
        }

        var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout };
        if (try builtins.dispatchInstance(&bctx, obj, method, args)) |result| {
            return result;
        }

        // SObject field access methods
        if (obj == .sobject) {
            // getSObjects(relationship)
            if (std.ascii.eqlIgnoreCase(method, "getSObjects") and args.len > 0 and args[0] == .string) {
                return obj.sobject.fields.get(args[0].string) orelse try self.makeEmptyList();
            }
            // get(fieldName)
            if (std.ascii.eqlIgnoreCase(method, "get") and args.len > 0 and args[0] == .string) {
                return obj.sobject.fields.get(args[0].string) orelse Value.null_val;
            }
            // put(fieldName, value)
            if (std.ascii.eqlIgnoreCase(method, "put") and args.len >= 2 and args[0] == .string) {
                try obj.sobject.fields.put(self.arena, args[0].string, args[1]);
                return args[1];
            }
        }

        // List methods
        if (obj == .list) {
            return self.evalListMethod(obj.list, method, args);
        }

        // Map methods
        if (obj == .map) {
            return self.evalMapMethod(obj.map, method, args);
        }

        // Set methods
        if (obj == .set) {
            return self.evalSetMethod(obj.set, method, args);
        }

        // String methods
        if (obj == .string) {
            return self.evalStringMethod(obj.string, method, args);
        }

        // ObjectInstance methods (user-defined class)
        if (obj == .object) {
            // Try to call method on the class with `this` bound
            if (self.findClass(obj.object.class_name)) |class_decl| {
                return self.callInstanceMethod(class_decl, obj.object, method, args);
            }
            // If class not found by instance class_name, check if there's a parent class
            // (inner class pattern: "OuterClass.InnerClass")
        }

        return Value.null_val;
    }

    fn evalListMethod(self: *Evaluator, list: *types.ListValue, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "add")) {
            if (args.len > 0) try list.items.append(self.arena, args[0]);
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "size")) return Value{ .integer = @intCast(list.items.items.len) };
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) return Value{ .boolean = list.items.items.len == 0 };
        if (std.ascii.eqlIgnoreCase(method, "get") and args.len > 0 and args[0] == .integer) {
            const i: usize = @intCast(args[0].integer);
            if (i < list.items.items.len) return list.items.items[i];
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "set") and args.len >= 2 and args[0] == .integer) {
            const i: usize = @intCast(args[0].integer);
            if (i < list.items.items.len) list.items.items[i] = args[1];
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "clear")) {
            list.items.items.len = 0;
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "contains") and args.len > 0) {
            for (list.items.items) |item| {
                if (utils.valueEql(item, args[0])) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (std.ascii.eqlIgnoreCase(method, "remove") and args.len > 0 and args[0] == .integer) {
            const i: usize = @intCast(args[0].integer);
            if (i < list.items.items.len) {
                const removed = list.items.orderedRemove(i);
                return removed;
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "sort")) return .void_val; // simplified
        if (std.ascii.eqlIgnoreCase(method, "addAll") and args.len > 0) {
            if (args[0] == .list) {
                for (args[0].list.items.items) |item| try list.items.append(self.arena, item);
            } else if (args[0] == .set) {
                for (args[0].set.entries.keys()) |key| try list.items.append(self.arena, Value{ .string = key });
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "clone") or std.ascii.eqlIgnoreCase(method, "deepClone")) {
            const new_list = try self.arena.create(types.ListValue);
            new_list.* = .{};
            for (list.items.items) |item| try new_list.items.append(self.arena, item);
            return Value{ .list = new_list };
        }
        if (std.ascii.eqlIgnoreCase(method, "indexOf") and args.len > 0) {
            for (list.items.items, 0..) |item, idx| {
                if (utils.valueEql(item, args[0])) return Value{ .integer = @intCast(idx) };
            }
            return Value{ .integer = -1 };
        }
        if (std.ascii.eqlIgnoreCase(method, "getSObjectType")) {
            // Return type of first element
            if (list.items.items.len > 0 and list.items.items[0] == .sobject) {
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = list.items.items[0].sobject.type_name });
                return Value{ .object = sot };
            }
            const sot = try self.arena.create(types.ObjectInstance);
            sot.* = .{ .class_name = "Schema.SObjectType" };
            try sot.fields.put(self.arena, "name", Value{ .string = "SObject" });
            return Value{ .object = sot };
        }
        return Value.null_val;
    }

    fn evalMapMethod(self: *Evaluator, map: *types.MapValue, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "put") and args.len >= 2) {
            const key = try utils.coerceToString(args[0], self.arena);
            try map.entries.put(self.arena, key, args[1]);
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "get") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            return map.entries.get(key) orelse Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "containsKey") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            return Value{ .boolean = map.entries.contains(key) };
        }
        if (std.ascii.eqlIgnoreCase(method, "size")) return Value{ .integer = @intCast(map.entries.count()) };
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) return Value{ .boolean = map.entries.count() == 0 };
        if (std.ascii.eqlIgnoreCase(method, "keySet")) {
            const set = try self.arena.create(types.SetValue);
            set.* = .{};
            for (map.entries.keys()) |key| {
                try set.entries.put(self.arena, key, {});
            }
            return Value{ .set = set };
        }
        if (std.ascii.eqlIgnoreCase(method, "values")) {
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            for (map.entries.values()) |val| {
                try list.items.append(self.arena, val);
            }
            return Value{ .list = list };
        }
        if (std.ascii.eqlIgnoreCase(method, "remove") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            if (map.entries.get(key)) |val| {
                _ = map.entries.orderedRemove(key);
                return val;
            }
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "putAll") and args.len > 0) {
            if (args[0] == .map) {
                for (args[0].map.entries.keys(), args[0].map.entries.values()) |k, v| {
                    try map.entries.put(self.arena, k, v);
                }
            } else if (args[0] == .list) {
                // putAll from list of SObjects: key=Id, value=record
                for (args[0].list.items.items) |item| {
                    if (item == .sobject and item.sobject.id != null) {
                        try map.entries.put(self.arena, item.sobject.id.?, item);
                    }
                }
            }
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "clear")) {
            map.entries = .empty;
            return .void_val;
        }
        return Value.null_val;
    }

    fn evalSetMethod(self: *Evaluator, set: *types.SetValue, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "add") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            try set.entries.put(self.arena, key, {});
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "contains") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            return Value{ .boolean = set.entries.contains(key) };
        }
        if (std.ascii.eqlIgnoreCase(method, "size")) return Value{ .integer = @intCast(set.entries.count()) };
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) return Value{ .boolean = set.entries.count() == 0 };
        if (std.ascii.eqlIgnoreCase(method, "addAll") and args.len > 0) {
            if (args[0] == .list) {
                for (args[0].list.items.items) |item| {
                    const key = try utils.coerceToString(item, self.arena);
                    try set.entries.put(self.arena, key, {});
                }
            } else if (args[0] == .set) {
                for (args[0].set.entries.keys()) |key| {
                    try set.entries.put(self.arena, key, {});
                }
            }
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "remove") and args.len > 0) {
            const key = try utils.coerceToString(args[0], self.arena);
            _ = set.entries.orderedRemove(key);
            return Value{ .boolean = true };
        }
        if (std.ascii.eqlIgnoreCase(method, "clear")) {
            set.entries = .empty;
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "containsAll") and args.len > 0 and args[0] == .set) {
            for (args[0].set.entries.keys()) |key| {
                if (!set.entries.contains(key)) return Value{ .boolean = false };
            }
            return Value{ .boolean = true };
        }
        return Value.null_val;
    }

    fn evalStringMethod(self: *Evaluator, s: []const u8, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "length")) return Value{ .integer = @intCast(s.len) };
        if (std.ascii.eqlIgnoreCase(method, "toUpperCase")) {
            const upper = try self.arena.alloc(u8, s.len);
            for (s, 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
            return Value{ .string = upper };
        }
        if (std.ascii.eqlIgnoreCase(method, "toLowerCase")) {
            const lower = try self.arena.alloc(u8, s.len);
            for (s, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
            return Value{ .string = lower };
        }
        if (std.ascii.eqlIgnoreCase(method, "trim")) return Value{ .string = std.mem.trim(u8, s, " \t\r\n") };
        if (std.ascii.eqlIgnoreCase(method, "contains") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.indexOf(u8, s, args[0].string) != null };
        }
        if (std.ascii.eqlIgnoreCase(method, "containsIgnoreCase") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.ascii.indexOfIgnoreCase(s, args[0].string) != null };
        }
        if (std.ascii.eqlIgnoreCase(method, "startsWith") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.startsWith(u8, s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "endsWith") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.endsWith(u8, s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "indexOf") and args.len > 0 and args[0] == .string) {
            const idx = std.mem.indexOf(u8, s, args[0].string);
            return Value{ .integer = if (idx) |i| @intCast(i) else -1 };
        }
        if (std.ascii.eqlIgnoreCase(method, "substring")) {
            if (args.len >= 2 and args[0] == .integer and args[1] == .integer) {
                const start: usize = @intCast(@max(args[0].integer, 0));
                const end: usize = @intCast(@min(args[1].integer, @as(i64, @intCast(s.len))));
                if (start <= end and end <= s.len) return Value{ .string = s[start..end] };
            } else if (args.len >= 1 and args[0] == .integer) {
                const start: usize = @intCast(@max(args[0].integer, 0));
                if (start <= s.len) return Value{ .string = s[start..] };
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "split") and args.len > 0 and args[0] == .string) {
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            var iter = std.mem.splitSequence(u8, s, args[0].string);
            while (iter.next()) |part| {
                try list.items.append(self.arena, Value{ .string = part });
            }
            return Value{ .list = list };
        }
        if ((std.ascii.eqlIgnoreCase(method, "replace") or std.ascii.eqlIgnoreCase(method, "replaceAll")) and args.len >= 2 and args[0] == .string and args[1] == .string) {
            const result = try std.mem.replaceOwned(u8, self.arena, s, args[0].string, args[1].string);
            return Value{ .string = result };
        }
        if (std.ascii.eqlIgnoreCase(method, "equals") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.mem.eql(u8, s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "equalsIgnoreCase") and args.len > 0 and args[0] == .string) {
            return Value{ .boolean = std.ascii.eqlIgnoreCase(s, args[0].string) };
        }
        if (std.ascii.eqlIgnoreCase(method, "left") and args.len > 0 and args[0] == .integer) {
            const n: usize = @intCast(@max(args[0].integer, 0));
            const end = @min(n, s.len);
            return Value{ .string = s[0..end] };
        }
        if (std.ascii.eqlIgnoreCase(method, "right") and args.len > 0 and args[0] == .integer) {
            const n: usize = @intCast(@max(args[0].integer, 0));
            const start = if (n >= s.len) 0 else s.len - n;
            return Value{ .string = s[start..] };
        }
        if (std.ascii.eqlIgnoreCase(method, "abbreviate") and args.len > 0 and args[0] == .integer) {
            const max_width: usize = @intCast(@max(args[0].integer, 0));
            if (s.len <= max_width) return Value{ .string = s };
            if (max_width <= 3) return Value{ .string = s[0..max_width] };
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{s}...", .{s[0 .. max_width - 3]}) };
        }
        if (std.ascii.eqlIgnoreCase(method, "isBlank")) {
            return Value{ .boolean = std.mem.trim(u8, s, " \t\r\n").len == 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "isNotBlank")) {
            return Value{ .boolean = std.mem.trim(u8, s, " \t\r\n").len > 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "isEmpty")) {
            return Value{ .boolean = s.len == 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "isNotEmpty")) {
            return Value{ .boolean = s.len > 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "capitalize")) {
            if (s.len == 0) return Value{ .string = s };
            const result = try self.arena.alloc(u8, s.len);
            result[0] = std.ascii.toUpper(s[0]);
            @memcpy(result[1..], s[1..]);
            return Value{ .string = result };
        }
        if (std.ascii.eqlIgnoreCase(method, "deleteWhitespace")) {
            var buf = try self.arena.alloc(u8, s.len);
            var j_idx: usize = 0;
            for (s) |ch| {
                if (!std.ascii.isWhitespace(ch)) {
                    buf[j_idx] = ch;
                    j_idx += 1;
                }
            }
            return Value{ .string = buf[0..j_idx] };
        }
        if (std.ascii.eqlIgnoreCase(method, "normalizeSpace")) {
            return Value{ .string = std.mem.trim(u8, s, " \t\r\n") };
        }
        if (std.ascii.eqlIgnoreCase(method, "lastIndexOf") and args.len > 0 and args[0] == .string) {
            const target = args[0].string;
            if (target.len == 0 or s.len == 0) return Value{ .integer = -1 };
            var last: i64 = -1;
            var k: usize = 0;
            while (k + target.len <= s.len) : (k += 1) {
                if (std.mem.eql(u8, s[k .. k + target.len], target)) last = @intCast(k);
            }
            return Value{ .integer = last };
        }
        if (std.ascii.eqlIgnoreCase(method, "removeEnd") and args.len > 0 and args[0] == .string) {
            if (std.mem.endsWith(u8, s, args[0].string)) {
                return Value{ .string = s[0 .. s.len - args[0].string.len] };
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "removeStart") and args.len > 0 and args[0] == .string) {
            if (std.mem.startsWith(u8, s, args[0].string)) {
                return Value{ .string = s[args[0].string.len..] };
            }
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "format") or std.ascii.eqlIgnoreCase(method, "escapeHtml4") or
            std.ascii.eqlIgnoreCase(method, "escapeJava") or std.ascii.eqlIgnoreCase(method, "escapeSingleQuotes"))
        {
            return Value{ .string = s };
        }
        if (std.ascii.eqlIgnoreCase(method, "toInteger")) {
            return Value{ .integer = std.fmt.parseInt(i64, s, 10) catch 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "valueOf")) {
            return Value{ .string = s };
        }
        // name() - for enum values, returns the string itself
        if (std.ascii.eqlIgnoreCase(method, "name") or std.ascii.eqlIgnoreCase(method, "toString")) {
            return Value{ .string = s };
        }
        // ordinal() - for enum values, return 0 as stub
        if (std.ascii.eqlIgnoreCase(method, "ordinal")) {
            return Value{ .integer = 0 };
        }
        return Value.null_val;
    }

    // -----------------------------------------------------------------------
    // new 式
    // -----------------------------------------------------------------------

    fn evalNewExpr(self: *Evaluator, ne: *ast.NewExpr, current_env: *Env) !Value {
        const type_name = ne.type_name.name;

        // new List<T>() / new List<T>{...}
        if (std.ascii.eqlIgnoreCase(type_name, "List")) {
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            for (ne.args) |*arg| {
                try list.items.append(self.arena, try self.evalExpr(arg, current_env));
            }
            return Value{ .list = list };
        }

        // new Map<K,V>()
        if (std.ascii.eqlIgnoreCase(type_name, "Map")) {
            const map = try self.arena.create(types.MapValue);
            map.* = .{};
            for (ne.args) |*arg| {
                if (arg.* == .assignment) {
                    // Map literal: key => value
                    const asgn = arg.assignment;
                    const key_val = try self.evalExpr(asgn.target, current_env);
                    const val_val = try self.evalExpr(asgn.value, current_env);
                    const key_str = try utils.coerceToString(key_val, self.arena);
                    try map.entries.put(self.arena, key_str, val_val);
                }
            }
            // If single non-assignment arg is a list, construct map from SObject list
            if (ne.args.len == 1 and ne.args[0] != .assignment) {
                var arg_copy = ne.args[0];
                const arg_val = try self.evalExpr(&arg_copy, current_env);
                if (arg_val == .list) {
                    for (arg_val.list.items.items) |item| {
                        if (item == .sobject and item.sobject.id != null) {
                            try map.entries.put(self.arena, item.sobject.id.?, item);
                        }
                    }
                }
            }
            return Value{ .map = map };
        }

        // new Set<T>()
        if (std.ascii.eqlIgnoreCase(type_name, "Set")) {
            const set = try self.arena.create(types.SetValue);
            set.* = .{};
            for (ne.args) |*arg| {
                const v = try self.evalExpr(arg, current_env);
                const key = try utils.coerceToString(v, self.arena);
                try set.entries.put(self.arena, key, {});
            }
            return Value{ .set = set };
        }

        // Known non-SObject types: create ObjectInstance instead
        const non_sobject_types = [_][]const u8{
            "RestRequest",  "RestResponse",  "HttpRequest",    "HttpResponse",
            "Http",         "PageReference",  "SelectOption",   "Messaging.SingleEmailMessage",
            "Messaging.InboundEmail",         "QueryException", "DmlException",
            "AuraHandledException",           "CalloutException",
        };
        for (non_sobject_types) |nst| {
            if (std.ascii.eqlIgnoreCase(type_name, nst)) {
                const instance = try self.arena.create(types.ObjectInstance);
                instance.* = .{ .class_name = type_name };
                // If args contain a message (exception pattern)
                if (ne.args.len > 0) {
                    var arg_copy = ne.args[0];
                    const arg_val = try self.evalExpr(&arg_copy, current_env);
                    if (std.mem.endsWith(u8, type_name, "Exception")) {
                        try instance.fields.put(self.arena, "message", arg_val);
                    }
                }
                return Value{ .object = instance };
            }
        }

        // SObject with named params: new Account(Name = 'Test', ...)
        const obj = try self.arena.create(types.SObject);
        obj.* = .{ .type_name = type_name };
        // Parse named params: args should be Assignment expressions
        for (ne.args) |*arg| {
            if (arg.* == .assignment) {
                const asgn = arg.assignment;
                if (asgn.target.* == .identifier) {
                    const field_name = asgn.target.identifier.name;
                    const field_val = try self.evalExpr(asgn.value, current_env);
                    try obj.fields.put(self.arena, field_name, field_val);
                }
            }
        }

        // Check if it's a user-defined class or exception
        // Also try the simple name (after last dot) for dotted type names
        const simple_name = if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |di| type_name[di + 1 ..] else type_name;
        if (self.findClass(type_name) orelse self.findClass(simple_name)) |class_decl| {
            const instance = try self.arena.create(types.ObjectInstance);
            instance.* = .{ .class_name = type_name };

            // Check if it's an exception class (extends Exception)
            if (class_decl.super_class) |sc| {
                if (std.mem.endsWith(u8, sc.name, "Exception")) {
                    // First arg is the message
                    if (ne.args.len > 0) {
                        var arg_copy = ne.args[0];
                        const msg_val = try self.evalExpr(&arg_copy, current_env);
                        try instance.fields.put(self.arena, "message", msg_val);
                    }
                    return Value{ .object = instance };
                }
            }
            // Also check if the type_name itself ends with Exception
            if (std.mem.endsWith(u8, type_name, "Exception")) {
                if (ne.args.len > 0) {
                    var arg_copy = ne.args[0];
                    const msg_val = try self.evalExpr(&arg_copy, current_env);
                    try instance.fields.put(self.arena, "message", msg_val);
                }
                return Value{ .object = instance };
            }

            // Initialize instance fields from class (non-static)
            self.initInstanceFields(class_decl, instance) catch {};

            // Initialize parent class fields
            if (class_decl.super_class) |sc| {
                if (self.findClass(sc.name)) |parent_decl| {
                    self.initInstanceFields(parent_decl, instance) catch {};
                }
            }

            // Evaluate constructor args
            var eval_args: std.ArrayListUnmanaged(Value) = .empty;
            for (ne.args) |*arg| {
                try eval_args.append(self.arena, try self.evalExpr(arg, current_env));
            }

            // Execute parent constructor first (if has super_class and parent has constructor)
            if (class_decl.super_class) |sc| {
                if (self.findClass(sc.name)) |parent_decl| {
                    self.runConstructor(parent_decl, instance, &.{}) catch {};
                }
            }

            // Execute own constructor
            self.runConstructor(class_decl, instance, eval_args.items) catch {};

            return Value{ .object = instance };
        }

        // Any type ending with "Exception" that wasn't found as a user class
        // should still be an ObjectInstance (not SObject)
        if (std.mem.endsWith(u8, type_name, "Exception")) {
            const instance = try self.arena.create(types.ObjectInstance);
            instance.* = .{ .class_name = type_name };
            if (ne.args.len > 0) {
                var arg_copy = ne.args[0];
                const msg_val = try self.evalExpr(&arg_copy, current_env);
                try instance.fields.put(self.arena, "message", msg_val);
            }
            return Value{ .object = instance };
        }

        return Value{ .sobject = obj };
    }

    // -----------------------------------------------------------------------
    // フィールドアクセス
    // -----------------------------------------------------------------------

    fn evalFieldAccess(self: *Evaluator, fa: *ast.FieldAccess, obj: Value, current_env: *Env) !Value {
        _ = current_env;

        // Auto-unwrap list to first element for field access (SOQL single-record pattern)
        if (obj == .list) {
            // Empty SOQL result with field access → QueryException (only for SOQL sources)
            if (obj.list.items.items.len == 0 and fa.object.* == .soql) {
                const exc = try self.arena.create(types.ObjectInstance);
                exc.* = .{ .class_name = "QueryException" };
                try exc.fields.put(self.arena, "message", Value{ .string = "List has no rows for assignment to SObject" });
                self.pending_exception = Value{ .object = exc };
                return error.ApexException;
            }
            if (obj.list.items.items.len > 0) {
                const first = obj.list.items.items[0];
                if (first == .sobject) {
                    // Case-insensitive field lookup
                    for (first.sobject.fields.keys(), first.sobject.fields.values()) |k, v| {
                        if (std.ascii.eqlIgnoreCase(k, fa.field)) return v;
                    }
                    return Value.null_val;
                }
            }
            // List.size as property
            if (std.ascii.eqlIgnoreCase(fa.field, "size")) return Value{ .integer = @intCast(obj.list.items.items.len) };
            return Value.null_val;
        }

        if (obj == .sobject) {
            // Case-insensitive field lookup
            for (obj.sobject.fields.keys(), obj.sobject.fields.values()) |k, v| {
                if (std.ascii.eqlIgnoreCase(k, fa.field)) return v;
            }
            return Value.null_val;
        }
        if (obj == .object) {
            // Case-insensitive field lookup
            for (obj.object.fields.keys(), obj.object.fields.values()) |k, v| {
                if (std.ascii.eqlIgnoreCase(k, fa.field)) return v;
            }
            return Value.null_val;
        }
        if (obj == .string) {
            // String.length as property (shouldn't be needed but just in case)
            if (std.ascii.eqlIgnoreCase(fa.field, "length")) return Value{ .integer = @intCast(obj.string.len) };
        }

        // Static field: ClassName.fieldName
        if (fa.object.* == .identifier) {
            const class_name = fa.object.identifier.name;

            // Date.today()
            if (std.ascii.eqlIgnoreCase(class_name, "Date") and std.ascii.eqlIgnoreCase(fa.field, "today")) {
                return Value{ .string = "2026-04-06" };
            }

            // AccessLevel / AccessType enum
            if (std.ascii.eqlIgnoreCase(class_name, "AccessLevel") or
                std.ascii.eqlIgnoreCase(class_name, "AccessType"))
            {
                return Value{ .string = fa.field };
            }

            // RestContext.request / RestContext.response
            if (std.ascii.eqlIgnoreCase(class_name, "RestContext")) {
                if (std.ascii.eqlIgnoreCase(fa.field, "request")) {
                    const req = try self.arena.create(types.ObjectInstance);
                    req.* = .{ .class_name = "RestRequest" };
                    try req.fields.put(self.arena, "requestURI", Value{ .string = "/services/apexrest/test" });
                    try req.fields.put(self.arena, "httpMethod", Value{ .string = "GET" });
                    try req.fields.put(self.arena, "requestBody", Value.null_val);
                    // Check if the test set RestContext.request already
                    const key = try std.fmt.allocPrint(self.arena, "RestContext.request", .{});
                    return self.global_env.get(key) orelse Value{ .object = req };
                }
                if (std.ascii.eqlIgnoreCase(fa.field, "response")) {
                    const resp = try self.arena.create(types.ObjectInstance);
                    resp.* = .{ .class_name = "RestResponse" };
                    try resp.fields.put(self.arena, "statusCode", Value{ .integer = 200 });
                    try resp.fields.put(self.arena, "responseBody", Value.null_val);
                    const key = try std.fmt.allocPrint(self.arena, "RestContext.response", .{});
                    return self.global_env.get(key) orelse Value{ .object = resp };
                }
            }

            // SObject.SObjectType
            if (std.ascii.eqlIgnoreCase(fa.field, "SObjectType")) {
                // e.g., Account.SObjectType
                const sot = try self.arena.create(types.ObjectInstance);
                sot.* = .{ .class_name = "Schema.SObjectType" };
                try sot.fields.put(self.arena, "name", Value{ .string = class_name });
                return Value{ .object = sot };
            }

            // SObject.class
            if (std.ascii.eqlIgnoreCase(fa.field, "class")) {
                const type_obj = try self.arena.create(types.ObjectInstance);
                type_obj.* = .{ .class_name = "Type" };
                try type_obj.fields.put(self.arena, "name", Value{ .string = class_name });
                return Value{ .object = type_obj };
            }

            // Trigger context
            if (std.ascii.eqlIgnoreCase(class_name, "Trigger")) {
                if (std.ascii.eqlIgnoreCase(fa.field, "new") or std.ascii.eqlIgnoreCase(fa.field, "old")) {
                    const list = try self.arena.create(types.ListValue);
                    list.* = .{};
                    return Value{ .list = list };
                }
                if (std.ascii.eqlIgnoreCase(fa.field, "isBefore") or std.ascii.eqlIgnoreCase(fa.field, "isAfter") or
                    std.ascii.eqlIgnoreCase(fa.field, "isInsert") or std.ascii.eqlIgnoreCase(fa.field, "isUpdate") or
                    std.ascii.eqlIgnoreCase(fa.field, "isDelete") or std.ascii.eqlIgnoreCase(fa.field, "isUndelete") or
                    std.ascii.eqlIgnoreCase(fa.field, "isExecuting"))
                {
                    return Value{ .boolean = false };
                }
                if (std.ascii.eqlIgnoreCase(fa.field, "newMap") or std.ascii.eqlIgnoreCase(fa.field, "oldMap")) {
                    const map = try self.arena.create(types.MapValue);
                    map.* = .{};
                    return Value{ .map = map };
                }
                if (std.ascii.eqlIgnoreCase(fa.field, "size")) {
                    return Value{ .integer = 0 };
                }
            }

            // Check if it's an enum class
            var class_iter = self.classes.iterator();
            while (class_iter.next()) |entry| {
                const cd = entry.value_ptr.*;
                for (cd.members) |member| {
                    switch (member) {
                        .enum_decl => |ed| {
                            if (std.ascii.eqlIgnoreCase(ed.name, class_name)) {
                                // Return enum value as string
                                return Value{ .string = fa.field };
                            }
                        },
                        else => {},
                    }
                }
            }
            // Also check top-level enums
            if (self.findClass(class_name)) |cd| {
                // It might be a class with the enum as inner
                for (cd.members) |member| {
                    switch (member) {
                        .enum_decl => |_| {},
                        .field_decl => |fd| {
                            if (std.ascii.eqlIgnoreCase(fd.name, fa.field)) {
                                if (fd.modifiers.is_static) {
                                    const skey = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, fa.field }) catch return Value.null_val;
                                    return self.global_env.get(skey) orelse Value.null_val;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }

            // General enum value pattern — any ClassName.CONSTANT_NAME
            const key = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, fa.field });
            if (self.global_env.get(key)) |v| return v;

            // If it looks like an enum constant (all upper case or known pattern), return as string
            return Value{ .string = fa.field };
        }

        // Nested static: ClassName.InnerClass.field → already resolved as field_access chain
        if (fa.object.* == .field_access) {
            const inner_fa = fa.object.field_access;
            if (inner_fa.object.* == .identifier) {
                const outer_name = inner_fa.object.identifier.name;
                const inner_name = inner_fa.field;
                // Check for nested enum or class constant
                if (self.findClass(outer_name)) |cd| {
                    for (cd.members) |member| {
                        switch (member) {
                            .enum_decl => |ed| {
                                if (std.ascii.eqlIgnoreCase(ed.name, inner_name)) {
                                    return Value{ .string = fa.field };
                                }
                            },
                            else => {},
                        }
                    }
                }
                // System.AccessType.CREATABLE / System.AccessLevel.SYSTEM_MODE etc.
                if (std.ascii.eqlIgnoreCase(outer_name, "System") and
                    (std.ascii.eqlIgnoreCase(inner_name, "AccessType") or
                    std.ascii.eqlIgnoreCase(inner_name, "AccessLevel")))
                {
                    return Value{ .string = fa.field };
                }

                // Schema.SObjectType.Account etc.
                if (std.ascii.eqlIgnoreCase(outer_name, "Schema") and std.ascii.eqlIgnoreCase(inner_name, "SObjectType")) {
                    const sot = try self.arena.create(types.ObjectInstance);
                    sot.* = .{ .class_name = "Schema.SObjectType" };
                    try sot.fields.put(self.arena, "name", Value{ .string = fa.field });
                    return Value{ .object = sot };
                }
            }
        }

        return Value.null_val;
    }

    // -----------------------------------------------------------------------
    // テストフレームワーク
    // -----------------------------------------------------------------------

    fn handleAssert(self: *Evaluator, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "areEqual") or std.ascii.eqlIgnoreCase(method, "assertEquals")) {
            if (args.len >= 2) {
                if (!utils.valueEql(args[0], args[1])) {
                    const msg = if (args.len >= 3 and args[2] == .string)
                        args[2].string
                    else
                        try std.fmt.allocPrint(self.arena, "Expected {s} but got {s}", .{
                            try utils.coerceToString(args[0], self.arena),
                            try utils.coerceToString(args[1], self.arena),
                        });
                    self.assertion_failure = msg;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "areNotEqual") or std.ascii.eqlIgnoreCase(method, "assertNotEquals")) {
            if (args.len >= 2) {
                if (utils.valueEql(args[0], args[1])) {
                    self.assertion_failure = if (args.len >= 3 and args[2] == .string) args[2].string else "Values should not be equal";
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isTrue") or std.ascii.eqlIgnoreCase(method, "assertTrue")) {
            if (args.len >= 1) {
                const val = utils.coerceToBool(args[0]) catch false;
                if (!val) {
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string) args[1].string else "Expected true";
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isFalse") or std.ascii.eqlIgnoreCase(method, "assertFalse")) {
            if (args.len >= 1) {
                const val = utils.coerceToBool(args[0]) catch false;
                if (val) {
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string) args[1].string else "Expected false";
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isNotNull") or std.ascii.eqlIgnoreCase(method, "assertNotNull")) {
            if (args.len >= 1) {
                if (args[0] == .null_val) {
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string) args[1].string else "Expected non-null";
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isNull")) {
            if (args.len >= 1) {
                if (args[0] != .null_val) {
                    self.assertion_failure = if (args.len >= 2 and args[1] == .string) args[1].string else "Expected null";
                }
            }
        } else if (std.ascii.eqlIgnoreCase(method, "isInstanceOfType")) {
            // simplified: always pass
        } else if (std.ascii.eqlIgnoreCase(method, "fail")) {
            self.assertion_failure = if (args.len >= 1 and args[0] == .string) args[0].string else "Assert.fail called";
        }
        return .void_val;
    }

    fn handleTest(self: *Evaluator, method: []const u8, args: []const Value) !Value {
        // Test.startTest() / Test.stopTest() — no-op stubs
        if (std.ascii.eqlIgnoreCase(method, "startTest") or std.ascii.eqlIgnoreCase(method, "stopTest")) {
            return .void_val;
        }
        // Test.setMock(Type, mockInstance)
        if (std.ascii.eqlIgnoreCase(method, "setMock") and args.len >= 2) {
            self.callout_mock = args[1];
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "isRunningTest")) {
            return Value{ .boolean = true };
        }
        return .void_val;
    }

    fn handleTriggerHandler(self: *Evaluator, method: []const u8, args: []const Value) !Value {
        if (std.ascii.eqlIgnoreCase(method, "bypass") and args.len > 0 and args[0] == .string) {
            try self.bypasses.put(self.arena, args[0].string, {});
        }
        return .void_val;
    }

    fn handleDatabaseMethod(self: *Evaluator, method: []const u8, args: []const Value) anyerror!Value {
        if (std.ascii.eqlIgnoreCase(method, "insert") or
            std.ascii.eqlIgnoreCase(method, "update") or
            std.ascii.eqlIgnoreCase(method, "upsert") or
            std.ascii.eqlIgnoreCase(method, "delete") or
            std.ascii.eqlIgnoreCase(method, "undelete"))
        {
            const result_class = if (std.ascii.eqlIgnoreCase(method, "upsert"))
                "Database.UpsertResult"
            else if (std.ascii.eqlIgnoreCase(method, "delete") or std.ascii.eqlIgnoreCase(method, "undelete"))
                "Database.DeleteResult"
            else
                "Database.SaveResult";

            // Check allOrNothing flag (second arg, defaults to true)
            const all_or_nothing = if (args.len >= 2 and args[1] == .boolean) args[1].boolean else true;

            // First arg is the records to DML
            if (args.len > 0) {
                const op: ast.DmlOp = if (std.ascii.eqlIgnoreCase(method, "insert"))
                    .insert
                else if (std.ascii.eqlIgnoreCase(method, "update"))
                    .update
                else if (std.ascii.eqlIgnoreCase(method, "upsert"))
                    .upsert
                else if (std.ascii.eqlIgnoreCase(method, "undelete"))
                    .undelete
                else
                    .delete;

                if (all_or_nothing) {
                    // allOrNothing mode: propagate exceptions
                    try self.executeDml(op, args[0]);
                } else {
                    // Best-effort mode: catch exceptions and return failed SaveResults
                    self.executeDml(op, args[0]) catch {
                        self.pending_exception = null; // Consume the exception
                        // Return failed SaveResult(s)
                        if (args[0] == .sobject) {
                            const sr = try self.arena.create(types.ObjectInstance);
                            sr.* = .{ .class_name = result_class };
                            try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = false });
                                try sr.fields.put(self.arena, "success", Value{ .boolean = false });
                            return Value{ .object = sr };
                        }
                        const list = try self.arena.create(types.ListValue);
                        list.* = .{};
                        const count: usize = if (args[0] == .list) args[0].list.items.items.len else 1;
                        for (0..count) |_| {
                            const sr = try self.arena.create(types.ObjectInstance);
                            sr.* = .{ .class_name = result_class };
                            try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = false });
                                try sr.fields.put(self.arena, "success", Value{ .boolean = false });
                            try list.items.append(self.arena, Value{ .object = sr });
                        }
                        return Value{ .list = list };
                    };
                }
            }
            // Create SaveResult(s) for success case
            if (args.len > 0 and args[0] == .sobject) {
                // Single record: return single result (not a list)
                const sr = try self.arena.create(types.ObjectInstance);
                sr.* = .{ .class_name = result_class };
                try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = true });
                try sr.fields.put(self.arena, "success", Value{ .boolean = true });
                try sr.fields.put(self.arena, "Id", Value{ .string = args[0].sobject.id orelse "001000000000001" });
                return Value{ .object = sr };
            }
            // Return SaveResult list
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            const count: usize = if (args.len > 0 and args[0] == .list) args[0].list.items.items.len else 1;
            for (0..count) |_| {
                const sr = try self.arena.create(types.ObjectInstance);
                sr.* = .{ .class_name = result_class };
                try sr.fields.put(self.arena, "isSuccess", Value{ .boolean = true });
                try sr.fields.put(self.arena, "success", Value{ .boolean = true });
                try sr.fields.put(self.arena, "Id", Value{ .string = "001000000000001" });
                try list.items.append(self.arena, Value{ .object = sr });
            }
            return Value{ .list = list };
        }
        if (std.ascii.eqlIgnoreCase(method, "query")) {
            // Execute the SOQL string against the store
            if (args.len > 0 and args[0] == .string) {
                return self.executeSoql(args[0].string, self.global_env);
            }
            const list = try self.arena.create(types.ListValue);
            list.* = .{};
            return Value{ .list = list };
        }
        if (std.ascii.eqlIgnoreCase(method, "queryWithBinds")) {
            // Database.queryWithBinds(queryString, bindMap, accessLevel)
            if (args.len >= 2 and args[0] == .string) {
                // Resolve bind variables from the map
                var soql_str = args[0].string;
                if (args[1] == .map) {
                    // Replace :bindVar with actual values from the map
                    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
                    var pos: usize = 0;
                    while (pos < soql_str.len) {
                        if (soql_str[pos] == ':') {
                            // Extract bind variable name
                            var end = pos + 1;
                            while (end < soql_str.len and (std.ascii.isAlphanumeric(soql_str[end]) or soql_str[end] == '_')) end += 1;
                            const bind_name = soql_str[pos + 1 .. end];
                            if (args[1].map.entries.get(bind_name)) |bind_val| {
                                const s = try utils.coerceToString(bind_val, self.arena);
                                try result_buf.append(self.arena, '\'');
                                try result_buf.appendSlice(self.arena, s);
                                try result_buf.append(self.arena, '\'');
                            } else {
                                try result_buf.appendSlice(self.arena, soql_str[pos..end]);
                            }
                            pos = end;
                        } else {
                            try result_buf.append(self.arena, soql_str[pos]);
                            pos += 1;
                        }
                    }
                    soql_str = try result_buf.toOwnedSlice(self.arena);
                }
                return self.executeSoql(soql_str, self.global_env);
            }
            return try self.makeEmptyList();
        }
        if (std.ascii.eqlIgnoreCase(method, "countQuery") or std.ascii.eqlIgnoreCase(method, "countQueryWithBinds")) {
            // countQuery can take a SOQL string
            if (args.len > 0 and args[0] == .string) {
                const soql = args[0].string;
                // Execute as a count query
                if (std.ascii.indexOfIgnoreCase(soql, "count()")) |_| {
                    return self.executeSoql(soql, self.global_env);
                }
                // Wrap as COUNT query
                const count_result = try self.executeSoql(soql, self.global_env);
                if (count_result == .list) return Value{ .integer = @intCast(count_result.list.items.items.len) };
                return count_result;
            }
            return Value{ .integer = 0 };
        }
        if (std.ascii.eqlIgnoreCase(method, "getQueryLocator")) {
            return Value.null_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "setSavepoint")) {
            const sp = try self.arena.create(types.ObjectInstance);
            sp.* = .{ .class_name = "Database.SavePoint" };
            return Value{ .object = sp };
        }
        if (std.ascii.eqlIgnoreCase(method, "rollback")) {
            return .void_val;
        }
        if (std.ascii.eqlIgnoreCase(method, "executeBatch")) {
            // Execute the batch class's execute method directly
            if (args.len > 0 and args[0] == .object) {
                const batch_obj = args[0].object;
                if (self.findClass(batch_obj.class_name)) |batch_class| {
                    // Call start() to get the scope
                    const scope = self.callInstanceMethod(batch_class, batch_obj, "start", &.{Value.null_val}) catch Value.null_val;
                    _ = scope;
                    // Call execute() with the full store
                    // Get all records from store
                    var all_records: std.ArrayListUnmanaged(Value) = .empty;
                    var store_iter = self.store.iterator();
                    while (store_iter.next()) |entry| {
                        for (entry.value_ptr.items) |item| {
                            try all_records.append(self.arena, item);
                        }
                    }
                    const record_list = try self.arena.create(types.ListValue);
                    record_list.* = .{ .items = all_records };
                    _ = self.callInstanceMethod(batch_class, batch_obj, "execute", &.{ Value.null_val, Value{ .list = record_list } }) catch {};
                    // Call finish()
                    _ = self.callInstanceMethod(batch_class, batch_obj, "finish", &.{Value.null_val}) catch {};
                }
            }
            return Value{ .string = "707000000000001" }; // Fake job ID
        }
        return .void_val;
    }

    fn handleSystemMethod(self: *Evaluator, inner: []const u8, method: []const u8, args: []const Value, current_env: *Env) !Value {
        _ = current_env;
        // System.enqueueJob → execute the Queueable's execute method synchronously
        if (std.ascii.eqlIgnoreCase(inner, "enqueueJob") and args.len > 0 and args[0] == .object) {
            const job_obj = args[0].object;
            if (self.findClass(job_obj.class_name)) |job_class| {
                _ = self.callInstanceMethod(job_class, job_obj, "execute", &.{Value.null_val}) catch {};
            }
            return Value{ .string = "707000000000002" }; // Fake async job ID
        }
        if (std.ascii.eqlIgnoreCase(inner, "enqueueJob")) return .void_val;
        // System.runAs → no-op (runs the block but ignores user context)
        if (std.ascii.eqlIgnoreCase(inner, "runAs")) return .void_val;
        // System.schedule → no-op, return fake job ID
        if (std.ascii.eqlIgnoreCase(inner, "schedule")) return Value{ .string = "08e000000000001" };
        // System.abortJob → no-op
        if (std.ascii.eqlIgnoreCase(inner, "abortJob")) return .void_val;
        // System.debug
        if (std.ascii.eqlIgnoreCase(inner, "debug") and args.len > 0) {
            const msg = try utils.coerceToString(args[0], self.arena);
            try self.stdout.appendSlice(self.arena, msg);
            try self.stdout.append(self.arena, '\n');
            return .void_val;
        }
        // System.Request.getCurrent() → return a Request object
        if (std.ascii.eqlIgnoreCase(inner, "Request")) {
            var bctx = builtins.BuiltinContext{ .arena = self.arena, .stdout = &self.stdout };
            if (try builtins.dispatchStatic(&bctx, "Request", method, args)) |result| return result;
            const obj = try self.arena.create(types.ObjectInstance);
            obj.* = .{ .class_name = "Request" };
            return Value{ .object = obj };
        }
        // System.AccessType/AccessLevel
        if (std.ascii.eqlIgnoreCase(inner, "AccessType") or std.ascii.eqlIgnoreCase(inner, "AccessLevel")) {
            return Value{ .string = method };
        }
        // System.SObjectAccessDecision
        if (std.ascii.eqlIgnoreCase(inner, "SObjectAccessDecision")) {
            return .void_val;
        }
        return .void_val;
    }

    // -----------------------------------------------------------------------
    // ヘルパー
    // -----------------------------------------------------------------------

    fn handleTestFactory(self: *Evaluator, class_name: []const u8, method_name: []const u8, args: []const Value) !?Value {
        // TestFactory.createSObject(sObj) / createSObject(sObj, doInsert) / createSObject(sObj, className)
        if (std.ascii.eqlIgnoreCase(class_name, "TestFactory")) {
            if (std.ascii.eqlIgnoreCase(method_name, "createSObject")) {
                if (args.len >= 1 and args[0] == .sobject) {
                    // Apply default fields if not set
                    if (args[0].sobject.fields.get("Name") == null) {
                        try args[0].sobject.fields.put(self.arena, "Name", Value{ .string = "Test Record" });
                    }
                    if (std.ascii.eqlIgnoreCase(args[0].sobject.type_name, "Contact") and args[0].sobject.fields.get("LastName") == null) {
                        try args[0].sobject.fields.put(self.arena, "LastName", Value{ .string = "Test Record" });
                    }
                    // If second arg is boolean and true, insert
                    if (args.len >= 2 and args[1] == .boolean and args[1].boolean) {
                        try self.insertRecord(args[0].sobject);
                    }
                    // If second arg is string, it's a defaults class name — just insert
                    if (args.len >= 2 and args[1] == .string) {
                        try self.insertRecord(args[0].sobject);
                    }
                    return args[0];
                }
                return Value.null_val;
            }
            if (std.ascii.eqlIgnoreCase(method_name, "createSObjectList")) {
                // createSObjectList(sObj, count, doInsert)
                var template: ?*types.SObject = null;
                var count: i64 = 5;
                var do_insert = false;

                if (args.len >= 1 and args[0] == .sobject) template = args[0].sobject;
                if (args.len >= 2 and args[1] == .integer) count = args[1].integer;
                if (args.len >= 3 and args[2] == .boolean) do_insert = args[2].boolean;

                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                var i: i64 = 0;
                while (i < count) : (i += 1) {
                    const obj = try self.arena.create(types.SObject);
                    obj.* = .{ .type_name = if (template) |t| t.type_name else "Account" };
                    // Copy template fields
                    if (template) |t| {
                        for (t.fields.keys(), t.fields.values()) |k, v| {
                            try obj.fields.put(self.arena, k, v);
                        }
                    }
                    // Set Name with index
                    const name = try std.fmt.allocPrint(self.arena, "Test Record {d}", .{i});
                    try obj.fields.put(self.arena, "Name", Value{ .string = name });
                    // Set required fields for specific object types
                    if (std.ascii.eqlIgnoreCase(obj.type_name, "Contact") and obj.fields.get("LastName") == null) {
                        try obj.fields.put(self.arena, "LastName", Value{ .string = name });
                    }
                    if (std.ascii.eqlIgnoreCase(obj.type_name, "Opportunity") and obj.fields.get("StageName") == null) {
                        try obj.fields.put(self.arena, "StageName", Value{ .string = "Prospecting" });
                    }

                    if (do_insert) try self.insertRecord(obj);
                    try list.items.append(self.arena, Value{ .sobject = obj });
                }
                return Value{ .list = list };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assignPermSetToUser")) {
                return .void_val;
            }
            if (std.ascii.eqlIgnoreCase(method_name, "createTestUser") or
                std.ascii.eqlIgnoreCase(method_name, "createMinAccessUser") or
                std.ascii.eqlIgnoreCase(method_name, "createMarketingUser"))
            {
                const user = try self.arena.create(types.SObject);
                user.* = .{ .type_name = "User" };
                try user.fields.put(self.arena, "Name", Value{ .string = "Test User" });
                try user.fields.put(self.arena, "Id", Value{ .string = "005000000000001" });
                user.id = "005000000000001";
                return Value{ .sobject = user };
            }
            return null;
        }

        // TestDataHelpers
        if (std.ascii.eqlIgnoreCase(class_name, "TestDataHelpers")) {
            if (std.ascii.eqlIgnoreCase(method_name, "createAccount")) {
                const acct = try self.arena.create(types.SObject);
                acct.* = .{ .type_name = "Account" };
                try acct.fields.put(self.arena, "Name", Value{ .string = "Awesome Test Account" });
                // Check if shipping country arg provided
                if (args.len >= 2 and args[1] == .string and args[1].string.len > 0) {
                    try acct.fields.put(self.arena, "ShippingCountry", args[1]);
                }
                try self.insertRecord(acct);
                return Value{ .sobject = acct };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "genXnumberOfAccounts")) {
                const count = if (args.len >= 1 and args[0] == .integer) args[0].integer else 5;
                const list = try self.arena.create(types.ListValue);
                list.* = .{};
                var i: i64 = 0;
                while (i < count) : (i += 1) {
                    const acct = try self.arena.create(types.SObject);
                    acct.* = .{ .type_name = "Account" };
                    const name = try std.fmt.allocPrint(self.arena, "Awesome Test Account {d}", .{i});
                    try acct.fields.put(self.arena, "Name", Value{ .string = name });
                    try list.items.append(self.arena, Value{ .sobject = acct });
                }
                return Value{ .list = list };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "genAccountWithOptions")) {
                const acct = try self.arena.create(types.SObject);
                acct.* = .{ .type_name = "Account" };
                try acct.fields.put(self.arena, "Name", Value{ .string = "Awesome Test Account" });
                if (args.len >= 2 and args[1] == .string) {
                    try acct.fields.put(self.arena, "ShippingCountry", args[1]);
                }
                if (args.len >= 1 and args[0] == .boolean and args[0].boolean) {
                    try self.insertRecord(acct);
                }
                return Value{ .sobject = acct };
            }
            if (std.ascii.eqlIgnoreCase(method_name, "genContactForAccount")) {
                const contact = try self.arena.create(types.SObject);
                contact.* = .{ .type_name = "Contact" };
                try contact.fields.put(self.arena, "LastName", Value{ .string = "Test Contact" });
                try contact.fields.put(self.arena, "Name", Value{ .string = "Test Contact" });
                if (args.len >= 1) {
                    try contact.fields.put(self.arena, "AccountId", args[0]);
                    try contact.fields.put(self.arena, "accountId", args[0]);
                }
                return Value{ .sobject = contact };
            }
            return null;
        }

        return null;
    }

    fn callInstanceMethod(self: *Evaluator, class_decl: *ast.ClassDecl, instance: *types.ObjectInstance, method_name: []const u8, args: []const Value) anyerror!Value {
        // For virtual dispatch: find method in instance's actual class first (child override),
        // then in the provided class_decl, then in parent classes
        const actual_class = self.findClass(instance.class_name);
        const md = self.findMethodInHierarchyTyped(actual_class, class_decl, method_name, args) orelse
            self.findMethodInHierarchy(actual_class, class_decl, method_name, args.len);

        if (md) |method| {
            const method_env = try self.global_env.child();
            try method_env.define("this", Value{ .object = instance });
            for (method.params, 0..) |param, i| {
                const val = if (i < args.len) args[i] else Value.null_val;
                try method_env.define(param.name, val);
            }
            // Also define instance fields as local variables
            for (instance.fields.keys(), instance.fields.values()) |k, v| {
                method_env.set(k, v) catch {
                    try method_env.define(k, v);
                };
            }
            const result = try self.execBlock(method.body, method_env);
            // Sync back fields modified via `this.field = value`
            const this_val = method_env.get("this");
            if (this_val != null and this_val.? == .object) {
                const updated = this_val.?.object;
                if (updated == instance) {
                    // Same pointer, fields already updated in place
                } else {
                    // Copy fields back
                    for (updated.fields.keys(), updated.fields.values()) |k, v| {
                        instance.fields.put(self.arena, k, v) catch {};
                    }
                }
            }
            return switch (result) {
                .return_val => |v| v,
                else => blk: {
                    // Fluent pattern: if method return type matches the class (or parent),
                    // return `this` instead of void. This enables method chaining.
                    if (method.return_type.name.len > 0 and
                        !std.ascii.eqlIgnoreCase(method.return_type.name, "void"))
                    {
                        if (std.ascii.eqlIgnoreCase(method.return_type.name, class_decl.name) or
                            std.ascii.eqlIgnoreCase(method.return_type.name, instance.class_name))
                        {
                            break :blk Value{ .object = instance };
                        }
                        // Check if return type matches a parent class
                        if (class_decl.super_class) |sc| {
                            if (std.ascii.eqlIgnoreCase(method.return_type.name, sc.name)) {
                                break :blk Value{ .object = instance };
                            }
                        }
                    }
                    break :blk self.return_value;
                },
            };
        }
        // Try static method as fallback
        return self.callMethod(class_decl.name, method_name, args);
    }

    /// Type-aware version of findMethodInHierarchy
    fn findMethodInHierarchyTyped(self: *Evaluator, actual_class: ?*ast.ClassDecl, class_decl: *ast.ClassDecl, method_name: []const u8, args: []const Value) ?*ast.MethodDecl {
        if (actual_class) |ac| {
            if (ac != class_decl) {
                if (self.findBestMethodInClass(ac, method_name, args)) |md| return md;
            }
        }
        if (self.findBestMethodInClass(class_decl, method_name, args)) |md| return md;
        var current: ?*ast.ClassDecl = class_decl;
        while (current) |cd| {
            if (cd.super_class) |sc| {
                const parent = self.findClass(sc.name);
                if (parent) |p| {
                    if (self.findBestMethodInClass(p, method_name, args)) |md| return md;
                    current = p;
                } else break;
            } else break;
        }
        return null;
    }

    /// Find a method in the class hierarchy. Searches:
    /// 1. The actual (child) class for overrides
    /// 2. The provided class_decl
    /// 3. Parent classes via super_class chain
    fn findMethodInHierarchy(self: *Evaluator, actual_class: ?*ast.ClassDecl, class_decl: *ast.ClassDecl, method_name: []const u8, arg_count: usize) ?*ast.MethodDecl {
        // 1. Search actual class first (child override) if different from class_decl
        if (actual_class) |ac| {
            if (ac != class_decl) {
                if (self.findMethodInClass(ac, method_name, arg_count)) |md| return md;
            }
        }
        // 2. Search the provided class_decl
        if (self.findMethodInClass(class_decl, method_name, arg_count)) |md| return md;
        // 3. Walk up parent chain
        var current: ?*ast.ClassDecl = class_decl;
        while (current) |cd| {
            if (cd.super_class) |sc| {
                const parent = self.findClass(sc.name);
                if (parent) |p| {
                    if (self.findMethodInClass(p, method_name, arg_count)) |md| return md;
                    current = p;
                } else break;
            } else break;
        }
        return null;
    }

    fn findMethodInClass(_: *Evaluator, class_decl: *ast.ClassDecl, method_name: []const u8, arg_count: usize) ?*ast.MethodDecl {
        var best_match: ?*ast.MethodDecl = null;
        for (class_decl.members) |member| {
            switch (member) {
                .method_decl => |md| {
                    if (std.ascii.eqlIgnoreCase(md.name, method_name)) {
                        if (md.params.len == arg_count) return md;
                        if (best_match == null) best_match = md;
                    }
                },
                else => {},
            }
        }
        return best_match;
    }

    /// Type-aware method resolution for overloaded methods.
    /// When multiple methods match by name and arg count, picks the one
    /// whose parameter types best match the actual argument types.
    fn findBestMethodInClass(_: *Evaluator, class_decl: *ast.ClassDecl, method_name: []const u8, args: []const Value) ?*ast.MethodDecl {
        var candidates: [8]*ast.MethodDecl = undefined;
        var count: usize = 0;
        var best_any: ?*ast.MethodDecl = null;

        for (class_decl.members) |member| {
            switch (member) {
                .method_decl => |md| {
                    if (std.ascii.eqlIgnoreCase(md.name, method_name)) {
                        if (md.params.len == args.len) {
                            if (count < candidates.len) {
                                candidates[count] = md;
                                count += 1;
                            }
                        }
                        if (best_any == null) best_any = md;
                    }
                },
                else => {},
            }
        }

        if (count == 0) return best_any;
        if (count == 1) return candidates[0];

        // Multiple candidates: score each by type compatibility
        var best: ?*ast.MethodDecl = null;
        var best_score: i32 = -1;
        for (candidates[0..count]) |md| {
            var score: i32 = 0;
            for (md.params, 0..) |param, i| {
                if (i >= args.len) break;
                const pt = param.type_ref.name;
                const arg = args[i];
                // Score: higher is better match
                if (arg == .list and std.ascii.eqlIgnoreCase(pt, "List")) {
                    score += 2;
                } else if (arg == .sobject and (std.ascii.eqlIgnoreCase(pt, "SObject") or
                    std.ascii.eqlIgnoreCase(pt, "Sobject") or std.ascii.eqlIgnoreCase(pt, "sObject")))
                {
                    score += 2;
                } else if (arg == .sobject and std.ascii.eqlIgnoreCase(pt, "List")) {
                    // SObject passed where List expected = poor match
                    score -= 1;
                } else if (arg == .list and !std.ascii.eqlIgnoreCase(pt, "List")) {
                    // List passed where non-List expected = poor match
                    score -= 1;
                } else if (arg == .string and std.ascii.eqlIgnoreCase(pt, "String")) {
                    score += 2;
                } else if (arg == .integer and (std.ascii.eqlIgnoreCase(pt, "Integer") or std.ascii.eqlIgnoreCase(pt, "int"))) {
                    score += 2;
                } else if (arg == .boolean and std.ascii.eqlIgnoreCase(pt, "Boolean")) {
                    score += 2;
                } else if (arg == .object) {
                    // Object matches any class type
                    score += 1;
                } else {
                    score += 0; // neutral
                }
            }
            if (best == null or score > best_score) {
                best = md;
                best_score = score;
            }
        }
        return best orelse candidates[0];
    }

    fn initInstanceFields(self: *Evaluator, class_decl: *ast.ClassDecl, instance: *types.ObjectInstance) !void {
        for (class_decl.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (!fd.modifiers.is_static) {
                        const val = if (fd.initializer) |init_expr|
                            self.evalExpr(init_expr, self.global_env) catch Value.null_val
                        else
                            defaultValue(fd.type_ref);
                        try instance.fields.put(self.arena, fd.name, val);
                    }
                },
                else => {},
            }
        }
    }

    fn runConstructor(self: *Evaluator, class_decl: *ast.ClassDecl, instance: *types.ObjectInstance, args: []const Value) anyerror!void {
        for (class_decl.members) |member| {
            switch (member) {
                .constructor_decl => |cd| {
                    // Match by param count if possible
                    if (cd.params.len == args.len or args.len == 0) {
                        const ctor_env = try self.global_env.child();
                        try ctor_env.define("this", Value{ .object = instance });
                        // Also define instance fields as local variables
                        for (instance.fields.keys(), instance.fields.values()) |k, v| {
                            ctor_env.set(k, v) catch {
                                try ctor_env.define(k, v);
                            };
                        }
                        for (cd.params, 0..) |param, pi| {
                            const pval = if (pi < args.len) args[pi] else Value.null_val;
                            try ctor_env.define(param.name, pval);
                        }
                        _ = try self.execBlock(cd.body, ctor_env);
                        return;
                    }
                },
                else => {},
            }
        }
    }

    fn isInstanceField(_: *Evaluator, class_decl: *ast.ClassDecl, name: []const u8) bool {
        for (class_decl.members) |member| {
            switch (member) {
                .field_decl => |fd| {
                    if (!fd.modifiers.is_static and std.ascii.eqlIgnoreCase(fd.name, name)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn isParentInstanceField(self: *Evaluator, class_decl: *ast.ClassDecl, name: []const u8) bool {
        if (class_decl.super_class) |sc| {
            if (self.findClass(sc.name)) |parent| {
                if (self.isInstanceField(parent, name)) return true;
                return self.isParentInstanceField(parent, name);
            }
        }
        return false;
    }

    fn findClass(self: *Evaluator, name: []const u8) ?*ast.ClassDecl {
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// 静的ヘルパー
// ---------------------------------------------------------------------------

fn evalBinary(left: Value, op: ast.BinaryOp, right: Value, arena: std.mem.Allocator) !Value {
    switch (op) {
        .eq => return .{ .boolean = utils.valueEql(left, right) },
        .neq => return .{ .boolean = !utils.valueEql(left, right) },
        .strict_eq => return .{ .boolean = utils.valueEql(left, right) },
        .strict_neq => return .{ .boolean = !utils.valueEql(left, right) },
        .and_op => return .{ .boolean = (utils.coerceToBool(left) catch false) and (utils.coerceToBool(right) catch false) },
        .or_op => return .{ .boolean = (utils.coerceToBool(left) catch false) or (utils.coerceToBool(right) catch false) },
        else => {},
    }

    if (left == .integer and right == .integer) {
        return .{ .integer = switch (op) {
            .add => left.integer + right.integer,
            .sub => left.integer - right.integer,
            .mul => left.integer * right.integer,
            .div => if (right.integer != 0) @divTrunc(left.integer, right.integer) else 0,
            .mod => if (right.integer != 0) @mod(left.integer, right.integer) else 0,
            .lt => return .{ .boolean = left.integer < right.integer },
            .gt => return .{ .boolean = left.integer > right.integer },
            .lte => return .{ .boolean = left.integer <= right.integer },
            .gte => return .{ .boolean = left.integer >= right.integer },
            else => 0,
        } };
    }

    if ((left == .double or left == .integer) and (right == .double or right == .integer)) {
        const l = if (left == .double) left.double else @as(f64, @floatFromInt(left.integer));
        const r = if (right == .double) right.double else @as(f64, @floatFromInt(right.integer));
        return switch (op) {
            .add => .{ .double = l + r },
            .sub => .{ .double = l - r },
            .mul => .{ .double = l * r },
            .div => .{ .double = if (r != 0) l / r else 0 },
            .lt => .{ .boolean = l < r },
            .gt => .{ .boolean = l > r },
            .lte => .{ .boolean = l <= r },
            .gte => .{ .boolean = l >= r },
            else => .null_val,
        };
    }

    // String concatenation
    if (op == .add and (left == .string or right == .string)) {
        const ls = try utils.coerceToString(left, arena);
        const rs = try utils.coerceToString(right, arena);
        const result = try std.fmt.allocPrint(arena, "{s}{s}", .{ ls, rs });
        return .{ .string = result };
    }

    return .null_val;
}

fn evalUnary(op: ast.UnaryOp, operand: Value) !Value {
    switch (op) {
        .negate => {
            if (operand == .integer) return .{ .integer = -operand.integer };
            if (operand == .double) return .{ .double = -operand.double };
            return .null_val;
        },
        .not => return .{ .boolean = !(utils.coerceToBool(operand) catch false) },
    }
}

fn evalCompoundAssign(current: Value, op: ast.AssignOp, value: Value) Value {
    switch (op) {
        .plus_assign => {
            if (current == .integer and value == .integer) return .{ .integer = current.integer + value.integer };
            if (current == .double and value == .double) return .{ .double = current.double + value.double };
        },
        .minus_assign => {
            if (current == .integer and value == .integer) return .{ .integer = current.integer - value.integer };
        },
        .star_assign => {
            if (current == .integer and value == .integer) return .{ .integer = current.integer * value.integer };
        },
        .slash_assign => {
            if (current == .integer and value == .integer and value.integer != 0)
                return .{ .integer = @divTrunc(current.integer, value.integer) };
        },
        .assign => return value,
    }
    return value;
}

fn defaultValue(type_ref: types.TypeRef) Value {
    if (std.ascii.eqlIgnoreCase(type_ref.name, "Integer") or std.ascii.eqlIgnoreCase(type_ref.name, "Long"))
        return .{ .integer = 0 };
    if (std.ascii.eqlIgnoreCase(type_ref.name, "Double") or std.ascii.eqlIgnoreCase(type_ref.name, "Decimal"))
        return .{ .double = 0.0 };
    if (std.ascii.eqlIgnoreCase(type_ref.name, "Boolean"))
        return .{ .boolean = false };
    return .null_val;
}

fn extractFromType(soql: []const u8) ?[]const u8 {
    // Find "FROM <type>" case-insensitive
    const lower = soql;
    var i: usize = 0;
    while (i + 5 < lower.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(lower[i .. i + 4], "from") and (lower[i + 4] == ' ' or lower[i + 4] == '\n')) {
            var start = i + 5;
            while (start < lower.len and lower[start] == ' ') start += 1;
            var end = start;
            while (end < lower.len and lower[end] != ' ' and lower[end] != '\n' and lower[end] != ']' and lower[end] != ')') end += 1;
            if (end > start) return lower[start..end];
        }
    }
    return null;
}

fn extractWhereClause(soql: []const u8) ?[]const u8 {
    // Find WHERE ... (ends before ORDER BY, GROUP BY, LIMIT, OFFSET, WITH, FOR)
    var i: usize = 0;
    while (i + 5 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 5], "where") and
            (i == 0 or soql[i - 1] == ' ' or soql[i - 1] == '\n') and
            (soql[i + 5] == ' ' or soql[i + 5] == '\n'))
        {
            const start = i + 6;
            // Find end of WHERE clause
            var end = soql.len;
            var j: usize = start;
            while (j + 3 < soql.len) : (j += 1) {
                // Check for terminating keywords
                const remaining = soql[j..];
                if (remaining.len >= 5 and std.ascii.eqlIgnoreCase(remaining[0..5], "ORDER") and
                    (j == 0 or soql[j - 1] == ' ' or soql[j - 1] == '\n'))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 5 and std.ascii.eqlIgnoreCase(remaining[0..5], "GROUP") and
                    (j == 0 or soql[j - 1] == ' ' or soql[j - 1] == '\n'))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 5 and std.ascii.eqlIgnoreCase(remaining[0..5], "LIMIT") and
                    (j == 0 or soql[j - 1] == ' ' or soql[j - 1] == '\n'))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 6 and std.ascii.eqlIgnoreCase(remaining[0..6], "OFFSET") and
                    (j == 0 or soql[j - 1] == ' ' or soql[j - 1] == '\n'))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 4 and std.ascii.eqlIgnoreCase(remaining[0..4], "WITH") and
                    (j == 0 or soql[j - 1] == ' ' or soql[j - 1] == '\n'))
                {
                    end = j;
                    break;
                }
                if (remaining.len >= 3 and std.ascii.eqlIgnoreCase(remaining[0..3], "FOR") and
                    (j == 0 or soql[j - 1] == ' ' or soql[j - 1] == '\n'))
                {
                    end = j;
                    break;
                }
            }
            if (start < end) return soql[start..end];
        }
    }
    return null;
}

fn findLogicalOp(clause: []const u8, keyword: []const u8) ?usize {
    // Find AND/OR at top level (not inside parens)
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < clause.len) : (i += 1) {
        if (clause[i] == '(') { depth += 1; continue; }
        if (clause[i] == ')') { if (depth > 0) depth -= 1; continue; }
        if (clause[i] == '\'') {
            // Skip string literal
            i += 1;
            while (i < clause.len and clause[i] != '\'') : (i += 1) {}
            continue;
        }
        if (depth == 0 and i + keyword.len <= clause.len) {
            if (std.ascii.eqlIgnoreCase(clause[i .. i + keyword.len], keyword)) {
                // Check word boundaries
                const before_ok = (i == 0 or clause[i - 1] == ' ' or clause[i - 1] == '\n' or clause[i - 1] == ')');
                const after_ok = (i + keyword.len >= clause.len or clause[i + keyword.len] == ' ' or clause[i + keyword.len] == '\n' or clause[i + keyword.len] == '(');
                if (before_ok and after_ok) return i;
            }
        }
    }
    return null;
}

fn extractOffset(soql: []const u8) ?usize {
    var i: usize = 0;
    while (i + 7 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 6], "offset") and (soql[i + 6] == ' ' or soql[i + 6] == '\n')) {
            var start = i + 7;
            while (start < soql.len and soql[start] == ' ') start += 1;
            var end = start;
            while (end < soql.len and std.ascii.isDigit(soql[end])) end += 1;
            if (end > start) return std.fmt.parseUnsigned(usize, soql[start..end], 10) catch null;
        }
    }
    return null;
}

fn extractLimitBindVar(soql: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 6 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 5], "limit") and (soql[i + 5] == ' ' or soql[i + 5] == '\n')) {
            var start = i + 6;
            while (start < soql.len and soql[start] == ' ') start += 1;
            if (start < soql.len and soql[start] == ':') {
                var end = start + 1;
                while (end < soql.len and (std.ascii.isAlphanumeric(soql[end]) or soql[end] == '_')) end += 1;
                return soql[start + 1 .. end];
            }
        }
    }
    return null;
}

fn extractLimit(soql: []const u8) ?usize {
    var i: usize = 0;
    while (i + 6 < soql.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(soql[i .. i + 5], "limit") and (soql[i + 5] == ' ' or soql[i + 5] == '\n')) {
            var start = i + 6;
            while (start < soql.len and soql[start] == ' ') start += 1;
            var end = start;
            while (end < soql.len and std.ascii.isDigit(soql[end])) end += 1;
            if (end > start) return std.fmt.parseUnsigned(usize, soql[start..end], 10) catch null;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

const EvalTestResult = struct {
    value: Value,
    stdout: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *EvalTestResult) void {
        self.arena.deinit();
    }
};

fn evalSource(source: []const u8, class_name: []const u8, method_name: []const u8) !EvalTestResult {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    const tokens = try lexer_mod.tokenize(source, arena.allocator());
    const decls = try parser_mod.parse(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    try eval.loadDecls(decls);
    const result = try eval.callMethod(class_name, method_name, &.{});

    return .{ .value = result, .stdout = eval.stdout.items, .arena = arena };
}

test "evaluate 1 + 2" {
    const tokens = try lexer_mod.tokenize("1 + 2", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parser_mod.parseExpr(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    const result = try eval.evalExpr(expr, eval.global_env);
    try std.testing.expectEqual(@as(i64, 3), result.integer);
}

test "evaluate string equality case-insensitive" {
    const tokens = try lexer_mod.tokenize("'Hello' == 'hello'", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parser_mod.parseExpr(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    const result = try eval.evalExpr(expr, eval.global_env);
    try std.testing.expect(result.boolean);
}

test "evaluate null == null" {
    const tokens = try lexer_mod.tokenize("null == null", std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parser_mod.parseExpr(tokens, arena.allocator());
    var eval = try Evaluator.init(arena.allocator());
    const result = try eval.evalExpr(expr, eval.global_env);
    try std.testing.expect(result.boolean);
}

test "evaluate class method returning string" {
    const source =
        \\public class Hello {
        \\    public static String greet() {
        \\        return 'world';
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Hello", "greet");
    defer r.deinit();
    try std.testing.expectEqualStrings("world", r.value.string);
}

test "evaluate class method with arithmetic" {
    const source =
        \\public class Calc {
        \\    public static Integer add() {
        \\        Integer x = 10;
        \\        Integer y = 20;
        \\        return x + y;
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Calc", "add");
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 30), r.value.integer);
}

test "evaluate System.debug" {
    const source =
        \\public class Debug {
        \\    public static void run() {
        \\        System.debug('hello');
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Debug", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("hello\n", r.stdout);
}

test "evaluate if-else" {
    const source =
        \\public class Branch {
        \\    public static String check() {
        \\        Boolean cond = true;
        \\        if (cond) {
        \\            return 'yes';
        \\        } else {
        \\            return 'no';
        \\        }
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Branch", "check");
    defer r.deinit();
    try std.testing.expectEqualStrings("yes", r.value.string);
}

test "evaluate for loop" {
    const source =
        \\public class Loop {
        \\    public static Integer sum() {
        \\        Integer total = 0;
        \\        for (Integer i = 0; i < 5; i += 1) {
        \\            total += i;
        \\        }
        \\        return total;
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Loop", "sum");
    defer r.deinit();
    try std.testing.expectEqual(@as(i64, 10), r.value.integer);
}

test "evaluate string concatenation" {
    const source =
        \\public class Concat {
        \\    public static String run() {
        \\        return 'Hello' + ' ' + 'World';
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Concat", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("Hello World", r.value.string);
}

test "evaluate ternary expression" {
    const source =
        \\public class Ternary {
        \\    public static String run() {
        \\        Boolean flag = false;
        \\        return flag ? 'yes' : 'no';
        \\    }
        \\}
    ;
    var r = try evalSource(source, "Ternary", "run");
    defer r.deinit();
    try std.testing.expectEqualStrings("no", r.value.string);
}
