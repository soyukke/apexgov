const std = @import("std");

pub const Options = struct {
    input_paths: []const []const u8,
    out_dir: []const u8,
    package_name: []const u8 = "generated",
    overwrite: bool = false,
    strict: bool = false,
};

pub const Summary = struct {
    files_scanned: usize = 0,
    files_generated: usize = 0,
    methods_generated: usize = 0,
    unsupported_statements: usize = 0,
};

const ApexFile = struct {
    path: []u8,
    content: []u8,
};

const ParsedMethod = struct {
    name: []u8,
    java_return_type: []u8,
    java_parameters: []u8,
    is_static: bool,
    is_constructor: bool,
    is_test: bool,
    body: []u8,
};

const ParsedField = struct {
    declaration: []u8,
};

const ParsedClass = struct {
    class_name: []u8,
    source_path: []u8,
    fields: std.ArrayList(ParsedField) = .empty,
    methods: std.ArrayList(ParsedMethod) = .empty,

    fn deinit(self: *ParsedClass, gpa: std.mem.Allocator) void {
        gpa.free(self.class_name);
        gpa.free(self.source_path);
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

const MethodSignature = struct {
    name: []u8,
    java_return_type: []u8,
    java_parameters: []u8,
    is_static: bool,
    is_constructor: bool,
};

const SwitchMode = enum {
    value,
    typed,
};

const ActiveSwitchContext = struct {
    body_depth: i32,
    subject_expr: []u8,
    mode: SwitchMode,
};

const RenderedClass = struct {
    java: []u8,
    unsupported_statements: usize,
};

pub fn run(gpa: std.mem.Allocator, opts: Options) !Summary {
    if (opts.input_paths.len == 0) return error.MissingInputPath;

    var files = try collectApexFiles(gpa, opts.input_paths);
    defer deinitApexFiles(gpa, &files);

    if (files.items.len == 0) return error.NoApexClassSourceFound;
    if (!isValidPackageName(opts.package_name)) return error.InvalidPackageName;

    try std.fs.cwd().makePath(opts.out_dir);

    var summary = Summary{
        .files_scanned = files.items.len,
    };

    for (files.items) |file| {
        var parsed = try parseApexClass(gpa, file.path, file.content);
        defer parsed.deinit(gpa);

        const rendered = try renderJavaClass(gpa, parsed, opts.package_name);
        defer gpa.free(rendered.java);

        if (opts.strict and rendered.unsupported_statements > 0) {
            return error.UnsupportedApexSyntax;
        }

        const output_name = try std.fmt.allocPrint(gpa, "{s}.java", .{parsed.class_name});
        defer gpa.free(output_name);

        const output_path = try std.fs.path.join(gpa, &.{ opts.out_dir, output_name });
        defer gpa.free(output_path);

        if (!opts.overwrite and pathExists(output_path)) {
            return error.OutputAlreadyExists;
        }

        try writeOutputFile(output_path, rendered.java);

        summary.files_generated += 1;
        summary.methods_generated += parsed.methods.items.len;
        summary.unsupported_statements += rendered.unsupported_statements;
    }

    return summary;
}

fn collectApexFiles(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(ApexFile) {
    var files: std.ArrayList(ApexFile) = .empty;
    errdefer deinitApexFiles(gpa, &files);

    for (roots) |root| {
        try collectPath(gpa, root, &files);
    }
    return files;
}

fn collectPath(gpa: std.mem.Allocator, path: []const u8, files: *std.ArrayList(ApexFile)) !void {
    collectDirectory(gpa, path, files) catch |err| switch (err) {
        error.NotDir => {
            if (isApexClassSource(path)) {
                try appendApexFile(gpa, files, path);
            }
        },
        else => return err,
    };
}

fn collectDirectory(gpa: std.mem.Allocator, root: []const u8, files: *std.ArrayList(ApexFile)) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isApexClassSource(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        defer gpa.free(joined);
        try appendApexFile(gpa, files, joined);
    }
}

fn appendApexFile(gpa: std.mem.Allocator, files: *std.ArrayList(ApexFile), path: []const u8) !void {
    const content = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    errdefer gpa.free(content);

    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    try files.append(gpa, .{
        .path = path_copy,
        .content = content,
    });
}

fn deinitApexFiles(gpa: std.mem.Allocator, files: *std.ArrayList(ApexFile)) void {
    for (files.items) |file| {
        gpa.free(file.path);
        gpa.free(file.content);
    }
    files.deinit(gpa);
}

fn parseApexClass(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) !ParsedClass {
    const class_name = try parseClassName(gpa, source_path, content);
    errdefer gpa.free(class_name);
    const class_is_test = detectClassIsTest(content);

    var parsed = ParsedClass{
        .class_name = class_name,
        .source_path = try gpa.dupe(u8, source_path),
    };
    errdefer parsed.deinit(gpa);

    var pending_test_annotation = false;
    var in_method = false;
    var brace_depth: i32 = 0;
    var current_signature: MethodSignature = undefined;
    var current_is_test = false;
    var current_body: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (!in_method) {
            if (isIsTestAnnotation(trimmed)) {
                pending_test_annotation = true;
                continue;
            }

            if (try parseMethodSignature(gpa, trimmed, parsed.class_name)) |signature| {
                in_method = true;
                brace_depth = braceDelta(line);
                current_signature = signature;
                current_is_test = pending_test_annotation or class_is_test or containsWordIgnoreCase(trimmed, "testMethod");
                current_body = .empty;
                pending_test_annotation = false;

                if (std.mem.indexOfScalar(u8, line, '{')) |brace_idx| {
                    var tail = std.mem.trim(u8, line[(brace_idx + 1)..], " \t");
                    if (tail.len > 0 and tail[tail.len - 1] == '}') {
                        tail = std.mem.trimRight(u8, tail[0 .. tail.len - 1], " \t");
                    }
                    if (tail.len > 0) {
                        try current_body.appendSlice(gpa, tail);
                        try current_body.append(gpa, '\n');
                    }
                }

                if (brace_depth <= 0) {
                    const body = try current_body.toOwnedSlice(gpa);
                    try parsed.methods.append(gpa, .{
                        .name = current_signature.name,
                        .java_return_type = current_signature.java_return_type,
                        .java_parameters = current_signature.java_parameters,
                        .is_static = current_signature.is_static,
                        .is_constructor = current_signature.is_constructor,
                        .is_test = current_is_test,
                        .body = body,
                    });
                    in_method = false;
                }
                continue;
            }

            if (try parseConstructorSignature(gpa, trimmed, parsed.class_name)) |signature| {
                in_method = true;
                brace_depth = braceDelta(line);
                current_signature = signature;
                current_is_test = pending_test_annotation or class_is_test or containsWordIgnoreCase(trimmed, "testMethod");
                current_body = .empty;
                pending_test_annotation = false;

                if (std.mem.indexOfScalar(u8, line, '{')) |brace_idx| {
                    var tail = std.mem.trim(u8, line[(brace_idx + 1)..], " \t");
                    if (tail.len > 0 and tail[tail.len - 1] == '}') {
                        tail = std.mem.trimRight(u8, tail[0 .. tail.len - 1], " \t");
                    }
                    if (tail.len > 0) {
                        try current_body.appendSlice(gpa, tail);
                        try current_body.append(gpa, '\n');
                    }
                }

                if (brace_depth <= 0) {
                    const body = try current_body.toOwnedSlice(gpa);
                    try parsed.methods.append(gpa, .{
                        .name = current_signature.name,
                        .java_return_type = current_signature.java_return_type,
                        .java_parameters = current_signature.java_parameters,
                        .is_static = current_signature.is_static,
                        .is_constructor = current_signature.is_constructor,
                        .is_test = current_is_test,
                        .body = body,
                    });
                    in_method = false;
                }
                continue;
            }

            if (try transpileClassMemberLine(gpa, trimmed)) |declaration| {
                try parsed.fields.append(gpa, .{ .declaration = declaration });
                pending_test_annotation = false;
                continue;
            }

            if (trimmed.len > 0 and trimmed[0] != '@') {
                pending_test_annotation = false;
            }
            continue;
        }

        try current_body.appendSlice(gpa, line);
        try current_body.append(gpa, '\n');
        brace_depth += braceDelta(line);
        if (brace_depth > 0) continue;

        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_signature.name,
            .java_return_type = current_signature.java_return_type,
            .java_parameters = current_signature.java_parameters,
            .is_static = current_signature.is_static,
            .is_constructor = current_signature.is_constructor,
            .is_test = current_is_test,
            .body = body,
        });
        in_method = false;
    }

    if (in_method) {
        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_signature.name,
            .java_return_type = current_signature.java_return_type,
            .java_parameters = current_signature.java_parameters,
            .is_static = current_signature.is_static,
            .is_constructor = current_signature.is_constructor,
            .is_test = current_is_test,
            .body = body,
        });
    }

    return parsed;
}

fn parseClassName(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (indexOfWordIgnoreCase(trimmed, "class")) |class_pos| {
            const after = std.mem.trimLeft(u8, trimmed[(class_pos + 5)..], " \t");
            if (leadingIdentifier(after)) |name| {
                return gpa.dupe(u8, name);
            }
        }
    }

    const base = std.fs.path.basename(source_path);
    const stem = std.fs.path.stem(base);
    if (stem.len == 0) return error.InvalidClassName;
    return gpa.dupe(u8, stem);
}

fn detectClassIsTest(content: []const u8) bool {
    var pending_annotation = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (isIsTestAnnotation(trimmed)) {
            pending_annotation = true;
            continue;
        }

        if (containsWordIgnoreCase(trimmed, "class")) {
            return pending_annotation;
        }

        if (trimmed[0] != '@') {
            pending_annotation = false;
        }
    }
    return false;
}

fn parseMethodSignature(gpa: std.mem.Allocator, line: []const u8, class_name: []const u8) !?MethodSignature {
    if (line.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, ")")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "{")) return null;
    if (line[line.len - 1] == ';') return null;
    if (containsWordIgnoreCase(line, "class")) return null;

    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, line[0..open_paren], '=')) |_| return null;

    const prefix = std.mem.trim(u8, line[0..open_paren], " \t");
    if (prefix.len == 0) return null;

    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return null;
    }

    const candidate = lastIdentifier(prefix) orelse return null;
    if (isControlKeyword(candidate)) return null;
    if (std.mem.eql(u8, candidate, class_name)) return null;

    var tokens = try splitWhitespace(gpa, prefix);
    defer tokens.deinit(gpa);
    if (tokens.items.len < 2) return null;

    const name_token = tokens.items[tokens.items.len - 1];
    if (!std.mem.eql(u8, name_token, candidate)) return null;
    if (tokens.items.len < 2) return null;

    const name_pos = std.mem.lastIndexOf(u8, prefix, candidate) orelse return null;
    const before_name = std.mem.trimRight(u8, prefix[0..name_pos], " \t");
    if (before_name.len == 0) return null;

    var before_tokens = try splitWhitespace(gpa, before_name);
    defer before_tokens.deinit(gpa);
    if (before_tokens.items.len == 0) return null;

    var return_raw: std.ArrayList(u8) = .empty;
    errdefer return_raw.deinit(gpa);

    var is_static = false;
    for (before_tokens.items) |token| {
        if (isMethodModifierToken(token)) {
            if (std.ascii.eqlIgnoreCase(token, "static")) is_static = true;
            continue;
        }
        if (return_raw.items.len != 0) try return_raw.append(gpa, ' ');
        try return_raw.appendSlice(gpa, token);
    }
    if (return_raw.items.len == 0) return null;

    const return_type_raw = try return_raw.toOwnedSlice(gpa);
    defer gpa.free(return_type_raw);

    const java_return_type = try convertApexType(gpa, return_type_raw);
    errdefer gpa.free(java_return_type);

    const close_paren = findMatchingParen(line, open_paren) orelse return null;
    const param_segment = std.mem.trim(u8, line[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    errdefer gpa.free(java_parameters);

    return .{
        .name = try gpa.dupe(u8, candidate),
        .java_return_type = java_return_type,
        .java_parameters = java_parameters,
        .is_static = is_static,
        .is_constructor = false,
    };
}

fn parseConstructorSignature(gpa: std.mem.Allocator, line: []const u8, class_name: []const u8) !?MethodSignature {
    if (line.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, ")")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "{")) return null;
    if (line[line.len - 1] == ';') return null;
    if (containsWordIgnoreCase(line, "class")) return null;

    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, line[0..open_paren], '=')) |_| return null;

    const prefix = std.mem.trim(u8, line[0..open_paren], " \t");
    if (prefix.len == 0) return null;

    const candidate = lastIdentifier(prefix) orelse return null;
    if (!std.mem.eql(u8, candidate, class_name)) return null;

    var tokens = try splitWhitespace(gpa, prefix);
    defer tokens.deinit(gpa);
    if (tokens.items.len == 0) return null;

    for (tokens.items[0 .. tokens.items.len - 1]) |token| {
        if (!isMethodModifierToken(token)) return null;
    }

    const close_paren = findMatchingParen(line, open_paren) orelse return null;
    const param_segment = std.mem.trim(u8, line[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    errdefer gpa.free(java_parameters);

    return .{
        .name = try gpa.dupe(u8, class_name),
        .java_return_type = try gpa.dupe(u8, ""),
        .java_parameters = java_parameters,
        .is_static = false,
        .is_constructor = true,
    };
}

fn convertMethodParameters(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return gpa.dupe(u8, "");

    var params = try splitTypeArguments(gpa, trimmed);
    defer params.deinit(gpa);
    if (params.items.len == 0) return gpa.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (params.items, 0..) |param, idx| {
        var part = std.mem.trim(u8, param, " \t");
        if (part.len == 0) continue;
        if (startsWithIgnoreCase(part, "final ")) {
            part = std.mem.trimLeft(u8, part["final".len..], " \t");
        }
        const param_name = lastIdentifier(part) orelse continue;
        const type_segment = std.mem.trimRight(u8, part[0..(part.len - param_name.len)], " \t");
        if (type_segment.len == 0) continue;

        const java_type = try convertApexType(gpa, type_segment);
        defer gpa.free(java_type);

        if (idx != 0) try out.appendSlice(gpa, ", ");
        try appendFmt(gpa, &out, "{s} {s}", .{ java_type, param_name });
    }

    return try out.toOwnedSlice(gpa);
}

fn transpileClassMemberLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (isIsTestAnnotation(trimmed)) return null;
    if (indexOfWordIgnoreCase(trimmed, "class") != null and std.mem.indexOfScalar(u8, trimmed, '{') != null) return null;
    if (std.mem.eql(u8, trimmed, "{") or std.mem.eql(u8, trimmed, "}")) return null;

    if (try transpilePropertyDeclarationLine(gpa, trimmed)) |property_line| {
        return property_line;
    }

    if (trimmed[trimmed.len - 1] != ';') return null;
    const without_semicolon = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    if (without_semicolon.len == 0) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "return")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "insert")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "update")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "upsert")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "delete")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "undelete")) return null;

    return transpileTypedDeclarationLine(gpa, without_semicolon, true);
}

fn transpilePropertyDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const open_brace = std.mem.indexOfScalar(u8, line, '{') orelse return null;
    const close_brace = std.mem.lastIndexOfScalar(u8, line, '}') orelse return null;
    if (close_brace <= open_brace) return null;

    const body = std.mem.trim(u8, line[(open_brace + 1)..close_brace], " \t");
    if (!containsWordIgnoreCase(body, "get") or !containsWordIgnoreCase(body, "set")) return null;

    const head = std.mem.trim(u8, line[0..open_brace], " \t");
    if (head.len == 0) return null;
    const declaration = (try transpileTypedDeclarationLine(gpa, head, true)) orelse return null;
    defer gpa.free(declaration);
    const with_comment = try std.fmt.allocPrint(gpa, "{s} // Apex property {{ get; set; }}", .{declaration});
    return with_comment;
}

