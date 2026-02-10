const std = @import("std");

pub const Options = struct {
    input_paths: []const []const u8,
    out_dir: []const u8,
    package_name: []const u8 = "generated",
    overwrite: bool = false,
};

pub const Summary = struct {
    files_scanned: usize = 0,
    files_generated: usize = 0,
    methods_generated: usize = 0,
};

const ApexFile = struct {
    path: []u8,
    content: []u8,
};

const ParsedMethod = struct {
    name: []u8,
    is_test: bool,
    body: []u8,
};

const ParsedClass = struct {
    class_name: []u8,
    source_path: []u8,
    methods: std.ArrayList(ParsedMethod) = .empty,

    fn deinit(self: *ParsedClass, gpa: std.mem.Allocator) void {
        gpa.free(self.class_name);
        gpa.free(self.source_path);
        for (self.methods.items) |method| {
            gpa.free(method.name);
            gpa.free(method.body);
        }
        self.methods.deinit(gpa);
    }
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
        defer gpa.free(rendered);

        const output_name = try std.fmt.allocPrint(gpa, "{s}.java", .{parsed.class_name});
        defer gpa.free(output_name);

        const output_path = try std.fs.path.join(gpa, &.{ opts.out_dir, output_name });
        defer gpa.free(output_path);

        if (!opts.overwrite and pathExists(output_path)) {
            return error.OutputAlreadyExists;
        }

        try writeOutputFile(output_path, rendered);

        summary.files_generated += 1;
        summary.methods_generated += parsed.methods.items.len;
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
    var current_name: []u8 = undefined;
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

            if (parseMethodName(trimmed, parsed.class_name)) |method_name| {
                in_method = true;
                brace_depth = braceDelta(line);
                current_name = try gpa.dupe(u8, method_name);
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
                        .name = current_name,
                        .is_test = current_is_test,
                        .body = body,
                    });
                    in_method = false;
                }
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
            .name = current_name,
            .is_test = current_is_test,
            .body = body,
        });
        in_method = false;
    }

    if (in_method) {
        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_name,
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

fn parseMethodName(line: []const u8, class_name: []const u8) ?[]const u8 {
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
    return candidate;
}

fn renderJavaClass(gpa: std.mem.Allocator, parsed: ParsedClass, package_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var method_name_counts = std.StringHashMap(usize).init(gpa);
    defer method_name_counts.deinit();

    try appendFmt(gpa, &out, "package {s};\n\n", .{package_name});
    try out.appendSlice(gpa, "import apexemu.annotations.Test;\n\n");
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

    if (parsed.methods.items.len == 0) {
        try out.appendSlice(gpa, "  // No method body was detected in the Apex source.\n");
    }

    for (parsed.methods.items) |method| {
        const emitted_name = try uniqueMethodName(gpa, &method_name_counts, method.name);
        defer gpa.free(emitted_name);

        if (method.is_test) {
            try out.appendSlice(gpa, "  @Test\n");
        }
        try appendFmt(gpa, &out, "  public static void {s}() {{\n", .{emitted_name});
        try out.appendSlice(gpa, "    // TODO(apex): method body is copied as comments and needs manual porting.\n");

        var body_lines = std.mem.splitScalar(u8, method.body, '\n');
        while (body_lines.next()) |body_line| {
            const clean = std.mem.trimRight(u8, body_line, "\r");
            const trimmed = std.mem.trim(u8, clean, " \t");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "{") or std.mem.eql(u8, trimmed, "}")) continue;
            if (try transpileExecutableLine(gpa, trimmed)) |statement| {
                defer gpa.free(statement);
                try appendFmt(gpa, &out, "    {s}\n", .{statement});
            } else {
                try appendFmt(gpa, &out, "    // {s}\n", .{trimmed});
            }
        }

        try out.appendSlice(gpa, "  }\n\n");
    }

    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

