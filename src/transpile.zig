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
            try appendFmt(gpa, &out, "    // {s}\n", .{trimmed});
        }

        try out.appendSlice(gpa, "  }\n\n");
    }

    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
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
    try std.testing.expect(std.mem.indexOf(u8, output, "System.assertEquals(1, 1);") != null);
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