fn transpileTypedDeclarationLine(gpa: std.mem.Allocator, line: []const u8, allow_visibility: bool) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |_| {
        if (startsWithWordIgnoreCase(trimmed, "for")) return null;
    }

    const eq_pos = findTopLevelAssignmentOperator(trimmed);
    const left = std.mem.trim(u8, if (eq_pos) |pos| trimmed[0..pos] else trimmed, " \t");
    if (left.len == 0) return null;
    if (std.mem.indexOfScalar(u8, left, '.')) |_| return null;

    var tokens = try splitWhitespace(gpa, left);
    defer tokens.deinit(gpa);
    if (tokens.items.len < 2) return null;

    const name = tokens.items[tokens.items.len - 1];
    if (!isSimpleIdentifier(name)) return null;

    var modifier_out: std.ArrayList(u8) = .empty;
    defer modifier_out.deinit(gpa);

    var type_index: usize = 0;
    while (type_index + 1 < tokens.items.len and isDeclarationModifier(tokens.items[type_index], allow_visibility)) : (type_index += 1) {
        if (modifier_out.items.len > 0) try modifier_out.append(gpa, ' ');
        try modifier_out.appendSlice(gpa, normalizeDeclarationModifier(tokens.items[type_index]));
    }
    if (type_index >= tokens.items.len - 1) return null;

    var type_raw_buf: std.ArrayList(u8) = .empty;
    defer type_raw_buf.deinit(gpa);
    for (tokens.items[type_index .. tokens.items.len - 1], 0..) |part, idx| {
        if (idx != 0) try type_raw_buf.append(gpa, ' ');
        try type_raw_buf.appendSlice(gpa, part);
    }
    const type_raw = try type_raw_buf.toOwnedSlice(gpa);
    defer gpa.free(type_raw);
    if (!looksLikeTypeName(type_raw)) return null;

    const java_type = try convertApexType(gpa, type_raw);
    defer gpa.free(java_type);

    const has_initializer = eq_pos != null;
    if (!has_initializer) {
        if (modifier_out.items.len == 0) {
            return try std.fmt.allocPrint(gpa, "{s} {s};", .{ java_type, name });
        }
        return try std.fmt.allocPrint(gpa, "{s} {s} {s};", .{ modifier_out.items, java_type, name });
    }

    const rhs = std.mem.trim(u8, trimmed[(eq_pos.? + 1)..], " \t");
    if (rhs.len == 0) return null;
    const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
    defer gpa.free(converted_rhs);

    if (modifier_out.items.len == 0) {
        return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ java_type, name, converted_rhs });
    }
    return try std.fmt.allocPrint(gpa, "{s} {s} {s} = {s};", .{ modifier_out.items, java_type, name, converted_rhs });
}

fn renderJavaClass(gpa: std.mem.Allocator, parsed: ParsedClass, package_name: []const u8) !RenderedClass {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var unsupported_statements: usize = 0;

    var method_name_counts = std.StringHashMap(usize).init(gpa);
    defer method_name_counts.deinit();

    try appendFmt(gpa, &out, "package {s};\n\n", .{package_name});
    try out.appendSlice(gpa, "import apexemu.annotations.Test;\n\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexSObject;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexCollections;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexSwitch;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexStrings;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexAssert;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Database;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.JSON;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.SystemAssert;\n\n");
    try out.appendSlice(gpa, "import java.util.ArrayList;\n");
    try out.appendSlice(gpa, "import java.util.LinkedHashMap;\n");
    try out.appendSlice(gpa, "import java.util.LinkedHashSet;\n");
    try out.appendSlice(gpa, "import java.util.List;\n");
    try out.appendSlice(gpa, "import java.util.Map;\n");
    try out.appendSlice(gpa, "import java.util.Set;\n\n");
    try appendFmt(
        gpa,
        &out,
        "// Generated by `apexgov emulate transpile` from {s}\n",
        .{parsed.source_path},
    );
    try appendFmt(gpa, &out, "public final class {s} {{\n", .{parsed.class_name});

    if (parsed.fields.items.len == 0 and parsed.methods.items.len == 0) {
        try out.appendSlice(gpa, "  // No method body was detected in the Apex source.\n");
    }

    if (parsed.fields.items.len > 0) {
        for (parsed.fields.items) |field| {
            try appendFmt(gpa, &out, "  {s}\n", .{field.declaration});
        }
        try out.append(gpa, '\n');
    }

    for (parsed.methods.items) |method| {
        var emitted_name_storage: ?[]u8 = null;
        defer if (emitted_name_storage) |value| gpa.free(value);
        const emitted_name = if (method.is_constructor)
            parsed.class_name
        else blk: {
            const unique = try uniqueMethodName(gpa, &method_name_counts, method.name);
            emitted_name_storage = unique;
            break :blk unique;
        };

        if (method.is_test and !method.is_constructor) {
            try out.appendSlice(gpa, "  @Test\n");
        }
        if (method.is_constructor) {
            try appendFmt(gpa, &out, "  public {s}({s}) {{\n", .{ emitted_name, method.java_parameters });
        } else {
            const static_prefix = if (method.is_static) "static " else "";
            try appendFmt(
                gpa,
                &out,
                "  public {s}{s} {s}({s}) {{\n",
                .{ static_prefix, method.java_return_type, emitted_name, method.java_parameters },
            );
        }
        try out.appendSlice(gpa, "    // TODO(apex): method body is copied as comments and needs manual porting.\n");

        var statements = try collectLogicalStatements(gpa, method.body);
        defer {
            for (statements.items) |statement| gpa.free(statement);
            statements.deinit(gpa);
        }

        var brace_depth: i32 = 0;
        var switch_stack: std.ArrayList(ActiveSwitchContext) = .empty;
        defer {
            while (switch_stack.items.len > 0) {
                const ctx = switch_stack.pop().?;
                gpa.free(ctx.subject_expr);
            }
            switch_stack.deinit(gpa);
        }

        for (statements.items, 0..) |raw_stmt, idx| {
            const trimmed = std.mem.trim(u8, raw_stmt, " \t");
            if (trimmed.len == 0) continue;
            if (idx == statements.items.len - 1 and std.mem.eql(u8, trimmed, "}")) continue;

            while (switch_stack.items.len > 0 and brace_depth < switch_stack.items[switch_stack.items.len - 1].body_depth) {
                const stale = switch_stack.pop().?;
                gpa.free(stale.subject_expr);
            }

            const active_switch_expr: ?[]const u8 = if (switch_stack.items.len > 0)
                switch_stack.items[switch_stack.items.len - 1].subject_expr
            else
                null;
            const active_switch_mode = if (switch_stack.items.len > 0)
                switch_stack.items[switch_stack.items.len - 1].mode
            else
                SwitchMode.value;

            var switch_header_mode: ?SwitchMode = null;
            if (startsWithWordIgnoreCase(trimmed, "switch")) {
                switch_header_mode = try detectSwitchMode(gpa, statements.items, idx);
            }

            if (try transpileExecutableLineWithContext(
                gpa,
                trimmed,
                active_switch_expr,
                active_switch_mode,
                switch_header_mode,
            )) |converted| {
                defer gpa.free(converted);
                try appendFmt(gpa, &out, "    {s}\n", .{converted});

                if (switch_header_mode) |mode| {
                    if (parseSwitchSubjectExpression(trimmed)) |switch_expr_raw| {
                        const switch_expr_java = try convertApexExpressionToJava(gpa, switch_expr_raw);
                        try switch_stack.append(gpa, .{
                            .body_depth = brace_depth + 1,
                            .subject_expr = switch_expr_java,
                            .mode = mode,
                        });
                    }
                }
            } else {
                unsupported_statements += 1;
                try appendFmt(gpa, &out, "    // {s}\n", .{trimmed});
            }

            brace_depth += braceDelta(trimmed);
            while (switch_stack.items.len > 0 and brace_depth < switch_stack.items[switch_stack.items.len - 1].body_depth) {
                const stale = switch_stack.pop().?;
                gpa.free(stale.subject_expr);
            }
        }

        try out.appendSlice(gpa, "  }\n\n");
    }

    try out.appendSlice(gpa, "}\n");
    return .{
        .java = try out.toOwnedSlice(gpa),
        .unsupported_statements = unsupported_statements,
    };
}

const NestingState = struct {
    paren: i32 = 0,
    bracket: i32 = 0,
    brace: i32 = 0,
    in_single: bool = false,
    in_double: bool = false,
    escaped: bool = false,
};

fn collectLogicalStatements(gpa: std.mem.Allocator, body: []const u8) !std.ArrayList([]u8) {
    var statements: std.ArrayList([]u8) = .empty;
    errdefer {
        for (statements.items) |statement| gpa.free(statement);
        statements.deinit(gpa);
    }

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const clean = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, clean, " \t");
        if (trimmed.len == 0) continue;

        if (pending.items.len > 0) try pending.append(gpa, ' ');
        try pending.appendSlice(gpa, trimmed);

        const current = std.mem.trim(u8, pending.items, " \t");
        if (!shouldFlushLogicalStatement(current)) continue;

        try statements.append(gpa, try gpa.dupe(u8, current));
        pending.clearRetainingCapacity();
    }

    const tail = std.mem.trim(u8, pending.items, " \t");
    if (tail.len > 0) {
        try statements.append(gpa, try gpa.dupe(u8, tail));
    }

    return statements;
}

fn shouldFlushLogicalStatement(statement: []const u8) bool {
    if (statement.len == 0) return false;
    if (std.mem.eql(u8, statement, "{") or std.mem.eql(u8, statement, "}")) return true;

    const state = scanNestingState(statement);
    if (state.paren > 0 or state.bracket > 0) return false;
    if (state.brace > 0 and !isControlBlockHeader(statement)) return false;

    if (looksLikeControlHeaderWithoutBrace(statement)) return false;

    const last = statement[statement.len - 1];
    if (last == ';' or last == '{' or last == '}') return true;
    return true;
}

fn scanNestingState(text: []const u8) NestingState {
    var state = NestingState{};
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];

        if (state.in_double) {
            if (state.escaped) {
                state.escaped = false;
                continue;
            }
            if (ch == '\\') {
                state.escaped = true;
                continue;
            }
            if (ch == '"') state.in_double = false;
            continue;
        }
        if (state.in_single) {
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') state.in_single = false;
            continue;
        }

        switch (ch) {
            '"' => state.in_double = true,
            '\'' => state.in_single = true,
            '(' => state.paren += 1,
            ')' => {
                if (state.paren > 0) state.paren -= 1;
            },
            '[' => state.bracket += 1,
            ']' => {
                if (state.bracket > 0) state.bracket -= 1;
            },
            '{' => state.brace += 1,
            '}' => {
                if (state.brace > 0) state.brace -= 1;
            },
            else => {},
        }
    }
    return state;
}

fn isControlBlockHeader(statement: []const u8) bool {
    const trimmed = std.mem.trim(u8, statement, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[trimmed.len - 1] != '{') return false;

    const keywords = [_][]const u8{
        "if",  "else",  "for",     "while",  "do",
        "try", "catch", "finally", "switch", "when",
    };
    for (keywords) |keyword| {
        if (startsWithWordIgnoreCase(trimmed, keyword)) return true;
    }
    return false;
}

fn looksLikeControlHeaderWithoutBrace(statement: []const u8) bool {
    const trimmed = std.mem.trim(u8, statement, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[trimmed.len - 1] == '{' or trimmed[trimmed.len - 1] == ';') return false;
    if (std.mem.eql(u8, trimmed, "else")) return true;

    const keywords = [_][]const u8{
        "if", "for", "while", "catch", "switch", "when",
    };
    for (keywords) |keyword| {
        if (startsWithWordIgnoreCase(trimmed, keyword)) return true;
    }
    return false;
}

fn transpileExecutableLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    return transpileExecutableLineWithContext(gpa, line, null, .value, null);
}

fn transpileExecutableLineWithContext(
    gpa: std.mem.Allocator,
    line: []const u8,
    active_switch_expr: ?[]const u8,
    active_switch_mode: SwitchMode,
    switch_header_mode: ?SwitchMode,
) !?[]u8 {
    if (try transpileControlFlowLineWithContext(gpa, line, active_switch_expr, active_switch_mode, switch_header_mode)) |statement| return statement;
    if (try transpileAssertionLine(gpa, line)) |statement| return statement;
    if (try transpileSystemDebugLine(gpa, line)) |statement| return statement;
    if (try transpileSoqlLine(gpa, line)) |statement| return statement;
    if (try transpileDmlLine(gpa, line)) |statement| return statement;
    if (try transpileCollectionDeclarationLine(gpa, line)) |statement| return statement;
    if (try transpileGenericStatementLine(gpa, line)) |statement| return statement;
    return null;
}

fn transpileControlFlowLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    return transpileControlFlowLineWithContext(gpa, line, null, .value, null);
}

fn transpileControlFlowLineWithContext(
    gpa: std.mem.Allocator,
    line: []const u8,
    active_switch_expr: ?[]const u8,
    active_switch_mode: SwitchMode,
    switch_header_mode: ?SwitchMode,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (isDoWhileTailLine(trimmed)) {
        return try normalizeApexDoWhileTailLine(gpa, trimmed);
    }
    if (std.mem.eql(u8, trimmed, "{") or std.mem.eql(u8, trimmed, "}")) {
        return try gpa.dupe(u8, trimmed);
    }

    if (!isControlFlowLine(trimmed)) return null;

    if (startsWithWordIgnoreCase(trimmed, "when")) {
        const converted_when = try convertApexExpressionToJava(gpa, trimmed);
        defer gpa.free(converted_when);
        return try normalizeApexWhenLine(gpa, converted_when, active_switch_expr, active_switch_mode);
    }

    var converted = try convertApexExpressionToJava(gpa, trimmed);
    errdefer gpa.free(converted);

    if (startsWithWordIgnoreCase(converted, "switch")) {
        const mode = switch_header_mode orelse .value;
        const switch_fixed = try normalizeApexSwitchHeader(gpa, converted, mode);
        gpa.free(converted);
        converted = switch_fixed;
    }

    if (startsWithWordIgnoreCase(converted, "for")) {
        const for_fixed = try normalizeForHeaderTypes(gpa, converted);
        gpa.free(converted);
        converted = for_fixed;
    }
    return converted;
}

fn transpileSoqlLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }

    const select_start = indexOfSoqlBracketSelect(trimmed) orelse return null;
    const close_bracket = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return null;
    if (close_bracket <= select_start) return null;

    const query_segment = std.mem.trim(u8, trimmed[(select_start + 1)..close_bracket], " \t");
    if (!startsWithIgnoreCase(query_segment, "SELECT")) return null;
    const java_query = try quoteJavaStringLiteral(gpa, query_segment);
    defer gpa.free(java_query);

    const prefix = std.mem.trim(u8, trimmed[0..select_start], " \t");
    const suffix = std.mem.trim(u8, trimmed[(close_bracket + 1)..], " \t");
    if (suffix.len != 0) return null;

    if (prefix.len == 0) {
        return try std.fmt.allocPrint(gpa, "Database.query({s});", .{java_query});
    }

    if (prefix[prefix.len - 1] != '=') return null;
    const left = std.mem.trim(u8, prefix[0 .. prefix.len - 1], " \t");
    if (isSimpleIdentifier(left)) {
        return try std.fmt.allocPrint(
            gpa,
            "{s} = Database.query({s});",
            .{ left, java_query },
        );
    }

    if (try parseCollectionDeclaration(gpa, left)) |decl| {
        defer {
            gpa.free(decl.java_type);
            gpa.free(decl.variable_name);
        }
        if (decl.kind == .list) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} {s} = Database.query({s});",
                .{ decl.java_type, decl.variable_name, java_query },
            );
        }
        if (decl.kind == .map) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} {s} = ApexCollections.mapById(Database.query({s}));",
                .{ decl.java_type, decl.variable_name, java_query },
            );
        }
    }

    if (try parseTypedVariableDeclaration(gpa, left, false)) |decl| {
        defer {
            gpa.free(decl.declaration_head);
            gpa.free(decl.variable_name);
            gpa.free(decl.java_type);
        }
        return try std.fmt.allocPrint(
            gpa,
            "{s} = ApexCollections.firstOrNull(Database.query({s}));",
            .{ decl.declaration_head, java_query },
        );
    }

    const var_name = lastIdentifier(left) orelse return null;
    if (var_name.len == 0) return null;
    return try std.fmt.allocPrint(gpa, "List<ApexSObject> {s} = Database.query({s});", .{ var_name, java_query });
}