fn transpileExecutableLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    if (try transpileAssertionLine(gpa, line)) |statement| return statement;
    if (try transpileSystemDebugLine(gpa, line)) |statement| return statement;
    if (try transpileCollectionDeclarationLine(gpa, line)) |statement| return statement;
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
    if (!startsWithIgnoreCase(head, "System.")) return null;

    const method_name = std.mem.trim(u8, head["System.".len..], " \t");
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

    const maybe_init = try transpileCollectionInitializer(gpa, decl.kind, right);
    if (maybe_init) |initializer| {
        defer gpa.free(initializer);
        return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ decl.java_type, decl.variable_name, initializer });
    }

    if (std.mem.indexOfScalar(u8, right, '[')) |_| return null;
    const rhs = try convertApexExpressionToJava(gpa, right);
    defer gpa.free(rhs);
    return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ decl.java_type, decl.variable_name, rhs });
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

fn transpileCollectionInitializer(gpa: std.mem.Allocator, kind: CollectionKind, right: []const u8) !?[]u8 {
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
    if (std.mem.indexOfScalar(u8, args_raw, '[')) |_| return null;

    var args = try splitCallArguments(gpa, args_raw);
    defer args.deinit(gpa);
    if (args.items.len == 0) {
        return try std.fmt.allocPrint(gpa, "new {s}<>()", .{impl_name});
    }

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(gpa);

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
    if (std.ascii.eqlIgnoreCase(raw, "Id")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Decimal")) return "Double";
    if (std.ascii.eqlIgnoreCase(raw, "List")) return "List";
    if (std.ascii.eqlIgnoreCase(raw, "Map")) return "Map";
    if (std.ascii.eqlIgnoreCase(raw, "Set")) return "Set";
    if (std.ascii.eqlIgnoreCase(raw, "Integer")) return "Integer";
    if (std.ascii.eqlIgnoreCase(raw, "Long")) return "Long";
    if (std.ascii.eqlIgnoreCase(raw, "Double")) return "Double";
    if (std.ascii.eqlIgnoreCase(raw, "Boolean")) return "Boolean";
    if (std.ascii.eqlIgnoreCase(raw, "String")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Object")) return "Object";
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
            ',' => {
                if (paren_depth != 0) continue;
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

fn buildSystemAssertCall(gpa: std.mem.Allocator, method_name: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "SystemAssert.");
    try out.appendSlice(gpa, method_name);
    try out.appendSlice(gpa, "(");
    for (args, 0..) |arg, idx| {
        if (idx != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, arg);
    }
    try out.appendSlice(gpa, ");");
    return out.toOwnedSlice(gpa);
}

fn convertApexExpressionToJava(gpa: std.mem.Allocator, expression: []const u8) ![]u8 {
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

    return out.toOwnedSlice(gpa);
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

test "parseMethodName ignores control statements and picks regular methods" {
    try std.testing.expectEqualStrings(
        "run",
        parseMethodName("public static void run(List<Account> records) {", "Demo").?,
    );
    try std.testing.expect(parseMethodName("for (Integer i = 0; i < 10; i++) {", "Demo") == null);
    try std.testing.expect(parseMethodName("if (records == null) {", "Demo") == null);
    try std.testing.expect(parseMethodName("public Demo() {", "Demo") == null);
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
        .is_test = true,
        .body = try gpa.dupe(u8, "System.assertEquals(1, 1);\n"),
    });

    const output = try renderJavaClass(gpa, parsed, "generated");
    defer gpa.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "package generated;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "@Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "public static void firstMethod()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SystemAssert.assertEquals(1, 1);") != null);
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
        "Map<String, Account> accountMap = new LinkedHashMap<>();",
        map_line.?,
    );

    const set_line = try transpileCollectionDeclarationLine(gpa, "final Set<Id> accountIds = new Set<Id>();");
    defer if (set_line) |value| gpa.free(value);
    try std.testing.expect(set_line != null);
    try std.testing.expectEqualStrings(
        "Set<String> accountIds = new LinkedHashSet<>();",
        set_line.?,
    );
}