fn transpileDmlLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }

    const keywords = [_][]const u8{ "insert", "update", "upsert", "delete", "undelete", "merge" };
    for (keywords) |keyword| {
        if (!startsWithWordIgnoreCase(trimmed, keyword)) continue;
        const payload = std.mem.trimLeft(u8, trimmed[keyword.len..], " \t");
        if (payload.len == 0) return null;

        if (std.ascii.eqlIgnoreCase(keyword, "merge")) {
            var args = try splitMergeArguments(gpa, payload);
            defer args.deinit(gpa);
            if (args.items.len < 2 or args.items.len > 3) return null;

            const master = try convertApexExpressionToJava(gpa, args.items[0]);
            defer gpa.free(master);
            const dup1 = try convertApexExpressionToJava(gpa, args.items[1]);
            defer gpa.free(dup1);

            if (args.items.len == 2) {
                return try std.fmt.allocPrint(gpa, "Database.merge({s}, {s});", .{ master, dup1 });
            }

            const dup2 = try convertApexExpressionToJava(gpa, args.items[2]);
            defer gpa.free(dup2);
            return try std.fmt.allocPrint(
                gpa,
                "Database.merge({s}, java.util.List.of({s}, {s}));",
                .{ master, dup1, dup2 },
            );
        }

        if (std.ascii.eqlIgnoreCase(keyword, "upsert")) {
            if (splitTrailingIdentifierAtTopLevel(payload)) |split| {
                const converted = try convertApexExpressionToJava(gpa, split.head);
                defer gpa.free(converted);
                return try std.fmt.allocPrint(
                    gpa,
                    "Database.upsert({s}); // external id field: {s}",
                    .{ converted, split.tail },
                );
            }
        }

        const converted = try convertApexExpressionToJava(gpa, payload);
        defer gpa.free(converted);
        return try std.fmt.allocPrint(gpa, "Database.{s}({s});", .{ keyword, converted });
    }
    return null;
}

fn transpileAssertionLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const close_paren = findMatchingParen(trimmed, open_paren) orelse return null;
    if (close_paren + 1 < trimmed.len) {
        const trailing = std.mem.trim(u8, trimmed[(close_paren + 1)..], " \t");
        if (trailing.len != 0) return null;
    }

    const head = std.mem.trim(u8, trimmed[0..open_paren], " \t");
    var method_name: []const u8 = undefined;
    var assert_target: enum { system, apex } = undefined;
    if (startsWithIgnoreCase(head, "System.Assert.")) {
        assert_target = .apex;
        method_name = std.mem.trim(u8, head["System.Assert.".len..], " \t");
    } else if (startsWithIgnoreCase(head, "Assert.")) {
        assert_target = .apex;
        method_name = std.mem.trim(u8, head["Assert.".len..], " \t");
    } else if (startsWithIgnoreCase(head, "System.")) {
        assert_target = .system;
        method_name = std.mem.trim(u8, head["System.".len..], " \t");
    } else {
        return null;
    }

    if (method_name.len == 0) return null;
    if (std.mem.indexOfScalar(u8, method_name, '.')) |_| return null;

    var args = try splitCallArguments(gpa, trimmed[(open_paren + 1)..close_paren]);
    defer args.deinit(gpa);

    var converted: std.ArrayList([]u8) = .empty;
    defer {
        for (converted.items) |arg| gpa.free(arg);
        converted.deinit(gpa);
    }

    for (args.items) |arg| {
        try converted.append(gpa, try convertApexExpressionToJava(gpa, arg));
    }

    switch (assert_target) {
        .system => {
            if (std.ascii.eqlIgnoreCase(method_name, "assert")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildSystemAssertCall(gpa, "assertTrue", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assertEquals")) {
                if (converted.items.len < 2 or converted.items.len > 3) return null;
                return try buildSystemAssertCall(gpa, "assertEquals", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assertNotEquals")) {
                if (converted.items.len < 2 or converted.items.len > 3) return null;
                return try buildSystemAssertCall(gpa, "assertNotEquals", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assertFalse")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildSystemAssertCall(gpa, "assertFalse", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assertTrue")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildSystemAssertCall(gpa, "assertTrue", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assertNull")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildSystemAssertCall(gpa, "assertNull", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "assertNotNull")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildSystemAssertCall(gpa, "assertNotNull", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "fail")) {
                if (converted.items.len < 1 or converted.items.len > 1) return null;
                return try buildSystemAssertCall(gpa, "fail", converted.items);
            }
        },
        .apex => {
            if (std.ascii.eqlIgnoreCase(method_name, "isTrue") or std.ascii.eqlIgnoreCase(method_name, "assertTrue")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildApexAssertCall(gpa, "isTrue", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "isFalse") or std.ascii.eqlIgnoreCase(method_name, "assertFalse")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildApexAssertCall(gpa, "isFalse", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "areEqual") or std.ascii.eqlIgnoreCase(method_name, "assertEquals")) {
                if (converted.items.len < 2 or converted.items.len > 3) return null;
                return try buildApexAssertCall(gpa, "areEqual", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "areNotEqual") or std.ascii.eqlIgnoreCase(method_name, "assertNotEquals")) {
                if (converted.items.len < 2 or converted.items.len > 3) return null;
                return try buildApexAssertCall(gpa, "areNotEqual", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "isNull") or std.ascii.eqlIgnoreCase(method_name, "assertNull")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildApexAssertCall(gpa, "isNull", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "isNotNull") or std.ascii.eqlIgnoreCase(method_name, "assertNotNull")) {
                if (converted.items.len < 1 or converted.items.len > 2) return null;
                return try buildApexAssertCall(gpa, "isNotNull", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "isInstanceOfType")) {
                if (converted.items.len < 2 or converted.items.len > 3) return null;
                const normalized_type_arg = try normalizeApexAssertTypeArg(gpa, converted.items[1]);
                gpa.free(converted.items[1]);
                converted.items[1] = normalized_type_arg;
                return try buildApexAssertCall(gpa, "isInstanceOfType", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "isNotInstanceOfType")) {
                if (converted.items.len < 2 or converted.items.len > 3) return null;
                const normalized_type_arg = try normalizeApexAssertTypeArg(gpa, converted.items[1]);
                gpa.free(converted.items[1]);
                converted.items[1] = normalized_type_arg;
                return try buildApexAssertCall(gpa, "isNotInstanceOfType", converted.items);
            }
            if (std.ascii.eqlIgnoreCase(method_name, "fail")) {
                if (converted.items.len > 1) return null;
                return try buildApexAssertCall(gpa, "fail", converted.items);
            }
        },
    }

    return null;
}

fn transpileSystemDebugLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }

    if (!startsWithIgnoreCase(trimmed, "System.debug")) return null;
    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const close_paren = findMatchingParen(trimmed, open_paren) orelse return null;
    if (close_paren + 1 < trimmed.len) {
        const trailing = std.mem.trim(u8, trimmed[(close_paren + 1)..], " \t");
        if (trailing.len != 0) return null;
    }

    var args = try splitCallArguments(gpa, trimmed[(open_paren + 1)..close_paren]);
    defer args.deinit(gpa);
    if (args.items.len == 0) return null;

    const payload = args.items[args.items.len - 1];
    const converted = try convertApexExpressionToJava(gpa, payload);
    defer gpa.free(converted);
    return try std.fmt.allocPrint(gpa, "System.out.println({s});", .{converted});
}

fn transpileCollectionDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }

    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=');
    const left = std.mem.trim(u8, if (eq_pos) |pos| trimmed[0..pos] else trimmed, " \t");
    const right = if (eq_pos) |pos| std.mem.trim(u8, trimmed[(pos + 1)..], " \t") else "";

    const declaration = try parseCollectionDeclaration(gpa, left);
    if (declaration == null) return null;
    const decl = declaration.?;
    defer {
        gpa.free(decl.java_type);
        gpa.free(decl.variable_name);
    }

    if (eq_pos == null) {
        return try std.fmt.allocPrint(gpa, "{s} {s};", .{ decl.java_type, decl.variable_name });
    }

    if (right.len == 0) return null;

    const maybe_init = try transpileCollectionInitializer(gpa, decl.kind, decl.java_type, right);
    if (maybe_init) |initializer| {
        defer gpa.free(initializer);
        return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ decl.java_type, decl.variable_name, initializer });
    }

    if (std.mem.indexOfScalar(u8, right, '[')) |_| return null;
    const rhs = try convertApexExpressionToJava(gpa, right);
    defer gpa.free(rhs);
    return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ decl.java_type, decl.variable_name, rhs });
}

fn transpileGenericStatementLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] != ';') return null;
    trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    if (trimmed.len == 0) return null;

    if (try transpileTypedDeclarationLine(gpa, trimmed, false)) |declaration| {
        return declaration;
    }

    if (findTopLevelAssignmentOperator(trimmed)) |eq_pos| {
        const lhs = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const rhs = std.mem.trim(u8, trimmed[(eq_pos + 1)..], " \t");
        if (lhs.len != 0) {
            const lhs_tail = lhs[lhs.len - 1];
            if (lhs_tail != '+' and lhs_tail != '-' and lhs_tail != '*' and lhs_tail != '/' and lhs_tail != '%' and lhs_tail != '&' and lhs_tail != '|' and lhs_tail != '^') {
                if (rhs.len == 0) return null;
                const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
                defer gpa.free(converted_rhs);
                if (parseSObjectFieldLvalue(lhs)) |lvalue| {
                    const converted_base = try convertApexExpressionToJava(gpa, lvalue.base_expr);
                    defer gpa.free(converted_base);
                    return try std.fmt.allocPrint(
                        gpa,
                        "{s}.set(\"{s}\", {s});",
                        .{ converted_base, lvalue.field_name, converted_rhs },
                    );
                }
                return try std.fmt.allocPrint(gpa, "{s} = {s};", .{ lhs, converted_rhs });
            }
        }
    }

    const converted = try convertApexExpressionToJava(gpa, trimmed);
    defer gpa.free(converted);
    return try std.fmt.allocPrint(gpa, "{s};", .{converted});
}

const CollectionKind = enum {
    list,
    map,
    set,
};

const CollectionDeclaration = struct {
    kind: CollectionKind,
    java_type: []u8,
    variable_name: []u8,
};

const TypedVariableDeclaration = struct {
    declaration_head: []u8,
    variable_name: []u8,
    java_type: []u8,
};

fn parseCollectionDeclaration(gpa: std.mem.Allocator, left: []const u8) !?CollectionDeclaration {
    var rest = std.mem.trim(u8, left, " \t");
    if (startsWithIgnoreCase(rest, "final ")) {
        rest = std.mem.trimLeft(u8, rest["final".len..], " \t");
    }
    if (rest.len == 0) return null;

    const lt = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    const raw_type = std.mem.trim(u8, rest[0..lt], " \t");
    const kind = collectionKindFromName(raw_type) orelse return null;

    const gt = findMatchingAngle(rest, lt) orelse return null;
    const generic_part = std.mem.trim(u8, rest[(lt + 1)..gt], " \t");
    if (generic_part.len == 0) return null;

    const variable_part = std.mem.trim(u8, rest[(gt + 1)..], " \t");
    if (variable_part.len == 0) return null;
    const variable_name = leadingIdentifier(variable_part) orelse return null;
    if (!std.mem.eql(u8, variable_name, variable_part)) return null;

    const converted_generic = try convertApexTypeList(gpa, generic_part);
    defer gpa.free(converted_generic);
    const java_interface = collectionInterfaceName(kind);
    const java_type = try std.fmt.allocPrint(gpa, "{s}<{s}>", .{ java_interface, converted_generic });

    return .{
        .kind = kind,
        .java_type = java_type,
        .variable_name = try gpa.dupe(u8, variable_name),
    };
}

fn parseTypedVariableDeclaration(
    gpa: std.mem.Allocator,
    left: []const u8,
    allow_visibility: bool,
) !?TypedVariableDeclaration {
    const trimmed = std.mem.trim(u8, left, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| return null;

    var tokens = try splitWhitespace(gpa, trimmed);
    defer tokens.deinit(gpa);
    if (tokens.items.len < 2) return null;

    const variable_name = tokens.items[tokens.items.len - 1];
    if (!isSimpleIdentifier(variable_name)) return null;

    var modifier_out: std.ArrayList(u8) = .empty;
    defer modifier_out.deinit(gpa);

    var type_index: usize = 0;
    while (type_index + 1 < tokens.items.len and isDeclarationModifier(tokens.items[type_index], allow_visibility)) : (type_index += 1) {
        if (modifier_out.items.len > 0) try modifier_out.append(gpa, ' ');
        try modifier_out.appendSlice(gpa, normalizeDeclarationModifier(tokens.items[type_index]));
    }
    if (type_index >= tokens.items.len - 1) return null;

    var type_raw_buf: std.ArrayList(u8) = .empty;
    defer type_raw_buf.deinit(gpa);
    for (tokens.items[type_index .. tokens.items.len - 1], 0..) |part, idx| {
        if (idx != 0) try type_raw_buf.append(gpa, ' ');
        try type_raw_buf.appendSlice(gpa, part);
    }
    const type_raw = try type_raw_buf.toOwnedSlice(gpa);
    defer gpa.free(type_raw);
    if (!looksLikeTypeName(type_raw)) return null;

    const java_type = try convertApexType(gpa, type_raw);
    errdefer gpa.free(java_type);

    const declaration_head = if (modifier_out.items.len == 0)
        try std.fmt.allocPrint(gpa, "{s} {s}", .{ java_type, variable_name })
    else
        try std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ modifier_out.items, java_type, variable_name });
    errdefer gpa.free(declaration_head);

    return .{
        .declaration_head = declaration_head,
        .variable_name = try gpa.dupe(u8, variable_name),
        .java_type = java_type,
    };
}

fn transpileCollectionInitializer(
    gpa: std.mem.Allocator,
    kind: CollectionKind,
    java_type: []const u8,
    right: []const u8,
) !?[]u8 {
    var rest = std.mem.trim(u8, right, " \t");
    if (!startsWithIgnoreCase(rest, "new")) return null;
    rest = std.mem.trimLeft(u8, rest["new".len..], " \t");

    const lt = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    const raw_type = std.mem.trim(u8, rest[0..lt], " \t");
    const parsed_kind = collectionKindFromName(raw_type) orelse return null;
    if (parsed_kind != kind) return null;

    const gt = findMatchingAngle(rest, lt) orelse return null;
    var after = std.mem.trim(u8, rest[(gt + 1)..], " \t");
    if (after.len == 0 or after[0] != '(') return null;

    const close = findMatchingParen(after, 0) orelse return null;
    const trailing = std.mem.trim(u8, after[(close + 1)..], " \t");
    if (trailing.len != 0) return null;

    const args_raw = std.mem.trim(u8, after[1..close], " \t");
    const impl_name = collectionImplName(kind);
    if (args_raw.len == 0) {
        return try std.fmt.allocPrint(gpa, "new {s}<>()", .{impl_name});
    }

    var args = try splitCallArguments(gpa, args_raw);
    defer args.deinit(gpa);
    if (args.items.len == 0) {
        return try std.fmt.allocPrint(gpa, "new {s}<>()", .{impl_name});
    }

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(gpa);

    if (kind == .map and args.items.len == 1) {
        const single = try convertApexExpressionToJava(gpa, args.items[0]);
        defer gpa.free(single);
        if (try isIdSObjectMapType(gpa, java_type)) {
            if (startsWithIgnoreCase(std.mem.trim(u8, single, " \t"), "Database.query(")) {
                return try std.fmt.allocPrint(gpa, "ApexCollections.mapById({s})", .{single});
            }
            return try std.fmt.allocPrint(gpa, "ApexCollections.toIdMap({s})", .{single});
        }
        if (startsWithIgnoreCase(std.mem.trim(u8, single, " \t"), "Database.query(")) {
            return try std.fmt.allocPrint(gpa, "ApexCollections.mapById({s})", .{single});
        }
    }

    try appendFmt(gpa, &rendered, "new {s}<>(", .{impl_name});
    for (args.items, 0..) |arg, idx| {
        const converted = try convertApexExpressionToJava(gpa, arg);
        defer gpa.free(converted);
        if (idx != 0) try rendered.appendSlice(gpa, ", ");
        try rendered.appendSlice(gpa, converted);
    }
    try rendered.append(gpa, ')');
    return try rendered.toOwnedSlice(gpa);
}

fn convertApexTypeList(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var items = try splitTypeArguments(gpa, raw);
    defer items.deinit(gpa);

    if (items.items.len == 0) return gpa.dupe(u8, "Object");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (items.items, 0..) |part, idx| {
        const converted = try convertApexType(gpa, part);
        defer gpa.free(converted);
        if (idx != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, converted);
    }
    return out.toOwnedSlice(gpa);
}

fn convertApexType(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return gpa.dupe(u8, "Object");

    if (std.mem.indexOfScalar(u8, trimmed, '<')) |lt| {
        const gt = findMatchingAngle(trimmed, lt) orelse return gpa.dupe(u8, normalizeScalarTypeName(trimmed));
        const outer_raw = std.mem.trim(u8, trimmed[0..lt], " \t");
        const inner_raw = std.mem.trim(u8, trimmed[(lt + 1)..gt], " \t");

        const outer = normalizeScalarTypeName(outer_raw);
        const inner = try convertApexTypeList(gpa, inner_raw);
        defer gpa.free(inner);
        return std.fmt.allocPrint(gpa, "{s}<{s}>", .{ outer, inner });
    }

    return gpa.dupe(u8, normalizeScalarTypeName(trimmed));
}

fn splitTypeArguments(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return out;

    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        switch (ch) {
            '<' => depth += 1,
            '>' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth != 0) continue;
                const part = std.mem.trim(u8, trimmed[start..i], " \t");
                if (part.len > 0) try out.append(gpa, part);
                start = i + 1;
            },
            else => {},
        }
    }
    const tail = std.mem.trim(u8, trimmed[start..], " \t");
    if (tail.len > 0) try out.append(gpa, tail);
    return out;
}

fn normalizeScalarTypeName(raw: []const u8) []const u8 {
    if (raw.len == 0) return "Object";
    if (std.mem.indexOfScalar(u8, raw, '.')) |_| return raw;

    if (std.ascii.eqlIgnoreCase(raw, "void")) return "void";
    if (std.ascii.eqlIgnoreCase(raw, "Id")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Decimal")) return "Double";
    if (std.ascii.eqlIgnoreCase(raw, "Date")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Datetime")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Time")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Blob")) return "byte[]";
    if (std.ascii.eqlIgnoreCase(raw, "List")) return "List";
    if (std.ascii.eqlIgnoreCase(raw, "Map")) return "Map";
    if (std.ascii.eqlIgnoreCase(raw, "Set")) return "Set";
    if (std.ascii.eqlIgnoreCase(raw, "Integer")) return "Integer";
    if (std.ascii.eqlIgnoreCase(raw, "Long")) return "Long";
    if (std.ascii.eqlIgnoreCase(raw, "Double")) return "Double";
    if (std.ascii.eqlIgnoreCase(raw, "Boolean")) return "Boolean";
    if (std.ascii.eqlIgnoreCase(raw, "String")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Object")) return "Object";
    if (std.ascii.eqlIgnoreCase(raw, "ApexSObject")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "Exception")) return "Exception";
    if (std.ascii.eqlIgnoreCase(raw, "RuntimeException")) return "RuntimeException";
    if (std.ascii.eqlIgnoreCase(raw, "Throwable")) return "Throwable";
    if (std.ascii.eqlIgnoreCase(raw, "Database")) return "Database";
    if (std.ascii.eqlIgnoreCase(raw, "Schema")) return "Schema";
    if (std.ascii.eqlIgnoreCase(raw, "SystemAssert")) return "SystemAssert";
    if (std.ascii.eqlIgnoreCase(raw, "Assert")) return "ApexAssert";
    if (std.ascii.eqlIgnoreCase(raw, "ApexAssert")) return "ApexAssert";

    if (raw.len == 1 and std.ascii.isUpper(raw[0])) return "Object";
    if (std.ascii.isUpper(raw[0])) return "ApexSObject";
    return raw;
}

fn collectionKindFromName(type_name: []const u8) ?CollectionKind {
    if (std.ascii.eqlIgnoreCase(type_name, "List")) return .list;
    if (std.ascii.eqlIgnoreCase(type_name, "Map")) return .map;
    if (std.ascii.eqlIgnoreCase(type_name, "Set")) return .set;
    return null;
}

fn collectionInterfaceName(kind: CollectionKind) []const u8 {
    return switch (kind) {
        .list => "List",
        .map => "Map",
        .set => "Set",
    };
}

fn collectionImplName(kind: CollectionKind) []const u8 {
    return switch (kind) {
        .list => "ArrayList",
        .map => "LinkedHashMap",
        .set => "LinkedHashSet",
    };
}

fn findMatchingAngle(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '<') return null;
    var depth: i32 = 0;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '<') {
            depth += 1;
        } else if (ch == '>') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

fn splitCallArguments(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return out;

    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < trimmed.len and trimmed[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            ',' => {
                if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0 or angle_depth != 0) continue;
                const piece = std.mem.trim(u8, trimmed[start..i], " \t");
                if (piece.len > 0) try out.append(gpa, piece);
                start = i + 1;
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, trimmed[start..], " \t");
    if (tail.len > 0) try out.append(gpa, tail);
    return out;
}

fn splitMergeArguments(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
    if (hasTopLevelComma(raw)) {
        return splitCallArguments(gpa, raw);
    }
    return splitTopLevelWhitespaceExpressions(gpa, raw);
}

fn hasTopLevelComma(text: []const u8) bool {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            ',' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) return true;
            },
            else => {},
        }
    }
    return false;
}

fn splitTopLevelWhitespaceExpressions(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return out;

    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var token_start: ?usize = null;

    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];

        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < trimmed.len and trimmed[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            if (token_start == null) token_start = i;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            if (token_start == null) token_start = i;
            continue;
        }

        if (!in_single and !in_double) {
            switch (ch) {
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                },
                '{' => brace_depth += 1,
                '}' => {
                    if (brace_depth > 0) brace_depth -= 1;
                },
                '<' => angle_depth += 1,
                '>' => {
                    if (angle_depth > 0) angle_depth -= 1;
                },
                else => {},
            }
        }

        if (std.ascii.isWhitespace(ch) and !in_single and !in_double and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
            if (token_start) |start| {
                const piece = std.mem.trim(u8, trimmed[start..i], " \t");
                if (piece.len > 0) try out.append(gpa, piece);
                token_start = null;
            }
            continue;
        }

        if (token_start == null) token_start = i;
    }

    if (token_start) |start| {
        const tail = std.mem.trim(u8, trimmed[start..], " \t");
        if (tail.len > 0) try out.append(gpa, tail);
    }
    return out;
}

fn buildSystemAssertCall(gpa: std.mem.Allocator, method_name: []const u8, args: []const []const u8) ![]u8 {
    return buildAssertCall(gpa, "SystemAssert", method_name, args);
}

fn buildApexAssertCall(gpa: std.mem.Allocator, method_name: []const u8, args: []const []const u8) ![]u8 {
    return buildAssertCall(gpa, "ApexAssert", method_name, args);
}

fn normalizeApexAssertTypeArg(gpa: std.mem.Allocator, raw_arg: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_arg, " \t");
    if (trimmed.len < 7) return try gpa.dupe(u8, raw_arg);
    if (!std.mem.endsWith(u8, trimmed, ".class")) return try gpa.dupe(u8, raw_arg);

    const type_expr = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - ".class".len], " \t");
    const simple_name = extractSimpleTypeName(type_expr) orelse return try gpa.dupe(u8, raw_arg);
    return try std.fmt.allocPrint(gpa, "\"{s}\"", .{simple_name});
}

fn extractSimpleTypeName(type_expr_raw: []const u8) ?[]const u8 {
    const type_expr = std.mem.trim(u8, type_expr_raw, " \t");
    if (type_expr.len == 0) return null;

    var start: usize = 0;
    var i: usize = 0;
    while (i < type_expr.len) : (i += 1) {
        const c = type_expr[i];
        if (c == '.') {
            start = i + 1;
            continue;
        }
        if (!isIdentifierChar(c)) return null;
    }
    if (start >= type_expr.len) return null;
    return type_expr[start..];
}

fn buildAssertCall(gpa: std.mem.Allocator, class_name: []const u8, method_name: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, class_name);
    try out.appendSlice(gpa, ".");
    try out.appendSlice(gpa, method_name);
    try out.appendSlice(gpa, "(");
    for (args, 0..) |arg, idx| {
        if (idx != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, arg);
    }
    try out.appendSlice(gpa, ");");
    return out.toOwnedSlice(gpa);
}

fn convertApexExpressionToJava(gpa: std.mem.Allocator, expression: []const u8) anyerror![]u8 {
    const trimmed = std.mem.trim(u8, expression, " \t");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < trimmed.len) {
        const ch = trimmed[i];
        if (ch != '\'') {
            try out.append(gpa, ch);
            i += 1;
            continue;
        }

        i += 1;
        try out.append(gpa, '"');
        while (i < trimmed.len) {
            const curr = trimmed[i];
            if (curr == '\'') {
                if (i + 1 < trimmed.len and trimmed[i + 1] == '\'') {
                    try appendEscapedJavaStringChar(gpa, &out, '\'');
                    i += 2;
                    continue;
                }
                i += 1;
                break;
            }

            try appendEscapedJavaStringChar(gpa, &out, curr);
            i += 1;
        }
        try out.append(gpa, '"');
    }

    const literal_converted = try out.toOwnedSlice(gpa);
    errdefer gpa.free(literal_converted);

    const soql_converted = try convertInlineSoqlQueries(gpa, literal_converted);
    gpa.free(literal_converted);
    errdefer gpa.free(soql_converted);

    const soql_api_converted = try rewriteDatabaseQueryStringConsumers(gpa, soql_converted);
    gpa.free(soql_converted);
    errdefer gpa.free(soql_api_converted);

    const string_api_converted = try rewriteApexStringUtilityCalls(gpa, soql_api_converted);
    gpa.free(soql_api_converted);
    errdefer gpa.free(string_api_converted);

    const indexed_converted = try convertBracketIndexAccess(gpa, string_api_converted);
    gpa.free(string_api_converted);
    errdefer gpa.free(indexed_converted);

    const ctor_converted = try convertInlineCollectionConstructors(gpa, indexed_converted);
    gpa.free(indexed_converted);
    errdefer gpa.free(ctor_converted);

    const literal_ctor_converted = try convertInlineCollectionLiterals(gpa, ctor_converted);
    gpa.free(ctor_converted);
    errdefer gpa.free(literal_ctor_converted);

    const sobject_ctor_converted = try convertInlineSObjectConstructors(gpa, literal_ctor_converted);
    gpa.free(literal_ctor_converted);
    errdefer gpa.free(sobject_ctor_converted);

    const field_converted = try convertSObjectFieldAccess(gpa, sobject_ctor_converted);
    gpa.free(sobject_ctor_converted);
    errdefer gpa.free(field_converted);

    const instanceof_converted = try rewriteApexInstanceofChecks(gpa, field_converted);
    gpa.free(field_converted);
    return instanceof_converted;
}

fn convertBracketIndexAccess(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch != '[') continue;
        if (i == 0) continue;

        const close = findMatchingSquareBracket(text, i) orelse continue;
        const index_expr = std.mem.trim(u8, text[(i + 1)..close], " \t");
        if (index_expr.len == 0) continue;
        if (startsWithIgnoreCase(index_expr, "SELECT")) continue;

        var base_start = i;
        while (base_start > 0 and isIdentifierChar(text[base_start - 1])) : (base_start -= 1) {}
        if (base_start == i) continue;
        const base_name = text[base_start..i];
        if (!isSimpleIdentifier(base_name)) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "{s}.get({s})", .{ base_name, index_expr });
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn convertInlineCollectionConstructors(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];

        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') {
                in_double = false;
            }
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }

        if (!isNewKeywordAt(text, i)) continue;

        var cursor = i + "new".len;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or !isIdentifierChar(text[cursor])) continue;

        const type_start = cursor;
        while (cursor < text.len and isIdentifierChar(text[cursor])) : (cursor += 1) {}
        const raw_type = text[type_start..cursor];
        const kind = collectionKindFromName(raw_type) orelse continue;

        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '<') continue;
        const close_angle = findMatchingAngle(text, cursor) orelse continue;

        const generic_raw = std.mem.trim(u8, text[(cursor + 1)..close_angle], " \t");
        if (generic_raw.len == 0) continue;
        const java_generic = try convertApexTypeList(gpa, generic_raw);
        defer gpa.free(java_generic);

        cursor = close_angle + 1;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '(') continue;
        const close_paren = findMatchingParen(text, cursor) orelse continue;

        const args_raw = text[(cursor + 1)..close_paren];
        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);

        const impl_name = collectionImplName(kind);
        var replacement: []u8 = undefined;
        if (args.items.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "new {s}<{s}>()", .{ impl_name, java_generic });
        } else if (kind == .map and args.items.len == 1 and try isIdSObjectMapGeneric(gpa, java_generic)) {
            const single = try convertApexExpressionToJava(gpa, args.items[0]);
            defer gpa.free(single);
            if (startsWithIgnoreCase(std.mem.trim(u8, single, " \t"), "Database.query(")) {
                replacement = try std.fmt.allocPrint(gpa, "ApexCollections.mapById({s})", .{single});
            } else {
                replacement = try std.fmt.allocPrint(gpa, "ApexCollections.toIdMap({s})", .{single});
            }
        } else {
            var rendered: std.ArrayList(u8) = .empty;
            defer rendered.deinit(gpa);
            try appendFmt(gpa, &rendered, "new {s}<{s}>(", .{ impl_name, java_generic });
            for (args.items, 0..) |arg, idx| {
                const converted = try convertApexExpressionToJava(gpa, arg);
                defer gpa.free(converted);
                if (idx != 0) try rendered.appendSlice(gpa, ", ");
                try rendered.appendSlice(gpa, converted);
            }
            try rendered.append(gpa, ')');
            replacement = try rendered.toOwnedSlice(gpa);
        }
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement);
        replaced = true;

        i = close_paren;
        last_emit = close_paren + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn isIdSObjectMapType(gpa: std.mem.Allocator, java_type: []const u8) !bool {
    const trimmed = std.mem.trim(u8, java_type, " \t");
    if (!startsWithIgnoreCase(trimmed, "Map<")) return false;
    const open = std.mem.indexOfScalar(u8, trimmed, '<') orelse return false;
    const close = findMatchingAngle(trimmed, open) orelse return false;
    const inner = std.mem.trim(u8, trimmed[(open + 1)..close], " \t");
    return isIdSObjectMapGeneric(gpa, inner);
}

fn isIdSObjectMapGeneric(gpa: std.mem.Allocator, generic: []const u8) !bool {
    var parts = try splitTypeArguments(gpa, generic);
    defer parts.deinit(gpa);
    if (parts.items.len != 2) return false;
    const key = std.mem.trim(u8, parts.items[0], " \t");
    const value = std.mem.trim(u8, parts.items[1], " \t");
    return std.ascii.eqlIgnoreCase(key, "String") and std.ascii.eqlIgnoreCase(value, "ApexSObject");
}

fn convertInlineCollectionLiterals(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!isNewKeywordAt(text, i)) continue;

        var cursor = i + "new".len;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or !isIdentifierChar(text[cursor])) continue;

        const type_start = cursor;
        while (cursor < text.len and isIdentifierChar(text[cursor])) : (cursor += 1) {}
        const raw_type = text[type_start..cursor];
        const kind = collectionKindFromName(raw_type) orelse continue;

        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '<') continue;
        const close_angle = findMatchingAngle(text, cursor) orelse continue;

        const generic_raw = std.mem.trim(u8, text[(cursor + 1)..close_angle], " \t");
        if (generic_raw.len == 0) continue;
        const java_generic = try convertApexTypeList(gpa, generic_raw);
        defer gpa.free(java_generic);

        cursor = close_angle + 1;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '{') continue;

        const close_brace = findMatchingBrace(text, cursor) orelse continue;
        const literal_raw = std.mem.trim(u8, text[(cursor + 1)..close_brace], " \t");
        const impl_name = collectionImplName(kind);

        var replacement: []u8 = undefined;
        if (kind == .map) {
            if (literal_raw.len == 0) {
                replacement = try std.fmt.allocPrint(gpa, "new {s}<{s}>()", .{ impl_name, java_generic });
            } else {
                var entries = try splitCallArguments(gpa, literal_raw);
                defer entries.deinit(gpa);
                if (entries.items.len == 0) continue;

                var mapped: std.ArrayList([]u8) = .empty;
                defer {
                    for (mapped.items) |entry| gpa.free(entry);
                    mapped.deinit(gpa);
                }

                for (entries.items) |entry| {
                    const arrow = findTopLevelMapArrow(entry) orelse {
                        mapped.clearRetainingCapacity();
                        break;
                    };
                    const key_raw = std.mem.trim(u8, entry[0..arrow], " \t");
                    const value_raw = std.mem.trim(u8, entry[(arrow + 2)..], " \t");
                    if (key_raw.len == 0 or value_raw.len == 0) {
                        mapped.clearRetainingCapacity();
                        break;
                    }

                    const key = try convertApexExpressionToJava(gpa, key_raw);
                    defer gpa.free(key);
                    const value = try convertApexExpressionToJava(gpa, value_raw);
                    defer gpa.free(value);
                    try mapped.append(gpa, try std.fmt.allocPrint(gpa, "java.util.Map.entry({s}, {s})", .{ key, value }));
                }
                if (mapped.items.len != entries.items.len) continue;

                var joined: std.ArrayList(u8) = .empty;
                defer joined.deinit(gpa);
                for (mapped.items, 0..) |entry, idx| {
                    if (idx != 0) try joined.appendSlice(gpa, ", ");
                    try joined.appendSlice(gpa, entry);
                }
                replacement = try std.fmt.allocPrint(
                    gpa,
                    "new {s}<{s}>(java.util.Map.ofEntries({s}))",
                    .{ impl_name, java_generic, joined.items },
                );
            }
        } else {
            if (literal_raw.len == 0) {
                replacement = try std.fmt.allocPrint(gpa, "new {s}<{s}>()", .{ impl_name, java_generic });
            } else {
                var items = try splitCallArguments(gpa, literal_raw);
                defer items.deinit(gpa);
                if (items.items.len == 0) continue;

                var joined: std.ArrayList(u8) = .empty;
                defer joined.deinit(gpa);
                for (items.items, 0..) |item, idx| {
                    const converted_item = try convertApexExpressionToJava(gpa, item);
                    defer gpa.free(converted_item);
                    if (idx != 0) try joined.appendSlice(gpa, ", ");
                    try joined.appendSlice(gpa, converted_item);
                }
                replacement = try std.fmt.allocPrint(
                    gpa,
                    "new {s}<{s}>(java.util.List.of({s}))",
                    .{ impl_name, java_generic, joined.items },
                );
            }
        }
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement);
        replaced = true;

        i = close_brace;
        last_emit = close_brace + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn convertInlineSObjectConstructors(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!isNewKeywordAt(text, i)) continue;

        var cursor = i + "new".len;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or !isIdentifierChar(text[cursor])) continue;

        const type_start = cursor;
        while (cursor < text.len and isIdentifierChar(text[cursor])) : (cursor += 1) {}
        const type_name = text[type_start..cursor];
        if (collectionKindFromName(type_name) != null) continue;

        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '(') continue;
        const close_paren = findMatchingParen(text, cursor) orelse continue;
        const args_raw = std.mem.trim(u8, text[(cursor + 1)..close_paren], " \t");

        var replacement: ?[]u8 = null;

        if (args_raw.len == 0) {
            if (std.mem.eql(u8, normalizeScalarTypeName(type_name), "ApexSObject")) {
                replacement = try std.fmt.allocPrint(gpa, "ApexSObject.of(\"{s}\")", .{type_name});
            }
        } else {
            var args = try splitCallArguments(gpa, args_raw);
            defer args.deinit(gpa);
            if (args.items.len == 0) continue;

            var builder: std.ArrayList(u8) = .empty;
            defer builder.deinit(gpa);
            try appendFmt(gpa, &builder, "ApexSObject.of(\"{s}\")", .{type_name});

            var named_count: usize = 0;
            for (args.items) |arg| {
                const eq_pos = findTopLevelAssignmentOperator(arg) orelse break;
                const field_name = std.mem.trim(u8, arg[0..eq_pos], " \t");
                const value_raw = std.mem.trim(u8, arg[(eq_pos + 1)..], " \t");
                if (!isSimpleIdentifier(field_name) or value_raw.len == 0) break;

                const value = try convertApexExpressionToJava(gpa, value_raw);
                defer gpa.free(value);
                try appendFmt(gpa, &builder, ".set(\"{s}\", {s})", .{ field_name, value });
                named_count += 1;
            }

            if (named_count == args.items.len and named_count > 0) {
                replacement = try builder.toOwnedSlice(gpa);
            }
        }

        if (replacement) |value| {
            defer gpa.free(value);
            try out.appendSlice(gpa, text[last_emit..i]);
            try out.appendSlice(gpa, value);
            replaced = true;
            i = close_paren;
            last_emit = close_paren + 1;
            in_double = false;
            escaped = false;
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteApexInstanceofChecks(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var in_single = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (in_single) {
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (!isInstanceofKeywordAt(text, i)) continue;

        var lhs_end = i;
        while (lhs_end > 0 and std.ascii.isWhitespace(text[lhs_end - 1])) : (lhs_end -= 1) {}
        if (lhs_end == 0) continue;

        const lhs_start = findInstanceofLhsStart(text, lhs_end) orelse continue;
        const lhs = std.mem.trim(u8, text[lhs_start..lhs_end], " \t");
        if (lhs.len == 0) continue;

        var type_start = i + "instanceof".len;
        while (type_start < text.len and std.ascii.isWhitespace(text[type_start])) : (type_start += 1) {}
        if (type_start >= text.len) continue;

        var type_end = type_start;
        while (type_end < text.len and isTypeNameTokenChar(text[type_end])) : (type_end += 1) {}
        const type_name = std.mem.trim(u8, text[type_start..type_end], " \t");
        if (type_name.len == 0 or !looksLikeTypeName(type_name) or !isLikelySObjectTypeForInstanceof(type_name)) continue;

        try out.appendSlice(gpa, text[last_emit..lhs_start]);
        if (std.ascii.eqlIgnoreCase(type_name, "SObject") or std.ascii.eqlIgnoreCase(type_name, "ApexSObject")) {
            try appendFmt(gpa, &out, "({s} instanceof ApexSObject)", .{lhs});
        } else {
            try appendFmt(
                gpa,
                &out,
                "\"{s}\".equals(ApexSwitch.typeName({s}))",
                .{ type_name, lhs },
            );
        }

        replaced = true;
        i = type_end - 1;
        last_emit = type_end;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn isTypeNameTokenChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

fn findInstanceofLhsStart(text: []const u8, lhs_end: usize) ?usize {
    if (lhs_end == 0) return null;

    var idx = lhs_end;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;

    while (idx > 0) {
        const ch = text[idx - 1];
        switch (ch) {
            ')' => {
                paren_depth += 1;
                idx -= 1;
                continue;
            },
            ']' => {
                bracket_depth += 1;
                idx -= 1;
                continue;
            },
            '}' => {
                brace_depth += 1;
                idx -= 1;
                continue;
            },
            '(' => {
                if (paren_depth > 0) {
                    paren_depth -= 1;
                    idx -= 1;
                    continue;
                }
                break;
            },
            '[' => {
                if (bracket_depth > 0) {
                    bracket_depth -= 1;
                    idx -= 1;
                    continue;
                }
                break;
            },
            '{' => {
                if (brace_depth > 0) {
                    brace_depth -= 1;
                    idx -= 1;
                    continue;
                }
                break;
            },
            else => {},
        }

        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and isInstanceofOperandBoundary(ch)) {
            break;
        }
        idx -= 1;
    }

    return idx;
}

fn isInstanceofKeywordAt(text: []const u8, index: usize) bool {
    const keyword = "instanceof";
    if (index + keyword.len > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[index .. index + keyword.len], keyword)) return false;
    if (index > 0 and isTypeNameTokenChar(text[index - 1])) return false;
    if (index + keyword.len < text.len and isTypeNameTokenChar(text[index + keyword.len])) return false;
    return true;
}

fn isInstanceofOperandBoundary(ch: u8) bool {
    return std.ascii.isWhitespace(ch) or
        ch == '(' or
        ch == ')' or
        ch == '[' or
        ch == ']' or
        ch == '{' or
        ch == '}' or
        ch == ',' or
        ch == ';' or
        ch == '=' or
        ch == '+' or
        ch == '-' or
        ch == '*' or
        ch == '/' or
        ch == '%' or
        ch == '!' or
        ch == '&' or
        ch == '|' or
        ch == '^' or
        ch == '<' or
        ch == '>' or
        ch == '?' or
        ch == ':';
}

fn isLikelySObjectTypeForInstanceof(type_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_name, " \t");
    if (trimmed.len == 0) return false;

    if (std.ascii.eqlIgnoreCase(trimmed, "SObject") or std.ascii.eqlIgnoreCase(trimmed, "ApexSObject")) {
        return true;
    }

    if (endsWithIgnoreCase(trimmed, "__c") or
        endsWithIgnoreCase(trimmed, "__mdt") or
        endsWithIgnoreCase(trimmed, "__e") or
        endsWithIgnoreCase(trimmed, "__x") or
        endsWithIgnoreCase(trimmed, "__b") or
        endsWithIgnoreCase(trimmed, "__kav"))
    {
        return true;
    }

    const standard_objects = [_][]const u8{
        "Account",
        "Contact",
        "Lead",
        "Opportunity",
        "Case",
        "Task",
        "Event",
        "User",
        "Group",
        "Campaign",
        "Contract",
        "Asset",
        "Product2",
        "Pricebook2",
        "OpportunityLineItem",
        "Order",
        "OrderItem",
        "Quote",
        "QuoteLineItem",
        "ContentDocument",
        "ContentVersion",
        "KnowledgeArticleVersion",
    };

    for (standard_objects) |name| {
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }

    return false;
}

fn convertInlineSoqlQueries(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch != '[') continue;

        const close_bracket = findMatchingSquareBracket(text, i) orelse continue;
        const query_raw = std.mem.trim(u8, text[(i + 1)..close_bracket], " \t");
        if (query_raw.len == 0 or !startsWithIgnoreCase(query_raw, "SELECT")) continue;

        const quoted = try quoteJavaStringLiteral(gpa, query_raw);
        defer gpa.free(quoted);
        const replacement = try std.fmt.allocPrint(gpa, "Database.query({s})", .{quoted});
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement);
        replaced = true;
        i = close_bracket;
        last_emit = close_bracket + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteDatabaseQueryStringConsumers(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!startsWithIgnoreCase(text[i..], "Database.")) continue;

        const method_candidates = [_][]const u8{
            "getQueryLocator",
            "countQuery",
            "queryWithBinds",
            "countQueryWithBinds",
            "getQueryLocatorWithBinds",
        };

        const method_start = i + "Database.".len;
        if (method_start >= text.len) continue;

        var method_name: ?[]const u8 = null;
        for (method_candidates) |candidate| {
            if (!startsWithIgnoreCase(text[method_start..], candidate)) continue;
            const boundary = method_start + candidate.len;
            if (boundary < text.len and isIdentifierChar(text[boundary])) continue;
            method_name = candidate;
            break;
        }
        if (method_name == null) continue;

        var cursor = method_start + method_name.?.len;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '(') continue;
        const close_paren = findMatchingParen(text, cursor) orelse continue;

        const args_raw = std.mem.trim(u8, text[(cursor + 1)..close_paren], " \t");
        if (args_raw.len == 0) continue;

        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);
        if (args.items.len == 0) continue;

        const first_arg = std.mem.trim(u8, args.items[0], " \t");
        const unwrapped_query = unwrapDatabaseQueryCall(first_arg) orelse continue;

        const one_arg = std.ascii.eqlIgnoreCase(method_name.?, "getQueryLocator") or
            std.ascii.eqlIgnoreCase(method_name.?, "countQuery");
        if (one_arg and args.items.len != 1) continue;
        if (!one_arg and args.items.len < 2) continue;

        var replacement: std.ArrayList(u8) = .empty;
        defer replacement.deinit(gpa);
        try appendFmt(gpa, &replacement, "Database.{s}(", .{method_name.?});
        try replacement.appendSlice(gpa, unwrapped_query);
        if (!one_arg) {
            for (args.items[1..]) |tail_arg| {
                try replacement.appendSlice(gpa, ", ");
                try replacement.appendSlice(gpa, tail_arg);
            }
        }
        try replacement.append(gpa, ')');

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement.items);
        replaced = true;
        i = close_paren;
        last_emit = close_paren + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteApexStringUtilityCalls(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    const method_names = [_][]const u8{
        "isBlank",
        "isNotBlank",
        "isEmpty",
        "isNotEmpty",
        "join",
        "escapeSingleQuotes",
    };

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!startsWithIgnoreCase(text[i..], "String.")) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;

        const method_start = i + "String.".len;
        if (method_start >= text.len) continue;

        var matched_method: ?[]const u8 = null;
        for (method_names) |method_name| {
            if (!startsWithIgnoreCase(text[method_start..], method_name)) continue;
            const method_end = method_start + method_name.len;
            if (method_end < text.len and isIdentifierChar(text[method_end])) continue;

            var call_open = method_end;
            while (call_open < text.len and std.ascii.isWhitespace(text[call_open])) : (call_open += 1) {}
            if (call_open >= text.len or text[call_open] != '(') continue;

            matched_method = method_name;
            break;
        }
        if (matched_method == null) continue;

        const method_end = method_start + matched_method.?.len;
        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "ApexStrings.{s}", .{matched_method.?});
        replaced = true;
        i = method_end - 1;
        last_emit = method_end;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn unwrapDatabaseQueryCall(arg: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (!startsWithIgnoreCase(trimmed, "Database.query")) return null;

    const method_end = "Database.query".len;
    if (method_end < trimmed.len and isIdentifierChar(trimmed[method_end])) return null;

    var cursor = method_end;
    while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
    if (cursor >= trimmed.len or trimmed[cursor] != '(') return null;

    const close_paren = findMatchingParen(trimmed, cursor) orelse return null;
    const trailing = std.mem.trim(u8, trimmed[(close_paren + 1)..], " \t");
    if (trailing.len != 0) return null;

    const inner = std.mem.trim(u8, trimmed[(cursor + 1)..close_paren], " \t");
    if (inner.len == 0) return null;
    return inner;
}

fn convertSObjectFieldAccess(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch != '.') continue;
        if (i + 1 >= text.len or !isIdentifierChar(text[i + 1])) continue;

        var end = i + 1;
        while (end < text.len and isIdentifierChar(text[end])) : (end += 1) {}
        const member = text[(i + 1)..end];
        if (!isLikelySObjectFieldName(member)) continue;

        const next_non_space = nextNonSpace(text, end);
        if (next_non_space < text.len and text[next_non_space] == '(') continue;

        if (baseIdentifierBeforeDot(text, i)) |base| {
            if (base.value.len > 0 and std.ascii.isUpper(base.value[0])) continue;
            if (std.ascii.eqlIgnoreCase(base.value, "this")) continue;
            if (isLikelyQualifiedTypeChain(text, base)) continue;
        }

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, ".getAs(\"{s}\")", .{member});
        replaced = true;
        i = end - 1;
        last_emit = end;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn isLikelySObjectFieldName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(name, "List")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Map")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Set")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Database")) return false;
    if (std.ascii.eqlIgnoreCase(name, "System")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Schema")) return false;
    if (std.ascii.isUpper(name[0])) return true;
    if (std.mem.indexOf(u8, name, "__") != null) return true;
    if (std.ascii.eqlIgnoreCase(name, "id")) return true;
    return false;
}

fn isNewKeywordAt(text: []const u8, pos: usize) bool {
    if (pos + "new".len > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + "new".len], "new")) return false;

    const left_ok = pos == 0 or !isIdentifierChar(text[pos - 1]);
    const right_idx = pos + "new".len;
    const right_ok = right_idx == text.len or !isIdentifierChar(text[right_idx]);
    return left_ok and right_ok;
}

fn appendEscapedJavaStringChar(gpa: std.mem.Allocator, out: *std.ArrayList(u8), ch: u8) !void {
    switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, ch),
    }
}

fn findMatchingParen(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '(') return null;

    var depth: i32 = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

fn findMatchingBrace(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '{') return null;

    var depth: i32 = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

fn findMatchingSquareBracket(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '[') return null;

    var depth: i32 = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        if (ch == '[') {
            depth += 1;
        } else if (ch == ']') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

fn findTopLevelMapArrow(text: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '=' => {
                if (text[i + 1] == '>' and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}

fn findTopLevelAssignmentOperator(text: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '=' => {
                if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0 or angle_depth != 0) continue;
                const prev = if (i > 0) text[i - 1] else 0;
                const next = if (i + 1 < text.len) text[i + 1] else 0;
                if (prev == '=' or prev == '!' or prev == '<' or prev == '>') continue;
                if (prev == '+' or prev == '-' or prev == '*' or prev == '/' or prev == '%' or prev == '&' or prev == '|' or prev == '^') continue;
                if (next == '=' or next == '>') continue;
                return i;
            },
            else => {},
        }
    }
    return null;
}

const TrailingIdentifierSplit = struct {
    head: []const u8,
    tail: []const u8,
};

fn splitTrailingIdentifierAtTopLevel(text: []const u8) ?TrailingIdentifierSplit {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var split_idx: ?usize = null;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            else => {
                if (std.ascii.isWhitespace(ch) and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    split_idx = i;
                }
            },
        }
    }

    if (split_idx == null) return null;
    const head = std.mem.trim(u8, text[0..split_idx.?], " \t");
    const tail = std.mem.trim(u8, text[(split_idx.? + 1)..], " \t");
    if (head.len == 0 or tail.len == 0) return null;
    if (!isSimpleIdentifier(tail)) return null;
    return .{
        .head = head,
        .tail = tail,
    };
}

const SObjectFieldLvalue = struct {
    base_expr: []const u8,
    field_name: []const u8,
};

fn parseSObjectFieldLvalue(lhs: []const u8) ?SObjectFieldLvalue {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len == 0) return null;

    const dot_pos = findLastTopLevelDot(trimmed) orelse return null;
    const base_expr = std.mem.trim(u8, trimmed[0..dot_pos], " \t");
    const field_name = std.mem.trim(u8, trimmed[(dot_pos + 1)..], " \t");
    if (base_expr.len == 0 or field_name.len == 0) return null;
    if (!isSimpleIdentifier(field_name)) return null;
    if (!isLikelySObjectFieldName(field_name)) return null;
    if (std.ascii.eqlIgnoreCase(base_expr, "this") or std.ascii.eqlIgnoreCase(base_expr, "super")) return null;
    return .{
        .base_expr = base_expr,
        .field_name = field_name,
    };
}

fn findLastTopLevelDot(text: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var last_dot: ?usize = null;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '.' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    last_dot = i;
                }
            },
            else => {},
        }
    }
    return last_dot;
}

fn nextNonSpace(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return i;
}

const IdentifierSpan = struct {
    value: []const u8,
    start: usize,
    end: usize,
};

fn baseIdentifierBeforeDot(text: []const u8, dot_pos: usize) ?IdentifierSpan {
    if (dot_pos == 0) return null;
    var idx = dot_pos;
    while (idx > 0 and std.ascii.isWhitespace(text[idx - 1])) : (idx -= 1) {}
    if (idx == 0) return null;
    if (!isIdentifierChar(text[idx - 1])) return null;

    var start = idx - 1;
    while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
    return .{
        .value = text[start..idx],
        .start = start,
        .end = idx,
    };
}

fn isLikelyQualifiedTypeChain(text: []const u8, base: IdentifierSpan) bool {
    if (base.start == 0) return false;
    if (text[base.start - 1] != '.') return false;

    const prev_span = baseIdentifierBeforeDot(text, base.start - 1) orelse return false;
    if (prev_span.value.len == 0 or base.value.len == 0) return false;

    const prev_lower = std.ascii.isLower(prev_span.value[0]);
    const base_lower = std.ascii.isLower(base.value[0]);
    return prev_lower and base_lower;
}

fn uniqueMethodName(
    gpa: std.mem.Allocator,
    name_counts: *std.StringHashMap(usize),
    method_name: []const u8,
) ![]u8 {
    const normalized = method_name;
    if (name_counts.get(normalized)) |seen| {
        const next = seen + 1;
        try name_counts.put(normalized, next);
        return std.fmt.allocPrint(gpa, "{s}__apex{d}", .{ method_name, next });
    }

    try name_counts.put(normalized, 1);
    return gpa.dupe(u8, method_name);
}

fn writeOutputFile(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            try std.fs.cwd().makePath(parent);
        }
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn appendFmt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
}

fn isApexClassSource(path: []const u8) bool {
    return std.fs.path.extension(path).len == 4 and std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".cls");
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn isIsTestAnnotation(line: []const u8) bool {
    if (line.len < 7) return false;
    if (line[0] != '@') return false;
    return startsWithIgnoreCase(line, "@istest");
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(
        haystack[haystack.len - needle.len ..],
        needle,
    );
}

fn startsWithWordIgnoreCase(haystack: []const u8, keyword: []const u8) bool {
    if (!startsWithIgnoreCase(haystack, keyword)) return false;
    if (haystack.len == keyword.len) return true;
    const next = haystack[keyword.len];
    return std.ascii.isWhitespace(next) or next == '(';
}

fn isControlFlowLine(line: []const u8) bool {
    if (isDoWhileTailLine(line)) return true;
    if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) return true;
    const keywords = [_][]const u8{
        "if",       "else",    "for",    "while", "do",     "try",
        "catch",    "finally", "switch", "when",  "return", "break",
        "continue",
    };
    for (keywords) |keyword| {
        if (startsWithWordIgnoreCase(line, keyword)) return true;
    }
    return false;
}

fn isDoWhileTailLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 8 or trimmed[0] != '}') return false;

    var rest = std.mem.trimLeft(u8, trimmed[1..], " \t");
    if (!startsWithWordIgnoreCase(rest, "while")) return false;
    rest = std.mem.trimLeft(u8, rest["while".len..], " \t");
    if (rest.len == 0 or rest[0] != '(') return false;

    const close = findMatchingParen(rest, 0) orelse return false;
    const after = std.mem.trim(u8, rest[(close + 1)..], " \t");
    return after.len == 0 or std.mem.eql(u8, after, ";");
}

fn normalizeApexDoWhileTailLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!isDoWhileTailLine(trimmed)) return null;

    var rest = std.mem.trimLeft(u8, trimmed[1..], " \t");
    rest = std.mem.trimLeft(u8, rest["while".len..], " \t");
    const close = findMatchingParen(rest, 0) orelse return null;

    const condition_raw = std.mem.trim(u8, rest[1..close], " \t");
    if (condition_raw.len == 0) return null;
    const converted_condition = try convertApexExpressionToJava(gpa, condition_raw);
    defer gpa.free(converted_condition);

    const after = std.mem.trim(u8, rest[(close + 1)..], " \t");
    const has_semicolon = std.mem.eql(u8, after, ";");
    if (has_semicolon) {
        return try std.fmt.allocPrint(gpa, "}} while ({s});", .{converted_condition});
    }
    return try std.fmt.allocPrint(gpa, "}} while ({s})", .{converted_condition});
}

fn indexOfSoqlBracketSelect(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '[') continue;
        const tail = line[(i + 1)..];
        const trimmed = std.mem.trimLeft(u8, tail, " \t");
        if (startsWithIgnoreCase(trimmed, "SELECT")) return i;
    }
    return null;
}

fn quoteJavaStringLiteral(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.append(gpa, '"');
    for (raw) |ch| {
        try appendEscapedJavaStringChar(gpa, &out, ch);
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

fn normalizeForHeaderTypes(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return gpa.dupe(u8, line);
    const close_paren = findMatchingParen(line, open_paren) orelse return gpa.dupe(u8, line);

    const header = line[(open_paren + 1)..close_paren];
    if (std.mem.indexOfScalar(u8, header, ':')) |colon_pos| {
        const left = std.mem.trim(u8, header[0..colon_pos], " \t");
        const right = std.mem.trim(u8, header[(colon_pos + 1)..], " \t");
        const var_name = lastIdentifier(left) orelse return gpa.dupe(u8, line);
        const type_segment = std.mem.trimRight(u8, left[0..(left.len - var_name.len)], " \t");
        if (type_segment.len == 0) return gpa.dupe(u8, line);

        const java_type = try convertApexType(gpa, type_segment);
        defer gpa.free(java_type);

        const prefix = line[0..(open_paren + 1)];
        const suffix = line[close_paren..];
        return std.fmt.allocPrint(
            gpa,
            "{s}{s} {s} : {s}{s}",
            .{ prefix, java_type, var_name, right, suffix },
        );
    }

    return gpa.dupe(u8, line);
}

fn normalizeApexSwitchHeader(gpa: std.mem.Allocator, line: []const u8, mode: SwitchMode) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!startsWithWordIgnoreCase(trimmed, "switch")) return gpa.dupe(u8, line);

    var rest = std.mem.trimLeft(u8, trimmed["switch".len..], " \t");
    if (rest.len == 0) return gpa.dupe(u8, line);
    if (rest[0] == '(') return gpa.dupe(u8, line);
    if (!startsWithWordIgnoreCase(rest, "on")) return gpa.dupe(u8, line);

    rest = std.mem.trimLeft(u8, rest["on".len..], " \t");
    if (rest.len == 0) return gpa.dupe(u8, line);

    const has_block = rest[rest.len - 1] == '{';
    const expr = if (has_block)
        std.mem.trimRight(u8, rest[0 .. rest.len - 1], " \t")
    else
        std.mem.trim(u8, rest, " \t");
    if (expr.len == 0) return gpa.dupe(u8, line);

    const wrapped_expr = if (mode == .typed)
        try std.fmt.allocPrint(gpa, "ApexSwitch.typeName({s})", .{expr})
    else
        try gpa.dupe(u8, expr);
    defer gpa.free(wrapped_expr);

    if (has_block) {
        return std.fmt.allocPrint(gpa, "switch ({s}) {{", .{wrapped_expr});
    }
    return std.fmt.allocPrint(gpa, "switch ({s})", .{wrapped_expr});
}

const ApexWhenTypePattern = struct {
    type_name: []const u8,
    binding_name: []const u8,
};

fn parseApexWhenTypePattern(gpa: std.mem.Allocator, text: []const u8) !?ApexWhenTypePattern {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, ',')) |_| return null;

    var parts = try splitTopLevelWhitespaceExpressions(gpa, trimmed);
    defer parts.deinit(gpa);
    if (parts.items.len != 2) return null;

    const type_name = std.mem.trim(u8, parts.items[0], " \t");
    const binding_name = std.mem.trim(u8, parts.items[1], " \t");
    if (!looksLikeTypeName(type_name)) return null;
    if (!isSimpleIdentifier(binding_name)) return null;
    return .{
        .type_name = type_name,
        .binding_name = binding_name,
    };
}

fn normalizeApexWhenLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    active_switch_expr: ?[]const u8,
    active_switch_mode: SwitchMode,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!startsWithWordIgnoreCase(trimmed, "when")) return null;

    var rest = std.mem.trimLeft(u8, trimmed["when".len..], " \t");
    if (rest.len == 0) return null;
    const has_block = rest[rest.len - 1] == '{';
    if (has_block) {
        rest = std.mem.trimRight(u8, rest[0 .. rest.len - 1], " \t");
        if (rest.len == 0) return null;
    }

    if (startsWithWordIgnoreCase(rest, "else")) {
        const trailing = std.mem.trimLeft(u8, rest["else".len..], " \t");
        if (trailing.len != 0) return null;
        if (has_block) return try gpa.dupe(u8, "default -> {");
        return try gpa.dupe(u8, "default ->");
    }

    if (active_switch_mode == .typed) {
        if (try parseApexWhenTypePattern(gpa, rest)) |pattern| {
            if (!has_block) return null;
            const switch_expr = active_switch_expr orelse return null;
            const java_type = try convertApexType(gpa, pattern.type_name);
            defer gpa.free(java_type);
            return try std.fmt.allocPrint(
                gpa,
                "case \"{s}\" -> {{ {s} {s} = {s};",
                .{ pattern.type_name, java_type, pattern.binding_name, switch_expr },
            );
        }
    }

    var values = try splitCallArguments(gpa, rest);
    defer values.deinit(gpa);
    if (values.items.len == 0) return null;

    var converted_values: std.ArrayList([]u8) = .empty;
    defer {
        for (converted_values.items) |value| gpa.free(value);
        converted_values.deinit(gpa);
    }

    for (values.items) |value| {
        if (std.mem.indexOf(u8, value, "..") != null) return null;
        var ws_parts = try splitTopLevelWhitespaceExpressions(gpa, value);
        defer ws_parts.deinit(gpa);
        if (ws_parts.items.len > 1) return null;

        try converted_values.append(gpa, try convertApexExpressionToJava(gpa, value));
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "case ");
    for (converted_values.items, 0..) |value, idx| {
        if (idx != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, value);
    }
    try out.appendSlice(gpa, " ->");
    if (has_block) try out.appendSlice(gpa, " {");
    return try out.toOwnedSlice(gpa);
}

fn parseSwitchSubjectExpression(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!startsWithWordIgnoreCase(trimmed, "switch")) return null;

    var rest = std.mem.trimLeft(u8, trimmed["switch".len..], " \t");
    if (rest.len == 0) return null;

    if (startsWithWordIgnoreCase(rest, "on")) {
        rest = std.mem.trimLeft(u8, rest["on".len..], " \t");
        if (rest.len == 0) return null;
        const has_block = rest[rest.len - 1] == '{';
        const expr = if (has_block)
            std.mem.trimRight(u8, rest[0 .. rest.len - 1], " \t")
        else
            std.mem.trim(u8, rest, " \t");
        if (expr.len == 0) return null;
        return expr;
    }

    if (rest[0] != '(') return null;
    const close = findMatchingParen(rest, 0) orelse return null;
    const expr = std.mem.trim(u8, rest[1..close], " \t");
    if (expr.len == 0) return null;
    return expr;
}

fn detectSwitchMode(
    gpa: std.mem.Allocator,
    statements: []const []u8,
    start_idx: usize,
) !SwitchMode {
    if (start_idx >= statements.len) return .value;
    const start_stmt = std.mem.trim(u8, statements[start_idx], " \t");
    if (!startsWithWordIgnoreCase(start_stmt, "switch")) return .value;

    var depth = braceDelta(start_stmt);
    if (depth <= 0) depth = 1;

    var i = start_idx + 1;
    while (i < statements.len and depth > 0) : (i += 1) {
        const stmt = std.mem.trim(u8, statements[i], " \t");
        if (depth == 1 and startsWithWordIgnoreCase(stmt, "when")) {
            var rest = std.mem.trimLeft(u8, stmt["when".len..], " \t");
            if (rest.len > 0 and rest[rest.len - 1] == '{') {
                rest = std.mem.trimRight(u8, rest[0 .. rest.len - 1], " \t");
            }
            if (!startsWithWordIgnoreCase(rest, "else") and (try parseApexWhenTypePattern(gpa, rest)) != null) {
                return .typed;
            }
        }
        depth += braceDelta(stmt);
    }

    return .value;
}

fn containsWordIgnoreCase(text: []const u8, word: []const u8) bool {
    return indexOfWordIgnoreCase(text, word) != null;
}

fn indexOfWordIgnoreCase(text: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or text.len < word.len) return null;
    var i: usize = 0;
    while (i + word.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) continue;
        const left_ok = i == 0 or !isIdentifierChar(text[i - 1]);
        const right_idx = i + word.len;
        const right_ok = right_idx == text.len or !isIdentifierChar(text[right_idx]);
        if (left_ok and right_ok) return i;
    }
    return null;
}

fn splitWhitespace(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        try out.append(gpa, token);
    }
    return out;
}

fn firstIdentifier(text: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < text.len and !isIdentifierChar(text[idx])) : (idx += 1) {}
    if (idx == text.len) return null;
    const start = idx;
    while (idx < text.len and isIdentifierChar(text[idx])) : (idx += 1) {}
    return text[start..idx];
}

fn leadingIdentifier(text: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < text.len and std.ascii.isWhitespace(text[idx])) : (idx += 1) {}
    if (idx >= text.len or !isIdentifierChar(text[idx])) return null;
    const start = idx;
    while (idx < text.len and isIdentifierChar(text[idx])) : (idx += 1) {}
    return text[start..idx];
}

fn lastIdentifier(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    var end = text.len;
    while (end > 0 and !isIdentifierChar(text[end - 1])) : (end -= 1) {}
    if (end == 0) return null;
    var start = end;
    while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
    return text[start..end];
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isSimpleIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return false;
    for (value[1..]) |ch| {
        if (!isIdentifierChar(ch)) return false;
    }
    return true;
}

fn isDeclarationModifier(token: []const u8, allow_visibility: bool) bool {
    if (std.ascii.eqlIgnoreCase(token, "final")) return true;
    if (std.ascii.eqlIgnoreCase(token, "static")) return true;
    if (std.ascii.eqlIgnoreCase(token, "transient")) return true;
    if (!allow_visibility) return false;
    return std.ascii.eqlIgnoreCase(token, "public") or
        std.ascii.eqlIgnoreCase(token, "private") or
        std.ascii.eqlIgnoreCase(token, "protected") or
        std.ascii.eqlIgnoreCase(token, "global");
}

fn normalizeDeclarationModifier(token: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(token, "global")) return "public";
    if (std.ascii.eqlIgnoreCase(token, "public")) return "public";
    if (std.ascii.eqlIgnoreCase(token, "private")) return "private";
    if (std.ascii.eqlIgnoreCase(token, "protected")) return "protected";
    if (std.ascii.eqlIgnoreCase(token, "final")) return "final";
    if (std.ascii.eqlIgnoreCase(token, "static")) return "static";
    if (std.ascii.eqlIgnoreCase(token, "transient")) return "transient";
    return token;
}

fn looksLikeTypeName(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '<') != null) return true;
    if (std.mem.indexOf(u8, trimmed, "[]") != null) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "int")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "long")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "double")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "float")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "short")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "byte")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "boolean")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "char")) return true;
    return std.ascii.isUpper(trimmed[0]);
}

fn isControlKeyword(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, "if") or
        std.ascii.eqlIgnoreCase(word, "for") or
        std.ascii.eqlIgnoreCase(word, "while") or
        std.ascii.eqlIgnoreCase(word, "switch") or
        std.ascii.eqlIgnoreCase(word, "catch") or
        std.ascii.eqlIgnoreCase(word, "else") or
        std.ascii.eqlIgnoreCase(word, "return") or
        std.ascii.eqlIgnoreCase(word, "do");
}

fn isMethodModifierToken(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "public") or
        std.ascii.eqlIgnoreCase(token, "private") or
        std.ascii.eqlIgnoreCase(token, "protected") or
        std.ascii.eqlIgnoreCase(token, "global") or
        std.ascii.eqlIgnoreCase(token, "static") or
        std.ascii.eqlIgnoreCase(token, "final") or
        std.ascii.eqlIgnoreCase(token, "virtual") or
        std.ascii.eqlIgnoreCase(token, "override") or
        std.ascii.eqlIgnoreCase(token, "abstract") or
        std.ascii.eqlIgnoreCase(token, "testmethod") or
        std.ascii.eqlIgnoreCase(token, "webservice") or
        std.ascii.eqlIgnoreCase(token, "transient");
}

fn braceDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    for (line) |ch| {
        switch (ch) {
            '{' => delta += 1,
            '}' => delta -= 1,
            else => {},
        }
    }
    return delta;
}

fn isValidPackageName(name: []const u8) bool {
    if (name.len == 0) return false;
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (!std.ascii.isAlphabetic(part[0]) and part[0] != '_') return false;
        for (part[1..]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        }
    }
    return true;
}

test "parseMethodSignature preserves return type params and static" {
    const gpa = std.testing.allocator;
    const sig = (try parseMethodSignature(gpa, "public static List<Id> run(List<Account> records, Integer n) {", "Demo")).?;
    defer {
        gpa.free(sig.name);
        gpa.free(sig.java_return_type);
        gpa.free(sig.java_parameters);
    }

    try std.testing.expectEqualStrings("run", sig.name);
    try std.testing.expectEqualStrings("List<String>", sig.java_return_type);
    try std.testing.expectEqualStrings("List<ApexSObject> records, Integer n", sig.java_parameters);
    try std.testing.expect(sig.is_static);

    const sig_map = (try parseMethodSignature(gpa, "public static Map<Id, Account> build(List<Account> records) {", "Demo")).?;
    defer {
        gpa.free(sig_map.name);
        gpa.free(sig_map.java_return_type);
        gpa.free(sig_map.java_parameters);
    }
    try std.testing.expectEqualStrings("build", sig_map.name);
    try std.testing.expectEqualStrings("Map<String, ApexSObject>", sig_map.java_return_type);
    try std.testing.expectEqualStrings("List<ApexSObject> records", sig_map.java_parameters);
    try std.testing.expect(sig_map.is_static);

    try std.testing.expect((try parseMethodSignature(gpa, "for (Integer i = 0; i < 10; i++) {", "Demo")) == null);
    try std.testing.expect((try parseMethodSignature(gpa, "if (records == null) {", "Demo")) == null);
    try std.testing.expect((try parseMethodSignature(gpa, "public Demo() {", "Demo")) == null);
}

test "renderJavaClass emits test annotation and method comment body" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "SampleTest"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/SampleTest.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "firstMethod"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, ""),
        .is_static = true,
        .is_constructor = false,
        .is_test = true,
        .body = try gpa.dupe(u8, "System.assertEquals(1, 1);\n"),
    });

    const output = try renderJavaClass(gpa, parsed, "generated");
    defer gpa.free(output.java);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "package generated;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "@Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static void firstMethod()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "import apexemu.runtime.ApexAssert;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "SystemAssert.assertEquals(1, 1);") != null);
}

test "detectClassIsTest catches annotation immediately before class" {
    const source =
        \\@IsTest
        \\private class DemoTest {
        \\  static void testOne() {}
        \\}
    ;
    try std.testing.expect(detectClassIsTest(source));
}

test "transpileAssertionLine converts System.assert overloads" {
    const gpa = std.testing.allocator;
    const one = try transpileAssertionLine(gpa, "System.assert(total > 0, 'must be positive');");
    defer if (one) |value| gpa.free(value);
    try std.testing.expect(one != null);
    try std.testing.expectEqualStrings(
        "SystemAssert.assertTrue(total > 0, \"must be positive\");",
        one.?,
    );

    const two = try transpileAssertionLine(gpa, "System.assertEquals(1, actual, 'don''t fail');");
    defer if (two) |value| gpa.free(value);
    try std.testing.expect(two != null);
    try std.testing.expectEqualStrings(
        "SystemAssert.assertEquals(1, actual, \"don't fail\");",
        two.?,
    );

    const non_assert = try transpileAssertionLine(gpa, "System.debug('noop');");
    try std.testing.expect(non_assert == null);
}

test "transpileAssertionLine converts Assert and System.Assert API" {
    const gpa = std.testing.allocator;

    const one = try transpileAssertionLine(gpa, "Assert.isTrue(total > 0, 'must be positive');");
    defer if (one) |value| gpa.free(value);
    try std.testing.expect(one != null);
    try std.testing.expectEqualStrings(
        "ApexAssert.isTrue(total > 0, \"must be positive\");",
        one.?,
    );

    const two = try transpileAssertionLine(gpa, "System.Assert.areEqual(1, actual, 'don''t fail');");
    defer if (two) |value| gpa.free(value);
    try std.testing.expect(two != null);
    try std.testing.expectEqualStrings(
        "ApexAssert.areEqual(1, actual, \"don't fail\");",
        two.?,
    );

    const three = try transpileAssertionLine(gpa, "Assert.fail();");
    defer if (three) |value| gpa.free(value);
    try std.testing.expect(three != null);
    try std.testing.expectEqualStrings(
        "ApexAssert.fail();",
        three.?,
    );

    const four = try transpileAssertionLine(gpa, "Assert.isInstanceOfType(record, Account.class, 'expected account');");
    defer if (four) |value| gpa.free(value);
    try std.testing.expect(four != null);
    try std.testing.expectEqualStrings(
        "ApexAssert.isInstanceOfType(record, \"Account\", \"expected account\");",
        four.?,
    );

    const five = try transpileAssertionLine(gpa, "System.Assert.isNotInstanceOfType(payload, Contact.class);");
    defer if (five) |value| gpa.free(value);
    try std.testing.expect(five != null);
    try std.testing.expectEqualStrings(
        "ApexAssert.isNotInstanceOfType(payload, \"Contact\");",
        five.?,
    );
}

test "transpileSystemDebugLine converts to println and keeps last arg" {
    const gpa = std.testing.allocator;

    const one = try transpileSystemDebugLine(gpa, "System.debug('hello');");
    defer if (one) |value| gpa.free(value);
    try std.testing.expect(one != null);
    try std.testing.expectEqualStrings("System.out.println(\"hello\");", one.?);

    const two = try transpileSystemDebugLine(gpa, "System.debug(LoggingLevel.ERROR, 'fail');");
    defer if (two) |value| gpa.free(value);
    try std.testing.expect(two != null);
    try std.testing.expectEqualStrings("System.out.println(\"fail\");", two.?);

    const three = try transpileSystemDebugLine(gpa, "System.debug(new List<Id>());");
    defer if (three) |value| gpa.free(value);
    try std.testing.expect(three != null);
    try std.testing.expectEqualStrings("System.out.println(new ArrayList<String>());", three.?);
}

test "transpileCollectionDeclarationLine converts list map set declarations" {
    const gpa = std.testing.allocator;

    const list_line = try transpileCollectionDeclarationLine(gpa, "List<Id> ids = new List<Id>();");
    defer if (list_line) |value| gpa.free(value);
    try std.testing.expect(list_line != null);
    try std.testing.expectEqualStrings(
        "List<String> ids = new ArrayList<>();",
        list_line.?,
    );

    const map_line = try transpileCollectionDeclarationLine(
        gpa,
        "Map<Id, Account> accountMap = new Map<Id, Account>();",
    );
    defer if (map_line) |value| gpa.free(value);
    try std.testing.expect(map_line != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = new LinkedHashMap<>();",
        map_line.?,
    );

    const set_line = try transpileCollectionDeclarationLine(gpa, "final Set<Id> accountIds = new Set<Id>();");
    defer if (set_line) |value| gpa.free(value);
    try std.testing.expect(set_line != null);
    try std.testing.expectEqualStrings(
        "Set<String> accountIds = new LinkedHashSet<>();",
        set_line.?,
    );

    const map_from_query = try transpileCollectionDeclarationLine(
        gpa,
        "Map<Id, Account> accountMap = new Map<Id, Account>([SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10]);",
    );
    defer if (map_from_query) |value| gpa.free(value);
    try std.testing.expect(map_from_query != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.mapById(Database.query(\"SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10\"));",
        map_from_query.?,
    );

    const map_from_query_spaced = try transpileCollectionDeclarationLine(
        gpa,
        "Map<Id, Account> accountMap = new Map<Id, Account>( [ SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10 ] );",
    );
    defer if (map_from_query_spaced) |value| gpa.free(value);
    try std.testing.expect(map_from_query_spaced != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.mapById(Database.query(\"SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10\"));",
        map_from_query_spaced.?,
    );

    const map_from_list = try transpileCollectionDeclarationLine(
        gpa,
        "Map<Id, Account> accountMap = new Map<Id, Account>(records);",
    );
    defer if (map_from_list) |value| gpa.free(value);
    try std.testing.expect(map_from_list != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.toIdMap(records);",
        map_from_list.?,
    );

    const map_from_existing_map = try transpileCollectionDeclarationLine(
        gpa,
        "Map<Id, Account> copied = new Map<Id, Account>(existingMap);",
    );
    defer if (map_from_existing_map) |value| gpa.free(value);
    try std.testing.expect(map_from_existing_map != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> copied = ApexCollections.toIdMap(existingMap);",
        map_from_existing_map.?,
    );
}

test "transpileSoqlAndDmlAndControlLines" {
    const gpa = std.testing.allocator;

    const soql = try transpileSoqlLine(gpa, "List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :accId LIMIT 5];");
    defer if (soql) |value| gpa.free(value);
    try std.testing.expect(soql != null);
    try std.testing.expect(std.mem.indexOf(u8, soql.?, "Database.query(") != null);

    const dml = try transpileDmlLine(gpa, "insert contacts;");
    defer if (dml) |value| gpa.free(value);
    try std.testing.expect(dml != null);
    try std.testing.expectEqualStrings("Database.insert(contacts);", dml.?);

    const control = try transpileControlFlowLine(gpa, "for (Id accountId : accountIds) {");
    defer if (control) |value| gpa.free(value);
    try std.testing.expect(control != null);
    try std.testing.expectEqualStrings("for (String accountId : accountIds) {", control.?);

    const close_brace = try transpileControlFlowLine(gpa, "}");
    defer if (close_brace) |value| gpa.free(value);
    try std.testing.expect(close_brace != null);
    try std.testing.expectEqualStrings("}", close_brace.?);

    const return_with_new = try transpileControlFlowLine(gpa, "return new Map<Id, Account>();");
    defer if (return_with_new) |value| gpa.free(value);
    try std.testing.expect(return_with_new != null);
    try std.testing.expectEqualStrings("return new LinkedHashMap<String, ApexSObject>();", return_with_new.?);
}

test "transpileControlFlowLine converts apex switch/when syntax" {
    const gpa = std.testing.allocator;

    const switch_header = try transpileControlFlowLine(gpa, "switch on stageName {");
    defer if (switch_header) |value| gpa.free(value);
    try std.testing.expect(switch_header != null);
    try std.testing.expectEqualStrings("switch (stageName) {", switch_header.?);

    const when_values = try transpileControlFlowLine(gpa, "when 'New', 'Working' {");
    defer if (when_values) |value| gpa.free(value);
    try std.testing.expect(when_values != null);
    try std.testing.expectEqualStrings("case \"New\", \"Working\" -> {", when_values.?);

    const when_else = try transpileControlFlowLine(gpa, "when else {");
    defer if (when_else) |value| gpa.free(value);
    try std.testing.expect(when_else != null);
    try std.testing.expectEqualStrings("default -> {", when_else.?);

    const unsupported_pattern = try transpileControlFlowLine(gpa, "when Account acc {");
    try std.testing.expect(unsupported_pattern == null);
}

test "transpileControlFlowLine supports typed when with switch context" {
    const gpa = std.testing.allocator;

    const typed_switch = try transpileControlFlowLineWithContext(
        gpa,
        "switch on record {",
        null,
        .value,
        .typed,
    );
    defer if (typed_switch) |value| gpa.free(value);
    try std.testing.expect(typed_switch != null);
    try std.testing.expectEqualStrings("switch (ApexSwitch.typeName(record)) {", typed_switch.?);

    const typed_when = try transpileControlFlowLineWithContext(
        gpa,
        "when Account acc {",
        "record",
        .typed,
        null,
    );
    defer if (typed_when) |value| gpa.free(value);
    try std.testing.expect(typed_when != null);
    try std.testing.expectEqualStrings(
        "case \"Account\" -> { ApexSObject acc = record;",
        typed_when.?,
    );

    const typed_else = try transpileControlFlowLineWithContext(
        gpa,
        "when else {",
        "record",
        .typed,
        null,
    );
    defer if (typed_else) |value| gpa.free(value);
    try std.testing.expect(typed_else != null);
    try std.testing.expectEqualStrings("default -> {", typed_else.?);
}

test "transpileControlFlowLine rewrites sobject instanceof checks" {
    const gpa = std.testing.allocator;

    const sobject_instanceof = try transpileControlFlowLine(
        gpa,
        "if (record instanceof Account) {",
    );
    defer if (sobject_instanceof) |value| gpa.free(value);
    try std.testing.expect(sobject_instanceof != null);
    try std.testing.expectEqualStrings(
        "if (\"Account\".equals(ApexSwitch.typeName(record))) {",
        sobject_instanceof.?,
    );

    const scalar_instanceof = try transpileControlFlowLine(
        gpa,
        "if (value instanceof Integer) {",
    );
    defer if (scalar_instanceof) |value| gpa.free(value);
    try std.testing.expect(scalar_instanceof != null);
    try std.testing.expectEqualStrings(
        "if (value instanceof Integer) {",
        scalar_instanceof.?,
    );

    const negated_instanceof = try transpileControlFlowLine(
        gpa,
        "if (!(record instanceof Contact)) {",
    );
    defer if (negated_instanceof) |value| gpa.free(value);
    try std.testing.expect(negated_instanceof != null);
    try std.testing.expectEqualStrings(
        "if (!(\"Contact\".equals(ApexSwitch.typeName(record)))) {",
        negated_instanceof.?,
    );

    const multi_branch_instanceof = try transpileControlFlowLine(
        gpa,
        "if (record instanceof Account || record instanceof Contact) {",
    );
    defer if (multi_branch_instanceof) |value| gpa.free(value);
    try std.testing.expect(multi_branch_instanceof != null);
    try std.testing.expectEqualStrings(
        "if (\"Account\".equals(ApexSwitch.typeName(record)) || \"Contact\".equals(ApexSwitch.typeName(record))) {",
        multi_branch_instanceof.?,
    );

    const generic_sobject_instanceof = try transpileControlFlowLine(
        gpa,
        "if (record instanceof SObject) {",
    );
    defer if (generic_sobject_instanceof) |value| gpa.free(value);
    try std.testing.expect(generic_sobject_instanceof != null);
    try std.testing.expectEqualStrings(
        "if ((record instanceof ApexSObject)) {",
        generic_sobject_instanceof.?,
    );

    const class_instanceof = try transpileControlFlowLine(
        gpa,
        "if (value instanceof CustomService) {",
    );
    defer if (class_instanceof) |value| gpa.free(value);
    try std.testing.expect(class_instanceof != null);
    try std.testing.expectEqualStrings(
        "if (value instanceof CustomService) {",
        class_instanceof.?,
    );

    const do_header = try transpileControlFlowLine(gpa, "do {");
    defer if (do_header) |value| gpa.free(value);
    try std.testing.expect(do_header != null);
    try std.testing.expectEqualStrings("do {", do_header.?);

    const do_tail = try transpileControlFlowLine(
        gpa,
        "} while (records[i] instanceof Account);",
    );
    defer if (do_tail) |value| gpa.free(value);
    try std.testing.expect(do_tail != null);
    try std.testing.expectEqualStrings(
        "} while (\"Account\".equals(ApexSwitch.typeName(records.get(i))));",
        do_tail.?,
    );
}

test "transpileSoqlLine supports list map and single-sobject declarations" {
    const gpa = std.testing.allocator;

    const list_decl = try transpileSoqlLine(gpa, "List<Account> rows = [SELECT Id, Name FROM Account LIMIT 10];");
    defer if (list_decl) |value| gpa.free(value);
    try std.testing.expect(list_decl != null);
    try std.testing.expectEqualStrings(
        "List<ApexSObject> rows = Database.query(\"SELECT Id, Name FROM Account LIMIT 10\");",
        list_decl.?,
    );

    const map_decl = try transpileSoqlLine(gpa, "Map<Id, Account> accountMap = [SELECT Id, Name FROM Account LIMIT 10];");
    defer if (map_decl) |value| gpa.free(value);
    try std.testing.expect(map_decl != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.mapById(Database.query(\"SELECT Id, Name FROM Account LIMIT 10\"));",
        map_decl.?,
    );

    const single_decl = try transpileSoqlLine(gpa, "Account acc = [SELECT Id, Name FROM Account LIMIT 1];");
    defer if (single_decl) |value| gpa.free(value);
    try std.testing.expect(single_decl != null);
    try std.testing.expectEqualStrings(
        "ApexSObject acc = ApexCollections.firstOrNull(Database.query(\"SELECT Id, Name FROM Account LIMIT 1\"));",
        single_decl.?,
    );
}

test "transpileExecutableLine prefers collection declaration rewrite for map query initializer" {
    const gpa = std.testing.allocator;
    const line = "Map<Id, Account> accountMap = new Map<Id, Account>([SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10]);";
    const converted = try transpileExecutableLine(gpa, line);
    defer if (converted) |value| gpa.free(value);
    try std.testing.expect(converted != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.mapById(Database.query(\"SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10\"));",
        converted.?,
    );
}

test "convertApexExpressionToJava converts nested inline collection constructors" {
    const gpa = std.testing.allocator;
    const converted = try convertApexExpressionToJava(
        gpa,
        "new Map<Id, Account>(new Map<Id, Account>())",
    );
    defer gpa.free(converted);
    try std.testing.expectEqualStrings(
        "ApexCollections.toIdMap(new LinkedHashMap<String, ApexSObject>())",
        converted,
    );

    const from_list = try convertApexExpressionToJava(
        gpa,
        "new Map<Id, Account>(records)",
    );
    defer gpa.free(from_list);
    try std.testing.expectEqualStrings(
        "ApexCollections.toIdMap(records)",
        from_list,
    );
}

test "convertApexExpressionToJava rewrites database query-string consumers" {
    const gpa = std.testing.allocator;

    const locator = try convertApexExpressionToJava(
        gpa,
        "Database.getQueryLocator([SELECT Id FROM Account])",
    );
    defer gpa.free(locator);
    try std.testing.expectEqualStrings(
        "Database.getQueryLocator(\"SELECT Id FROM Account\")",
        locator,
    );

    const count = try convertApexExpressionToJava(
        gpa,
        "Database.countQuery([SELECT Id FROM Account WHERE Name = :name])",
    );
    defer gpa.free(count);
    try std.testing.expectEqualStrings(
        "Database.countQuery(\"SELECT Id FROM Account WHERE Name = :name\")",
        count,
    );

    const with_binds = try convertApexExpressionToJava(
        gpa,
        "Database.queryWithBinds([SELECT Id FROM Account WHERE Name = :name], binds)",
    );
    defer gpa.free(with_binds);
    try std.testing.expectEqualStrings(
        "Database.queryWithBinds(\"SELECT Id FROM Account WHERE Name = :name\", binds)",
        with_binds,
    );

    const count_with_binds = try convertApexExpressionToJava(
        gpa,
        "Database.countQueryWithBinds([SELECT Id FROM Account WHERE Name = :name], binds)",
    );
    defer gpa.free(count_with_binds);
    try std.testing.expectEqualStrings(
        "Database.countQueryWithBinds(\"SELECT Id FROM Account WHERE Name = :name\", binds)",
        count_with_binds,
    );

    const locator_with_binds = try convertApexExpressionToJava(
        gpa,
        "Database.getQueryLocatorWithBinds([SELECT Id FROM Account WHERE Name IN :names], binds)",
    );
    defer gpa.free(locator_with_binds);
    try std.testing.expectEqualStrings(
        "Database.getQueryLocatorWithBinds(\"SELECT Id FROM Account WHERE Name IN :names\", binds)",
        locator_with_binds,
    );
}

test "convertApexExpressionToJava rewrites apex string utility calls" {
    const gpa = std.testing.allocator;

    const is_blank = try convertApexExpressionToJava(gpa, "String.isBlank(name)");
    defer gpa.free(is_blank);
    try std.testing.expectEqualStrings("ApexStrings.isBlank(name)", is_blank);

    const join_call = try convertApexExpressionToJava(
        gpa,
        "String.join(new List<String>{'A', 'B'}, ',')",
    );
    defer gpa.free(join_call);
    try std.testing.expectEqualStrings(
        "ApexStrings.join(new ArrayList<String>(java.util.List.of(\"A\", \"B\")), \",\")",
        join_call,
    );

    const escape_call = try convertApexExpressionToJava(gpa, "String.escapeSingleQuotes(lastName)");
    defer gpa.free(escape_call);
    try std.testing.expectEqualStrings("ApexStrings.escapeSingleQuotes(lastName)", escape_call);
}

test "parseConstructorSignature captures constructor params" {
    const gpa = std.testing.allocator;
    const sig = (try parseConstructorSignature(gpa, "public Demo(String name, List<Account> records) {", "Demo")).?;
    defer {
        gpa.free(sig.name);
        gpa.free(sig.java_return_type);
        gpa.free(sig.java_parameters);
    }

    try std.testing.expectEqualStrings("Demo", sig.name);
    try std.testing.expectEqualStrings("", sig.java_return_type);
    try std.testing.expectEqualStrings("String name, List<ApexSObject> records", sig.java_parameters);
    try std.testing.expect(!sig.is_static);
    try std.testing.expect(sig.is_constructor);
}

test "transpileClassMemberLine converts fields and properties" {
    const gpa = std.testing.allocator;

    const field_line = try transpileClassMemberLine(gpa, "private static final List<Account> cache = new List<Account>();");
    defer if (field_line) |value| gpa.free(value);
    try std.testing.expect(field_line != null);
    try std.testing.expectEqualStrings(
        "private static final List<ApexSObject> cache = new ArrayList<ApexSObject>();",
        field_line.?,
    );

    const property_line = try transpileClassMemberLine(gpa, "public String Name { get; set; }");
    defer if (property_line) |value| gpa.free(value);
    try std.testing.expect(property_line != null);
    try std.testing.expectEqualStrings(
        "public String Name; // Apex property { get; set; }",
        property_line.?,
    );
}

test "transpileGenericStatementLine converts declarations assignments and calls" {
    const gpa = std.testing.allocator;

    const decl = try transpileGenericStatementLine(gpa, "Integer sizeHint = tasksToInsert.size();");
    defer if (decl) |value| gpa.free(value);
    try std.testing.expect(decl != null);
    try std.testing.expectEqualStrings("Integer sizeHint = tasksToInsert.size();", decl.?);

    const assign = try transpileGenericStatementLine(gpa, "payload = records[0].Id;");
    defer if (assign) |value| gpa.free(value);
    try std.testing.expect(assign != null);
    try std.testing.expectEqualStrings("payload = records.get(0).getAs(\"Id\");", assign.?);

    const call = try transpileGenericStatementLine(gpa, "doWork(records[0].Id);");
    defer if (call) |value| gpa.free(value);
    try std.testing.expect(call != null);
    try std.testing.expectEqualStrings("doWork(records.get(0).getAs(\"Id\"));", call.?);

    const plus_assign = try transpileGenericStatementLine(gpa, "payload += 'Contact: ' + records[0].LastName;");
    defer if (plus_assign) |value| gpa.free(value);
    try std.testing.expect(plus_assign != null);
    try std.testing.expectEqualStrings("payload += \"Contact: \" + records.get(0).getAs(\"LastName\");", plus_assign.?);

    const sobject_field_assign = try transpileGenericStatementLine(gpa, "acc.Name = records[0].Name;");
    defer if (sobject_field_assign) |value| gpa.free(value);
    try std.testing.expect(sobject_field_assign != null);
    try std.testing.expectEqualStrings(
        "acc.set(\"Name\", records.get(0).getAs(\"Name\"));",
        sobject_field_assign.?,
    );

    const this_assign = try transpileGenericStatementLine(gpa, "this.Name = name;");
    defer if (this_assign) |value| gpa.free(value);
    try std.testing.expect(this_assign != null);
    try std.testing.expectEqualStrings("this.Name = name;", this_assign.?);

    const instanceof_assign = try transpileGenericStatementLine(gpa, "Boolean isAccount = record instanceof Account;");
    defer if (instanceof_assign) |value| gpa.free(value);
    try std.testing.expect(instanceof_assign != null);
    try std.testing.expectEqualStrings(
        "Boolean isAccount = \"Account\".equals(ApexSwitch.typeName(record));",
        instanceof_assign.?,
    );

    const negated_instanceof_assign = try transpileGenericStatementLine(
        gpa,
        "Boolean isNotContact = !(record instanceof Contact);",
    );
    defer if (negated_instanceof_assign) |value| gpa.free(value);
    try std.testing.expect(negated_instanceof_assign != null);
    try std.testing.expectEqualStrings(
        "Boolean isNotContact = !(\"Contact\".equals(ApexSwitch.typeName(record)));",
        negated_instanceof_assign.?,
    );
}

test "transpileDmlLine supports upsert with external id hint and merge" {
    const gpa = std.testing.allocator;
    const line = try transpileDmlLine(gpa, "upsert tasksToInsert External_Id__c;");
    defer if (line) |value| gpa.free(value);
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings(
        "Database.upsert(tasksToInsert); // external id field: External_Id__c",
        line.?,
    );

    const merge_two = try transpileDmlLine(gpa, "merge masterAccount duplicateAccount;");
    defer if (merge_two) |value| gpa.free(value);
    try std.testing.expect(merge_two != null);
    try std.testing.expectEqualStrings(
        "Database.merge(masterAccount, duplicateAccount);",
        merge_two.?,
    );

    const merge_three = try transpileDmlLine(gpa, "merge masterAccount, duplicateA, duplicateB;");
    defer if (merge_three) |value| gpa.free(value);
    try std.testing.expect(merge_three != null);
    try std.testing.expectEqualStrings(
        "Database.merge(masterAccount, java.util.List.of(duplicateA, duplicateB));",
        merge_three.?,
    );

    const merge_indexed = try transpileDmlLine(gpa, "merge masterAccount duplicateAccounts[0];");
    defer if (merge_indexed) |value| gpa.free(value);
    try std.testing.expect(merge_indexed != null);
    try std.testing.expectEqualStrings(
        "Database.merge(masterAccount, duplicateAccounts.get(0));",
        merge_indexed.?,
    );

    const merge_expr = try transpileDmlLine(
        gpa,
        "merge pickMaster(records, 0) pickDuplicate(records, 1);",
    );
    defer if (merge_expr) |value| gpa.free(value);
    try std.testing.expect(merge_expr != null);
    try std.testing.expectEqualStrings(
        "Database.merge(pickMaster(records, 0), pickDuplicate(records, 1));",
        merge_expr.?,
    );
}

test "convertApexExpressionToJava converts collection literals and sobject constructor args" {
    const gpa = std.testing.allocator;

    const list_literal = try convertApexExpressionToJava(gpa, "new List<Id>{'a', 'b'}");
    defer gpa.free(list_literal);
    try std.testing.expectEqualStrings(
        "new ArrayList<String>(java.util.List.of(\"a\", \"b\"))",
        list_literal,
    );

    const map_literal = try convertApexExpressionToJava(gpa, "new Map<Id, Account>{'001' => record}");
    defer gpa.free(map_literal);
    try std.testing.expectEqualStrings(
        "new LinkedHashMap<String, ApexSObject>(java.util.Map.ofEntries(java.util.Map.entry(\"001\", record)))",
        map_literal,
    );

    const sobject_ctor = try convertApexExpressionToJava(gpa, "new Task(Subject = 'Bulk', WhatId = records[0].Id)");
    defer gpa.free(sobject_ctor);
    try std.testing.expectEqualStrings(
        "ApexSObject.of(\"Task\").set(\"Subject\", \"Bulk\").set(\"WhatId\", records.get(0).getAs(\"Id\"))",
        sobject_ctor,
    );

    const nested_literal = try convertApexExpressionToJava(
        gpa,
        "new List<Task>{ new Task(WhatId = records[0].Id) }",
    );
    defer gpa.free(nested_literal);
    try std.testing.expectEqualStrings(
        "new ArrayList<ApexSObject>(java.util.List.of(ApexSObject.of(\"Task\").set(\"WhatId\", records.get(0).getAs(\"Id\"))))",
        nested_literal,
    );
}

test "collectLogicalStatements keeps multiline soql as one statement" {
    const gpa = std.testing.allocator;
    const body =
        \\Map<Id, Account> accountMap = new Map<Id, Account>([
        \\  SELECT Id, Name
        \\  FROM Account
        \\  WHERE Id IN :new Set<Id>()
        \\  LIMIT 10
        \\]);
    ;
    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line);
        statements.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), statements.items.len);
    const converted = try transpileExecutableLine(gpa, statements.items[0]);
    defer if (converted) |value| gpa.free(value);
    try std.testing.expect(converted != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.mapById(Database.query(\"SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10\"));",
        converted.?,
    );
}

test "run counts unsupported statements when strict is disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class UnsupportedDemo {
        \\  public static void run() {
        \\    when Account acc {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "UnsupportedDemo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(root);
    const out_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "out" },
    );
    defer std.testing.allocator.free(out_dir);

    const inputs = [_][]const u8{root};
    const summary = try run(std.testing.allocator, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
        .strict = false,
    });

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
    try std.testing.expect(summary.unsupported_statements > 0);
}

test "run strict mode fails on unsupported statements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class UnsupportedStrictDemo {
        \\  public static void run() {
        \\    when Account acc {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "UnsupportedStrictDemo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(root);
    const out_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "out" },
    );
    defer std.testing.allocator.free(out_dir);

    const inputs = [_][]const u8{root};
    try std.testing.expectError(
        error.UnsupportedApexSyntax,
        run(std.testing.allocator, .{
            .input_paths = &inputs,
            .out_dir = out_dir,
            .package_name = "generated",
            .overwrite = true,
            .strict = true,
        }),
    );
}

test "renderJavaClass keeps inner block closing brace" {
    const gpa = std.testing.allocator;

    const source =
        \\public class Demo {
        \\  public static void run() {
        \\    if (true) {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    const output = try renderJavaClass(gpa, parsed, "generated");
    defer gpa.free(output.java);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "if (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "    }\n  }\n") != null);
}
