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
    is_test_setup: bool = false,
    is_test_see_all_data: bool = false,
    body: []u8,
    start_line: usize,
};

const ParsedField = struct {
    declaration: []u8,
};

const InnerTypeKind = enum {
    class,
    interface,
    enum_type,
};

const TopLevelKind = enum {
    class,
    interface,
    enum_type,
};

const ParsedClass = struct {
    class_name: []u8,
    source_path: []u8,
    top_level_kind: TopLevelKind = .class,
    class_declaration_suffix: ?[]u8 = null,
    top_level_enum_constants: ?[]u8 = null,
    fields: std.ArrayList(ParsedField) = .empty,
    methods: std.ArrayList(ParsedMethod) = .empty,

    fn deinit(self: *ParsedClass, gpa: std.mem.Allocator) void {
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

const UnsupportedLine = struct {
    method_name: []const u8,
    source_line: usize,
    reason: []const u8,
    statement: []u8,
};

const RenderedClass = struct {
    java: []u8,
    unsupported_statements: usize,
    unsupported_lines: std.ArrayList(UnsupportedLine) = .empty,

    fn deinit(self: *RenderedClass, gpa: std.mem.Allocator) void {
        gpa.free(self.java);
        for (self.unsupported_lines.items) |line| {
            gpa.free(line.statement);
        }
        self.unsupported_lines.deinit(gpa);
    }
};

const TriggerEvent = enum {
    before_insert,
    before_update,
    before_delete,
    after_insert,
    after_update,
    after_delete,
    after_undelete,
};

const TriggerRegistration = struct {
    source_path: []u8,
    sobject_type: []u8,
    handler_class: []u8,
    events: std.ArrayList(TriggerEvent) = .empty,

    fn deinit(self: *TriggerRegistration, gpa: std.mem.Allocator) void {
        gpa.free(self.source_path);
        gpa.free(self.sobject_type);
        gpa.free(self.handler_class);
        self.events.deinit(gpa);
    }
};

pub fn run(gpa: std.mem.Allocator, opts: Options) !Summary {
    if (opts.input_paths.len == 0) return error.MissingInputPath;

    var files = try collectApexFiles(gpa, opts.input_paths);
    defer deinitApexFiles(gpa, &files);

    var trigger_files = try collectApexTriggerFiles(gpa, opts.input_paths);
    defer deinitApexFiles(gpa, &trigger_files);

    if (files.items.len == 0) return error.NoApexClassSourceFound;
    if (!isValidPackageName(opts.package_name)) return error.InvalidPackageName;

    try std.fs.cwd().makePath(opts.out_dir);

    var summary = Summary{
        .files_scanned = files.items.len,
    };
    errdefer summary.deinit(gpa);

    for (files.items) |file| {
        var parsed = try parseApexClass(gpa, file.path, file.content);
        defer parsed.deinit(gpa);

        var rendered = try renderJavaClass(gpa, parsed, opts.package_name);
        defer rendered.deinit(gpa);

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
        for (rendered.unsupported_lines.items) |line| {
            if (summary.unsupported_examples.items.len >= 64) break;

            const source_copy = try gpa.dupe(u8, parsed.source_path);
            errdefer gpa.free(source_copy);
            const method_copy = try gpa.dupe(u8, line.method_name);
            errdefer {
                gpa.free(source_copy);
                gpa.free(method_copy);
            }
            const statement_copy = try gpa.dupe(u8, line.statement);
            errdefer {
                gpa.free(source_copy);
                gpa.free(method_copy);
                gpa.free(statement_copy);
            }
            try summary.unsupported_examples.append(gpa, .{
                .source_path = source_copy,
                .method_name = method_copy,
                .line_no = line.source_line,
                .reason = line.reason,
                .statement = statement_copy,
            });
        }
    }

    var trigger_registrations: std.ArrayList(TriggerRegistration) = .empty;
    defer {
        for (trigger_registrations.items) |*registration| {
            registration.deinit(gpa);
        }
        trigger_registrations.deinit(gpa);
    }

    for (trigger_files.items) |file| {
        const maybe_registration = try parseTriggerRegistration(gpa, file.path, file.content);
        if (maybe_registration) |registration| {
            try trigger_registrations.append(gpa, registration);
            continue;
        }
        if (opts.strict) {
            return error.UnsupportedApexSyntax;
        }
    }

    if (trigger_registrations.items.len > 0) {
        try writeTriggerManifest(gpa, opts.out_dir, trigger_registrations.items, opts.overwrite);
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

fn collectApexTriggerFiles(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(ApexFile) {
    var files: std.ArrayList(ApexFile) = .empty;
    errdefer deinitApexFiles(gpa, &files);

    for (roots) |root| {
        try collectTriggerPath(gpa, root, &files);
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

fn collectTriggerPath(gpa: std.mem.Allocator, path: []const u8, files: *std.ArrayList(ApexFile)) !void {
    collectTriggerDirectory(gpa, path, files) catch |err| switch (err) {
        error.NotDir => {
            if (isApexTriggerSource(path)) {
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

fn collectTriggerDirectory(gpa: std.mem.Allocator, root: []const u8, files: *std.ArrayList(ApexFile)) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isApexTriggerSource(entry.path)) continue;

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

fn parseTriggerRegistration(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    content: []const u8,
) !?TriggerRegistration {
    var cursor = skipApexCommentsAndWhitespace(content, 0);
    if (cursor >= content.len or !startsWithWordIgnoreCase(content[cursor..], "trigger")) {
        return null;
    }
    cursor += "trigger".len;
    cursor = skipInlineWhitespace(content, cursor);
    cursor = readTriggerToken(content, cursor) orelse return null; // trigger name
    cursor = skipInlineWhitespace(content, cursor);
    if (cursor >= content.len or !startsWithWordIgnoreCase(content[cursor..], "on")) {
        return null;
    }
    cursor += "on".len;
    cursor = skipInlineWhitespace(content, cursor);
    const object_start = cursor;
    cursor = readTriggerToken(content, cursor) orelse return null;
    const sobject_type = std.mem.trim(u8, content[object_start..cursor], " \t\r\n");
    if (sobject_type.len == 0) return null;

    cursor = skipInlineWhitespace(content, cursor);
    if (cursor >= content.len or content[cursor] != '(') return null;
    const events_start = cursor + 1;
    const events_end = std.mem.indexOfScalarPos(u8, content, events_start, ')') orelse return null;
    var events = parseTriggerEvents(gpa, content[events_start..events_end]) catch return null;
    errdefer events.deinit(gpa);

    const handler_prefix = "fflib_SObjectDomain.triggerHandler(";
    const handler_idx = indexOfIgnoreCase(content, handler_prefix) orelse {
        events.deinit(gpa);
        return null;
    };
    const handler_open = std.mem.indexOfScalarPos(u8, content, handler_idx, '(') orelse {
        events.deinit(gpa);
        return null;
    };
    const handler_close = std.mem.indexOfScalarPos(u8, content, handler_open + 1, ')') orelse {
        events.deinit(gpa);
        return null;
    };
    const raw_handler = std.mem.trim(u8, content[handler_open + 1 .. handler_close], " \t\r\n");
    if (!endsWithIgnoreCase(raw_handler, ".class")) {
        events.deinit(gpa);
        return null;
    }
    const handler_class = std.mem.trim(u8, raw_handler[0 .. raw_handler.len - ".class".len], " \t\r\n");
    if (handler_class.len == 0) {
        events.deinit(gpa);
        return null;
    }

    return TriggerRegistration{
        .source_path = try gpa.dupe(u8, source_path),
        .sobject_type = try gpa.dupe(u8, sobject_type),
        .handler_class = try gpa.dupe(u8, handler_class),
        .events = events,
    };
}

fn parseTriggerEvents(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(TriggerEvent) {
    var events: std.ArrayList(TriggerEvent) = .empty;
    errdefer events.deinit(gpa);

    var start: usize = 0;
    while (start <= text.len) {
        const comma = std.mem.indexOfScalarPos(u8, text, start, ',') orelse text.len;
        const token = std.mem.trim(u8, text[start..comma], " \t\r\n");
        if (token.len > 0) {
            const event = parseTriggerEvent(token) orelse return error.UnsupportedApexSyntax;
            if (!triggerEventListContains(events.items, event)) {
                try events.append(gpa, event);
            }
        }
        if (comma == text.len) break;
        start = comma + 1;
    }
    return events;
}

fn parseTriggerEvent(token: []const u8) ?TriggerEvent {
    if (std.ascii.eqlIgnoreCase(token, "before insert")) return .before_insert;
    if (std.ascii.eqlIgnoreCase(token, "before update")) return .before_update;
    if (std.ascii.eqlIgnoreCase(token, "before delete")) return .before_delete;
    if (std.ascii.eqlIgnoreCase(token, "after insert")) return .after_insert;
    if (std.ascii.eqlIgnoreCase(token, "after update")) return .after_update;
    if (std.ascii.eqlIgnoreCase(token, "after delete")) return .after_delete;
    if (std.ascii.eqlIgnoreCase(token, "after undelete")) return .after_undelete;
    return null;
}

fn triggerEventListContains(events: []const TriggerEvent, needle: TriggerEvent) bool {
    for (events) |event| {
        if (event == needle) return true;
    }
    return false;
}

fn triggerEventName(event: TriggerEvent) []const u8 {
    return switch (event) {
        .before_insert => "before_insert",
        .before_update => "before_update",
        .before_delete => "before_delete",
        .after_insert => "after_insert",
        .after_update => "after_update",
        .after_delete => "after_delete",
        .after_undelete => "after_undelete",
    };
}

fn writeTriggerManifest(
    gpa: std.mem.Allocator,
    out_dir: []const u8,
    registrations: []const TriggerRegistration,
    overwrite: bool,
) !void {
    if (registrations.len == 0) return;

    const manifest_path = try std.fs.path.join(gpa, &.{ out_dir, "apex-triggers.txt" });
    defer gpa.free(manifest_path);

    if (!overwrite and pathExists(manifest_path)) {
        return error.OutputAlreadyExists;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    for (registrations) |registration| {
        try appendFmt(gpa, &out, "{s}|", .{registration.sobject_type});
        for (registration.events.items, 0..) |event, idx| {
            if (idx > 0) {
                try out.append(gpa, ',');
            }
            try out.appendSlice(gpa, triggerEventName(event));
        }
        try appendFmt(gpa, &out, "|{s}\n", .{registration.handler_class});
    }

    try writeOutputFile(manifest_path, out.items);
}

fn skipApexCommentsAndWhitespace(text: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < text.len) {
        if (std.ascii.isWhitespace(text[cursor])) {
            cursor += 1;
            continue;
        }
        if (cursor + 1 < text.len and text[cursor] == '/' and text[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < text.len and text[cursor] != '\n') : (cursor += 1) {}
            continue;
        }
        if (cursor + 1 < text.len and text[cursor] == '/' and text[cursor + 1] == '*') {
            cursor += 2;
            while (cursor + 1 < text.len and !(text[cursor] == '*' and text[cursor + 1] == '/')) : (cursor += 1) {}
            if (cursor + 1 < text.len) {
                cursor += 2;
            }
            continue;
        }
        break;
    }
    return cursor;
}

fn skipInlineWhitespace(text: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
    return cursor;
}

const AnnotationPrefix = struct {
    annotations: [8][]const u8 = [_][]const u8{""} ** 8,
    count: usize = 0,
    consumed_len: usize = 0,
    saw_annotation: bool = false,
    incomplete: bool = false,
};

fn consumeLeadingInlineAnnotations(text: []const u8) AnnotationPrefix {
    var result = AnnotationPrefix{};
    var cursor: usize = 0;
    const trimmed = std.mem.trimLeft(u8, text, " \t");
    const offset = text.len - trimmed.len;
    cursor = offset;

    while (cursor < text.len and text[cursor] == '@') {
        result.saw_annotation = true;
        const start = cursor;
        cursor += 1;
        while (cursor < text.len and (isIdentifierChar(text[cursor]) or text[cursor] == '.')) : (cursor += 1) {}
        if (cursor < text.len and text[cursor] == '(') {
            const close = findMatchingParen(text, cursor) orelse {
                result.incomplete = true;
                return result;
            };
            cursor = close + 1;
        }
        if (result.count < result.annotations.len) {
            result.annotations[result.count] = text[start..cursor];
            result.count += 1;
        }
        cursor = skipInlineWhitespace(text, cursor);
    }

    result.consumed_len = cursor;
    return result;
}

fn readTriggerToken(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    var cursor = start;
    while (cursor < text.len) : (cursor += 1) {
        const ch = text[cursor];
        if (isIdentifierChar(ch) or ch == '.') continue;
        break;
    }
    return if (cursor > start) cursor else null;
}

fn parseApexClass(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) anyerror!ParsedClass {
    const class_name = try parseClassName(gpa, source_path, content);
    errdefer gpa.free(class_name);
    const top_level_kind = try parseTopLevelDeclarationKind(gpa, content, class_name);
    const class_declaration_suffix = try parseClassDeclarationSuffix(gpa, content, class_name);
    errdefer if (class_declaration_suffix) |suffix| gpa.free(suffix);
    const top_level_enum_constants = try parseTopLevelEnumConstants(gpa, content, class_name);
    errdefer if (top_level_enum_constants) |constants| gpa.free(constants);
    const class_is_test = detectClassIsTest(content);
    const class_is_test_see_all_data = detectClassSeeAllData(content);

    var parsed = ParsedClass{
        .class_name = class_name,
        .source_path = try gpa.dupe(u8, source_path),
        .top_level_kind = top_level_kind,
        .class_declaration_suffix = class_declaration_suffix,
        .top_level_enum_constants = top_level_enum_constants,
    };
    errdefer parsed.deinit(gpa);

    var pending_test_annotation = false;
    var pending_test_setup_annotation = false;
    var pending_test_see_all_data = false;
    var pending_test_visible_annotation = false;
    var in_method = false;
    var brace_depth: i32 = 0;
    var current_signature: MethodSignature = undefined;
    var current_is_test = false;
    var current_is_test_setup = false;
    var current_is_test_see_all_data = false;
    var current_body_base_line: usize = 0;
    var current_body: std.ArrayList(u8) = .empty;
    var pending_signature: std.ArrayList(u8) = .empty;
    var inner_type_block: std.ArrayList(u8) = .empty;
    var pending_member: std.ArrayList(u8) = .empty;
    var pending_property_header: std.ArrayList(u8) = .empty;
    var line_buffer: std.ArrayList(u8) = .empty;
    var collecting_inner_type = false;
    var collecting_member = false;
    var awaiting_property_block = false;
    var inner_type_kind: InnerTypeKind = .class;
    var inner_type_test_visible = false;
    var inner_type_brace_depth: i32 = 0;
    var inner_type_seen_open_brace = false;
    var member_brace_depth: i32 = 0;
    var annotation_paren_depth: i32 = 0;
    var in_block_comment = false;
    defer pending_signature.deinit(gpa);
    defer inner_type_block.deinit(gpa);
    defer pending_member.deinit(gpa);
    defer pending_property_header.deinit(gpa);
    defer line_buffer.deinit(gpa);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed_raw = std.mem.trim(u8, code_only, " \t");
        var logical_code_only = code_only;
        var logical_trimmed = trimmed_raw;

        if (!in_method and annotation_paren_depth == 0 and logical_trimmed.len > 0 and logical_trimmed[0] == '@') {
            const annotation_prefix = consumeLeadingInlineAnnotations(logical_trimmed);
            if (annotation_prefix.saw_annotation and !annotation_prefix.incomplete) {
                for (annotation_prefix.annotations) |annotation| {
                    if (isIsTestAnnotation(annotation)) {
                        pending_test_annotation = true;
                        if (isTestAnnotationSeeAllDataTrue(annotation)) {
                            pending_test_see_all_data = true;
                        }
                    }
                    if (isTestSetupAnnotation(annotation)) {
                        pending_test_setup_annotation = true;
                    }
                    if (isTestVisibleAnnotation(annotation)) {
                        pending_test_visible_annotation = true;
                    }
                }
                logical_trimmed = std.mem.trimLeft(u8, logical_trimmed[annotation_prefix.consumed_len..], " \t");
                logical_code_only = logical_trimmed;
            }
        }

        if (!in_method) {
            if (annotation_paren_depth > 0) {
                if (pending_test_annotation and isTestAnnotationSeeAllDataTrue(code_only)) {
                    pending_test_see_all_data = true;
                }
                annotation_paren_depth += parenDelta(code_only);
                if (annotation_paren_depth < 0) annotation_paren_depth = 0;
                continue;
            }

            if (logical_trimmed.len > 0 and logical_trimmed[0] == '@') {
                if (isIsTestAnnotation(logical_trimmed)) {
                    pending_test_annotation = true;
                    if (isTestAnnotationSeeAllDataTrue(logical_trimmed)) {
                        pending_test_see_all_data = true;
                    }
                }
                if (isTestSetupAnnotation(logical_trimmed)) {
                    pending_test_setup_annotation = true;
                }
                if (isTestVisibleAnnotation(logical_trimmed)) {
                    pending_test_visible_annotation = true;
                }
                annotation_paren_depth += parenDelta(logical_code_only);
                if (annotation_paren_depth < 0) annotation_paren_depth = 0;
                continue;
            }

            if (awaiting_property_block) {
                if (logical_trimmed.len == 0) continue;
                if (std.mem.eql(u8, logical_trimmed, "{")) {
                    collecting_member = true;
                    member_brace_depth = braceDelta(logical_code_only);
                    pending_member.clearRetainingCapacity();
                    try pending_member.appendSlice(gpa, std.mem.trim(u8, pending_property_header.items, " \t"));
                    if (pending_member.items.len > 0) try pending_member.append(gpa, ' ');
                    try pending_member.appendSlice(gpa, logical_trimmed);
                    pending_property_header.clearRetainingCapacity();
                    awaiting_property_block = false;

                    const member_done = member_brace_depth <= 0 and (std.mem.endsWith(u8, logical_trimmed, ";") or std.mem.endsWith(u8, logical_trimmed, "}"));
                    if (member_done) {
                        const member_candidate = std.mem.trim(u8, pending_member.items, " \t");
                        if (try transpileClassMemberLine(gpa, member_candidate, pending_test_visible_annotation)) |declaration| {
                            try parsed.fields.append(gpa, .{ .declaration = declaration });
                        }
                        collecting_member = false;
                        member_brace_depth = 0;
                        pending_member.clearRetainingCapacity();
                        pending_test_annotation = false;
                        pending_test_setup_annotation = false;
                        pending_test_see_all_data = false;
                        pending_test_visible_annotation = false;
                    }
                    continue;
                }

                awaiting_property_block = false;
                pending_property_header.clearRetainingCapacity();
            }

            if (collecting_inner_type) {
                try inner_type_block.appendSlice(gpa, line);
                try inner_type_block.append(gpa, '\n');
                if (std.mem.indexOfScalar(u8, code_only, '{') != null) {
                    inner_type_seen_open_brace = true;
                }
                inner_type_brace_depth += braceDelta(code_only);
                if (inner_type_seen_open_brace and inner_type_brace_depth <= 0) {
                    collecting_inner_type = false;
                    const block_source = try inner_type_block.toOwnedSlice(gpa);
                    defer gpa.free(block_source);
                    inner_type_block.clearRetainingCapacity();

                    if (try transpileInnerTypeBlock(
                        gpa,
                        source_path,
                        block_source,
                        parsed.class_name,
                        inner_type_kind,
                    )) |inner_decl_raw| {
                        var inner_decl = inner_decl_raw;
                        if (inner_type_test_visible) {
                            const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, inner_decl_raw);
                            gpa.free(inner_decl_raw);
                            inner_decl = promoted;
                        }
                        try parsed.fields.append(gpa, .{ .declaration = inner_decl });
                    }
                    inner_type_test_visible = false;
                    pending_test_visible_annotation = false;
                }
                continue;
            }

            if (collecting_member) {
                if (logical_trimmed.len > 0) {
                    if (pending_member.items.len > 0) try pending_member.append(gpa, ' ');
                    try pending_member.appendSlice(gpa, logical_trimmed);
                }
                member_brace_depth += braceDelta(logical_code_only);

                const member_done = member_brace_depth <= 0 and (std.mem.endsWith(u8, logical_trimmed, ";") or std.mem.endsWith(u8, logical_trimmed, "}"));
                if (!member_done) continue;

                const member_candidate = std.mem.trim(u8, pending_member.items, " \t");
                if (try transpileClassMemberLine(gpa, member_candidate, pending_test_visible_annotation)) |declaration| {
                    try parsed.fields.append(gpa, .{ .declaration = declaration });
                }
                collecting_member = false;
                member_brace_depth = 0;
                pending_member.clearRetainingCapacity();
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
                continue;
            }

            if (innerTypeKindFromDeclarationLine(logical_trimmed, parsed.class_name)) |kind| {
                if (kind == .class and isExceptionLikeInnerClassDeclaration(logical_trimmed)) {
                    // Keep legacy single-line Exception conversion path to preserve constructor shape.
                    pending_signature.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                } else {
                    collecting_inner_type = true;
                    inner_type_kind = kind;
                    inner_type_test_visible = pending_test_visible_annotation;
                    inner_type_brace_depth = braceDelta(logical_code_only);
                    inner_type_seen_open_brace = std.mem.indexOfScalar(u8, logical_code_only, '{') != null;
                    inner_type_block.clearRetainingCapacity();
                    try inner_type_block.appendSlice(gpa, line);
                    try inner_type_block.append(gpa, '\n');
                    if (inner_type_seen_open_brace and inner_type_brace_depth <= 0) {
                        collecting_inner_type = false;
                        const block_source = try inner_type_block.toOwnedSlice(gpa);
                        defer gpa.free(block_source);
                        inner_type_block.clearRetainingCapacity();

                        if (try transpileInnerTypeBlock(
                            gpa,
                            source_path,
                            block_source,
                            parsed.class_name,
                            inner_type_kind,
                        )) |inner_decl_raw| {
                            var inner_decl = inner_decl_raw;
                            if (inner_type_test_visible) {
                                const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, inner_decl_raw);
                                gpa.free(inner_decl_raw);
                                inner_decl = promoted;
                            }
                            try parsed.fields.append(gpa, .{ .declaration = inner_decl });
                        }
                        inner_type_test_visible = false;
                        pending_test_visible_annotation = false;
                    }
                    pending_signature.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                    pending_test_visible_annotation = false;
                    continue;
                }
            }

            if (pending_signature.items.len > 0) {
                if (logical_trimmed.len == 0) continue;
                if (pending_signature.items.len > 0) try pending_signature.append(gpa, ' ');
                try pending_signature.appendSlice(gpa, logical_trimmed);
                const signature_candidate = std.mem.trim(u8, pending_signature.items, " \t");

                if (try parseMethodSignature(gpa, signature_candidate, parsed.class_name)) |signature| {
                    in_method = try beginMethodFromSignature(
                        gpa,
                        &parsed,
                        signature,
                        signature_candidate,
                        code_only,
                        line_no,
                        class_is_test,
                        class_is_test_see_all_data,
                        &pending_test_annotation,
                        &pending_test_setup_annotation,
                        &pending_test_see_all_data,
                        &current_signature,
                        &current_is_test,
                        &current_is_test_setup,
                        &current_is_test_see_all_data,
                        &current_body_base_line,
                        &current_body,
                        &brace_depth,
                    );
                    pending_signature.clearRetainingCapacity();
                    pending_test_visible_annotation = false;
                    continue;
                }
                if (try parseConstructorSignature(gpa, signature_candidate, parsed.class_name)) |signature| {
                    in_method = try beginMethodFromSignature(
                        gpa,
                        &parsed,
                        signature,
                        signature_candidate,
                        code_only,
                        line_no,
                        class_is_test,
                        class_is_test_see_all_data,
                        &pending_test_annotation,
                        &pending_test_setup_annotation,
                        &pending_test_see_all_data,
                        &current_signature,
                        &current_is_test,
                        &current_is_test_setup,
                        &current_is_test_see_all_data,
                        &current_body_base_line,
                        &current_body,
                        &brace_depth,
                    );
                    pending_signature.clearRetainingCapacity();
                    pending_test_visible_annotation = false;
                    continue;
                }

                if (try transpileAbstractMethodDeclarationLine(gpa, signature_candidate, parsed.class_name)) |declaration| {
                    try parsed.fields.append(gpa, .{ .declaration = declaration });
                    pending_signature.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                    pending_test_visible_annotation = false;
                    continue;
                }

                if (std.mem.indexOfScalar(u8, signature_candidate, '{') == null) continue;
                pending_signature.clearRetainingCapacity();
            }

            if (try parseMethodSignature(gpa, logical_trimmed, parsed.class_name)) |signature| {
                in_method = try beginMethodFromSignature(
                    gpa,
                    &parsed,
                    signature,
                    logical_trimmed,
                    logical_code_only,
                    line_no,
                    class_is_test,
                    class_is_test_see_all_data,
                    &pending_test_annotation,
                    &pending_test_setup_annotation,
                    &pending_test_see_all_data,
                    &current_signature,
                    &current_is_test,
                    &current_is_test_setup,
                    &current_is_test_see_all_data,
                    &current_body_base_line,
                    &current_body,
                    &brace_depth,
                );
                pending_test_visible_annotation = false;
                continue;
            }

            if (try parseConstructorSignature(gpa, logical_trimmed, parsed.class_name)) |signature| {
                in_method = try beginMethodFromSignature(
                    gpa,
                    &parsed,
                    signature,
                    logical_trimmed,
                    logical_code_only,
                    line_no,
                    class_is_test,
                    class_is_test_see_all_data,
                    &pending_test_annotation,
                    &pending_test_setup_annotation,
                    &pending_test_see_all_data,
                    &current_signature,
                    &current_is_test,
                    &current_is_test_setup,
                    &current_is_test_see_all_data,
                    &current_body_base_line,
                    &current_body,
                    &brace_depth,
                );
                pending_test_visible_annotation = false;
                continue;
            }

            if (try transpileAbstractMethodDeclarationLine(gpa, logical_trimmed, parsed.class_name)) |declaration| {
                try parsed.fields.append(gpa, .{ .declaration = declaration });
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
                continue;
            }

            if (try transpileClassMemberLine(gpa, logical_trimmed, pending_test_visible_annotation)) |declaration| {
                try parsed.fields.append(gpa, .{ .declaration = declaration });
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
                continue;
            }

            if (try looksLikePropertyDeclarationHeader(gpa, logical_trimmed)) {
                awaiting_property_block = true;
                pending_property_header.clearRetainingCapacity();
                try pending_property_header.appendSlice(gpa, logical_trimmed);
                continue;
            }

            if (std.mem.eql(u8, logical_trimmed, "{") or std.mem.eql(u8, logical_trimmed, "}")) {
                continue;
            }

            const starts_multiline_member = (std.mem.indexOfScalar(u8, logical_trimmed, '{') != null and std.mem.indexOfScalar(u8, logical_trimmed, '(') == null) or
                std.mem.endsWith(u8, logical_trimmed, "=") or
                (std.mem.indexOfScalar(u8, logical_trimmed, '=') != null and !std.mem.endsWith(u8, logical_trimmed, ";"));
            if (starts_multiline_member and
                !looksLikeTypeDeclarationLine(logical_trimmed))
            {
                collecting_member = true;
                member_brace_depth = braceDelta(logical_code_only);
                pending_member.clearRetainingCapacity();
                if (logical_trimmed.len > 0) try pending_member.appendSlice(gpa, logical_trimmed);

                const member_done = member_brace_depth <= 0 and (std.mem.endsWith(u8, logical_trimmed, ";") or std.mem.endsWith(u8, logical_trimmed, "}"));
                if (member_done) {
                    const member_candidate = std.mem.trim(u8, pending_member.items, " \t");
                    if (try transpileClassMemberLine(gpa, member_candidate, pending_test_visible_annotation)) |declaration| {
                        try parsed.fields.append(gpa, .{ .declaration = declaration });
                    }
                    collecting_member = false;
                    member_brace_depth = 0;
                    pending_member.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                    pending_test_visible_annotation = false;
                }
                continue;
            }

            if (shouldStartMethodSignatureBuffer(logical_trimmed, parsed.class_name)) {
                pending_signature.clearRetainingCapacity();
                try pending_signature.appendSlice(gpa, logical_trimmed);
                continue;
            }

            if (try looksLikeMethodSignaturePrefix(gpa, logical_trimmed)) {
                pending_signature.clearRetainingCapacity();
                try pending_signature.appendSlice(gpa, logical_trimmed);
                continue;
            }

            if (logical_trimmed.len > 0 and logical_trimmed[0] != '@') {
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
            }
            continue;
        }

        try current_body.appendSlice(gpa, code_only);
        try current_body.append(gpa, '\n');
        brace_depth += braceDelta(code_only);
        if (brace_depth > 0) continue;

        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_signature.name,
            .java_return_type = current_signature.java_return_type,
            .java_parameters = current_signature.java_parameters,
            .is_static = current_signature.is_static,
            .is_constructor = current_signature.is_constructor,
            .is_test = current_is_test,
            .is_test_setup = current_is_test_setup,
            .is_test_see_all_data = current_is_test_see_all_data,
            .body = body,
            .start_line = current_body_base_line,
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
            .is_test_setup = current_is_test_setup,
            .is_test_see_all_data = current_is_test_see_all_data,
            .body = body,
            .start_line = current_body_base_line,
        });
    }

    return parsed;
}

const InnerTypeHeader = struct {
    visibility: []const u8,
    type_name: []u8,
    suffix: []u8,
    kind: InnerTypeKind,
    is_abstract: bool = false,
};

const InnerTypeKeyword = struct {
    kind: InnerTypeKind,
    pos: usize,
    keyword: []const u8,
};

fn innerTypeKeywordFromLine(trimmed: []const u8) ?InnerTypeKeyword {
    var best: ?InnerTypeKeyword = null;

    if (indexOfWordIgnoreCase(trimmed, "class")) |pos| {
        best = .{ .kind = .class, .pos = pos, .keyword = "class" };
    }
    if (indexOfWordIgnoreCase(trimmed, "interface")) |pos| {
        if (best == null or pos < best.?.pos) {
            best = .{ .kind = .interface, .pos = pos, .keyword = "interface" };
        }
    }
    if (indexOfWordIgnoreCase(trimmed, "enum")) |pos| {
        if (best == null or pos < best.?.pos) {
            best = .{ .kind = .enum_type, .pos = pos, .keyword = "enum" };
        }
    }

    return best;
}

fn innerTypeKindFromDeclarationLine(line: []const u8, outer_class_name: []const u8) ?InnerTypeKind {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;

    const keyword = innerTypeKeywordFromLine(trimmed) orelse return null;
    const prefix = std.mem.trim(u8, trimmed[0..keyword.pos], " \t");
    if (!looksLikeInnerTypeDeclarationPrefix(prefix)) return null;
    const after_keyword = std.mem.trimLeft(u8, trimmed[(keyword.pos + keyword.keyword.len)..], " \t");
    const type_name = leadingIdentifier(after_keyword) orelse return null;
    if (type_name.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(type_name, outer_class_name)) return null;
    return keyword.kind;
}

fn looksLikeTypeDeclarationLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;

    const keyword = innerTypeKeywordFromLine(trimmed) orelse return false;
    const prefix = std.mem.trim(u8, trimmed[0..keyword.pos], " \t");
    if (!looksLikeInnerTypeDeclarationPrefix(prefix)) return false;
    const after_keyword = std.mem.trimLeft(u8, trimmed[(keyword.pos + keyword.keyword.len)..], " \t");
    const type_name = leadingIdentifier(after_keyword) orelse return false;
    return type_name.len > 0;
}

fn isExceptionLikeInnerClassDeclaration(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;

    const class_pos = indexOfWordIgnoreCase(trimmed, "class") orelse return false;
    const after_class = std.mem.trimLeft(u8, trimmed[(class_pos + "class".len)..], " \t");
    const class_name = leadingIdentifier(after_class) orelse return false;

    if (endsWithIgnoreCase(class_name, "Exception")) return true;
    if (indexOfWordIgnoreCase(after_class, "extends")) |extends_pos| {
        const after_extends =
            std.mem.trimLeft(u8, after_class[(extends_pos + "extends".len)..], " \t");
        if (leadingIdentifier(after_extends)) |extends_name| {
            if (endsWithIgnoreCase(extends_name, "Exception")) return true;
        }
    }
    return false;
}

fn isExceptionLikeTypeHeader(type_name: []const u8, suffix: []const u8) bool {
    if (endsWithIgnoreCase(type_name, "Exception")) return true;
    if (indexOfWordIgnoreCase(suffix, "extends")) |extends_pos| {
        const after_extends =
            std.mem.trimLeft(u8, suffix[(extends_pos + "extends".len)..], " \t");
        if (leadingIdentifier(after_extends)) |extends_name| {
            return endsWithIgnoreCase(extends_name, "Exception");
        }
    }
    return false;
}

fn parseInnerTypeHeader(
    gpa: std.mem.Allocator,
    outer_class_name: []const u8,
    block_source: []const u8,
) !?InnerTypeHeader {
    var found_header = false;
    var header_kind: InnerTypeKind = .class;
    var header_visibility: []const u8 = "public";
    var header_type_name: ?[]u8 = null;
    var header_is_abstract = false;
    errdefer if (header_type_name) |value| gpa.free(value);
    var saw_open_brace = false;
    var suffix_head: std.ArrayList(u8) = .empty;
    defer suffix_head.deinit(gpa);

    var lines = std.mem.splitScalar(u8, block_source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (!found_header) {
            const keyword = innerTypeKeywordFromLine(trimmed) orelse continue;
            const prefix = std.mem.trim(u8, trimmed[0..keyword.pos], " \t");
            if (!looksLikeInnerTypeDeclarationPrefix(prefix)) continue;
            const after_keyword_full = trimmed[(keyword.pos + keyword.keyword.len)..];
            const after_keyword = std.mem.trimLeft(u8, after_keyword_full, " \t");
            const type_name = leadingIdentifier(after_keyword) orelse continue;
            if (type_name.len == 0 or std.ascii.eqlIgnoreCase(type_name, outer_class_name)) continue;

            const lead_ws_len = after_keyword_full.len - after_keyword.len;
            const type_name_start = keyword.pos + keyword.keyword.len + lead_ws_len;
            const type_name_end = type_name_start + type_name.len;
            if (type_name_end > trimmed.len) continue;

            var header_tail = std.mem.trim(u8, trimmed[type_name_end..], " \t");
            if (std.mem.indexOfScalar(u8, header_tail, '{')) |brace_pos| {
                header_tail = std.mem.trim(u8, header_tail[0..brace_pos], " \t");
                saw_open_brace = true;
            }
            if (header_tail.len > 0) {
                try suffix_head.appendSlice(gpa, header_tail);
            }

            found_header = true;
            header_kind = keyword.kind;
            header_visibility = visibilityModifierForInnerClass(prefix);
            header_is_abstract = containsWordIgnoreCase(prefix, "abstract");
            header_type_name = try gpa.dupe(u8, type_name);
            if (saw_open_brace) break;
            continue;
        }

        var continuation = trimmed;
        if (std.mem.indexOfScalar(u8, continuation, '{')) |brace_pos| {
            continuation = std.mem.trim(u8, continuation[0..brace_pos], " \t");
            saw_open_brace = true;
        }
        if (continuation.len > 0) {
            if (suffix_head.items.len > 0) try suffix_head.append(gpa, ' ');
            try suffix_head.appendSlice(gpa, continuation);
        }
        if (saw_open_brace) break;
    }

    if (!found_header or header_type_name == null) return null;

    const suffix = try normalizeInnerClassSuffix(gpa, std.mem.trim(u8, suffix_head.items, " \t"));
    errdefer gpa.free(suffix);

    return .{
        .visibility = header_visibility,
        .type_name = header_type_name.?,
        .suffix = suffix,
        .kind = header_kind,
        .is_abstract = header_is_abstract,
    };
}

fn normalizeInnerClassSuffix(gpa: std.mem.Allocator, suffix: []const u8) ![]u8 {
    if (suffix.len == 0) return gpa.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var tokens = std.mem.tokenizeAny(u8, suffix, " \t\r\n");
    var first = true;
    while (tokens.next()) |token| {
        if (!first) try out.append(gpa, ' ');
        first = false;

        const converted = try convertApexType(gpa, token);
        defer gpa.free(converted);
        try out.appendSlice(gpa, converted);
    }
    return try out.toOwnedSlice(gpa);
}

fn extractRenderedJavaClassBody(rendered_java: []const u8) ?[]const u8 {
    const class_pos = std.mem.indexOf(u8, rendered_java, "public class") orelse
        std.mem.indexOf(u8, rendered_java, "public final class") orelse
        std.mem.indexOf(u8, rendered_java, "public abstract class") orelse return null;
    const open_brace = std.mem.indexOfScalarPos(u8, rendered_java, class_pos, '{') orelse return null;
    const close_brace = std.mem.lastIndexOfScalar(u8, rendered_java, '}') orelse return null;
    if (close_brace <= open_brace) return null;
    return std.mem.trim(u8, rendered_java[(open_brace + 1)..close_brace], " \t\r\n");
}

fn rewriteClassSuffixInnerTypeRefs(
    gpa: std.mem.Allocator,
    suffix_raw: []const u8,
    class_name: []const u8,
    fields: []const ParsedField,
) ![]u8 {
    if (suffix_raw.len == 0) return gpa.dupe(u8, "");

    var inner_names: std.ArrayList([]const u8) = .empty;
    defer inner_names.deinit(gpa);

    for (fields) |field| {
        const declaration = field.declaration;
        if (declaration.len == 0) continue;

        const KeywordMatch = struct {
            pos: usize,
            len: usize,
        };
        const keyword_match = blk: {
            const class_pos = indexOfWordIgnoreCase(declaration, "class");
            const interface_pos = indexOfWordIgnoreCase(declaration, "interface");
            const enum_pos = indexOfWordIgnoreCase(declaration, "enum");

            if (class_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "class".len };
            if (interface_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "interface".len };
            if (enum_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "enum".len };
            continue;
        };

        const after_keyword = std.mem.trimLeft(u8, declaration[(keyword_match.pos + keyword_match.len)..], " \t");
        const inner_name = leadingIdentifier(after_keyword) orelse continue;
        if (inner_name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(inner_name, class_name)) continue;

        var seen = false;
        for (inner_names.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, inner_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try inner_names.append(gpa, inner_name);
    }

    if (inner_names.items.len == 0) return gpa.dupe(u8, suffix_raw);

    var current = try gpa.dupe(u8, suffix_raw);
    errdefer gpa.free(current);

    for (inner_names.items) |inner_name| {
        const replacement = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ class_name, inner_name });
        defer gpa.free(replacement);

        const rewritten = try replaceStandaloneTypeName(gpa, current, inner_name, replacement);
        gpa.free(current);
        current = rewritten;
    }
    return current;
}

fn collectInnerTypeNames(
    gpa: std.mem.Allocator,
    class_name: []const u8,
    fields: []const ParsedField,
) !std.ArrayList([]const u8) {
    var inner_names: std.ArrayList([]const u8) = .empty;
    errdefer inner_names.deinit(gpa);

    for (fields) |field| {
        const declaration = field.declaration;
        if (declaration.len == 0) continue;

        const KeywordMatch = struct {
            pos: usize,
            len: usize,
        };
        const keyword_match = blk: {
            const class_pos = indexOfWordIgnoreCase(declaration, "class");
            const interface_pos = indexOfWordIgnoreCase(declaration, "interface");
            const enum_pos = indexOfWordIgnoreCase(declaration, "enum");

            if (class_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "class".len };
            if (interface_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "interface".len };
            if (enum_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "enum".len };
            continue;
        };

        const after_keyword = std.mem.trimLeft(u8, declaration[(keyword_match.pos + keyword_match.len)..], " \t");
        const inner_name = leadingIdentifier(after_keyword) orelse continue;
        if (inner_name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(inner_name, class_name)) continue;

        var seen = false;
        for (inner_names.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, inner_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try inner_names.append(gpa, inner_name);
    }

    return inner_names;
}

fn stripSelfInnerImplementsFromClassSuffix(
    gpa: std.mem.Allocator,
    suffix_raw: []const u8,
    class_name: []const u8,
    fields: []const ParsedField,
) ![]u8 {
    if (suffix_raw.len == 0) return gpa.dupe(u8, "");
    const implements_pos = indexOfWordIgnoreCase(suffix_raw, "implements") orelse return gpa.dupe(u8, suffix_raw);

    var inner_names = try collectInnerTypeNames(gpa, class_name, fields);
    defer inner_names.deinit(gpa);
    if (inner_names.items.len == 0) return gpa.dupe(u8, suffix_raw);

    const impl_keyword_end = implements_pos + "implements".len;
    if (impl_keyword_end > suffix_raw.len) return gpa.dupe(u8, suffix_raw);
    const before_impl = std.mem.trimRight(u8, suffix_raw[0..implements_pos], " \t");
    const impl_segment = std.mem.trimLeft(u8, suffix_raw[impl_keyword_end..], " \t");
    if (impl_segment.len == 0) return gpa.dupe(u8, before_impl);

    var impl_items = try splitTypeArguments(gpa, impl_segment);
    defer impl_items.deinit(gpa);
    if (impl_items.items.len == 0) return gpa.dupe(u8, before_impl);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, before_impl);

    var emitted_any = false;
    for (impl_items.items) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t");
        if (item.len == 0) continue;

        const generic_pos = std.mem.indexOfScalar(u8, item, '<');
        const base = if (generic_pos) |pos| item[0..pos] else item;
        const base_trimmed = std.mem.trim(u8, base, " \t");
        if (base_trimmed.len == 0) continue;

        var skip = false;
        for (inner_names.items) |inner_name| {
            if (std.ascii.eqlIgnoreCase(base_trimmed, inner_name)) {
                skip = true;
                break;
            }
            const qualified = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ class_name, inner_name });
            defer gpa.free(qualified);
            if (std.ascii.eqlIgnoreCase(base_trimmed, qualified)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        if (!emitted_any) {
            try out.appendSlice(gpa, " implements ");
            emitted_any = true;
        } else {
            try out.appendSlice(gpa, ", ");
        }
        try out.appendSlice(gpa, item);
    }

    return try out.toOwnedSlice(gpa);
}

fn replaceStandaloneTypeName(
    gpa: std.mem.Allocator,
    text: []const u8,
    target: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (target.len == 0) return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        if (i + target.len <= text.len and
            std.ascii.eqlIgnoreCase(text[i .. i + target.len], target))
        {
            const left_ok = i == 0 or !isIdentifierChar(text[i - 1]);
            const right_idx = i + target.len;
            const right_ok = right_idx == text.len or !isIdentifierChar(text[right_idx]);
            const already_qualified = i > 0 and text[i - 1] == '.';

            if (left_ok and right_ok and !already_qualified) {
                try out.appendSlice(gpa, replacement);
                replaced = true;
                i += target.len;
                continue;
            }
        }

        try out.append(gpa, text[i]);
        i += 1;
    }

    const base = blk: {
        if (!replaced) {
            out.deinit(gpa);
            break :blk try gpa.dupe(u8, text);
        }
        break :blk try out.toOwnedSlice(gpa);
    };

    const schema_rewritten = try rewriteSchemaObjectNamespaceAccess(gpa, base);
    gpa.free(base);

    const token_rewritten = try rewriteTokenOverloadCalls(gpa, schema_rewritten);
    gpa.free(schema_rewritten);
    const array_rewritten = try rewriteApexArrayStyleListLiterals(gpa, token_rewritten);
    gpa.free(token_rewritten);
    return array_rewritten;
}

fn rewriteSchemaObjectNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!startsWithIgnoreCase(text[i..], "Schema.")) continue;

        const object_start = i + "Schema.".len;
        var cursor = object_start;
        while (cursor < text.len and isIdentifierChar(text[cursor])) : (cursor += 1) {}
        if (cursor == object_start or cursor >= text.len or text[cursor] != '.') continue;

        const object_name = text[object_start..cursor];
        if (isKnownSchemaHelperTypeName(object_name)) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, object_name);
        try out.append(gpa, '.');
        replaced = true;
        i = cursor;
        last_emit = cursor + 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return try out.toOwnedSlice(gpa);
}

fn rewriteFieldNamespacePropertyAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!startsWithIgnoreCase(text[i..], ".fields.")) continue;

        const field_start = i + ".fields.".len;
        var field_end = field_start;
        while (field_end < text.len and isIdentifierChar(text[field_end])) : (field_end += 1) {}
        if (field_end == field_start) continue;
        if (field_end < text.len and text[field_end] == '(') continue;

        const field_name = text[field_start..field_end];
        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, ".fields.<Schema.SObjectField>getAs(\"");
        try out.appendSlice(gpa, field_name);
        try out.appendSlice(gpa, "\")");
        replaced = true;
        i = field_end - 1;
        last_emit = field_end;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteTokenOverloadCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const select_fixed = try rewriteMethodCallByArgumentHint(gpa, text, "selectFields", "selectFieldsByToken", "Schema.SObjectField");
    defer gpa.free(select_fixed);

    const changed_fixed = try rewriteMethodCallByArgumentHint(gpa, select_fixed, "getChangedRecords", "getChangedRecordsByToken", "Schema.SObjectField");
    defer gpa.free(changed_fixed);

    const insert_fixed = try rewriteMethodCallByArgumentHint(gpa, changed_fixed, "checkInsert", "checkInsertByToken", "Schema.SObjectField");
    defer gpa.free(insert_fixed);

    const read_fixed = try rewriteMethodCallByArgumentHint(gpa, insert_fixed, "checkRead", "checkReadByToken", "Schema.SObjectField");
    defer gpa.free(read_fixed);

    return rewriteMethodCallByArgumentHint(gpa, read_fixed, "checkUpdate", "checkUpdateByToken", "Schema.SObjectField");
}

fn rewriteTypedNullSchemaFieldCollections(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const prefixes = [_][]const u8{
        "new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf(",
        "new ArrayList<Schema.SObjectField>(ApexCollections.listOf(",
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var matched_prefix: ?[]const u8 = null;
        for (prefixes) |prefix| {
            if (i + prefix.len <= text.len and startsWithIgnoreCase(text[i..], prefix)) {
                matched_prefix = prefix;
                break;
            }
        }
        const prefix = matched_prefix orelse continue;
        const args_start = i + prefix.len;
        const open_paren = args_start - 1;
        const close_paren = findMatchingParen(text, open_paren) orelse continue;
        const args_raw = text[args_start..close_paren];
        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);

        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(gpa);
        var local_replaced = false;
        for (args.items, 0..) |arg, idx| {
            const trimmed = std.mem.trim(u8, arg, " \t");
            const normalized = if (std.ascii.eqlIgnoreCase(trimmed, "(Object) null"))
                "(Schema.SObjectField) null"
            else if (std.ascii.eqlIgnoreCase(trimmed, "null"))
                "(Schema.SObjectField) null"
            else
                trimmed;
            if (!std.mem.eql(u8, normalized, trimmed)) {
                local_replaced = true;
            }
            if (idx != 0) try rebuilt.appendSlice(gpa, ", ");
            try rebuilt.appendSlice(gpa, normalized);
        }
        if (!local_replaced) continue;

        try out.appendSlice(gpa, text[last_emit..args_start]);
        try out.appendSlice(gpa, rebuilt.items);
        replaced = true;
        i = close_paren - 1;
        last_emit = close_paren;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteMethodLocalDefaultInitializers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var brace_depth: i32 = 0;
    var method_body_depth: ?i32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        const inside_method = method_body_depth != null and brace_depth >= method_body_depth.?;
        if (inside_method) {
            if (try defaultInitializedLocalDeclaration(gpa, line, trimmed)) |rewritten_line| {
                defer gpa.free(rewritten_line);
                try out.appendSlice(gpa, rewritten_line);
            } else {
                try out.appendSlice(gpa, line);
            }
        } else {
            try out.appendSlice(gpa, line);
        }
        try out.append(gpa, '\n');

        if (method_body_depth == null and isMethodOpeningLine(trimmed)) {
            method_body_depth = brace_depth + braceDelta(line);
        }

        brace_depth += braceDelta(line);
        if (method_body_depth != null and brace_depth < method_body_depth.?) {
            method_body_depth = null;
        }
    }

    return out.toOwnedSlice(gpa);
}

fn defaultInitializedLocalDeclaration(
    gpa: std.mem.Allocator,
    line: []const u8,
    trimmed: []const u8,
) !?[]u8 {
    if (trimmed.len == 0 or !std.mem.endsWith(u8, trimmed, ";")) return null;
    var prefix: []const u8 = "";
    var declaration = trimmed;
    if (declaration[0] == '{') {
        prefix = "{ ";
        declaration = std.mem.trim(u8, declaration[1..], " \t");
        if (declaration.len == 0) return null;
    }

    if (std.mem.indexOfScalar(u8, declaration, '=') != null) return null;
    if (std.mem.indexOfScalar(u8, declaration, '(') != null or std.mem.indexOfScalar(u8, declaration, ')') != null) return null;
    if (startsWithIgnoreCase(declaration, "return ") or
        startsWithIgnoreCase(declaration, "throw ") or
        startsWithIgnoreCase(declaration, "break") or
        startsWithIgnoreCase(declaration, "continue"))
    {
        return null;
    }

    const body = std.mem.trimRight(u8, declaration[0 .. declaration.len - 1], " \t");
    const split_index = std.mem.lastIndexOfAny(u8, body, " \t") orelse return null;
    const name = std.mem.trim(u8, body[(split_index + 1)..], " \t");
    if (!isSimpleIdentifier(name)) return null;

    var type_text = std.mem.trim(u8, body[0..split_index], " \t");
    if (type_text.len == 0) return null;
    if (startsWithIgnoreCase(type_text, "final ")) {
        type_text = std.mem.trim(u8, type_text["final ".len..], " \t");
    }
    if (type_text.len == 0 or !looksLikeTypeName(type_text)) return null;

    const initializer = defaultInitializerForType(type_text) orelse return null;
    const indent_len = line.len - std.mem.trimLeft(u8, line, " \t").len;
    const indent = line[0..indent_len];
    return try std.fmt.allocPrint(gpa, "{s}{s}{s} = {s};", .{ indent, prefix, body, initializer });
}

fn defaultInitializerForType(type_text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_text, " \t");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "boolean")) return "false";
    if (std.ascii.eqlIgnoreCase(trimmed, "char")) return "'\\0'";
    if (std.ascii.eqlIgnoreCase(trimmed, "byte") or
        std.ascii.eqlIgnoreCase(trimmed, "short") or
        std.ascii.eqlIgnoreCase(trimmed, "int") or
        std.ascii.eqlIgnoreCase(trimmed, "long") or
        std.ascii.eqlIgnoreCase(trimmed, "float") or
        std.ascii.eqlIgnoreCase(trimmed, "double"))
    {
        return "0";
    }
    return "null";
}

fn isMethodOpeningLine(trimmed: []const u8) bool {
    if (trimmed.len == 0 or !std.mem.endsWith(u8, trimmed, "{")) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') == null) return false;
    if (indexOfWordIgnoreCase(trimmed, "class") != null or
        indexOfWordIgnoreCase(trimmed, "interface") != null or
        indexOfWordIgnoreCase(trimmed, "enum") != null)
    {
        return false;
    }
    const block_keywords = [_][]const u8{
        "if",
        "for",
        "while",
        "switch",
        "catch",
        "try",
        "else",
        "do",
        "synchronized",
    };
    for (block_keywords) |keyword| {
        if (startsWithIgnoreCase(trimmed, keyword)) return false;
    }
    return true;
}

fn rewriteMethodCallByArgumentHint(
    gpa: std.mem.Allocator,
    text: []const u8,
    method_name: []const u8,
    replacement_name: []const u8,
    hint: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        if (!startsWithIgnoreCase(text[i..], method_name)) continue;

        const method_end = i + method_name.len;
        if (method_end < text.len and isIdentifierChar(text[method_end])) continue;

        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        const args = text[(open + 1)..close];
        if (std.mem.indexOf(u8, args, hint) == null) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement_name);
        replaced = true;
        i = method_end - 1;
        last_emit = method_end;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteApexArrayStyleListLiterals(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!isNewKeywordAt(text, i)) continue;

        var cursor = i + "new".len;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len) continue;

        const type_start = cursor;
        while (cursor < text.len and (isIdentifierChar(text[cursor]) or text[cursor] == '.')) : (cursor += 1) {}
        if (cursor == type_start) continue;
        const raw_type = std.mem.trim(u8, text[type_start..cursor], " \t");

        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor + 1 >= text.len or text[cursor] != '[' or text[cursor + 1] != ']') continue;
        cursor += 2;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '{') continue;

        const close_brace = findMatchingBrace(text, cursor) orelse continue;
        const items_raw = std.mem.trim(u8, text[(cursor + 1)..close_brace], " \t");
        const java_type = if (isLikelySObjectTypeForInstanceof(raw_type))
            try gpa.dupe(u8, "ApexSObject")
        else
            try convertApexType(gpa, raw_type);
        defer gpa.free(java_type);

        var replacement: []u8 = undefined;
        if (items_raw.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "new ArrayList<{s}>()", .{java_type});
        } else {
            var items = try splitCallArguments(gpa, items_raw);
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
                "new ArrayList<{s}>(ApexCollections.listOf({s}))",
                .{ java_type, joined.items },
            );
        }
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement);
        replaced = true;
        i = close_brace;
        last_emit = close_brace + 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn appendIndentedBlock(gpa: std.mem.Allocator, out: *std.ArrayList(u8), block: []const u8, indent: []const u8) !void {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) {
            try out.append(gpa, '\n');
            continue;
        }
        try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
}

fn appendInnerEnumConstantFromSegment(
    gpa: std.mem.Allocator,
    constants: *std.ArrayList([]u8),
    segment: []const u8,
) !void {
    var trimmed = std.mem.trim(u8, segment, " \t\r\n");
    if (trimmed.len == 0) return;

    if (std.mem.indexOfScalar(u8, trimmed, '(')) |paren_pos| {
        trimmed = std.mem.trim(u8, trimmed[0..paren_pos], " \t\r\n");
    }
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
        trimmed = std.mem.trim(u8, trimmed[0..eq_pos], " \t\r\n");
    }

    const name = leadingIdentifier(trimmed) orelse return;
    if (name.len == 0) return;

    for (constants.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try constants.append(gpa, try gpa.dupe(u8, name));
}

fn collectInnerEnumConstants(gpa: std.mem.Allocator, block_source: []const u8) ![]u8 {
    const open_brace = std.mem.indexOfScalar(u8, block_source, '{') orelse return gpa.dupe(u8, "PLACEHOLDER");
    const close_brace = findMatchingBrace(block_source, open_brace) orelse return gpa.dupe(u8, "PLACEHOLDER");
    const body = block_source[(open_brace + 1)..close_brace];

    var constants: std.ArrayList([]u8) = .empty;
    defer {
        for (constants.items) |item| gpa.free(item);
        constants.deinit(gpa);
    }

    var in_single = false;
    var in_double = false;
    var escaped = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var segment_start: usize = 0;
    var saw_terminator = false;

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
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
            if (ch == '\'' and i + 1 < body.len and body[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }

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
            ',' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    try appendInnerEnumConstantFromSegment(gpa, &constants, body[segment_start..i]);
                    segment_start = i + 1;
                }
            },
            ';' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    try appendInnerEnumConstantFromSegment(gpa, &constants, body[segment_start..i]);
                    saw_terminator = true;
                    break;
                }
            },
            else => {},
        }
    }

    if (!saw_terminator) {
        try appendInnerEnumConstantFromSegment(gpa, &constants, body[segment_start..]);
    }

    if (constants.items.len == 0) {
        return gpa.dupe(u8, "PLACEHOLDER");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (constants.items, 0..) |name, idx| {
        if (idx != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, name);
    }
    return out.toOwnedSlice(gpa);
}

fn parseInterfaceMethodDeclaration(
    gpa: std.mem.Allocator,
    statement: []const u8,
    interface_name: []const u8,
) !?[]u8 {
    var trimmed = std.mem.trim(u8, statement, " \t");
    if (trimmed.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, ")")) return null;
    if (containsWordIgnoreCase(trimmed, "class")) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return null;

    if (trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }
    if (trimmed.len == 0) return null;

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, trimmed[0..open_paren], '=')) |_| return null;

    const prefix = std.mem.trim(u8, trimmed[0..open_paren], " \t");
    if (prefix.len == 0) return null;

    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return null;
        if (isLikelyNonMethodLeadKeyword(first)) return null;
    }

    const candidate = lastIdentifier(prefix) orelse return null;
    if (isControlKeyword(candidate)) return null;
    if (isLikelyNonMethodLeadKeyword(candidate)) return null;
    if (std.mem.eql(u8, candidate, interface_name)) return null;

    const name_pos = std.mem.lastIndexOf(u8, prefix, candidate) orelse return null;
    const before_name = std.mem.trimRight(u8, prefix[0..name_pos], " \t");
    if (before_name.len == 0) return null;

    var before_tokens = try splitWhitespace(gpa, before_name);
    defer before_tokens.deinit(gpa);
    if (before_tokens.items.len == 0) return null;

    var return_raw: std.ArrayList(u8) = .empty;
    errdefer return_raw.deinit(gpa);

    for (before_tokens.items) |token| {
        if (isMethodModifierToken(token)) continue;
        if (return_raw.items.len != 0) try return_raw.append(gpa, ' ');
        try return_raw.appendSlice(gpa, token);
    }
    if (return_raw.items.len == 0) return null;

    const return_type_raw = try return_raw.toOwnedSlice(gpa);
    defer gpa.free(return_type_raw);

    const java_return_type = try convertApexType(gpa, return_type_raw);
    defer gpa.free(java_return_type);

    const close_paren = findMatchingParen(trimmed, open_paren) orelse return null;
    const param_segment = std.mem.trim(u8, trimmed[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    defer gpa.free(java_parameters);

    const declaration = try std.fmt.allocPrint(
        gpa,
        "public {s} {s}({s});",
        .{ java_return_type, candidate, java_parameters },
    );
    return declaration;
}

fn transpileAbstractMethodDeclarationLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    class_name: []const u8,
) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] != ';') return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, ")")) return null;
    if (containsWordIgnoreCase(trimmed, "class")) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return null;

    trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    if (trimmed.len == 0) return null;

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, trimmed[0..open_paren], '=')) |_| return null;
    const close_paren = findMatchingParen(trimmed, open_paren) orelse return null;
    const trailing = std.mem.trim(u8, trimmed[(close_paren + 1)..], " \t");
    if (trailing.len != 0) return null;

    const prefix = std.mem.trim(u8, trimmed[0..open_paren], " \t");
    if (prefix.len == 0) return null;
    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return null;
        if (isLikelyNonMethodLeadKeyword(first)) return null;
    }

    const candidate = lastIdentifier(prefix) orelse return null;
    if (isControlKeyword(candidate)) return null;
    if (isLikelyNonMethodLeadKeyword(candidate)) return null;
    if (std.mem.eql(u8, candidate, class_name)) return null;

    const name_pos = std.mem.lastIndexOf(u8, prefix, candidate) orelse return null;
    const before_name = std.mem.trimRight(u8, prefix[0..name_pos], " \t");
    if (before_name.len == 0) return null;

    var before_tokens = try splitWhitespace(gpa, before_name);
    defer before_tokens.deinit(gpa);
    if (before_tokens.items.len == 0) return null;

    var modifiers_out: std.ArrayList(u8) = .empty;
    defer modifiers_out.deinit(gpa);
    var return_raw: std.ArrayList(u8) = .empty;
    defer return_raw.deinit(gpa);
    var has_abstract = false;

    for (before_tokens.items) |token| {
        if (std.ascii.eqlIgnoreCase(token, "abstract")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "abstract");
            has_abstract = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "public")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "public");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "private")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "private");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "protected")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "protected");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "global")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "public");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "static")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "static");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "final") or
            std.ascii.eqlIgnoreCase(token, "virtual") or
            std.ascii.eqlIgnoreCase(token, "override") or
            std.ascii.eqlIgnoreCase(token, "testmethod") or
            std.ascii.eqlIgnoreCase(token, "webservice") or
            std.ascii.eqlIgnoreCase(token, "transient"))
        {
            continue;
        }

        if (return_raw.items.len > 0) try return_raw.append(gpa, ' ');
        try return_raw.appendSlice(gpa, token);
    }

    if (!has_abstract) return null;
    if (return_raw.items.len == 0) return null;
    const return_type_raw = try return_raw.toOwnedSlice(gpa);
    defer gpa.free(return_type_raw);
    if (!looksLikeTypeName(return_type_raw)) return null;

    const java_return_type = try convertApexType(gpa, return_type_raw);
    defer gpa.free(java_return_type);

    const param_segment = std.mem.trim(u8, trimmed[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    defer gpa.free(java_parameters);

    if (modifiers_out.items.len == 0) {
        const declaration = try std.fmt.allocPrint(gpa, "abstract {s} {s}({s});", .{ java_return_type, candidate, java_parameters });
        return declaration;
    }
    const declaration = try std.fmt.allocPrint(gpa, "{s} {s} {s}({s});", .{ modifiers_out.items, java_return_type, candidate, java_parameters });
    return declaration;
}

fn collectInterfaceMethodDeclarations(
    gpa: std.mem.Allocator,
    block_source: []const u8,
    interface_name: []const u8,
) ![]u8 {
    const open_brace = std.mem.indexOfScalar(u8, block_source, '{') orelse return gpa.dupe(u8, "");
    const close_brace = findMatchingBrace(block_source, open_brace) orelse return gpa.dupe(u8, "");
    const body = block_source[(open_brace + 1)..close_brace];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var statement: std.ArrayList(u8) = .empty;
    defer statement.deinit(gpa);
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);

    var in_block_comment = false;
    var annotation_paren_depth: i32 = 0;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) continue;

        if (annotation_paren_depth > 0) {
            annotation_paren_depth += parenDelta(code_only);
            if (annotation_paren_depth < 0) annotation_paren_depth = 0;
            continue;
        }

        if (trimmed[0] == '@') {
            annotation_paren_depth += parenDelta(code_only);
            if (annotation_paren_depth < 0) annotation_paren_depth = 0;
            continue;
        }

        if (trimmed[0] == '{' or trimmed[0] == '}') continue;

        if (statement.items.len > 0) try statement.append(gpa, ' ');
        try statement.appendSlice(gpa, trimmed);

        if (std.mem.indexOfScalar(u8, trimmed, ';') == null) continue;

        const candidate = std.mem.trim(u8, statement.items, " \t");
        if (try parseInterfaceMethodDeclaration(gpa, candidate, interface_name)) |decl| {
            defer gpa.free(decl);
            try out.appendSlice(gpa, "  ");
            try out.appendSlice(gpa, decl);
            try out.append(gpa, '\n');
        }
        statement.clearRetainingCapacity();
    }

    return out.toOwnedSlice(gpa);
}

fn transpileInnerTypeBlock(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    block_source: []const u8,
    outer_class_name: []const u8,
    kind_hint: InnerTypeKind,
) !?[]u8 {
    _ = source_path;
    _ = kind_hint;
    const header = (try parseInnerTypeHeader(gpa, outer_class_name, block_source)) orelse return null;
    defer {
        gpa.free(header.type_name);
        gpa.free(header.suffix);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    switch (header.kind) {
        .class => {
            const synthetic_source_path = try std.fmt.allocPrint(gpa, "{s}.cls", .{header.type_name});
            defer gpa.free(synthetic_source_path);
            var parsed_inner = try parseApexClass(gpa, synthetic_source_path, block_source);
            defer parsed_inner.deinit(gpa);

            var rendered_inner = try renderJavaClass(gpa, parsed_inner, "generated");
            defer rendered_inner.deinit(gpa);

            const body = extractRenderedJavaClassBody(rendered_inner.java) orelse return null;
            const abstract_keyword = if (header.is_abstract) " abstract" else "";

            if (header.suffix.len == 0) {
                try appendFmt(gpa, &out, "{s} static{s} class {s} {{\n", .{ header.visibility, abstract_keyword, header.type_name });
            } else {
                try appendFmt(
                    gpa,
                    &out,
                    "{s} static{s} class {s} {s} {{\n",
                    .{ header.visibility, abstract_keyword, header.type_name, header.suffix },
                );
            }
            if (body.len > 0) {
                try appendIndentedBlock(gpa, &out, body, "  ");
            }
            const exception_like = isExceptionLikeTypeHeader(header.type_name, header.suffix);
            if (exception_like) {
                const noarg_pattern = try std.fmt.allocPrint(gpa, "public {s}()", .{header.type_name});
                defer gpa.free(noarg_pattern);
                const string_pattern = try std.fmt.allocPrint(gpa, "public {s}(String", .{header.type_name});
                defer gpa.free(string_pattern);
                const has_noarg_ctor = std.mem.indexOf(u8, body, noarg_pattern) != null;
                const has_string_ctor = std.mem.indexOf(u8, body, string_pattern) != null;
                if (!has_noarg_ctor) {
                    try appendFmt(gpa, &out, "  public {s}() {{ super(); }}\n", .{header.type_name});
                }
                if (!has_string_ctor) {
                    try appendFmt(gpa, &out, "  public {s}(String message) {{ super(message); }}\n", .{header.type_name});
                }
            }
            try out.appendSlice(gpa, "}");
        },
        .interface => {
            const methods = try collectInterfaceMethodDeclarations(gpa, block_source, header.type_name);
            defer gpa.free(methods);
            if (header.suffix.len == 0) {
                try appendFmt(gpa, &out, "{s} static interface {s} {{\n", .{ header.visibility, header.type_name });
            } else {
                try appendFmt(
                    gpa,
                    &out,
                    "{s} static interface {s} {s} {{\n",
                    .{ header.visibility, header.type_name, header.suffix },
                );
            }
            if (methods.len > 0) try out.appendSlice(gpa, methods);
            try out.appendSlice(gpa, "}");
        },
        .enum_type => {
            const constants = try collectInnerEnumConstants(gpa, block_source);
            defer gpa.free(constants);
            try appendFmt(
                gpa,
                &out,
                "{s} static enum {s} {{ {s} }}",
                .{ header.visibility, header.type_name, constants },
            );
        },
    }

    const rendered = try out.toOwnedSlice(gpa);
    return rendered;
}

fn beginMethodFromSignature(
    gpa: std.mem.Allocator,
    parsed: *ParsedClass,
    signature: MethodSignature,
    signature_source: []const u8,
    line: []const u8,
    line_no: usize,
    class_is_test: bool,
    class_is_test_see_all_data: bool,
    pending_test_annotation: *bool,
    pending_test_setup_annotation: *bool,
    pending_test_see_all_data: *bool,
    current_signature: *MethodSignature,
    current_is_test: *bool,
    current_is_test_setup: *bool,
    current_is_test_see_all_data: *bool,
    current_body_base_line: *usize,
    current_body: *std.ArrayList(u8),
    brace_depth: *i32,
) !bool {
    brace_depth.* = braceDelta(line);
    current_signature.* = signature;
    const explicit_test_setup = pending_test_setup_annotation.* or containsWordIgnoreCase(signature_source, "testSetup");
    const explicit_test = pending_test_annotation.* or containsWordIgnoreCase(signature_source, "testMethod");
    const explicit_test_see_all_data = pending_test_see_all_data.*;
    const class_level_implicit_test = class_is_test and
        signature.is_static and
        std.ascii.eqlIgnoreCase(signature.java_return_type, "void") and
        std.mem.trim(u8, signature.java_parameters, " \t").len == 0 and
        startsWithIgnoreCase(signature.name, "test");
    current_is_test_setup.* = explicit_test_setup;
    current_is_test.* = (explicit_test or class_level_implicit_test) and !current_is_test_setup.*;
    current_is_test_see_all_data.* = current_is_test.* and (explicit_test_see_all_data or class_is_test_see_all_data);
    current_body_base_line.* = line_no + 1;
    current_body.* = .empty;
    pending_test_annotation.* = false;
    pending_test_setup_annotation.* = false;
    pending_test_see_all_data.* = false;

    if (std.mem.indexOfScalar(u8, line, '{')) |brace_idx| {
        var tail = std.mem.trim(u8, line[(brace_idx + 1)..], " \t");
        if (tail.len > 0 and tail[tail.len - 1] == '}') {
            tail = std.mem.trimRight(u8, tail[0 .. tail.len - 1], " \t");
        }
        if (tail.len > 0) {
            current_body_base_line.* = line_no;
            try current_body.appendSlice(gpa, tail);
            try current_body.append(gpa, '\n');
        }
    }

    if (brace_depth.* <= 0) {
        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_signature.name,
            .java_return_type = current_signature.java_return_type,
            .java_parameters = current_signature.java_parameters,
            .is_static = current_signature.is_static,
            .is_constructor = current_signature.is_constructor,
            .is_test = current_is_test.*,
            .is_test_setup = current_is_test_setup.*,
            .is_test_see_all_data = current_is_test_see_all_data.*,
            .body = body,
            .start_line = current_body_base_line.*,
        });
        return false;
    }
    return true;
}

fn shouldStartMethodSignatureBuffer(line: []const u8, class_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '@') return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') == null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return false;
    if (containsWordIgnoreCase(trimmed, "class")) return false;

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return false;
    if (std.mem.indexOfScalar(u8, trimmed[0..open_paren], '=')) |_| return false;
    const prefix = std.mem.trim(u8, trimmed[0..open_paren], " \t");
    if (prefix.len == 0) return false;

    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return false;
        if (isLikelyNonMethodLeadKeyword(first)) return false;
    }

    const candidate = lastIdentifier(prefix) orelse return false;
    if (isControlKeyword(candidate)) return false;
    if (isLikelyNonMethodLeadKeyword(candidate)) return false;
    _ = class_name;
    return true;
}

fn looksLikeMethodSignaturePrefix(gpa: std.mem.Allocator, line: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '@') return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '=') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '}') != null) return false;
    if (containsWordIgnoreCase(trimmed, "class")) return false;

    var tokens = try splitWhitespace(gpa, trimmed);
    defer tokens.deinit(gpa);
    if (tokens.items.len < 2) return false;

    if (firstIdentifier(trimmed)) |first| {
        if (isControlKeyword(first) or isLikelyNonMethodLeadKeyword(first)) return false;
    }

    var saw_type = false;
    for (tokens.items) |token| {
        if (isMethodModifierToken(token)) continue;
        if (!looksLikeTypeName(token)) return false;
        saw_type = true;
    }

    return saw_type;
}

fn parseClassName(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) ![]u8 {
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) continue;

        if (indexOfWordIgnoreCase(trimmed, "class")) |class_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..class_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
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

fn parseClassDeclarationSuffix(
    gpa: std.mem.Allocator,
    content: []const u8,
    class_name: []const u8,
) !?[]u8 {
    const DeclKind = enum {
        class,
        interface,
    };
    const DeclMatch = struct {
        kind: DeclKind,
        pos: usize,
        keyword: []const u8,
    };

    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;
    var declaration: std.ArrayList(u8) = .empty;
    defer declaration.deinit(gpa);
    var collecting = false;
    var brace_depth: i32 = 0;
    var declaration_kind: DeclKind = .class;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");

        if (brace_depth == 0) {
            if (!collecting) {
                const decl_match = blk: {
                    if (indexOfWordIgnoreCase(trimmed, "class")) |class_pos| {
                        const class_prefix = std.mem.trim(u8, trimmed[0..class_pos], " \t");
                        if (looksLikeTopLevelDeclarationPrefix(class_prefix)) {
                            break :blk DeclMatch{ .kind = .class, .pos = class_pos, .keyword = "class" };
                        }
                    }
                    if (indexOfWordIgnoreCase(trimmed, "interface")) |interface_pos| {
                        const interface_prefix = std.mem.trim(u8, trimmed[0..interface_pos], " \t");
                        if (looksLikeTopLevelDeclarationPrefix(interface_prefix)) {
                            break :blk DeclMatch{ .kind = .interface, .pos = interface_pos, .keyword = "interface" };
                        }
                    }
                    break :blk null;
                };

                if (decl_match) |decl| {
                    const after = std.mem.trimLeft(u8, trimmed[(decl.pos + decl.keyword.len)..], " \t");
                    const found_name = leadingIdentifier(after) orelse {
                        brace_depth += braceDelta(code_only);
                        continue;
                    };
                    if (!std.ascii.eqlIgnoreCase(found_name, class_name)) {
                        brace_depth += braceDelta(code_only);
                        continue;
                    }

                    collecting = true;
                    declaration_kind = decl.kind;
                    declaration.clearRetainingCapacity();
                    try declaration.appendSlice(gpa, trimmed);
                    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) break;
                    brace_depth += braceDelta(code_only);
                    continue;
                }
            } else {
                if (trimmed.len > 0) {
                    if (declaration.items.len > 0) try declaration.append(gpa, ' ');
                    try declaration.appendSlice(gpa, trimmed);
                    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) break;
                }
            }
        }

        brace_depth += braceDelta(code_only);
    }

    if (!collecting or declaration.items.len == 0) return null;

    var declaration_text = std.mem.trim(u8, declaration.items, " \t");
    if (std.mem.indexOfScalar(u8, declaration_text, '{')) |brace_pos| {
        declaration_text = std.mem.trimRight(u8, declaration_text[0..brace_pos], " \t");
    }

    const keyword = if (declaration_kind == .interface) "interface" else "class";
    const keyword_pos = indexOfWordIgnoreCase(declaration_text, keyword) orelse return null;
    const after_decl = std.mem.trimLeft(u8, declaration_text[(keyword_pos + keyword.len)..], " \t");
    const found_name = leadingIdentifier(after_decl) orelse return null;
    if (!std.ascii.eqlIgnoreCase(found_name, class_name)) return null;

    const after_name = std.mem.trimLeft(u8, after_decl[found_name.len..], " \t");
    if (after_name.len == 0) return null;

    const extends_len = "extends".len;
    const implements_len = "implements".len;
    const extends_pos = indexOfWordIgnoreCase(after_name, "extends");
    const implements_pos = if (declaration_kind == .class)
        indexOfWordIgnoreCase(after_name, "implements")
    else
        null;

    const extends_segment: []const u8 = blk: {
        if (extends_pos == null) break :blk "";
        const ext_start = extends_pos.? + extends_len;
        if (ext_start > after_name.len) break :blk "";
        const ext_end = if (implements_pos) |impl_pos|
            if (impl_pos > ext_start) impl_pos else after_name.len
        else
            after_name.len;
        if (ext_end > after_name.len or ext_end <= ext_start) break :blk "";
        break :blk std.mem.trim(u8, after_name[ext_start..ext_end], " \t");
    };

    const implements_segment: []const u8 = blk: {
        if (implements_pos == null) break :blk "";
        const impl_start = implements_pos.? + implements_len;
        break :blk std.mem.trimLeft(u8, after_name[impl_start..], " \t");
    };

    var suffix: std.ArrayList(u8) = .empty;
    errdefer suffix.deinit(gpa);

    if (extends_segment.len > 0) {
        var extends_items = try splitTypeArguments(gpa, extends_segment);
        defer extends_items.deinit(gpa);
        if (extends_items.items.len > 0) {
            try suffix.appendSlice(gpa, " extends ");
            for (extends_items.items, 0..) |ext_item, idx| {
                const converted_extends = try convertApexType(gpa, ext_item);
                defer gpa.free(converted_extends);
                if (idx != 0) try suffix.appendSlice(gpa, ", ");
                try suffix.appendSlice(gpa, converted_extends);
            }
        }
    }

    if (declaration_kind == .class and implements_segment.len > 0) {
        var impl_items = try splitTypeArguments(gpa, implements_segment);
        defer impl_items.deinit(gpa);
        if (impl_items.items.len > 0) {
            var emitted_any = false;
            for (impl_items.items) |impl_item| {
                if (isSelfQualifiedTypeReference(impl_item, class_name)) continue;
                const converted_impl = try convertApexType(gpa, impl_item);
                defer gpa.free(converted_impl);
                if (!emitted_any) {
                    try suffix.appendSlice(gpa, " implements ");
                    emitted_any = true;
                } else {
                    try suffix.appendSlice(gpa, ", ");
                }
                try suffix.appendSlice(gpa, converted_impl);
            }
        }
    }

    if (suffix.items.len == 0) {
        suffix.deinit(gpa);
        return null;
    }
    const owned = try suffix.toOwnedSlice(gpa);
    return owned;
}

fn parseTopLevelDeclarationKind(
    gpa: std.mem.Allocator,
    content: []const u8,
    class_name: []const u8,
) !TopLevelKind {
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) continue;

        if (indexOfWordIgnoreCase(trimmed, "class")) |class_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..class_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
            const after = std.mem.trimLeft(u8, trimmed[(class_pos + "class".len)..], " \t");
            if (leadingIdentifier(after)) |name| {
                if (std.ascii.eqlIgnoreCase(name, class_name)) return .class;
            }
        }

        if (indexOfWordIgnoreCase(trimmed, "interface")) |interface_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..interface_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
            const after = std.mem.trimLeft(u8, trimmed[(interface_pos + "interface".len)..], " \t");
            if (leadingIdentifier(after)) |name| {
                if (std.ascii.eqlIgnoreCase(name, class_name)) return .interface;
            }
        }

        if (indexOfWordIgnoreCase(trimmed, "enum")) |enum_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..enum_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
            const after = std.mem.trimLeft(u8, trimmed[(enum_pos + "enum".len)..], " \t");
            if (leadingIdentifier(after)) |name| {
                if (std.ascii.eqlIgnoreCase(name, class_name)) return .enum_type;
            }
        }
    }
    return .class;
}

fn parseTopLevelEnumConstants(
    gpa: std.mem.Allocator,
    content: []const u8,
    class_name: []const u8,
) !?[]u8 {
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(gpa);

    var lines_for_strip = std.mem.splitScalar(u8, content, '\n');
    while (lines_for_strip.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        try stripped.appendSlice(gpa, code_only);
        try stripped.append(gpa, '\n');
    }

    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, stripped.items, '\n');
    while (lines.next()) |line| {
        const line_trimmed_left = std.mem.trimLeft(u8, line, " \t");
        const trim_left_len = line.len - line_trimmed_left.len;
        const trimmed = std.mem.trim(u8, line_trimmed_left, " \t");
        if (trimmed.len == 0) {
            offset += line.len + 1;
            continue;
        }

        const enum_pos = indexOfWordIgnoreCase(trimmed, "enum") orelse {
            offset += line.len + 1;
            continue;
        };
        const prefix = std.mem.trim(u8, trimmed[0..enum_pos], " \t");
        if (!looksLikeTopLevelDeclarationPrefix(prefix)) {
            offset += line.len + 1;
            continue;
        }

        const after_enum = std.mem.trimLeft(u8, trimmed[(enum_pos + "enum".len)..], " \t");
        const enum_name = leadingIdentifier(after_enum) orelse {
            offset += line.len + 1;
            continue;
        };
        if (!std.ascii.eqlIgnoreCase(enum_name, class_name)) {
            offset += line.len + 1;
            continue;
        }

        const line_start = offset + trim_left_len;
        const open_brace = std.mem.indexOfScalarPos(u8, stripped.items, line_start, '{') orelse return null;
        const close_brace = findMatchingBrace(stripped.items, open_brace) orelse return null;
        const enum_block = stripped.items[line_start .. close_brace + 1];
        const constants = try collectInnerEnumConstants(gpa, enum_block);
        return constants;
    }

    return null;
}

fn looksLikeClassDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;

    var found_token = false;
    var it = std.mem.tokenizeAny(u8, prefix, " \t\r\n");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        found_token = true;
        if (!isClassDeclarationPrefixToken(token)) return false;
    }
    return found_token;
}

fn looksLikeTopLevelDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return looksLikeClassDeclarationPrefix(prefix);
}

fn looksLikeInnerTypeDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return looksLikeClassDeclarationPrefix(prefix);
}

fn isClassDeclarationPrefixToken(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "public") or
        std.ascii.eqlIgnoreCase(token, "private") or
        std.ascii.eqlIgnoreCase(token, "protected") or
        std.ascii.eqlIgnoreCase(token, "global") or
        std.ascii.eqlIgnoreCase(token, "with") or
        std.ascii.eqlIgnoreCase(token, "without") or
        std.ascii.eqlIgnoreCase(token, "sharing") or
        std.ascii.eqlIgnoreCase(token, "inherited") or
        std.ascii.eqlIgnoreCase(token, "virtual") or
        std.ascii.eqlIgnoreCase(token, "abstract") or
        std.ascii.eqlIgnoreCase(token, "final") or
        std.ascii.eqlIgnoreCase(token, "static") or
        std.ascii.eqlIgnoreCase(token, "testmethod");
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

fn detectClassSeeAllData(content: []const u8) bool {
    var pending_see_all_data = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (isIsTestAnnotation(trimmed)) {
            pending_see_all_data = isTestAnnotationSeeAllDataTrue(trimmed);
            continue;
        }

        if (containsWordIgnoreCase(trimmed, "class")) {
            return pending_see_all_data;
        }

        if (trimmed[0] != '@') {
            pending_see_all_data = false;
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
        if (isLikelyNonMethodLeadKeyword(first)) return null;
    }

    const candidate = lastIdentifier(prefix) orelse return null;
    if (isControlKeyword(candidate)) return null;
    if (isLikelyNonMethodLeadKeyword(candidate)) return null;
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

fn transpileClassMemberLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    test_visible_hint: bool,
) !?[]u8 {
    const trimmed_raw = std.mem.trim(u8, line, " \t");
    const annotation_info = try stripLeadingAnnotationsFromMemberLine(gpa, trimmed_raw);
    defer if (annotation_info.stripped) |value| gpa.free(value);
    const trimmed = if (annotation_info.stripped) |value| std.mem.trim(u8, value, " \t") else trimmed_raw;
    const test_visible = test_visible_hint or annotation_info.has_test_visible;
    if (trimmed.len == 0) return null;
    if (isIsTestAnnotation(trimmed)) return null;
    if (try transpileExceptionClassDeclarationLine(gpa, trimmed)) |exception_decl| {
        if (!test_visible) return exception_decl;
        const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, exception_decl);
        gpa.free(exception_decl);
        return promoted;
    }
    if (looksLikeTypeDeclarationLine(trimmed)) return null;
    if (std.mem.eql(u8, trimmed, "{") or std.mem.eql(u8, trimmed, "}")) return null;
    if (try transpileStaticInitializerBlock(gpa, trimmed)) |static_block| {
        return static_block;
    }

    if (try transpilePropertyDeclarationLine(gpa, trimmed)) |property_line| {
        if (!test_visible) return property_line;
        const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, property_line);
        gpa.free(property_line);
        return promoted;
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

    const declaration = (try transpileTypedDeclarationLine(gpa, without_semicolon, true)) orelse return null;
    if (!test_visible) return declaration;
    const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, declaration);
    gpa.free(declaration);
    return promoted;
}

fn transpileStaticInitializerBlock(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!startsWithWordIgnoreCase(trimmed, "static")) return null;

    const static_len = "static".len;
    if (static_len < trimmed.len and isIdentifierChar(trimmed[static_len])) return null;

    var open_brace = static_len;
    while (open_brace < trimmed.len and std.ascii.isWhitespace(trimmed[open_brace])) : (open_brace += 1) {}
    if (open_brace >= trimmed.len or trimmed[open_brace] != '{') return null;
    const close_brace = findMatchingBrace(trimmed, open_brace) orelse return null;
    if (std.mem.trim(u8, trimmed[(close_brace + 1)..], " \t").len != 0) return null;

    const body_raw = std.mem.trim(u8, trimmed[(open_brace + 1)..close_brace], " \t");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "static {\n");

    if (body_raw.len > 0) {
        var statements = try collectLogicalStatements(gpa, body_raw);
        defer {
            for (statements.items) |statement| gpa.free(statement.text);
            statements.deinit(gpa);
        }

        for (statements.items) |statement| {
            const stmt = std.mem.trim(u8, statement.text, " \t");
            if (stmt.len == 0) continue;
            if (try transpileExecutableLine(gpa, stmt)) |converted| {
                defer gpa.free(converted);
                try appendFmt(gpa, &out, "    {s}\n", .{converted});
            } else {
                try appendFmt(gpa, &out, "    // {s}\n", .{stmt});
            }
        }
    }

    try out.appendSlice(gpa, "  }");
    const rendered = try out.toOwnedSlice(gpa);
    return rendered;
}

const LeadingMemberAnnotations = struct {
    stripped: ?[]u8 = null,
    has_test_visible: bool = false,
};

fn stripLeadingAnnotationsFromMemberLine(
    gpa: std.mem.Allocator,
    line: []const u8,
) !LeadingMemberAnnotations {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] != '@') return .{};

    var cursor: usize = 0;
    var changed = false;
    var has_test_visible = false;
    while (cursor < trimmed.len and trimmed[cursor] == '@') {
        changed = true;
        cursor += 1;
        const annotation_name = leadingIdentifier(trimmed[cursor..]) orelse break;
        if (std.ascii.eqlIgnoreCase(annotation_name, "TestVisible")) {
            has_test_visible = true;
        }
        cursor += annotation_name.len;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        if (cursor < trimmed.len and trimmed[cursor] == '(') {
            const close = findMatchingParen(trimmed, cursor) orelse break;
            cursor = close + 1;
        }
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
    }

    if (!changed) return .{ .has_test_visible = has_test_visible };
    const stripped = std.mem.trim(u8, trimmed[cursor..], " \t");
    const owned = try gpa.dupe(u8, stripped);
    return .{
        .stripped = owned,
        .has_test_visible = has_test_visible,
    };
}

fn promoteDeclarationVisibilityForTestVisible(
    gpa: std.mem.Allocator,
    declaration: []const u8,
) ![]u8 {
    const trimmed = std.mem.trimLeft(u8, declaration, " \t");
    const leading_ws = declaration.len - trimmed.len;
    const private_prefix = "private ";
    const protected_prefix = "protected ";

    var replace_len: usize = 0;
    if (startsWithIgnoreCase(trimmed, private_prefix)) {
        replace_len = private_prefix.len;
    } else if (startsWithIgnoreCase(trimmed, protected_prefix)) {
        replace_len = protected_prefix.len;
    } else {
        return gpa.dupe(u8, declaration);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, declaration[0..leading_ws]);
    try out.appendSlice(gpa, "public ");
    try out.appendSlice(gpa, trimmed[replace_len..]);
    return out.toOwnedSlice(gpa);
}

fn transpileExceptionClassDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const class_pos = indexOfWordIgnoreCase(line, "class") orelse return null;
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;

    const after_class = std.mem.trimLeft(u8, line[(class_pos + "class".len)..], " \t");
    const class_name = leadingIdentifier(after_class) orelse return null;
    if (class_name.len == 0) return null;

    var exception_like = endsWithIgnoreCase(class_name, "Exception");
    if (!exception_like) {
        if (indexOfWordIgnoreCase(after_class, "extends")) |extends_pos| {
            const after_extends = std.mem.trimLeft(
                u8,
                after_class[(extends_pos + "extends".len)..],
                " \t",
            );
            if (leadingIdentifier(after_extends)) |extends_name| {
                exception_like = endsWithIgnoreCase(extends_name, "Exception");
            }
        }
    }
    if (!exception_like) return null;

    const prefix = std.mem.trim(u8, line[0..class_pos], " \t");
    const visibility = visibilityModifierForInnerClass(prefix);
    return try std.fmt.allocPrint(
        gpa,
        "{s} static class {s} extends apexemu.runtime.System.Exception {{ public {s}() {{ super(); }} public {s}(String message) {{ super(message); }} }}",
        .{ visibility, class_name, class_name, class_name },
    );
}

fn visibilityModifierForInnerClass(prefix: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, prefix, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "private")) return "private";
        if (std.ascii.eqlIgnoreCase(token, "protected")) return "protected";
        if (std.ascii.eqlIgnoreCase(token, "public")) return "public";
        if (std.ascii.eqlIgnoreCase(token, "global")) return "public";
    }
    return "public";
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

fn looksLikePropertyDeclarationHeader(gpa: std.mem.Allocator, line: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    const first = firstIdentifier(trimmed) orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, "public") and
        !std.ascii.eqlIgnoreCase(first, "private") and
        !std.ascii.eqlIgnoreCase(first, "protected") and
        !std.ascii.eqlIgnoreCase(first, "global"))
    {
        return false;
    }
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '=') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '}') != null) return false;
    if (containsWordIgnoreCase(trimmed, "class")) return false;
    if (containsWordIgnoreCase(trimmed, "interface")) return false;
    if (containsWordIgnoreCase(trimmed, "enum")) return false;
    if (containsWordIgnoreCase(trimmed, "implements")) return false;
    if (containsWordIgnoreCase(trimmed, "extends")) return false;

    const parsed = (try parseTypedVariableDeclaration(gpa, trimmed, true)) orelse return false;
    defer {
        gpa.free(parsed.declaration_head);
        gpa.free(parsed.variable_name);
        gpa.free(parsed.java_type);
    }
    return true;
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

    if (hasTopLevelComma(left)) {
        if (try transpileTypedMultiDeclarationLine(gpa, left, if (eq_pos) |pos| std.mem.trim(u8, trimmed[(pos + 1)..], " \t") else null, allow_visibility)) |multi| {
            return multi;
        }
    }

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
    const collection_unwrapped_rhs = try maybeUnwrapCollectionQueryResult(gpa, java_type, converted_rhs);
    defer gpa.free(collection_unwrapped_rhs);
    const normalized_rhs = try maybeWrapSingleQueryAssignment(gpa, name, collection_unwrapped_rhs);
    defer gpa.free(normalized_rhs);
    const coerced_rhs = try coerceLiteralForDeclaredType(gpa, java_type, normalized_rhs);
    defer gpa.free(coerced_rhs);

    if (modifier_out.items.len == 0) {
        return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ java_type, name, coerced_rhs });
    }
    return try std.fmt.allocPrint(gpa, "{s} {s} {s} = {s};", .{ modifier_out.items, java_type, name, coerced_rhs });
}

fn transpileTypedMultiDeclarationLine(
    gpa: std.mem.Allocator,
    left: []const u8,
    rhs_opt: ?[]const u8,
    allow_visibility: bool,
) !?[]u8 {
    var pieces = try splitCallArguments(gpa, left);
    defer pieces.deinit(gpa);
    if (pieces.items.len < 2) return null;

    const first_piece = std.mem.trim(u8, pieces.items[0], " \t");
    const first = (try parseTypedVariableDeclaration(gpa, first_piece, allow_visibility)) orelse return null;
    defer {
        gpa.free(first.declaration_head);
        gpa.free(first.variable_name);
        gpa.free(first.java_type);
    }

    var names_out: std.ArrayList(u8) = .empty;
    defer names_out.deinit(gpa);
    try names_out.appendSlice(gpa, first.variable_name);

    for (pieces.items[1..]) |raw_name| {
        const name = std.mem.trim(u8, raw_name, " \t");
        if (!isSimpleIdentifier(name)) return null;
        try names_out.appendSlice(gpa, ", ");
        try names_out.appendSlice(gpa, name);
    }

    const var_pos = std.mem.lastIndexOf(u8, first.declaration_head, first.variable_name) orelse return null;
    const decl_prefix = std.mem.trimRight(u8, first.declaration_head[0..var_pos], " \t");
    if (decl_prefix.len == 0) return null;

    if (rhs_opt) |rhs| {
        if (rhs.len == 0) return null;
        const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
        defer gpa.free(converted_rhs);
        const coerced_rhs = try coerceLiteralForDeclaredType(gpa, first.java_type, converted_rhs);
        defer gpa.free(coerced_rhs);
        return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ decl_prefix, names_out.items, coerced_rhs });
    }

    return try std.fmt.allocPrint(gpa, "{s} {s};", .{ decl_prefix, names_out.items });
}

fn coerceLiteralForDeclaredType(
    gpa: std.mem.Allocator,
    declared_java_type: []const u8,
    rhs: []const u8,
) ![]u8 {
    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    if (std.ascii.eqlIgnoreCase(declared_java_type, "Double") and isIntegerLiteral(trimmed_rhs)) {
        return std.fmt.allocPrint(gpa, "{s}.0", .{trimmed_rhs});
    }
    if (std.ascii.eqlIgnoreCase(declared_java_type, "String") and shouldCoerceExpressionToString(trimmed_rhs)) {
        return std.fmt.allocPrint(gpa, "String.valueOf({s})", .{trimmed_rhs});
    }
    return gpa.dupe(u8, rhs);
}

fn shouldCoerceExpressionToString(rhs: []const u8) bool {
    const trimmed = std.mem.trim(u8, rhs, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '"') return false;
    if (std.mem.indexOfScalar(u8, trimmed, '+') != null) return false;

    const known_non_string_producers = [_][]const u8{
        "System.now(",
        "DateTime.now(",
        "Date.today(",
        "System.today(",
    };
    for (known_non_string_producers) |prefix| {
        if (startsWithIgnoreCase(trimmed, prefix)) return true;
    }
    return false;
}

fn isIntegerLiteral(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return false;

    var idx: usize = 0;
    if (trimmed[idx] == '+' or trimmed[idx] == '-') {
        idx += 1;
    }
    if (idx >= trimmed.len) return false;

    while (idx < trimmed.len) : (idx += 1) {
        if (!std.ascii.isDigit(trimmed[idx])) return false;
    }
    return true;
}

fn appendImportUnlessClassNameConflicts(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    class_name: []const u8,
    import_line: []const u8,
    imported_simple_name: []const u8,
) !void {
    if (std.ascii.eqlIgnoreCase(class_name, imported_simple_name)) return;
    try out.appendSlice(gpa, import_line);
}

fn renderJavaClass(gpa: std.mem.Allocator, parsed: ParsedClass, package_name: []const u8) !RenderedClass {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var unsupported_statements: usize = 0;
    var unsupported_lines: std.ArrayList(UnsupportedLine) = .empty;
    errdefer {
        for (unsupported_lines.items) |line| gpa.free(line.statement);
        unsupported_lines.deinit(gpa);
    }

    try appendFmt(gpa, &out, "package {s};\n\n", .{package_name});
    if (parsed.top_level_kind == .enum_type) {
        if (parsed.top_level_enum_constants) |enum_constants| {
            try appendFmt(
                gpa,
                &out,
                "// Generated by `apexgov emulate transpile` from {s}\n",
                .{parsed.source_path},
            );
            try appendFmt(gpa, &out, "public enum {s} {{ {s} }}\n", .{ parsed.class_name, enum_constants });
            return .{
                .java = try out.toOwnedSlice(gpa),
                .unsupported_statements = 0,
                .unsupported_lines = unsupported_lines,
            };
        }
    }

    if (parsed.top_level_kind == .interface) {
        const source_content = std.fs.cwd().readFileAlloc(gpa, parsed.source_path, 16 * 1024 * 1024) catch null;
        defer if (source_content) |content| gpa.free(content);
        const interface_methods = if (source_content) |content|
            try collectInterfaceMethodDeclarations(gpa, content, parsed.class_name)
        else
            try gpa.dupe(u8, "");
        defer gpa.free(interface_methods);

        try out.appendSlice(gpa, "import apexemu.runtime.*;\n");
        try out.appendSlice(gpa, "import java.util.*;\n\n");
        try appendFmt(
            gpa,
            &out,
            "// Generated by `apexgov emulate transpile` from {s}\n",
            .{parsed.source_path},
        );
        if (parsed.class_declaration_suffix) |suffix| {
            try appendFmt(gpa, &out, "public interface {s}{s} {{\n", .{ parsed.class_name, suffix });
        } else {
            try appendFmt(gpa, &out, "public interface {s} {{\n", .{parsed.class_name});
        }
        if (interface_methods.len > 0) try out.appendSlice(gpa, interface_methods);
        try out.appendSlice(gpa, "}\n");

        const raw_java = try out.toOwnedSlice(gpa);
        errdefer gpa.free(raw_java);
        const compatibility_fixed = try rewriteKnownCompatibilityFixups(gpa, raw_java);
        gpa.free(raw_java);
        const interface_fixed = try rewriteInterfaceCompatibilityFixups(gpa, compatibility_fixed);
        gpa.free(compatibility_fixed);
        return .{
            .java = interface_fixed,
            .unsupported_statements = 0,
            .unsupported_lines = unsupported_lines,
        };
    }

    try out.appendSlice(gpa, "import apexemu.runtime.*;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexSObject;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexCollections;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexSwitch;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexStrings;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.StringException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexAssert;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexCompare;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexMath;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Database;\n", "Database");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.JSON;\n", "JSON");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Test;\n", "Test");
    try out.appendSlice(gpa, "import apexemu.runtime.SystemAssert;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Security;\n", "Security");
    try out.appendSlice(gpa, "import apexemu.runtime.DmlException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ConnectApi;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Cache;\n", "Cache");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.EventBus;\n", "EventBus");
    try out.appendSlice(gpa, "import apexemu.runtime.DataWeave;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.DataWeaveScriptResource;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System;\n", "System");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System.Type;\n", "Type");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System.AccessType;\n", "AccessType");
    try out.appendSlice(gpa, "import apexemu.runtime.System.AccessLevel;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System.SObjectAccessDecision;\n", "SObjectAccessDecision");
    try out.appendSlice(gpa, "import apexemu.runtime.System.NoAccessException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.System.SecurityException;\n\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Schema;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Trigger;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.UserInfo;\n", "UserInfo");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Limits;\n", "Limits");
    try out.appendSlice(gpa, "import apexemu.runtime.Messaging;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.VisualEditor;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Network;\n", "Network");
    try out.appendSlice(gpa, "import apexemu.runtime.DateTime;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Date;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Time;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexPages;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.PageReference;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Page;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Queueable;\n", "Queueable");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Schedulable;\n", "Schedulable");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.RestContext;\n", "RestContext");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.RestRequest;\n", "RestRequest");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.RestResponse;\n", "RestResponse");
    try out.appendSlice(gpa, "import apexemu.runtime.QueryException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.JSONException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Crypto;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Http;\n", "Http");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.HttpRequest;\n", "HttpRequest");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.HttpResponse;\n", "HttpResponse");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.HttpCalloutMock;\n", "HttpCalloutMock");
    try out.appendSlice(gpa, "import apexemu.runtime.URL;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.EncodingUtil;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Blob;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.AuraHandledException;\n\n");
    try out.appendSlice(gpa, "import java.util.ArrayList;\n");
    try out.appendSlice(gpa, "import java.util.LinkedHashMap;\n");
    try out.appendSlice(gpa, "import java.util.LinkedHashSet;\n");
    try out.appendSlice(gpa, "import java.util.Iterator;\n");
    try out.appendSlice(gpa, "import java.util.List;\n");
    try out.appendSlice(gpa, "import java.util.Map;\n");
    try out.appendSlice(gpa, "import java.util.Set;\n\n");
    try out.appendSlice(gpa, "import java.util.Comparator;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import java.util.regex.Matcher;\n", "Matcher");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import java.util.regex.Pattern;\n", "Pattern");
    try out.append(gpa, '\n');
    try appendFmt(
        gpa,
        &out,
        "// Generated by `apexgov emulate transpile` from {s}\n",
        .{parsed.source_path},
    );
    const class_suffix_raw = parsed.class_declaration_suffix orelse "";
    const class_suffix_inner_qualified = try rewriteClassSuffixInnerTypeRefs(gpa, class_suffix_raw, parsed.class_name, parsed.fields.items);
    defer gpa.free(class_suffix_inner_qualified);
    const class_suffix = try stripSelfInnerImplementsFromClassSuffix(gpa, class_suffix_inner_qualified, parsed.class_name, parsed.fields.items);
    defer gpa.free(class_suffix);
    const class_decl_prefix = if (classContainsAbstractMethodDeclaration(parsed.fields.items))
        "public abstract class"
    else
        "public class";
    try appendFmt(gpa, &out, "{s} {s}{s} {{\n", .{ class_decl_prefix, parsed.class_name, class_suffix });
    const is_comparator_class = class_suffix.len > 0 and std.mem.indexOf(u8, class_suffix, "Comparator") != null;

    if (parsed.fields.items.len == 0 and parsed.methods.items.len == 0) {
        try out.appendSlice(gpa, "  // No method body was detected in the Apex source.\n");
    }

    if (parsed.fields.items.len > 0) {
        for (parsed.fields.items) |field| {
            try appendFmt(gpa, &out, "  {s}\n", .{field.declaration});
        }
        try out.append(gpa, '\n');
    }

    var emit_method = try gpa.alloc(bool, parsed.methods.items.len);
    defer gpa.free(emit_method);
    @memset(emit_method, true);

    for (parsed.methods.items, 0..) |method, method_idx| {
        var lookahead = method_idx + 1;
        while (lookahead < parsed.methods.items.len) : (lookahead += 1) {
            if (methodsCollapseToSameJavaSignature(method, parsed.methods.items[lookahead])) {
                emit_method[method_idx] = false;
                break;
            }
        }
    }

    for (parsed.methods.items, 0..) |method, method_idx| {
        if (!emit_method[method_idx]) continue;
        const emitted_name = if (method.is_constructor)
            parsed.class_name
        else
            method.name;

        if (method.is_test_setup and !method.is_constructor) {
            try out.appendSlice(gpa, "  @apexemu.annotations.TestSetup\n");
        } else if (method.is_test and !method.is_constructor) {
            if (method.is_test_see_all_data) {
                try out.appendSlice(gpa, "  @apexemu.annotations.Test(seeAllData = true)\n");
            } else {
                try out.appendSlice(gpa, "  @apexemu.annotations.Test\n");
            }
        }
        if (method.is_constructor) {
            try appendFmt(gpa, &out, "  public {s}({s}) {{\n", .{ emitted_name, method.java_parameters });
        } else {
            const static_prefix = if (method.is_static) "static " else "";
            const emitted_return_type = if (is_comparator_class and
                std.ascii.eqlIgnoreCase(method.name, "compare") and
                std.ascii.eqlIgnoreCase(method.java_return_type, "Integer"))
                "int"
            else if (std.ascii.eqlIgnoreCase(method.name, "hasNext") and
                std.ascii.eqlIgnoreCase(method.java_return_type, "Boolean"))
                "boolean"
            else
                method.java_return_type;
            try appendFmt(
                gpa,
                &out,
                "  public {s}{s} {s}({s}) {{\n",
                .{ static_prefix, emitted_return_type, emitted_name, method.java_parameters },
            );
        }
        try out.appendSlice(gpa, "    // TODO(apex): method body is copied as comments and needs manual porting.\n");

        var statements = try collectLogicalStatements(gpa, method.body);
        defer {
            for (statements.items) |statement| gpa.free(statement.text);
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
        // Track brace depths where System.runAs lambda blocks were opened
        var runas_depth_stack: std.ArrayList(i32) = .empty;
        defer runas_depth_stack.deinit(gpa);

        for (statements.items, 0..) |statement, idx| {
            const trimmed = std.mem.trim(u8, statement.text, " \t");
            if (trimmed.len == 0) continue;
            if (idx == statements.items.len - 1 and std.mem.eql(u8, trimmed, "}")) continue;

            while (switch_stack.items.len > 0 and brace_depth < switch_stack.items[switch_stack.items.len - 1].body_depth) {
                const stale = switch_stack.pop().?;
                gpa.free(stale.subject_expr);
            }

            // Check if this closing brace matches a runAs block
            if (std.mem.eql(u8, trimmed, "}") and runas_depth_stack.items.len > 0) {
                const expected_depth = runas_depth_stack.items[runas_depth_stack.items.len - 1];
                if (brace_depth - 1 == expected_depth) {
                    _ = runas_depth_stack.pop();
                    try appendFmt(gpa, &out, "    }} finally {{ Test.endRunAs(); }}\n", .{});
                    brace_depth += braceDelta(trimmed);
                    continue;
                }
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

                // Track runAs block openings
                if (std.mem.indexOf(u8, converted, "// RUNAS_BLOCK") != null) {
                    try runas_depth_stack.append(gpa, brace_depth);
                }

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
                try unsupported_lines.append(gpa, .{
                    .method_name = method.name,
                    .source_line = method.start_line + statement.line_offset,
                    .reason = inferUnsupportedReason(trimmed),
                    .statement = try gpa.dupe(u8, trimmed),
                });
            }

            brace_depth += braceDelta(trimmed);
            while (switch_stack.items.len > 0 and brace_depth < switch_stack.items[switch_stack.items.len - 1].body_depth) {
                const stale = switch_stack.pop().?;
                gpa.free(stale.subject_expr);
            }
        }

        try out.appendSlice(gpa, "  }\n\n");
        try appendDoubleNumberCompatibilityOverload(gpa, &out, method, emitted_name);
    }

    try out.appendSlice(gpa,
        \\  @SuppressWarnings("unchecked")
        \\  public <T> T getAs(String field) {
        \\    return (T) ApexSwitch.getAs(this, field);
        \\  }
        \\
    );

    try out.appendSlice(gpa, "}\n");
    const raw_java = try out.toOwnedSlice(gpa);
    errdefer gpa.free(raw_java);

    const normalized_method_case = try rewriteCommonJavaMethodCase(gpa, raw_java);
    gpa.free(raw_java);
    errdefer gpa.free(normalized_method_case);

    const sobject_field_converted = try convertSObjectFieldAccess(gpa, normalized_method_case);
    gpa.free(normalized_method_case);
    errdefer gpa.free(sobject_field_converted);

    const sobject_type_field_constants = try rewriteTypeSObjectFieldConstants(gpa, sobject_field_converted);
    gpa.free(sobject_field_converted);
    errdefer gpa.free(sobject_type_field_constants);

    const sobject_fieldset_constants = try rewriteSObjectTypeFieldSetConstants(gpa, sobject_type_field_constants);
    gpa.free(sobject_type_field_constants);
    errdefer gpa.free(sobject_fieldset_constants);

    const sobject_get_as_calls = try rewriteSObjectGetAsMethodCalls(gpa, sobject_fieldset_constants);
    gpa.free(sobject_fieldset_constants);
    errdefer gpa.free(sobject_get_as_calls);

    const string_instance_calls = try rewriteStringInstanceMethodCalls(gpa, sobject_get_as_calls);
    gpa.free(sobject_get_as_calls);
    errdefer gpa.free(string_instance_calls);

    const println_calls = try rewritePrintlnGetAsCalls(gpa, string_instance_calls);
    gpa.free(string_instance_calls);
    errdefer gpa.free(println_calls);

    const identifier_case_fixed = try rewriteSpecificIdentifierCase(gpa, println_calls);
    gpa.free(println_calls);
    errdefer gpa.free(identifier_case_fixed);

    const test_double_ctor_fixed = try rewriteTestDoubleClassCtorCalls(gpa, identifier_case_fixed);
    gpa.free(identifier_case_fixed);
    errdefer gpa.free(test_double_ctor_fixed);

    const sobject_field_after_case = try convertSObjectFieldAccess(gpa, test_double_ctor_fixed);
    gpa.free(test_double_ctor_fixed);
    errdefer gpa.free(sobject_field_after_case);

    const system_type_list_literals = try rewriteSystemTypeListOfClassLiterals(gpa, sobject_field_after_case);
    gpa.free(sobject_field_after_case);
    errdefer gpa.free(system_type_list_literals);

    const system_type_method_class_literals = try rewriteSystemTypeMethodClassLiteralArgs(gpa, system_type_list_literals);
    gpa.free(system_type_list_literals);
    errdefer gpa.free(system_type_method_class_literals);

    const clone_calls = try rewriteNoArgCloneCalls(gpa, system_type_method_class_literals);
    gpa.free(system_type_method_class_literals);
    errdefer gpa.free(clone_calls);

    const dynamic_set_calls = try rewriteStringKeyedSetMethodCalls(gpa, clone_calls);
    gpa.free(clone_calls);
    errdefer gpa.free(dynamic_set_calls);

    const sort_calls = try rewriteNoArgSortCalls(gpa, dynamic_set_calls);
    gpa.free(dynamic_set_calls);
    errdefer gpa.free(sort_calls);

    const dynamic_where_binds_fixed = try rewriteDynamicWhereClauseQueryBinds(gpa, sort_calls);
    gpa.free(sort_calls);
    errdefer gpa.free(dynamic_where_binds_fixed);

    const math_mod_fixed = try rewriteMathModCalls(gpa, dynamic_where_binds_fixed);
    gpa.free(dynamic_where_binds_fixed);
    errdefer gpa.free(math_mod_fixed);

    const compatibility_fixed = try rewriteKnownCompatibilityFixups(gpa, math_mod_fixed);
    gpa.free(math_mod_fixed);
    errdefer gpa.free(compatibility_fixed);

    const apex_mocks_utils_fixed = try rewriteApexMocksUtilsMethodFixups(gpa, compatibility_fixed);
    gpa.free(compatibility_fixed);
    errdefer gpa.free(apex_mocks_utils_fixed);

    return .{
        .java = apex_mocks_utils_fixed,
        .unsupported_statements = unsupported_statements,
        .unsupported_lines = unsupported_lines,
    };
}

fn methodsCollapseToSameJavaSignature(a: ParsedMethod, b: ParsedMethod) bool {
    if (a.is_constructor != b.is_constructor) return false;
    if (a.is_constructor) {
        return std.mem.eql(u8, std.mem.trim(u8, a.java_parameters, " \t"), std.mem.trim(u8, b.java_parameters, " \t"));
    }
    if (!std.ascii.eqlIgnoreCase(a.name, b.name)) return false;
    return std.mem.eql(u8, std.mem.trim(u8, a.java_parameters, " \t"), std.mem.trim(u8, b.java_parameters, " \t"));
}

fn classContainsAbstractMethodDeclaration(fields: []const ParsedField) bool {
    for (fields) |field| {
        const declaration = std.mem.trim(u8, field.declaration, " \t");
        if (declaration.len == 0) continue;
        if (!std.mem.containsAtLeast(u8, declaration, 1, "(")) continue;
        if (!std.mem.endsWith(u8, declaration, ";")) continue;
        if (startsWithIgnoreCase(declaration, "abstract ")) return true;
        if (std.mem.indexOf(u8, declaration, " abstract ")) |_| return true;
    }
    return false;
}

fn appendDoubleNumberCompatibilityOverload(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    method: ParsedMethod,
    emitted_name: []const u8,
) !void {
    if (method.is_constructor or !method.is_static) return;

    var params = try splitCallArguments(gpa, method.java_parameters);
    defer params.deinit(gpa);
    if (params.items.len == 0) return;

    var bridge_params: std.ArrayList(u8) = .empty;
    defer bridge_params.deinit(gpa);
    var call_args: std.ArrayList(u8) = .empty;
    defer call_args.deinit(gpa);

    var has_double_param = false;
    for (params.items, 0..) |raw_param, idx| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (param.len == 0) return;

        const param_name = lastIdentifier(param) orelse return;
        const name_pos = std.mem.lastIndexOf(u8, param, param_name) orelse return;
        const type_part = std.mem.trimRight(u8, param[0..name_pos], " \t");
        if (type_part.len == 0) return;

        const is_double = std.ascii.eqlIgnoreCase(type_part, "Double");
        has_double_param = has_double_param or is_double;

        if (idx != 0) {
            try bridge_params.appendSlice(gpa, ", ");
            try call_args.appendSlice(gpa, ", ");
        }

        if (is_double) {
            try appendFmt(gpa, &bridge_params, "Number {s}", .{param_name});
            try appendFmt(
                gpa,
                &call_args,
                "{s} == null ? null : {s}.doubleValue()",
                .{ param_name, param_name },
            );
        } else {
            try bridge_params.appendSlice(gpa, param);
            try call_args.appendSlice(gpa, param_name);
        }
    }

    if (!has_double_param) return;

    try appendFmt(
        gpa,
        out,
        "  public static {s} {s}({s}) {{\n",
        .{ method.java_return_type, emitted_name, bridge_params.items },
    );
    if (std.ascii.eqlIgnoreCase(method.java_return_type, "void")) {
        try appendFmt(gpa, out, "    {s}({s});\n", .{ emitted_name, call_args.items });
    } else {
        try appendFmt(gpa, out, "    return {s}({s});\n", .{ emitted_name, call_args.items });
    }
    try out.appendSlice(gpa, "  }\n\n");
}

const NestingState = struct {
    paren: i32 = 0,
    bracket: i32 = 0,
    brace: i32 = 0,
    in_single: bool = false,
    in_double: bool = false,
    escaped: bool = false,
};

const LogicalStatement = struct {
    text: []u8,
    line_offset: usize,
};

fn collectLogicalStatements(gpa: std.mem.Allocator, body: []const u8) !std.ArrayList(LogicalStatement) {
    var statements: std.ArrayList(LogicalStatement) = .empty;
    errdefer {
        for (statements.items) |statement| gpa.free(statement.text);
        statements.deinit(gpa);
    }

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var pending_line_offset: usize = 0;
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var line_offset: usize = 0;
    while (lines.next()) |raw_line| {
        const clean = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            clean,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) {
            line_offset += 1;
            continue;
        }

        if (pending.items.len == 0) {
            pending_line_offset = line_offset;
        } else {
            try pending.append(gpa, ' ');
        }
        try pending.appendSlice(gpa, trimmed);

        const current = std.mem.trim(u8, pending.items, " \t");
        if (!shouldFlushLogicalStatement(current)) {
            line_offset += 1;
            continue;
        }

        try appendLogicalStatement(gpa, &statements, current, pending_line_offset);
        pending.clearRetainingCapacity();
        line_offset += 1;
    }

    const tail = std.mem.trim(u8, pending.items, " \t");
    if (tail.len > 0) {
        try appendLogicalStatement(gpa, &statements, tail, pending_line_offset);
    }

    return statements;
}

fn appendLogicalStatement(
    gpa: std.mem.Allocator,
    statements: *std.ArrayList(LogicalStatement),
    raw_statement: []const u8,
    line_offset: usize,
) !void {
    const trimmed = std.mem.trim(u8, raw_statement, " \t");
    if (trimmed.len == 0) return;

    var chunks = try splitTopLevelSemicolonChunks(gpa, trimmed);
    defer {
        for (chunks.items) |chunk| gpa.free(chunk);
        chunks.deinit(gpa);
    }

    for (chunks.items) |chunk| {
        try appendLogicalChunk(gpa, statements, chunk, line_offset);
    }
}

fn appendLogicalChunk(
    gpa: std.mem.Allocator,
    statements: *std.ArrayList(LogicalStatement),
    raw_chunk: []const u8,
    line_offset: usize,
) !void {
    var rest = std.mem.trim(u8, raw_chunk, " \t");
    if (rest.len == 0) return;

    // Keep Apex do-while tails as one statement: `} while (cond);`
    if (isDoWhileTailLine(rest)) {
        try statements.append(gpa, .{
            .text = try gpa.dupe(u8, rest),
            .line_offset = line_offset,
        });
        return;
    }

    while (rest.len > 0 and rest[0] == '}') {
        try statements.append(gpa, .{
            .text = try gpa.dupe(u8, "}"),
            .line_offset = line_offset,
        });
        rest = std.mem.trimLeft(u8, rest[1..], " \t");
        if (rest.len == 0) return;
        if (isDoWhileTailLine(rest)) {
            try statements.append(gpa, .{
                .text = try gpa.dupe(u8, rest),
                .line_offset = line_offset,
            });
            return;
        }
    }

    if (try splitInlineBlockHeader(gpa, rest)) |split| {
        defer {
            gpa.free(split.head);
            gpa.free(split.tail);
        }
        try appendLogicalChunk(gpa, statements, split.head, line_offset);
        try appendLogicalChunk(gpa, statements, split.tail, line_offset);
        return;
    }

    try statements.append(gpa, .{
        .text = try gpa.dupe(u8, rest),
        .line_offset = line_offset,
    });
}

fn splitTopLevelSemicolonChunks(
    gpa: std.mem.Allocator,
    statement: []const u8,
) !std.ArrayList([]u8) {
    var chunks: std.ArrayList([]u8) = .empty;
    errdefer {
        for (chunks.items) |chunk| gpa.free(chunk);
        chunks.deinit(gpa);
    }

    var state = NestingState{};
    var start: usize = 0;
    var i: usize = 0;
    while (i < statement.len) : (i += 1) {
        const ch = statement[i];

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
            if (state.escaped) {
                state.escaped = false;
                continue;
            }
            if (ch == '\\') {
                state.escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < statement.len and statement[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') state.in_single = false;
            continue;
        }

        switch (ch) {
            '"' => state.in_double = true,
            '\'' => {
                state.in_single = true;
                state.escaped = false;
            },
            '(' => state.paren += 1,
            ')' => {
                if (state.paren > 0) state.paren -= 1;
            },
            '[' => state.bracket += 1,
            ']' => {
                if (state.bracket > 0) state.bracket -= 1;
            },
            ';' => {
                if (state.paren == 0 and state.bracket == 0) {
                    const piece = std.mem.trim(u8, statement[start .. i + 1], " \t");
                    if (piece.len > 0) {
                        try chunks.append(gpa, try gpa.dupe(u8, piece));
                    }
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, statement[start..], " \t");
    if (tail.len > 0) {
        try chunks.append(gpa, try gpa.dupe(u8, tail));
    }
    return chunks;
}

const InlineBlockHeaderSplit = struct {
    head: []u8,
    tail: []u8,
};

fn splitInlineBlockHeader(gpa: std.mem.Allocator, statement: []const u8) !?InlineBlockHeaderSplit {
    var state = NestingState{};
    var i: usize = 0;
    while (i < statement.len) : (i += 1) {
        const ch = statement[i];

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
            if (state.escaped) {
                state.escaped = false;
                continue;
            }
            if (ch == '\\') {
                state.escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < statement.len and statement[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') state.in_single = false;
            continue;
        }

        switch (ch) {
            '"' => state.in_double = true,
            '\'' => {
                state.in_single = true;
                state.escaped = false;
            },
            '(' => state.paren += 1,
            ')' => {
                if (state.paren > 0) state.paren -= 1;
            },
            '[' => state.bracket += 1,
            ']' => {
                if (state.bracket > 0) state.bracket -= 1;
            },
            '{' => {
                if (state.paren != 0 or state.bracket != 0) continue;

                const before = std.mem.trim(u8, statement[0..i], " \t");
                if (!shouldSplitInlineBlockHeader(before)) return null;

                const after = std.mem.trim(u8, statement[(i + 1)..], " \t");
                if (after.len == 0) return null;

                return .{
                    .head = try gpa.dupe(u8, std.mem.trim(u8, statement[0 .. i + 1], " \t")),
                    .tail = try gpa.dupe(u8, after),
                };
            },
            else => {},
        }
    }
    return null;
}

fn shouldSplitInlineBlockHeader(before_open_brace: []const u8) bool {
    if (before_open_brace.len == 0) return false;

    const control_headers = [_][]const u8{
        "if", "else", "for", "while", "do", "try", "catch", "finally", "switch", "when",
    };
    for (control_headers) |keyword| {
        if (startsWithWordIgnoreCase(before_open_brace, keyword)) return true;
    }

    if (startsWithIgnoreCase(before_open_brace, "System.runAs") and
        before_open_brace[before_open_brace.len - 1] == ')')
    {
        return true;
    }

    return false;
}

fn inferUnsupportedReason(statement: []const u8) []const u8 {
    if (startsWithWordIgnoreCase(statement, "when")) {
        return "pattern `when` outside switch context is unsupported";
    }
    if (startsWithWordIgnoreCase(statement, "try") or
        startsWithWordIgnoreCase(statement, "catch") or
        startsWithWordIgnoreCase(statement, "finally"))
    {
        return "try/catch/finally is not transpiled yet";
    }
    if (std.mem.indexOf(u8, statement, "->") != null) {
        return "lambda expression is not transpiled yet";
    }
    return "no transpile rule matched";
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
    return false;
}

fn stripApexCommentsFromLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    in_block_comment: *bool,
    out: *std.ArrayList(u8),
) ![]const u8 {
    out.clearRetainingCapacity();

    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < line.len) {
        if (in_block_comment.*) {
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                in_block_comment.* = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        const ch = line[i];
        if (!in_single and !in_double and i + 1 < line.len and ch == '/') {
            const next = line[i + 1];
            if (next == '/') break;
            if (next == '*') {
                in_block_comment.* = true;
                i += 2;
                continue;
            }
        }

        try out.append(allocator, ch);

        if (in_single) {
            if (ch == '\'' and !escaped) {
                in_single = false;
            }
            escaped = ch == '\\' and !escaped;
            i += 1;
            continue;
        }

        if (in_double) {
            if (ch == '"' and !escaped) {
                in_double = false;
            }
            escaped = ch == '\\' and !escaped;
            i += 1;
            continue;
        }

        if (ch == '\'') {
            in_single = true;
            escaped = false;
        } else if (ch == '"') {
            in_double = true;
            escaped = false;
        } else {
            escaped = false;
        }
        i += 1;
    }

    return out.items;
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
            if (state.escaped) {
                state.escaped = false;
                continue;
            }
            if (ch == '\\') {
                state.escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') state.in_single = false;
            continue;
        }

        switch (ch) {
            '"' => state.in_double = true,
            '\'' => {
                state.in_single = true;
                state.escaped = false;
            },
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
    if (try transpileScopedInvocationBlockHeader(gpa, trimmed)) |statement| {
        return statement;
    }

    if (startsWithWordIgnoreCase(trimmed, "return") and indexOfSoqlBracketSelect(trimmed) != null) {
        return null;
    }

    if (!isControlFlowLine(trimmed)) return null;

    if (try transpileInlineControlFlowStatement(
        gpa,
        trimmed,
        active_switch_expr,
        active_switch_mode,
        switch_header_mode,
    )) |statement| {
        return statement;
    }

    if (startsWithWordIgnoreCase(trimmed, "when")) {
        const converted_when = try convertApexExpressionToJava(gpa, trimmed);
        defer gpa.free(converted_when);
        return try normalizeApexWhenLine(gpa, converted_when, active_switch_expr, active_switch_mode);
    }

    if (startsWithWordIgnoreCase(trimmed, "return")) {
        var return_expr = std.mem.trim(u8, trimmed["return".len..], " \t");
        if (return_expr.len > 0 and return_expr[return_expr.len - 1] == ';') {
            return_expr = std.mem.trimRight(u8, return_expr[0 .. return_expr.len - 1], " \t");
        }
        if (return_expr.len == 0) {
            const statement = try gpa.dupe(u8, "return;");
            return statement;
        }
        const converted_expr = try convertApexExpressionToJava(gpa, return_expr);
        defer gpa.free(converted_expr);
        const statement = try std.fmt.allocPrint(gpa, "return {s};", .{converted_expr});
        return statement;
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
    const keyword_fixed = try normalizeLeadingControlKeywordCase(gpa, converted);
    gpa.free(converted);
    converted = keyword_fixed;
    return converted;
}

fn transpileInlineControlFlowStatement(
    gpa: std.mem.Allocator,
    line: []const u8,
    active_switch_expr: ?[]const u8,
    active_switch_mode: SwitchMode,
    switch_header_mode: ?SwitchMode,
) anyerror!?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ';') return null;

    const split_idx = if (startsWithWordIgnoreCase(trimmed, "else if")) blk: {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse break :blk null;
        const close = findMatchingParen(trimmed, open) orelse break :blk null;
        break :blk close + 1;
    } else if (startsWithWordIgnoreCase(trimmed, "if") or
        startsWithWordIgnoreCase(trimmed, "for") or
        startsWithWordIgnoreCase(trimmed, "while"))
    blk: {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse break :blk null;
        const close = findMatchingParen(trimmed, open) orelse break :blk null;
        break :blk close + 1;
    } else if (startsWithWordIgnoreCase(trimmed, "else")) blk: {
        break :blk "else".len;
    } else null;

    if (split_idx == null or split_idx.? >= trimmed.len) return null;
    const head = std.mem.trimRight(u8, trimmed[0..split_idx.?], " \t");
    const tail = std.mem.trim(u8, trimmed[split_idx.?..], " \t");
    if (tail.len == 0 or tail[0] == '{') return null;

    const converted_head_raw = try convertApexExpressionToJava(gpa, head);
    defer gpa.free(converted_head_raw);
    var converted_head = try normalizeLeadingControlKeywordCase(gpa, converted_head_raw);
    defer gpa.free(converted_head);
    if (startsWithWordIgnoreCase(converted_head, "for")) {
        const for_fixed = try normalizeForHeaderTypes(gpa, converted_head);
        gpa.free(converted_head);
        converted_head = for_fixed;
    }

    const converted_tail = try transpileExecutableLineWithContext(
        gpa,
        tail,
        active_switch_expr,
        active_switch_mode,
        switch_header_mode,
    ) orelse return null;
    defer gpa.free(converted_tail);

    return try std.fmt.allocPrint(gpa, "{s} {{ {s} }}", .{ converted_head, converted_tail });
}

fn normalizeLeadingControlKeywordCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return gpa.dupe(u8, text);

    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "Else If", .to = "else if" },
        .{ .from = "else If", .to = "else if" },
        .{ .from = "If", .to = "if" },
        .{ .from = "For", .to = "for" },
        .{ .from = "While", .to = "while" },
        .{ .from = "Try", .to = "try" },
        .{ .from = "Catch", .to = "catch" },
        .{ .from = "Else", .to = "else" },
    };
    for (patterns) |pattern| {
        if (!startsWithWordIgnoreCase(trimmed, pattern.from)) continue;
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ pattern.to, trimmed[pattern.from.len..] });
    }
    return gpa.dupe(u8, trimmed);
}

fn transpileScopedInvocationBlockHeader(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '{') return null;

    const head = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    if (head.len == 0) return null;
    if (!startsWithIgnoreCase(head, "System.runAs")) return null;
    if (head[head.len - 1] != ')') return null;

    // Extract user argument from System.runAs(userArg)
    const open_paren = std.mem.indexOfScalar(u8, head, '(') orelse return null;
    const close_paren = std.mem.lastIndexOfScalar(u8, head, ')') orelse return null;
    if (close_paren <= open_paren) return null;
    const user_arg_raw = std.mem.trim(u8, head[(open_paren + 1)..close_paren], " \t");
    const user_arg = try convertApexExpressionToJava(gpa, user_arg_raw);
    defer gpa.free(user_arg);
    return try std.fmt.allocPrint(gpa, "Test.beginRunAs({s}); try {{ // RUNAS_BLOCK", .{user_arg});
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

    const query_segment_raw = std.mem.trim(u8, trimmed[(select_start + 1)..close_bracket], " \t");
    if (!startsWithIgnoreCase(query_segment_raw, "SELECT")) return null;
    const query_segment = try normalizeSoqlQueryForEmulation(gpa, query_segment_raw);
    defer gpa.free(query_segment);

    const java_query = try quoteJavaStringLiteral(gpa, query_segment);
    defer gpa.free(java_query);
    const query_call = try buildDatabaseQueryCall(gpa, query_segment, java_query);
    defer gpa.free(query_call);
    const count_query_call = try buildDatabaseCountQueryCall(gpa, query_segment, java_query);
    defer gpa.free(count_query_call);

    const prefix = std.mem.trim(u8, trimmed[0..select_start], " \t");
    const suffix = std.mem.trim(u8, trimmed[(close_bracket + 1)..], " \t");
    if (suffix.len != 0) return null;

    if (prefix.len == 0) {
        return try std.fmt.allocPrint(gpa, "{s};", .{query_call});
    }

    if (startsWithWordIgnoreCase(prefix, "return")) {
        const return_tail = std.mem.trim(u8, prefix["return".len..], " \t");
        if (return_tail.len == 0) {
            if (isSoqlCountQuery(query_segment)) {
                return try std.fmt.allocPrint(gpa, "return {s};", .{count_query_call});
            }
            if (isSoqlLikelySingleRow(query_segment)) {
                return try std.fmt.allocPrint(
                    gpa,
                    "return ApexCollections.firstOrThrow({s});",
                    .{query_call},
                );
            }
            return try std.fmt.allocPrint(gpa, "return {s};", .{query_call});
        }
    }

    if (prefix[prefix.len - 1] != '=') return null;
    const left = std.mem.trim(u8, prefix[0 .. prefix.len - 1], " \t");
    if (isSimpleIdentifier(left)) {
        if (isSoqlCountQuery(query_segment)) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} = {s};",
                .{ left, count_query_call },
            );
        }
        if (!looksLikeCollectionVariableName(left) and isSoqlLikelySingleRow(query_segment)) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} = ApexCollections.firstOrThrow({s});",
                .{ left, query_call },
            );
        }
        return try std.fmt.allocPrint(
            gpa,
            "{s} = {s};",
            .{ left, query_call },
        );
    }

    if (parseIndexedLvalue(left)) |lvalue| {
        const converted_base = try convertApexExpressionToJava(gpa, lvalue.base_expr);
        defer gpa.free(converted_base);
        const converted_index = try convertApexExpressionToJava(gpa, lvalue.index_expr);
        defer gpa.free(converted_index);
        if (isSoqlCountQuery(query_segment)) {
            return try std.fmt.allocPrint(
                gpa,
                "{s}.set({s}, {s});",
                .{ converted_base, converted_index, count_query_call },
            );
        }
        if (isSoqlLikelySingleRow(query_segment)) {
            return try std.fmt.allocPrint(
                gpa,
                "{s}.set({s}, ApexCollections.firstOrThrow({s}));",
                .{ converted_base, converted_index, query_call },
            );
        }
        return try std.fmt.allocPrint(
            gpa,
            "{s}.set({s}, {s});",
            .{ converted_base, converted_index, query_call },
        );
    }

    if (std.mem.indexOfScalar(u8, left, '.')) |_| {
        const converted_left = try convertApexExpressionToJava(gpa, left);
        defer gpa.free(converted_left);
        if (isSoqlCountQuery(query_segment)) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} = {s};",
                .{ converted_left, count_query_call },
            );
        }
        if (isSoqlLikelySingleRow(query_segment)) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} = ApexCollections.firstOrThrow({s});",
                .{ converted_left, query_call },
            );
        }
        return try std.fmt.allocPrint(
            gpa,
            "{s} = {s};",
            .{ converted_left, query_call },
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
                "{s} {s} = {s};",
                .{ decl.java_type, decl.variable_name, query_call },
            );
        }
        if (decl.kind == .map) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} {s} = ApexCollections.mapById({s});",
                .{ decl.java_type, decl.variable_name, query_call },
            );
        }
    }

    if (try parseTypedVariableDeclaration(gpa, left, false)) |decl| {
        defer {
            gpa.free(decl.declaration_head);
            gpa.free(decl.variable_name);
            gpa.free(decl.java_type);
        }
        const decl_is_collection = isLikelyJavaCollectionType(decl.java_type);
        if (isSoqlCountQuery(query_segment)) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} = {s};",
                .{ decl.declaration_head, count_query_call },
            );
        }
        if (!decl_is_collection) {
            return try std.fmt.allocPrint(
                gpa,
                "{s} = ApexCollections.firstOrThrow({s});",
                .{ decl.declaration_head, query_call },
            );
        }
        return try std.fmt.allocPrint(
            gpa,
            "{s} = {s};",
            .{ decl.declaration_head, query_call },
        );
    }

    const var_name = lastIdentifier(left) orelse return null;
    if (var_name.len == 0) return null;
    return try std.fmt.allocPrint(gpa, "List<ApexSObject> {s} = {s};", .{ var_name, query_call });
}

fn isSoqlLikelySingleRow(query_segment: []const u8) bool {
    if (indexOfWordIgnoreCase(query_segment, "LIMIT")) |limit_pos| {
        const after_limit = std.mem.trimLeft(u8, query_segment[(limit_pos + "LIMIT".len)..], " \t");
        if (after_limit.len > 0 and after_limit[0] == '1') {
            if (after_limit.len == 1 or !std.ascii.isDigit(after_limit[1])) return true;
        }
    }

    if (indexOfWordIgnoreCase(query_segment, "WHERE")) |where_pos| {
        const where_clause = std.mem.trimLeft(u8, query_segment[(where_pos + "WHERE".len)..], " \t");
        if (indexOfWordIgnoreCase(where_clause, "Id")) |id_pos| {
            const before_id = if (id_pos == 0) "" else where_clause[0..id_pos];
            if (indexOfWordIgnoreCase(before_id, "AND") == null and indexOfWordIgnoreCase(before_id, "OR") == null) {
                const after_id = std.mem.trimLeft(u8, where_clause[(id_pos + "Id".len)..], " \t");
                if (after_id.len > 0 and after_id[0] == '=') return true;
            }
        }
    }
    return false;
}

fn isSoqlCountQuery(query_segment: []const u8) bool {
    return startsWithIgnoreCase(query_segment, "SELECT COUNT(");
}

fn isLikelyJavaCollectionType(java_type: []const u8) bool {
    const trimmed = std.mem.trim(u8, java_type, " \t");
    if (trimmed.len == 0) return false;
    return startsWithIgnoreCase(trimmed, "List<") or
        startsWithIgnoreCase(trimmed, "Set<") or
        startsWithIgnoreCase(trimmed, "Map<");
}

fn normalizeSoqlQueryForEmulation(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (tokens.next()) |token| {
        try parts.append(gpa, token);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < parts.items.len) : (i += 1) {
        const token = parts.items[i];
        if (std.ascii.eqlIgnoreCase(token, "WITH") and i + 1 < parts.items.len) {
            const next = parts.items[i + 1];
            if (std.ascii.eqlIgnoreCase(next, "SYSTEM_MODE")) {
                i += 1;
                continue;
            }
            // Preserve WITH USER_MODE and WITH SECURITY_ENFORCED for runtime checks
        }
        if (out.items.len != 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, token);
    }

    if (out.items.len == 0) return gpa.dupe(u8, query);
    return out.toOwnedSlice(gpa);
}

fn buildDatabaseQueryCall(
    gpa: std.mem.Allocator,
    query_segment: []const u8,
    java_query_literal: []const u8,
) ![]u8 {
    // COUNT() queries (without GROUP BY) return Integer, not List.
    if (isSoqlCountQuery(query_segment) and !containsIgnoreCaseSubstring(query_segment, "GROUP BY")) {
        return buildDatabaseCountQueryCall(gpa, query_segment, java_query_literal);
    }
    var bind_names = try collectSoqlBindNames(gpa, query_segment);
    defer bind_names.deinit(gpa);
    if (bind_names.items.len == 0) {
        return std.fmt.allocPrint(gpa, "Database.query({s})", .{java_query_literal});
    }

    var bind_map_args: std.ArrayList(u8) = .empty;
    defer bind_map_args.deinit(gpa);
    for (bind_names.items, 0..) |bind_name, idx| {
        const bind_expr = try convertBindReferenceToJava(gpa, bind_name);
        defer gpa.free(bind_expr);
        if (idx != 0) try bind_map_args.appendSlice(gpa, ", ");
        try appendFmt(gpa, &bind_map_args, "\"{s}\", {s}", .{ bind_name, bind_expr });
    }

    return std.fmt.allocPrint(
        gpa,
        "Database.queryWithBinds({s}, ApexCollections.bindMap({s}))",
        .{ java_query_literal, bind_map_args.items },
    );
}

fn buildDatabaseCountQueryCall(
    gpa: std.mem.Allocator,
    query_segment: []const u8,
    java_query_literal: []const u8,
) ![]u8 {
    var bind_names = try collectSoqlBindNames(gpa, query_segment);
    defer bind_names.deinit(gpa);
    if (bind_names.items.len == 0) {
        return std.fmt.allocPrint(gpa, "Database.countQuery({s})", .{java_query_literal});
    }

    var bind_map_args: std.ArrayList(u8) = .empty;
    defer bind_map_args.deinit(gpa);
    for (bind_names.items, 0..) |bind_name, idx| {
        const bind_expr = try convertBindReferenceToJava(gpa, bind_name);
        defer gpa.free(bind_expr);
        if (idx != 0) try bind_map_args.appendSlice(gpa, ", ");
        try appendFmt(gpa, &bind_map_args, "\"{s}\", {s}", .{ bind_name, bind_expr });
    }

    return std.fmt.allocPrint(
        gpa,
        "Database.countQueryWithBinds({s}, ApexCollections.bindMap({s}))",
        .{ java_query_literal, bind_map_args.items },
    );
}

fn collectSoqlBindNames(gpa: std.mem.Allocator, query_segment: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var in_single = false;
    var in_double = false;
    var escaped = false;
    var i: usize = 0;
    while (i < query_segment.len) : (i += 1) {
        const ch = query_segment[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < query_segment.len and query_segment[i + 1] == '\'') {
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
        if (in_single or in_double or ch != ':') continue;

        const start = i + 1;
        var end = start;
        while (end < query_segment.len and isSoqlBindNameChar(query_segment[end])) : (end += 1) {}
        if (end == start) continue;

        const bind_name = query_segment[start..end];
        if (!isSimpleBindReference(bind_name)) continue;

        var seen = false;
        for (out.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, bind_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try out.append(gpa, bind_name);
        }
        i = end - 1;
    }
    return out;
}

fn isSimpleBindReference(bind_name: []const u8) bool {
    if (bind_name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(bind_name, "new")) return false;
    if (!isSimpleIdentifierOrPath(bind_name)) return false;
    return true;
}

fn isSimpleIdentifierOrPath(text: []const u8) bool {
    if (text.len == 0) return false;
    var parts = std.mem.tokenizeScalar(u8, text, '.');
    var seen_part = false;
    while (parts.next()) |part| {
        if (!isSimpleIdentifier(part)) return false;
        seen_part = true;
    }
    return seen_part;
}

fn isSoqlBindNameChar(ch: u8) bool {
    return isIdentifierChar(ch) or std.ascii.isDigit(ch) or ch == '.';
}

fn convertBindReferenceToJava(gpa: std.mem.Allocator, bind_name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, bind_name, " \t");
    if (!isSimpleIdentifierOrPath(trimmed)) return gpa.dupe(u8, trimmed);
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
        var parts = std.mem.tokenizeScalar(u8, trimmed, '.');
        const root = parts.next() orelse return gpa.dupe(u8, trimmed);
        if (isLikelyTypeReferenceIdentifier(root)) {
            var static_out: std.ArrayList(u8) = .empty;
            errdefer static_out.deinit(gpa);
            try static_out.appendSlice(gpa, root);

            var idx: usize = 0;
            var last_part: []const u8 = "";
            while (parts.next()) |part| {
                idx += 1;
                last_part = part;
                try appendFmt(gpa, &static_out, ".{s}", .{part});
            }
            if (idx > 0 and startsWithIgnoreCase(last_part, "get") and last_part.len > 3 and std.ascii.isUpper(last_part[3])) {
                try static_out.appendSlice(gpa, "()");
            }
            if (idx > 0 and std.ascii.eqlIgnoreCase(last_part, "trim")) {
                try static_out.appendSlice(gpa, "()");
            }
            return static_out.toOwnedSlice(gpa);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, root);

        var last_part: []const u8 = root;
        var saw_path = false;
        while (parts.next()) |field| {
            saw_path = true;
            last_part = field;
            try appendFmt(gpa, &out, ".{s}", .{field});
        }
        if (saw_path and isLikelyBindMethodReferenceName(last_part)) {
            try out.appendSlice(gpa, "()");
        }
        return out.toOwnedSlice(gpa);
    }
    return gpa.dupe(u8, trimmed);
}

fn isLikelyBindMethodReferenceName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(name, "trim")) return true;
    if (startsWithIgnoreCase(name, "get") and name.len > 3 and std.ascii.isUpper(name[3])) return true;
    return false;
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
        const raw_payload = std.mem.trimLeft(u8, trimmed[keyword.len..], " \t");
        if (raw_payload.len == 0) return null;
        const payload_mode = parseApexDmlAccessMode(raw_payload);
        const payload = payload_mode.payload;
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
                return try buildDatabaseDmlCallWithMode(
                    gpa,
                    "merge",
                    payload_mode.mode,
                    "{s}, {s}",
                    .{ master, dup1 },
                );
            }

            const dup2 = try convertApexExpressionToJava(gpa, args.items[2]);
            defer gpa.free(dup2);
            return try buildDatabaseDmlCallWithMode(
                gpa,
                "merge",
                payload_mode.mode,
                "{s}, java.util.List.of({s}, {s})",
                .{ master, dup1, dup2 },
            );
        }

        if (std.ascii.eqlIgnoreCase(keyword, "upsert")) {
            if (splitTrailingIdentifierAtTopLevel(payload)) |split| {
                const converted = try convertApexExpressionToJava(gpa, split.head);
                defer gpa.free(converted);
                const rendered = try buildDatabaseDmlCallWithMode(
                    gpa,
                    "upsert",
                    payload_mode.mode,
                    "{s}",
                    .{converted},
                );
                errdefer gpa.free(rendered);
                const with_ext = try std.fmt.allocPrint(
                    gpa,
                    "{s} // external id field: {s}",
                    .{ rendered, split.tail },
                );
                gpa.free(rendered);
                return with_ext;
            }
        }

        const converted = try convertApexExpressionToJava(gpa, payload);
        defer gpa.free(converted);
        return try buildDatabaseDmlCallWithMode(
            gpa,
            keyword,
            payload_mode.mode,
            "{s}",
            .{converted},
        );
    }
    return null;
}

const ApexDmlAccessMode = enum {
    none,
    user,
    system,
};

const ParsedDmlPayload = struct {
    payload: []const u8,
    mode: ApexDmlAccessMode,
};

fn parseApexDmlAccessMode(raw_payload: []const u8) ParsedDmlPayload {
    var payload = std.mem.trim(u8, raw_payload, " \t");
    var mode: ApexDmlAccessMode = .none;

    if (startsWithWordIgnoreCase(payload, "as")) {
        var rest = std.mem.trimLeft(u8, payload["as".len..], " \t");
        if (startsWithWordIgnoreCase(rest, "user")) {
            mode = .user;
            rest = std.mem.trimLeft(u8, rest["user".len..], " \t");
            payload = rest;
        } else if (startsWithWordIgnoreCase(rest, "system")) {
            mode = .system;
            rest = std.mem.trimLeft(u8, rest["system".len..], " \t");
            payload = rest;
        }
    }

    return .{
        .payload = payload,
        .mode = mode,
    };
}

fn buildDatabaseDmlCallWithMode(
    gpa: std.mem.Allocator,
    keyword: []const u8,
    mode: ApexDmlAccessMode,
    comptime args_fmt: []const u8,
    args: anytype,
) ![]u8 {
    const rendered_args = try std.fmt.allocPrint(gpa, args_fmt, args);
    defer gpa.free(rendered_args);

    const mode_suffix = switch (mode) {
        .none => "",
        .user => " // Apex DML mode: user",
        .system => " // Apex DML mode: system",
    };
    return std.fmt.allocPrint(
        gpa,
        "Database.{s}({s});{s}",
        .{ keyword, rendered_args, mode_suffix },
    );
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

    if (startsWithWordIgnoreCase(trimmed, "return")) {
        const expr = std.mem.trim(u8, trimmed["return".len..], " \t");
        if (expr.len == 0) {
            const statement = try gpa.dupe(u8, "return;");
            return statement;
        }
        const converted = try convertApexExpressionToJava(gpa, expr);
        defer gpa.free(converted);
        const statement = try std.fmt.allocPrint(gpa, "return {s};", .{converted});
        return statement;
    }

    if (try transpileTypedDeclarationLine(gpa, trimmed, false)) |declaration| {
        return declaration;
    }

    if (try transpileSafeNavigationInvocationStatement(gpa, trimmed)) |statement| {
        return statement;
    }

    if (findTopLevelPlusAssignmentOperator(trimmed)) |plus_pos| {
        const lhs_base = std.mem.trim(u8, trimmed[0..plus_pos], " \t");
        const rhs = std.mem.trim(u8, trimmed[(plus_pos + 2)..], " \t");
        if (lhs_base.len > 0 and rhs.len > 0) {
            if (parseSObjectFieldLvalue(lhs_base)) |lvalue| {
                const converted_base = try convertApexExpressionToJava(gpa, lvalue.base_expr);
                defer gpa.free(converted_base);
                const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
                defer gpa.free(converted_rhs);
                const normalized_rhs = try maybeWrapSingleQueryAssignment(gpa, lhs_base, converted_rhs);
                defer gpa.free(normalized_rhs);
                const coerced_rhs = try coerceLiteralForAssignmentContext(gpa, lhs_base, normalized_rhs);
                defer gpa.free(coerced_rhs);
                return try std.fmt.allocPrint(
                    gpa,
                    "{s}.set(\"{s}\", String.valueOf({s}.getAs(\"{s}\")) + ({s}));",
                    .{ converted_base, lvalue.field_name, converted_base, lvalue.field_name, coerced_rhs },
                );
            }
        }
    }

    if (findTopLevelAssignmentOperator(trimmed)) |eq_pos| {
        const lhs = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const rhs = std.mem.trim(u8, trimmed[(eq_pos + 1)..], " \t");
        if (lhs.len != 0) {
            const lhs_tail = lhs[lhs.len - 1];
            if (lhs_tail == '+') {
                if (rhs.len == 0) return null;
                const lhs_base = std.mem.trimRight(u8, lhs[0 .. lhs.len - 1], " \t");
                if (lhs_base.len > 0) {
                    if (parseSObjectFieldLvalue(lhs_base)) |lvalue| {
                        const converted_base = try convertApexExpressionToJava(gpa, lvalue.base_expr);
                        defer gpa.free(converted_base);
                        const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
                        defer gpa.free(converted_rhs);
                        const normalized_rhs = try maybeWrapSingleQueryAssignment(gpa, lhs_base, converted_rhs);
                        defer gpa.free(normalized_rhs);
                        const coerced_rhs = try coerceLiteralForAssignmentContext(gpa, lhs_base, normalized_rhs);
                        defer gpa.free(coerced_rhs);
                        return try std.fmt.allocPrint(
                            gpa,
                            "{s}.set(\"{s}\", String.valueOf({s}.getAs(\"{s}\")) + ({s}));",
                            .{ converted_base, lvalue.field_name, converted_base, lvalue.field_name, coerced_rhs },
                        );
                    }
                }
            }
            if (lhs_tail != '+' and lhs_tail != '-' and lhs_tail != '*' and lhs_tail != '/' and lhs_tail != '%' and lhs_tail != '&' and lhs_tail != '|' and lhs_tail != '^') {
                if (rhs.len == 0) return null;
                const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
                defer gpa.free(converted_rhs);
                const normalized_rhs = try maybeWrapSingleQueryAssignment(gpa, lhs, converted_rhs);
                defer gpa.free(normalized_rhs);
                const coerced_rhs = try coerceLiteralForAssignmentContext(gpa, lhs, normalized_rhs);
                defer gpa.free(coerced_rhs);
                if (parseIndexedLvalue(lhs)) |lvalue| {
                    const converted_base = try convertApexExpressionToJava(gpa, lvalue.base_expr);
                    defer gpa.free(converted_base);
                    const converted_index = try convertApexExpressionToJava(gpa, lvalue.index_expr);
                    defer gpa.free(converted_index);
                    const wrapped_rhs = try maybeWrapSingleQueryResult(gpa, coerced_rhs);
                    defer gpa.free(wrapped_rhs);
                    return try std.fmt.allocPrint(
                        gpa,
                        "{s}.set({s}, {s});",
                        .{ converted_base, converted_index, wrapped_rhs },
                    );
                }
                if (parseSObjectFieldLvalue(lhs)) |lvalue| {
                    const converted_base = try convertApexExpressionToJava(gpa, lvalue.base_expr);
                    defer gpa.free(converted_base);
                    return try std.fmt.allocPrint(
                        gpa,
                        "{s}.set(\"{s}\", {s});",
                        .{ converted_base, lvalue.field_name, coerced_rhs },
                    );
                }
                if (parseJavaKeywordMemberLvalue(lhs)) |lvalue| {
                    const converted_base = try convertApexExpressionToJava(gpa, lvalue.base_expr);
                    defer gpa.free(converted_base);
                    return try std.fmt.allocPrint(
                        gpa,
                        "ApexSwitch.set({s}, \"{s}\", {s});",
                        .{ converted_base, lvalue.field_name, coerced_rhs },
                    );
                }
                // Apply property normalization to LHS (e.g., .requestUri → .requestURI)
                const converted_lhs = try rewriteTriggerContextPropertyAccess(gpa, lhs);
                defer gpa.free(converted_lhs);
                return try std.fmt.allocPrint(gpa, "{s} = {s};", .{ converted_lhs, coerced_rhs });
            }
        }
    }

    const converted = try convertApexExpressionToJava(gpa, trimmed);
    defer gpa.free(converted);
    return try std.fmt.allocPrint(gpa, "{s};", .{converted});
}

fn transpileSafeNavigationInvocationStatement(gpa: std.mem.Allocator, statement_no_semicolon: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, statement_no_semicolon, " \t");
    if (trimmed.len == 0) return null;

    const safe_nav_pos = findTopLevelSafeNavigationOperator(trimmed) orelse return null;
    const base_raw = std.mem.trim(u8, trimmed[0..safe_nav_pos], " \t");
    const tail = std.mem.trimLeft(u8, trimmed[(safe_nav_pos + 2)..], " \t");
    if (base_raw.len == 0 or tail.len == 0) return null;

    const open_paren = std.mem.indexOfScalar(u8, tail, '(') orelse return null;
    const close_paren = findMatchingParen(tail, open_paren) orelse return null;
    if (close_paren + 1 != tail.len) {
        const trailing = std.mem.trim(u8, tail[(close_paren + 1)..], " \t");
        if (trailing.len != 0) return null;
    }

    const call_head = std.mem.trim(u8, tail[0..open_paren], " \t");
    if (call_head.len == 0 or lastIdentifier(call_head) == null) return null;

    const base_converted = try convertApexExpressionToJava(gpa, base_raw);
    defer gpa.free(base_converted);

    const call_source = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ base_raw, tail });
    defer gpa.free(call_source);
    const call_converted = try convertApexExpressionToJava(gpa, call_source);
    defer gpa.free(call_converted);

    return try std.fmt.allocPrint(
        gpa,
        "if (({s}) != null) {{ {s}; }}",
        .{ base_converted, call_converted },
    );
}

fn findTopLevelPlusAssignmentOperator(text: []const u8) ?usize {
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
            '+' => {
                if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0 or angle_depth != 0) continue;
                if (text[i + 1] == '=') return i;
            },
            else => {},
        }
    }
    return null;
}

fn maybeWrapSingleQueryAssignment(
    gpa: std.mem.Allocator,
    lhs: []const u8,
    rhs: []const u8,
) ![]u8 {
    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    if (!startsWithIgnoreCase(trimmed_rhs, "Database.query(") and
        !startsWithIgnoreCase(trimmed_rhs, "Database.queryWithBinds("))
    {
        return gpa.dupe(u8, rhs);
    }

    const lhs_name = std.mem.trim(u8, lhs, " \t");
    if (!isSimpleIdentifier(lhs_name)) return gpa.dupe(u8, rhs);
    if (looksLikeCollectionVariableName(lhs_name)) return gpa.dupe(u8, rhs);

    return std.fmt.allocPrint(gpa, "ApexCollections.firstOrNull({s})", .{trimmed_rhs});
}

fn maybeUnwrapCollectionQueryResult(
    gpa: std.mem.Allocator,
    declared_java_type: []const u8,
    rhs: []const u8,
) ![]u8 {
    if (!isLikelyJavaCollectionType(declared_java_type)) {
        return gpa.dupe(u8, rhs);
    }

    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    const wrappers = [_][]const u8{
        "ApexCollections.firstOrThrow(",
        "ApexCollections.firstOrNull(",
    };

    for (wrappers) |wrapper| {
        if (!startsWithIgnoreCase(trimmed_rhs, wrapper)) continue;
        const open_paren = wrapper.len - 1;
        const close_paren = findMatchingParen(trimmed_rhs, open_paren) orelse return gpa.dupe(u8, rhs);
        if (close_paren != trimmed_rhs.len - 1) return gpa.dupe(u8, rhs);
        const inner = std.mem.trim(u8, trimmed_rhs[(open_paren + 1)..close_paren], " \t");
        if (startsWithIgnoreCase(inner, "Database.query(") or
            startsWithIgnoreCase(inner, "Database.queryWithBinds("))
        {
            return gpa.dupe(u8, inner);
        }
        return gpa.dupe(u8, rhs);
    }

    return gpa.dupe(u8, rhs);
}

fn maybeWrapSingleQueryResult(gpa: std.mem.Allocator, rhs: []const u8) ![]u8 {
    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    if (!startsWithIgnoreCase(trimmed_rhs, "Database.query(") and
        !startsWithIgnoreCase(trimmed_rhs, "Database.queryWithBinds("))
    {
        return gpa.dupe(u8, rhs);
    }
    return std.fmt.allocPrint(gpa, "ApexCollections.firstOrNull({s})", .{trimmed_rhs});
}

fn looksLikeCollectionVariableName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0) return false;
    if (endsWithIgnoreCase(trimmed, "List")) return true;
    if (endsWithIgnoreCase(trimmed, "Map")) return true;
    if (endsWithIgnoreCase(trimmed, "Set")) return true;
    return std.ascii.toLower(trimmed[trimmed.len - 1]) == 's';
}

fn coerceLiteralForAssignmentContext(
    gpa: std.mem.Allocator,
    lhs: []const u8,
    rhs: []const u8,
) ![]u8 {
    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    if (!isIntegerLiteral(trimmed_rhs)) return gpa.dupe(u8, rhs);

    const target_name = blk: {
        if (findLastTopLevelDot(lhs)) |dot| {
            const member = std.mem.trim(u8, lhs[(dot + 1)..], " \t");
            if (isSimpleIdentifier(member)) break :blk member;
        }
        const raw = std.mem.trim(u8, lhs, " \t");
        if (isSimpleIdentifier(raw)) break :blk raw;
        break :blk "";
    };
    if (target_name.len == 0) return gpa.dupe(u8, rhs);
    if (!containsIgnoreCaseSubstring(target_name, "price")) return gpa.dupe(u8, rhs);

    return std.fmt.allocPrint(gpa, "{s}.0", .{trimmed_rhs});
}

fn containsIgnoreCaseSubstring(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
            return true;
        }
    }
    return false;
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

    if (std.mem.endsWith(u8, trimmed, "[]")) {
        const base_raw = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 2], " \t");
        if (base_raw.len == 0) return gpa.dupe(u8, "List<Object>");
        const base_type = try convertApexType(gpa, base_raw);
        defer gpa.free(base_type);
        if (std.ascii.eqlIgnoreCase(base_type, "Object")) {
            return gpa.dupe(u8, "List<ApexSObject>");
        }
        return std.fmt.allocPrint(gpa, "List<{s}>", .{base_type});
    }

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
    if (std.mem.indexOfScalar(u8, raw, '.')) |_| {
        if (normalizeQualifiedTypeName(raw)) |normalized| return normalized;
        return raw;
    }

    if (std.ascii.eqlIgnoreCase(raw, "void")) return "void";
    if (std.ascii.eqlIgnoreCase(raw, "Id")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "Decimal")) return "Double";
    if (std.ascii.eqlIgnoreCase(raw, "Date")) return "Date";
    if (std.ascii.eqlIgnoreCase(raw, "Datetime")) return "DateTime";
    if (std.ascii.eqlIgnoreCase(raw, "Time")) return "Time";
    if (std.ascii.eqlIgnoreCase(raw, "Blob")) return "byte[]";
    if (std.ascii.eqlIgnoreCase(raw, "SObject")) return "ApexSObject";
    if (isLikelyCustomSObjectTypeName(raw)) return "ApexSObject";
    if (isLikelySObjectTypeForInstanceof(raw)) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "SObjectType")) return "Schema.SObjectType";
    if (std.ascii.eqlIgnoreCase(raw, "SObjectField")) return "Schema.SObjectField";
    if (std.ascii.eqlIgnoreCase(raw, "SoapType")) return "Schema.SoapType";
    if (std.ascii.eqlIgnoreCase(raw, "FieldSetMember")) return "Schema.FieldSetMember";
    if (std.ascii.eqlIgnoreCase(raw, "TriggerOperation")) return "System.TriggerOperation";
    if (std.ascii.eqlIgnoreCase(raw, "Finalizer")) return "apexemu.runtime.System.Finalizer";
    if (std.ascii.eqlIgnoreCase(raw, "FinalizerContext")) return "System.FinalizerContext";
    if (std.ascii.eqlIgnoreCase(raw, "ParentJobResult")) return "System.FinalizerContext.ParentJobResult";
    if (std.ascii.eqlIgnoreCase(raw, "InstallContext")) return "apexemu.runtime.System.InstallContext";
    if (std.ascii.eqlIgnoreCase(raw, "InstallHandler")) return "apexemu.runtime.System.InstallHandler";
    if (std.ascii.eqlIgnoreCase(raw, "UninstallHandler")) return "apexemu.runtime.System.UninstallHandler";
    if (std.ascii.eqlIgnoreCase(raw, "UninstallContext")) return "apexemu.runtime.System.UninstallContext";
    if (std.ascii.eqlIgnoreCase(raw, "SObjectAccessDecision")) return "apexemu.runtime.System.SObjectAccessDecision";
    if (std.ascii.eqlIgnoreCase(raw, "AccessType")) return "apexemu.runtime.System.AccessType";
    if (std.ascii.eqlIgnoreCase(raw, "AccessLevel")) return "apexemu.runtime.System.AccessLevel";
    if (std.ascii.eqlIgnoreCase(raw, "StubProvider")) return "apexemu.runtime.System.StubProvider";
    if (std.ascii.eqlIgnoreCase(raw, "DisplayType")) return "Schema.DisplayType";
    if (std.ascii.eqlIgnoreCase(raw, "Displaytype")) return "Schema.DisplayType";
    if (std.ascii.eqlIgnoreCase(raw, "RecordTypeInfo")) return "RecordTypeInfo";
    if (std.ascii.eqlIgnoreCase(raw, "Recordtypeinfo")) return "RecordTypeInfo";
    if (std.ascii.eqlIgnoreCase(raw, "BDI_FIeldMapping")) return "BDI_FieldMapping";
    if (std.ascii.eqlIgnoreCase(raw, "version")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "RecordType")) return "RecordType";
    if (std.ascii.eqlIgnoreCase(raw, "CampaignMemberStatus")) return "CampaignMemberStatus";
    if (std.ascii.eqlIgnoreCase(raw, "CustomNotificationType")) return "CustomNotificationType";
    if (std.ascii.eqlIgnoreCase(raw, "SearchBuilder")) return "Search.SearchBuilder";
    if (std.ascii.eqlIgnoreCase(raw, "QueueableContext")) return "apexemu.runtime.System.QueueableContext";
    if (std.ascii.eqlIgnoreCase(raw, "SchedulableContext")) return "apexemu.runtime.System.SchedulableContext";
    if (std.ascii.eqlIgnoreCase(raw, "BatchableContext")) return "Database.BatchableContext";
    if (std.ascii.eqlIgnoreCase(raw, "Savepoint")) return "Database.Savepoint";
    if (std.ascii.eqlIgnoreCase(raw, "DmlException")) return "DmlException";
    if (std.ascii.eqlIgnoreCase(raw, "DMLException")) return "DmlException";
    if (std.ascii.eqlIgnoreCase(raw, "NoAccessException")) return "apexemu.runtime.System.NoAccessException";
    if (std.ascii.eqlIgnoreCase(raw, "SecurityException")) return "apexemu.runtime.System.SecurityException";
    if (std.ascii.eqlIgnoreCase(raw, "DescribeFieldResult")) return "Schema.DescribeFieldResult";
    if (std.ascii.eqlIgnoreCase(raw, "DescribeSObjectResult")) return "Schema.DescribeSObjectResult";
    if (std.ascii.eqlIgnoreCase(raw, "InboundEmail")) return "Messaging.InboundEmail";
    if (std.ascii.eqlIgnoreCase(raw, "InboundEnvelope")) return "Messaging.InboundEnvelope";
    if (std.ascii.eqlIgnoreCase(raw, "InboundEmailResult")) return "Messaging.InboundEmailResult";
    if (std.ascii.eqlIgnoreCase(raw, "ApexClass")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "Organization")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "ObjectPermissions")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "PermissionSetGroup")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "FieldDefinition")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "FieldPermissions")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "PlatformCachePartition")) return "ApexSObject";
    if (std.ascii.eqlIgnoreCase(raw, "Quiddity")) return "apexemu.runtime.System.Quiddity";
    if (std.ascii.eqlIgnoreCase(raw, "Type")) return "apexemu.runtime.System.Type";
    if (std.ascii.eqlIgnoreCase(raw, "HTTPRequest")) return "HttpRequest";
    if (std.ascii.eqlIgnoreCase(raw, "HTTPResponse")) return "HttpResponse";
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
    if (std.ascii.eqlIgnoreCase(raw, "Exception")) return "apexemu.runtime.System.Exception";
    if (std.ascii.eqlIgnoreCase(raw, "RuntimeException")) return "RuntimeException";
    if (std.ascii.eqlIgnoreCase(raw, "Throwable")) return "Throwable";
    if (std.ascii.eqlIgnoreCase(raw, "Database")) return "Database";
    if (std.ascii.eqlIgnoreCase(raw, "Schema")) return "Schema";
    if (std.ascii.eqlIgnoreCase(raw, "SystemAssert")) return "SystemAssert";
    if (std.ascii.eqlIgnoreCase(raw, "Assert")) return "ApexAssert";
    if (std.ascii.eqlIgnoreCase(raw, "ApexAssert")) return "ApexAssert";
    if (std.ascii.eqlIgnoreCase(raw, "SelectOption")) return "SelectOption";
    if (std.ascii.eqlIgnoreCase(raw, "Comparable")) return "ApexComparable";
    if (std.ascii.eqlIgnoreCase(raw, "SObjectDescribeOptions")) return "Schema.SObjectDescribeOptions";
    if (std.ascii.eqlIgnoreCase(raw, "Apexpages")) return "ApexPages";
    if (std.ascii.eqlIgnoreCase(raw, "pageReference")) return "PageReference";

    if (raw.len == 1 and std.ascii.isUpper(raw[0])) return "Object";
    if (std.ascii.isUpper(raw[0])) {
        if (isLikelySObjectTypeForInstanceof(raw)) return "ApexSObject";
        return raw;
    }
    return raw;
}

fn normalizeQualifiedTypeName(raw: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "Schema.sObjectType")) return "Schema.SObjectType";
    if (std.ascii.eqlIgnoreCase(raw, "Database.QueryLocator")) return "Database.QueryLocator";
    if (std.ascii.eqlIgnoreCase(raw, "Database.Querylocator")) return "Database.QueryLocator";
    if (std.ascii.eqlIgnoreCase(raw, "Database.Batchable")) return "Database.Batchable";
    if (std.ascii.eqlIgnoreCase(raw, "Database.Stateful")) return "Database.Stateful";
    if (std.ascii.eqlIgnoreCase(raw, "Database.AllowsCallouts")) return "Database.AllowsCallouts";
    if (std.ascii.eqlIgnoreCase(raw, "Database.LeadConvert")) return "Database.LeadConvert";
    if (std.ascii.eqlIgnoreCase(raw, "Database.LeadConvertResult")) return "Database.LeadConvertResult";
    if (std.ascii.eqlIgnoreCase(raw, "System.Type")) return "apexemu.runtime.System.Type";
    if (std.ascii.eqlIgnoreCase(raw, "System.Comparable")) return "apexemu.runtime.System.Comparable";
    if (std.ascii.eqlIgnoreCase(raw, "System.Callable")) return "apexemu.runtime.System.Callable";
    if (std.ascii.eqlIgnoreCase(raw, "System.Finalizer")) return "apexemu.runtime.System.Finalizer";
    if (std.ascii.eqlIgnoreCase(raw, "System.FinalizerContext")) return "apexemu.runtime.System.FinalizerContext";
    if (std.ascii.eqlIgnoreCase(raw, "System.FinalizerContext.ParentJobResult")) return "apexemu.runtime.System.FinalizerContext.ParentJobResult";
    if (std.ascii.eqlIgnoreCase(raw, "System.System.FinalizerContext")) return "apexemu.runtime.System.FinalizerContext";
    if (std.ascii.eqlIgnoreCase(raw, "System.System.FinalizerContext.ParentJobResult")) return "apexemu.runtime.System.FinalizerContext.ParentJobResult";
    if (std.ascii.eqlIgnoreCase(raw, "apexemu.runtime.System.System.FinalizerContext")) return "apexemu.runtime.System.FinalizerContext";
    if (std.ascii.eqlIgnoreCase(raw, "apexemu.runtime.System.System.FinalizerContext.ParentJobResult")) return "apexemu.runtime.System.FinalizerContext.ParentJobResult";
    if (std.ascii.eqlIgnoreCase(raw, "System.InstallHandler")) return "apexemu.runtime.System.InstallHandler";
    if (std.ascii.eqlIgnoreCase(raw, "System.UninstallHandler")) return "apexemu.runtime.System.UninstallHandler";
    if (std.ascii.eqlIgnoreCase(raw, "System.UninstallContext")) return "apexemu.runtime.System.UninstallContext";
    if (std.ascii.eqlIgnoreCase(raw, "System.HttpCalloutMock")) return "apexemu.runtime.System.HttpCalloutMock";
    if (std.ascii.eqlIgnoreCase(raw, "System.HttpRequest")) return "HttpRequest";
    if (std.ascii.eqlIgnoreCase(raw, "System.HttpResponse")) return "HttpResponse";
    if (std.ascii.eqlIgnoreCase(raw, "System.OrgLimit")) return "apexemu.runtime.System.OrgLimit";
    if (std.ascii.eqlIgnoreCase(raw, "System.StatusCode")) return "String";
    if (std.ascii.eqlIgnoreCase(raw, "TDTM_Runnable.DMLWrapper")) return "TDTM_Runnable.DmlWrapper";
    if (std.ascii.eqlIgnoreCase(raw, "System.Database")) return "Database";
    if (std.ascii.eqlIgnoreCase(raw, "System.Limits")) return "Limits";
    if (std.ascii.eqlIgnoreCase(raw, "System.Security")) return "Security";
    if (std.ascii.eqlIgnoreCase(raw, "System.FeatureManagement")) return "FeatureManagement";
    if (std.ascii.eqlIgnoreCase(raw, "System.Test")) return "apexemu.runtime.System.Test";
    if (std.ascii.eqlIgnoreCase(raw, "System.TriggerOperation")) return "apexemu.runtime.System.TriggerOperation";
    if (std.ascii.eqlIgnoreCase(raw, "System.JSON")) return "apexemu.runtime.System.JSON";
    if (std.ascii.eqlIgnoreCase(raw, "System.JSONException")) return "apexemu.runtime.System.JSONException";
    if (std.ascii.eqlIgnoreCase(raw, "System.AuraHandledException")) return "apexemu.runtime.System.AuraHandledException";
    if (std.ascii.eqlIgnoreCase(raw, "System.FormulaValidationException")) return "apexemu.runtime.System.FormulaValidationException";
    if (std.ascii.eqlIgnoreCase(raw, "System.AccessType")) return "apexemu.runtime.System.AccessType";
    if (std.ascii.eqlIgnoreCase(raw, "System.AccessLevel")) return "apexemu.runtime.System.AccessLevel";
    if (std.ascii.eqlIgnoreCase(raw, "System.SObjectAccessDecision")) return "apexemu.runtime.System.SObjectAccessDecision";
    if (std.ascii.eqlIgnoreCase(raw, "System.NoAccessException")) return "apexemu.runtime.System.NoAccessException";
    if (std.ascii.eqlIgnoreCase(raw, "System.SecurityException")) return "apexemu.runtime.System.SecurityException";
    if (std.ascii.eqlIgnoreCase(raw, "System.StubProvider")) return "apexemu.runtime.System.StubProvider";
    if (std.ascii.eqlIgnoreCase(raw, "System.Pattern")) return "Pattern";
    if (std.ascii.eqlIgnoreCase(raw, "System.Matcher")) return "Matcher";
    if (std.ascii.eqlIgnoreCase(raw, "System.Queueable")) return "Queueable";
    if (std.ascii.eqlIgnoreCase(raw, "System.Schedulable")) return "Schedulable";
    if (std.ascii.eqlIgnoreCase(raw, "System.QueueableContext")) return "apexemu.runtime.System.QueueableContext";
    if (std.ascii.eqlIgnoreCase(raw, "System.SchedulableContext")) return "apexemu.runtime.System.SchedulableContext";
    if (std.ascii.eqlIgnoreCase(raw, "System.Quiddity")) return "apexemu.runtime.System.Quiddity";
    if (std.ascii.eqlIgnoreCase(raw, "Schema.Displaytype")) return "Schema.DisplayType";
    if (std.ascii.eqlIgnoreCase(raw, "Schema.DescribeSobjectResult")) return "Schema.DescribeSObjectResult";
    if (std.ascii.eqlIgnoreCase(raw, "Messaging.inboundEmail")) return "Messaging.InboundEmail";
    if (std.ascii.eqlIgnoreCase(raw, "Messaging.inboundEmail.BinaryAttachment")) return "Messaging.InboundEmail.BinaryAttachment";
    if (std.ascii.eqlIgnoreCase(raw, "Messaging.inboundEnvelope")) return "Messaging.InboundEnvelope";
    if (std.ascii.eqlIgnoreCase(raw, "Messaging.inboundEmailResult")) return "Messaging.InboundEmailResult";
    if (std.ascii.eqlIgnoreCase(raw, "Messaging.InboundEmailresult")) return "Messaging.InboundEmailResult";
    if (std.ascii.eqlIgnoreCase(raw, "Database.saveresult")) return "Database.SaveResult";
    if (std.ascii.eqlIgnoreCase(raw, "Database.upsertresult")) return "Database.UpsertResult";
    if (std.ascii.eqlIgnoreCase(raw, "Database.deleteresult")) return "Database.DeleteResult";
    if (std.ascii.eqlIgnoreCase(raw, "Database.mergeresult")) return "Database.MergeResult";

    if (startsWithIgnoreCase(raw, "Schema.")) {
        const tail = raw["Schema.".len..];
        if (tail.len > 0 and std.mem.indexOfScalar(u8, tail, '.') == null and !isKnownSchemaHelperTypeName(tail)) {
            return "ApexSObject";
        }
    }
    return null;
}

fn isKnownSchemaHelperTypeName(raw: []const u8) bool {
    if (raw.len == 0) return false;
    const known = [_][]const u8{
        "SObjectType",
        "sObjectType",
        "SObjectField",
        "DescribeFieldResult",
        "DescribeSObjectResult",
        "ChildRelationship",
        "FieldSet",
        "FieldSetMember",
        "DisplayType",
        "SoapType",
        "PicklistEntry",
        "SObjectDescribeOptions",
    };
    for (known) |name| {
        if (std.ascii.eqlIgnoreCase(raw, name)) return true;
    }
    return false;
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
    var single_escaped = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < trimmed.len and trimmed[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') {
                in_single = false;
            }
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = true;
            single_escaped = false;
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
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return out;

    const split_at = findFirstTopLevelWhitespace(trimmed) orelse {
        try out.append(gpa, trimmed);
        return out;
    };
    const first = std.mem.trim(u8, trimmed[0..split_at], " \t");
    const second = std.mem.trim(u8, trimmed[split_at..], " \t");
    if (first.len > 0) try out.append(gpa, first);
    if (second.len > 0) try out.append(gpa, second);
    return out;
}

fn findFirstTopLevelWhitespace(text: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;

    for (text, 0..) |ch, i| {
        if (ch == '\'' and !in_double) {
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') continue;
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
            else => {},
        }

        if (std.ascii.isWhitespace(ch) and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
            return i;
        }
    }
    return null;
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
    var in_double = false;
    var double_escaped = false;
    while (i < trimmed.len) {
        const ch = trimmed[i];
        if (in_double) {
            try out.append(gpa, ch);
            if (double_escaped) {
                double_escaped = false;
            } else if (ch == '\\') {
                double_escaped = true;
            } else if (ch == '"') {
                in_double = false;
            }
            i += 1;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            double_escaped = false;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        if (ch != '\'') {
            try out.append(gpa, ch);
            i += 1;
            continue;
        }

        i += 1;
        try out.append(gpa, '"');
        while (i < trimmed.len) {
            const curr = trimmed[i];
            if (curr == '\\' and i + 1 < trimmed.len) {
                const next = trimmed[i + 1];
                if (next == '\'') {
                    try appendEscapedJavaStringChar(gpa, &out, '\'');
                    i += 2;
                    continue;
                }
                if (next == '"') {
                    // Apex single-quoted literals often escape double quotes as \".
                    // Emit a Java string literal with a single escaped quote.
                    try appendEscapedJavaStringChar(gpa, &out, '"');
                    i += 2;
                    continue;
                }
                if (next == '\\') {
                    // Apex `\\` inside single-quoted strings represents a single backslash.
                    try appendEscapedJavaStringChar(gpa, &out, '\\');
                    i += 2;
                    continue;
                }
                try appendEscapedJavaStringChar(gpa, &out, '\\');
                try appendEscapedJavaStringChar(gpa, &out, next);
                i += 2;
                continue;
            }
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

    const sosl_converted = try convertInlineSoslQueries(gpa, soql_converted);
    gpa.free(soql_converted);
    errdefer gpa.free(sosl_converted);

    const soql_api_converted = try rewriteDatabaseQueryStringConsumers(gpa, sosl_converted);
    gpa.free(sosl_converted);
    errdefer gpa.free(soql_api_converted);

    const query_get_as_converted = try rewriteQueryGetAsAccess(gpa, soql_api_converted);
    gpa.free(soql_api_converted);
    errdefer gpa.free(query_get_as_converted);

    const string_api_converted = try rewriteApexStringUtilityCalls(gpa, query_get_as_converted);
    gpa.free(query_get_as_converted);
    errdefer gpa.free(string_api_converted);

    const normalized_method_case = try rewriteCommonJavaMethodCase(gpa, string_api_converted);
    gpa.free(string_api_converted);
    errdefer gpa.free(normalized_method_case);

    const normalized_qualified_types = try rewriteKnownQualifiedTypeCase(gpa, normalized_method_case);
    gpa.free(normalized_method_case);
    errdefer gpa.free(normalized_qualified_types);

    const system_utility_converted = try rewriteApexSystemUtilityCalls(gpa, normalized_qualified_types);
    gpa.free(normalized_qualified_types);
    errdefer gpa.free(system_utility_converted);

    const date_arith_converted = try rewriteDateArithmetic(gpa, system_utility_converted);
    gpa.free(system_utility_converted);
    errdefer gpa.free(date_arith_converted);

    const strict_equality_converted = try rewriteApexStrictEqualityOperators(gpa, date_arith_converted);
    gpa.free(date_arith_converted);
    errdefer gpa.free(strict_equality_converted);

    const not_equals_converted = try rewriteApexNotEqualsOperator(gpa, strict_equality_converted);
    gpa.free(strict_equality_converted);
    errdefer gpa.free(not_equals_converted);

    const relational_converted = try rewriteStringRelationalComparisons(gpa, not_equals_converted);
    gpa.free(not_equals_converted);
    errdefer gpa.free(relational_converted);

    const trigger_property_converted = try rewriteTriggerContextPropertyAccess(gpa, relational_converted);
    gpa.free(relational_converted);
    errdefer gpa.free(trigger_property_converted);

    const safe_nav_converted = try rewriteApexSafeNavigationOperators(gpa, trigger_property_converted);
    gpa.free(trigger_property_converted);
    errdefer gpa.free(safe_nav_converted);

    const null_safe_cmp_converted = try wrapNullSafeComparisons(gpa, safe_nav_converted);
    gpa.free(safe_nav_converted);
    errdefer gpa.free(null_safe_cmp_converted);

    const null_coalescing_converted = try rewriteNullCoalescingOperator(gpa, null_safe_cmp_converted);
    gpa.free(null_safe_cmp_converted);
    errdefer gpa.free(null_coalescing_converted);

    const cast_type_converted = try rewriteApexTypeCasts(gpa, null_coalescing_converted);
    gpa.free(null_coalescing_converted);
    errdefer gpa.free(cast_type_converted);

    const generic_class_literal_converted = try rewriteGenericClassLiterals(gpa, cast_type_converted);
    gpa.free(cast_type_converted);
    errdefer gpa.free(generic_class_literal_converted);

    const deserialize_list_converted = try rewriteJsonDeserializeListCasts(gpa, generic_class_literal_converted);
    gpa.free(generic_class_literal_converted);
    errdefer gpa.free(deserialize_list_converted);

    const indexed_converted = try convertBracketIndexAccess(gpa, deserialize_list_converted);
    gpa.free(deserialize_list_converted);
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

    const status_code_constants = try rewriteSystemStatusCodeConstants(gpa, field_converted);
    gpa.free(field_converted);
    errdefer gpa.free(status_code_constants);

    const sobject_type_constants = try rewriteTypeSObjectTypeConstants(gpa, status_code_constants);
    gpa.free(status_code_constants);
    errdefer gpa.free(sobject_type_constants);

    const sobject_type_field_constants = try rewriteTypeSObjectFieldConstants(gpa, sobject_type_constants);
    gpa.free(sobject_type_constants);
    errdefer gpa.free(sobject_type_field_constants);

    const sobject_fieldset_constants = try rewriteSObjectTypeFieldSetConstants(gpa, sobject_type_field_constants);
    gpa.free(sobject_type_field_constants);
    errdefer gpa.free(sobject_fieldset_constants);

    const sobject_type_calls = try rewriteIdGetSObjectTypeCalls(gpa, sobject_fieldset_constants);
    gpa.free(sobject_fieldset_constants);
    errdefer gpa.free(sobject_type_calls);

    const sobject_get_as_calls = try rewriteSObjectGetAsMethodCalls(gpa, sobject_type_calls);
    gpa.free(sobject_type_calls);
    errdefer gpa.free(sobject_get_as_calls);

    const numeric_valueof_converted = try rewriteIntegerValueOfNumericCasts(gpa, sobject_get_as_calls);
    gpa.free(sobject_get_as_calls);
    errdefer gpa.free(numeric_valueof_converted);

    const string_instance_calls = try rewriteStringInstanceMethodCalls(gpa, numeric_valueof_converted);
    gpa.free(numeric_valueof_converted);
    errdefer gpa.free(string_instance_calls);

    const clone_calls = try rewriteNoArgCloneCalls(gpa, string_instance_calls);
    gpa.free(string_instance_calls);
    errdefer gpa.free(clone_calls);

    const dynamic_set_calls = try rewriteStringKeyedSetMethodCalls(gpa, clone_calls);
    gpa.free(clone_calls);
    errdefer gpa.free(dynamic_set_calls);

    const sort_calls = try rewriteNoArgSortCalls(gpa, dynamic_set_calls);
    gpa.free(dynamic_set_calls);
    errdefer gpa.free(sort_calls);

    const query_get_as_final = try rewriteQueryGetAsAccess(gpa, sort_calls);
    gpa.free(sort_calls);
    errdefer gpa.free(query_get_as_final);

    const first_field_or_null = try rewriteFirstOrNullGetAs(gpa, query_get_as_final);
    gpa.free(query_get_as_final);
    errdefer gpa.free(first_field_or_null);

    const query_with_binds = try rewriteDatabaseQueryCallsWithBinds(gpa, first_field_or_null);
    gpa.free(first_field_or_null);
    errdefer gpa.free(query_with_binds);

    const trigger_operation_constant_case = try rewriteTriggerOperationEnumConstantCase(gpa, query_with_binds);
    gpa.free(query_with_binds);
    errdefer gpa.free(trigger_operation_constant_case);

    const instanceof_converted = try rewriteApexInstanceofChecks(gpa, trigger_operation_constant_case);
    gpa.free(trigger_operation_constant_case);
    errdefer gpa.free(instanceof_converted);

    return instanceof_converted;
}

fn rewriteCommonJavaMethodCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "Integer.valueof(", .to = "Integer.valueOf(" },
        .{ .from = "Long.valueof(", .to = "Long.valueOf(" },
        .{ .from = "Double.valueof(", .to = "Double.valueOf(" },
        .{ .from = "String.valueof(", .to = "ApexStrings.valueOf(" },
        .{ .from = "getSobjectType(", .to = "getSObjectType(" },
        .{ .from = "getSobjectField(", .to = "getSObjectField(" },
        .{ .from = ".getSobjectType(", .to = ".getSObjectType(" },
        .{ .from = ".getSobjectField(", .to = ".getSObjectField(" },
        .{ .from = ".keyset(", .to = ".keySet(" },
        .{ .from = "DMLException", .to = "DmlException" },
        .{ .from = "catch (exception ", .to = "catch (Exception " },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        var matched = false;
        for (patterns) |pattern| {
            if (i + pattern.from.len > text.len) continue;
            if (!startsWithIgnoreCase(text[i..], pattern.from)) continue;
            const needs_left_boundary = pattern.from.len == 0 or pattern.from[0] != '.';
            if (needs_left_boundary and i > 0 and isIdentifierChar(text[i - 1])) continue;
            try out.appendSlice(gpa, pattern.to);
            i += pattern.from.len;
            replaced = true;
            matched = true;
            break;
        }
        if (matched) continue;

        try out.append(gpa, text[i]);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteKnownQualifiedTypeCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "Messaging.inboundEmail.", .to = "Messaging.InboundEmail." },
        .{ .from = "Messaging.inboundEnvelope", .to = "Messaging.InboundEnvelope" },
        .{ .from = "Messaging.inboundEmailResult", .to = "Messaging.InboundEmailResult" },
        .{ .from = "Messaging.InboundEmailresult", .to = "Messaging.InboundEmailResult" },
        .{ .from = "Schema.sObjectType", .to = "Schema.SObjectType" },
        .{ .from = "System.Test.", .to = "apexemu.runtime.System.Test." },
        .{ .from = "Pattern.Matches(", .to = "Pattern.matches(" },
        .{ .from = "System.Limits.", .to = "Limits." },
        .{ .from = "System.Database.", .to = "Database." },
        .{ .from = "System.Security.", .to = "Security." },
        .{ .from = "System.FeatureManagement.", .to = "FeatureManagement." },
        .{ .from = "System.UserInfo.", .to = "UserInfo." },
        .{ .from = "limits.", .to = "Limits." },
        .{ .from = "featuremanagement.", .to = "FeatureManagement." },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        var matched = false;
        for (patterns) |pattern| {
            if (i + pattern.from.len > text.len) continue;
            if (!startsWithIgnoreCase(text[i..], pattern.from)) continue;
            try out.appendSlice(gpa, pattern.to);
            i += pattern.from.len;
            replaced = true;
            matched = true;
            break;
        }
        if (matched) continue;

        try out.append(gpa, text[i]);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteMathModCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "Math.mod(";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        if (i + marker.len <= text.len and startsWithIgnoreCase(text[i..], marker)) {
            const left_ok = i == 0 or !isIdentifierChar(text[i - 1]);
            if (left_ok) {
                try out.appendSlice(gpa, "ApexMath.mod(");
                i += marker.len;
                replaced = true;
                continue;
            }
        }

        try out.append(gpa, text[i]);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteKnownCompatibilityFixups(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "catch (Exception ", .to = "catch (apexemu.runtime.System.Exception " },
        .{ .from = "catch (exception ", .to = "catch (apexemu.runtime.System.Exception " },
        .{ .from = "catch(Exception ", .to = "catch(apexemu.runtime.System.Exception " },
        .{ .from = "catch(exception ", .to = "catch(apexemu.runtime.System.Exception " },
        .{ .from = "throws Exception", .to = "throws apexemu.runtime.System.Exception" },
        .{ .from = " instanceof Id", .to = " instanceof String" },
        .{ .from = "apexemu.runtime.getAs(\"RecordTypeInfo\")", .to = "apexemu.runtime.RecordTypeInfo" },
        .{ .from = "Math.roundToLong(", .to = "Math.round(" },
        .{ .from = ".GetRecordTypeName(", .to = ".getRecordTypeName(" },
        .{ .from = ".GetRecordTypeId(", .to = ".getRecordTypeId(" },
        .{ .from = ".GetRecordTypeIdSet(", .to = ".getRecordTypeIdSet(" },
        .{ .from = ".canDisplaytypesCopy(", .to = ".canDisplayTypesCopy(" },
        .{ .from = ".containskey(", .to = ".containsKey(" },
        .{ .from = "database.", .to = "Database." },
        .{ .from = "List<Report>", .to = "List<ApexSObject>" },
        .{ .from = "Report r = null;", .to = "ApexSObject r = null;" },
        .{ .from = "Report r = new Report();", .to = "ApexSObject r = ApexSObject.of(\"Report\");" },
        .{ .from = "public Long percentComplete = 0;", .to = "public Long percentComplete = 0L;" },
        .{ .from = "Long percentComplete = defaultPercentComplete;", .to = "Long percentComplete = Long.valueOf(defaultPercentComplete);" },
        .{ .from = "percentComplete = 100;", .to = "percentComplete = 100L;" },
        .{ .from = "percentComplete = 10;", .to = "percentComplete = 10L;" },
        .{ .from = "percentComplete = 0;", .to = "percentComplete = 0L;" },
        .{ .from = "percentComplete = Math.max( Math.round(100 * jobItemsProcessed / totalJobItems), defaultPercentComplete );", .to = "percentComplete = Math.max(Math.round(100.0 * jobItemsProcessed / totalJobItems), defaultPercentComplete.longValue());" },
        .{ .from = "return days > MAX_DAYS_EXCEEDED ? MAX_DAYS_EXCEEDED : Integer.valueOf(days);", .to = "return days > MAX_DAYS_EXCEEDED ? MAX_DAYS_EXCEEDED : Integer.valueOf(days.intValue());" },
        .{ .from = "LoggerStacktrace", .to = "LoggerStackTrace" },
        .{ .from = "Database.DMLOptions", .to = "Database.DmlOptions" },
        .{ .from = " instanceOf ", .to = " instanceof " },
        .{ .from = "sender.email", .to = "sender.getAs(\"email\")" },
        .{ .from = "\"bPl\", bPl", .to = "\"bPl\", bPL" },
        .{ .from = "getRecords()ToUpdate", .to = "recordsToUpdate" },
        .{ .from = "super(getIdList(objects));", .to = "super(new ArrayList<Object>((java.util.Collection<?>) getIdList(objects)));"},
        .{ .from = ".si size", .to = ".size()" },
        .{ .from = ".getsObject(", .to = ".getSObject(" },
        .{ .from = "List<String> names = new String.get(0);", .to = "List<String> names = new ArrayList<>();" },
        .{ .from = "listFName", .to = "listFname" },
        .{ .from = "strConFSpec(", .to = "strConFspec(" },
        .{ .from = "strFName +=", .to = "strFname +=" },
        .{ .from = "DateTime typeCheck = (DateTime) obj;", .to = "DateTime typeCheck = ApexCompare.castDateTime(obj);" },
        .{ .from = "this.OrgShape", .to = "this.orgShape" },
        .{ .from = "new orgShape()", .to = "new OrgShape()" },
        .{ .from = "private static class LoopCount", .to = "public static class LoopCount" },
        .{ .from = "public Cache.OrgPartition safeDefaultCachePartition;", .to = "public static Cache.OrgPartition safeDefaultCachePartition;" },
        .{
            .from = "public Boolean multiCurrencyEnabled; // Apex property { get; set; }",
            .to = "public Boolean multiCurrencyEnabled = UserInfo.isMultiCurrencyOrganization(); // Apex property { get; set; }",
        },
        .{ .from = " implements IA, IB, IC", .to = "" },
        .{ .from = " implements fflib_Inheritor.IA, fflib_Inheritor.IB, fflib_Inheritor.IC", .to = "" },
        .{ .from = "List<AppMenuItem>", .to = "List<ApexSObject>" },
        .{ .from = "Map<String, AppMenuItem>", .to = "Map<String, ApexSObject>" },
        .{ .from = "(Organization)", .to = "(ApexSObject)" },
        .{ .from = "List<Campaign>", .to = "List<ApexSObject>" },
        .{ .from = "List<Account>", .to = "List<ApexSObject>" },
        .{
            .from = "public static ErrorFactory Errors; // Apex property { get; set; }",
            .to = "public static ErrorFactory Errors = new ErrorFactory(); // Apex property { get; set; }",
        },
        .{
            .from = "public static fflib_SObjectDomain.ErrorFactory Errors; // Apex property { get; set; }",
            .to = "public static fflib_SObjectDomain.ErrorFactory Errors = new fflib_SObjectDomain.ErrorFactory(); // Apex property { get; set; }",
        },
        .{
            .from = "public static TestFactory Test; // Apex property { get; set; }",
            .to = "public static TestFactory Test = new TestFactory(); // Apex property { get; set; }",
        },
        .{
            .from = "private static Map<apexemu.runtime.System.Type, List<fflib_SObjectDomain>> TriggerStateByClass;",
            .to = "private static Map<apexemu.runtime.System.Type, List<fflib_SObjectDomain>> TriggerStateByClass = new LinkedHashMap<apexemu.runtime.System.Type, List<fflib_SObjectDomain>>();",
        },
        .{
            .from = "private static Map<apexemu.runtime.System.Type, TriggerEvent> TriggerEventByClass;",
            .to = "private static Map<apexemu.runtime.System.Type, TriggerEvent> TriggerEventByClass = new LinkedHashMap<apexemu.runtime.System.Type, TriggerEvent>();",
        },
        .{
            .from = "private static Map<String, Schema.SObjectType> rawGlobalDescribe; // Apex property { get; set; }",
            .to = "private static Map<String, Schema.SObjectType> rawGlobalDescribe = Schema.getGlobalDescribe(); // Apex property { get; set; }",
        },
        .{
            .from = "private static GlobalDescribeMap wrappedGlobalDescribe; // Apex property { get; set; }",
            .to = "private static GlobalDescribeMap wrappedGlobalDescribe = new GlobalDescribeMap(rawGlobalDescribe); // Apex property { get; set; }",
        },
        .{
            .from = "private static Map<String, fflib_SObjectDescribe> instanceCache; // Apex property { get; set; }",
            .to = "private static Map<String, fflib_SObjectDescribe> instanceCache = new LinkedHashMap<String, fflib_SObjectDescribe>(); // Apex property { get; set; }",
        },
        .{
            .from = "public DomainFactory(fflib_Application.SelectorFactory selectorFactory, Map<Schema.SObjectType, apexemu.runtime.System.Type> sObjectByDomainConstructorType)",
            .to = "public DomainFactory(fflib_Application.SelectorFactory selectorFactory, LinkedHashMap<Schema.SObjectType, apexemu.runtime.System.Type> sObjectByDomainConstructorType)",
        },
        .{
            .from = "public fflib_QueryFactory selectFields(Set<Schema.SObjectField> fields)",
            .to = "public fflib_QueryFactory selectFieldsByToken(Set<Schema.SObjectField> fields)",
        },
        .{
            .from = "public fflib_QueryFactory selectFields(List<Schema.SObjectField> fields)",
            .to = "public fflib_QueryFactory selectFieldsByToken(List<Schema.SObjectField> fields)",
        },
        .{
            .from = "public static String describe(List<fflib_MethodArgValues> valuesFromAllInvocations)",
            .to = "public static String describeArgValues(List<fflib_MethodArgValues> valuesFromAllInvocations)",
        },
        .{
            .from = "this.token = token;\n    instanceCache.put( ApexStrings.valueOf(token).toLowerCase() , this);",
            .to = "this.token = token;\n    this.describe = token.getDescribe();\n    this.fields = this.describe.fields.getMap();\n    Schema.FieldSetNamespace fieldSetNamespace = this.describe.getAs(\"fieldsets\");\n    this.fieldSets = fieldSetNamespace == null ? new LinkedHashMap<String, Schema.FieldSet>() : fieldSetNamespace.getMap();\n    this.wrappedFields = new FieldsMap(this.fields);\n    instanceCache.put( ApexStrings.valueOf(token).toLowerCase() , this);",
        },
        .{
            .from = "public static Map<String, Schema.SObjectType> getRawGlobalDescribe() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return rawGlobalDescribe;\n  }",
            .to = "public static Map<String, Schema.SObjectType> getRawGlobalDescribe() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    if(rawGlobalDescribe == null) rawGlobalDescribe = Schema.getGlobalDescribe();\n    return rawGlobalDescribe;\n  }",
        },
        .{
            .from = "public static GlobalDescribeMap getGlobalDescribe() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return wrappedGlobalDescribe;\n  }",
            .to = "public static GlobalDescribeMap getGlobalDescribe() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    if(wrappedGlobalDescribe == null) wrappedGlobalDescribe = new GlobalDescribeMap(getRawGlobalDescribe());\n    return wrappedGlobalDescribe;\n  }",
        },
        .{
            .from = "public static void flushCache() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    rawGlobalDescribe = null;\n    instanceCache = null;\n  }",
            .to = "public static void flushCache() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    rawGlobalDescribe = null;\n    wrappedGlobalDescribe = null;\n    instanceCache = new LinkedHashMap<String, fflib_SObjectDescribe>();\n  }",
        },
        .{ .from = "actualDescription = describe(actualArguments);", .to = "actualDescription = describeArgValues(actualArguments);" },
        .{ .from = "mockinvocation.getMethod()", .to = "mockInvocation.getMethod()" },
        .{ .from = "mockinvocation.getMethodArgValues()", .to = "mockInvocation.getMethodArgValues()" },
        .{ .from = ".getmessage()", .to = ".getMessage()" },
        .{ .from = "fflib_VerificationMode.ModeName.CALLS", .to = "fflib_VerificationMode.ModeName.calls" },
        .{ .from = "verificationMode.getAs(\"VerifyMin\")", .to = "((Integer) verificationMode.getAs(\"VerifyMin\"))" },
        .{ .from = "verificationMode.getAs(\"VerifyMax\")", .to = "((Integer) verificationMode.getAs(\"VerifyMax\"))" },
        .{ .from = "verificationMode.getAs(\"Method\")", .to = "((fflib_VerificationMode.ModeName) verificationMode.getAs(\"Method\"))" },
        .{ .from = "verificationMode.getAs(\"CustomAssertMessage\")", .to = "((String) verificationMode.getAs(\"CustomAssertMessage\"))" },
        .{
            .from = "methodReturnValue.getAs(\"Answer\").answer(invocation)",
            .to = "((fflib_Answer) methodReturnValue.getAs(\"Answer\")).answer(invocation)",
        },
        .{
            .from = "return ApexStrings.split(ApexStrings.valueOf(mockInstance), \":\").get(0);",
            .to = "String typeName = ApexStrings.split(ApexStrings.valueOf(mockInstance), \":\").get(0);\n    return typeName != null && typeName.endsWith(\"__sfdc_ApexStub\") ? typeName : (typeName + \"__sfdc_ApexStub\");",
        },
        .{ .from = "this.argValues == that.argValues", .to = "ApexEquals.eq(this.argValues, that.argValues)" },
        .{ .from = "this.typeName == that.typeName", .to = "ApexEquals.eq(this.typeName, that.typeName)" },
        .{ .from = "this.methodName == that.methodName", .to = "ApexEquals.eq(this.methodName, that.methodName)" },
        .{ .from = "this.methodArgTypes == that.methodArgTypes", .to = "ApexEquals.eq(this.methodArgTypes, that.methodArgTypes)" },
        .{ .from = "if( arg == methodArg) count++;", .to = "if(ApexEquals.eq(arg, methodArg)) count++;" },
        .{ .from = "(qualifiedMethod == invocation.getMethod())", .to = "(ApexEquals.eq(qualifiedMethod, invocation.getMethod()))" },
        .{ .from = "else if(calledMethodArg == methodArg) {", .to = "else if(ApexEquals.eq(calledMethodArg, methodArg)) {" },
        .{
            .from = "return typeName + \".\" + methodName + methodArgTypes;",
            .to = "return typeName + \".\" + methodName + \"(\" + ApexStrings.join(methodArgTypes, \", \") + \")\";",
        },
        .{
            .from = "public static Boolean HasIndependentMocks; // Apex property { get; set; }",
            .to = "public static Boolean HasIndependentMocks = false; // Apex property { get; set; }",
        },
        .{
            .from = "methodReturnValueRecorder.set(\"Stubbing\", true);",
            .to = "ApexSwitch.set(methodReturnValueRecorder, \"Stubbing\", true);",
        },
        .{
            .from = "methodReturnValueRecorder.set(\"Stubbing\", false);",
            .to = "ApexSwitch.set(methodReturnValueRecorder, \"Stubbing\", false);",
        },
        .{
            .from = "evaluators.add(subCriteria);",
            .to =
            \\evaluators.add(new Evaluator() {
            \\    public Boolean evaluate(Object obj) { return subCriteria.evaluate(obj); }
            \\    public String toSOQL() { return subCriteria.toSOQL(); }
            \\    });
            ,
        },
        .{
            .from = "else if (Stubbing) {",
            .to = "else if (Boolean.TRUE.equals(methodReturnValueRecorder.getAs(\"Stubbing\"))) {",
        },
        .{
            .from = "if(DoThrowWhenExceptions != null) {\n    methotReturnValue.thenThrowMulti(DoThrowWhenExceptions);\n    DoThrowWhenExceptions = null;\n    return null;\n    }",
            .to = "List<apexemu.runtime.System.Exception> doThrowWhenExceptions = (List<apexemu.runtime.System.Exception>) methodReturnValueRecorder.getAs(\"DoThrowWhenExceptions\");\n    if(doThrowWhenExceptions != null) {\n    methotReturnValue.thenThrowMulti(doThrowWhenExceptions);\n    ApexSwitch.set(methodReturnValueRecorder, \"DoThrowWhenExceptions\", null);\n    return null;\n    }",
        },
        .{
            .from = "public static Object setReadOnlyFields(ApexSObject objInstance, apexemu.runtime.System.Type deserializeType, Map<String, Object> properties)",
            .to = "public static Object setReadOnlyFieldsByName(ApexSObject objInstance, apexemu.runtime.System.Type deserializeType, Map<String, Object> properties)",
        },
        .{
            .from = "public static Object setReadOnlyFields(ApexSObject objInstance, apexemu.runtime.System.Type deserializeType, Map<Schema.SObjectField, Object> properties)",
            .to = "public static Object setReadOnlyFields(ApexSObject objInstance, apexemu.runtime.System.Type deserializeType, Map<?, Object> properties)",
        },
        .{
            .from = "for (Schema.SObjectField field : properties.keySet()) {\n    fieldNameMap.put(field.getDescribe().getName(), properties.get(field));\n    }",
            .to = "for (Object field : properties.keySet()) {\n    if (field instanceof Schema.SObjectField token) {\n    fieldNameMap.put(token.getDescribe().getName(), properties.get(field));\n    }\n    else if (field != null) {\n    fieldNameMap.put(String.valueOf(field), properties.get(field));\n    }\n    }",
        },
        .{
            .from = "setReadOnlyFields(objInstance, deserializeType, fieldNameMap)",
            .to = "setReadOnlyFieldsByName(objInstance, deserializeType, fieldNameMap)",
        },
        .{
            .from = "Map<String, Object> mergedMap = new LinkedHashMap<>(objInstance.getPopulatedFieldsAsMap());\n    mergedMap.putAll(properties);\n    String jsonString = JSON.serializePretty(mergedMap);\n    return (ApexSObject) JSON.deserialize(jsonString, deserializeType);",
            .to = "Map<String, Object> mergedMap = new LinkedHashMap<>(objInstance.fields());\n    mergedMap.putAll(properties);\n    ApexSObject deserialized = ApexSObject.of(ApexSwitch.typeName(objInstance));\n    if (objInstance.id() != null) {\n    deserialized.withId(objInstance.id());\n    }\n    for (Map.Entry<String, Object> entry : mergedMap.entrySet()) {\n    deserialized.set(entry.getKey(), entry.getValue());\n    }\n    return deserialized;",
        },
        .{
            .from = "Map<String, Object> mergedMap = new LinkedHashMap<>(objInstance.fields());\n    mergedMap.putAll(properties);\n    String jsonString = JSON.serializePretty(mergedMap);\n    return (ApexSObject) JSON.deserialize(jsonString, deserializeType);",
            .to = "Map<String, Object> mergedMap = new LinkedHashMap<>(objInstance.fields());\n    mergedMap.putAll(properties);\n    ApexSObject deserialized = ApexSObject.of(ApexSwitch.typeName(objInstance));\n    if (objInstance.id() != null) {\n    deserialized.withId(objInstance.id());\n    }\n    for (Map.Entry<String, Object> entry : mergedMap.entrySet()) {\n    deserialized.set(entry.getKey(), entry.getValue());\n    }\n    return deserialized;",
        },
        .{ .from = "Schema.SobjectField", .to = "Schema.SObjectField" },
        .{
            .from = "public List<ApexSObject> getChangedRecords(Set<Schema.SObjectField> fieldTokens)",
            .to = "public List<ApexSObject> getChangedRecordsByToken(Set<Schema.SObjectField> fieldTokens)",
        },
        .{
            .from = "public static void checkInsert(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens)",
            .to = "public static void checkInsertByToken(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens)",
        },
        .{
            .from = "public static void checkRead(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens)",
            .to = "public static void checkReadByToken(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens)",
        },
        .{
            .from = "public static void checkUpdate(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens)",
            .to = "public static void checkUpdateByToken(Schema.SObjectType objType, List<Schema.SObjectField> fieldTokens)",
        },
        .{
            .from = "new InvalidFieldException(fieldName, this.table)",
            .to = "new InvalidFieldException(fieldName + \":\" + this.table)",
        },
        .{
            .from = "new InvalidFieldException(field,lastSObjectType)",
            .to = "new InvalidFieldException(field + \":\" + lastSObjectType)",
        },
        .{ .from = "new InvalidFieldException()", .to = "new InvalidFieldException(\"\")" },
        .{ .from = "public Boolean equals(Object obj)", .to = "public boolean equals(Object obj)" },
        .{ .from = "public Boolean equals(Object other)", .to = "public boolean equals(Object other)" },
        .{ .from = "public Integer hashCode()", .to = "public int hashCode()" },
        .{
            .from = "if (ApexStrings.compareTo(sObjectType.length(), 3 && ApexStrings.right(sObjectType, 3)  == \"__e\") > 0)",
            .to = "if (sObjectType.length() > 3 && ApexStrings.right(sObjectType, 3).equals(\"__e\"))",
        },
        .{
            .from = "if (ApexStrings.compareTo(sObjectType.length(), 3 && ApexStrings.right(sObjectType, 3) != \"__e\") > 0)",
            .to = "if (sObjectType.length() > 3 && !ApexStrings.right(sObjectType, 3).equals(\"__e\"))",
        },
        .{
            .from = "employeeCount += acct.getAs(\"NumberOfEmployees\");",
            .to = "employeeCount += ApexStrings.toInteger(acct.getAs(\"NumberOfEmployees\"));",
        },
        .{ .from = "acct.getAs(\"BillingState\") = \"IN\";", .to = "acct.set(\"BillingState\", \"IN\");" },
        .{ .from = "acct.getAs(\"ShippingState\") = \"IN\";", .to = "acct.set(\"ShippingState\", \"IN\");" },
        .{ .from = "JSONToken currentToken = fromStream.getCurrentToken();", .to = "JSONParser.Token currentToken = fromStream.getCurrentToken();" },
        .{ .from = "currentToken == JSONToken.END_OBJECT", .to = "currentToken == JSONParser.Token.END_OBJECT" },
        .{ .from = "String.format(", .to = "ApexStrings.format(" },
        .{ .from = "ApexCollections.listOf(null)", .to = "ApexCollections.listOf((Object) null)" },
        .{
            .from = "apexemu.runtime.System.Type parentsType = List.class;",
            .to = "apexemu.runtime.System.Type parentsType = apexemu.runtime.System.Type.forName(\"List\");",
        },
        .{
            .from = "accounts.getAs(\"Constructor\").class",
            .to = "apexemu.runtime.System.Type.forName(\"Accounts.Constructor\")",
        },
        .{
            .from = "new LinkedHashMap<>(objInstance.getPopulatedFieldsAsMap())",
            .to = "new LinkedHashMap<>(objInstance.fields())",
        },
        .{
            .from = "if(childRelationship.getField() == relationshipField)",
            .to = "if(childRelationship.getField().equalsIgnoreCase(relationshipField.getName()))",
        },
        .{
            .from = "if(ApexEquals.eq(childRelationship.getField(), relationshipField))",
            .to = "if(childRelationship.getField().equalsIgnoreCase(relationshipField.getName()))",
        },
        .{
            .from = "List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();\n    String relationshipName = null;\n    for(Schema.ChildRelationship childRelationship : childRelationships) {\n    if(childRelationship.getField() == relationshipField) {\n    relationshipName = childRelationship.getRelationshipName();\n    break;\n    }\n    }\n    JSONParser parentsParser = JSON.createParser(JSON.serialize(parents));\n    JSONParser childrenParser = JSON.createParser(JSON.serialize(children));\n    JSONGenerator combinedOutput = JSON.createGenerator(false);\n    streamTokens(parentsParser, combinedOutput, new InjectChildrenEventHandler(childrenParser, relationshipName, children) );\n    return JSON.deserialize(combinedOutput.getAsString(), parentsType);",
            .to = "List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();\n    String relationshipName = null;\n    for(Schema.ChildRelationship childRelationship : childRelationships) {\n    if(childRelationship.getField().equalsIgnoreCase(relationshipField.getName())) {\n    relationshipName = childRelationship.getRelationshipName();\n    break;\n    }\n    }\n    if (relationshipName == null && relationshipField != null) {\n    relationshipName = relationshipField.getDescribe().getRelationshipName();\n    }\n    List<ApexSObject> withChildren = new ArrayList<>();\n    for (Integer i = 0; i < parents.size(); i++) {\n    ApexSObject parent = parents.get(i);\n    ApexSObject copy = ApexSObject.of(parent.type());\n    if (parent.id() != null) {\n    copy.withId(parent.id());\n    }\n    for (Map.Entry<String, Object> entry : parent.fields().entrySet()) {\n    copy.set(entry.getKey(), entry.getValue());\n    }\n    List<ApexSObject> rowChildren = (children != null && i < children.size() && children.get(i) != null) ? children.get(i) : new ArrayList<ApexSObject>();\n    if (relationshipName != null && !relationshipName.isBlank()) {\n    copy.set(relationshipName, rowChildren);\n    }\n    withChildren.add(copy);\n    }\n    return withChildren;",
        },
        .{
            .from = "List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();\n    String relationshipName = null;\n    for(Schema.ChildRelationship childRelationship : childRelationships) {\n    if(childRelationship.getField().equals(relationshipField.getName())) {\n    relationshipName = childRelationship.getRelationshipName();\n    break;\n    }\n    }\n    JSONParser parentsParser = JSON.createParser(JSON.serialize(parents));\n    JSONParser childrenParser = JSON.createParser(JSON.serialize(children));\n    JSONGenerator combinedOutput = JSON.createGenerator(false);\n    streamTokens(parentsParser, combinedOutput, new InjectChildrenEventHandler(childrenParser, relationshipName, children) );\n    return JSON.deserialize(combinedOutput.getAsString(), parentsType);",
            .to = "List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();\n    String relationshipName = null;\n    for(Schema.ChildRelationship childRelationship : childRelationships) {\n    if(childRelationship.getField().equalsIgnoreCase(relationshipField.getName())) {\n    relationshipName = childRelationship.getRelationshipName();\n    break;\n    }\n    }\n    if (relationshipName == null && relationshipField != null) {\n    relationshipName = relationshipField.getDescribe().getRelationshipName();\n    }\n    List<ApexSObject> withChildren = new ArrayList<>();\n    for (Integer i = 0; i < parents.size(); i++) {\n    ApexSObject parent = parents.get(i);\n    ApexSObject copy = ApexSObject.of(parent.type());\n    if (parent.id() != null) {\n    copy.withId(parent.id());\n    }\n    for (Map.Entry<String, Object> entry : parent.fields().entrySet()) {\n    copy.set(entry.getKey(), entry.getValue());\n    }\n    List<ApexSObject> rowChildren = (children != null && i < children.size() && children.get(i) != null) ? children.get(i) : new ArrayList<ApexSObject>();\n    if (relationshipName != null && !relationshipName.isBlank()) {\n    copy.set(relationshipName, rowChildren);\n    }\n    withChildren.add(copy);\n    }\n    return withChildren;",
        },
        .{
            .from = "List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();\n    String relationshipName = null;\n    for(Schema.ChildRelationship childRelationship : childRelationships) {\n    if(childRelationship.getField().equalsIgnoreCase(relationshipField.getName())) {\n    relationshipName = childRelationship.getRelationshipName();\n    break;\n    }\n    }\n    JSONParser parentsParser = JSON.createParser(JSON.serialize(parents));\n    JSONParser childrenParser = JSON.createParser(JSON.serialize(children));\n    JSONGenerator combinedOutput = JSON.createGenerator(false);\n    streamTokens(parentsParser, combinedOutput, new InjectChildrenEventHandler(childrenParser, relationshipName, children) );\n    return JSON.deserialize(combinedOutput.getAsString(), parentsType);",
            .to = "List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();\n    String relationshipName = null;\n    for(Schema.ChildRelationship childRelationship : childRelationships) {\n    if(childRelationship.getField().equalsIgnoreCase(relationshipField.getName())) {\n    relationshipName = childRelationship.getRelationshipName();\n    break;\n    }\n    }\n    if (relationshipName == null && relationshipField != null) {\n    relationshipName = relationshipField.getDescribe().getRelationshipName();\n    }\n    List<ApexSObject> withChildren = new ArrayList<>();\n    for (Integer i = 0; i < parents.size(); i++) {\n    ApexSObject parent = parents.get(i);\n    ApexSObject copy = ApexSObject.of(parent.type());\n    if (parent.id() != null) {\n    copy.withId(parent.id());\n    }\n    for (Map.Entry<String, Object> entry : parent.fields().entrySet()) {\n    copy.set(entry.getKey(), entry.getValue());\n    }\n    List<ApexSObject> rowChildren = (children != null && i < children.size() && children.get(i) != null) ? children.get(i) : new ArrayList<ApexSObject>();\n    if (relationshipName != null && !relationshipName.isBlank()) {\n    copy.set(relationshipName, rowChildren);\n    }\n    withChildren.add(copy);\n    }\n    return withChildren;",
        },
        .{
            .from = "thenAnswer(this.basicAnswer.setValues(es));",
            .to = "thenAnswer(this.basicAnswer.setValues(es == null ? null : new ArrayList<Object>(es)));",
        },
        .{
            .from = "mockList.add(new String[] {\"bob\"});",
            .to = "mockList.add(new ArrayList<String>(ApexCollections.listOf(\"bob\")));",
        },
        .{
            .from = "((fflib_MyList.IList) mocks.verify(mockList)).add(new String[] {\"bob\"});",
            .to = "((fflib_MyList) mocks.verify(mockList)).add(new ArrayList<String>(ApexCollections.listOf(\"bob\")));",
        },
        .{
            .from = "((fflib_MyList.IList) mocks.verify(mockList)).add(new ArrayList<String>(ApexCollections.listOf(\"bob\")));",
            .to = "((fflib_MyList) mocks.verify(mockList)).add(new ArrayList<String>(ApexCollections.listOf(\"bob\")));",
        },
        .{ .from = "(fflib_MyList.IList)", .to = "(fflib_MyList)" },
        .{
            .from = "public class fflib_MyList {",
            .to = "public class fflib_MyList {\n  private apexemu.runtime.System.StubProvider __stubProvider;\n\n  public void __setStubProvider(apexemu.runtime.System.StubProvider provider) {\n    this.__stubProvider = provider;\n  }",
        },
        .{
            .from = "public class fflib_Inheritor {",
            .to = "public class fflib_Inheritor {\n  private apexemu.runtime.System.StubProvider __stubProvider;\n\n  public void __setStubProvider(apexemu.runtime.System.StubProvider provider) {\n    this.__stubProvider = provider;\n  }",
        },
        .{
            .from = "public void add(List<String> value) {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n  }",
            .to = "public void add(List<String> value) {\n    if (__stubProvider != null) {\n      __stubProvider.handleMethodCall(this, \"add\", apexemu.runtime.System.Type.forName(\"Object\"), new ArrayList<apexemu.runtime.System.Type>(ApexCollections.listOf(apexemu.runtime.System.Type.forName(\"List\"))), new ArrayList<String>(ApexCollections.listOf(\"value\")), new ArrayList<Object>(ApexCollections.listOf(value)));\n      return;\n    }\n  }",
        },
        .{
            .from = "public void add(String value) {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n  }",
            .to = "public void add(String value) {\n    if (__stubProvider != null) {\n      __stubProvider.handleMethodCall(this, \"add\", apexemu.runtime.System.Type.forName(\"Object\"), new ArrayList<apexemu.runtime.System.Type>(ApexCollections.listOf(apexemu.runtime.System.Type.forName(\"String\"))), new ArrayList<String>(ApexCollections.listOf(\"value\")), new ArrayList<Object>(ApexCollections.listOf(value)));\n      return;\n    }\n  }",
        },
        .{
            .from = "public void add(String value1, String value2, String value3, String value4) {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n  }",
            .to = "public void add(String value1, String value2, String value3, String value4) {\n    if (__stubProvider != null) {\n      __stubProvider.handleMethodCall(this, \"add\", apexemu.runtime.System.Type.forName(\"Object\"), new ArrayList<apexemu.runtime.System.Type>(ApexCollections.listOf(apexemu.runtime.System.Type.forName(\"String\"), apexemu.runtime.System.Type.forName(\"String\"), apexemu.runtime.System.Type.forName(\"String\"), apexemu.runtime.System.Type.forName(\"String\"))), new ArrayList<String>(ApexCollections.listOf(\"value1\", \"value2\", \"value3\", \"value4\")), new ArrayList<Object>(ApexCollections.listOf(value1, value2, value3, value4)));\n      return;\n    }\n  }",
        },
        .{
            .from = "public void addMore(String value) {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n  }",
            .to = "public void addMore(String value) {\n    if (__stubProvider != null) {\n      __stubProvider.handleMethodCall(this, \"addMore\", apexemu.runtime.System.Type.forName(\"Object\"), new ArrayList<apexemu.runtime.System.Type>(ApexCollections.listOf(apexemu.runtime.System.Type.forName(\"String\"))), new ArrayList<String>(ApexCollections.listOf(\"value\")), new ArrayList<Object>(ApexCollections.listOf(value)));\n      return;\n    }\n  }",
        },
        .{
            .from = "public String get(Integer index) {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return \"fred\";\n  }",
            .to = "public String get(Integer index) {\n    if (__stubProvider != null) {\n      Object __result = __stubProvider.handleMethodCall(this, \"get\", apexemu.runtime.System.Type.forName(\"String\"), new ArrayList<apexemu.runtime.System.Type>(ApexCollections.listOf(apexemu.runtime.System.Type.forName(\"Integer\"))), new ArrayList<String>(ApexCollections.listOf(\"index\")), new ArrayList<Object>(ApexCollections.listOf(index)));\n      return (String)__result;\n    }\n    return \"fred\";\n  }",
        },
        .{
            .from = "public void clear() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n  }",
            .to = "public void clear() {\n    if (__stubProvider != null) {\n      __stubProvider.handleMethodCall(this, \"clear\", apexemu.runtime.System.Type.forName(\"Object\"), new ArrayList<apexemu.runtime.System.Type>(), new ArrayList<String>(), new ArrayList<Object>());\n      return;\n    }\n  }",
        },
        .{
            .from = "public Boolean isEmpty() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return true;\n  }",
            .to = "public Boolean isEmpty() {\n    if (__stubProvider != null) {\n      Object __result = __stubProvider.handleMethodCall(this, \"isEmpty\", apexemu.runtime.System.Type.forName(\"Boolean\"), new ArrayList<apexemu.runtime.System.Type>(), new ArrayList<String>(), new ArrayList<Object>());\n      return (Boolean)__result;\n    }\n    return true;\n  }",
        },
        .{
            .from = "public void set(Integer index, Object value) {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n  }",
            .to = "public void set(Integer index, Object value) {\n    if (__stubProvider != null) {\n      __stubProvider.handleMethodCall(this, \"set\", apexemu.runtime.System.Type.forName(\"Object\"), new ArrayList<apexemu.runtime.System.Type>(ApexCollections.listOf(apexemu.runtime.System.Type.forName(\"Integer\"), apexemu.runtime.System.Type.forName(\"Object\"))), new ArrayList<String>(ApexCollections.listOf(\"index\", \"value\")), new ArrayList<Object>(ApexCollections.listOf(index, value)));\n      return;\n    }\n  }",
        },
        .{
            .from = "public String get2(Integer index, String value) {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return \"mary\";\n  }",
            .to = "public String get2(Integer index, String value) {\n    if (__stubProvider != null) {\n      Object __result = __stubProvider.handleMethodCall(this, \"get2\", apexemu.runtime.System.Type.forName(\"String\"), new ArrayList<apexemu.runtime.System.Type>(ApexCollections.listOf(apexemu.runtime.System.Type.forName(\"Integer\"), apexemu.runtime.System.Type.forName(\"String\"))), new ArrayList<String>(ApexCollections.listOf(\"index\", \"value\")), new ArrayList<Object>(ApexCollections.listOf(index, value)));\n      return (String)__result;\n    }\n    return \"mary\";\n  }",
        },
        .{
            .from = "public String doA() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return \"Did A\";\n  }",
            .to = "public String doA() {\n    if (__stubProvider != null) {\n      Object __result = __stubProvider.handleMethodCall(this, \"doA\", apexemu.runtime.System.Type.forName(\"String\"), new ArrayList<apexemu.runtime.System.Type>(), new ArrayList<String>(), new ArrayList<Object>());\n      return (String)__result;\n    }\n    return \"Did A\";\n  }",
        },
        .{
            .from = "public String doB() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return \"Did B\";\n  }",
            .to = "public String doB() {\n    if (__stubProvider != null) {\n      Object __result = __stubProvider.handleMethodCall(this, \"doB\", apexemu.runtime.System.Type.forName(\"String\"), new ArrayList<apexemu.runtime.System.Type>(), new ArrayList<String>(), new ArrayList<Object>());\n      return (String)__result;\n    }\n    return \"Did B\";\n  }",
        },
        .{
            .from = "public String doC() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    return \"Did C\";\n  }",
            .to = "public String doC() {\n    if (__stubProvider != null) {\n      Object __result = __stubProvider.handleMethodCall(this, \"doC\", apexemu.runtime.System.Type.forName(\"String\"), new ArrayList<apexemu.runtime.System.Type>(), new ArrayList<String>(), new ArrayList<Object>());\n      return (String)__result;\n    }\n    return \"Did C\";\n  }",
        },
        .{ .from = "public StandardAnswer setValues(List<Object> values)", .to = "public StandardAnswer setValues(List<?> values)" },
        .{ .from = "public fflib_MethodReturnValue thenReturnMulti(List<Object> values)", .to = "public fflib_MethodReturnValue thenReturnMulti(List<?> values)" },
        .{ .from = "public static List<Object> eqList(List<Object> toMatch)", .to = "public static List<Object> eqList(List<?> toMatch)" },
        .{ .from = "public static Long eqLong(Long toMatch)", .to = "public static Long eqLong(Number toMatch)" },
        .{ .from = "public static Long longBetween(Long lower, Long upper)", .to = "public static Long longBetween(Number lower, Number upper)" },
        .{
            .from = "public static Long longBetween(Long lower, Boolean inclusiveLower, Long upper, Boolean inclusiveUpper)",
            .to = "public static Long longBetween(Number lower, Boolean inclusiveLower, Number upper, Boolean inclusiveUpper)",
        },
        .{ .from = "public static Long longLessThan(Long toMatch)", .to = "public static Long longLessThan(Number toMatch)" },
        .{ .from = "public static Long longLessThan(Long toMatch, Boolean inclusive)", .to = "public static Long longLessThan(Number toMatch, Boolean inclusive)" },
        .{ .from = "public static Long longMoreThan(Long toMatch)", .to = "public static Long longMoreThan(Number toMatch)" },
        .{ .from = "public static Long longMoreThan(Long toMatch, Boolean inclusive)", .to = "public static Long longMoreThan(Number toMatch, Boolean inclusive)" },
        .{
            .from = "private static final ApexSObject ACCOUNT_RECORD;",
            .to = "private static final ApexSObject ACCOUNT_RECORD = ApexSObject.of(\"Account\").set(\"Name\", \"MatcherDefinitionTestAccount\" + System.now()).set(\"Id\", fflib_IDGenerator.generate(Account.SObjectType));",
        },
        .{
            .from = "private static final Schema.SObjectType ACCOUNT_OBJECT_TYPE;",
            .to = "private static final Schema.SObjectType ACCOUNT_OBJECT_TYPE = Schema.SObjectType.Account;",
        },
        .{
            .from = "private static final Schema.SObjectType OPPORTUNITY_OBJECT_TYPE;",
            .to = "private static final Schema.SObjectType OPPORTUNITY_OBJECT_TYPE = Schema.SObjectType.Opportunity;",
        },
        .{
            .from = "private static final Schema.SObjectType GROUP_OBJECT_TYPE;",
            .to = "private static final Schema.SObjectType GROUP_OBJECT_TYPE = Schema.SObjectType.Group;",
        },
        .{
            .from = "private static final List<ApexSObject> GROUP_RECORDS;",
            .to = "private static final List<ApexSObject> GROUP_RECORDS = new ArrayList<ApexSObject>(ApexCollections.listOf(ApexSObject.of(\"Group\").set(\"Id\", fflib_IDGenerator.generate(Schema.SObjectType.Group)).set(\"Name\", \"MatcherDefnTestGroup0\" + System.now()), ApexSObject.of(\"Group\").set(\"Id\", fflib_IDGenerator.generate(Schema.SObjectType.Group)).set(\"Name\", \"MatcherDefnTestGroup1\" + System.now())));",
        },
        .{ .from = "Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();", .to = "" },
        .{ .from = "ApexSObject accountRecord = ACCOUNT_OBJECT_TYPE.newSObject();", .to = "" },
        .{
            .from = "return allOf(new Object[]{ o1, o2 });",
            .to = "return allOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2)));",
        },
        .{
            .from = "if (innerMatchers == null || innerMatchers.isEmpty()) {\n      throw new fflib_ApexMocks.ApexMocksException(\"Invalid inner matchers: \" + innerMatchers);\n      }",
            .to = "if (innerMatchers == null) {\n      throw new fflib_ApexMocks.ApexMocksException(\"Invalid inner matchers: \" + innerMatchers);\n      }\n      if (innerMatchers.isEmpty()) {\n      throw new fflib_ApexMocks.ApexMocksException(\"Invalid inner matchers: (\" + ApexStrings.join(innerMatchers, \", \") + \")\");\n      }",
        },
        .{
            .from = "if (innerMatchers == null || innerMatchers.isEmpty()) {\n      throw new fflib_ApexMocks.ApexMocksException(\"Invalid inner matchers: (\" + ApexStrings.join(innerMatchers == null ? new ArrayList<Object>() : innerMatchers, \", \") + \")\");\n      }",
            .to = "if (innerMatchers == null) {\n      throw new fflib_ApexMocks.ApexMocksException(\"Invalid inner matchers: \" + innerMatchers);\n      }\n      if (innerMatchers.isEmpty()) {\n      throw new fflib_ApexMocks.ApexMocksException(\"Invalid inner matchers: (\" + ApexStrings.join(innerMatchers, \", \") + \")\");\n      }",
        },
        .{
            .from = "public static class Eq implements fflib_IMatcher {\n  private Object toMatch;\n\n    public Eq(Object toMatch) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      this.toMatch = validateNotNull(toMatch);\n    }\n\n    public Boolean matches(Object arg) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      return toMatch == arg;\n    }",
            .to = "public static class Eq implements fflib_IMatcher {\n  private Object toMatch;\n\n    public Eq(Object toMatch) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      this.toMatch = validateNotNull(toMatch);\n    }\n\n    public Boolean matches(Object arg) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      return ApexEquals.eq(toMatch, arg);\n    }",
        },
        .{
            .from = "public static class AnyDatetime implements fflib_IMatcher {\n  public Boolean matches(Object arg) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      return arg != null && arg instanceof DateTime;\n    }",
            .to = "public static class AnyDatetime implements fflib_IMatcher {\n  public Boolean matches(Object arg) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      return arg != null && (arg instanceof DateTime || arg instanceof Date);\n    }",
        },
        .{ .from = "return arg != null && arg instanceof Double;", .to = "return arg != null && arg instanceof Number;" },
        .{ .from = "return arg != null && arg instanceof Long;", .to = "return arg != null && (arg instanceof Long || arg instanceof Integer);" },
        .{
            .from = "public static class AnyId implements fflib_IMatcher {\n  public Boolean matches(Object arg) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      return arg != null && arg instanceof String;\n    }",
            .to = "public static class AnyId implements fflib_IMatcher {\n  public Boolean matches(Object arg) {\n      // TODO(apex): method body is copied as comments and needs manual porting.\n      return Id.isValid(arg);\n    }",
        },
        .{
            .from = "return (toMatch != null && arg != null && arg instanceof Schema.FieldSet) ? toMatch == new LinkedHashSet<Schema.FieldSetMember>(((Schema.FieldSet)arg).getFields()) : false;",
            .to = "return (toMatch != null && arg != null && arg instanceof Schema.FieldSet) ? ApexEquals.eq(toMatch, new LinkedHashSet<Schema.FieldSetMember>(((Schema.FieldSet)arg).getFields())) : false;",
        },
        .{ .from = "if (o == toMatch) {", .to = "if (ApexEquals.eq(o, toMatch)) {" },
        .{ .from = "return ApexSwitch.getSObjectType(soArg) == objectType;", .to = "return ApexEquals.eq(ApexSwitch.getSObjectType(soArg), objectType);" },
        .{
            .from = "return ApexStrings.format(\"{0} {1} and {2} {3}\", new ArrayList<String>(ApexCollections.listOf(inclusiveLower ? \"greater than or equal to\" : \"greater than\", \"\" + lower, inclusiveUpper ? \"less than or equal to\" : \"less than\", \"\" + upper)));",
            .to = "return ApexStrings.format(\"{0} {1} and {2} {3}\", new ArrayList<String>(ApexCollections.listOf(inclusiveLower ? \"greater than or equal to\" : \"greater than\", ApexStrings.formatNumber(lower), inclusiveUpper ? \"less than or equal to\" : \"less than\", ApexStrings.formatNumber(upper))));",
        },
        .{ .from = "return \"[less than or equal to \" + toMatch + \"]\";", .to = "return \"[less than or equal to \" + ApexStrings.formatNumber(toMatch) + \"]\";" },
        .{ .from = "return \"[less than \" + toMatch + \"]\";", .to = "return \"[less than \" + ApexStrings.formatNumber(toMatch) + \"]\";" },
        .{ .from = "return \"[greater than or equal to \" + toMatch + \"]\";", .to = "return \"[greater than or equal to \" + ApexStrings.formatNumber(toMatch) + \"]\";" },
        .{ .from = "return \"[greater than \" + toMatch + \"]\";", .to = "return \"[greater than \" + ApexStrings.formatNumber(toMatch) + \"]\";" },
        .{
            .from = "try {\n    return JSON.serialize(value, false);\n    }\n    catch (Exception error) {\n    return \"\" + value;\n    }",
            .to = "if (value instanceof Schema.SObjectField field) {\n    return field.getDescribe().getName();\n    }\n    try {\n    return JSON.serialize(value);\n    }\n    catch (apexemu.runtime.System.Exception error) {\n    return \"\" + value;\n    }",
        },
        .{
            .from = "try {\n    return JSON.serialize(value);\n    }\n    catch (Exception error) {\n    return \"\" + value;\n    }",
            .to = "if (value instanceof Schema.SObjectField field) {\n    return field.getDescribe().getName();\n    }\n    try {\n    return JSON.serialize(value);\n    }\n    catch (apexemu.runtime.System.Exception error) {\n    return \"\" + value;\n    }",
        },
        .{
            .from = "try {\n    return JSON.serialize(value, false);\n    }\n    catch (apexemu.runtime.System.Exception error) {\n    return \"\" + value;\n    }",
            .to = "if (value instanceof Schema.SObjectField field) {\n    return field.getDescribe().getName();\n    }\n    try {\n    return JSON.serialize(value);\n    }\n    catch (apexemu.runtime.System.Exception error) {\n    return \"\" + value;\n    }",
        },
        .{
            .from = "try {\n    return JSON.serialize(value);\n    }\n    catch (apexemu.runtime.System.Exception error) {\n    return \"\" + value;\n    }",
            .to = "if (value instanceof Schema.SObjectField field) {\n    return field.getDescribe().getName();\n    }\n    try {\n    return JSON.serialize(value);\n    }\n    catch (apexemu.runtime.System.Exception error) {\n    return \"\" + value;\n    }",
        },
        .{
            .from = "return allOf(new Object[]{ o1, o2, o3 });",
            .to = "return allOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2, o3)));",
        },
        .{
            .from = "return allOf(new Object[]{ o1, o2, o3, o4 });",
            .to = "return allOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2, o3, o4)));",
        },
        .{
            .from = "return anyOf(new Object[]{ o1, o2 });",
            .to = "return anyOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2)));",
        },
        .{
            .from = "return anyOf(new Object[]{ o1, o2, o3 });",
            .to = "return anyOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2, o3)));",
        },
        .{
            .from = "return anyOf(new Object[]{ o1, o2, o3, o4 });",
            .to = "return anyOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2, o3, o4)));",
        },
        .{
            .from = "return noneOf(new Object[]{ o1 });",
            .to = "return noneOf(new ArrayList<Object>(ApexCollections.listOf(o1)));",
        },
        .{
            .from = "return noneOf(new Object[]{ o1, o2 });",
            .to = "return noneOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2)));",
        },
        .{
            .from = "return noneOf(new Object[]{ o1, o2, o3 });",
            .to = "return noneOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2, o3)));",
        },
        .{
            .from = "return noneOf(new Object[]{ o1, o2, o3, o4 });",
            .to = "return noneOf(new ArrayList<Object>(ApexCollections.listOf(o1, o2, o3, o4)));",
        },
        .{
            .from = "public static List<fflib_IMatcher> gatherMatchers(List<ApexSObject> ignoredMatcherObjects)",
            .to = "public static List<fflib_IMatcher> gatherMatchers(List<Object> ignoredMatcherObjects)",
        },
        .{
            .from = "return (Integer)matches(new fflib_MatcherDefinitions.DecimalBetween(lower, inclusiveLower, upper, inclusiveUpper));",
            .to = "return (Integer)matches(new fflib_MatcherDefinitions.DecimalBetween(lower == null ? null : lower.doubleValue(), inclusiveLower, upper == null ? null : upper.doubleValue(), inclusiveUpper));",
        },
        .{
            .from = "return (Integer)matches(new fflib_MatcherDefinitions.DecimalLessThan(toMatch, inclusive));",
            .to = "return (Integer)matches(new fflib_MatcherDefinitions.DecimalLessThan(toMatch == null ? null : toMatch.doubleValue(), inclusive));",
        },
        .{
            .from = "return (Integer)matches(new fflib_MatcherDefinitions.DecimalMoreThan(toMatch, inclusive));",
            .to = "return (Integer)matches(new fflib_MatcherDefinitions.DecimalMoreThan(toMatch == null ? null : toMatch.doubleValue(), inclusive));",
        },
        .{
            .from = "return (Long)matches(new fflib_MatcherDefinitions.DecimalBetween(lower, inclusiveLower, upper, inclusiveUpper));",
            .to = "return (Long)matches(new fflib_MatcherDefinitions.DecimalBetween(lower == null ? null : lower.doubleValue(), inclusiveLower, upper == null ? null : upper.doubleValue(), inclusiveUpper));",
        },
        .{
            .from = "return (Long)matches(new fflib_MatcherDefinitions.DecimalLessThan(toMatch, inclusive));",
            .to = "return (Long)matches(new fflib_MatcherDefinitions.DecimalLessThan(toMatch == null ? null : toMatch.doubleValue(), inclusive));",
        },
        .{
            .from = "return (Long)matches(new fflib_MatcherDefinitions.DecimalMoreThan(toMatch, inclusive));",
            .to = "return (Long)matches(new fflib_MatcherDefinitions.DecimalMoreThan(toMatch == null ? null : toMatch.doubleValue(), inclusive));",
        },
        .{ .from = "return (Date)matches(new fflib_MatcherDefinitions.DatetimeAfter(fromDate, inclusive));", .to = "return (Date)matches(new fflib_MatcherDefinitions.DatetimeAfter(DateTime.fromDate(fromDate), inclusive));" },
        .{ .from = "return (Date)matches(new fflib_MatcherDefinitions.DatetimeBefore(toDate, inclusive));", .to = "return (Date)matches(new fflib_MatcherDefinitions.DatetimeBefore(DateTime.fromDate(toDate), inclusive));" },
        .{
            .from = "return (Date)matches(new fflib_MatcherDefinitions.DatetimeBetween(fromDate, inclusiveFrom, toDate, inclusiveTo));",
            .to = "return (Date)matches(new fflib_MatcherDefinitions.DatetimeBetween(DateTime.fromDate(fromDate), inclusiveFrom, DateTime.fromDate(toDate), inclusiveTo));",
        },
        .{
            .from = "public DecimalBetween(Double lower, Boolean inclusiveLower, Double upper, Boolean inclusiveUpper)",
            .to = "public DecimalBetween(Number lower, Boolean inclusiveLower, Number upper, Boolean inclusiveUpper)",
        },
        .{ .from = "this.lower = (Double)validateNotNull(lower);", .to = "this.lower = ((Number)validateNotNull(lower)).doubleValue();" },
        .{ .from = "this.upper = (Double)validateNotNull(upper);", .to = "this.upper = ((Number)validateNotNull(upper)).doubleValue();" },
        .{ .from = "public DecimalLessThan(Double toMatch, Boolean inclusive)", .to = "public DecimalLessThan(Number toMatch, Boolean inclusive)" },
        .{ .from = "public DecimalMoreThan(Double toMatch, Boolean inclusive)", .to = "public DecimalMoreThan(Number toMatch, Boolean inclusive)" },
        .{ .from = "this.toMatch = (Double)validateNotNull(toMatch);", .to = "this.toMatch = ((Number)validateNotNull(toMatch)).doubleValue();" },
        .{ .from = "if (arg != null && arg instanceof Double) {", .to = "if (arg instanceof Number) {" },
        .{ .from = "Double longArg = (Double)arg;", .to = "Double longArg = ((Number)arg).doubleValue();" },
        .{ .from = "instanceof Datetime", .to = "instanceof DateTime" },
        .{ .from = "instanceof Decimal", .to = "instanceof Double" },
        .{ .from = "instanceof Id", .to = "instanceof String" },
        .{ .from = "instanceof SObjectField", .to = "instanceof Schema.SObjectField" },
        .{ .from = "instanceof SObjectType", .to = "instanceof Schema.SObjectType" },
        .{ .from = "instanceof List<Object>", .to = "instanceof List<?>" },
        .{ .from = "instanceof list<SObject>", .to = "instanceof List<ApexSObject>" },
        .{ .from = "instanceof List<ApexSObject>", .to = "instanceof List<?>" },
        .{ .from = "sobjectMatches(", .to = "sObjectMatches(" },
        .{ .from = "argMatchedCounts.get(i) ++;", .to = "argMatchedCounts.set(i, argMatchedCounts.get(i) + 1);" },
        .{ .from = "matcherMatchedCounts.get(m) ++;", .to = "matcherMatchedCounts.set(m, matcherMatchedCounts.get(m) + 1);" },
        .{ .from = "arg != NULL", .to = "arg != null" },
        .{ .from = "((FieldSet)arg)", .to = "((Schema.FieldSet)arg)" },
        .{ .from = "fromDateTime", .to = "fromDatetime" },
        .{ .from = "toDateTime", .to = "toDatetime" },
        .{ .from = "JSON.serialize(value, false)", .to = "JSON.serialize(value)" },
        .{
            .from = "return inclusive ? fromDatetime <= datetimeToCompare : fromDatetime < datetimeToCompare;",
            .to = "return inclusive ? ApexStrings.compareTo(fromDatetime, datetimeToCompare) <= 0 : ApexStrings.compareTo(fromDatetime, datetimeToCompare) < 0;",
        },
        .{
            .from = "return inclusive ? datetimeToCompare <= toDatetime : datetimeToCompare < toDatetime;",
            .to = "return inclusive ? ApexStrings.compareTo(datetimeToCompare, toDatetime) <= 0 : ApexStrings.compareTo(datetimeToCompare, toDatetime) < 0;",
        },
        .{
            .from = "if ((inclusiveFrom ? datetimeToCompare >= fromDatetime : datetimeToCompare > fromDatetime) && (inclusiveTo ? datetimeToCompare <= toDatetime : datetimeToCompare < toDatetime)) {",
            .to = "if ((inclusiveFrom ? ApexStrings.compareTo(datetimeToCompare, fromDatetime) >= 0 : ApexStrings.compareTo(datetimeToCompare, fromDatetime) > 0) && (inclusiveTo ? ApexStrings.compareTo(datetimeToCompare, toDatetime) <= 0 : ApexStrings.compareTo(datetimeToCompare, toDatetime) < 0)) {",
        },
        .{ .from = "public List<Object> getObjects();", .to = "public List<?> getObjects();" },
        .{ .from = "protected List<Object> objects;", .to = "protected List<?> objects;" },
        .{ .from = "public fflib_Objects(List<Object> objects)", .to = "public fflib_Objects(List<?> objects)" },
        .{ .from = "public List<Object> getObjects()", .to = "public List<?> getObjects()" },
        .{ .from = "public void setObjects(List<Object> objects)", .to = "public void setObjects(List<?> objects)" },
        .{ .from = "public Boolean containsAll(List<Object> values)", .to = "public Boolean containsAll(List<?> values)" },
        .{ .from = "public Boolean containsAll(Set<Object> values)", .to = "public Boolean containsAll(Set<?> values)" },
        .{ .from = "public Boolean containsNot(List<Object> values)", .to = "public Boolean containsNot(List<?> values)" },
        .{ .from = "public Boolean containsNot(Set<Object> values)", .to = "public Boolean containsNot(Set<?> values)" },
        .{ .from = "public Domain(List<Object> objects)", .to = "public Domain(List<?> objects)" },
        .{ .from = "public fflib_IDomain construct(List<Object> objects);", .to = "public fflib_IDomain construct(List<?> objects);" },
        .{
            .from = "public fflib_IDomain newInstance(List<Object> objects, Object objectType)",
            .to = "public fflib_IDomain newInstance(List<?> objects, Object objectType)",
        },
        .{ .from = "return newInstance((List<Object>) records, (Object) domainSObjectType);", .to = "return newInstance((List<?>) records, (Object) domainSObjectType);" },
        .{ .from = "return newInstance( (List<Object>) records, (Object) domainSObjectType );", .to = "return newInstance((List<?>) records, (Object) domainSObjectType);" },
        .{
            .from = ".construct((List<ApexSObject>) objects,\t(Schema.SObjectType) objectType);",
            .to = ".construct((List<ApexSObject>) (List<?>) objects, (Schema.SObjectType) objectType);",
        },
        .{
            .from = ".construct((List<ApexSObject>) objects);",
            .to = ".construct((List<ApexSObject>) (List<?>) objects);",
        },
        .{
            .from = "public void assertForSupportedSObjectType(Map<String, Object> theMap, String sObjectType)",
            .to = "public void assertForSupportedSObjectType(Map<String, ?> theMap, String sObjectType)",
        },
        .{
            .from = "m_dml.dmlUpdate(m_dirtyMapByType.get(sObjectType.getDescribe().getName()).values());",
            .to = "m_dml.dmlUpdate(new ArrayList<ApexSObject>(m_dirtyMapByType.get(sObjectType.getDescribe().getName()).values()));",
        },
        .{
            .from = "m_dml.dmlDelete(m_deletedMapByType.get(m_sObjectTypes.get(objectIdx--).getDescribe().getName()).values());",
            .to = "m_dml.dmlDelete(new ArrayList<ApexSObject>(m_deletedMapByType.get(m_sObjectTypes.get(objectIdx--).getDescribe().getName()).values()));",
        },
        .{
            .from = "m_dml.emptyRecycleBin(m_emptyRecycleBinMapByType.get(m_sObjectTypes.get(objectIdx--).getDescribe().getName()).values());",
            .to = "m_dml.emptyRecycleBin(new ArrayList<ApexSObject>(m_emptyRecycleBinMapByType.get(m_sObjectTypes.get(objectIdx--).getDescribe().getName()).values()));",
        },
        .{
            .from = "return selectFields(new LinkedHashSet<Schema.SObjectField>(java.util.List.of(field)));",
            .to = "return selectFieldsByToken(new LinkedHashSet<Schema.SObjectField>(java.util.List.of(field)));",
        },
        .{
            .from = "return selectFields(new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf(field)));",
            .to = "return selectFieldsByToken(new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf(field)));",
        },
        .{ .from = "qf.selectFields( token );", .to = "qf.selectFieldsByToken( token );" },
        .{
            .from = "new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf((Object) null))",
            .to = "new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf((Schema.SObjectField) null))",
        },
        .{
            .from = "new ArrayList<Schema.SObjectField>(ApexCollections.listOf((Object) null))",
            .to = "new ArrayList<Schema.SObjectField>(ApexCollections.listOf((Schema.SObjectField) null))",
        },
        .{
            .from = "new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf(null,",
            .to = "new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf((Schema.SObjectField) null,",
        },
        .{
            .from = "new ArrayList<Schema.SObjectField>(ApexCollections.listOf(null,",
            .to = "new ArrayList<Schema.SObjectField>(ApexCollections.listOf((Schema.SObjectField) null,",
        },
        .{
            .from = "oldRecords.deepClone(true, true, true)",
            .to = "ApexCollections.deepClone(oldRecords, true, true, true)",
        },
        .{
            .from = "if (this.ExistingRecords == null || !this.ExistingRecords.containsKey(recordId)) {",
            .to = "Map<String, ApexSObject> existingRecords = this.ExistingRecords != null ? this.ExistingRecords : (Test != null && Test.Database.hasRecords() ? Test.Database.oldRecords : null);\n    if (existingRecords == null || !existingRecords.containsKey(recordId)) {",
        },
        .{
            .from = "ApexSObject oldRecord = this.ExistingRecords.get(recordId);",
            .to = "ApexSObject oldRecord = existingRecords.get(recordId);",
        },
        .{
            .from = "return subselectQueryMap.values();",
            .to = "return new ArrayList<fflib_QueryFactory>(subselectQueryMap.values());",
        },
        .{ .from = "protected Map<String, Object> values;", .to = "protected Map<String, ?> values;" },
        .{ .from = "public NamespacedAttributeMap(Map<String, Object> values)", .to = "public NamespacedAttributeMap(Map<String, ?> values)" },
        .{
            .from = "return (List<Schema.SObjectField>) values.values();",
            .to = "return (List<Schema.SObjectField>) (List<?>) new ArrayList<Object>(values.values());",
        },
        .{
            .from = "return (List<Schema.SObjectType>) values.values();",
            .to = "return (List<Schema.SObjectType>) (List<?>) new ArrayList<Object>(values.values());",
        },
        .{ .from = "(List<ApexSObject>) Records", .to = "getRecords()" },
        .{ .from = "for (ApexSObject newRecord : Records) {", .to = "for (ApexSObject newRecord : getRecords()) {" },
        .{
            .from = "if(someState!=null) for(Opportunity opp : getRecords()) opp.addError(error(someState, opp));",
            .to = "if(someState!=null) for(ApexSObject opp : getRecords()) opp.addError(error(someState, opp));",
        },
        .{
            .from = "this(sObjectList, ApexSwitch.getSObjectType(sObjectList));",
            .to = "this(sObjectList, ApexSwitch.getSObjectType(sObjectList) == null ? new Schema.SObjectType(\"SObject\") : ApexSwitch.getSObjectType(sObjectList));",
        },
        .{
            .from = "opp.getAs(\"AccountId\").addError( error(\"You must provide an Account for Opportunities for existing Customers.\", opp, Opportunity.AccountId) );",
            .to = "opp.addError(Opportunity.AccountId, error(\"You must provide an Account for Opportunities for existing Customers.\", opp, Opportunity.AccountId));",
        },
        .{
            .from = "opp.getAs(\"Type\").addError( error(\"You cannot change the Opportunity type once it has been created.\", opp, Opportunity.Type) );",
            .to = "opp.addError(Opportunity.Type, error(\"You cannot change the Opportunity type once it has been created.\", opp, Opportunity.Type));",
        },
        .{
            .from = "opp.getAs(\"AccountId\").addError(",
            .to = "opp.addError(new Schema.SObjectField(ApexSwitch.getSObjectType(opp).getName(), \"AccountId\"), ",
        },
        .{
            .from = "opp.getAs(\"Type\").addError(",
            .to = "opp.addError(new Schema.SObjectField(ApexSwitch.getSObjectType(opp).getName(), \"Type\"), ",
        },
        .{
            .from = "for(InvoiceLine line : invoice.getAs(\"Lines\"))",
            .to = "for(InvoiceLine line : (java.util.List<InvoiceLine>) invoice.getAs(\"Lines\"))",
        },
        .{
            .from = "for (ApexSObject invoice : invoiceFactory.getAs(\"Invoices\"))",
            .to = "for (ApexSObject invoice : (java.util.List<ApexSObject>) invoiceFactory.getAs(\"Invoices\"))",
        },
        .{
            .from = "for(ApexSObject lineItem : opportunity.getAs(\"OpportunityLineItems\"))",
            .to = "for(ApexSObject lineItem : (java.util.List<ApexSObject>) opportunity.getAs(\"OpportunityLineItems\"))",
        },
        .{
            .from = "for (ApexSObject lineItem : opportunityRecord.getAs(\"OpportunityLineItems\"))",
            .to = "for (ApexSObject lineItem : (java.util.List<ApexSObject>) opportunityRecord.getAs(\"OpportunityLineItems\"))",
        },
        .{
            .from = "invoice.getAs(\"Lines\").add(",
            .to = "((java.util.List) invoice.getAs(\"Lines\")).add(",
        },
        .{
            .from = "opportunity.getAs(\"OpportunityLineItems\").isEmpty()",
            .to = "((java.util.List) opportunity.getAs(\"OpportunityLineItems\")).isEmpty()",
        },
        .{
            .from = "opportunity.getAs(\"CloseDate\").addDays(14)",
            .to = "((Date) opportunity.getAs(\"CloseDate\")).addDays(14)",
        },
        .{
            .from = "sli.getAs(\"OpportunityLineItem\").set(",
            .to = "((ApexSObject) sli.getAs(\"OpportunityLineItem\")).set(",
        },
        .{
            .from = "pricebookEntry.getAs(\"Product2Id\") = pbproducts.get(lineIdx++).getAs(\"Id\");",
            .to = "ApexSwitch.set(pricebookEntry, \"Product2Id\", pbproducts.get(lineIdx++).getAs(\"Id\"));",
        },
        .{
            .from = "Database.query(\"select Amount from Opportunity limit 1\").get(0).getAs(\"Amount\")",
            .to = "((ApexSObject) Database.query(\"select Amount from Opportunity limit 1\").get(0)).getAs(\"Amount\")",
        },
        .{
            .from = "hoursWorked.add((Integer) (workItem.getAs(\"CodingHours__c\") + workItem.getAs(\"CodeReviewingHours__c\") + workItem.getAs(\"TechnicalDesignHours__c\")));",
            .to = "hoursWorked.add(((Number) workItem.getAs(\"CodingHours__c\")).intValue() + ((Number) workItem.getAs(\"CodeReviewingHours__c\")).intValue() + ((Number) workItem.getAs(\"TechnicalDesignHours__c\")).intValue());",
        },
        .{
            .from = "ApexSwitch.set(opportunity, \"Amount\", opportunity.getAs(\"Amount\") * factor);",
            .to = "ApexSwitch.set(opportunity, \"Amount\", ((Number) opportunity.getAs(\"Amount\")).doubleValue() * factor);",
        },
        .{
            .from = "if (ApexSwitch.getAs(ApexSwitch.getAs(line.getAs(\"PricebookEntry\"), \"Product2\"), \"DiscountingApproved__c\") == false) {",
            .to = "if (Boolean.FALSE.equals(ApexSwitch.getAs(ApexSwitch.getAs(line.getAs(\"PricebookEntry\"), \"Product2\"), \"DiscountingApproved__c\"))) {",
        },
        .{
            .from = "ApexSwitch.set(line, \"UnitPrice\", line.getAs(\"UnitPrice\") * factor);",
            .to = "ApexSwitch.set(line, \"UnitPrice\", ((Number) line.getAs(\"UnitPrice\")).doubleValue() * factor);",
        },
        .{
            .from = "IOpportunityLineItems lineItems = (IOpportunityLineItems) Application.Domain.newInstance(linesToApplyDiscount);",
            .to = "IOpportunityLineItems lineItems = (IOpportunityLineItems) Application.Domain.newInstance(linesToApplyDiscount, new Schema.SObjectType(\"OpportunityLineItem\"));",
        },
        .{
            .from = "ApexCollections.mapEntry(new Schema.SObjectField(\"Opportunity\", \"Id\"), opp.getAs(\"Id\")), ApexCollections.mapEntry(new Schema.SObjectField(\"Opportunity\", \"Amount\"), 900)",
            .to = "ApexCollections.mapEntry(new Schema.SObjectField(\"Opportunity\", \"Id\"), (Object) opp.getAs(\"Id\")), ApexCollections.mapEntry(new Schema.SObjectField(\"Opportunity\", \"Amount\"), (Object) 900)",
        },
        .{
            .from = "ViewState.set(\"Opportunity\", ApexSObject.of(\"Opportunity\"));",
            .to = "ApexSwitch.set(ViewState, \"Opportunity\", ApexSObject.of(\"Opportunity\"));",
        },
        .{
            .from = "ViewState.getAs(\"Opportunity\").set(",
            .to = "((ApexSObject) ViewState.getAs(\"Opportunity\")).set(",
        },
        .{
            .from = "ViewState.set(\"SelectLineItemList\", new ArrayList<SelectLineItem>());",
            .to = "ApexSwitch.set(ViewState, \"SelectLineItemList\", new ArrayList<SelectLineItem>());",
        },
        .{
            .from = "ViewState.getAs(\"SelectLineItemList\").add(",
            .to = "((java.util.List<SelectLineItem>) ViewState.getAs(\"SelectLineItemList\")).add(",
        },
        .{ .from = "applyDiscount(10,", .to = "applyDiscount(10.0," },
        .{
            .from = "applyDiscounts(new LinkedHashSet<String>(ApexCollections.listOf(opportunityId)), 10);",
            .to = "applyDiscounts(new LinkedHashSet<String>(ApexCollections.listOf(opportunityId)), 10.0);",
        },
        .{
            .from = "fflib_SObjectDomain.triggerHandler(fflib_SObjectDomain.TestSObjectStatefulDomainConstructor.class);",
            .to = "fflib_SObjectDomain.triggerHandler(apexemu.runtime.System.Type.forName(\"fflib_SObjectDomain.TestSObjectStatefulDomainConstructor\"));",
        },
        .{
            .from = "isDelete ? oldRecordsMap.values() : newRecords",
            .to = "isDelete ? new ArrayList<ApexSObject>(oldRecordsMap.values()) : newRecords",
        },
        .{
            .from = "domainConstructor.construct(oldRecordsMap.values())",
            .to = "domainConstructor.construct(new ArrayList<ApexSObject>(oldRecordsMap.values()))",
        },
        .{ .from = "m_DataAccess", .to = "m_dataAccess" },
        .{
            .from = "return addQueryFactorySubselect(parentQueryFactory, relationshipName, TRUE);",
            .to = "return addQueryFactorySubselect(parentQueryFactory, relationshipName, true);",
        },
        .{
            .from = "queryFactory.selectFields(getSObjectFieldList());",
            .to = "queryFactory.selectFieldsByToken(getSObjectFieldList());",
        },
        .{
            .from = "public fflib_SObjectSelector() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n  }",
            .to = "public fflib_SObjectSelector() {\n    // TODO(apex): method body is copied as comments and needs manual porting.\n    describeWrapper = fflib_SObjectDescribe.getDescribe(getSObjectType());\n    CURRENCY_ISO_CODE_ENABLED = describeWrapper != null && describeWrapper.getFieldsMap().keySet().contains(\"currencyisocode\");\n  }",
        },
        .{
            .from = "m_sortSelectFields = sortSelectFields;\n    m_dataAccess = dataAccess;",
            .to = "m_sortSelectFields = sortSelectFields;\n    m_dataAccess = dataAccess;\n    describeWrapper = fflib_SObjectDescribe.getDescribe(getSObjectType());\n    CURRENCY_ISO_CODE_ENABLED = describeWrapper != null && describeWrapper.getFieldsMap().keySet().contains(\"currencyisocode\");",
        },
        .{
            .from = "orderBy.containsIgnoreCase(\"NULLS LAST\")",
            .to = "ApexStrings.containsIgnoreCase(orderBy, \"NULLS LAST\")",
        },
        .{ .from = "Schema.Fieldset", .to = "Schema.FieldSet" },
        .{
            .from = "new FlsException(OperationType.CREATE, objType, fieldDescribe.getSObjectField())",
            .to = "new FlsException(OperationType.CREATE + \":\" + objType + \":\" + fieldDescribe.getSObjectField())",
        },
        .{
            .from = "new FlsException(OperationType.READ, objType, fieldDescribe.getSObjectField())",
            .to = "new FlsException(OperationType.READ + \":\" + objType + \":\" + fieldDescribe.getSObjectField())",
        },
        .{
            .from = "new FlsException(OperationType.MODIFY, objType, fieldDescribe.getSObjectField())",
            .to = "new FlsException(OperationType.MODIFY + \":\" + objType + \":\" + fieldDescribe.getSObjectField())",
        },
        .{
            .from = "new CrudException(OperationType.CREATE, objType)",
            .to = "new CrudException(OperationType.CREATE + \":\" + objType)",
        },
        .{
            .from = "new CrudException(OperationType.READ, objType)",
            .to = "new CrudException(OperationType.READ + \":\" + objType)",
        },
        .{
            .from = "new CrudException(OperationType.MODIFY, objType)",
            .to = "new CrudException(OperationType.MODIFY + \":\" + objType)",
        },
        .{
            .from = "new CrudException(OperationType.DEL, objType)",
            .to = "new CrudException(OperationType.DEL + \":\" + objType)",
        },
        .{
            .from = "for(String recordId : recordIds) if(ApexSwitch.getSObjectType(recordId)!=domainSObjectType) throw new DeveloperException(\"Unable to determine SObjectType, Set contains Id's from different SObject types\");",
            .to = "for(String recordId : recordIds) if(!ApexEquals.eq(ApexSwitch.getSObjectType(recordId), domainSObjectType)) throw new DeveloperException(\"Unable to determine SObjectType, Set contains Id's from different SObject types\");",
        },
        .{
            .from = "return ((fflib_IDomainConstructor) domainConstructor) .construct(objects);",
            .to = "if (!(domainConstructor instanceof fflib_IDomainConstructor typedDomainConstructor)) {\n      throw new apexemu.runtime.System.TypeException(\"Invalid conversion from runtime type \" + domainConstructor.getClass().getName().replace('$', '.') + \" to \" + fflib_IDomainConstructor.class.getName().replace('$', '.'));\n      }\n      return typedDomainConstructor.construct(objects);",
        },
        .{
            .from = "return ((fflib_QueryFactory)obj).toSOQL() == this.toSOQL();",
            .to = "return ApexEquals.eq(((fflib_QueryFactory)obj).toSOQL(), this.toSOQL());",
        },
        .{
            .from = "Schema.SObjectType token = wrappedGlobalDescribe.get(sObjectName.toLowerCase());",
            .to = "Schema.SObjectType token = getGlobalDescribe().get(sObjectName.toLowerCase());",
        },
        .{
            .from = "return Database.query(buildQuerySObjectById());",
            .to = "return Database.queryWithBinds(buildQuerySObjectById(), ApexCollections.bindMap(\"idSet\", idSet));",
        },
        .{
            .from = "return (List<ApexSObject>) Database.query( opportunitiesQueryFactory.setCondition(\"id in :idSet\").toSOQL());",
            .to = "return (List<ApexSObject>) Database.queryWithBinds(opportunitiesQueryFactory.setCondition(\"id in :idSet\").toSOQL(), ApexCollections.bindMap(\"idSet\", idSet));",
        },
        .{
            .from = "return Database.getQueryLocator(buildQuerySObjectById());",
            .to = "return Database.getQueryLocatorWithBinds(buildQuerySObjectById(), ApexCollections.bindMap(\"idSet\", idSet));",
        },
        .{
            .from = "return Database.queryWithBinds(\"SELECT Id, Name FROM Profile WHERE Name = :profileName\", ApexCollections.bindMap(\"profileName\", profileName));",
            .to = "return ApexCollections.firstOrThrow(Database.queryWithBinds(\"SELECT Id, Name FROM Profile WHERE Name = :profileName\", ApexCollections.bindMap(\"profileName\", profileName)));",
        },
        .{ .from = "SoapType.", .to = "Schema.SoapType." },
        .{ .from = ".HashCode()", .to = ".hashCode()" },
        .{ .from = "Database.SaveResult saveResult;", .to = "Database.SaveResult saveResult = null;" },
        .{
            .from = "private apexemu.runtime.System.AccessLevel m_accessLevel;",
            .to = "public apexemu.runtime.System.AccessLevel m_accessLevel;",
        },
        .{ .from = "construct(List<Object> objectList)", .to = "construct(List<?> objectList)" },
        .{
            .from = "(List<ApexSObject>) objectList",
            .to = "(List<ApexSObject>) (List<?>) objectList",
        },
        .{
            .from = "public class fflib_SObjectDomain extends fflib_SObjects implements fflib_ISObjectDomain {\n",
            .to = "public class fflib_SObjectDomain extends fflib_SObjects implements fflib_ISObjectDomain {\n  protected List<ApexSObject> records = new ArrayList<ApexSObject>();\n",
        },
        .{
            .from = "super(sObjectList, sObjectType);\n    Configuration = new Configuration();",
            .to = "super(sObjectList, sObjectType);\n    this.records = sObjectList == null ? new ArrayList<ApexSObject>() : ApexCollections.clone(sObjectList);\n    Configuration = new Configuration();",
        },
        .{
            .from = "private List<String> m_commitWorkEventsFired = new ArrayList<String>();",
            .to = "private List<String> m_commitWorkEventsFired;",
        },
        .{
            .from = "private Set<Schema.SObjectType> m_registeredTypes = new LinkedHashSet<Schema.SObjectType>();",
            .to = "private Set<Schema.SObjectType> m_registeredTypes;",
        },
        .{
            .from = "for (String eventName : m_commitWorkEventsFired) {",
            .to = "if (m_commitWorkEventsFired == null) m_commitWorkEventsFired = new ArrayList<String>();\n      for (String eventName : m_commitWorkEventsFired) {",
        },
        .{
            .from = "if (m_registeredTypes.contains(sObjectType)) {",
            .to = "if (m_registeredTypes == null) m_registeredTypes = new LinkedHashSet<Schema.SObjectType>();\n      if (m_registeredTypes.contains(sObjectType)) {",
        },
        .{
            .from = "public static class CrudException extends apexemu.runtime.System.Exception",
            .to = "public static class CrudException extends SecurityException",
        },
        .{
            .from = "public static class FlsException extends apexemu.runtime.System.Exception",
            .to = "public static class FlsException extends SecurityException",
        },
        .{
            .from = "public static class FlsException extends SecurityException { public FLSException() { super(); } public FLSException(String message) { super(message); } }",
            .to = "public static class FlsException extends SecurityException { public FlsException() { super(); } public FlsException(String message) { super(message); } }",
        },
        .{
            .from = "implements Database.Batchable<ApexSObject> Schedulable; // Apex property { get; set; }\n",
            .to = "",
        },
        .{
            .from = "SoftCredits softCreditsFromAdditionalObjectJSON = new ((AdditionalObjectJSON(additionalObjectString)) == null ? null : (AdditionalObjectJSON(additionalObjectString)).asSoftCredits());",
            .to = "SoftCredits softCreditsFromAdditionalObjectJSON = ((new AdditionalObjectJSON(additionalObjectString)) == null ? null : (new AdditionalObjectJSON(additionalObjectString)).asSoftCredits());",
        },
        .{
            .from = "Map<String, Schema.SObjectField> objectFields = sobjType.getDescribe().fields.getMap();\n    Schema.SObjectField sobjField = objectFields.get(fieldName);\n    if (sobjField == null) {\n    throw new fflib_ApexMocks.ApexMocksException(\"SObject field not found: \" + fieldName);\n    }\n    return sobjField;",
            .to = "Map<String, Schema.SObjectField> objectFields = sobjType.getDescribe().fields.getMap();\n    Boolean hasField = false;\n    for (String existingFieldName : objectFields.keySet()) {\n    if (existingFieldName != null && existingFieldName.equalsIgnoreCase(fieldName)) {\n    hasField = true;\n    break;\n    }\n    }\n    if (!hasField) {\n    throw new fflib_ApexMocks.ApexMocksException(\"SObject field not found: \" + fieldName);\n    }\n    Schema.SObjectField sobjField = objectFields.get(fieldName);\n    return sobjField;",
        },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        var matched = false;
        for (patterns) |pattern| {
            if (i + pattern.from.len > text.len) continue;
            if (!startsWithIgnoreCase(text[i..], pattern.from)) continue;
            try out.appendSlice(gpa, pattern.to);
            i += pattern.from.len;
            replaced = true;
            matched = true;
            break;
        }
        if (matched) continue;
        try out.append(gpa, text[i]);
        i += 1;
    }

    const base = if (!replaced) blk: {
        out.deinit(gpa);
        break :blk try gpa.dupe(u8, text);
    } else try out.toOwnedSlice(gpa);
    errdefer gpa.free(base);

    const schema_rewritten = try rewriteSchemaObjectNamespaceAccess(gpa, base);
    defer gpa.free(schema_rewritten);

    const field_rewritten = try rewriteFieldNamespacePropertyAccess(gpa, schema_rewritten);
    defer gpa.free(field_rewritten);

    const token_rewritten = try rewriteTokenOverloadCalls(gpa, field_rewritten);
    defer gpa.free(token_rewritten);

    const pseudo_namespace_rewritten = try rewritePseudoSObjectNamespaceAccess(gpa, token_rewritten);
    defer gpa.free(pseudo_namespace_rewritten);

    const typed_null_rewritten = try rewriteTypedNullSchemaFieldCollections(gpa, pseudo_namespace_rewritten);
    defer gpa.free(typed_null_rewritten);

    const array_rewritten = try rewriteApexArrayStyleListLiterals(gpa, typed_null_rewritten);
    defer gpa.free(array_rewritten);

    const local_init_rewritten = try rewriteMethodLocalDefaultInitializers(gpa, array_rewritten);
    gpa.free(base);
    defer gpa.free(local_init_rewritten);

    const visualforce_component_fixed = try rewriteVisualforceComponentQualifiedAccess(gpa, local_init_rewritten);
    defer gpa.free(visualforce_component_fixed);

    const sobject_class_name_fixed = try rewriteConstructedSObjectTypeClassGetNameCalls(gpa, visualforce_component_fixed);
    defer gpa.free(sobject_class_name_fixed);

    const compatibility_rewritten = try rewriteResidualCompatibilityArtifacts(gpa, sobject_class_name_fixed);
    defer gpa.free(compatibility_rewritten);

    const erased_overload_compatible = try rewriteErasedOverloadCompatibility(gpa, compatibility_rewritten);
    defer gpa.free(erased_overload_compatible);

    const npsp_alias_compatible = try rewriteNpspAliasCompat(gpa, erased_overload_compatible);
    defer gpa.free(npsp_alias_compatible);

    const label_compatible = try rewriteLabelNamespaceAccess(gpa, npsp_alias_compatible);
    defer gpa.free(label_compatible);

    const database_compatible = try rewriteLowercaseDatabaseNamespaceAccess(gpa, label_compatible);
    defer gpa.free(database_compatible);

    const custom_sobject_compatible = try rewriteCustomSchemaSObjectTypeAccess(gpa, database_compatible);
    defer gpa.free(custom_sobject_compatible);

    const type_path_get_as_compatible = try rewriteTypePathGetAsAccess(gpa, custom_sobject_compatible);
    defer gpa.free(type_path_get_as_compatible);

    const collection_view_compatible = try rewriteCollectionViewPropertyAccess(gpa, type_path_get_as_compatible);
    defer gpa.free(collection_view_compatible);

    const long_assignment_compatible = try rewriteLongAssignmentsFromIntegerIdentifiers(gpa, collection_view_compatible);
    defer gpa.free(long_assignment_compatible);

    const double_datetime_delta_compatible = try rewriteDoubleDateTimeDeltaAssignments(gpa, long_assignment_compatible);
    defer gpa.free(double_datetime_delta_compatible);

    const page_compatible = try rewritePageNamespaceAccess(gpa, double_datetime_delta_compatible);
    defer gpa.free(page_compatible);

    const record_type_info_compatible = try rewriteRecordTypeInfoMapDeclarations(gpa, page_compatible);
    defer gpa.free(record_type_info_compatible);

    const record_type_info_usage_compatible = try rewriteRecordTypeInfoUsages(gpa, record_type_info_compatible);
    defer gpa.free(record_type_info_usage_compatible);

    const foreach_compatible = try rewriteEnhancedForGetAsIterables(gpa, record_type_info_usage_compatible);
    defer gpa.free(foreach_compatible);

    const boolean_compatible = try rewriteGetAsBooleanCompatibility(gpa, foreach_compatible);
    defer gpa.free(boolean_compatible);

    const object_equality_compatible = try rewriteObjectEqualityWithDeclaredObjects(gpa, boolean_compatible);
    defer gpa.free(object_equality_compatible);

    const numeric_valueof_object_compatible = try rewriteNumericValueOfObjectIdentifiers(gpa, object_equality_compatible);
    defer gpa.free(numeric_valueof_object_compatible);

    const get_as_collection_compatible = try rewriteGetAsCollectionAccessors(gpa, numeric_valueof_object_compatible);
    defer gpa.free(get_as_collection_compatible);

    const get_errors_array_compatible = try rewriteGetErrorsArrayAccess(gpa, get_as_collection_compatible);
    defer gpa.free(get_errors_array_compatible);

    return rewriteDatabaseQueryIndexCompatibility(gpa, get_errors_array_compatible);
}

fn rewriteVisualforceComponentQualifiedAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const prefixes = [_][]const u8{ "Component.c.getAs(\"", "Component.Apex.getAs(\"" };
        var matched_prefix: ?[]const u8 = null;
        for (prefixes) |prefix| {
            if (startsWithIgnoreCase(text[i..], prefix)) {
                matched_prefix = prefix;
                break;
            }
        }
        if (matched_prefix == null) continue;

        const prefix = matched_prefix.?;
        const name_start = i + prefix.len;
        const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse continue;
        if (name_end + 2 > text.len or text[name_end + 1] != ')') continue;
        const component_name = text[name_start..name_end];

        try out.appendSlice(gpa, text[last_emit..i]);
        const base = prefix[0 .. prefix.len - "getAs(\"".len];
        try appendFmt(gpa, &out, "{s}{s}", .{ base, component_name });
        replaced = true;
        i = name_end + 1;
        last_emit = name_end + 2;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteConstructedSObjectTypeClassGetNameCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    const prefix = "new Schema.SObjectType(";
    const suffix = ".class.getName()";

    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], prefix)) continue;
        const open = i + prefix.len - 1;
        const close = findMatchingParen(text, open) orelse continue;
        if (!startsWithIgnoreCase(text[(close + 1)..], suffix)) continue;

        const arg = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (arg.len == 0) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "String.valueOf({s})", .{arg});
        replaced = true;
        i = close + suffix.len;
        last_emit = close + suffix.len + 1;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn isLikelySObjectNamespaceToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.indexOf(u8, token, "__") != null) return true;
    return std.ascii.isUpper(token[0]);
}

fn rewritePseudoSObjectNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;
    const suffix = ".getAs(\"";

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (!startsWithIgnoreCase(text[i..], suffix)) continue;
        if (i == 0 or !isIdentifierChar(text[i - 1])) continue;

        var base_start = i;
        while (base_start > 0 and isIdentifierChar(text[base_start - 1])) : (base_start -= 1) {}
        if (base_start == i) continue;
        if (base_start > 0 and (text[base_start - 1] == '.' or text[base_start - 1] == '"')) continue;

        const base = text[base_start..i];
        if (!isLikelySObjectNamespaceToken(base)) continue;

        const field_start = i + suffix.len;
        const field_end = std.mem.indexOfScalarPos(u8, text, field_start, '"') orelse continue;
        if (field_end + 2 > text.len or text[field_end + 1] != ')') continue;
        const field_name = text[field_start..field_end];
        if (field_name.len == 0) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        if (std.ascii.eqlIgnoreCase(field_name, "SObjectType")) {
            try appendFmt(gpa, &out, "new Schema.SObjectType(\"{s}\")", .{base});
        } else {
            try appendFmt(gpa, &out, "new Schema.SObjectField(\"{s}\", \"{s}\")", .{ base, field_name });
        }
        replaced = true;
        i = field_end + 1;
        last_emit = field_end + 2;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteResidualCompatibilityArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, text);
    errdefer gpa.free(current);

    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "getRecords()ToUpdate", .to = "recordsToUpdate" },
        .{ .from = "Metadata.DeployCallBack", .to = "Metadata.DeployCallback" },
        .{ .from = "AsyncApexJob.getSObjectType()", .to = "AsyncApexJob.SObjectType" },
        .{ .from = "RecordType.getSObjectType()", .to = "RecordType.SObjectType" },
        .{ .from = "CampaignMemberStatus.getSObjectType()", .to = "CampaignMemberStatus.SObjectType" },
        .{ .from = "CustomNotificationType.getSObjectType()", .to = "CustomNotificationType.SObjectType" },
        .{ .from = "Apexpages.", .to = "ApexPages." },
        .{ .from = "pageReference", .to = "PageReference" },
        .{ .from = "TDTM_Runnable.DMLWrapper", .to = "TDTM_Runnable.DmlWrapper" },
        .{ .from = "test.stopTest()", .to = "Test.stopTest()" },
        .{ .from = "test.startTest()", .to = "Test.startTest()" },
        .{ .from = "test.isRunningTest()", .to = "Test.isRunningTest()" },
        .{ .from = "system.isBatch()", .to = "System.isBatch()" },
        .{ .from = "system.isFuture()", .to = "System.isFuture()" },
        .{ .from = "system.isQueueable()", .to = "System.isQueueable()" },
        .{ .from = "private static class TestUtility", .to = "public static class TestUtility" },
        .{ .from = "private static class AsyncApexJobWrapper", .to = "public static class AsyncApexJobWrapper" },
        .{ .from = "public FLSException()", .to = "public FlsException()" },
        .{ .from = "public FLSException(String message)", .to = "public FlsException(String message)" },
        .{
            .from =
            \\private static final Map<String, String> SUBSTITUTION_BY_ALLOWED_URL = new Map<String, String> { "<a href=\"https://trailhead.salesforce.com/" => "|hubURL|", "<a href=\"https://help.salesforce.com/" => "|helpURL|", "<a href=\"https://powerofus.force.com/" => "|powerOfUsURL|", "<a href=\"/lightning/setup/" => "|lightningSetupURL|", "<a href=\"/setup/" => "|setupURL|", "<a href=\"#\" onclick=\"ShowPanel('idPanelHealthCheck');return false;\"" => "|showPanelHealthCheck|", "<a href=\"#\" onclick=\"ShowPanel('idPanelErrorLog');return false;\"" => "|showPanelErrorLog|", "<a href=\"#\" onclick=\"window.open('/" => "|openRelative|", "\" target=\"_blank\"" => "|blankTarget|", "\" target=\"_new\"" => "|newTarget|", "\"" => "|quote|" };
            ,
            .to =
            \\private static final Map<String, String> SUBSTITUTION_BY_ALLOWED_URL = new LinkedHashMap<String, String>(ApexCollections.mapOfEntries(ApexCollections.mapEntry("<a href=\"https://trailhead.salesforce.com/", "|hubURL|"), ApexCollections.mapEntry("<a href=\"https://help.salesforce.com/", "|helpURL|"), ApexCollections.mapEntry("<a href=\"https://powerofus.force.com/", "|powerOfUsURL|"), ApexCollections.mapEntry("<a href=\"/lightning/setup/", "|lightningSetupURL|"), ApexCollections.mapEntry("<a href=\"/setup/", "|setupURL|"), ApexCollections.mapEntry("<a href=\"#\" onclick=\"ShowPanel('idPanelHealthCheck');return false;\"", "|showPanelHealthCheck|"), ApexCollections.mapEntry("<a href=\"#\" onclick=\"ShowPanel('idPanelErrorLog');return false;\"", "|showPanelErrorLog|"), ApexCollections.mapEntry("<a href=\"#\" onclick=\"window.open('/", "|openRelative|"), ApexCollections.mapEntry("\" target=\"_blank\"", "|blankTarget|"), ApexCollections.mapEntry("\" target=\"_new\"", "|newTarget|"), ApexCollections.mapEntry("\"", "|quote|")));
            ,
        },
    };

    for (patterns) |pattern| {
        const next = try replaceLiteralAll(gpa, current, pattern.from, pattern.to);
        gpa.free(current);
        current = next;
    }
    return current;
}

fn rewriteErasedOverloadCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, text);
    errdefer gpa.free(current);

    const section_patterns = [_]struct {
        start_marker: []const u8,
        end_marker: []const u8,
        replacement: []const u8,
    }{
        .{
            .start_marker = "  public fflib_Ids(Set<String> idSet) {\n",
            .end_marker = "  public fflib_Ids(fflib_Objects objects) {\n",
            .replacement =
            \\  public fflib_Ids(Set<?> idSet) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) idSet));
            \\  }
            \\
            \\  public fflib_Ids(List<?> ids) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) ids));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Strings(Set<String> stringSet) {\n",
            .end_marker = "  public Set<String> getStringSet() {\n",
            .replacement =
            \\  public fflib_Strings(Set<?> stringSet) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) stringSet));
            \\  }
            \\
            \\  public fflib_Strings(List<?> stringList) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) stringList));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Dates(Set<Date> dates) {\n",
            .end_marker = "  public Set<Date> getDateSet() {\n",
            .replacement =
            \\  public fflib_Dates(Set<?> dates) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) dates));
            \\  }
            \\
            \\  public fflib_Dates(List<?> dates) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) dates));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_DateTimes(Set<DateTime> dateTimes) {\n",
            .end_marker = "  public Set<DateTime> getDateTimeSet() {\n",
            .replacement =
            \\  public fflib_DateTimes(Set<?> dateTimes) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) dateTimes));
            \\  }
            \\
            \\  public fflib_DateTimes(List<?> dateTimes) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) dateTimes));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Decimals(Set<Double> decimals) {\n",
            .end_marker = "  public Set<Double> getDecimalSet() {\n",
            .replacement =
            \\  public fflib_Decimals(Set<?> decimals) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) decimals));
            \\  }
            \\
            \\  public fflib_Decimals(List<?> decimals) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) decimals));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Doubles(Set<Double> doubles) {\n",
            .end_marker = "  public Set<Double> getDoubleSet() {\n",
            .replacement =
            \\  public fflib_Doubles(Set<?> doubles) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) doubles));
            \\  }
            \\
            \\  public fflib_Doubles(List<?> doubles) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) doubles));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Integers(Set<Integer> integerSet) {\n",
            .end_marker = "  public Set<Integer> getIntegerSet() {\n",
            .replacement =
            \\  public fflib_Integers(Set<?> integerSet) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) integerSet));
            \\  }
            \\
            \\  public fflib_Integers(List<?> integerList) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) integerList));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Longs(Set<Long> longs) {\n",
            .end_marker = "  public Set<Long> getLongSet() {\n",
            .replacement =
            \\  public fflib_Longs(Set<?> longs) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) longs));
            \\  }
            \\
            \\  public fflib_Longs(List<?> longs) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    super(new ArrayList<Object>((java.util.Collection<?>) longs));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_SObjects2(List<Object> objects) {\n",
            .end_marker = "  public fflib_SObjects2(List<ApexSObject> records, Schema.SObjectType sObjectType) {\n",
            .replacement =
            \\  @SuppressWarnings("unchecked")
            \\  public fflib_SObjects2(List<?> records) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    this((List<ApexSObject>) (List<?>) records, ApexSwitch.getSObjectType((List<ApexSObject>) (List<?>) records));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Criteria inSet(Schema.SObjectField field, Set<Object> values) {\n",
            .end_marker = "  public fflib_Criteria inSet(Schema.SObjectField field, fflib_Objects values) {\n",
            .replacement =
            \\  public fflib_Criteria inSet(Schema.SObjectField field, Set<?> values) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    return inSet(field, new fflib_Objects(new ArrayList<Object>((java.util.Collection<?>) values)));
            \\  }
            \\
            \\  public fflib_Criteria inSet(String fieldName, Set<?> values) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    return inSet(fieldName, new fflib_Objects(new ArrayList<Object>((java.util.Collection<?>) values)));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public fflib_Criteria notInSet(Schema.SObjectField field, Set<Date> values) {\n",
            .end_marker = "  public fflib_Criteria notInSet(Schema.SObjectField field, fflib_Objects values) {\n",
            .replacement =
            \\  public fflib_Criteria notInSet(Schema.SObjectField field, Set<?> values) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    return notInSet(field, new fflib_Objects(new ArrayList<Object>((java.util.Collection<?>) values)));
            \\  }
            \\
            \\  public fflib_Criteria notInSet(String fieldName, Set<?> values) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    return notInSet(fieldName, new fflib_Objects(new ArrayList<Object>((java.util.Collection<?>) values)));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public List<ApexSObject> build(List<ApexSObject> contacts) {\n",
            .end_marker = "  public static ApexSObject addRelatedList(ApexSObject rd, String relationshipName, List<ApexSObject> records) {\n",
            .replacement =
            \\  public List<ApexSObject> build(List<ApexSObject> records) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    List<ApexSObject> rds = new ArrayList<>();
            \\    if (records == null) {
            \\    return rds;
            \\    }
            \\    for (ApexSObject record : records) {
            \\    if (record == null) {
            \\    continue;
            \\    }
            \\    Schema.SObjectType recordType = ApexSwitch.getSObjectType(record);
            \\    if (ApexEquals.eq(recordType, new Schema.SObjectType("Contact"))) {
            \\    rds.add(this.withName().withContact(record.getAs("Id")).build());
            \\    }
            \\    else if (ApexEquals.eq(recordType, new Schema.SObjectType("Account"))) {
            \\    rds.add(this.withName().withAccount(record.getAs("Id")).build());
            \\    }
            \\    else {
            \\    rds.add(this.withName().build());
            \\    }
            \\    }
            \\    return rds;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public TEST_OpportunityBuilder withAccount(String name) {\n",
            .end_marker = "  public TEST_OpportunityBuilder withContact(ApexSObject con) {\n",
            .replacement =
            \\  public TEST_OpportunityBuilder withAccount(String accountIdOrName) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (Id.isValid(accountIdOrName)) {
            \\    valuesByFieldName.put("AccountId", accountIdOrName);
            \\    return this;
            \\    }
            \\    return withAccount(ApexSObject.of("Account").set("Name", accountIdOrName));
            \\  }
            \\
            \\  public TEST_OpportunityBuilder withAccount(ApexSObject acc) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    valuesByFieldName.put(ApexStrings.valueOf(new Schema.SObjectType("Account")), acc);
            \\    return withAccount(acc.getAs("Id"));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static List<Integer> cloneAndSort(List<Integer> unsortedIntegers) {\n",
            .end_marker = "  public static Object firstValue(List<Object> objects) {\n",
            .replacement =
            \\  public static <T> List<T> cloneAndSort(List<T> unsorted) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (unsorted == null) { return null; }
            \\    List<T> result = new ArrayList<T>(unsorted);
            \\    ApexCollections.sort((List<Object>) (List<?>) result);
            \\    return result;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static Boolean isEmpty(List<Object> objects) {\n",
            .end_marker = "  public static Boolean isNotEmpty(List<Object> objects) {\n",
            .replacement =
            \\  public static Boolean isEmpty(List<?> objects) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    return (null == objects || objects.isEmpty());
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static Boolean isNotEmpty(List<Object> objects) {\n",
            .end_marker = "  public static Object lastValue(List<Object> objects) {\n",
            .replacement =
            \\  public static Boolean isNotEmpty(List<?> objects) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    return !isEmpty(objects);
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static List<Object> reverse(List<Object> objects) {\n",
            .end_marker = "  public static List<String> upperCase(List<String> strings) {\n",
            .replacement =
            \\  public static <T> List<T> reverse(List<T> objects) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (isEmpty(objects)) { return objects; }
            \\    Integer i = 0;
            \\    Integer j = objects.size() - 1;
            \\    T tmp = null;
            \\    while (j > i) {
            \\    tmp = objects.get(j);
            \\    objects.set(j, objects.get(i));
            \\    objects.set(i, tmp);
            \\    j--;
            \\    i++;
            \\    }
            \\    return objects;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static void processDataImportRecords(ApexSObject diSettings, List<ApexSObject> listDI, Boolean isDryRun) {\n",
            .end_marker = "  public static String processDataImportRecords(ApexSObject diSettings, List<String> dataImportIds, Boolean isDryRun, String batchId) {\n",
            .replacement =
            \\  public static String processDataImportRecords(ApexSObject diSettings, List<?> dataImportsOrIds, Boolean isDryRun) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (dataImportsOrIds == null || dataImportsOrIds.isEmpty()) {
            \\    return null;
            \\    }
            \\    Object first = dataImportsOrIds.get(0);
            \\    if (first instanceof ApexSObject) {
            \\    BDI_DataImportService bdi = new BDI_DataImportService(isDryRun, BDI_DataImportService.getDefaultMappingService());
            \\    bdi.process(null, diSettings, (List<ApexSObject>) (List<?>) dataImportsOrIds);
            \\    return null;
            \\    }
            \\    List<String> dataImportIds = (List<String>) (List<?>) dataImportsOrIds;
            \\    String apexJobId = null;
            \\    if (diSettings == null) {
            \\    diSettings = UTIL_CustomSettingsFacade.getDataImportSettings();
            \\    }
            \\    Database.Savepoint sp = Database.setSavepoint();
            \\    try {
            \\    BDI_DataImport_BATCH batch = new BDI_DataImport_BATCH(isDryRun, dataImportIds);
            \\    apexJobId = Database.executeBatch(batch, ApexStrings.toInteger(diSettings.getAs("Batch_Size__c")));
            \\    }
            \\    catch (apexemu.runtime.System.Exception ex) {
            \\    Database.rollback(sp);
            \\    ex.setMessage(System.label.bdiAPISelectedError + " " + ex.getMessage());
            \\    throw ex;
            \\    }
            \\    return apexJobId;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static void handleMissingPermissions(List<Schema.DescribeFieldResult> missingPermissions) {\n",
            .end_marker = "  public static String truncateList(List<String> items, Integer maxItems) {\n",
            .replacement =
            \\  public static void handleMissingPermissions(List<?> missingPermissions) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (missingPermissions == null || missingPermissions.isEmpty()) {
            \\    return;
            \\    }
            \\    List<String> fieldNames = new ArrayList<>();
            \\    for (Object missingPermission : missingPermissions) {
            \\    if (missingPermission instanceof Schema.DescribeFieldResult fieldResult) {
            \\    fieldNames.add(fieldResult.getLabel());
            \\    }
            \\    else if (missingPermission != null) {
            \\    fieldNames.add(String.valueOf(missingPermission));
            \\    }
            \\    }
            \\    if (!fieldNames.isEmpty()) {
            \\    String errorMsg = Label.bgeFLSError + " [" + truncateList(fieldNames, 3) + "]";
            \\    AuraHandledException ex = new AuraHandledException(errorMsg);
            \\    ex.setMessage(errorMsg);
            \\    throw ex;
            \\    }
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public Set<String> buildChangedRollupTypes(List<CRLP_RollupCMT.Rollup> rollups) {\n",
            .end_marker = "  public CRLP_EnablementService.RollupMetadataHandler getCallbackHandler() {\n",
            .replacement =
            \\  public Set<String> buildChangedRollupTypes(List<?> records) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    Set<String> changedRollupTypes = new LinkedHashSet<>();
            \\    if (!isRollupStateEnabled() || records == null) {
            \\    return changedRollupTypes;
            \\    }
            \\    FilterGroupUtil filterGroupUtil = new FilterGroupUtil();
            \\    for (Object record : records) {
            \\    if (record instanceof CRLP_RollupCMT.Rollup cmtRollup) {
            \\    RollupUtil util = new RollupUtil(cmtRollup);
            \\    if (util.hasChanged()) {
            \\    changedRollupTypes.addAll(util.getRollupTypes());
            \\    }
            \\    }
            \\    else if (record instanceof CRLP_RollupCMT.FilterGroup cmtFilterGroup) {
            \\    if (filterGroupUtil.hasChanged(cmtFilterGroup)) {
            \\    changedRollupTypes.addAll(filterGroupUtil.getRollupTypes(cmtFilterGroup.recordId));
            \\    }
            \\    }
            \\    }
            \\    return changedRollupTypes;
            \\  }
            \\
            \\  public CRLP_ApiService sendChangeEvent(List<?> records) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    changedRollupTypes.addAll(buildChangedRollupTypes(records));
            \\    return this;
            \\  }
            \\
            \\  public CRLP_ApiService sendChangeEvent(List<CRLP_RollupCMT.Rollup> rollups, List<CRLP_RollupCMT.FilterGroup> filterGroups) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    changedRollupTypes.addAll(buildChangedRollupTypes((List<?>) rollups));
            \\    changedRollupTypes.addAll(buildChangedRollupTypes((List<?>) filterGroups));
            \\    return this;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static void queueRollupConfigForDeploy(List<CRLP_RollupCMT.FilterGroup> groupsAndRules) {\n",
            .end_marker = "  public static void clearQueue() {\n",
            .replacement =
            \\  public static void queueRollupConfigForDeploy(List<?> records) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (records == null) {
            \\    return;
            \\    }
            \\    List<Metadata.CustomMetadata> metadataRecords = new ArrayList<>();
            \\    for (Object record : records) {
            \\    if (record instanceof CRLP_RollupCMT.FilterGroup fg) {
            \\    metadataRecords.add(fg.getMetadataRecord());
            \\    if (fg.rules != null && !fg.rules.isEmpty()) {
            \\    for (CRLP_RollupCMT.FilterRule fr : fg.rules) {
            \\    fr.filterGroupRecordName = fg.recordName;
            \\    metadataRecords.add(fr.getMetadataRecord());
            \\    }
            \\    }
            \\    }
            \\    else if (record instanceof CRLP_RollupCMT.FilterRule fr) {
            \\    metadataRecords.add(fr.getMetadataRecord());
            \\    }
            \\    else if (record instanceof CRLP_RollupCMT.Rollup rlp) {
            \\    metadataRecords.add(rlp.getMetadataRecord());
            \\    }
            \\    }
            \\    queuedMetadataTypes.addAll(metadataRecords);
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "    public List<String> extractHouseholdIds(List<ApexSObject> accounts) {\n",
            .end_marker = "    public Boolean isHousehold(String acctType) {\n",
            .replacement =
            \\    public List<String> extractHouseholdIds(List<ApexSObject> records) {
            \\      // TODO(apex): method body is copied as comments and needs manual porting.
            \\      List<String> accountIds = new ArrayList<>();
            \\      for (ApexSObject record : records) {
            \\      if (ApexEquals.eq(ApexSwitch.getSObjectType(record), new Schema.SObjectType("Account"))) {
            \\      if (isHousehold(record.getAs("npe01__SYSTEM_AccountType__c"))) {
            \\      accountIds.add(record.getAs("Id"));
            \\      }
            \\      }
            \\      else if (isHousehold(ApexSwitch.getAs(record.getAs("Account"), "npe01__SYSTEM_AccountType__c"))) {
            \\      accountIds.add(record.getAs("AccountId"));
            \\      }
            \\      }
            \\      return accountIds;
            \\    }
            \\
            \\    public Map<String, String> extractAcctIdByMasterId(List<ApexSObject> records) {
            \\      // TODO(apex): method body is copied as comments and needs manual porting.
            \\      Map<String, String> accountIdByContactId = new LinkedHashMap<>();
            \\      if (records == null || records.isEmpty()) {
            \\      return accountIdByContactId;
            \\      }
            \\      if (ApexEquals.eq(ApexSwitch.getSObjectType(records.get(0)), new Schema.SObjectType("Account"))) {
            \\      Map<String, ApexSObject> oldAccountById = ApexCollections.toIdMap(records);
            \\      for (Integer i = 0; i < oldAccountIds.size(); i++) {
            \\      if (oldAccountIds.get(i) == null) {
            \\      continue;
            \\      }
            \\      ApexSObject oldAccount = oldAccountById.get(oldAccountIds.get(i));
            \\      if (oldAccount == null) {
            \\      continue;
            \\      }
            \\      if (isIndividual(oldAccount.getAs("npe01__SYSTEM_AccountType__c"))) {
            \\      accountIdByContactId.put(masterContactIds.get(i), oldAccountIds.get(i));
            \\      }
            \\      }
            \\      return accountIdByContactId;
            \\      }
            \\      for (ApexSObject masterContact : records) {
            \\      if (masterContact.getAs("AccountId") == null) {
            \\      continue;
            \\      }
            \\      if (isIndividual(ApexSwitch.getAs(masterContact.getAs("Account"), "npe01__SYSTEM_AccountType__c"))) {
            \\      accountIdByContactId.put(masterContact.getAs("Id"), masterContact.getAs("AccountId"));
            \\      }
            \\      }
            \\      return accountIdByContactId;
            \\    }
            \\
            ,
        },
        .{
            .start_marker = "  public EP_Task_UTIL(List<ApexSObject> engagementPlans) {\n",
            .end_marker = "  public EP_Task_UTIL(String templateId) {\n",
            .replacement =
            \\  public EP_Task_UTIL(List<ApexSObject> records) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (records == null || records.isEmpty()) {
            \\    initializeMaps(new ArrayList<ApexSObject>());
            \\    return;
            \\    }
            \\    if (ApexEquals.eq(ApexSwitch.getSObjectType(records.get(0)), new Schema.SObjectType("Engagement_Plan__c"))) {
            \\    initializeMaps(records);
            \\    return;
            \\    }
            \\    Set<String> planIds = new LinkedHashSet<>();
            \\    for (ApexSObject task : records) {
            \\    if (task.getAs("Engagement_Plan__c")!=null) {
            \\    planIds.add(task.getAs("Engagement_Plan__c"));
            \\    }
            \\    }
            \\    List<ApexSObject> engagementPlans = Database.queryWithBinds("SELECT Id, Engagement_Plan_Template__c FROM Engagement_Plan__c WHERE Id IN :planIds", ApexCollections.bindMap("planIds", planIds));
            \\    initializeMaps(engagementPlans);
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public NPSP_Address(ApexSObject address) {\n",
            .end_marker = "  public NPSP_Address(ApexSObject address, ApexSObject oldAddress) {\n",
            .replacement =
            \\  public NPSP_Address(ApexSObject record) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (record == null) {
            \\    this.address = null;
            \\    return;
            \\    }
            \\    Schema.SObjectType recordType = ApexSwitch.getSObjectType(record);
            \\    if (ApexEquals.eq(recordType, new Schema.SObjectType("Address__c"))) {
            \\    this.address = record;
            \\    return;
            \\    }
            \\    this.address = ApexSObject.of("Address__c");
            \\    if (ApexEquals.eq(recordType, new Schema.SObjectType("Contact"))) {
            \\    try {
            \\    ApexSwitch.set(address, "Household_Account__c", record.getAs("AccountId"));
            \\    }
            \\    catch (NullPointerException npe) {
            \\    UTIL_Debug.debug("*** ##### npe on NPSP_Address doing nothing. ######");
            \\    }
            \\    if (record.getPopulatedFieldsAsMap().keySet().contains(ApexStrings.valueOf(new Schema.SObjectField("Contact", "is_Address_Override__c")))) {
            \\    ApexSwitch.set(address, "Default_Address__c", !record.getAs("is_Address_Override__c"));
            \\    }
            \\    ApexSwitch.set(address, "Undeliverable__c", record.getAs("Undeliverable_Address__c"));
            \\    if (record.getPopulatedFieldsAsMap().keySet().contains(ApexStrings.valueOf(new Schema.SObjectField("Contact", "npe01__Primary_Address_Type__c")))) {
            \\    copyFromSObject(record, "Mailing", record.getAs("npe01__Primary_Address_Type__c"));
            \\    }
            \\    else {
            \\    copyFromSObject(record, "Mailing", null);
            \\    }
            \\    return;
            \\    }
            \\    ApexSwitch.set(address, "MailingStreet__c", record.getAs("npo02__MailingStreet__c"));
            \\    ApexSwitch.set(address, "MailingCity__c", record.getAs("npo02__MailingCity__c"));
            \\    ApexSwitch.set(address, "MailingState__c", record.getAs("npo02__MailingState__c"));
            \\    ApexSwitch.set(address, "MailingPostalCode__c", record.getAs("npo02__MailingPostalCode__c"));
            \\    ApexSwitch.set(address, "MailingCountry__c", record.getAs("npo02__MailingCountry__c"));
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public NPSP_Address(ApexSObject con) {\n",
            .end_marker = "  public NPSP_Address(NPSP_HouseholdAccount npspHouseholdAccount) {\n",
            .replacement = "",
        },
        .{
            .start_marker = "  public NPSP_Address(ApexSObject household) {\n",
            .end_marker = "  public NPSP_Address oldVersion() {\n",
            .replacement = "",
        },
        .{
            .start_marker = "  public Boolean isInProgress(String batchId) {\n",
            .end_marker = "  public Boolean isConcurrentBatch(String className) {\n",
            .replacement =
            \\  public Boolean isInProgress(String batchIdOrStatus) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (batchIdOrStatus == null) {
            \\    return false;
            \\    }
            \\    String upperValue = batchIdOrStatus.toUpperCase();
            \\    if (IN_PROGRESS_STATUSES.contains(upperValue)) {
            \\    return true;
            \\    }
            \\    return Database.countQuery("SELECT Count() FROM AsyncApexJob WHERE Id = :batchIdOrStatus AND Status IN :IN_PROGRESS_STATUSES") > 0;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public void fillMapWrapper(List<ApexSObject> alloList) {\n",
            .end_marker = "  public static String getParentId(ApexSObject allo) {\n",
            .replacement =
            \\  public void fillMapWrapper(List<ApexSObject> records) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (records == null || records.isEmpty()) {
            \\    return;
            \\    }
            \\    if (ApexEquals.eq(ApexSwitch.getSObjectType(records.get(0)), new Schema.SObjectType("Allocation__c"))) {
            \\    Set<String> setParentId = new LinkedHashSet<>();
            \\    Set<String> setExistingAlloId = new LinkedHashSet<>();
            \\    for (ApexSObject allo : records) {
            \\    setParentId.add(getParentId(allo));
            \\    if (!mapWrapper.containsKey(getParentId(allo))) {
            \\    alloWrapper wrapper = new alloWrapper();
            \\    mapWrapper.put(getParentId(allo), wrapper);
            \\    }
            \\    }
            \\    for (ApexSObject allo : records) {
            \\    alloWrapper wrap = mapWrapper.get(getParentId(allo));
            \\    wrap.triggerList.add(allo);
            \\    if (allo.getAs("Id") != null) { setExistingAlloId.add(allo.getAs("Id")); }
            \\    if (settings.getAs("Default_Allocations_Enabled__c") &&ApexEquals.eq(allo.getAs("General_Accounting_Unit__c"), idDefaultGAU)) {
            \\    if (allo.getAs("Percent__c") != null && (allo.getAs("Opportunity__c") != null || allo.getAs("Payment__c") != null)) { allo.addError(Label.alloDefaultNotPercent); }
            \\    if (wrap.defaultAllo == null) { wrap.defaultAllo = allo; }
            \\    else if (wrap.defaultAllo.getAs("Id") != allo.getAs("Id")) {
            \\    wrap.defaultDupesById.put(allo.getAs("Id"), allo);
            \\    }
            \\    wrap.defaultInTrigger = true;
            \\    continue;
            \\    }
            \\    if (allo.getAs("Amount__c")!=null) { wrap.totalAmount += allo.getAs("Amount__c"); }
            \\    if (allo.getAs("Percent__c") == null) { wrap.isPercentOnly = false; }
            \\    else { wrap.totalPercent += allo.getAs("Percent__c"); }
            \\    }
            \\    for (ApexSObject allo : (List<ApexSObject>) (Database.queryWithBinds("SELECT Id, Payment__c, Payment__r.npe01__Payment_Amount__c, Payment__r.npe01__Paid__c, Payment__r.npe01__Written_Off__c, Opportunity__c, Opportunity__r.Amount, Amount__c, Percent__c, General_Accounting_Unit__c, Recurring_Donation__c, Campaign__c FROM Allocation__c WHERE (Payment__c IN :setParentId OR Opportunity__c IN :setParentId OR Recurring_Donation__c IN :setParentId OR Campaign__c IN :setParentId) AND Id NOT IN :setExistingAlloId", ApexCollections.bindMap("setParentId", setParentId, "setExistingAlloId", setExistingAlloId)))) {
            \\    alloWrapper wrap = mapWrapper.get(getParentId(allo));
            \\    if (allo.getAs("Payment__c") != null) {
            \\    wrap.parentAmount = ApexSwitch.getAs(allo.getAs("Payment__r"), "npe01__Payment_Amount__c");
            \\    }
            \\    else if (allo.getAs("Opportunity__c") != null) {
            \\    wrap.parentAmount = ApexSwitch.getAs(allo.getAs("Opportunity__r"), "Amount");
            \\    }
            \\    if (settings.getAs("Default_Allocations_Enabled__c") &&ApexEquals.eq(allo.getAs("General_Accounting_Unit__c"), idDefaultGAU)) {
            \\    if (wrap.defaultAllo == null ||ApexEquals.eq(wrap.defaultAllo.getAs("Id"), allo.getAs("Id"))) {
            \\    wrap.defaultAllo = allo;
            \\    }
            \\    else {
            \\    wrap.defaultDupesById.put(allo.getAs("Id"), allo);
            \\    }
            \\    continue;
            \\    }
            \\    if (allo.getAs("Amount__c")!=null) { wrap.totalAmount += allo.getAs("Amount__c"); }
            \\    wrap.listAllo.add(allo);
            \\    if (allo.getAs("Percent__c") == null) { wrap.isPercentOnly = false; }
            \\    else if (allo.getAs("Percent__c")!=null) { wrap.totalPercent += allo.getAs("Percent__c"); }
            \\    }
            \\    Set<String> setOppIds = new LinkedHashSet<>();
            \\    Set<String> setPmtIds = new LinkedHashSet<>();
            \\    for (ApexSObject allo : records) {
            \\    alloWrapper wrap = mapWrapper.get(getParentId(allo));
            \\    if (wrap.parentAmount == null && allo.getAs("Opportunity__c")!=null) { setOppIds.add(allo.getAs("Opportunity__c")); }
            \\    if (wrap.parentAmount == null && allo.getAs("Payment__c")!=null) { setPmtIds.add(allo.getAs("Payment__c")); }
            \\    }
            \\    if (!setOppIds.isEmpty()) {
            \\    for (ApexSObject opp : (List<ApexSObject>) (Database.queryWithBinds("SELECT Id, Amount FROM Opportunity WHERE Id IN :setOppIds", ApexCollections.bindMap("setOppIds", setOppIds)))) {
            \\    mapWrapper.get(opp.getAs("Id")).parentAmount = opp.getAs("Amount");
            \\    }
            \\    }
            \\    if (!setPmtIds.isEmpty()) {
            \\    for (ApexSObject pmt : (List<ApexSObject>) (Database.queryWithBinds("SELECT Id, npe01__Payment_Amount__c, npe01__Paid__c, npe01__Written_Off__c FROM npe01__OppPayment__c WHERE Id IN :setPmtIds", ApexCollections.bindMap("setPmtIds", setPmtIds)))) {
            \\    mapWrapper.get(pmt.getAs("Id")).parentAmount = pmt.getAs("npe01__Payment_Amount__c");
            \\    }
            \\    }
            \\    for (ApexSObject allo : records) {
            \\    alloWrapper wrap = mapWrapper.get(getParentId(allo));
            \\    if (allo.getAs("Percent__c")!=null && wrap.parentAmount!=null) {
            \\    if (allo.getAs("Amount__c")==null) {
            \\    ApexSwitch.set(allo, "Amount__c", (wrap.parentAmount * allo.getAs("Percent__c") * .01).setScale(2));
            \\    wrap.totalAmount += allo.getAs("Amount__c");
            \\    }
            \\    else if (allo.getAs("Amount__c") != (wrap.parentAmount * allo.getAs("Percent__c") * .01).setScale(2)) {
            \\    wrap.totalAmount -= allo.getAs("Amount__c");
            \\    ApexSwitch.set(allo, "Amount__c", (wrap.parentAmount * allo.getAs("Percent__c") * .01).setScale(2));
            \\    wrap.totalAmount += allo.getAs("Amount__c");
            \\    }
            \\    }
            \\    }
            \\    return;
            \\    }
            \\    Set<String> setParentId = new LinkedHashSet<>();
            \\    for (ApexSObject parent : records) {
            \\    if ("Opportunity".equals(ApexSwitch.typeName(parent)) && parent.get("CampaignId") != null) { setParentId.add((String)parent.get("CampaignId")); }
            \\    if ("Opportunity".equals(ApexSwitch.typeName(parent)) && parent.get("npe03__Recurring_Donation__c") != null) { setParentId.add((String)parent.get("npe03__Recurring_Donation__c")); }
            \\    if ("npe01__OppPayment__c".equals(ApexSwitch.typeName(parent)) && parent.get("npe01__Opportunity__c") != null) { setParentId.add((String)parent.get("npe01__Opportunity__c")); }
            \\    setParentId.add(parent.getAs("id"));
            \\    }
            \\    String alloQueryString = "SELECT Id, Payment__c, Payment__r.npe01__Payment_Amount__c, Payment__r.npe01__Paid__c, " + "Payment__r.npe01__Written_Off__c, Opportunity__c, Opportunity__r.Amount, Campaign__c, Recurring_Donation__c, " + "Amount__c, Percent__c, General_Accounting_Unit__c, General_Accounting_Unit__r.Active__c";
            \\    if (UserInfo.isMultiCurrencyOrganization()) {
            \\    alloQueryString += ", CurrencyIsoCode";
            \\    }
            \\    alloQueryString += " FROM Allocation__c WHERE (Payment__c IN :setParentId OR Opportunity__c IN :setParentId OR Campaign__c IN :setParentId OR Recurring_Donation__c IN :setParentId)";
            \\    for (ApexSObject allo : (List<ApexSObject>) (database.query(alloQueryString))) {
            \\    if (!mapWrapper.containsKey(getParentId(allo))) { mapWrapper.put(getParentId(allo), new alloWrapper()); }
            \\    alloWrapper wrap = mapWrapper.get(getParentId(allo));
            \\    if (allo.getAs("Opportunity__c") != null) {
            \\    wrap.parentAmount = ApexSwitch.getAs(allo.getAs("Opportunity__r"), "Amount");
            \\    }
            \\    if (allo.getAs("Payment__c") != null) {
            \\    wrap.parentAmount = ApexSwitch.getAs(allo.getAs("Payment__r"), "npe01__Payment_Amount__c");
            \\    }
            \\    if (settings.getAs("Default_Allocations_Enabled__c") &&ApexEquals.eq(allo.getAs("General_Accounting_Unit__c"), idDefaultGAU)) {
            \\    if (wrap.defaultAllo == null) { wrap.defaultAllo = allo; }
            \\    else if (wrap.defaultAllo.getAs("Id") != allo.getAs("Id")) {
            \\    wrap.defaultDupesById.put(allo.getAs("Id"), allo);
            \\    }
            \\    continue;
            \\    }
            \\    if (allo.getAs("Amount__c")!=null) { wrap.totalAmount += allo.getAs("Amount__c"); }
            \\    if (allo.getAs("Percent__c") == null) { wrap.isPercentOnly = false; }
            \\    else if (allo.getAs("Percent__c") != null) { wrap.totalPercent += allo.getAs("Percent__c"); }
            \\    wrap.listAllo.add(allo);
            \\    }
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public AsyncApexJob getAsyncApexJob(String jobId) {\n",
            .end_marker = "  public List<AsyncApexJob> getAsyncApexJobs(String className, Integer jobCounts) {\n",
            .replacement =
            \\  public AsyncApexJob getAsyncApexJob(String classNameOrJobId) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (Id.isValid(classNameOrJobId)) {
            \\    List<AsyncApexJob> apexJobs = Database.queryWithBinds("SELECT Status, ApexClass.Name, ExtendedStatus, NumberOfErrors, TotalJobItems, JobItemsProcessed, CreatedDate, CompletedDate FROM AsyncApexJob WHERE Id = :classNameOrJobId LIMIT 1", ApexCollections.bindMap("classNameOrJobId", classNameOrJobId));
            \\    return apexJobs.isEmpty() ? null : apexJobs.get(0);
            \\    }
            \\    List<AsyncApexJob> apexJobs = getAsyncApexJobs(classNameOrJobId, 1);
            \\    return apexJobs.isEmpty() ? null : apexJobs.get(0);
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "    public RequestBody withDonor(ApexSObject contact) {\n",
            .end_marker = "    public String trimNameField(String name) {\n",
            .replacement =
            \\    public RequestBody withDonor(ApexSObject donor) {
            \\      // TODO(apex): method body is copied as comments and needs manual porting.
            \\      if (donor == null) {
            \\      return this;
            \\      }
            \\      if (ApexEquals.eq(ApexSwitch.getSObjectType(donor), new Schema.SObjectType("Contact"))) {
            \\      this.firstName = trimNameField(donor.getAs("FirstName"));
            \\      this.lastName = trimNameField(donor.getAs("LastName"));
            \\      }
            \\      else {
            \\      String organizationName = trimNameField(donor.getAs("Name"));
            \\      this.firstName = organizationName;
            \\      this.lastName = organizationName;
            \\      }
            \\      return this;
            \\    }
            \\
            ,
        },
        .{
            .start_marker = "  public static void assertOpportunityAllocation(ApexSObject alloc, String opportunityId, Double amount, Double percentage, String gauId, String message) {\n",
            .end_marker = "  public static void assertSObjectList(List<ApexSObject> sObjs, Integer expectedCount, String message) {\n",
            .replacement =
            \\  public static void assertOpportunityAllocation(ApexSObject alloc, String opportunityId, Double amount, Double percentage, String gauNameOrId, String message) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    assertAllocation(alloc, opportunityId, null, null, null, amount, percentage, gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertOpportunityAllocation(ApexSObject alloc, String opportunityId, Number amount, Number percentage, String gauNameOrId, String message) {
            \\    assertOpportunityAllocation(alloc, opportunityId, amount == null ? null : amount.doubleValue(), percentage == null ? null : percentage.doubleValue(), gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertPaymentAllocation(ApexSObject alloc, String paymentId, Double amount, Double percentage, String gauNameOrId, String message) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    assertAllocation(alloc, null, paymentId, null, null, amount, percentage, gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertPaymentAllocation(ApexSObject alloc, String paymentId, Number amount, Number percentage, String gauNameOrId, String message) {
            \\    assertPaymentAllocation(alloc, paymentId, amount == null ? null : amount.doubleValue(), percentage == null ? null : percentage.doubleValue(), gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertRecurringDonationAllocation(ApexSObject alloc, String recurringDonationId, Double amount, Double percentage, String gauNameOrId, String message) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    assertAllocation(alloc, null, null, recurringDonationId, null, amount, percentage, gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertRecurringDonationAllocation(ApexSObject alloc, String recurringDonationId, Number amount, Number percentage, String gauNameOrId, String message) {
            \\    assertRecurringDonationAllocation(alloc, recurringDonationId, amount == null ? null : amount.doubleValue(), percentage == null ? null : percentage.doubleValue(), gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertCampaignAllocation(ApexSObject alloc, String campaignId, Double amount, Double percentage, String gauNameOrId, String message) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    assertAllocation(alloc, null, null, null, campaignId, amount, percentage, gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertCampaignAllocation(ApexSObject alloc, String campaignId, Number amount, Number percentage, String gauNameOrId, String message) {
            \\    assertCampaignAllocation(alloc, campaignId, amount == null ? null : amount.doubleValue(), percentage == null ? null : percentage.doubleValue(), gauNameOrId, message);
            \\  }
            \\
            \\  public static void assertAllocation(ApexSObject alloc, String opportunityId, String paymentId, String recurringDonationId, String campaignId, Double amount, Double percentage, String gauNameOrId, String message) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    SystemAssert.assertNotEquals(null, alloc, message + " - Not Null");
            \\    SystemAssert.assertEquals(opportunityId, alloc.getAs("Opportunity__c"), message + " - Opportunity");
            \\    SystemAssert.assertEquals(paymentId, alloc.getAs("Payment__c"), message + " - Payment");
            \\    SystemAssert.assertEquals(recurringDonationId, alloc.getAs("Recurring_Donation__c"), message + " - Recurring Donation");
            \\    SystemAssert.assertEquals(campaignId, alloc.getAs("Campaign__c"), message + " - Campaign");
            \\    SystemAssert.assertEquals(amount, alloc.getAs("Amount__c"), message + " - Amount");
            \\    SystemAssert.assertEquals(percentage, alloc.getAs("Percent__c"), message + " - Percent");
            \\    if (gauNameOrId != null) {
            \\    Object actualGauId = alloc.getAs("General_Accounting_Unit__c");
            \\    Object actualGauName = ApexSwitch.getAs(alloc.getAs("General_Accounting_Unit__r"), "Name");
            \\    if (ApexEquals.eq(gauNameOrId, actualGauId)) {
            \\    SystemAssert.assertEquals(gauNameOrId, actualGauId, message + " - GAU (Id)");
            \\    }
            \\    else {
            \\    SystemAssert.assertEquals(gauNameOrId, actualGauName, message + " - GAU (Name)");
            \\    }
            \\    }
            \\  }
            \\
            \\  public static void assertAllocation(ApexSObject alloc, String opportunityId, String paymentId, String recurringDonationId, String campaignId, Number amount, Number percentage, String gauNameOrId, String message) {
            \\    assertAllocation(alloc, opportunityId, paymentId, recurringDonationId, campaignId, amount == null ? null : amount.doubleValue(), percentage == null ? null : percentage.doubleValue(), gauNameOrId, message);
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public static void validateSettings(ApexSObject dataImportBatch) {\n",
            .end_marker = "  public static void updateDIBatchStatistics(String apexJobId, String batchId) {\n",
            .replacement =
            \\  public static void validateSettings(ApexSObject dataImportBatchOrSettings) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (dataImportBatchOrSettings == null) {
            \\    return;
            \\    }
            \\    Boolean looksLikeBatch = ApexEquals.eq(ApexSwitch.getSObjectType(dataImportBatchOrSettings), new Schema.SObjectType("DataImportBatch__c")) || dataImportBatchOrSettings.getPopulatedFieldsAsMap().containsKey("Batch_Process_Size__c") || (dataImportBatchOrSettings.getAs("Batch_Size__c") == null && dataImportBatchOrSettings.getAs("Name") != null);
            \\    ApexSObject dataImportSettings = dataImportBatchOrSettings;
            \\    if (looksLikeBatch) {
            \\    if (ApexStrings.isBlank(dataImportBatchOrSettings.getAs("Name"))) {
            \\    throw(new BDIException(Label.bdiErrorBatchNameRequired));
            \\    }
            \\    dataImportSettings = diSettingsFromDiBatch(dataImportBatchOrSettings);
            \\    }
            \\    String dataImportSettingsObject = UTIL_Namespace.StrTokenNSPrefix("Data_Import_Settings__c");
            \\    String strDataImportObj = UTIL_Namespace.StrTokenNSPrefix("DataImport__c");
            \\    if (dataImportSettings.getAs("Donation_Matching_Behavior__c") != null &&ApexEquals.ne(dataImportSettings.getAs("Donation_Matching_Behavior__c"), BDI_DataImport_API.DoNotMatch)&& ApexStrings.isBlank(dataImportSettings.getAs("Donation_Matching_Rule__c"))) {
            \\    throw(new BDIException(Label.bdiDonationMatchingRuleEmpty));
            \\    }
            \\    if (dataImportSettings.getAs("Batch_Size__c") == null || dataImportSettings.getAs("Batch_Size__c") < 0) {
            \\    throw(new BDIException(ApexStrings.format(Label.bdiPositiveNumber, new ArrayList<String>(ApexCollections.listOf(UTIL_Describe.getFieldLabelSafe(dataImportSettingsObject, UTIL_Namespace.StrTokenNSPrefix("Batch_Size__c")))) )));
            \\    }
            \\    if (dataImportSettings.getAs("Donation_Date_Range__c") < 0) {
            \\    throw(new BDIException(ApexStrings.format(Label.bdiPositiveNumber, new ArrayList<String>(ApexCollections.listOf(UTIL_Describe.getFieldLabelSafe( dataImportSettingsObject, UTIL_Namespace.StrTokenNSPrefix("Donation_Date_Range__c") ))) )));
            \\    }
            \\    instantiateClassForInterface("BDI_IMatchDonations", dataImportSettings.getAs("Donation_Matching_Implementing_Class__c"));
            \\    instantiateClassForInterface("BDI_IPostProcess", dataImportSettings.getAs("Post_Process_Implementing_Class__c"));
            \\    Boolean validAccountModel = CAO_Constants.isHHAccountModel() || (ADV_PackageInfo_SVC.useAdv() && CAO_Constants.isOneToOne());
            \\    if (!validAccountModel){
            \\    throw(new BDIException(Label.bdiHouseholdModelRequired));
            \\    }
            \\    if (dataImportSettings.getAs("Contact_Custom_Unique_ID__c") != null) {
            \\    String strContact1 = strDIContactCustomIDField("Contact1", dataImportSettings);
            \\    String strContact2 = strDIContactCustomIDField("Contact2", dataImportSettings);
            \\    if (!UTIL_Describe.isValidField(strDataImportObj, strContact1) || !UTIL_Describe.isValidField(strDataImportObj, strContact2)) {
            \\    throw(new BDIException(ApexStrings.format(Label.bdiContactCustomIdError, new ArrayList<String>(ApexCollections.listOf(dataImportSettings.getAs("Contact_Custom_Unique_ID__c"), strContact1, strContact2)))));
            \\    }
            \\    }
            \\    if (dataImportSettings.getAs("Account_Custom_Unique_ID__c") != null) {
            \\    String strAccount1 = strDIAccountCustomIDField("Account1", dataImportSettings);
            \\    String strAccount2 = strDIAccountCustomIDField("Account2", dataImportSettings);
            \\    if (!UTIL_Describe.isValidField(strDataImportObj, strAccount1) || !UTIL_Describe.isValidField(strDataImportObj, strAccount2)) {
            \\    throw(new BDIException(ApexStrings.format(Label.bdiAccountCustomIdError, new ArrayList<String>(ApexCollections.listOf(dataImportSettings.getAs("Account_Custom_Unique_ID__c"), strAccount1, strAccount2)))));
            \\    }
            \\    }
            \\    Set<String> setDMBehavior = new LinkedHashSet<String>(ApexCollections.listOf(BDI_DataImport_API.DoNotMatch, BDI_DataImport_API.RequireNoMatch, BDI_DataImport_API.RequireExactMatch, BDI_DataImport_API.ExactMatchOrCreate, BDI_DataImport_API.RequireBestMatch, BDI_DataImport_API.BestMatchOrCreate));
            \\    if (!setDMBehavior.contains(dataImportSettings.getAs("Donation_Matching_Behavior__c"))) {
            \\    throw(new BDIException(ApexStrings.format(Label.bdiInvalidDonationMatchingBehavior, new ArrayList<String>(ApexCollections.listOf(dataImportSettings.getAs("Donation_Matching_Behavior__c"))))));
            \\    }
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public CRLP_RollupQueueable(List<String> summaryRecordIds) {\n",
            .end_marker = "  public void execute(apexemu.runtime.System.QueueableContext qc) {\n",
            .replacement =
            \\  public CRLP_RollupQueueable(List<?> summaryRecordIdsOrQueue) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    this.queueOfSummaryIds = new ArrayList<List<String>>();
            \\    if (summaryRecordIdsOrQueue == null || summaryRecordIdsOrQueue.isEmpty()) {
            \\    return;
            \\    }
            \\    Object first = summaryRecordIdsOrQueue.get(0);
            \\    if (first instanceof List<?>) {
            \\    this.queueOfSummaryIds = (List<List<String>>) (List<?>) summaryRecordIdsOrQueue;
            \\    }
            \\    else {
            \\    this.queueOfSummaryIds.add((List<String>) (List<?>) summaryRecordIdsOrQueue);
            \\    }
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "    public GatewayMock withDonors(List<ApexSObject> accounts) {\n",
            .end_marker = "    public Map<String, RD2_Donor.Record> getDonors(List<ApexSObject> rds) {\n",
            .replacement =
            \\    public GatewayMock withDonors(List<ApexSObject> donors) {
            \\      // TODO(apex): method body is copied as comments and needs manual porting.
            \\      for (ApexSObject donor : donors) {
            \\      if (ApexEquals.eq(ApexSwitch.getSObjectType(donor), new Schema.SObjectType("Contact"))) {
            \\      String contactName = (ApexStrings.isBlank(donor.getAs("FirstName")) ? "" : donor.getAs("FirstName") + " ") + donor.getAs("LastName");
            \\      donorById.put(donor.getAs("Id"), new RD2_Donor.Record(donor.getAs("Id"), contactName));
            \\      }
            \\      else {
            \\      donorById.put(donor.getAs("Id"), new RD2_Donor.Record(donor.getAs("Id"), donor.getAs("Name"), donor.getAs("RecordTypeId")));
            \\      }
            \\      }
            \\      return this;
            \\    }
            \\
            ,
        },
        .{
            .start_marker = "  public static String getDefaultExpectedName(ApexSObject acc, String amount, String currencyCode) {\n",
            .end_marker = "  public static String getExpectedName(String nameFormat, String period, String amount, String currencyCode, ApexSObject contact, ApexSObject account) {\n",
            .replacement =
            \\  public static String getDefaultExpectedName(ApexSObject donor, String amount, String currencyCode) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    if (ApexEquals.eq(ApexSwitch.getSObjectType(donor), new Schema.SObjectType("Contact"))) {
            \\    String contactName = (ApexStrings.isBlank(donor.getAs("FirstName")) ? "" : (donor.getAs("FirstName") + " ")) + donor.getAs("LastName");
            \\    return contactName + " " + getCurrencySymbol(currencyCode) + amount + " - " + System.Label.RecurringDonationNameSuffix;
            \\    }
            \\    return donor.getAs("Name") + " " + getCurrencySymbol(currencyCode) + amount + " - " + System.Label.RecurringDonationNameSuffix;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public UTIL_Finder withSelectFields(List<String> fieldNames) {\n",
            .end_marker = "  public UTIL_Finder withWhere(UTIL_Where.FieldExpression fieldExp) {\n",
            .replacement =
            \\  public UTIL_Finder withSelectFields(java.util.Collection<?> fieldNamesOrFieldSet) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    for (Object value : fieldNamesOrFieldSet) {
            \\    if (value instanceof Schema.FieldSetMember member) {
            \\    selectFields.add(member.getFieldPath());
            \\    }
            \\    else if (value != null) {
            \\    selectFields.add(String.valueOf(value));
            \\    }
            \\    }
            \\    return this;
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "  public void setFieldValue(Schema.SObjectField sObjectIdFieldToCheck, Schema.SObjectField sObjectFieldToUpdate, Map<String, Object> values) {\n",
            .end_marker = "  @SuppressWarnings(\"unchecked\")\n",
            .replacement =
            \\  public void setFieldValue(Schema.SObjectField fieldToCheck, Schema.SObjectField sObjectFieldToUpdate, Map<String, Object> values) {
            \\    // TODO(apex): method body is copied as comments and needs manual porting.
            \\    for (ApexSObject record : getRecords()) {
            \\    String keyValue = (String) record.get(fieldToCheck);
            \\    if (((values) == null ? null : (values).containsKey(keyValue))) {
            \\    record.put(sObjectFieldToUpdate, values.get(keyValue));
            \\    }
            \\    }
            \\  }
            \\
            ,
        },
        .{
            .start_marker = "    public AsyncApexJob getRecord(String className) {\n",
            .end_marker = "    @SuppressWarnings(\"unchecked\")\n",
            .replacement =
            \\    public AsyncApexJob getRecord(String classNameOrJobId) {
            \\      // TODO(apex): method body is copied as comments and needs manual porting.
            \\      String soql;
            \\      if (Id.isValid(classNameOrJobId)) {
            \\      soql = new UTIL_Query() .withFrom(AsyncApexJob.SObjectType) .withSelectFields(fields) .withWhere("Id = :classNameOrJobId") .build();
            \\      }
            \\      else {
            \\      soql = new UTIL_Query() .withFrom(AsyncApexJob.SObjectType) .withSelectFields(fields) .withWhere("ApexClass.Name = :classNameOrJobId") .withLimit(1) .build();
            \\      }
            \\      List<ApexSObject> records = Database.query(soql);
            \\      return records == null || records.isEmpty() ? null : (AsyncApexJob) records.get(0);
            \\    }
            \\
            ,
        },
    };

    for (section_patterns) |pattern| {
        const next = try replaceSectionBetweenMarkers(gpa, current, pattern.start_marker, pattern.end_marker, pattern.replacement);
        gpa.free(current);
        current = next;
    }

    const literal_patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{
            .from = "  public Boolean canUpdate(Schema.SObjectType sObjectType, Set<String> fieldNames) {\n",
            .to = "  public Boolean canUpdate(Schema.SObjectType sObjectType, java.util.Collection<String> fieldNames) {\n",
        },
        .{
            .from = "  public List<AddressResponse> verifyAddresses(List<String> addresses) {\n",
            .to = "  public List<AddressResponse> verifyAddresses(java.util.Collection<String> addresses) {\n",
        },
        .{
            .from = "  public Search.SearchBuilder searchBuilder() {\n",
            .to = "  public SearchBuilder searchBuilder() {\n",
        },
        .{
            .from = "implements Finalizer",
            .to = "implements System.Finalizer",
        },
        .{
            .from = "FinalizerContext context",
            .to = "System.FinalizerContext context",
        },
        .{
            .from = "System.System.FinalizerContext",
            .to = "System.FinalizerContext",
        },
        .{
            .from = "apexemu.runtime.System.System.FinalizerContext",
            .to = "apexemu.runtime.System.FinalizerContext",
        },
        .{
            .from = "(FinalizerContext) new MockFinalizerContext(",
            .to = "(System.FinalizerContext) new MockFinalizerContext(",
        },
        .{
            .from = "private ParentJobResult jobResult;",
            .to = "private System.FinalizerContext.ParentJobResult jobResult;",
        },
        .{
            .from = "MockFinalizerContext(ParentJobResult jobResult)",
            .to = "MockFinalizerContext(System.FinalizerContext.ParentJobResult jobResult)",
        },
        .{
            .from = "public ParentJobResult getResult()",
            .to = "public System.FinalizerContext.ParentJobResult getResult()",
        },
        .{
            .from = "ParentJobResult.UNHANDLED_EXCEPTION",
            .to = "System.FinalizerContext.ParentJobResult.UNHANDLED_EXCEPTION",
        },
        .{
            .from = "ParentJobResult.SUCCESS",
            .to = "System.FinalizerContext.ParentJobResult.SUCCESS",
        },
        .{
            .from = " InstallContext ",
            .to = " System.InstallContext ",
        },
        .{
            .from = "List<FieldSetMember>",
            .to = "List<Schema.FieldSetMember>",
        },
        .{
            .from = "for (FieldSetMember ",
            .to = "for (Schema.FieldSetMember ",
        },
        .{
            .from = "for(FieldSetMember ",
            .to = "for(Schema.FieldSetMember ",
        },
        .{
            .from = "ApexPages.standardController",
            .to = "ApexPages.StandardController",
        },
        .{
            .from = "Test.StartTest(",
            .to = "Test.startTest(",
        },
        .{
            .from = "Test.StopTest(",
            .to = "Test.stopTest(",
        },
        .{
            .from = "logginglevel.",
            .to = "LoggingLevel.",
        },
    };

    for (literal_patterns) |pattern| {
        const next = try replaceLiteralAll(gpa, current, pattern.from, pattern.to);
        gpa.free(current);
        current = next;
    }

    const util_finder_fixed = try rewriteUtilFinderInnerSearchBuilder(gpa, current);
    gpa.free(current);
    current = util_finder_fixed;

    const ep_manage_fixed = try rewriteEpManageTemplateCompat(gpa, current);
    gpa.free(current);
    current = ep_manage_fixed;

    return current;
}

fn rewriteNpspAliasCompat(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker =
        \\  @SuppressWarnings("unchecked")
    ;

    var current = try gpa.dupe(u8, text);
    errdefer gpa.free(current);

    if (std.mem.indexOf(u8, current, "public class UTIL_UnitTestData_TEST") != null) {
        const insertion =
            \\  public static List<ApexSObject> OppsForAccountList(List<ApexSObject> accounts, String campId, String stage, Date closeDate, Double amt, String recordTypeName, String oppType) {
            \\    return oppsForAccountList(accounts, campId, stage, closeDate, amt, recordTypeName, oppType);
            \\  }
            \\
            \\  public static List<ApexSObject> OppsForAccountList(List<ApexSObject> accounts, String campId, String stage, Date closeDate, Number amt, String recordTypeName, String oppType) {
            \\    return oppsForAccountList(accounts, campId, stage, closeDate, amt, recordTypeName, oppType);
            \\  }
            \\
            \\  public static List<ApexSObject> CreateMultipleTestAccounts(Integer n, String strType) {
            \\    return createMultipleTestAccounts(n, strType);
            \\  }
            \\
            \\  public static ApexSObject CreateNewUserForTests(String strUsername) {
            \\    return createNewUserForTests(strUsername);
            \\  }
            \\
            \\  @SuppressWarnings("unchecked")
        ;
        const next = try replaceLiteralAll(gpa, current, marker, insertion);
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class CAO_Constants") != null) {
        const insertion =
            \\  public static String Contact_FIRSTNAME_FOR_TESTS = CONTACT_FIRSTNAME_FOR_TESTS;
            \\  public static String Contact_LASTNAME_FOR_TESTS = CONTACT_LASTNAME_FOR_TESTS;
            \\
            \\  @SuppressWarnings("unchecked")
        ;
        const next = try replaceLiteralAll(gpa, current, marker, insertion);
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class UTIL_Profile") != null) {
        const insertion =
            \\  public static final String SYSTEM_ADMINISTRATOR = "System Administrator";
            \\  public static final String PROFILE_STANDARD_USER = "Standard User";
            \\  public static final String PROFILE_READ_ONLY = PROFILE_MINIMUM_ACCESS;
            \\
            \\  @SuppressWarnings("unchecked")
        ;
        const next = try replaceLiteralAll(gpa, current, marker, insertion);
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class CDL_CascadeDeleteLookups") != null) {
        const alias_insertion =
            \\  public static class CascadeUnDelete extends CascadeUndelete {}
            \\  public static class Error {
        ;
        var next = try replaceLiteralAll(gpa, current, "  public static class Error {\n", alias_insertion);
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "validator.validate(deletedRecords.values(), children);", "validator.validate(new ArrayList<ApexSObject>(deletedRecords.values()), children);");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "ERR_Handler.getErrors(deletionResults, children)", "ERR_Handler.getErrors(new ArrayList<Object>(deletionResults), children)");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "ERR_Handler.getErrors(undeleteResults, children)", "ERR_Handler.getErrors(new ArrayList<Object>(undeleteResults), children)");
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class TEST_RecurringDonationBuilder") != null) {
        const insertion =
            \\  public TEST_RecurringDonationBuilder withAmount(Number amount) {
            \\    return withAmount(amount == null ? null : amount.doubleValue());
            \\  }
            \\
            \\  @SuppressWarnings("unchecked")
        ;
        const next = try replaceLiteralAll(gpa, current, marker, insertion);
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ACCT_IndividualAccounts_TEST") != null) {
        var next = try replaceLiteralAll(gpa, current, "insertedcontacts", "insertedContacts");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "Map<String, RecordType> recTypesById = new LinkedHashMap<>(recTypes);",
            "Map<String, RecordType> recTypesById = new LinkedHashMap<>();\n    for (RecordType rt : recTypes) {\n    recTypesById.put(rt.getAs(\"Id\"), rt);\n    }",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "newRecTypeId = recTypesById.values().get(0).getAs(\"Id\");",
            "newRecTypeId = new ArrayList<RecordType>(recTypesById.values()).get(0).getAs(\"Id\");",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_Addresses_TEST") != null) {
        var next = try replaceLiteralAll(
            gpa,
            current,
            "testContacts.get((i * cConT) + j).set(\"LastName\", testContacts.get((i * cConT) + j).getAs(\"LastName\") + j);",
            "testContacts.get((i * cConT) + j).set(\"LastName\", ApexStrings.valueOf(testContacts.get((i * cConT) + j).getAs(\"LastName\")) + j);",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "new Address__c.get(0)", "new ArrayList<ApexSObject>()");
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_Addresses_TEST2") != null) {
        const next = try replaceLiteralAll(
            gpa,
            current,
            "con = Database.query(\"SELECT Id, LastName, MailingStreet, Current_Address__c FROM Contact\");",
            "con = ApexCollections.firstOrThrow(Database.query(\"SELECT Id, LastName, MailingStreet, Current_Address__c FROM Contact\"));",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_Cicero_Validator") != null) {
        const next = try replaceLiteralAll(
            gpa,
            current,
            "req.setTimeout((dblTimeout == null) ? 5000 : (dblTimeout * 1000).intValue());",
            "req.setTimeout((dblTimeout == null) ? 5000 : (int) (dblTimeout * 1000));",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_GoogleGeoAPI_Validator") != null) {
        var next = try replaceLiteralAll(
            gpa,
            current,
            "switch (googleResponse.getAs(\"status\")) {",
            "switch (ApexStrings.valueOf(googleResponse.getAs(\"status\"))) {",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "String endPoint = settings.getAs(\"Address_Verification_Endpoint__c\") != null ? settings.getAs(\"Address_Verification_Endpoint__c\") : getDefaultURL();",
            "String endPoint = settings.getAs(\"Address_Verification_Endpoint__c\") != null ? ApexStrings.valueOf(settings.getAs(\"Address_Verification_Endpoint__c\")) : getDefaultURL();",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_SmartyStreets_Gateway") != null) {
        var next = try replaceLiteralAll(
            gpa,
            current,
            "public HttpResponse sendRequest(List<Object> payload, String baseURL) {",
            "public HttpResponse sendRequest(List<?> payload, String baseURL) {",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "req.setTimeout((settings.getAs(\"timeout__c\") == null) ? 10000 : (settings.getAs(\"timeout__c\") * 1000).intValue());",
            "req.setTimeout((settings.getAs(\"timeout__c\") == null) ? 10000 : (int) (((Number) settings.getAs(\"timeout__c\")).doubleValue() * 1000));",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_MockHttpRespGenerator_TEST") != null) {
        const next = try replaceLiteralAll(
            gpa,
            current,
            "responseCnt = Math.Min(100, Integer.valueOf((int) (req.getHeader(\"bodySize\"))));",
            "responseCnt = Math.min(100, Integer.valueOf(req.getHeader(\"bodySize\")));",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public abstract class UTIL_AbstractChunkingLDV_BATCH") != null) {
        var next = try replaceLiteralAll(gpa, current, "batchJobinProgress", "batchJobInProgress");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "getQueryOrderByAndLimitClause()", "getQueryOrderByANDLimitClause()");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "getQueryNonLdvWhereClause()", "getQueryNonLDVWhereClause()");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "String LastIdInScope", "String lastIdInScope");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(gpa, current, "return e;", "return new apexemu.runtime.System.Exception(e.getMessage());");
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_Validator_Batch") != null) {
        const next = try replaceLiteralAll(gpa, current, "List<ApexSObject> addressesToProcess = getRecords();", "List<ApexSObject> addressesToProcess = records;");
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ADDR_CopyAddrHHObjBTN_CTRL") != null) {
        var next = try replaceLiteralAll(gpa, current, "pageref.getUrl()", "pageRef.getUrl()");
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "String strTitle = \"ADDRESS UPDATE FROM CONTACT: \" + apexemu.runtime.System.today().addDays(\" BY: \" + UserInfo.getName());",
            "String strTitle = \"ADDRESS UPDATE FROM CONTACT: \" + apexemu.runtime.System.today() + \" BY: \" + UserInfo.getName();",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "n = ApexSObject.of(\"Note\").set(\"Title\", strTitle).set(\"ParentId\", h.getAs(\"id\")).set(\"Body\", notebody);",
            "n = (Note) new Note().set(\"Title\", strTitle).set(\"ParentId\", h.getAs(\"id\")).set(\"Body\", notebody);",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "List<Database.Error> ers = sr.getErrors();",
            "List<Database.Error> ers = new ArrayList<Database.Error>(java.util.Arrays.asList(sr.getErrors()));",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "String strTitle = \"ADDRESS UPDATE FROM HOUSEHOLD: \" + apexemu.runtime.System.today().addDays(\" BY: \" + UserInfo.getName());",
            "String strTitle = \"ADDRESS UPDATE FROM HOUSEHOLD: \" + apexemu.runtime.System.today() + \" BY: \" + UserInfo.getName();",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "n = ApexSObject.of(\"Note\").set(\"Title\", strTitle).set(\"ParentId\", con.getAs(\"id\")).set(\"Body\", notebody);",
            "n = (Note) new Note().set(\"Title\", strTitle).set(\"ParentId\", con.getAs(\"id\")).set(\"Body\", notebody);",
        );
        gpa.free(current);
        current = next;

        next = try replaceLiteralAll(
            gpa,
            current,
            "UTIL_DMLService.insertRecords(notestoinsert);",
            "UTIL_DMLService.insertRecords(new ArrayList<ApexSObject>(notestoinsert));",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class UTIL_Permissions") != null) {
        const next = try replaceLiteralAll(gpa, current, "SObjFields", "sObjFields");
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class ERR_Handler_API") != null) {
        const next = try replaceLiteralAll(
            gpa,
            current,
            "public static enum Context { PLACEHOLDER }",
            "public static enum Context { ADDR, AFFL, ALLO, BDE, BDI, CON, CONV, CRLP, GE, HH, LD, LVL, OPP, PMT, REL, RD, Elevate, RLLP, SCH, STTG, TDTM, USER }",
        );
        gpa.free(current);
        current = next;
    }

    if (std.mem.indexOf(u8, current, "public class SfdoInstrumentationEnum") != null) {
        const next = try replaceLiteralAll(
            gpa,
            current,
            "public static enum Action { Save, Cancel, Create, Dml_Delete, Dml_Update, Dml_Merge, Dml_Undelete,",
            "public static enum Action { Save, Cancel, Create, Dml_Insert, Dml_Delete, Dml_Update, Dml_Merge, Dml_Undelete,",
        );
        gpa.free(current);
        current = next;
    }

    return current;
}

fn rewriteLabelNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const prefixes = [_][]const u8{
        "System.Label.",
        "System.label.",
        "Label.",
        "label.",
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const State = enum {
        normal,
        line_comment,
        block_comment,
        string_literal,
        char_literal,
    };

    var state: State = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    i += 1;
                    continue;
                }

                if (i > 0 and (isIdentifierChar(text[i - 1]) or text[i - 1] == '.')) {
                    i += 1;
                    continue;
                }

                var matched_prefix: ?[]const u8 = null;
                for (prefixes) |prefix| {
                    if (startsWithIgnoreCase(text[i..], prefix)) {
                        matched_prefix = prefix;
                        break;
                    }
                }
                if (matched_prefix == null) {
                    i += 1;
                    continue;
                }

                const prefix = matched_prefix.?;
                const first_start = i + prefix.len;
                if (first_start >= text.len or !isIdentifierChar(text[first_start])) {
                    i += 1;
                    continue;
                }

                var first_end = first_start;
                while (first_end < text.len and isIdentifierChar(text[first_end])) : (first_end += 1) {}
                const first_ident = text[first_start..first_end];

                var replacement: ?[]u8 = null;
                var replace_end = first_end;

                if (std.ascii.eqlIgnoreCase(first_ident, "getAs") and first_end < text.len and text[first_end] == '(') {
                    replacement = try std.fmt.allocPrint(gpa, "Labels.", .{});
                    replace_end = first_start;
                } else if (std.ascii.eqlIgnoreCase(prefix, "label.") and first_end < text.len and text[first_end] == '(') {
                    i += 1;
                    continue;
                } else if (first_end < text.len and text[first_end] == '.') {
                    const second_start = first_end + 1;
                    if (second_start < text.len and isIdentifierChar(text[second_start])) {
                        var second_end = second_start;
                        while (second_end < text.len and isIdentifierChar(text[second_end])) : (second_end += 1) {}
                        const second_ident = text[second_start..second_end];
                        if (std.ascii.eqlIgnoreCase(second_ident, "getAs") and second_end < text.len and text[second_end] == '(') {
                            replacement = try std.fmt.allocPrint(gpa, "Labels.namespace(\"{s}\")", .{first_ident});
                            replace_end = first_end;
                        } else if (second_end < text.len and text[second_end] == '(') {
                            replacement = try std.fmt.allocPrint(gpa, "Labels.get(\"{s}\")", .{first_ident});
                            replace_end = first_end;
                        } else {
                            replacement = try std.fmt.allocPrint(gpa, "Labels.namespace(\"{s}\").get(\"{s}\")", .{ first_ident, second_ident });
                            replace_end = second_end;
                        }
                    } else {
                        replacement = try std.fmt.allocPrint(gpa, "Labels.namespace(\"{s}\")", .{first_ident});
                        replace_end = first_end;
                    }
                } else {
                    replacement = try std.fmt.allocPrint(gpa, "Labels.get(\"{s}\")", .{first_ident});
                    replace_end = first_end;
                }

                if (replacement) |rewritten| {
                    defer gpa.free(rewritten);
                    try out.appendSlice(gpa, text[last_emit..i]);
                    try out.appendSlice(gpa, rewritten);
                    replaced = true;
                    last_emit = replace_end;
                    i = replace_end;
                    continue;
                }

                i += 1;
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
                i += 1;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 2;
                    continue;
                }
                i += 1;
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '"') state = .normal;
                i += 1;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
                i += 1;
            },
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteLowercaseDatabaseNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const needle = "database.";
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], needle)) continue;
        if (i > 0 and (isIdentifierChar(text[i - 1]) or text[i - 1] == '.')) continue;
        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, "Database.");
        replaced = true;
        i += needle.len - 1;
        last_emit = i + 1;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteCustomSchemaSObjectTypeAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    const prefix = "Schema.SObjectType.";

    while (i < text.len) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    i += 1;
                    continue;
                }

                if (!startsWithIgnoreCase(text[i..], prefix)) {
                    i += 1;
                    continue;
                }
                if (i > 0 and (isIdentifierChar(text[i - 1]) or text[i - 1] == '.')) {
                    i += 1;
                    continue;
                }

                const name_start = i + prefix.len;
                if (name_start >= text.len or !isIdentifierChar(text[name_start])) {
                    i += 1;
                    continue;
                }

                var name_end = name_start;
                while (name_end < text.len and isIdentifierChar(text[name_end])) : (name_end += 1) {}
                const type_name = text[name_start..name_end];
                if (std.mem.indexOf(u8, type_name, "__") == null) {
                    i = name_end;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..i]);
                try appendFmt(gpa, &out, "new Schema.SObjectType(\"{s}\")", .{type_name});
                replaced = true;
                last_emit = name_end;
                i = name_end;
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
                i += 1;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 2;
                    continue;
                }
                i += 1;
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '"') state = .normal;
                i += 1;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
                i += 1;
            },
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewritePageNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    const prefix = "Page.";

    while (i < text.len) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    i += 1;
                    continue;
                }

                if (!startsWithIgnoreCase(text[i..], prefix)) {
                    i += 1;
                    continue;
                }
                if (i > 0 and (isIdentifierChar(text[i - 1]) or text[i - 1] == '.')) {
                    i += 1;
                    continue;
                }

                const name_start = i + prefix.len;
                if (name_start >= text.len or !isIdentifierChar(text[name_start])) {
                    i += 1;
                    continue;
                }

                var name_end = name_start;
                while (name_end < text.len and isIdentifierChar(text[name_end])) : (name_end += 1) {}
                const page_name = text[name_start..name_end];

                try out.appendSlice(gpa, text[last_emit..i]);
                try appendFmt(gpa, &out, "new PageReference(\"/apex/{s}\")", .{page_name});
                replaced = true;
                last_emit = name_end;
                i = name_end;
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
                i += 1;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 2;
                    continue;
                }
                i += 1;
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '"') state = .normal;
                i += 1;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
                i += 1;
            },
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteTypePathGetAsAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (!startsWithIgnoreCase(text[i..], ".getAs")) continue;

        const method_end = i + ".getAs".len;
        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (!isLikelyTypeReferencePathExpression(base_expr)) continue;
        if (std.mem.count(u8, base_expr, ".") != 1) continue;

        const arg = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (arg.len < 3 or arg[0] != '"' or arg[arg.len - 1] != '"') continue;
        const member = arg[1 .. arg.len - 1];
        if (member.len == 0 or !isSimpleIdentifierOrPath(member)) continue;
        if (std.mem.indexOfScalar(u8, member, '.') != null) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "{s}.{s}", .{ base_expr, member });
        replaced = true;
        last_emit = close + 1;
        i = close;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteCollectionViewPropertyAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    while (i < text.len) {
        const ch = text[i];
        if (in_double) {
            try out.append(gpa, ch);
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_double = false;
            }
            i += 1;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }

        const accessor = blk: {
            if (startsWithIgnoreCase(text[i..], ".keySet")) break :blk ".keySet";
            if (startsWithIgnoreCase(text[i..], ".values")) break :blk ".values";
            break :blk "";
        };
        if (accessor.len == 0) {
            try out.append(gpa, ch);
            i += 1;
            continue;
        }

        const accessor_end = i + accessor.len;
        if (accessor_end < text.len and isIdentifierChar(text[accessor_end])) {
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        const next = nextNonSpace(text, accessor_end);
        if (next < text.len and text[next] == '(') {
            try out.appendSlice(gpa, text[i..accessor_end]);
            i = accessor_end;
            continue;
        }
        if (next < text.len and (text[next] == '=' or text[next] == '.')) {
            try out.appendSlice(gpa, text[i..accessor_end]);
            i = accessor_end;
            continue;
        }

        try out.appendSlice(gpa, accessor);
        try out.appendSlice(gpa, "()");
        i = accessor_end;
        replaced = true;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteLongAssignmentsFromIntegerIdentifiers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var integer_names: std.ArrayList([]u8) = .empty;
    defer {
        for (integer_names.items) |name| gpa.free(name);
        integer_names.deinit(gpa);
    }

    var long_names: std.ArrayList([]u8) = .empty;
    defer {
        for (long_names.items) |name| gpa.free(name);
        long_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractTypedVariableName(line, "Integer")) |name| {
            try integer_names.append(gpa, try gpa.dupe(u8, name));
        }
        if (extractTypedVariableName(line, "Long")) |name| {
            try long_names.append(gpa, try gpa.dupe(u8, name));
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var render_lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (render_lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        var rendered = try gpa.dupe(u8, std.mem.trimRight(u8, raw_line, "\r"));
        defer gpa.free(rendered);

        for (long_names.items) |long_name| {
            for (integer_names.items) |integer_name| {
                const needle = try std.fmt.allocPrint(gpa, "{s} = {s};", .{ long_name, integer_name });
                defer gpa.free(needle);
                if (std.mem.indexOf(u8, rendered, needle) == null) continue;

                const replacement = try std.fmt.allocPrint(gpa, "{s} = Long.valueOf({s});", .{ long_name, integer_name });
                defer gpa.free(replacement);
                const next = try replaceLiteralAll(gpa, rendered, needle, replacement);
                gpa.free(rendered);
                rendered = next;
                replaced = true;
            }
        }

        try out.appendSlice(gpa, rendered);
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteDoubleDateTimeDeltaAssignments(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const double_pos = std.mem.indexOf(u8, line, "Double ");
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        if (double_pos == null or eq_pos <= double_pos.?) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const rhs = std.mem.trim(u8, line[(eq_pos + 1)..], " \t");
        if (!endsWithIgnoreCase(rhs, ";") or std.mem.indexOf(u8, rhs, "Double.valueOf(") != null or std.mem.indexOf(u8, rhs, ".getTime()") == null or std.mem.indexOf(u8, rhs, " - ") == null) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const rhs_expr = std.mem.trimRight(u8, rhs[0 .. rhs.len - 1], " \t");
        try out.appendSlice(gpa, line[0 .. eq_pos + 1]);
        try out.append(gpa, ' ');
        try appendFmt(gpa, &out, "Double.valueOf({s});", .{rhs_expr});
        replaced = true;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteGetAsCollectionAccessors(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], ".getAs")) continue;

        const open = std.mem.indexOfScalarPos(u8, text, i + ".getAs".len, '(') orelse continue;
        const close = findMatchingParen(text, open) orelse continue;
        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const get_as_call = std.mem.trim(u8, text[base_start .. close + 1], " \t");

        const accessor_start = nextNonSpace(text, close + 1);
        if (accessor_start >= text.len or text[accessor_start] != '.') continue;

        if (startsWithIgnoreCase(text[accessor_start..], ".size()")) {
            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "ApexCollections.size({s})", .{get_as_call});
            replaced = true;
            last_emit = accessor_start + ".size()".len;
            i = last_emit - 1;
            continue;
        }

        if (startsWithIgnoreCase(text[accessor_start..], ".isEmpty()")) {
            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "ApexCollections.size({s}) == 0", .{get_as_call});
            replaced = true;
            last_emit = accessor_start + ".isEmpty()".len;
            i = last_emit - 1;
            continue;
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteGetErrorsArrayAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], ".getErrors")) continue;

        const open = std.mem.indexOfScalarPos(u8, text, i + ".getErrors".len, '(') orelse continue;
        const close = findMatchingParen(text, open) orelse continue;
        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");

        const accessor_start = nextNonSpace(text, close + 1);
        if (accessor_start >= text.len or text[accessor_start] != '.') continue;
        if (!startsWithIgnoreCase(text[accessor_start..], ".get(")) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "java.util.Arrays.asList({s}.getErrors())", .{base_expr});
        replaced = true;
        last_emit = accessor_start;
        i = accessor_start - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteRecordTypeInfoMapDeclarations(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const from_type = "Map<String, ApexSObject>";
    const to_type = "Map<String, apexemu.runtime.RecordTypeInfo>";
    const markers = [_][]const u8{
        ".getRecordTypeInfosById(",
        ".getRecordTypeInfosByName(",
        ".getRecordTypeInfosByDeveloperName(",
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    i += 1;
                    continue;
                }

                if (!startsWithIgnoreCase(text[i..], from_type)) {
                    i += 1;
                    continue;
                }

                const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
                const statement = text[i..line_end];
                if (std.mem.indexOfScalar(u8, statement, '=')) |eq_idx| {
                    const rhs = statement[(eq_idx + 1)..];
                    var matches_record_type_info = false;
                    for (markers) |marker| {
                        if (std.mem.indexOf(u8, rhs, marker) != null) {
                            matches_record_type_info = true;
                            break;
                        }
                    }
                    if (matches_record_type_info) {
                        try out.appendSlice(gpa, text[last_emit..i]);
                        try out.appendSlice(gpa, to_type);
                        replaced = true;
                        i += from_type.len;
                        last_emit = i;
                        continue;
                    }
                }

                i += 1;
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
                i += 1;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 2;
                    continue;
                }
                i += 1;
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '"') state = .normal;
                i += 1;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
                i += 1;
            },
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteRecordTypeInfoUsages(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var map_names: std.ArrayList([]u8) = .empty;
    defer {
        for (map_names.items) |name| gpa.free(name);
        map_names.deinit(gpa);
    }

    var list_names: std.ArrayList([]u8) = .empty;
    defer {
        for (list_names.items) |name| gpa.free(name);
        list_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractDeclaredVariableName(line, "Map<String, apexemu.runtime.RecordTypeInfo> ")) |name| {
            try map_names.append(gpa, try gpa.dupe(u8, name));
        }
        if (extractDeclaredVariableName(line, "List<apexemu.runtime.RecordTypeInfo> ")) |name| {
            try list_names.append(gpa, try gpa.dupe(u8, name));
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var render_lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (render_lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        var rendered = try gpa.dupe(u8, std.mem.trimRight(u8, raw_line, "\r"));
        defer gpa.free(rendered);

        if (lineContainsRecordTypeInfoGetter(rendered)) {
            if (std.mem.indexOf(u8, rendered, "Map<String, ApexSObject>") != null) {
                const next = try replaceLiteralAll(gpa, rendered, "Map<String, ApexSObject>", "Map<String, apexemu.runtime.RecordTypeInfo>");
                gpa.free(rendered);
                rendered = next;
                replaced = true;
            }
            if (std.mem.indexOf(u8, rendered, "List<ApexSObject>") != null) {
                const next = try replaceLiteralAll(gpa, rendered, "List<ApexSObject>", "List<apexemu.runtime.RecordTypeInfo>");
                gpa.free(rendered);
                rendered = next;
                replaced = true;
            }
            if (std.mem.indexOf(u8, rendered, "ApexSObject ") != null) {
                const next = try replaceLiteralAll(gpa, rendered, "ApexSObject ", "apexemu.runtime.RecordTypeInfo ");
                gpa.free(rendered);
                rendered = next;
                replaced = true;
            }
        }

        if (startsWithIgnoreCase(std.mem.trimLeft(u8, rendered, " \t"), "for (ApexSObject ")) {
            for (map_names.items) |name| {
                const needle = try std.fmt.allocPrint(gpa, ": {s}.values()", .{name});
                defer gpa.free(needle);
                if (std.mem.indexOf(u8, rendered, needle) != null) {
                    const next = try replaceLiteralAll(gpa, rendered, "for (ApexSObject ", "for (apexemu.runtime.RecordTypeInfo ");
                    gpa.free(rendered);
                    rendered = next;
                    replaced = true;
                    break;
                }
            }
            if (std.mem.indexOf(u8, rendered, "for (ApexSObject ") != null) {
                for (list_names.items) |name| {
                    const needle = try std.fmt.allocPrint(gpa, ": {s})", .{name});
                    defer gpa.free(needle);
                    if (std.mem.indexOf(u8, rendered, needle) != null) {
                        const next = try replaceLiteralAll(gpa, rendered, "for (ApexSObject ", "for (apexemu.runtime.RecordTypeInfo ");
                        gpa.free(rendered);
                        rendered = next;
                        replaced = true;
                        break;
                    }
                }
            }
        }

        try out.appendSlice(gpa, rendered);
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn extractDeclaredVariableName(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(line, prefix)) return null;
    var cursor = prefix.len;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    const name_start = cursor;
    while (cursor < line.len and isIdentifierChar(line[cursor])) : (cursor += 1) {}
    if (cursor == name_start) return null;
    return line[name_start..cursor];
}

fn extractTypedVariableName(line: []const u8, type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    var i: usize = 0;
    while (i + type_name.len < trimmed.len) : (i += 1) {
        if (!startsWithIgnoreCase(trimmed[i..], type_name)) continue;
        if (i > 0 and isIdentifierChar(trimmed[i - 1])) continue;

        const after_type = i + type_name.len;
        if (after_type >= trimmed.len or !std.ascii.isWhitespace(trimmed[after_type])) continue;

        var cursor = after_type;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        const name_start = cursor;
        while (cursor < trimmed.len and isIdentifierChar(trimmed[cursor])) : (cursor += 1) {}
        if (cursor == name_start) return null;
        return trimmed[name_start..cursor];
    }
    return null;
}

fn lineContainsRecordTypeInfoGetter(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ".getRecordTypeInfosById()") != null or
        std.mem.indexOf(u8, line, ".getRecordTypeInfosByName()") != null or
        std.mem.indexOf(u8, line, ".getRecordTypeInfosByDeveloperName()") != null or
        std.mem.indexOf(u8, line, ".getRecordTypeInfos()") != null;
}

const CompatibilityState = enum {
    normal,
    line_comment,
    block_comment,
    string_literal,
    char_literal,
};

const GetAsLikeCall = struct {
    start: usize,
    end: usize,
};

fn rewriteGetAsBooleanCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    i += 1;
                    continue;
                }

                const call = matchGetAsLikeCall(text, i) orelse {
                    i += 1;
                    continue;
                };
                if (call.start < last_emit) {
                    i = @max(i + 1, call.end);
                    continue;
                }

                const prev_idx = findPreviousNonWhitespace(text, call.start);
                const next_idx = findNextNonWhitespace(text, call.end);
                const call_text = text[call.start..call.end];

                var replacement: ?[]u8 = null;
                var replace_start = call.start;
                var replace_end = call.end;

                if (prev_idx) |prev| {
                    if (text[prev] == '!' and (prev == 0 or text[prev - 1] != '=')) {
                        replacement = try std.fmt.allocPrint(gpa, "!Boolean.TRUE.equals({s})", .{call_text});
                        replace_start = prev;
                    }
                }

                if (replacement == null) {
                    if (parseBooleanLiteralComparison(text, call.end)) |comparison| {
                        if (comparison.negated) {
                            replacement = try std.fmt.allocPrint(
                                gpa,
                                "!Boolean.{s}.equals({s})",
                                .{ if (comparison.value) "TRUE" else "FALSE", call_text },
                            );
                        } else {
                            replacement = try std.fmt.allocPrint(
                                gpa,
                                "Boolean.{s}.equals({s})",
                                .{ if (comparison.value) "TRUE" else "FALSE", call_text },
                            );
                        }
                        replace_end = comparison.end;
                    }
                }

                if (replacement == null and isBooleanOperandContext(text, call.start, call.end, prev_idx, next_idx)) {
                    replacement = try std.fmt.allocPrint(gpa, "Boolean.TRUE.equals({s})", .{call_text});
                }

                if (replacement) |rewritten| {
                    defer gpa.free(rewritten);
                    try out.appendSlice(gpa, text[last_emit..replace_start]);
                    try out.appendSlice(gpa, rewritten);
                    replaced = true;
                    last_emit = replace_end;
                    i = replace_end;
                    continue;
                }

                i = call.end;
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
                i += 1;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 2;
                    continue;
                }
                i += 1;
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '"') state = .normal;
                i += 1;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
                i += 1;
            },
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteEnhancedForGetAsIterables(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    i += 1;
                    continue;
                }

                if (!startsWithWordIgnoreCase(text[i..], "for")) {
                    i += 1;
                    continue;
                }
                if (i > 0 and isIdentifierChar(text[i - 1])) {
                    i += 1;
                    continue;
                }

                var open = i + "for".len;
                while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
                if (open >= text.len or text[open] != '(') {
                    i += 1;
                    continue;
                }
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };

                const header = text[(open + 1)..close];
                const colon = findTopLevelColon(header) orelse {
                    i = close + 1;
                    continue;
                };
                const left = std.mem.trim(u8, header[0..colon], " \t");
                const right = std.mem.trim(u8, header[(colon + 1)..], " \t");
                if (right.len == 0 or !containsGetAsLikeCall(right)) {
                    i = close + 1;
                    continue;
                }
                if (startsWithIgnoreCase(right, "(java.util.List<") or startsWithIgnoreCase(right, "(List<")) {
                    i = close + 1;
                    continue;
                }

                const element_type = inferEnhancedForElementType(left) orelse {
                    i = close + 1;
                    continue;
                };
                const replacement = try std.fmt.allocPrint(gpa, "(java.util.List<{s}>) {s}", .{ element_type, right });
                defer gpa.free(replacement);

                try out.appendSlice(gpa, text[last_emit .. open + 1 + colon + 1]);
                try out.append(gpa, ' ');
                try out.appendSlice(gpa, replacement);
                replaced = true;
                last_emit = close;
                i = close;
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
                i += 1;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 2;
                    continue;
                }
                i += 1;
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '"') state = .normal;
                i += 1;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
                i += 1;
            },
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteDatabaseQueryIndexCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    i += 1;
                    continue;
                }

                const query_method_len: usize = if (startsWithIgnoreCase(text[i..], "Database.queryWithBinds"))
                    "Database.queryWithBinds".len
                else if (startsWithIgnoreCase(text[i..], "Database.query"))
                    "Database.query".len
                else
                    0;
                if (query_method_len == 0 or (i > 0 and isIdentifierChar(text[i - 1]))) {
                    i += 1;
                    continue;
                }
                if (i + query_method_len < text.len and isIdentifierChar(text[i + query_method_len])) {
                    i += 1;
                    continue;
                }

                var open = i + query_method_len;
                while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
                if (open >= text.len or text[open] != '(') {
                    i += 1;
                    continue;
                }
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };

                var dot_pos = close + 1;
                while (dot_pos < text.len and std.ascii.isWhitespace(text[dot_pos])) : (dot_pos += 1) {}
                if (dot_pos >= text.len or text[dot_pos] != '.') {
                    i = close + 1;
                    continue;
                }
                var method_pos = dot_pos + 1;
                while (method_pos < text.len and std.ascii.isWhitespace(text[method_pos])) : (method_pos += 1) {}
                if (!startsWithIgnoreCase(text[method_pos..], "get")) {
                    i = close + 1;
                    continue;
                }
                const get_end = method_pos + "get".len;
                if (get_end < text.len and isIdentifierChar(text[get_end])) {
                    i = close + 1;
                    continue;
                }
                var get_open = get_end;
                while (get_open < text.len and std.ascii.isWhitespace(text[get_open])) : (get_open += 1) {}
                if (get_open >= text.len or text[get_open] != '(') {
                    i = close + 1;
                    continue;
                }
                const get_close = findMatchingParen(text, get_open) orelse {
                    i = close + 1;
                    continue;
                };

                const index_arg = std.mem.trim(u8, text[(get_open + 1)..get_close], " \t");
                if (index_arg.len == 0) {
                    i = get_close + 1;
                    continue;
                }

                const query_call = text[i .. close + 1];
                const replacement = if (std.mem.eql(u8, index_arg, "0"))
                    try std.fmt.allocPrint(gpa, "ApexCollections.firstOrThrow({s})", .{query_call})
                else
                    try std.fmt.allocPrint(gpa, "((java.util.List<ApexSObject>) {s}).get({s})", .{ query_call, index_arg });
                defer gpa.free(replacement);

                try out.appendSlice(gpa, text[last_emit..i]);
                try out.appendSlice(gpa, replacement);
                replaced = true;
                last_emit = get_close + 1;
                i = get_close + 1;
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
                i += 1;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 2;
                    continue;
                }
                i += 1;
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '"') state = .normal;
                i += 1;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
                i += 1;
            },
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn matchGetAsLikeCall(text: []const u8, i: usize) ?GetAsLikeCall {
    if (i < text.len and text[i] == '.' and startsWithIgnoreCase(text[i..], ".getAs")) {
        const method_boundary = i + ".getAs".len;
        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') return null;
        const close = findMatchingParen(text, open) orelse return null;
        const base_start = findMemberAccessBaseStart(text, i) orelse return null;
        return .{ .start = base_start, .end = close + 1 };
    }

    const prefix = "ApexSwitch.getAs";
    if (!startsWithIgnoreCase(text[i..], prefix)) return null;
    if (i > 0 and isIdentifierChar(text[i - 1])) return null;
    if (i + prefix.len < text.len and isIdentifierChar(text[i + prefix.len])) return null;
    var open = i + prefix.len;
    while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
    if (open >= text.len or text[open] != '(') return null;
    const close = findMatchingParen(text, open) orelse return null;
    return .{ .start = i, .end = close + 1 };
}

const BooleanLiteralComparison = struct {
    value: bool,
    negated: bool,
    end: usize,
};

fn parseBooleanLiteralComparison(text: []const u8, from: usize) ?BooleanLiteralComparison {
    var i = from;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    var negated = false;
    if (i + 1 < text.len and text[i] == '=' and text[i + 1] == '=') {
        i += 2;
    } else if (i + 1 < text.len and text[i] == '!' and text[i + 1] == '=') {
        negated = true;
        i += 2;
    } else {
        return null;
    }
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    if (startsWithWordIgnoreCase(text[i..], "true")) return .{ .value = true, .negated = negated, .end = i + "true".len };
    if (startsWithWordIgnoreCase(text[i..], "false")) return .{ .value = false, .negated = negated, .end = i + "false".len };
    return null;
}

fn isBooleanOperandContext(text: []const u8, call_start: usize, call_end: usize, prev_idx: ?usize, next_idx: ?usize) bool {
    _ = call_start;
    if (next_idx) |next| {
        const ch = text[next];
        if (ch == '.') return false;
        if (ch == '=' or ch == '>' or ch == '<') return false;
        if (!(ch == ')' or ch == '&' or ch == '|' or ch == ',' or ch == ';')) return false;
    } else {
        _ = call_end;
    }

    if (prev_idx) |prev| {
        const ch = text[prev];
        if (ch == '.' or isIdentifierChar(ch) or ch == ')' or ch == ']') return false;
        if (ch == '(') return isBooleanIntroducerBeforeParen(text, prev);
        return ch == '&' or ch == '|' or ch == ';';
    }

    return true;
}

fn isBooleanIntroducerBeforeParen(text: []const u8, paren_idx: usize) bool {
    const prev = findPreviousNonWhitespace(text, paren_idx) orelse return true;
    const ch = text[prev];
    if (ch == '(' or ch == '&' or ch == '|' or ch == '?' or ch == ':' or ch == ';') return true;
    if (!isIdentifierChar(ch)) return false;

    var start = prev;
    while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
    const token = text[start .. prev + 1];
    return std.ascii.eqlIgnoreCase(token, "if") or
        std.ascii.eqlIgnoreCase(token, "while") or
        std.ascii.eqlIgnoreCase(token, "assertTrue") or
        std.ascii.eqlIgnoreCase(token, "assertFalse");
}

fn findPreviousNonWhitespace(text: []const u8, before: usize) ?usize {
    var i = before;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return i;
    }
    return null;
}

fn findNextNonWhitespace(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isWhitespace(text[i])) return i;
    }
    return null;
}

fn containsGetAsLikeCall(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (matchGetAsLikeCall(text, i) != null) return true;
    }
    return false;
}

fn findTopLevelColon(text: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '(' or text[i] == '[' or text[i] == '{') depth += 1;
        if (text[i] == ')' or text[i] == ']' or text[i] == '}') depth -= 1;
        if (depth == 0 and text[i] == ':') return i;
    }
    return null;
}

fn inferEnhancedForElementType(left: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, left, " \t");
    if (startsWithWordIgnoreCase(trimmed, "final")) {
        trimmed = std.mem.trim(u8, trimmed["final".len..], " \t");
    }
    const space = std.mem.lastIndexOfAny(u8, trimmed, " \t") orelse return null;
    return std.mem.trim(u8, trimmed[0..space], " \t");
}

fn rewriteUtilFinderInnerSearchBuilder(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, text, "public class UTIL_Finder") == null) {
        return gpa.dupe(u8, text);
    }
    if (std.mem.indexOf(u8, text, "class SearchBuilder") != null) {
        return gpa.dupe(u8, text);
    }

    const marker =
        \\  @SuppressWarnings("unchecked")
    ;
    const insertion =
        \\  public static class SearchBuilder {
        \\  private String searchQuery;
        \\    private String searchGroup;
        \\    private Schema.SObjectType sObjType;
        \\    private Set<String> fields = new LinkedHashSet<String>();
        \\    private String orderBy;
        \\
        \\    public SearchBuilder withFind(String searchQuery) {
        \\      this.searchQuery = searchQuery;
        \\      return this;
        \\    }
        \\
        \\    public SearchBuilder withSearchGroup(String searchGroup) {
        \\      this.searchGroup = searchGroup;
        \\      return this;
        \\    }
        \\
        \\    public SearchBuilder withReturning(Schema.SObjectType sObjType) {
        \\      this.sObjType = sObjType;
        \\      return this;
        \\    }
        \\
        \\    public SearchBuilder withFields(Set<String> fields) {
        \\      this.fields = fields == null ? new LinkedHashSet<String>() : new LinkedHashSet<String>(fields);
        \\      return this;
        \\    }
        \\
        \\    public SearchBuilder withOrderBy(String orderBy) {
        \\      this.orderBy = orderBy;
        \\      return this;
        \\    }
        \\
        \\    public String build() {
        \\      if (sObjType == null) {
        \\      throw new SoslException(SOBJECT_TYPE_REQUIRED);
        \\      }
        \\      if (ApexStrings.isBlank(searchQuery)) {
        \\      throw new SoslException(SEARCH_QUERY_REQUIRED);
        \\      }
        \\      if (fields == null || fields.isEmpty()) {
        \\      throw new SoslException(FIELDS_REQUIRED);
        \\      }
        \\      String resolvedSearchGroup = ApexStrings.isBlank(searchGroup) ? "ALL" : searchGroup;
        \\      String returningFields = ApexStrings.join(new ArrayList<String>(fields), ", ");
        \\      String orderByClause = ApexStrings.isBlank(orderBy) ? "" : " ORDER BY " + orderBy;
        \\      return ApexStrings.format("FIND ''{0}'' IN {1} FIELDS RETURNING {2}({3}{4})", new ArrayList<String>(ApexCollections.listOf(searchQuery, resolvedSearchGroup, ApexStrings.valueOf(sObjType), returningFields, orderByClause)));
        \\    }
        \\  }
        \\
        \\  @SuppressWarnings("unchecked")
    ;

    return replaceLiteralAll(gpa, text, marker, insertion);
}

fn rewriteEpManageTemplateCompat(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, text, "public class EP_ManageEPTemplate_CTRL") == null) {
        return gpa.dupe(u8, text);
    }

    const get_task_tree_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    mapTaskWrappers = new LinkedHashMap<String, TaskWrapper>();
        \\    return new Component.Apex.OutputPanel();
        \\  
    ;
    const add_child_components_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    if (wrapper != null) {
        \\    wrapper.level = levelString;
        \\    mapTaskWrappers.put(levelString, wrapper);
        \\    }
        \\    return new Component.Apex.OutputPanel();
        \\  
    ;
    const field_label_panel_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    Component.Apex.OutputPanel result = new Component.Apex.OutputPanel();
        \\    Component.Apex.OutputLabel fieldLabel = new Component.Apex.OutputLabel();
        \\    fieldLabel.value = UTIL_Describe.getFieldLabel(UTIL_Namespace.StrTokenNSPrefix("Engagement_Plan_Task__c"), fieldName.endsWith("__c") ? UTIL_Namespace.StrTokenNSPrefix(fieldName) : fieldName).escapeHtml4();
        \\    fieldLabel.for_x = fieldName + (wrapper == null ? "" : wrapper.level);
        \\    result.childComponents.add(fieldLabel);
        \\    return result;
        \\  
    ;
    const generic_input_field_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    Component.c.UTIL_FormField inputField = new Component.c.UTIL_FormField();
        \\    inputField.field = fieldName;
        \\    inputField.sObjType = "Engagement_Plan_Task__c";
        \\    inputField.styleClass = style;
        \\    inputField.appearRequired = req;
        \\    inputField.expressions.sObj = "{!" + accessString + ".detail}";
        \\    return inputField;
        \\  
    ;
    const select_list_input_panel_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    return fieldLabelPanel(wrapper, fieldName, outterCss, required);
        \\  
    ;
    const comments_input_panel_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    return fieldLabelPanel(wrapper, fieldName, outterCss, required);
        \\  
    ;

    const get_task_tree_sig = "public Component.Apex.OutputPanel getTaskTree()";
    const add_child_components_sig = "public Component.Apex.OutputPanel addChildComponents(TaskWrapper wrapper, Integer level, String accessString, String levelString)";
    const field_label_panel_sig = "public Component.Apex.OutputPanel fieldLabelPanel(TaskWrapper wrapper, String fieldName, String outterCss, Boolean required)";
    const generic_input_field_sig = "public Component.c.UTIL_FormField genericInputField(TaskWrapper wrapper, String accessString, String fieldName, String style, Boolean req)";
    const select_list_input_panel_sig = "public Component.Apex.OutputPanel selectListInputPanel(TaskWrapper wrapper, String accessString, String fieldName, String outterCss, String inputCss, String selectOptions, Boolean required)";
    const comments_input_panel_sig = "public Component.Apex.OutputPanel commentsInputPanel(TaskWrapper wrapper, String accessString, String fieldName, String outterCss, String inputCss, Boolean required)";

    const get_task_tree_fixed = try replaceMethodBodyBySignature(gpa, text, get_task_tree_sig, get_task_tree_body);
    defer gpa.free(get_task_tree_fixed);
    const add_child_components_fixed = try replaceMethodBodyBySignature(gpa, get_task_tree_fixed, add_child_components_sig, add_child_components_body);
    defer gpa.free(add_child_components_fixed);
    const field_label_panel_fixed = try replaceMethodBodyBySignature(gpa, add_child_components_fixed, field_label_panel_sig, field_label_panel_body);
    defer gpa.free(field_label_panel_fixed);
    const generic_input_field_fixed = try replaceMethodBodyBySignature(gpa, field_label_panel_fixed, generic_input_field_sig, generic_input_field_body);
    defer gpa.free(generic_input_field_fixed);
    const select_list_input_panel_fixed = try replaceMethodBodyBySignature(gpa, generic_input_field_fixed, select_list_input_panel_sig, select_list_input_panel_body);
    defer gpa.free(select_list_input_panel_fixed);
    return replaceMethodBodyBySignature(gpa, select_list_input_panel_fixed, comments_input_panel_sig, comments_input_panel_body);
}

fn replaceLiteralAll(gpa: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    if (from.len == 0) return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, from)) |pos| {
        try out.appendSlice(gpa, text[start..pos]);
        try out.appendSlice(gpa, to);
        replaced = true;
        start = pos + from.len;
    }
    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[start..]);
    return out.toOwnedSlice(gpa);
}

fn replaceSectionBetweenMarkers(
    gpa: std.mem.Allocator,
    text: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (start_marker.len == 0 or end_marker.len == 0) return gpa.dupe(u8, text);

    const start = std.mem.indexOf(u8, text, start_marker) orelse return gpa.dupe(u8, text);
    const end = std.mem.indexOfPos(u8, text, start + start_marker.len, end_marker) orelse return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, text[0..start]);
    try out.appendSlice(gpa, replacement);
    try out.appendSlice(gpa, text[end..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteApexMocksUtilsMethodFixups(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, text, "class fflib_ApexMocksUtils") == null) {
        return gpa.dupe(u8, text);
    }

    const set_read_only_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    Map<String, Object> mergedMap = new LinkedHashMap<>(objInstance.fields());
        \\    mergedMap.putAll(properties);
        \\    ApexSObject deserialized = ApexSObject.of(ApexSwitch.typeName(objInstance));
        \\    if (objInstance.id() != null) {
        \\    deserialized.withId(objInstance.id());
        \\    }
        \\    for (Map.Entry<String, Object> entry : mergedMap.entrySet()) {
        \\    deserialized.set(entry.getKey(), entry.getValue());
        \\    }
        \\    return deserialized;
        \\  
    ;

    const deserialize_relationship_body =
        \\    // TODO(apex): method body is copied as comments and needs manual porting.
        \\    List<Schema.ChildRelationship> childRelationships = parentDescribe.getChildRelationships();
        \\    String relationshipName = null;
        \\    for(Schema.ChildRelationship childRelationship : childRelationships) {
        \\    if(childRelationship.getField().equalsIgnoreCase(relationshipField.getName())) {
        \\    relationshipName = childRelationship.getRelationshipName();
        \\    break;
        \\    }
        \\    }
        \\    if (relationshipName == null && relationshipField != null) {
        \\    relationshipName = relationshipField.getDescribe().getRelationshipName();
        \\    }
        \\    List<ApexSObject> withChildren = new ArrayList<>();
        \\    for (Integer i = 0; i < parents.size(); i++) {
        \\    ApexSObject parent = parents.get(i);
        \\    ApexSObject copy = ApexSObject.of(parent.type());
        \\    if (parent.id() != null) {
        \\    copy.withId(parent.id());
        \\    }
        \\    for (Map.Entry<String, Object> entry : parent.fields().entrySet()) {
        \\    copy.set(entry.getKey(), entry.getValue());
        \\    }
        \\    List<ApexSObject> rowChildren = (children != null && i < children.size() && children.get(i) != null) ? children.get(i) : new ArrayList<ApexSObject>();
        \\    if (relationshipName != null && !relationshipName.isBlank()) {
        \\    copy.set(relationshipName, rowChildren);
        \\    }
        \\    withChildren.add(copy);
        \\    }
        \\    return withChildren;
        \\  
    ;

    const signature_set_read_only = "public static Object setReadOnlyFieldsByName(ApexSObject objInstance, apexemu.runtime.System.Type deserializeType, Map<String, Object> properties)";
    const signature_deserialize_relationship = "public static Object deserializeParentsAndChildren(apexemu.runtime.System.Type parentsType, Schema.DescribeSObjectResult parentDescribe, Schema.SObjectField relationshipField, List<ApexSObject> parents, List<List<ApexSObject>> children)";

    const set_read_only_fixed = try replaceMethodBodyBySignature(gpa, text, signature_set_read_only, set_read_only_body);
    defer gpa.free(set_read_only_fixed);

    return replaceMethodBodyBySignature(gpa, set_read_only_fixed, signature_deserialize_relationship, deserialize_relationship_body);
}

fn replaceMethodBodyBySignature(
    gpa: std.mem.Allocator,
    text: []const u8,
    signature: []const u8,
    new_body: []const u8,
) ![]u8 {
    const signature_index = std.mem.indexOf(u8, text, signature) orelse return gpa.dupe(u8, text);
    const open_brace_index = std.mem.indexOfScalarPos(u8, text, signature_index, '{') orelse return gpa.dupe(u8, text);
    const close_brace_index = findMatchingBrace(text, open_brace_index) orelse return gpa.dupe(u8, text);

    return std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}",
        .{ text[0 .. open_brace_index + 1], new_body, text[close_brace_index..] },
    );
}

const DynamicBindEntry = struct {
    var_name: []u8,
    bind_names: std.ArrayList([]u8) = .empty,
};

fn rewriteDynamicWhereClauseQueryBinds(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var cursor: usize = 0;

    while (cursor < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
        const line_raw = std.mem.trimRight(u8, text[cursor..line_end], "\r");
        const line = std.mem.trim(u8, line_raw, " \t");
        if (!looksLikePublicMethodSignatureLine(line)) {
            cursor = if (line_end < text.len) line_end + 1 else text.len;
            continue;
        }

        const open_rel = std.mem.indexOfScalar(u8, line_raw, '{') orelse {
            cursor = if (line_end < text.len) line_end + 1 else text.len;
            continue;
        };
        const open_abs = cursor + open_rel;
        const close_abs = findMatchingBrace(text, open_abs) orelse {
            cursor = if (line_end < text.len) line_end + 1 else text.len;
            continue;
        };

        const method_body = text[(open_abs + 1)..close_abs];
        var method_bind_entries = try collectDynamicQueryBindEntriesForMethod(gpa, method_body);
        defer deinitDynamicBindEntries(gpa, &method_bind_entries);

        if (method_bind_entries.items.len > 0) {
            const initialized_body = try initializeBindVariablesInMethod(
                gpa,
                method_body,
                method_bind_entries.items,
            );
            defer gpa.free(initialized_body);

            const rewritten_body = try rewriteMethodQueryCallsWithDynamicBinds(
                gpa,
                initialized_body,
                method_bind_entries.items,
            );
            defer gpa.free(rewritten_body);

            if (!std.mem.eql(u8, rewritten_body, method_body)) {
                try out.appendSlice(gpa, text[last_emit .. open_abs + 1]);
                try out.appendSlice(gpa, rewritten_body);
                replaced = true;
                last_emit = close_abs;
            }
        }

        cursor = close_abs + 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn looksLikePublicMethodSignatureLine(line: []const u8) bool {
    if (line.len == 0) return false;
    if (!startsWithIgnoreCase(line, "public ")) return false;
    if (containsWordIgnoreCase(line, "class")) return false;
    if (containsWordIgnoreCase(line, "interface")) return false;
    if (containsWordIgnoreCase(line, "enum")) return false;
    if (std.mem.indexOfScalar(u8, line, '(') == null) return false;
    if (std.mem.indexOfScalar(u8, line, '{') == null) return false;
    if (std.mem.endsWith(u8, line, ";")) return false;
    return true;
}

fn collectDynamicQueryBindEntriesForMethod(
    gpa: std.mem.Allocator,
    method_body: []const u8,
) !std.ArrayList(DynamicBindEntry) {
    var entries: std.ArrayList(DynamicBindEntry) = .empty;
    errdefer deinitDynamicBindEntries(gpa, &entries);

    var lines = std.mem.splitScalar(u8, method_body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ".add(")) |add_index| {
            const base_expr = std.mem.trim(u8, trimmed[0..add_index], " \t");
            const list_var = lastIdentifier(base_expr) orelse continue;

            const open_paren = std.mem.indexOfScalarPos(u8, trimmed, add_index, '(') orelse continue;
            const close_paren = findMatchingParen(trimmed, open_paren) orelse continue;
            const args_raw = std.mem.trim(u8, trimmed[(open_paren + 1)..close_paren], " \t");
            if (args_raw.len == 0) continue;
            var args = try splitCallArguments(gpa, args_raw);
            defer args.deinit(gpa);
            if (args.items.len == 0) continue;

            const first_arg = std.mem.trim(u8, args.items[0], " \t");
            if (!isJavaStringLiteral(first_arg)) continue;

            var bind_names = try collectSoqlBindNamesFromJavaLiteral(gpa, first_arg);
            defer bind_names.deinit(gpa);
            if (bind_names.items.len == 0) continue;

            const entry = try getOrCreateDynamicBindEntry(gpa, &entries, list_var);
            for (bind_names.items) |bind_name| {
                try appendUniqueOwnedName(gpa, &entry.bind_names, bind_name);
            }
        }

        if (std.mem.indexOf(u8, trimmed, "ApexStrings.join(")) |join_index| {
            var join_open = join_index + "ApexStrings.join".len;
            while (join_open < trimmed.len and std.ascii.isWhitespace(trimmed[join_open])) : (join_open += 1) {}
            if (join_open >= trimmed.len or trimmed[join_open] != '(') continue;
            const join_close = findMatchingParen(trimmed, join_open) orelse continue;

            const join_args_raw = std.mem.trim(u8, trimmed[(join_open + 1)..join_close], " \t");
            if (join_args_raw.len == 0) continue;
            var join_args = try splitCallArguments(gpa, join_args_raw);
            defer join_args.deinit(gpa);
            if (join_args.items.len == 0) continue;

            const source_expr = std.mem.trim(u8, join_args.items[0], " \t");
            const source_var = lastIdentifier(source_expr) orelse continue;
            const source_index = dynamicBindEntryIndex(entries.items, source_var) orelse continue;

            const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const target_expr = std.mem.trim(u8, trimmed[0..eq_index], " \t");
            const target_var = lastIdentifier(target_expr) orelse continue;

            const target_entry = try getOrCreateDynamicBindEntry(gpa, &entries, target_var);
            for (entries.items[source_index].bind_names.items) |bind_name| {
                try appendUniqueOwnedName(gpa, &target_entry.bind_names, bind_name);
            }
        }
    }

    return entries;
}

fn initializeBindVariablesInMethod(
    gpa: std.mem.Allocator,
    method_body: []const u8,
    bind_entries: []const DynamicBindEntry,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var cursor: usize = 0;
    while (cursor < method_body.len) {
        const line_end = std.mem.indexOfScalarPos(u8, method_body, cursor, '\n') orelse method_body.len;
        const line_raw = method_body[cursor..line_end];

        if (try maybeInitializeBindDeclarationLine(gpa, line_raw, bind_entries)) |rewritten| {
            defer gpa.free(rewritten);
            try out.appendSlice(gpa, rewritten);
            changed = true;
        } else {
            try out.appendSlice(gpa, line_raw);
        }

        if (line_end < method_body.len) {
            try out.append(gpa, '\n');
            cursor = line_end + 1;
        } else {
            cursor = method_body.len;
        }
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, method_body);
    }
    return out.toOwnedSlice(gpa);
}

fn maybeInitializeBindDeclarationLine(
    gpa: std.mem.Allocator,
    line_raw: []const u8,
    bind_entries: []const DynamicBindEntry,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, line_raw, " \t");
    if (trimmed.len == 0) return null;
    if (!std.mem.endsWith(u8, trimmed, ";")) return null;

    const semicolon = std.mem.lastIndexOfScalar(u8, trimmed, ';') orelse return null;
    const declaration = std.mem.trimRight(u8, trimmed[0..semicolon], " \t");
    if (declaration.len == 0) return null;

    var type_split: ?usize = null;
    var angle_depth: i32 = 0;
    var idx: usize = 0;
    while (idx < declaration.len) : (idx += 1) {
        const ch = declaration[idx];
        switch (ch) {
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            ' ', '\t' => {
                if (angle_depth == 0) {
                    type_split = idx;
                    break;
                }
            },
            else => {},
        }
    }
    if (type_split == null) return null;

    const type_part = std.mem.trimRight(u8, declaration[0..type_split.?], " \t");
    if (!isLikelyLocalDeclarationType(type_part)) return null;
    const vars_part = std.mem.trim(u8, declaration[type_split.?..], " \t");
    if (type_part.len == 0 or vars_part.len == 0) return null;

    var variables = try splitTypeArguments(gpa, vars_part);
    defer variables.deinit(gpa);
    if (variables.items.len == 0) return null;

    var rewritten_vars: std.ArrayList(u8) = .empty;
    defer rewritten_vars.deinit(gpa);
    var changed = false;

    for (variables.items, 0..) |variable, var_idx| {
        const token = std.mem.trim(u8, variable, " \t");
        if (token.len == 0) continue;
        const has_initializer = std.mem.indexOfScalar(u8, token, '=') != null;
        const name = lastIdentifier(token) orelse continue;
        const needs_init = !has_initializer and isBindVariableName(bind_entries, name);

        if (var_idx != 0 and rewritten_vars.items.len > 0) {
            try rewritten_vars.appendSlice(gpa, ", ");
        }
        if (needs_init) {
            try appendFmt(gpa, &rewritten_vars, "{s} = null", .{token});
            changed = true;
        } else {
            try rewritten_vars.appendSlice(gpa, token);
        }
    }

    if (!changed) return null;

    var indent_len: usize = 0;
    while (indent_len < line_raw.len and (line_raw[indent_len] == ' ' or line_raw[indent_len] == '\t')) : (indent_len += 1) {}
    const indent = line_raw[0..indent_len];
    const rewritten = try std.fmt.allocPrint(gpa, "{s}{s} {s};", .{ indent, type_part, rewritten_vars.items });
    return rewritten;
}

fn isBindVariableName(bind_entries: []const DynamicBindEntry, name: []const u8) bool {
    for (bind_entries) |entry| {
        for (entry.bind_names.items) |bind_name| {
            if (std.ascii.eqlIgnoreCase(bind_name, name)) return true;
        }
    }
    return false;
}

fn isLikelyLocalDeclarationType(type_part: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_part, " \t");
    if (trimmed.len == 0) return false;

    const primitive_or_builtin = [_][]const u8{
        "int",     "long",   "double", "float",   "short",  "byte",
        "boolean", "char",   "String", "Integer", "Double", "Long",
        "Boolean", "Object", "Id",
    };
    for (primitive_or_builtin) |token| {
        if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
    }

    var base_end: usize = 0;
    while (base_end < trimmed.len and trimmed[base_end] != '<' and trimmed[base_end] != '.') : (base_end += 1) {}
    const base = if (base_end == 0) trimmed else trimmed[0..base_end];
    if (base.len == 0) return false;

    if (std.ascii.isUpper(base[0])) return true;
    if (startsWithIgnoreCase(base, "fflib_")) return true;
    return false;
}

fn rewriteMethodQueryCallsWithDynamicBinds(
    gpa: std.mem.Allocator,
    method_body: []const u8,
    bind_entries: []const DynamicBindEntry,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;

    const methods = [_]struct {
        method: []const u8,
        with_binds_method: []const u8,
        already_with_binds: bool,
    }{
        .{ .method = "countQueryWithBinds", .with_binds_method = "countQueryWithBinds", .already_with_binds = true },
        .{ .method = "getQueryLocatorWithBinds", .with_binds_method = "getQueryLocatorWithBinds", .already_with_binds = true },
        .{ .method = "queryWithBinds", .with_binds_method = "queryWithBinds", .already_with_binds = true },
        .{ .method = "countQuery", .with_binds_method = "countQueryWithBinds", .already_with_binds = false },
        .{ .method = "getQueryLocator", .with_binds_method = "getQueryLocatorWithBinds", .already_with_binds = false },
        .{ .method = "query", .with_binds_method = "queryWithBinds", .already_with_binds = false },
    };

    while (i < method_body.len) : (i += 1) {
        const ch = method_body[i];
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
        if (!startsWithIgnoreCase(method_body[i..], "Database.")) continue;

        const method_start = i + "Database.".len;
        var matched_index: ?usize = null;
        for (methods, 0..) |candidate, idx| {
            if (!startsWithIgnoreCase(method_body[method_start..], candidate.method)) continue;
            const boundary = method_start + candidate.method.len;
            if (boundary < method_body.len and isIdentifierChar(method_body[boundary])) continue;
            matched_index = idx;
            break;
        }
        if (matched_index == null) continue;
        const matched = methods[matched_index.?];

        var open_paren = method_start + matched.method.len;
        while (open_paren < method_body.len and std.ascii.isWhitespace(method_body[open_paren])) : (open_paren += 1) {}
        if (open_paren >= method_body.len or method_body[open_paren] != '(') continue;
        const close_paren = findMatchingParen(method_body, open_paren) orelse continue;

        const args_raw = std.mem.trim(u8, method_body[(open_paren + 1)..close_paren], " \t");
        if (args_raw.len == 0) continue;
        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);
        if (args.items.len == 0) continue;

        const query_arg = std.mem.trim(u8, args.items[0], " \t");
        if (query_arg.len == 0) continue;
        var required_bind_names = try collectBindNamesFromQueryExpression(gpa, query_arg, bind_entries);
        defer deinitOwnedNameList(gpa, &required_bind_names);
        if (required_bind_names.items.len == 0) continue;

        var rewritten_bind_arg: ?[]u8 = null;
        const replacement_method = matched.with_binds_method;
        var tail_start_index: usize = 1;

        if (matched.already_with_binds) {
            if (args.items.len >= 2) {
                rewritten_bind_arg = try rewriteBindMapArgumentWithMissingBinds(
                    gpa,
                    std.mem.trim(u8, args.items[1], " \t"),
                    required_bind_names.items,
                );
                if (rewritten_bind_arg == null) continue;
                tail_start_index = 2;
            } else {
                rewritten_bind_arg = try buildBindMapArgument(gpa, required_bind_names.items);
                tail_start_index = 1;
            }
        } else {
            rewritten_bind_arg = try buildBindMapArgument(gpa, required_bind_names.items);
            tail_start_index = 1;
        }
        defer if (rewritten_bind_arg) |value| gpa.free(value);

        var replacement: std.ArrayList(u8) = .empty;
        defer replacement.deinit(gpa);
        try appendFmt(gpa, &replacement, "Database.{s}(", .{replacement_method});
        try replacement.appendSlice(gpa, query_arg);
        if (rewritten_bind_arg) |value| {
            try replacement.appendSlice(gpa, ", ");
            try replacement.appendSlice(gpa, value);
        }
        if (tail_start_index < args.items.len) {
            for (args.items[tail_start_index..]) |tail_arg| {
                try replacement.appendSlice(gpa, ", ");
                try replacement.appendSlice(gpa, std.mem.trim(u8, tail_arg, " \t"));
            }
        }
        try replacement.append(gpa, ')');

        try out.appendSlice(gpa, method_body[last_emit..i]);
        try out.appendSlice(gpa, replacement.items);
        replaced = true;
        i = close_paren;
        last_emit = close_paren + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, method_body);
    }
    try out.appendSlice(gpa, method_body[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn collectBindNamesFromQueryExpression(
    gpa: std.mem.Allocator,
    query_expr: []const u8,
    bind_entries: []const DynamicBindEntry,
) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer deinitOwnedNameList(gpa, &out);

    var in_double = false;
    var escaped = false;
    var literal_start: usize = 0;
    var i: usize = 0;
    while (i < query_expr.len) : (i += 1) {
        const ch = query_expr[i];
        if (!in_double) {
            if (ch == '"') {
                in_double = true;
                escaped = false;
                literal_start = i;
            }
            continue;
        }

        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch != '"') continue;

        const literal = query_expr[literal_start .. i + 1];
        var literal_bind_names = try collectSoqlBindNamesFromJavaLiteral(gpa, literal);
        defer literal_bind_names.deinit(gpa);
        for (literal_bind_names.items) |bind_name| {
            try appendUniqueOwnedName(gpa, &out, bind_name);
        }
        in_double = false;
        escaped = false;
    }

    for (bind_entries) |entry| {
        if (!containsWordIgnoreCase(query_expr, entry.var_name)) continue;
        for (entry.bind_names.items) |bind_name| {
            try appendUniqueOwnedName(gpa, &out, bind_name);
        }
    }

    return out;
}

fn buildBindMapArgument(gpa: std.mem.Allocator, bind_names: []const []u8) ![]u8 {
    var bind_map_args: std.ArrayList(u8) = .empty;
    defer bind_map_args.deinit(gpa);

    for (bind_names, 0..) |bind_name, idx| {
        const bind_expr = try convertBindReferenceToJava(gpa, bind_name);
        defer gpa.free(bind_expr);
        if (idx != 0) try bind_map_args.appendSlice(gpa, ", ");
        try appendFmt(gpa, &bind_map_args, "\"{s}\", {s}", .{ bind_name, bind_expr });
    }

    return std.fmt.allocPrint(gpa, "ApexCollections.bindMap({s})", .{bind_map_args.items});
}

fn rewriteBindMapArgumentWithMissingBinds(
    gpa: std.mem.Allocator,
    bind_arg: []const u8,
    required_bind_names: []const []u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, bind_arg, " \t");
    if (!startsWithIgnoreCase(trimmed, "ApexCollections.bindMap")) return null;

    var open = "ApexCollections.bindMap".len;
    while (open < trimmed.len and std.ascii.isWhitespace(trimmed[open])) : (open += 1) {}
    if (open >= trimmed.len or trimmed[open] != '(') return null;
    const close = findMatchingParen(trimmed, open) orelse return null;
    if (std.mem.trim(u8, trimmed[(close + 1)..], " \t").len != 0) return null;

    const inner_raw = std.mem.trim(u8, trimmed[(open + 1)..close], " \t");
    var existing_names: std.ArrayList([]const u8) = .empty;
    defer existing_names.deinit(gpa);

    if (inner_raw.len > 0) {
        var existing_args = try splitCallArguments(gpa, inner_raw);
        defer existing_args.deinit(gpa);
        for (existing_args.items, 0..) |arg, idx| {
            if ((idx % 2) != 0) continue;
            const key_raw = std.mem.trim(u8, arg, " \t");
            if (!isJavaStringLiteral(key_raw)) continue;
            try existing_names.append(gpa, key_raw[1 .. key_raw.len - 1]);
        }
    }

    var updated_inner: std.ArrayList(u8) = .empty;
    defer updated_inner.deinit(gpa);
    if (inner_raw.len > 0) {
        try updated_inner.appendSlice(gpa, inner_raw);
    }

    var changed = false;
    for (required_bind_names) |bind_name| {
        if (containsIgnoreCaseNameSlice(existing_names.items, bind_name)) continue;
        const bind_expr = try convertBindReferenceToJava(gpa, bind_name);
        defer gpa.free(bind_expr);
        if (updated_inner.items.len > 0) try updated_inner.appendSlice(gpa, ", ");
        try appendFmt(gpa, &updated_inner, "\"{s}\", {s}", .{ bind_name, bind_expr });
        try existing_names.append(gpa, bind_name);
        changed = true;
    }

    if (!changed) return null;
    const updated = try std.fmt.allocPrint(gpa, "ApexCollections.bindMap({s})", .{updated_inner.items});
    return updated;
}

fn appendUniqueOwnedName(
    gpa: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    name: []const u8,
) !void {
    if (containsIgnoreCaseOwnedName(names.items, name)) return;
    try names.append(gpa, try gpa.dupe(u8, name));
}

fn containsIgnoreCaseOwnedName(items: []const []u8, name: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item, name)) return true;
    }
    return false;
}

fn containsIgnoreCaseNameSlice(items: []const []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item, name)) return true;
    }
    return false;
}

fn getOrCreateDynamicBindEntry(
    gpa: std.mem.Allocator,
    entries: *std.ArrayList(DynamicBindEntry),
    var_name: []const u8,
) !*DynamicBindEntry {
    if (dynamicBindEntryIndex(entries.items, var_name)) |existing| {
        return &entries.items[existing];
    }

    const name_copy = try gpa.dupe(u8, var_name);
    errdefer gpa.free(name_copy);
    try entries.append(gpa, .{
        .var_name = name_copy,
    });
    return &entries.items[entries.items.len - 1];
}

fn dynamicBindEntryIndex(entries: []const DynamicBindEntry, var_name: []const u8) ?usize {
    for (entries, 0..) |entry, idx| {
        if (std.ascii.eqlIgnoreCase(entry.var_name, var_name)) return idx;
    }
    return null;
}

fn deinitOwnedNameList(gpa: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |name| gpa.free(name);
    names.deinit(gpa);
}

fn deinitDynamicBindEntries(gpa: std.mem.Allocator, entries: *std.ArrayList(DynamicBindEntry)) void {
    for (entries.items) |*entry| {
        gpa.free(entry.var_name);
        for (entry.bind_names.items) |bind_name| gpa.free(bind_name);
        entry.bind_names.deinit(gpa);
    }
    entries.deinit(gpa);
}

fn rewriteInterfaceCompatibilityFixups(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    return gpa.dupe(u8, text);
}

fn rewriteApexSystemUtilityCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "System.TypeException", .to = "apexemu.runtime.System.TypeException" },
        .{ .from = "System.IllegalArgumentException", .to = "apexemu.runtime.System.IllegalArgumentException" },
        .{ .from = "System.Exception", .to = "apexemu.runtime.System.Exception" },
        .{ .from = "System.Type.", .to = "apexemu.runtime.System.Type." },
        .{ .from = "System.AccessType.", .to = "apexemu.runtime.System.AccessType." },
        .{ .from = "System.AccessLevel.", .to = "apexemu.runtime.System.AccessLevel." },
        .{ .from = "System.SObjectAccessDecision", .to = "apexemu.runtime.System.SObjectAccessDecision" },
        .{ .from = "System.NoAccessException", .to = "apexemu.runtime.System.NoAccessException" },
        .{ .from = "System.SecurityException", .to = "apexemu.runtime.System.SecurityException" },
        .{ .from = "System.JSONException", .to = "apexemu.runtime.System.JSONException" },
        .{ .from = "System.QueueableContext", .to = "apexemu.runtime.System.QueueableContext" },
        .{ .from = "System.SchedulableContext", .to = "apexemu.runtime.System.SchedulableContext" },
        .{ .from = "System.LoggingLevel.", .to = "apexemu.runtime.System.LoggingLevel." },
        .{ .from = "System.Quiddity.", .to = "apexemu.runtime.System.Quiddity." },
        .{ .from = "System.JSON.deserialize(", .to = "apexemu.runtime.System.JSON.deserialize(" },
        .{ .from = "System.JSON.deserializeStrict(", .to = "apexemu.runtime.System.JSON.deserializeStrict(" },
        .{ .from = "System.JSON.deserializeUntyped(", .to = "apexemu.runtime.System.JSON.deserializeUntyped(" },
        .{ .from = "System.JSON.serializePretty(", .to = "apexemu.runtime.System.JSON.serializePretty(" },
        .{ .from = "System.JSON.serialize(", .to = "apexemu.runtime.System.JSON.serialize(" },
        .{ .from = "System.assertEquals(", .to = "SystemAssert.assertEquals(" },
        .{ .from = "System.assertNotEquals(", .to = "SystemAssert.assertNotEquals(" },
        .{ .from = "System.assertFalse(", .to = "SystemAssert.assertFalse(" },
        .{ .from = "System.assertTrue(", .to = "SystemAssert.assertTrue(" },
        .{ .from = "System.assertNull(", .to = "SystemAssert.assertNull(" },
        .{ .from = "System.assertNotNull(", .to = "SystemAssert.assertNotNull(" },
        .{ .from = "System.fail(", .to = "SystemAssert.fail(" },
        .{ .from = "System.assert(", .to = "SystemAssert.assertTrue(" },
        .{ .from = "System.today(", .to = "apexemu.runtime.System.today(" },
        .{ .from = "catch (apexemu.runtime.System.TypeException", .to = "catch (apexemu.runtime.System.TypeException | ClassCastException" },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        var matched = false;
        for (patterns) |pattern| {
            if (i + pattern.from.len > text.len) continue;
            if (!startsWithIgnoreCase(text[i..], pattern.from)) continue;
            if (i > 0 and isIdentifierChar(text[i - 1])) continue;
            const runtime_prefix = "apexemu.runtime.";
            if (i >= runtime_prefix.len and startsWithIgnoreCase(text[(i - runtime_prefix.len)..], runtime_prefix)) continue;
            try out.appendSlice(gpa, pattern.to);
            i += pattern.from.len;
            replaced = true;
            matched = true;
            break;
        }
        if (matched) continue;

        try out.append(gpa, text[i]);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteDateArithmetic(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "apexemu.runtime.System.today(";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        if (i + marker.len <= text.len and std.mem.eql(u8, text[i .. i + marker.len], marker)) {
            // Find the closing paren of today(...)
            const open_paren = i + marker.len - 1; // index of '('
            if (findMatchingParen(text, open_paren)) |close_paren| {
                // Check what follows the closing paren (skip spaces)
                var after = close_paren + 1;
                while (after < text.len and text[after] == ' ') : (after += 1) {}

                if (after < text.len and (text[after] == '-' or text[after] == '+')) {
                    const op = text[after];
                    var expr_start = after + 1;
                    while (expr_start < text.len and text[expr_start] == ' ') : (expr_start += 1) {}

                    // Capture the operand expression: track paren depth, stop at ';' or ')' at depth 0
                    var expr_end = expr_start;
                    var depth: i32 = 0;
                    while (expr_end < text.len) {
                        const ch = text[expr_end];
                        if (ch == '(') {
                            depth += 1;
                        } else if (ch == ')') {
                            if (depth == 0) break;
                            depth -= 1;
                        } else if (ch == ';' and depth == 0) {
                            break;
                        }
                        expr_end += 1;
                    }

                    // Trim trailing spaces from the expression
                    var trimmed_end = expr_end;
                    while (trimmed_end > expr_start and text[trimmed_end - 1] == ' ') : (trimmed_end -= 1) {}

                    if (trimmed_end > expr_start) {
                        const expr = text[expr_start..trimmed_end];
                        // Emit: apexemu.runtime.System.today().addDays(expr) or .addDays(-(expr))
                        try out.appendSlice(gpa, text[i .. close_paren + 1]);
                        if (op == '-') {
                            try out.appendSlice(gpa, ".addDays(-(");
                            try out.appendSlice(gpa, expr);
                            try out.appendSlice(gpa, "))");
                        } else {
                            try out.appendSlice(gpa, ".addDays(");
                            try out.appendSlice(gpa, expr);
                            try out.appendSlice(gpa, ")");
                        }
                        i = expr_end;
                        replaced = true;
                        continue;
                    }
                }
            }
        }

        try out.append(gpa, text[i]);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteApexStrictEqualityOperators(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    var in_double = false;
    var in_single = false;
    var single_escaped = false;
    while (i < text.len) {
        const ch = text[i];
        if (in_single) {
            try out.append(gpa, ch);
            if (single_escaped) {
                single_escaped = false;
                i += 1;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                i += 1;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                try out.append(gpa, text[i + 1]);
                i += 2;
                continue;
            }
            if (ch == '\'') in_single = false;
            i += 1;
            continue;
        }
        if (in_double) {
            try out.append(gpa, ch);
            if (ch == '\\' and i + 1 < text.len) {
                try out.append(gpa, text[i + 1]);
                i += 2;
                continue;
            }
            if (ch == '"') in_double = false;
            i += 1;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            single_escaped = false;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }

        if (i + 3 <= text.len and std.mem.eql(u8, text[i .. i + 3], "!==")) {
            try out.appendSlice(gpa, "!=");
            replaced = true;
            i += 3;
            continue;
        }
        if (i + 3 <= text.len and std.mem.eql(u8, text[i .. i + 3], "===")) {
            try out.appendSlice(gpa, "==");
            replaced = true;
            i += 3;
            continue;
        }

        try out.append(gpa, ch);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteApexNotEqualsOperator(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    var in_double = false;
    var in_single = false;
    var single_escaped = false;
    while (i < text.len) {
        const ch = text[i];
        if (in_single) {
            try out.append(gpa, ch);
            if (single_escaped) {
                single_escaped = false;
                i += 1;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                i += 1;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                try out.append(gpa, text[i + 1]);
                i += 2;
                continue;
            }
            if (ch == '\'') in_single = false;
            i += 1;
            continue;
        }
        if (in_double) {
            try out.append(gpa, ch);
            if (ch == '\\' and i + 1 < text.len) {
                try out.append(gpa, text[i + 1]);
                i += 2;
                continue;
            }
            if (ch == '"') in_double = false;
            i += 1;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            single_escaped = false;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        if (i + 2 <= text.len and std.mem.eql(u8, text[i .. i + 2], "<>")) {
            try out.appendSlice(gpa, "!=");
            replaced = true;
            i += 2;
            continue;
        }
        try out.append(gpa, ch);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteSystemStatusCodeConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (in_single) {
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }
        if (!startsWithIgnoreCase(text[i..], "System.StatusCode.")) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;

        const start = i;
        const name_start = start + "System.StatusCode.".len;
        if (name_start >= text.len or !isIdentifierChar(text[name_start])) continue;
        var end = name_start + 1;
        while (end < text.len and isIdentifierChar(text[end])) : (end += 1) {}
        const code_name = text[name_start..end];

        try out.appendSlice(gpa, text[last_emit..start]);
        try appendFmt(gpa, &out, "\"{s}\"", .{code_name});
        replaced = true;
        i = end - 1;
        last_emit = end;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

const RelationalOperator = enum {
    gt,
    lt,
    gte,
    lte,
};

const RelationalMatch = struct {
    op: RelationalOperator,
    start: usize,
    len: usize,
};

fn rewriteStringRelationalComparisons(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (startsWithWordIgnoreCase(trimmed, "if") or startsWithWordIgnoreCase(trimmed, "while")) {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return gpa.dupe(u8, text);
        const close = findMatchingParen(trimmed, open) orelse return gpa.dupe(u8, text);
        if (close > open + 1) {
            const condition_raw = std.mem.trim(u8, trimmed[(open + 1)..close], " \t");
            const rewritten_condition = try rewriteStringRelationalComparisons(gpa, condition_raw);
            defer gpa.free(rewritten_condition);
            if (!std.mem.eql(u8, rewritten_condition, condition_raw)) {
                const prefix = trimmed[0 .. open + 1];
                const suffix = trimmed[close..];
                return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix, rewritten_condition, suffix });
            }
        }
    }

    if (findTopLevelLogicalOperator(text)) |lp| {
        const left = text[0..lp.start];
        const op_text = text[lp.start .. lp.start + 2];
        const right = text[lp.start + 2 ..];
        const left_rewritten = try rewriteStringRelationalComparisons(gpa, left);
        defer gpa.free(left_rewritten);
        const right_rewritten = try rewriteStringRelationalComparisons(gpa, right);
        defer gpa.free(right_rewritten);
        if (!std.mem.eql(u8, left_rewritten, left) or !std.mem.eql(u8, right_rewritten, right)) {
            return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ left_rewritten, op_text, right_rewritten });
        }
    }

    if (try rewriteTernaryStringRelationalComparisons(gpa, text)) |rewritten| {
        return rewritten;
    }

    if (try rewriteNestedParenStringRelationalComparisons(gpa, text)) |rewritten| {
        return rewritten;
    }

    const op_match = findTopLevelRelationalMatch(text) orelse return gpa.dupe(u8, text);
    const lhs = std.mem.trim(u8, text[0..op_match.start], " \t");
    const rhs = std.mem.trim(u8, text[(op_match.start + op_match.len)..], " \t");
    if (lhs.len == 0 or rhs.len == 0) return gpa.dupe(u8, text);
    if (findTopLevelLogicalOperator(lhs) != null or findTopLevelLogicalOperator(rhs) != null) {
        return gpa.dupe(u8, text);
    }
    if (!isLikelyStringishComparisonOperand(lhs) and !isLikelyStringishComparisonOperand(rhs)) {
        return gpa.dupe(u8, text);
    }

    const predicate = switch (op_match.op) {
        .gt => "> 0",
        .lt => "< 0",
        .gte => ">= 0",
        .lte => "<= 0",
    };
    return std.fmt.allocPrint(gpa, "ApexStrings.compareTo({s}, {s}) {s}", .{ lhs, rhs, predicate });
}

fn rewriteNestedParenStringRelationalComparisons(gpa: std.mem.Allocator, text: []const u8) anyerror!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }
        if (ch != '(') continue;

        const close = findMatchingParen(text, i) orelse continue;
        const inner = text[(i + 1)..close];
        const rewritten_inner = try rewriteStringRelationalComparisons(gpa, inner);
        defer gpa.free(rewritten_inner);
        if (std.mem.eql(u8, rewritten_inner, inner)) {
            i = close;
            continue;
        }

        try out.appendSlice(gpa, text[last_emit .. i + 1]);
        try out.appendSlice(gpa, rewritten_inner);
        replaced = true;
        last_emit = close;
        i = close;
    }

    if (!replaced) return null;
    try out.appendSlice(gpa, text[last_emit..]);
    return try out.toOwnedSlice(gpa);
}

fn rewriteTernaryStringRelationalComparisons(gpa: std.mem.Allocator, text: []const u8) anyerror!?[]u8 {
    const ternary = findTopLevelTernary(text) orelse return null;

    const condition = text[0..ternary.question];
    const when_true = text[(ternary.question + 1)..ternary.colon];
    const when_false = text[ternary.colon + 1 ..];

    const rewritten_condition = try rewriteStringRelationalComparisons(gpa, condition);
    defer gpa.free(rewritten_condition);
    const rewritten_true = try rewriteStringRelationalComparisons(gpa, when_true);
    defer gpa.free(rewritten_true);
    const rewritten_false = try rewriteStringRelationalComparisons(gpa, when_false);
    defer gpa.free(rewritten_false);

    if (std.mem.eql(u8, rewritten_condition, condition) and
        std.mem.eql(u8, rewritten_true, when_true) and
        std.mem.eql(u8, rewritten_false, when_false))
    {
        return null;
    }

    return try std.fmt.allocPrint(gpa, "{s}?{s}:{s}", .{ rewritten_condition, rewritten_true, rewritten_false });
}

fn findTopLevelTernary(text: []const u8) ?struct { question: usize, colon: usize } {
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var ternary_depth: i32 = 0;
    var question_pos: ?usize = null;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        switch (ch) {
            '\'' => in_single = true,
            '"' => {
                in_double = true;
                escaped = false;
            },
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
            '?' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    ternary_depth += 1;
                    if (question_pos == null) question_pos = i;
                }
            },
            ':' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and ternary_depth > 0) {
                    ternary_depth -= 1;
                    if (ternary_depth == 0 and question_pos != null) {
                        return .{ .question = question_pos.?, .colon = i };
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn findTopLevelRelationalMatch(text: []const u8) ?RelationalMatch {
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

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
            else => {},
        }
        if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0) continue;

        if (i + 2 <= text.len) {
            const two = text[i .. i + 2];
            if (std.mem.eql(u8, two, ">=") and hasWhitespaceAroundOperator(text, i, 2)) {
                return .{ .op = .gte, .start = i, .len = 2 };
            }
            if (std.mem.eql(u8, two, "<=") and hasWhitespaceAroundOperator(text, i, 2)) {
                return .{ .op = .lte, .start = i, .len = 2 };
            }
        }
        if (ch == '>') {
            if (i + 1 < text.len and text[i + 1] == '>') continue;
            if (i > 0 and (text[i - 1] == '-' or text[i - 1] == '=')) continue;
            if (isLikelyGenericCloseAngle(text, i)) continue;
            if (!hasWhitespaceAroundOperator(text, i, 1)) continue;
            return .{ .op = .gt, .start = i, .len = 1 };
        }
        if (ch == '<') {
            if (i + 1 < text.len and text[i + 1] == '<') continue;
            if (i > 0 and text[i - 1] == '=') continue;
            if (!hasWhitespaceAroundOperator(text, i, 1)) continue;
            return .{ .op = .lt, .start = i, .len = 1 };
        }
    }
    return null;
}

fn isLikelyGenericCloseAngle(text: []const u8, angle_index: usize) bool {
    if (angle_index >= text.len) return false;

    const next_non_ws = nextNonWhitespaceChar(text, angle_index + 1) orelse return false;
    switch (next_non_ws) {
        '{', '(', ')', ',', ';', '.', '?' => {},
        else => return false,
    }

    const prev_non_ws = prevNonWhitespaceChar(text, angle_index) orelse return false;
    if (!isIdentifierChar(prev_non_ws) and prev_non_ws != '>' and prev_non_ws != ']' and prev_non_ws != '?') {
        return false;
    }

    var cursor = angle_index;
    while (cursor > 0) {
        cursor -= 1;
        const ch = text[cursor];
        if (ch == '<') return true;
        if (ch == ';' or ch == '=' or ch == '(' or ch == ')' or ch == '{' or ch == '}') break;
    }
    return false;
}

fn nextNonWhitespaceChar(text: []const u8, start: usize) ?u8 {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isWhitespace(text[i])) return text[i];
    }
    return null;
}

fn prevNonWhitespaceChar(text: []const u8, before: usize) ?u8 {
    var i = before;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return text[i];
    }
    return null;
}

fn hasWhitespaceAroundOperator(text: []const u8, start: usize, len: usize) bool {
    if (start + len > text.len) return false;
    const left_ok = if (start == 0) false else std.ascii.isWhitespace(text[start - 1]);
    const right_idx = start + len;
    const right_ok = if (right_idx >= text.len) false else std.ascii.isWhitespace(text[right_idx]);
    return left_ok or right_ok;
}

fn isLikelyStringishComparisonOperand(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') return true;
    if (std.mem.indexOf(u8, trimmed, ".name") != null or std.mem.indexOf(u8, trimmed, ".Name") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "DeveloperName") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "Label") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "String.valueOf") != null or std.mem.indexOf(u8, trimmed, "ApexStrings.") != null) return true;
    if (std.mem.indexOf(u8, trimmed, ".substring(") != null or
        std.mem.indexOf(u8, trimmed, ".trim(") != null or
        std.mem.indexOf(u8, trimmed, ".toUpperCase(") != null or
        std.mem.indexOf(u8, trimmed, ".toLowerCase(") != null)
        return true;
    if (lastIdentifier(trimmed)) |identifier| {
        if (endsWithIgnoreCase(identifier, "Id") or
            endsWithIgnoreCase(identifier, "Name") or
            endsWithIgnoreCase(identifier, "Label"))
            return true;
    }
    return std.ascii.eqlIgnoreCase(trimmed, "name") or std.ascii.eqlIgnoreCase(trimmed, "label");
}

/// Wraps comparisons involving safe-navigation ternary results with ApexCompare
/// to avoid NPE from Java auto-unboxing of null.
/// e.g. `((x) == null ? null : (x).length()) > 2` → `ApexCompare.gt(((x) == null ? null : (x).length()), 2)`
fn wrapNullSafeComparisons(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t");

    // Handle if/while conditions by recursing into the condition part
    if (startsWithWordIgnoreCase(trimmed, "if") or startsWithWordIgnoreCase(trimmed, "while")) {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return gpa.dupe(u8, text);
        const close = findMatchingParen(trimmed, open) orelse return gpa.dupe(u8, text);
        if (close > open + 1) {
            const condition_raw = std.mem.trim(u8, trimmed[(open + 1)..close], " \t");
            const rewritten = try wrapNullSafeComparisons(gpa, condition_raw);
            defer gpa.free(rewritten);
            if (!std.mem.eql(u8, rewritten, condition_raw)) {
                const prefix = trimmed[0 .. open + 1];
                const suffix = trimmed[close..];
                return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix, rewritten, suffix });
            }
        }
        return gpa.dupe(u8, text);
    }

    // Split by top-level && or ||, process each side recursively
    const logical_pos = findTopLevelLogicalOperator(text);
    if (logical_pos) |lp| {
        const left = text[0..lp.start];
        const op_text = text[lp.start .. lp.start + 2]; // "&&" or "||"
        const right = text[lp.start + 2 ..];
        const left_rewritten = try wrapNullSafeComparisons(gpa, left);
        defer gpa.free(left_rewritten);
        const right_rewritten = try wrapNullSafeComparisons(gpa, right);
        defer gpa.free(right_rewritten);
        if (!std.mem.eql(u8, left_rewritten, left) or !std.mem.eql(u8, right_rewritten, right)) {
            return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ left_rewritten, op_text, right_rewritten });
        }
        return gpa.dupe(u8, text);
    }

    // Find top-level relational operator
    const op_match = findTopLevelRelationalMatch(text) orelse return gpa.dupe(u8, text);
    const lhs = std.mem.trim(u8, text[0..op_match.start], " \t");
    const rhs = std.mem.trim(u8, text[(op_match.start + op_match.len)..], " \t");
    if (lhs.len == 0 or rhs.len == 0) return gpa.dupe(u8, text);

    // Check if either side contains the safe navigation null ternary pattern
    const has_null_safe = std.mem.indexOf(u8, lhs, "== null ? null :") != null or
        std.mem.indexOf(u8, rhs, "== null ? null :") != null;
    if (!has_null_safe) return gpa.dupe(u8, text);

    const method = switch (op_match.op) {
        .gt => "gt",
        .lt => "lt",
        .gte => "gte",
        .lte => "lte",
    };

    return std.fmt.allocPrint(gpa, "ApexCompare.{s}({s}, {s})", .{ method, lhs, rhs });
}

fn findTopLevelLogicalOperator(text: []const u8) ?struct { start: usize } {
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var paren_depth: i32 = 0;

    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            else => {},
        }
        if (paren_depth != 0) continue;

        if (text[i] == '&' and text[i + 1] == '&') return .{ .start = i };
        if (text[i] == '|' and text[i + 1] == '|') return .{ .start = i };
    }
    return null;
}

fn rewriteTriggerContextPropertyAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
        check_left: bool,
    }{
        .{ .from = "Trigger.newMap", .to = "Trigger.getNewMap()", .check_left = true },
        .{ .from = "Trigger.oldMap", .to = "Trigger.getOldMap()", .check_left = true },
        .{ .from = "Trigger.isUndelete", .to = "Trigger.isUndelete()", .check_left = true },
        .{ .from = "Trigger.isUnDelete", .to = "Trigger.isUndelete()", .check_left = true },
        .{ .from = "Trigger.isExecuting", .to = "Trigger.isExecuting()", .check_left = true },
        .{ .from = "Trigger.isBefore", .to = "Trigger.isBefore()", .check_left = true },
        .{ .from = "Trigger.isAfter", .to = "Trigger.isAfter()", .check_left = true },
        .{ .from = "Trigger.isInsert", .to = "Trigger.isInsert()", .check_left = true },
        .{ .from = "Trigger.isUpdate", .to = "Trigger.isUpdate()", .check_left = true },
        .{ .from = "Trigger.isDelete", .to = "Trigger.isDelete()", .check_left = true },
        .{ .from = "Trigger.size", .to = "Trigger.size()", .check_left = true },
        .{ .from = "Trigger.operationType", .to = "Trigger.getOperationType()", .check_left = true },
        .{ .from = "Trigger.new", .to = "Trigger.getNew()", .check_left = true },
        .{ .from = "Trigger.old", .to = "Trigger.getOld()", .check_left = true },
        // Apex is case-insensitive; normalize REST API property casing for Java
        .{ .from = ".requestUri", .to = ".requestURI", .check_left = false },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    var in_double = false;
    var escaped = false;
    while (i < text.len) {
        const ch = text[i];
        if (in_double) {
            try out.append(gpa, ch);
            if (escaped) {
                escaped = false;
                i += 1;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                i += 1;
                continue;
            }
            if (ch == '"') in_double = false;
            i += 1;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }

        var matched = false;
        for (patterns) |pattern| {
            if (i + pattern.from.len > text.len) continue;
            if (!startsWithIgnoreCase(text[i..], pattern.from)) continue;
            if (pattern.check_left and i > 0 and isIdentifierChar(text[i - 1])) continue;

            const boundary = i + pattern.from.len;
            if (boundary < text.len and isIdentifierChar(text[boundary])) continue;

            const next = nextNonSpace(text, boundary);
            if (next < text.len and text[next] == '(') continue;

            try out.appendSlice(gpa, pattern.to);
            i = boundary;
            matched = true;
            replaced = true;
            break;
        }
        if (matched) continue;

        try out.append(gpa, ch);
        i += 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

const SafeNavigationRewrite = struct {
    text: []u8,
    replaced: bool,
};

fn rewriteApexSafeNavigationOperators(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, text);
    while (true) {
        const rewrite = try rewriteFirstApexSafeNavigationOperator(gpa, current);
        gpa.free(current);
        current = rewrite.text;
        if (!rewrite.replaced) return current;
    }
}

fn rewriteFirstApexSafeNavigationOperator(gpa: std.mem.Allocator, text: []const u8) !SafeNavigationRewrite {
    var i: usize = 0;
    var in_double = false;
    var escaped = false;
    while (i + 1 < text.len) : (i += 1) {
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
            escaped = false;
            continue;
        }
        if (ch != '?' or text[i + 1] != '.') continue;

        const left_start = findSafeNavigationLeftStart(text, i);
        const left_expr = std.mem.trim(u8, text[left_start..i], " \t");
        if (left_expr.len == 0) continue;

        var member_start = i + 2;
        while (member_start < text.len and std.ascii.isWhitespace(text[member_start])) : (member_start += 1) {}
        if (member_start >= text.len or !isIdentifierChar(text[member_start])) continue;

        var member_end = member_start;
        while (member_end < text.len and isIdentifierChar(text[member_end])) : (member_end += 1) {}

        var cursor = member_end;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor < text.len and text[cursor] == '(') {
            const close = findMatchingParen(text, cursor) orelse continue;
            member_end = close + 1;
        }

        const member_expr = std.mem.trim(u8, text[member_start..member_end], " \t");
        if (member_expr.len == 0) continue;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, text[0..left_start]);
        try appendFmt(
            gpa,
            &out,
            "(({s}) == null ? null : ({s}).{s})",
            .{ left_expr, left_expr, member_expr },
        );
        try out.appendSlice(gpa, text[member_end..]);
        return .{
            .text = try out.toOwnedSlice(gpa),
            .replaced = true,
        };
    }

    return .{
        .text = try gpa.dupe(u8, text),
        .replaced = false,
    };
}

fn findSafeNavigationLeftStart(text: []const u8, op_pos: usize) usize {
    if (op_pos == 0) return 0;
    var i = op_pos;
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}
    if (i == 0) return 0;

    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    while (i > 0) {
        const ch = text[i - 1];
        switch (ch) {
            ')' => paren_depth += 1,
            ']' => bracket_depth += 1,
            '}' => brace_depth += 1,
            '(' => {
                if (paren_depth == 0) return i;
                paren_depth -= 1;
            },
            '[' => {
                if (bracket_depth == 0) return i;
                bracket_depth -= 1;
            },
            '{' => {
                if (brace_depth == 0) return i;
                brace_depth -= 1;
            },
            else => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    if (std.ascii.isWhitespace(ch) or isSafeNavigationBoundaryChar(ch)) return i;
                }
            },
        }
        i -= 1;
    }
    return 0;
}

fn isSafeNavigationBoundaryChar(ch: u8) bool {
    return switch (ch) {
        ',', ';', ':', '+', '-', '*', '/', '%', '&', '|', '^', '=', '!', '<', '>', '?' => true,
        else => false,
    };
}

fn rewriteNullCoalescingOperator(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    const op = findTopLevelNullCoalescingOperator(trimmed) orelse return gpa.dupe(u8, text);

    const left_raw = std.mem.trim(u8, trimmed[0..op], " \t");
    const right_raw = std.mem.trim(u8, trimmed[(op + 2)..], " \t");
    if (left_raw.len == 0 or right_raw.len == 0) return gpa.dupe(u8, text);

    const left = try rewriteNullCoalescingOperator(gpa, left_raw);
    defer gpa.free(left);
    const right = try rewriteNullCoalescingOperator(gpa, right_raw);
    defer gpa.free(right);

    return std.fmt.allocPrint(
        gpa,
        "(({s}) != null ? ({s}) : ({s}))",
        .{ left, left, right },
    );
}

fn findTopLevelNullCoalescingOperator(text: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;

    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const ch = text[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
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
            '?' => {
                if (text[i + 1] == '?' and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}

fn rewriteApexTypeCasts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (ch != '(') continue;
        if (!isLikelyCastStart(text, i)) continue;

        const close = findMatchingParen(text, i) orelse continue;
        const raw_type = std.mem.trim(u8, text[(i + 1)..close], " \t");
        if (raw_type.len == 0 or !looksLikeTypeName(raw_type) or !isLikelyCastType(raw_type)) continue;
        if (!isLikelyCastFollowToken(text, close + 1)) continue;

        const converted_type = try convertApexType(gpa, raw_type);
        defer gpa.free(converted_type);

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "({s})", .{converted_type});
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return rewriteSObjectGetAsLengthFallback(gpa, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteSObjectGetAsLengthFallback(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        if (!startsWithIgnoreCase(text[i..], ".getAs")) continue;

        const method_boundary = i + ".getAs".len;
        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        var dot_pos = close + 1;
        while (dot_pos < text.len and std.ascii.isWhitespace(text[dot_pos])) : (dot_pos += 1) {}
        while (dot_pos < text.len and text[dot_pos] == ')') : (dot_pos += 1) {
            while (dot_pos < text.len and std.ascii.isWhitespace(text[dot_pos])) : (dot_pos += 1) {}
        }
        const accessor = blk: {
            if (startsWithIgnoreCase(text[dot_pos..], ".length")) break :blk ".length";
            if (startsWithIgnoreCase(text[dot_pos..], ".size")) break :blk ".size";
            break :blk "";
        };
        if (accessor.len == 0) continue;

        var len_open = dot_pos + accessor.len;
        while (len_open < text.len and std.ascii.isWhitespace(text[len_open])) : (len_open += 1) {}
        if (len_open >= text.len or text[len_open] != '(') continue;
        const len_close = findMatchingParen(text, len_open) orelse continue;
        const len_args = std.mem.trim(u8, text[(len_open + 1)..len_close], " \t");
        if (len_args.len != 0) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const get_as_call = std.mem.trim(u8, text[base_start .. close + 1], " \t");

        try out.appendSlice(gpa, text[last_emit..base_start]);
        if (std.ascii.eqlIgnoreCase(accessor, ".length")) {
            try appendFmt(gpa, &out, "ApexStrings.length({s})", .{get_as_call});
        } else {
            try appendFmt(gpa, &out, "ApexCollections.size({s})", .{get_as_call});
        }
        replaced = true;
        i = len_close;
        last_emit = len_close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn isLikelyCastStart(text: []const u8, open_paren: usize) bool {
    if (open_paren == 0) return true;
    var cursor = open_paren;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor == 0) return true;
    const prev = text[cursor - 1];
    if (isIdentifierChar(prev) or prev == ')' or prev == ']' or prev == '.') return false;
    return true;
}

fn isLikelyCastFollowToken(text: []const u8, start: usize) bool {
    var cursor = start;
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
    if (cursor >= text.len) return false;
    const next = text[cursor];
    if (next == ';' or next == ',' or next == ':' or next == '?' or next == ')' or next == ']' or next == '}') {
        return false;
    }
    return true;
}

fn isLikelyCastType(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return false;

    var generic_depth: i32 = 0;
    for (trimmed) |ch| {
        switch (ch) {
            '<' => generic_depth += 1,
            '>' => {
                generic_depth -= 1;
                if (generic_depth < 0) return false;
            },
            ' ', '\t', '\r', '\n' => if (generic_depth == 0) return false,
            ',', '.', '_', '?', '[', ']' => {},
            else => {
                if (!std.ascii.isAlphanumeric(ch)) return false;
            },
        }
    }

    return generic_depth == 0;
}

fn rewriteGenericClassLiterals(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (ch != '<') continue;

        const close_angle = findMatchingAngle(text, i) orelse continue;
        var after = close_angle + 1;
        while (after < text.len and std.ascii.isWhitespace(text[after])) : (after += 1) {}
        if (after + ".class".len > text.len) continue;
        if (!startsWithIgnoreCase(text[after..], ".class")) continue;
        const class_end = after + ".class".len;

        var base_start = i;
        while (base_start > 0 and (isIdentifierChar(text[base_start - 1]) or text[base_start - 1] == '.')) : (base_start -= 1) {}
        if (base_start == i) continue;
        const base = std.mem.trim(u8, text[base_start..i], " \t");
        if (base.len == 0) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "{s}.class", .{base});
        replaced = true;
        i = class_end - 1;
        last_emit = class_end;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteJsonDeserializeListCasts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (!startsWithIgnoreCase(text[i..], "JSON.deserialize")) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        const method_end = i + "JSON.deserialize".len;
        if (method_end < text.len and isIdentifierChar(text[method_end])) continue;

        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const args_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);
        if (args.items.len != 2) continue;

        const second_arg = std.mem.trim(u8, args.items[1], " \t");
        if (!startsWithIgnoreCase(second_arg, "List.class")) continue;
        if (second_arg.len != "List.class".len) continue;

        var cast_close = i;
        while (cast_close > 0 and std.ascii.isWhitespace(text[cast_close - 1])) : (cast_close -= 1) {}
        if (cast_close == 0 or text[cast_close - 1] != ')') continue;
        cast_close -= 1;
        const cast_open = findMatchingParenBackward(text, cast_close) orelse continue;
        const cast_raw = std.mem.trim(u8, text[(cast_open + 1)..cast_close], " \t");
        if (!startsWithIgnoreCase(cast_raw, "List<")) continue;
        if (!std.mem.endsWith(u8, cast_raw, ">")) continue;
        const elem_type = std.mem.trim(u8, cast_raw["List<".len .. cast_raw.len - 1], " \t");
        if (!looksLikeTypeName(elem_type)) continue;
        if (std.mem.indexOfScalar(u8, elem_type, '<') != null) continue;

        const first_arg = std.mem.trim(u8, args.items[0], " \t");
        const replacement = try std.fmt.allocPrint(
            gpa,
            "JSON.deserializeList({s}, {s}.class)",
            .{ first_arg, elem_type },
        );
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement);
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

fn rewriteSObjectGetAsMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        if (!startsWithIgnoreCase(text[i..], ".getAs")) continue;
        const method_boundary = i + ".getAs".len;
        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;

        var dot_pos = close + 1;
        while (dot_pos < text.len and std.ascii.isWhitespace(text[dot_pos])) : (dot_pos += 1) {}
        var wrapper_close_count: usize = 0;
        var wrapper_scan = dot_pos;
        var wrapper_expected_end = base_start;
        while (wrapper_scan < text.len and text[wrapper_scan] == ')') {
            const wrapper_open = findMatchingParenBackward(text, wrapper_scan) orelse break;
            // Only accept synthetic wrappers like ((obj.getAs("x"))).foo().
            // Skip if this ')' closes an outer call (e.g. bindMap(...)).
            const wrapper_gap = std.mem.trim(u8, text[(wrapper_open + 1)..wrapper_expected_end], " \t");
            if (wrapper_gap.len != 0) break;
            wrapper_close_count += 1;
            wrapper_expected_end = wrapper_open;
            wrapper_scan += 1;
            while (wrapper_scan < text.len and std.ascii.isWhitespace(text[wrapper_scan])) : (wrapper_scan += 1) {}
        }
        dot_pos = wrapper_scan;
        if (dot_pos >= text.len or text[dot_pos] != '.') continue;

        var called_method_pos = dot_pos + 1;
        while (called_method_pos < text.len and std.ascii.isWhitespace(text[called_method_pos])) : (called_method_pos += 1) {}
        if (called_method_pos >= text.len) continue;
        const called_method = leadingIdentifier(text[called_method_pos..]) orelse continue;
        const called_method_end = called_method_pos + called_method.len;

        var called_args_open = called_method_end;
        while (called_args_open < text.len and std.ascii.isWhitespace(text[called_args_open])) : (called_args_open += 1) {}
        if (called_args_open >= text.len or text[called_args_open] != '(') continue;
        const called_args_close = findMatchingParen(text, called_args_open) orelse continue;

        const get_as_call = std.mem.trim(u8, text[base_start .. close + 1], " \t");
        const called_args = std.mem.trim(u8, text[(called_args_open + 1)..called_args_close], " \t");

        var replacement: ?[]u8 = null;
        defer if (replacement) |value| gpa.free(value);
        if (std.ascii.eqlIgnoreCase(called_method, "length") and called_args.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.length({s})", .{get_as_call});
        } else if (std.ascii.eqlIgnoreCase(called_method, "compareTo")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.compareTo({s}, {s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "getAs")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexSwitch.getAs({s}, {s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "contains")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.contains({s}, {s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "containsIgnoreCase")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.containsIgnoreCase({s}, {s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "equalsIgnoreCase")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.equalsIgnoreCase({s}, {s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "formatGMT")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexSwitch.formatGMT({s}, {s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "toLowerCase") and called_args.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "String.valueOf({s}).toLowerCase()", .{get_as_call});
        } else if (std.ascii.eqlIgnoreCase(called_method, "toUpperCase") and called_args.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "String.valueOf({s}).toUpperCase()", .{get_as_call});
        } else if (std.ascii.eqlIgnoreCase(called_method, "trim") and called_args.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "String.valueOf({s}).trim()", .{get_as_call});
        } else if (std.ascii.eqlIgnoreCase(called_method, "split")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.split({s}, {s})", .{ get_as_call, called_args });
        } else {
            continue;
        }

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try out.appendSlice(gpa, replacement.?);
        var close_idx: usize = 0;
        while (close_idx < wrapper_close_count) : (close_idx += 1) {
            try out.append(gpa, ')');
        }
        replaced = true;
        i = called_args_close;
        last_emit = called_args_close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteStringInstanceMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        const method_name = blk: {
            if (startsWithIgnoreCase(text[i..], ".split")) break :blk "split";
            if (startsWithIgnoreCase(text[i..], ".substringAfter")) break :blk "substringAfter";
            if (startsWithIgnoreCase(text[i..], ".substringBefore")) break :blk "substringBefore";
            if (startsWithIgnoreCase(text[i..], ".leftPad")) break :blk "leftPad";
            if (startsWithIgnoreCase(text[i..], ".left")) break :blk "left";
            if (startsWithIgnoreCase(text[i..], ".rightPad")) break :blk "rightPad";
            if (startsWithIgnoreCase(text[i..], ".getStackTraceString")) break :blk "getStackTraceString";
            if (startsWithIgnoreCase(text[i..], ".getTypeName")) break :blk "getTypeName";
            if (startsWithIgnoreCase(text[i..], ".removeStart")) break :blk "removeStart";
            if (startsWithIgnoreCase(text[i..], ".removeStartIgnoreCase")) break :blk "removeStartIgnoreCase";
            if (startsWithIgnoreCase(text[i..], ".replaceFirst")) break :blk "replaceFirst";
            if (startsWithIgnoreCase(text[i..], ".replace")) break :blk "replace";
            if (startsWithIgnoreCase(text[i..], ".escapeEcmaScript")) break :blk "escapeEcmaScript";
            if (startsWithIgnoreCase(text[i..], ".endsWith")) break :blk "endsWith";
            if (startsWithIgnoreCase(text[i..], ".endsWithIgnoreCase")) break :blk "endsWithIgnoreCase";
            if (startsWithIgnoreCase(text[i..], ".removeEndIgnoreCase")) break :blk "removeEndIgnoreCase";
            if (startsWithIgnoreCase(text[i..], ".removeEnd")) break :blk "removeEnd";
            if (startsWithIgnoreCase(text[i..], ".right")) break :blk "right";
            if (startsWithIgnoreCase(text[i..], ".startsWith")) break :blk "startsWith";
            if (startsWithIgnoreCase(text[i..], ".containsIgnoreCase")) break :blk "containsIgnoreCase";
            if (startsWithIgnoreCase(text[i..], ".capitalize")) break :blk "capitalize";
            if (startsWithIgnoreCase(text[i..], ".deleteWhiteSpace")) break :blk "deleteWhiteSpace";
            if (startsWithIgnoreCase(text[i..], ".countMatches")) break :blk "countMatches";
            if (startsWithIgnoreCase(text[i..], ".isAlpha")) break :blk "isAlpha";
            if (startsWithIgnoreCase(text[i..], ".escapeHtml4")) break :blk "escapeHtml4";
            if (startsWithIgnoreCase(text[i..], ".format")) break :blk "format";
            if (startsWithIgnoreCase(text[i..], ".toString")) break :blk "toString";
            break :blk "";
        };
        if (method_name.len == 0) continue;
        const method_boundary = i + method_name.len + 1;
        if (method_boundary < text.len and isIdentifierChar(text[method_boundary])) continue;

        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        if (base_start < last_emit) continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (base_expr.len == 0) continue;
        if (isLikelyTypeReferencePathExpression(base_expr) and !isStaticValueAccessPathExpression(base_expr)) continue;

        const call_args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        var replacement: []u8 = undefined;
        if (std.ascii.eqlIgnoreCase(method_name, "split")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.split({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "substringAfter")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.substringAfter({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "left")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.left({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "leftPad")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.leftPad({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "rightPad")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.rightPad({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "removeEnd")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.removeEnd({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "removeStart")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.removeStart({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "removeStartIgnoreCase")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.removeStartIgnoreCase({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "replaceFirst")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.replaceFirst({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "replace")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.replace({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "escapeEcmaScript")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.escapeEcmaScript({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "endsWith")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.endsWith({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "endsWithIgnoreCase")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.endsWithIgnoreCase({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "removeEndIgnoreCase")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.removeEndIgnoreCase({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "right")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.right({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "startsWith")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.startsWith({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "containsIgnoreCase")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.containsIgnoreCase({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "capitalize")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.capitalize({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "deleteWhiteSpace")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.deleteWhiteSpace({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "countMatches")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.countMatches({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "isAlpha")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.isAlpha({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "escapeHtml4")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.escapeHtml4({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "format")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.formatNumber({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "getStackTraceString")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexSwitch.getStackTraceString({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "getTypeName")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexSwitch.getTypeName({s})", .{base_expr});
        } else if (std.ascii.eqlIgnoreCase(method_name, "toString")) {
            if (call_args.len != 0) continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.valueOf({s})", .{base_expr});
        } else {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.substringBefore({s}, {s})", .{ base_expr, call_args });
        }
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try out.appendSlice(gpa, replacement);
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewritePrintlnGetAsCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        const marker = "System.out.println";
        if (i + marker.len > text.len) continue;
        if (!std.mem.eql(u8, text[i .. i + marker.len], marker)) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        if (i + marker.len < text.len and isIdentifierChar(text[i + marker.len])) continue;

        var open = i + marker.len;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const arg_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (arg_raw.len == 0) continue;
        if (startsWithIgnoreCase(arg_raw, "String.valueOf(") or startsWithIgnoreCase(arg_raw, "ApexStrings.valueOf(")) continue;
        const has_get_as = indexOfIgnoreCase(arg_raw, ".getAs(") != null or
            indexOfIgnoreCase(arg_raw, "ApexSwitch.getAs(") != null;
        if (!has_get_as) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "System.out.println(ApexStrings.valueOf({s}))", .{arg_raw});
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn specificIdentifierReplacement(text: []const u8, token: []const u8, token_start: usize, token_end: usize) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(token, "acct")) return "acct";
    if (std.ascii.eqlIgnoreCase(token, "checkacct")) return "checkAcct";
    if (std.ascii.eqlIgnoreCase(token, "updatedacct")) return "updatedAcct";
    if (std.ascii.eqlIgnoreCase(token, "toinsert")) return "toInsert";
    if (std.ascii.eqlIgnoreCase(token, "permsetid")) return "permSetId";
    if (std.mem.eql(u8, token, "contacts")) return "contacts";
    if (std.mem.eql(u8, token, "testcontacts")) return "testContacts";
    if (std.ascii.eqlIgnoreCase(token, "filename")) return "fileName";
    if (std.ascii.eqlIgnoreCase(token, "genericfiletype")) return "GenericFileType";
    if (std.ascii.eqlIgnoreCase(token, "namefieldsearch")) return "nameFieldSearch";
    if (std.ascii.eqlIgnoreCase(token, "genxnumberofaccounts")) return "genXNumberOfAccounts";
    if (std.ascii.eqlIgnoreCase(token, "customdmlexception")) return "CustomDMLException";
    if (std.ascii.eqlIgnoreCase(token, "secondmethodtotrack")) return "secondMethodToTrack";
    if (std.ascii.eqlIgnoreCase(token, "integer")) return "Integer";
    if (std.ascii.eqlIgnoreCase(token, "datetime")) return "DateTime";
    if (std.ascii.eqlIgnoreCase(token, "viewstate")) return "ViewState";
    if (std.ascii.eqlIgnoreCase(token, "test")) return "Test";
    if (std.ascii.eqlIgnoreCase(token, "system")) return "System";
    if (std.ascii.eqlIgnoreCase(token, "apexpages")) return "ApexPages";
    if (std.ascii.eqlIgnoreCase(token, "pagereference")) return "PageReference";
    if (std.ascii.eqlIgnoreCase(token, "util_unittestdata_test")) return "UTIL_UnitTestData_TEST";
    if (std.ascii.eqlIgnoreCase(token, "createmultipletestcontacts")) return "CreateMultipleTestContacts";
    if (std.ascii.eqlIgnoreCase(token, "oppsforcontactlist")) return "OppsForContactList";
    if (std.ascii.eqlIgnoreCase(token, "oppsforcontactlistbyrectypeid")) return "OppsForContactListByRecTypeId";
    if (std.ascii.eqlIgnoreCase(token, "getclosedwonstage")) return "getClosedWonStage";
    if (std.ascii.eqlIgnoreCase(token, "getclosedwonstage4yearsago")) return "getClosedWonStage4YearsAgo";
    if (std.ascii.eqlIgnoreCase(token, "getopenstage")) return "getOpenStage";
    if (std.ascii.eqlIgnoreCase(token, "addyears")) return "addYears";
    if (std.ascii.eqlIgnoreCase(token, "test_sobjectgateway")) return "TEST_SObjectGateway";
    if (std.ascii.eqlIgnoreCase(token, "fflib_isobjectunitofwork")) return "fflib_ISObjectUnitOfWork";
    if (std.ascii.eqlIgnoreCase(token, "permissionsetgroup")) {
        const prev = prevNonSpace(text, token_start);
        if (prev != null and prev.? == '.') return null;
        const next = nextNonSpace(text, token_end);
        if (next >= text.len or text[next] != '.') return null;
        return "permissionSetGroup";
    }

    return null;
}

fn hasUpperAfterFirst(token: []const u8) bool {
    if (token.len <= 1) return false;
    for (token[1..]) |ch| {
        if (std.ascii.isUpper(ch)) return true;
    }
    return false;
}

fn isPrecededByKeywordIgnoreCase(text: []const u8, token_start: usize, keyword: []const u8) bool {
    var cursor = token_start;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor < keyword.len) return false;

    const keyword_start = cursor - keyword.len;
    if (!std.ascii.eqlIgnoreCase(text[keyword_start..cursor], keyword)) return false;
    if (keyword_start > 0 and isIdentifierChar(text[keyword_start - 1])) return false;
    return true;
}

fn rewriteSpecificIdentifierCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var in_line_comment = false;
    var in_block_comment = false;

    while (i < text.len) {
        const ch = text[i];

        if (in_line_comment) {
            try out.append(gpa, ch);
            i += 1;
            if (ch == '\n') in_line_comment = false;
            continue;
        }

        if (in_block_comment) {
            try out.append(gpa, ch);
            if (ch == '*' and i + 1 < text.len and text[i + 1] == '/') {
                try out.append(gpa, '/');
                i += 2;
                in_block_comment = false;
                continue;
            }
            i += 1;
            continue;
        }

        if (in_single) {
            try out.append(gpa, ch);
            i += 1;
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i < text.len and text[i] == '\'') {
                try out.append(gpa, '\'');
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }

        if (in_double) {
            try out.append(gpa, ch);
            i += 1;
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

        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            try out.appendSlice(gpa, "//");
            i += 2;
            in_line_comment = true;
            continue;
        }
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            try out.appendSlice(gpa, "/*");
            i += 2;
            in_block_comment = true;
            continue;
        }
        if (ch == '\'') {
            try out.append(gpa, ch);
            i += 1;
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            try out.append(gpa, ch);
            i += 1;
            in_double = true;
            escaped = false;
            continue;
        }

        if (!isIdentifierChar(ch)) {
            try out.append(gpa, ch);
            i += 1;
            continue;
        }

        const start = i;
        i += 1;
        while (i < text.len and isIdentifierChar(text[i])) : (i += 1) {}
        const token = text[start..i];
        const replacement = specificIdentifierReplacement(text, token, start, i);
        if (replacement) |canonical| {
            if (!std.mem.eql(u8, token, canonical)) {
                try out.appendSlice(gpa, canonical);
                replaced = true;
                continue;
            }
        }

        try out.appendSlice(gpa, token);
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteTestDoubleClassCtorCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    const marker = "new TestDouble";

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (i + marker.len > text.len) continue;
        if (!startsWithIgnoreCase(text[i..], marker)) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        if (i + marker.len < text.len and isIdentifierChar(text[i + marker.len])) continue;

        var open = i + marker.len;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const arg = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (arg.len <= ".class".len) continue;
        if (!endsWithIgnoreCase(arg, ".class")) continue;
        const type_name = std.mem.trim(u8, arg[0 .. arg.len - ".class".len], " \t");
        if (type_name.len == 0 or !isSimpleIdentifierOrPath(type_name)) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(
            gpa,
            &out,
            "new TestDouble(apexemu.runtime.System.Type.forName(\"{s}\"))",
            .{type_name},
        );
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn isSelfQualifiedTypeReference(type_name: []const u8, owner_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_name, " \t");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, owner_name)) return true;
    if (trimmed.len <= owner_name.len) return false;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..owner_name.len], owner_name)) return false;
    return trimmed[owner_name.len] == '.';
}

fn rewriteSystemTypeListOfClassLiterals(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    const markers = [_][]const u8{ "java.util.List.of", "ApexCollections.listOf" };

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        var matched_marker_len: usize = 0;
        for (markers) |marker| {
            if (i + marker.len <= text.len and
                startsWithIgnoreCase(text[i..], marker) and
                !(i > 0 and isIdentifierChar(text[i - 1])) and
                !(i + marker.len < text.len and isIdentifierChar(text[i + marker.len])))
            {
                matched_marker_len = marker.len;
                break;
            }
        }
        if (matched_marker_len == 0) continue;

        var open = i + matched_marker_len;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const prefix_start = if (i > 96) i - 96 else 0;
        const prefix = text[prefix_start..i];
        if (indexOfIgnoreCase(prefix, "ArrayList<apexemu.runtime.System.Type>") == null) continue;

        const raw_args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (raw_args.len == 0) continue;
        var args = try splitCallArguments(gpa, raw_args);
        defer args.deinit(gpa);
        if (args.items.len == 0) continue;

        var converted_args: std.ArrayList([]u8) = .empty;
        defer {
            for (converted_args.items) |value| gpa.free(value);
            converted_args.deinit(gpa);
        }

        var all_class_literals = true;
        for (args.items) |arg_raw| {
            const arg = std.mem.trim(u8, arg_raw, " \t");
            if (arg.len <= ".class".len or !endsWithIgnoreCase(arg, ".class")) {
                all_class_literals = false;
                break;
            }
            const type_name = std.mem.trim(u8, arg[0 .. arg.len - ".class".len], " \t");
            if (type_name.len == 0 or !isSimpleIdentifierOrPath(type_name)) {
                all_class_literals = false;
                break;
            }
            try converted_args.append(gpa, try std.fmt.allocPrint(
                gpa,
                "apexemu.runtime.System.Type.forName(\"{s}\")",
                .{type_name},
            ));
        }
        if (!all_class_literals) continue;

        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        for (converted_args.items, 0..) |value, idx| {
            if (idx != 0) try joined.appendSlice(gpa, ", ");
            try joined.appendSlice(gpa, value);
        }

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "ApexCollections.listOf({s})", .{joined.items});
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteSystemTypeMethodClassLiteralArgs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '(') continue;

        const prev_opt = prevNonSpace(text, i);
        if (prev_opt == null) continue;
        const prev = prev_opt.?;
        if (!isIdentifierChar(prev) and prev != ')' and prev != ']') continue;

        var name_end = i;
        while (name_end > 0 and std.ascii.isWhitespace(text[name_end - 1])) : (name_end -= 1) {}
        if (name_end == 0) continue;

        var name_start = name_end;
        while (name_start > 0 and isIdentifierChar(text[name_start - 1])) : (name_start -= 1) {}
        if (name_start < name_end) {
            const callee = text[name_start..name_end];
            if (std.ascii.eqlIgnoreCase(callee, "if") or
                std.ascii.eqlIgnoreCase(callee, "for") or
                std.ascii.eqlIgnoreCase(callee, "while") or
                std.ascii.eqlIgnoreCase(callee, "switch") or
                std.ascii.eqlIgnoreCase(callee, "catch"))
            {
                continue;
            }
        }

        const open = i;
        const close = findMatchingParen(text, open) orelse continue;

        const raw_args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (raw_args.len == 0) continue;
        var args = try splitCallArguments(gpa, raw_args);
        defer args.deinit(gpa);
        if (args.items.len == 0) continue;

        var converted_args: std.ArrayList([]u8) = .empty;
        defer {
            for (converted_args.items) |value| gpa.free(value);
            converted_args.deinit(gpa);
        }

        var changed = false;
        for (args.items) |arg_raw| {
            const arg = std.mem.trim(u8, arg_raw, " \t");
            if (arg.len > ".class".len and endsWithIgnoreCase(arg, ".class")) {
                const type_name = std.mem.trim(u8, arg[0 .. arg.len - ".class".len], " \t");
                if (type_name.len > 0 and isSimpleIdentifierOrPath(type_name)) {
                    try converted_args.append(gpa, try std.fmt.allocPrint(
                        gpa,
                        "apexemu.runtime.System.Type.forName(\"{s}\")",
                        .{type_name},
                    ));
                    changed = true;
                    continue;
                }
            }
            try converted_args.append(gpa, try gpa.dupe(u8, arg));
        }
        if (!changed) continue;

        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        for (converted_args.items, 0..) |value, idx| {
            if (idx != 0) try joined.appendSlice(gpa, ", ");
            try joined.appendSlice(gpa, value);
        }

        try out.appendSlice(gpa, text[last_emit .. open + 1]);
        try out.appendSlice(gpa, joined.items);
        try out.append(gpa, ')');
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteNoArgCloneCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        if (!startsWithIgnoreCase(text[i..], ".clone")) continue;
        const method_boundary = i + ".clone".len;
        if (method_boundary < text.len and isIdentifierChar(text[method_boundary])) continue;

        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        const args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (args.len != 0) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (base_expr.len == 0) continue;
        if (isLikelyTypeReferencePathExpression(base_expr)) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "ApexCollections.clone({s})", .{base_expr});
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteStringKeyedSetMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        if (!startsWithIgnoreCase(text[i..], ".set")) continue;
        const method_boundary = i + ".set".len;
        if (method_boundary < text.len and isIdentifierChar(text[method_boundary])) continue;

        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        if (base_start < last_emit) continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (base_expr.len == 0) continue;
        if (isLikelyTypeReferencePathExpression(base_expr)) continue;
        if (!isIdentifierPathExpression(base_expr)) continue;

        const call_args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        var args = try splitCallArguments(gpa, call_args);
        defer args.deinit(gpa);
        if (args.items.len != 2) continue;
        const key_arg = std.mem.trim(u8, args.items[0], " \t");
        if (key_arg.len < 2 or key_arg[0] != '"' or key_arg[key_arg.len - 1] != '"') continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "ApexSwitch.set({s}, {s})", .{ base_expr, call_args });
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteNoArgSortCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        if (!startsWithIgnoreCase(text[i..], ".sort")) continue;
        const method_boundary = i + ".sort".len;
        if (method_boundary < text.len and isIdentifierChar(text[method_boundary])) continue;

        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        const args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (args.len != 0) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (base_expr.len == 0) continue;
        if (isLikelyTypeReferencePathExpression(base_expr)) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "ApexCollections.sort({s})", .{base_expr});
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteIdGetSObjectTypeCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        const method_name = blk: {
            if (startsWithIgnoreCase(text[i..], ".getSObjectType")) break :blk ".getSObjectType";
            if (startsWithIgnoreCase(text[i..], ".getSobjectType")) break :blk ".getSobjectType";
            break :blk "";
        };
        if (method_name.len == 0) continue;

        const method_boundary = i + method_name.len;
        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        const args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (args.len != 0) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (base_expr.len == 0) continue;
        const base_is_type_ref = isLikelyTypeReferencePathExpression(base_expr);

        try out.appendSlice(gpa, text[last_emit..base_start]);
        if (base_is_type_ref) {
            const type_name = typeReferenceObjectName(base_expr);
            if (type_name.len == 0 or
                !isLikelySObjectTypeForInstanceof(type_name) or
                std.ascii.eqlIgnoreCase(type_name, "SObjectType"))
            {
                try out.appendSlice(gpa, text[base_start .. close + 1]);
                replaced = true;
                i = close;
                last_emit = close + 1;
                continue;
            }
            try appendFmt(
                gpa,
                &out,
                "new Schema.SObjectType(\"{s}\")",
                .{type_name},
            );
        } else {
            try appendFmt(
                gpa,
                &out,
                "ApexSwitch.getSObjectType({s})",
                .{base_expr},
            );
        }
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteTypeSObjectTypeConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        const suffix = blk: {
            if (startsWithIgnoreCase(text[i..], ".SObjectType")) break :blk ".SObjectType";
            if (startsWithIgnoreCase(text[i..], ".sObjectType")) break :blk ".sObjectType";
            break :blk "";
        };
        if (suffix.len == 0) continue;

        const suffix_end = i + suffix.len;
        if (suffix_end < text.len and isIdentifierChar(text[suffix_end])) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (!isLikelyTypeReferencePathExpression(base_expr)) continue;

        const type_name = typeReferenceObjectName(base_expr);
        if (type_name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(type_name, "Schema")) continue;
        if (std.ascii.eqlIgnoreCase(type_name, "SObjectType")) continue;
        if (!isLikelySObjectTypeForInstanceof(type_name)) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(
            gpa,
            &out,
            "new Schema.SObjectType(\"{s}\")",
            .{type_name},
        );
        replaced = true;
        i = suffix_end - 1;
        last_emit = suffix_end;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteTypeSObjectFieldConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        if (i + 1 >= text.len or !isIdentifierChar(text[i + 1])) continue;

        var member_end = i + 1;
        while (member_end < text.len and isIdentifierChar(text[member_end])) : (member_end += 1) {}
        const member = text[(i + 1)..member_end];
        if (!isLikelySObjectFieldName(member)) continue;
        if (std.ascii.eqlIgnoreCase(member, "FieldSets") or
            std.ascii.eqlIgnoreCase(member, "SObjectType") or
            std.ascii.eqlIgnoreCase(member, "fields"))
        {
            continue;
        }

        const next_non_space = nextNonSpace(text, member_end);
        if (next_non_space < text.len and text[next_non_space] == '(') continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (!isLikelyTypeReferencePathExpression(base_expr)) continue;

        const type_name = typeReferenceObjectName(base_expr);
        if (type_name.len == 0 or !isLikelySObjectTypeForInstanceof(type_name)) continue;
        if (std.ascii.eqlIgnoreCase(type_name, "Schema")) continue;
        if (std.ascii.eqlIgnoreCase(type_name, "SObjectType")) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(
            gpa,
            &out,
            "new Schema.SObjectField(\"{s}\", \"{s}\")",
            .{ type_name, member },
        );
        replaced = true;
        i = member_end - 1;
        last_emit = member_end;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteSObjectTypeFieldSetConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        if (ch != '.') continue;
        if (i + 1 >= text.len or !isIdentifierChar(text[i + 1])) continue;
        var fieldset_end = i + 1;
        while (fieldset_end < text.len and isIdentifierChar(text[fieldset_end])) : (fieldset_end += 1) {}
        const fieldset_name = text[(i + 1)..fieldset_end];
        if (std.ascii.eqlIgnoreCase(fieldset_name, "FieldSets")) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (!endsWithIgnoreCase(base_expr, ".FieldSets")) continue;

        const type_expr = std.mem.trim(u8, base_expr[0 .. base_expr.len - ".FieldSets".len], " \t");
        if (!isLikelyTypeReferencePathExpression(type_expr)) continue;
        const type_name = typeReferenceObjectName(type_expr);
        if (type_name.len == 0 or !isLikelySObjectTypeForInstanceof(type_name)) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(
            gpa,
            &out,
            "new Schema.FieldSetNamespace(\"{s}\").get(\"{s}\")",
            .{ type_name, fieldset_name },
        );
        replaced = true;
        i = fieldset_end - 1;
        last_emit = fieldset_end;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn typeReferenceObjectName(path: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, path, " \t");
    if (trimmed.len == 0) return "";

    if (startsWithIgnoreCase(trimmed, "Schema.")) {
        const after_schema = std.mem.trimLeft(u8, trimmed["Schema.".len..], " \t");
        if (leadingIdentifier(after_schema)) |name| return name;
    }

    return lastIdentifier(trimmed) orelse "";
}

fn rewriteTriggerOperationEnumConstantCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'') {
            in_single = true;
            escaped = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }

        const marker = "TriggerOperation.";
        if (i + marker.len > text.len) continue;
        if (!startsWithIgnoreCase(text[i..], marker)) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;

        const enum_start = i + marker.len;
        if (enum_start >= text.len or !isIdentifierChar(text[enum_start])) continue;
        var enum_end = enum_start + 1;
        while (enum_end < text.len and isIdentifierChar(text[enum_end])) : (enum_end += 1) {}

        const raw_constant = text[enum_start..enum_end];
        const canonical = canonicalTriggerOperationConstant(raw_constant) orelse continue;

        const is_qualified = i > 0 and text[i - 1] == '.';
        if (is_qualified) {
            try out.appendSlice(gpa, text[last_emit..enum_start]);
        } else {
            try out.appendSlice(gpa, text[last_emit..i]);
            try out.appendSlice(gpa, "System.TriggerOperation.");
        }
        try out.appendSlice(gpa, canonical);
        replaced = true;
        i = enum_end - 1;
        last_emit = enum_end;
        in_single = false;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn canonicalTriggerOperationConstant(value: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "BEFORE_INSERT")) return "BEFORE_INSERT";
    if (std.ascii.eqlIgnoreCase(value, "BEFORE_UPDATE")) return "BEFORE_UPDATE";
    if (std.ascii.eqlIgnoreCase(value, "BEFORE_DELETE")) return "BEFORE_DELETE";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_INSERT")) return "AFTER_INSERT";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_UPDATE")) return "AFTER_UPDATE";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_DELETE")) return "AFTER_DELETE";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_UNDELETE")) return "AFTER_UNDELETE";
    return null;
}

fn isLikelyTypeReferencePathExpression(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfAny(u8, trimmed, "()[]{}")) |_| return false;
    if (!isSimpleIdentifierOrPath(trimmed)) return false;

    var parts = std.mem.tokenizeScalar(u8, trimmed, '.');
    const first = parts.next() orelse return false;
    if (!isLikelyTypeReferenceIdentifier(first)) return false;
    return true;
}

fn isStaticValueAccessPathExpression(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (!isSimpleIdentifierOrPath(trimmed)) return false;

    var parts = std.mem.tokenizeScalar(u8, trimmed, '.');
    _ = parts.next() orelse return false;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!isLikelyTypeReferenceIdentifier(part)) return true;
    }
    return false;
}

fn findMemberAccessBaseStart(text: []const u8, dot_pos: usize) ?usize {
    if (dot_pos == 0 or dot_pos >= text.len or text[dot_pos] != '.') return null;
    var cursor = dot_pos;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor == 0) return null;

    if (isIdentifierChar(text[cursor - 1])) {
        var start = cursor - 1;
        while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
        return extendIndexBaseLeft(text, start);
    }

    if (text[cursor - 1] == ')') {
        const open = findMatchingParenBackward(text, cursor - 1) orelse return null;
        var method_start = open;
        if (open > 0 and isIdentifierChar(text[open - 1])) {
            method_start = open - 1;
            while (method_start > 0 and isIdentifierChar(text[method_start - 1])) : (method_start -= 1) {}
        }
        return extendIndexBaseLeft(text, method_start);
    }

    return null;
}

fn rewriteQueryGetAsAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        const query_method_len: usize = if (startsWithIgnoreCase(text[i..], "Database.queryWithBinds"))
            "Database.queryWithBinds".len
        else if (startsWithIgnoreCase(text[i..], "Database.query"))
            "Database.query".len
        else
            0;
        if (query_method_len == 0) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        if (i + query_method_len < text.len and isIdentifierChar(text[i + query_method_len])) continue;

        var open = i + query_method_len;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;

        const close = findMatchingParen(text, open) orelse continue;
        var dot_pos = close + 1;
        while (dot_pos < text.len and std.ascii.isWhitespace(text[dot_pos])) : (dot_pos += 1) {}
        if (dot_pos >= text.len or text[dot_pos] != '.') continue;

        var method_pos = dot_pos + 1;
        while (method_pos < text.len and std.ascii.isWhitespace(text[method_pos])) : (method_pos += 1) {}
        if (method_pos >= text.len or !startsWithIgnoreCase(text[method_pos..], "getAs")) continue;
        const boundary = method_pos + "getAs".len;
        if (boundary < text.len and isIdentifierChar(text[boundary])) continue;

        const args_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);

        const query_call = blk: {
            if (args.items.len == 1) {
                const first_arg = std.mem.trim(u8, args.items[0], " \t");
                if (parseDatabaseQuerySource(gpa, first_arg)) |source| {
                    defer {
                        gpa.free(source.query_arg);
                        if (source.binds_arg) |binds| gpa.free(binds);
                    }
                    if (source.binds_arg) |binds| {
                        break :blk try std.fmt.allocPrint(
                            gpa,
                            "Database.queryWithBinds({s}, {s})",
                            .{ source.query_arg, binds },
                        );
                    }
                    break :blk try std.fmt.allocPrint(gpa, "Database.query({s})", .{source.query_arg});
                }
            }
            break :blk try gpa.dupe(u8, text[i .. close + 1]);
        };
        defer gpa.free(query_call);

        const wrapped = try std.fmt.allocPrint(
            gpa,
            "ApexCollections.firstOrThrow({s})",
            .{query_call},
        );
        defer gpa.free(wrapped);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, wrapped);
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

fn rewriteFirstOrNullGetAs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const prefix = "ApexCollections.firstOrNull(";
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
        if (!startsWithIgnoreCase(text[i..], prefix)) continue;

        const open = i + prefix.len - 1;
        const close = findMatchingParen(text, open) orelse continue;

        var dot_pos = close + 1;
        while (dot_pos < text.len and std.ascii.isWhitespace(text[dot_pos])) : (dot_pos += 1) {}
        if (dot_pos >= text.len or text[dot_pos] != '.') continue;

        var method_pos = dot_pos + 1;
        while (method_pos < text.len and std.ascii.isWhitespace(text[method_pos])) : (method_pos += 1) {}
        if (!startsWithIgnoreCase(text[method_pos..], "getAs")) continue;
        const get_as_end = method_pos + "getAs".len;
        if (get_as_end < text.len and isIdentifierChar(text[get_as_end])) continue;

        var gas_open = get_as_end;
        while (gas_open < text.len and std.ascii.isWhitespace(text[gas_open])) : (gas_open += 1) {}
        if (gas_open >= text.len or text[gas_open] != '(') continue;

        const gas_close = findMatchingParen(text, gas_open) orelse continue;
        const field_arg = std.mem.trim(u8, text[(gas_open + 1)..gas_close], " \t");

        const inner_arg = std.mem.trim(u8, text[(open + 1)..close], " \t");

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "ApexCollections.emptyIfNull(ApexCollections.firstOrNull({s})).getAs({s})", .{ inner_arg, field_arg });
        replaced = true;
        i = gas_close;
        last_emit = gas_close + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn rewriteDatabaseQueryCallsWithBinds(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (!startsWithIgnoreCase(text[i..], "Database.query")) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        const method_boundary = i + "Database.query".len;
        if (method_boundary < text.len and isIdentifierChar(text[method_boundary])) continue;

        var open = method_boundary;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const args_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);
        if (args.items.len != 1) continue;

        const first_arg = std.mem.trim(u8, args.items[0], " \t");
        if (!isJavaStringLiteral(first_arg)) continue;

        var bind_names = try collectSoqlBindNamesFromJavaLiteral(gpa, first_arg);
        defer bind_names.deinit(gpa);
        if (bind_names.items.len == 0) continue;

        var bind_map_args: std.ArrayList(u8) = .empty;
        defer bind_map_args.deinit(gpa);
        for (bind_names.items, 0..) |bind_name, idx| {
            const bind_expr = try convertBindReferenceToJava(gpa, bind_name);
            defer gpa.free(bind_expr);
            if (idx != 0) try bind_map_args.appendSlice(gpa, ", ");
            try appendFmt(gpa, &bind_map_args, "\"{s}\", {s}", .{ bind_name, bind_expr });
        }

        const replacement = try std.fmt.allocPrint(
            gpa,
            "Database.queryWithBinds({s}, ApexCollections.bindMap({s}))",
            .{ first_arg, bind_map_args.items },
        );
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement);
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

fn collectSoqlBindNamesFromJavaLiteral(
    gpa: std.mem.Allocator,
    java_literal: []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    if (!isJavaStringLiteral(java_literal)) return out;
    const body = java_literal[1 .. java_literal.len - 1];
    var in_single = false;
    var escaped = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '\'') {
            if (in_single and i + 1 < body.len and body[i + 1] == '\'') {
                i += 1;
                continue;
            }
            in_single = !in_single;
            continue;
        }
        if (in_single or ch != ':') continue;

        const start = i + 1;
        var end = start;
        while (end < body.len and isSoqlBindNameChar(body[end])) : (end += 1) {}
        if (end == start) continue;

        const bind_name = body[start..end];
        if (!isSimpleBindReference(bind_name)) continue;

        var seen = false;
        for (out.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, bind_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try out.append(gpa, bind_name);
        }
        i = end - 1;
    }
    return out;
}

fn isJavaStringLiteral(text: []const u8) bool {
    return text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"';
}

fn rewriteIntegerValueOfNumericCasts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (!startsWithIgnoreCase(text[i..], "Integer.valueOf")) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;

        var open = i + "Integer.valueOf".len;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const arg_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (arg_raw.len == 0 or !shouldForceIntegerValueOfCast(arg_raw)) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        if (containsGetAsCall(arg_raw)) {
            try appendFmt(gpa, &out, "ApexStrings.toInteger({s})", .{arg_raw});
        } else {
            try appendFmt(gpa, &out, "Integer.valueOf((int) ({s}))", .{arg_raw});
        }
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

fn shouldForceIntegerValueOfCast(arg: []const u8) bool {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '"') return false;
    if (startsWithIgnoreCase(trimmed, "(int)")) return false;
    if (startsWithIgnoreCase(trimmed, "String.") or startsWithIgnoreCase(trimmed, "ApexStrings.")) return false;
    if (std.mem.indexOfAny(u8, trimmed, "*/%") != null) return true;
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| return true;
    if (std.mem.indexOfScalar(u8, trimmed, '(')) |_| return true;
    if (std.mem.indexOfScalar(u8, trimmed, '+')) |_| return true;
    if (std.mem.indexOfScalar(u8, trimmed, '-')) |_| return true;
    return false;
}

fn containsGetAsCall(arg: []const u8) bool {
    var i: usize = 0;
    while (i + 6 <= arg.len) : (i += 1) {
        if (startsWithIgnoreCase(arg[i..], ".getAs(") or
            startsWithIgnoreCase(arg[i..], "ApexSwitch.getAs("))
            return true;
    }
    return false;
}

fn rewriteNumericValueOfObjectIdentifiers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var object_names: std.ArrayList([]u8) = .empty;
    defer {
        for (object_names.items) |name| gpa.free(name);
        object_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractTypedVariableName(line, "Object")) |name| {
            try object_names.append(gpa, try gpa.dupe(u8, name));
        }
    }
    if (object_names.items.len == 0) return gpa.dupe(u8, text);

    const RewriteSpec = struct {
        marker: []const u8,
        replacement: []const u8,
    };
    const specs = [_]RewriteSpec{
        .{ .marker = "Integer.valueOf", .replacement = "ApexStrings.toInteger" },
        .{ .marker = "Long.valueOf", .replacement = "ApexStrings.toLong" },
        .{ .marker = "Double.valueOf", .replacement = "ApexStrings.toDouble" },
    };

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
            escaped = false;
            continue;
        }

        for (specs) |spec| {
            if (!startsWithIgnoreCase(text[i..], spec.marker)) continue;
            if (i > 0 and isIdentifierChar(text[i - 1])) continue;

            var open = i + spec.marker.len;
            while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
            if (open >= text.len or text[open] != '(') continue;
            const close = findMatchingParen(text, open) orelse continue;

            const arg_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
            if (!isSimpleIdentifier(arg_raw) or !containsKnownObjectIdentifier(object_names.items, arg_raw)) continue;

            try out.appendSlice(gpa, text[last_emit..i]);
            try appendFmt(gpa, &out, "{s}({s})", .{ spec.replacement, arg_raw });
            replaced = true;
            last_emit = close + 1;
            i = close;
            break;
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn convertBracketIndexAccessPass(gpa: std.mem.Allocator, text: []const u8) anyerror!?[]u8 {
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

        const base_start = findIndexAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (base_expr.len == 0) continue;
        if (base_start < last_emit) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "{s}.get({s})", .{ base_expr, index_expr });
        replaced = true;
        i = close;
        last_emit = close + 1;
        in_double = false;
        escaped = false;
    }

    if (!replaced) return null;
    try out.appendSlice(gpa, text[last_emit..]);
    return @as(?[]u8, try out.toOwnedSlice(gpa));
}

fn convertBracketIndexAccess(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var current = try gpa.dupe(u8, text);
    var pass_count: usize = 0;
    while (pass_count < 32) : (pass_count += 1) {
        const next = try convertBracketIndexAccessPass(gpa, current) orelse return current;
        gpa.free(current);
        current = next;
    }
    return current;
}

fn findIndexAccessBaseStart(text: []const u8, bracket_pos: usize) ?usize {
    if (bracket_pos == 0) return null;
    var cursor = bracket_pos;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor == 0) return null;

    if (isIdentifierChar(text[cursor - 1])) {
        var start = cursor - 1;
        while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
        return extendIndexBaseLeft(text, start);
    }

    if (text[cursor - 1] == ')') {
        const open = findMatchingParenBackward(text, cursor - 1) orelse return null;
        var method_start = open;
        if (open > 0 and isIdentifierChar(text[open - 1])) {
            method_start = open - 1;
            while (method_start > 0 and isIdentifierChar(text[method_start - 1])) : (method_start -= 1) {}
        }
        return extendIndexBaseLeft(text, method_start);
    }

    return null;
}

fn extendOverConstructorNewKeyword(text: []const u8, initial_start: usize) usize {
    if (initial_start == 0) return initial_start;
    var cursor = initial_start;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor < "new".len) return initial_start;

    const keyword_start = cursor - "new".len;
    if (!startsWithIgnoreCase(text[keyword_start..], "new")) return initial_start;
    if (keyword_start > 0 and isIdentifierChar(text[keyword_start - 1])) return initial_start;
    return keyword_start;
}

fn extendQualifiedIdentifierPathLeft(text: []const u8, initial_start: usize) usize {
    var start = initial_start;
    while (start > 0) {
        var cursor = start;
        while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
        if (cursor == 0 or text[cursor - 1] != '.') break;
        cursor -= 1;
        while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
        if (cursor == 0 or !isIdentifierChar(text[cursor - 1])) break;
        var segment_start = cursor - 1;
        while (segment_start > 0 and isIdentifierChar(text[segment_start - 1])) : (segment_start -= 1) {}
        start = segment_start;
    }
    return start;
}

fn extendIndexBaseLeft(text: []const u8, initial_start: usize) usize {
    var start = initial_start;
    while (start > 0) {
        var cursor = start;
        while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
        if (cursor == 0 or text[cursor - 1] != '.') break;
        cursor -= 1;
        while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
        if (cursor == 0) break;

        if (isIdentifierChar(text[cursor - 1])) {
            var segment_start = cursor - 1;
            while (segment_start > 0 and isIdentifierChar(text[segment_start - 1])) : (segment_start -= 1) {}
            start = segment_start;
            continue;
        }

        if (text[cursor - 1] == ')') {
            const open = findMatchingParenBackward(text, cursor - 1) orelse break;
            var method_start = open;
            if (open > 0 and isIdentifierChar(text[open - 1])) {
                method_start = open - 1;
                while (method_start > 0 and isIdentifierChar(text[method_start - 1])) : (method_start -= 1) {}
            } else if (open > 0 and text[open - 1] == '>') {
                const generic_open = findMatchingAngleBackward(text, open - 1) orelse break;
                if (generic_open == 0 or !isIdentifierChar(text[generic_open - 1])) break;
                method_start = generic_open - 1;
                while (method_start > 0 and isIdentifierChar(text[method_start - 1])) : (method_start -= 1) {}
                method_start = extendQualifiedIdentifierPathLeft(text, method_start);
            }
            start = extendOverConstructorNewKeyword(text, method_start);
            continue;
        }
        break;
    }
    return extendOverConstructorNewKeyword(text, start);
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
    var in_single = false;
    var single_escaped = false;
    var in_double = false;
    var escaped = false;

    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        if (ch == '\'' and !in_double) {
            in_single = true;
            single_escaped = false;
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
                    try mapped.append(gpa, try std.fmt.allocPrint(gpa, "ApexCollections.mapEntry({s}, {s})", .{ key, value }));
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
                    "new {s}<{s}>(ApexCollections.mapOfEntries({s}))",
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
                    "new {s}<{s}>(ApexCollections.listOf({s}))",
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
        in_single = false;
        single_escaped = false;
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

/// Rewrites `a == b` to `ApexEquals.eq(a, b)` and `a != b` to `ApexEquals.ne(a, b)`
/// when operands involve declared `Object` identifiers or method-call results.
fn rewriteObjectEqualityWithDeclaredObjects(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var object_names: std.ArrayList([]u8) = .empty;
    defer {
        for (object_names.items) |name| gpa.free(name);
        object_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractTypedVariableName(line, "Object")) |name| {
            try object_names.append(gpa, try gpa.dupe(u8, name));
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var render_lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (render_lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const rendered = try rewriteObjectEqualityLine(gpa, line, object_names.items);
        defer gpa.free(rendered);
        if (!std.mem.eql(u8, rendered, line)) changed = true;
        try out.appendSlice(gpa, rendered);
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

fn rewriteObjectEqualityLine(gpa: std.mem.Allocator, line: []const u8, object_names: []const []u8) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return gpa.dupe(u8, line);

    if (startsWithWordIgnoreCase(trimmed, "if") or startsWithWordIgnoreCase(trimmed, "while")) {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return gpa.dupe(u8, line);
        const close = findMatchingParen(trimmed, open) orelse return gpa.dupe(u8, line);
        if (close <= open + 1) return gpa.dupe(u8, line);

        const condition = trimmed[open + 1 .. close];
        const rewritten = try rewriteEqualityOperators(gpa, condition, object_names);
        defer gpa.free(rewritten);
        if (std.mem.eql(u8, rewritten, condition)) return gpa.dupe(u8, line);

        const leading = line[0 .. @intFromPtr(trimmed.ptr) - @intFromPtr(line.ptr)];
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, leading);
        try out.appendSlice(gpa, trimmed[0 .. open + 1]);
        try out.appendSlice(gpa, rewritten);
        try out.append(gpa, ')');
        if (close + 1 < trimmed.len) try out.appendSlice(gpa, trimmed[close + 1 ..]);
        return out.toOwnedSlice(gpa);
    }

    if (startsWithIgnoreCase(trimmed, "return ") and std.mem.endsWith(u8, trimmed, ";")) {
        const expr = std.mem.trim(u8, trimmed["return ".len .. trimmed.len - 1], " \t");
        if (expr.len == 0) return gpa.dupe(u8, line);
        const rewritten = try rewriteEqualityOperators(gpa, expr, object_names);
        defer gpa.free(rewritten);
        if (std.mem.eql(u8, rewritten, expr)) {
            if (try rewriteSimpleObjectEqualityExpression(gpa, expr, object_names)) |fallback| {
                defer gpa.free(fallback);
                const leading = line[0 .. @intFromPtr(trimmed.ptr) - @intFromPtr(line.ptr)];
                return std.fmt.allocPrint(gpa, "{s}return {s};", .{ leading, fallback });
            }
            return gpa.dupe(u8, line);
        }

        const leading = line[0 .. @intFromPtr(trimmed.ptr) - @intFromPtr(line.ptr)];
        return std.fmt.allocPrint(gpa, "{s}return {s};", .{ leading, rewritten });
    }

    return gpa.dupe(u8, line);
}

fn rewriteEqualityOperators(gpa: std.mem.Allocator, condition: []const u8, object_names: []const []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var escaped = false;
    var paren_depth: i32 = 0;

    while (i < condition.len) : (i += 1) {
        const ch = condition[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == '(') {
            paren_depth += 1;
            continue;
        }
        if (ch == ')') {
            paren_depth -= 1;
            continue;
        }

        // Only match at top level (not inside nested parens of a method call)
        if (paren_depth != 0) continue;

        // Check for == or != that is not === or !==
        const is_eq = i + 1 < condition.len and ch == '=' and condition[i + 1] == '=' and
            (i + 2 >= condition.len or condition[i + 2] != '=');
        const is_ne = i + 1 < condition.len and ch == '!' and condition[i + 1] == '=' and
            (i + 2 >= condition.len or condition[i + 2] != '=');
        // Also skip >= and <=
        const preceded_by_lt_gt = (i > 0 and (condition[i - 1] == '<' or condition[i - 1] == '>'));

        if ((!is_eq and !is_ne) or preceded_by_lt_gt) continue;

        // Extract left operand (before the operator)
        const left_raw = std.mem.trimRight(u8, condition[last_emit..i], " \t");
        // Extract right operand (after the operator)
        const op_end = i + 2;
        const right_end = findExpressionEnd(condition, op_end);
        const right_raw = std.mem.trim(u8, condition[op_end..right_end], " \t");

        if (left_raw.len == 0 or right_raw.len == 0) continue;

        // Skip if either side is null
        if (std.mem.eql(u8, left_raw, "null") or std.mem.eql(u8, right_raw, "null")) continue;

        const left_has_object = containsKnownObjectIdentifier(object_names, left_raw);
        const right_has_object = containsKnownObjectIdentifier(object_names, right_raw);
        const left_has_call = std.mem.indexOfScalar(u8, left_raw, '(') != null;
        const right_has_call = std.mem.indexOfScalar(u8, right_raw, '(') != null;
        if (!left_has_object and !right_has_object and !left_has_call and !right_has_call) continue;

        // Skip if either side is true/false unless this is an object comparison.
        if (!left_has_object and !right_has_object) {
            if (std.mem.eql(u8, left_raw, "true") or std.mem.eql(u8, left_raw, "false")) continue;
            if (std.mem.eql(u8, right_raw, "true") or std.mem.eql(u8, right_raw, "false")) continue;
            if (isNumericLiteral(left_raw) or isNumericLiteral(right_raw)) continue;
        }

        // Extract the real left operand from last_emit (might include && or ||)
        const left_start = findLeftOperandStart(condition, i);
        const left_operand = std.mem.trim(u8, condition[left_start..i], " \t");
        if (left_operand.len == 0) continue;
        if (std.mem.eql(u8, left_operand, "null")) continue;
        if (isNumericLiteral(left_operand) and !containsKnownObjectIdentifier(object_names, left_operand)) continue;

        try out.appendSlice(gpa, condition[last_emit..left_start]);
        const method = if (is_ne) "ApexEquals.ne" else "ApexEquals.eq";
        try appendFmt(gpa, &out, "{s}({s}, {s})", .{ method, left_operand, right_raw });
        replaced = true;
        last_emit = right_end;
        i = if (right_end > 0) right_end - 1 else 0;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, condition);
    }
    try out.appendSlice(gpa, condition[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn containsKnownObjectIdentifier(object_names: []const []u8, expr: []const u8) bool {
    for (object_names) |name| {
        if (containsStandaloneIdentifier(expr, name)) return true;
    }
    return false;
}

fn rewriteSimpleObjectEqualityExpression(
    gpa: std.mem.Allocator,
    expr: []const u8,
    object_names: []const []u8,
) !?[]u8 {
    const op = findSimpleEqualityOperator(expr) orelse return null;
    const lhs = std.mem.trim(u8, expr[0..op.start], " \t");
    const rhs = std.mem.trim(u8, expr[(op.start + 2)..], " \t");
    if (lhs.len == 0 or rhs.len == 0) return null;
    if (std.mem.eql(u8, lhs, "null") or std.mem.eql(u8, rhs, "null")) return null;
    if (!containsKnownObjectIdentifier(object_names, lhs) and !containsKnownObjectIdentifier(object_names, rhs)) return null;

    const method = if (op.is_ne) "ApexEquals.ne" else "ApexEquals.eq";
    return try std.fmt.allocPrint(gpa, "{s}({s}, {s})", .{ method, lhs, rhs });
}

fn findSimpleEqualityOperator(expr: []const u8) ?struct { start: usize, is_ne: bool } {
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var paren_depth: i32 = 0;

    var i: usize = 0;
    while (i + 1 < expr.len) : (i += 1) {
        const ch = expr[i];
        if (in_single) {
            if (ch == '\'' and i + 1 < expr.len and expr[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
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
        switch (ch) {
            '\'' => in_single = true,
            '"' => {
                in_double = true;
                escaped = false;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            else => {},
        }
        if (paren_depth != 0) continue;
        if (ch == '!' and expr[i + 1] == '=') return .{ .start = i, .is_ne = true };
        if (ch == '=' and expr[i + 1] == '=' and (i == 0 or (expr[i - 1] != '<' and expr[i - 1] != '>' and expr[i - 1] != '!'))) {
            return .{ .start = i, .is_ne = false };
        }
    }
    return null;
}

fn containsStandaloneIdentifier(text: []const u8, identifier: []const u8) bool {
    if (identifier.len == 0 or text.len < identifier.len) return false;
    var i: usize = 0;
    while (i + identifier.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + identifier.len], identifier)) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        const after = i + identifier.len;
        if (after < text.len and isIdentifierChar(text[after])) continue;
        return true;
    }
    return false;
}

fn findLeftOperandStart(text: []const u8, op_pos: usize) usize {
    // Walk backwards from op_pos to find the start of the left operand.
    // Stop at && || , ; { or start of text.
    var pos: usize = op_pos;
    var paren_depth: i32 = 0;
    while (pos > 0) {
        pos -= 1;
        const ch = text[pos];
        if (ch == ')') {
            paren_depth += 1;
            continue;
        }
        if (ch == '(') {
            if (paren_depth > 0) {
                paren_depth -= 1;
                continue;
            }
            return pos + 1;
        }
        if (paren_depth > 0) continue;
        if (ch == '&' and pos > 0 and text[pos - 1] == '&') return pos + 1;
        if (ch == '|' and pos > 0 and text[pos - 1] == '|') return pos + 1;
        if (ch == ',' or ch == ';' or ch == '{') return pos + 1;
        if (ch == '!') return pos + 1;
    }
    return 0;
}

fn findExpressionEnd(text: []const u8, start: usize) usize {
    // Find the end of a right-hand expression (up to && || ) , ; or end of text).
    var pos = start;
    var paren_depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (pos < text.len) : (pos += 1) {
        const ch = text[pos];
        if (in_str) {
            if (esc) {
                esc = false;
                continue;
            }
            if (ch == '\\') {
                esc = true;
                continue;
            }
            if (ch == '"') in_str = false;
            continue;
        }
        if (ch == '"') {
            in_str = true;
            continue;
        }
        if (ch == '(') {
            paren_depth += 1;
            continue;
        }
        if (ch == ')') {
            if (paren_depth > 0) {
                paren_depth -= 1;
                continue;
            }
            return pos;
        }
        if (paren_depth > 0) continue;
        if (ch == '&' and pos + 1 < text.len and text[pos + 1] == '&') return pos;
        if (ch == '|' and pos + 1 < text.len and text[pos + 1] == '|') return pos;
        if (ch == ',' or ch == ';') return pos;
    }
    return text.len;
}

fn isNumericLiteral(text: []const u8) bool {
    if (text.len == 0) return false;
    var start: usize = 0;
    if (text[0] == '-' or text[0] == '+') start = 1;
    if (start >= text.len) return false;
    var has_digit = false;
    for (text[start..]) |ch| {
        if (ch >= '0' and ch <= '9') {
            has_digit = true;
        } else if (ch == '.' or ch == 'L' or ch == 'l' or ch == 'f' or ch == 'F' or ch == 'd' or ch == 'D') {
            // decimal/long/float suffix ok
        } else {
            return false;
        }
    }
    return has_digit;
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
        "PricebookEntry",
        "Pricebook2",
        "OpportunityLineItem",
        "OpportunityContactRole",
        "Order",
        "OrderItem",
        "Quote",
        "QuoteLineItem",
        "ContentDocument",
        "ContentDocumentLink",
        "ContentVersion",
        "ContentDistribution",
        "EmailMessage",
        "EmailMessageRelation",
        "EntityDefinition",
        "StaticResource",
        "KnowledgeArticleVersion",
        "Profile",
        "PermissionSet",
        "ObjectPermissions",
        "PermissionSetAssignment",
        "CronTrigger",
    };

    for (standard_objects) |name| {
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }

    return false;
}

fn isLikelyCustomSObjectTypeName(type_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_name, " \t");
    if (trimmed.len == 0) return false;

    if (endsWithIgnoreCase(trimmed, "__c") or
        endsWithIgnoreCase(trimmed, "__mdt") or
        endsWithIgnoreCase(trimmed, "__e") or
        endsWithIgnoreCase(trimmed, "__x") or
        endsWithIgnoreCase(trimmed, "__b") or
        endsWithIgnoreCase(trimmed, "__kav"))
    {
        return true;
    }

    return endsWithIgnoreCase(trimmed, "ChangeEvent");
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

        const query_normalized = try normalizeSoqlQueryForEmulation(gpa, query_raw);
        defer gpa.free(query_normalized);

        const quoted = try quoteJavaStringLiteral(gpa, query_normalized);
        defer gpa.free(quoted);
        const replacement = try buildDatabaseQueryCall(gpa, query_normalized, quoted);
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

fn convertInlineSoslQueries(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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
        if (query_raw.len == 0 or !startsWithIgnoreCase(query_raw, "FIND")) continue;

        const query_normalized = try normalizeSoslQueryForEmulation(gpa, query_raw);
        defer gpa.free(query_normalized);
        const quoted = try quoteJavaStringLiteral(gpa, query_normalized);
        defer gpa.free(quoted);
        const replacement = try buildDatabaseSearchCall(gpa, query_normalized, quoted);
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

fn normalizeSoslQueryForEmulation(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var in_single = false;
    var prev_space = false;
    for (query) |ch| {
        if (ch == '\'') {
            in_single = !in_single;
            try out.append(gpa, ch);
            prev_space = false;
            continue;
        }

        if (!in_single and (ch == '\n' or ch == '\r' or ch == '\t' or ch == ' ')) {
            if (!prev_space and out.items.len > 0) {
                try out.append(gpa, ' ');
                prev_space = true;
            }
            continue;
        }

        try out.append(gpa, ch);
        prev_space = false;
    }

    const owned = try out.toOwnedSlice(gpa);
    const normalized = std.mem.trim(u8, owned, " \t");
    if (normalized.ptr == owned.ptr and normalized.len == owned.len) {
        return owned;
    }

    const trimmed = try gpa.dupe(u8, normalized);
    gpa.free(owned);
    return trimmed;
}

fn buildDatabaseSearchCall(
    gpa: std.mem.Allocator,
    query_segment: []const u8,
    java_query_literal: []const u8,
) ![]u8 {
    var bind_names = try collectSoqlBindNamesFromJavaLiteral(gpa, java_query_literal);
    defer bind_names.deinit(gpa);
    _ = query_segment;
    if (bind_names.items.len == 0) {
        return std.fmt.allocPrint(gpa, "Database.search({s})", .{java_query_literal});
    }

    var bind_map_args: std.ArrayList(u8) = .empty;
    defer bind_map_args.deinit(gpa);
    for (bind_names.items, 0..) |bind_name, idx| {
        const bind_expr = try convertBindReferenceToJava(gpa, bind_name);
        defer gpa.free(bind_expr);
        if (idx != 0) try bind_map_args.appendSlice(gpa, ", ");
        try appendFmt(gpa, &bind_map_args, "\"{s}\", {s}", .{ bind_name, bind_expr });
    }
    return std.fmt.allocPrint(
        gpa,
        "Database.searchWithBinds({s}, ApexCollections.bindMap({s}))",
        .{ java_query_literal, bind_map_args.items },
    );
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
        const query_source = parseDatabaseQuerySource(gpa, first_arg) orelse continue;
        defer {
            gpa.free(query_source.query_arg);
            if (query_source.binds_arg) |binds| gpa.free(binds);
        }

        const one_arg = std.ascii.eqlIgnoreCase(method_name.?, "getQueryLocator") or
            std.ascii.eqlIgnoreCase(method_name.?, "countQuery");
        if (one_arg and args.items.len != 1) continue;
        if (!one_arg and args.items.len < 2) continue;

        var replacement: std.ArrayList(u8) = .empty;
        defer replacement.deinit(gpa);
        var rewritten_method = method_name.?;
        if (query_source.binds_arg != null and one_arg) {
            if (std.ascii.eqlIgnoreCase(method_name.?, "countQuery")) {
                rewritten_method = "countQueryWithBinds";
            } else if (std.ascii.eqlIgnoreCase(method_name.?, "getQueryLocator")) {
                rewritten_method = "getQueryLocatorWithBinds";
            }
        }

        try appendFmt(gpa, &replacement, "Database.{s}(", .{rewritten_method});
        try replacement.appendSlice(gpa, query_source.query_arg);
        if (query_source.binds_arg) |binds| {
            if (one_arg) {
                try replacement.appendSlice(gpa, ", ");
                try replacement.appendSlice(gpa, binds);
            } else {
                for (args.items[1..]) |tail_arg| {
                    try replacement.appendSlice(gpa, ", ");
                    try replacement.appendSlice(gpa, tail_arg);
                }
            }
        } else if (!one_arg) {
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

const DatabaseQuerySource = struct {
    query_arg: []u8,
    binds_arg: ?[]u8 = null,
};

fn parseDatabaseQuerySource(gpa: std.mem.Allocator, arg: []const u8) ?DatabaseQuerySource {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) return null;

    const query_like = [_]struct {
        method: []const u8,
        with_binds: bool,
    }{
        .{ .method = "Database.queryWithBinds", .with_binds = true },
        .{ .method = "Database.query", .with_binds = false },
    };

    for (query_like) |candidate| {
        if (!startsWithIgnoreCase(trimmed, candidate.method)) continue;
        const method_end = candidate.method.len;
        if (method_end < trimmed.len and isIdentifierChar(trimmed[method_end])) continue;

        var cursor = method_end;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        if (cursor >= trimmed.len or trimmed[cursor] != '(') continue;

        const close_paren = findMatchingParen(trimmed, cursor) orelse continue;
        const trailing = std.mem.trim(u8, trimmed[(close_paren + 1)..], " \t");
        if (trailing.len != 0) continue;

        const args_raw = std.mem.trim(u8, trimmed[(cursor + 1)..close_paren], " \t");
        if (args_raw.len == 0) continue;
        var args = splitCallArguments(gpa, args_raw) catch continue;
        defer args.deinit(gpa);

        if (!candidate.with_binds and args.items.len == 1) {
            const query_arg = gpa.dupe(u8, std.mem.trim(u8, args.items[0], " \t")) catch continue;
            return .{ .query_arg = query_arg };
        }

        if (candidate.with_binds and args.items.len >= 2) {
            const query_arg = gpa.dupe(u8, std.mem.trim(u8, args.items[0], " \t")) catch continue;
            const binds_arg = gpa.dupe(u8, std.mem.trim(u8, args.items[1], " \t")) catch {
                gpa.free(query_arg);
                continue;
            };
            return .{
                .query_arg = query_arg,
                .binds_arg = binds_arg,
            };
        }
    }
    return null;
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
        if (isWithinImportOrPackageDeclaration(text, i)) continue;
        if (isWithinAnnotationQualifiedChain(text, i)) continue;
        if (i + 1 >= text.len or !isIdentifierChar(text[i + 1])) continue;

        var end = i + 1;
        while (end < text.len and isIdentifierChar(text[end])) : (end += 1) {}
        const member = text[(i + 1)..end];
        if (!isLikelySObjectFieldName(member)) continue;

        const next_non_space = nextNonSpace(text, end);
        if (next_non_space < text.len and text[next_non_space] == '(') continue;

        if (baseIdentifierBeforeDot(text, i)) |base| {
            if (isLikelyTypeReferenceIdentifier(base.value)) continue;
            if (std.ascii.eqlIgnoreCase(base.value, "this")) continue;
            if (isLikelyQualifiedTypeChain(text, base)) continue;
        }

        const base_start = findMemberAccessBaseStart(text, i) orelse {
            try out.appendSlice(gpa, text[last_emit..i]);
            try appendFmt(gpa, &out, ".getAs(\"{s}\")", .{member});
            replaced = true;
            i = end - 1;
            last_emit = end;
            continue;
        };
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (shouldSkipSObjectFieldAccessBase(base_expr)) continue;
        if (isLikelyTypeReferencePathExpression(base_expr) and
            !isStaticValueAccessPathExpression(base_expr) and
            !endsWithIgnoreCase(base_expr, ".fields") and
            !endsWithIgnoreCase(base_expr, ".SObjectType") and
            !endsWithIgnoreCase(base_expr, ".sObjectType"))
        {
            continue;
        }
        if (std.mem.indexOf(u8, base_expr, ".getAs(") != null or std.mem.indexOf(u8, base_expr, ".getas(") != null) {
            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "ApexSwitch.getAs({s}, \"{s}\")", .{ base_expr, member });
        } else {
            try out.appendSlice(gpa, text[last_emit..i]);
            try appendFmt(gpa, &out, ".getAs(\"{s}\")", .{member});
        }
        replaced = true;
        i = end - 1;
        last_emit = end;
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

fn shouldSkipSObjectFieldAccessBase(base_expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, base_expr, " \t");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "Database")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "System")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "Component")) return true;
    if (startsWithIgnoreCase(trimmed, "Component.")) return true;
    return false;
}

fn isWithinImportOrPackageDeclaration(text: []const u8, pos: usize) bool {
    if (pos >= text.len) return false;
    var line_start = pos;
    while (line_start > 0 and text[line_start - 1] != '\n') : (line_start -= 1) {}
    var line_end = pos;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line = std.mem.trim(u8, text[line_start..line_end], " \t");
    if (line.len == 0) return false;
    return startsWithWordIgnoreCase(line, "import") or startsWithWordIgnoreCase(line, "package");
}

fn isWithinAnnotationQualifiedChain(text: []const u8, dot_pos: usize) bool {
    if (dot_pos == 0 or dot_pos >= text.len) return false;
    var cursor = dot_pos;
    while (cursor > 0 and (isIdentifierChar(text[cursor - 1]) or text[cursor - 1] == '.')) : (cursor -= 1) {}
    return cursor > 0 and text[cursor - 1] == '@';
}

fn isLikelySObjectFieldName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(name, "List")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Map")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Set")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Database")) return false;
    if (std.ascii.eqlIgnoreCase(name, "System")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Schema")) return false;
    if (std.ascii.eqlIgnoreCase(name, "email")) return true;
    if (std.ascii.eqlIgnoreCase(name, "body")) return true;
    if (std.ascii.eqlIgnoreCase(name, "name")) return true;
    if (std.ascii.eqlIgnoreCase(name, "developerName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "filename")) return true;
    if (std.ascii.eqlIgnoreCase(name, "timesTriggered")) return true;
    if (std.ascii.eqlIgnoreCase(name, "nextFireTime")) return true;
    if (std.ascii.eqlIgnoreCase(name, "title")) return true;
    if (std.ascii.eqlIgnoreCase(name, "status")) return true;
    if (std.ascii.eqlIgnoreCase(name, "shippingStreet")) return true;
    if (std.ascii.eqlIgnoreCase(name, "shippingState")) return true;
    if (std.ascii.eqlIgnoreCase(name, "account")) return true;
    if (std.ascii.eqlIgnoreCase(name, "accountId")) return true;
    if (std.ascii.eqlIgnoreCase(name, "ownerId")) return true;
    if (std.ascii.eqlIgnoreCase(name, "firstName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "lastName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "isSandbox")) return true;
    if (std.ascii.eqlIgnoreCase(name, "isReadOnly")) return true;
    if (std.ascii.eqlIgnoreCase(name, "orgType")) return true;
    if (std.ascii.eqlIgnoreCase(name, "instanceName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "podName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "fiscalYearStartMonth")) return true;
    if (std.ascii.eqlIgnoreCase(name, "getFiscalYearStartMonth")) return true;
    if (std.ascii.eqlIgnoreCase(name, "lightningEnabled")) return true;
    if (std.ascii.eqlIgnoreCase(name, "languageLocaleKey")) return true;
    if (std.ascii.eqlIgnoreCase(name, "locale")) return true;
    if (std.ascii.eqlIgnoreCase(name, "for")) return true;
    if (std.ascii.eqlIgnoreCase(name, "timeZoneSidKey")) return true;
    if (std.ascii.eqlIgnoreCase(name, "timeZoneKey")) return true;
    if (std.ascii.eqlIgnoreCase(name, "namespacePrefix")) return true;
    if (std.ascii.eqlIgnoreCase(name, "hasNamespacePrefix")) return true;
    if (std.ascii.eqlIgnoreCase(name, "shareType")) return true;
    if (std.ascii.isUpper(name[0])) return true;
    if (std.mem.indexOf(u8, name, "__") != null) return true;
    if (std.ascii.eqlIgnoreCase(name, "id")) return true;
    return false;
}

fn isJavaReservedWord(name: []const u8) bool {
    const reserved = [_][]const u8{
        "abstract", "assert",       "boolean",  "break",     "byte",   "case",      "catch",    "char",
        "class",    "const",        "continue", "default",   "do",     "double",    "else",     "enum",
        "extends",  "final",        "finally",  "float",     "for",    "goto",      "if",       "implements",
        "import",   "instanceof",   "int",      "interface", "long",   "native",    "new",      "package",
        "private",  "protected",    "public",   "return",    "short",  "static",    "strictfp", "super",
        "switch",   "synchronized", "this",     "throw",     "throws", "transient", "try",      "void",
        "volatile", "while",
    };
    for (reserved) |keyword| {
        if (std.ascii.eqlIgnoreCase(name, keyword)) return true;
    }
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
    var single_escaped = false;
    var in_double = false;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = true;
            single_escaped = false;
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

fn findMatchingParenBackward(text: []const u8, close_index: usize) ?usize {
    if (close_index >= text.len or text[close_index] != ')') return null;

    var i: usize = close_index + 1;
    while (i > 0) {
        i -= 1;
        if (text[i] != '(') continue;
        const close = findMatchingParen(text, i) orelse continue;
        if (close == close_index) return i;
    }
    return null;
}

fn findMatchingAngleBackward(text: []const u8, close_index: usize) ?usize {
    if (close_index >= text.len or text[close_index] != '>') return null;

    var i: usize = close_index + 1;
    while (i > 0) {
        i -= 1;
        if (text[i] != '<') continue;
        const close = findMatchingAngle(text, i) orelse continue;
        if (close == close_index) return i;
    }
    return null;
}

fn findMatchingBrace(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '{') return null;

    var depth: i32 = 0;
    var in_single = false;
    var single_escaped = false;
    var in_double = false;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = true;
            single_escaped = false;
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
    var single_escaped = false;
    var in_double = false;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = true;
            single_escaped = false;
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
    var single_escaped = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = true;
            single_escaped = false;
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

fn findTopLevelSafeNavigationOperator(text: []const u8) ?usize {
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
            '?' => {
                if (text[i + 1] == '.' and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    return i;
                }
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

const IndexedLvalue = struct {
    base_expr: []const u8,
    index_expr: []const u8,
};

fn parseJavaKeywordMemberLvalue(lhs: []const u8) ?SObjectFieldLvalue {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len == 0) return null;

    const dot_pos = findLastTopLevelDot(trimmed) orelse return null;
    const base_expr = std.mem.trim(u8, trimmed[0..dot_pos], " \t");
    const field_name = std.mem.trim(u8, trimmed[(dot_pos + 1)..], " \t");
    if (base_expr.len == 0 or field_name.len == 0) return null;
    if (!isSimpleIdentifier(field_name)) return null;
    if (!isJavaReservedWord(field_name)) return null;
    if (isLikelyTypeReferencePathExpression(base_expr)) return null;
    return .{
        .base_expr = base_expr,
        .field_name = field_name,
    };
}

fn parseIndexedLvalue(lhs: []const u8) ?IndexedLvalue {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len < 4 or trimmed[trimmed.len - 1] != ']') return null;

    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] != '[') continue;
        const close = findMatchingSquareBracket(trimmed, i) orelse continue;
        if (close != trimmed.len - 1) continue;
        const base_expr = std.mem.trim(u8, trimmed[0..i], " \t");
        const index_expr = std.mem.trim(u8, trimmed[(i + 1)..close], " \t");
        if (base_expr.len == 0 or index_expr.len == 0) return null;
        return .{
            .base_expr = base_expr,
            .index_expr = index_expr,
        };
    }
    return null;
}

fn parseSObjectFieldLvalue(lhs: []const u8) ?SObjectFieldLvalue {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len == 0) return null;

    const dot_pos = findLastTopLevelDot(trimmed) orelse return null;
    const base_expr = std.mem.trim(u8, trimmed[0..dot_pos], " \t");
    const field_name = std.mem.trim(u8, trimmed[(dot_pos + 1)..], " \t");
    if (base_expr.len == 0 or field_name.len == 0) return null;
    if (!isSimpleIdentifier(field_name)) return null;
    if (!isLikelySObjectFieldName(field_name)) return null;
    if (isLikelyTypeReferencePathExpression(base_expr)) return null;
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

fn prevNonSpace(text: []const u8, from: usize) ?u8 {
    if (from == 0) return null;
    var i = from;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isWhitespace(text[i])) continue;
        return text[i];
    }
    return null;
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

    if (!isLikelyTypeReferenceIdentifier(prev_span.value)) return false;
    if (isLikelyTypeReferenceIdentifier(base.value)) return true;
    return startsWithIgnoreCase(base.value, "inboundEmail");
}

fn isLikelyTypeReferenceIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isUpper(name[0])) return true;

    if (startsWithIgnoreCase(name, "fflib_")) {
        var idx: usize = "fflib_".len;
        while (idx < name.len) : (idx += 1) {
            if (std.ascii.isUpper(name[idx])) return true;
        }
    }
    return false;
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

fn isApexTriggerSource(path: []const u8) bool {
    return std.fs.path.extension(path).len == 8 and std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".trigger");
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

fn isTestAnnotationSeeAllDataTrue(annotation_line: []const u8) bool {
    if (!isIsTestAnnotation(annotation_line)) return false;
    const open = std.mem.indexOfScalar(u8, annotation_line, '(') orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, annotation_line, ')') orelse return false;
    if (close <= open + 1) return false;

    const args = annotation_line[(open + 1)..close];
    const key_idx = indexOfIgnoreCase(args, "seealldata") orelse return false;
    var cursor = key_idx + "seealldata".len;
    while (cursor < args.len and (args[cursor] == ' ' or args[cursor] == '\t')) : (cursor += 1) {}
    if (cursor >= args.len or args[cursor] != '=') return false;
    cursor += 1;
    while (cursor < args.len and (args[cursor] == ' ' or args[cursor] == '\t')) : (cursor += 1) {}
    return startsWithWordIgnoreCase(args[cursor..], "true");
}

fn isTestSetupAnnotation(line: []const u8) bool {
    if (line.len < 10) return false;
    if (line[0] != '@') return false;
    return startsWithIgnoreCase(line, "@testsetup");
}

fn isTestVisibleAnnotation(line: []const u8) bool {
    if (line.len < 12) return false;
    if (line[0] != '@') return false;
    return startsWithIgnoreCase(line, "@testvisible");
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

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn startsWithWordIgnoreCase(haystack: []const u8, keyword: []const u8) bool {
    if (!startsWithIgnoreCase(haystack, keyword)) return false;
    if (haystack.len == keyword.len) return true;
    const next = haystack[keyword.len];
    return !isIdentifierChar(next);
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

        const right_fixed = blk: {
            const is_query = startsWithIgnoreCase(right, "Database.query(") or startsWithIgnoreCase(right, "Database.queryWithBinds(");
            if (startsWithIgnoreCase(java_type, "List<") and is_query) {
                break :blk try std.fmt.allocPrint(
                    gpa,
                    "ApexCollections.chunk((List<ApexSObject>) ({s}), 200)",
                    .{right},
                );
            }
            if (std.ascii.eqlIgnoreCase(java_type, "ApexSObject") and is_query) {
                break :blk try std.fmt.allocPrint(gpa, "(List<ApexSObject>) ({s})", .{right});
            }
            break :blk try gpa.dupe(u8, right);
        };
        defer gpa.free(right_fixed);

        const prefix = line[0..(open_paren + 1)];
        const suffix = line[close_paren..];
        return std.fmt.allocPrint(
            gpa,
            "{s}{s} {s} : {s}{s}",
            .{ prefix, java_type, var_name, right_fixed, suffix },
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
    statements: []const LogicalStatement,
    start_idx: usize,
) !SwitchMode {
    if (start_idx >= statements.len) return .value;
    const start_stmt = std.mem.trim(u8, statements[start_idx].text, " \t");
    if (!startsWithWordIgnoreCase(start_stmt, "switch")) return .value;

    var depth = braceDelta(start_stmt);
    if (depth <= 0) depth = 1;

    var i = start_idx + 1;
    while (i < statements.len and depth > 0) : (i += 1) {
        const stmt = std.mem.trim(u8, statements[i].text, " \t");
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
    return isTypeIdentifierPath(trimmed);
}

fn isTypeIdentifierPath(raw: []const u8) bool {
    var parts = std.mem.splitScalar(u8, raw, '.');
    var saw_segment = false;
    while (parts.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) return false;
        saw_segment = true;
        if (!std.ascii.isAlphabetic(segment[0]) and segment[0] != '_') return false;
        for (segment[1..]) |ch| {
            if (!isIdentifierChar(ch)) return false;
        }
    }
    return saw_segment;
}

fn isIdentifierPathExpression(raw: []const u8) bool {
    var parts = std.mem.splitScalar(u8, raw, '.');
    var saw_segment = false;
    while (parts.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (!isSimpleIdentifier(segment)) return false;
        saw_segment = true;
    }
    return saw_segment;
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

fn isLikelyNonMethodLeadKeyword(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, "select") or
        std.ascii.eqlIgnoreCase(word, "from") or
        std.ascii.eqlIgnoreCase(word, "where") or
        std.ascii.eqlIgnoreCase(word, "order") or
        std.ascii.eqlIgnoreCase(word, "group") or
        std.ascii.eqlIgnoreCase(word, "having") or
        std.ascii.eqlIgnoreCase(word, "limit") or
        std.ascii.eqlIgnoreCase(word, "offset") or
        std.ascii.eqlIgnoreCase(word, "insert") or
        std.ascii.eqlIgnoreCase(word, "update") or
        std.ascii.eqlIgnoreCase(word, "upsert") or
        std.ascii.eqlIgnoreCase(word, "delete") or
        std.ascii.eqlIgnoreCase(word, "undelete") or
        std.ascii.eqlIgnoreCase(word, "merge");
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
    var in_single = false;
    var in_double = false;
    var single_escaped = false;
    var double_escaped = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];

        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < line.len and line[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') {
                in_single = false;
            }
            continue;
        }

        if (in_double) {
            if (double_escaped) {
                double_escaped = false;
                continue;
            }
            if (ch == '\\') {
                double_escaped = true;
                continue;
            }
            if (ch == '"') {
                in_double = false;
            }
            continue;
        }

        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '{' => delta += 1,
            '}' => delta -= 1,
            else => {},
        }
    }
    return delta;
}

fn parenDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var in_single = false;
    var in_double = false;
    var single_escaped = false;
    var double_escaped = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];

        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < line.len and line[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }

        if (in_double) {
            if (double_escaped) {
                double_escaped = false;
                continue;
            }
            if (ch == '\\') {
                double_escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }

        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '(' => delta += 1,
            ')' => delta -= 1,
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

    const sig_http = (try parseMethodSignature(gpa, "public HTTPResponse respond(HTTPRequest req) {", "Demo")).?;
    defer {
        gpa.free(sig_http.name);
        gpa.free(sig_http.java_return_type);
        gpa.free(sig_http.java_parameters);
    }
    try std.testing.expectEqualStrings("respond", sig_http.name);
    try std.testing.expectEqualStrings("HttpResponse", sig_http.java_return_type);
    try std.testing.expectEqualStrings("HttpRequest req", sig_http.java_parameters);

    try std.testing.expect((try parseMethodSignature(gpa, "for (Integer i = 0; i < 10; i++) {", "Demo")) == null);
    try std.testing.expect((try parseMethodSignature(gpa, "if (records == null) {", "Demo")) == null);
    try std.testing.expect((try parseMethodSignature(gpa, "public Demo() {", "Demo")) == null);
}

test "braceDelta ignores braces inside string literals" {
    try std.testing.expectEqual(@as(i32, 1), braceDelta("if (ready) {"));
    try std.testing.expectEqual(@as(i32, -1), braceDelta("}"));
    try std.testing.expectEqual(
        @as(i32, 1),
        braceDelta("String payload = '{\"ok\":true}'; if (go) {"),
    );
    try std.testing.expectEqual(
        @as(i32, 0),
        braceDelta("System.debug(\"{still string}\");"),
    );
}

test "parseApexClass captures multiline method and constructor signatures" {
    const gpa = std.testing.allocator;
    const source =
        \\public class MultiLineSignatureDemo {
        \\  @IsTest
        \\  public static void run(
        \\      List<Account> records,
        \\      Integer limit
        \\  )
        \\  {
        \\    System.debug(records);
        \\  }
        \\
        \\  public MultiLineSignatureDemo(
        \\      Integer n
        \\  )
        \\  {
        \\    System.debug(n);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "MultiLineSignatureDemo.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), parsed.methods.items.len);
    try std.testing.expectEqualStrings("run", parsed.methods.items[0].name);
    try std.testing.expect(parsed.methods.items[0].is_test);
    try std.testing.expectEqualStrings("List<ApexSObject> records, Integer limit", parsed.methods.items[0].java_parameters);
    try std.testing.expect(parsed.methods.items[0].start_line > 0);

    try std.testing.expect(parsed.methods.items[1].is_constructor);
    try std.testing.expectEqualStrings("MultiLineSignatureDemo", parsed.methods.items[1].name);
    try std.testing.expectEqualStrings("Integer n", parsed.methods.items[1].java_parameters);

    var rendered = try renderJavaClass(gpa, parsed, "generated");
    defer rendered.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "public static void run(List<ApexSObject> records, Integer limit)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "public MultiLineSignatureDemo(Integer n)") != null);
}

test "parseApexClass captures @testSetup methods separately from @isTest methods" {
    const gpa = std.testing.allocator;
    const source =
        \\@isTest
        \\public class SetupDemo {
        \\  @testSetup
        \\  static void setupData() {
        \\    insert new Account(Name='A');
        \\  }
        \\
        \\  @isTest
        \\  static void testRun() {
        \\    System.assert(true);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "SetupDemo.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), parsed.methods.items.len);
    try std.testing.expectEqualStrings("setupData", parsed.methods.items[0].name);
    try std.testing.expect(parsed.methods.items[0].is_test_setup);
    try std.testing.expect(!parsed.methods.items[0].is_test);
    try std.testing.expectEqualStrings("testRun", parsed.methods.items[1].name);
    try std.testing.expect(parsed.methods.items[1].is_test);
}

test "parseApexClass captures seeAllData on class and method @isTest annotations" {
    const gpa = std.testing.allocator;
    const source =
        \\@isTest(SeeAllData=true)
        \\public class SeeAllDataDemo {
        \\  static void testImplicitFromClass() {
        \\    System.assert(true);
        \\  }
        \\
        \\  @isTest
        \\  static void testExplicitFromClass() {
        \\    System.assert(true);
        \\  }
        \\
        \\  @isTest(seeAllData = true)
        \\  static void testMethodLevel() {
        \\    System.assert(true);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "SeeAllDataDemo.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), parsed.methods.items.len);
    try std.testing.expect(parsed.methods.items[0].is_test);
    try std.testing.expect(parsed.methods.items[0].is_test_see_all_data);
    try std.testing.expect(parsed.methods.items[1].is_test);
    try std.testing.expect(parsed.methods.items[1].is_test_see_all_data);
    try std.testing.expect(parsed.methods.items[2].is_test);
    try std.testing.expect(parsed.methods.items[2].is_test_see_all_data);
}

test "parseApexClass ignores comment lines that look like signatures before enum" {
    const gpa = std.testing.allocator;
    const source =
        \\public class RestClient {
        \\  /**
        \\   * Keyword (DML) note should not be parsed as method signature.
        \\   */
        \\  public enum HttpVerb {
        \\    GET,
        \\    POST,
        \\    DEL
        \\  }
        \\
        \\  public static void ping() {
        \\    System.debug('ok');
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "RestClient.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), parsed.methods.items.len);
    try std.testing.expectEqualStrings("ping", parsed.methods.items[0].name);
}

test "parseApexClass captures nested classes without flattening their members" {
    const gpa = std.testing.allocator;
    const source =
        \\public class OuterService {
        \\  public static void run() {
        \\    System.debug('ok');
        \\  }
        \\
        \\  public class GeocodingAddress {
        \\    public String street;
        \\  }
        \\
        \\  public class OpenStreetMapHttpCalloutMockImpl implements HttpCalloutMock {
        \\    public HTTPResponse respond(HTTPRequest req) {
        \\      HttpResponse res = new HttpResponse();
        \\      return res;
        \\    }
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "OuterService.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), parsed.methods.items.len);
    try std.testing.expectEqualStrings("run", parsed.methods.items[0].name);

    var found_address = false;
    var found_mock = false;
    for (parsed.fields.items) |field| {
        if (std.mem.indexOf(u8, field.declaration, "static class GeocodingAddress") != null) {
            found_address = true;
        }
        if (std.mem.indexOf(u8, field.declaration, "static class OpenStreetMapHttpCalloutMockImpl implements HttpCalloutMock") != null) {
            found_mock = true;
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, "public HttpResponse respond(HttpRequest req)") != null);
        }
    }
    try std.testing.expect(found_address);
    try std.testing.expect(found_mock);
}

test "parseApexClass ignores string literals with class keywords for inner type detection" {
    const gpa = std.testing.allocator;
    const source =
        \\public class FinalizerHandler {
        \\  private static final String INVALID_TYPE_ERROR_FINALIZER = 'Please check metadata. The {0} class does not implement the TriggerAction.DmlFinalizer interface.';
        \\  public static void run() {
        \\    System.debug(INVALID_TYPE_ERROR_FINALIZER);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "FinalizerHandler.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), parsed.methods.items.len);
    try std.testing.expectEqualStrings("run", parsed.methods.items[0].name);

    for (parsed.fields.items) |field| {
        try std.testing.expect(std.mem.indexOf(u8, field.declaration, "static class does") == null);
    }
}

test "parseApexClass captures inner class declarations without explicit visibility modifier" {
    const gpa = std.testing.allocator;
    const source =
        \\public class OuterService {
        \\  class BaseTest {
        \\    public void run() {
        \\      System.debug('ok');
        \\    }
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "OuterService.cls", source);
    defer parsed.deinit(gpa);

    var found_inner = false;
    for (parsed.fields.items) |field| {
        if (std.mem.indexOf(u8, field.declaration, "static class BaseTest") != null) {
            found_inner = true;
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, "public void run()") != null);
        }
    }
    try std.testing.expect(found_inner);
}

test "parseApexClass captures multiline class-literal field declarations" {
    const gpa = std.testing.allocator;
    const source =
        \\public class ClassLiteralMember {
        \\  private static final String MY_CLASS = ClassLiteralMember.class
        \\    .getName();
        \\}
    ;

    var parsed = try parseApexClass(gpa, "ClassLiteralMember.cls", source);
    defer parsed.deinit(gpa);

    var found_field = false;
    for (parsed.fields.items) |field| {
        if (std.mem.indexOf(u8, field.declaration, "MY_CLASS") != null) {
            found_field = true;
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, ".class") != null);
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, ".getName()") != null);
        }
    }
    try std.testing.expect(found_field);
}

test "parseApexClass omits self-qualified nested interface implements to avoid Java cyclic inheritance" {
    const gpa = std.testing.allocator;
    const source =
        \\public class fflib_MyList implements IList {
        \\  public interface IList {
        \\    void add(String value);
        \\  }
        \\  public void add(String value) {}
        \\}
    ;

    var parsed = try parseApexClass(gpa, "fflib_MyList.cls", source);
    defer parsed.deinit(gpa);

    var rendered = try renderJavaClass(gpa, parsed, "generated");
    defer rendered.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "public class fflib_MyList {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "implements IList") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "implements fflib_MyList.IList") == null);
}

test "parseApexClass captures multiline property with brace on next line" {
    const gpa = std.testing.allocator;
    const source =
        \\public class PropertyDemo {
        \\  private fflib_Helper helper;
        \\  public Boolean Enabled
        \\  {
        \\    get
        \\    {
        \\      return true;
        \\    }
        \\    private set;
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "PropertyDemo.cls", source);
    defer parsed.deinit(gpa);

    var found_helper = false;
    var found_property = false;
    for (parsed.fields.items) |field| {
        if (std.mem.eql(u8, field.declaration, "private fflib_Helper helper;")) found_helper = true;
        if (std.mem.eql(u8, field.declaration, "public Boolean Enabled; // Apex property { get; set; }")) found_property = true;
    }

    try std.testing.expect(found_helper);
    try std.testing.expect(found_property);
}

test "shouldStartMethodSignatureBuffer ignores annotations and soql fragments" {
    try std.testing.expect(!shouldStartMethodSignatureBuffer("@AuraEnabled(cacheable=true scope='global')", "Demo"));
    try std.testing.expect(!shouldStartMethodSignatureBuffer("SELECT COUNT()", "Demo"));
    try std.testing.expect(shouldStartMethodSignatureBuffer("public static void run(", "Demo"));
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
        .is_test_setup = false,
        .body = try gpa.dupe(u8, "System.assertEquals(1, 1);\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "package generated;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static void firstMethod()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "import apexemu.runtime.ApexAssert;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "import apexemu.runtime.Test;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "SystemAssert.assertEquals(1, 1);") != null);
}

test "renderJavaClass emits seeAllData=true for test methods" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "SeeAllDataTest"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/SeeAllDataTest.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "testMethod"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, ""),
        .is_static = true,
        .is_constructor = false,
        .is_test = true,
        .is_test_setup = false,
        .is_test_see_all_data = true,
        .body = try gpa.dupe(u8, "System.assert(true);\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.Test(seeAllData = true)") != null);
}

test "renderJavaClass emits test setup annotation" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "SampleSetup"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/SampleSetup.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "setupData"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, ""),
        .is_static = true,
        .is_constructor = false,
        .is_test = false,
        .is_test_setup = true,
        .body = try gpa.dupe(u8, "Database.insert(ApexSObject.of(\"Account\"));\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.TestSetup") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.Test\n") == null);
}

test "renderJavaClass emits Number overload for static methods with Double parameters" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "PriceApi"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/PriceApi.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "run"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, "Double maxPrice, Integer page"),
        .is_static = true,
        .is_constructor = false,
        .is_test = false,
        .is_test_setup = false,
        .body = try gpa.dupe(u8, "System.debug(maxPrice);\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static void run(Number maxPrice, Integer page)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "run(maxPrice == null ? null : maxPrice.doubleValue(), page);") != null);
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

test "rewriteSpecificIdentifierCase preserves constructor names with underscores" {
    const gpa = std.testing.allocator;
    const input = "fflib_ApexMocks mocks = new fflib_ApexMocks();";
    const rewritten = try rewriteSpecificIdentifierCase(gpa, input);
    defer gpa.free(rewritten);
    try std.testing.expectEqualStrings(input, rewritten);
}

test "rewriteSystemTypeMethodClassLiteralArgs rewrites class literal args for Type-based methods" {
    const gpa = std.testing.allocator;
    const input = "fflib_MyList mockList = (fflib_MyList)mocks.mock(fflib_MyList.class);";
    const rewritten = try rewriteSystemTypeMethodClassLiteralArgs(gpa, input);
    defer gpa.free(rewritten);
    try std.testing.expectEqualStrings(
        "fflib_MyList mockList = (fflib_MyList)mocks.mock(apexemu.runtime.System.Type.forName(\"fflib_MyList\"));",
        rewritten,
    );
}

test "rewriteSystemTypeMethodClassLiteralArgs rewrites forClass and setReadOnlyFields calls" {
    const gpa = std.testing.allocator;

    const for_class_input = "fflib_ArgumentCaptor argument = fflib_ArgumentCaptor.forClass(String.class);";
    const for_class_rewritten = try rewriteSystemTypeMethodClassLiteralArgs(gpa, for_class_input);
    defer gpa.free(for_class_rewritten);
    try std.testing.expectEqualStrings(
        "fflib_ArgumentCaptor argument = fflib_ArgumentCaptor.forClass(apexemu.runtime.System.Type.forName(\"String\"));",
        for_class_rewritten,
    );

    const set_readonly_input = "acc = (ApexSObject)fflib_ApexMocksUtils.setReadOnlyFields(acc, Account.class, properties);";
    const set_readonly_rewritten = try rewriteSystemTypeMethodClassLiteralArgs(gpa, set_readonly_input);
    defer gpa.free(set_readonly_rewritten);
    try std.testing.expectEqualStrings(
        "acc = (ApexSObject)fflib_ApexMocksUtils.setReadOnlyFields(acc, apexemu.runtime.System.Type.forName(\"Account\"), properties);",
        set_readonly_rewritten,
    );
}

test "rewriteMathModCalls rewrites only standalone Math.mod calls" {
    const gpa = std.testing.allocator;
    const input = "x = Math.mod(a, 2); y = ApexMath.mod(b, 2);";
    const rewritten = try rewriteMathModCalls(gpa, input);
    defer gpa.free(rewritten);
    try std.testing.expectEqualStrings(
        "x = ApexMath.mod(a, 2); y = ApexMath.mod(b, 2);",
        rewritten,
    );
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

    const two_backslash = try transpileAssertionLine(gpa, "Assert.areEqual('don\\'t fail', actual, 'msg');");
    defer if (two_backslash) |value| gpa.free(value);
    try std.testing.expect(two_backslash != null);
    try std.testing.expectEqualStrings(
        "ApexAssert.areEqual(\"don't fail\", actual, \"msg\");",
        two_backslash.?,
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
    try std.testing.expect(
        std.mem.indexOf(u8, soql.?, "Database.query(") != null or
            std.mem.indexOf(u8, soql.?, "Database.queryWithBinds(") != null,
    );

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
        "ApexSObject acc = ApexCollections.firstOrThrow(Database.query(\"SELECT Id, Name FROM Account LIMIT 1\"));",
        single_decl.?,
    );

    const return_count = try transpileSoqlLine(gpa, "return [SELECT COUNT() FROM Account];");
    defer if (return_count) |value| gpa.free(value);
    try std.testing.expect(return_count != null);
    try std.testing.expectEqualStrings(
        "return Database.countQuery(\"SELECT COUNT() FROM Account\");",
        return_count.?,
    );

    const return_single = try transpileSoqlLine(gpa, "return [SELECT Id FROM Account LIMIT 1];");
    defer if (return_single) |value| gpa.free(value);
    try std.testing.expect(return_single != null);
    try std.testing.expectEqualStrings(
        "return ApexCollections.firstOrThrow(Database.query(\"SELECT Id FROM Account LIMIT 1\"));",
        return_single.?,
    );

    const assign_single = try transpileSoqlLine(gpa, "acc = [SELECT Id FROM Account LIMIT 1];");
    defer if (assign_single) |value| gpa.free(value);
    try std.testing.expect(assign_single != null);
    try std.testing.expectEqualStrings(
        "acc = ApexCollections.firstOrThrow(Database.query(\"SELECT Id FROM Account LIMIT 1\"));",
        assign_single.?,
    );

    const assign_single_by_id = try transpileSoqlLine(gpa, "acc = [SELECT Id FROM Account WHERE Id = :accountId];");
    defer if (assign_single_by_id) |value| gpa.free(value);
    try std.testing.expect(assign_single_by_id != null);
    try std.testing.expectEqualStrings(
        "acc = ApexCollections.firstOrThrow(Database.queryWithBinds(\"SELECT Id FROM Account WHERE Id = :accountId\", ApexCollections.bindMap(\"accountId\", accountId)));",
        assign_single_by_id.?,
    );

    const assign_count = try transpileSoqlLine(gpa, "total = [SELECT COUNT() FROM Account];");
    defer if (assign_count) |value| gpa.free(value);
    try std.testing.expect(assign_count != null);
    try std.testing.expectEqualStrings(
        "total = Database.countQuery(\"SELECT COUNT() FROM Account\");",
        assign_count.?,
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

test "transpileExecutableLine routes return soql to soql transpiler" {
    const gpa = std.testing.allocator;
    const converted = try transpileExecutableLine(gpa, "return [SELECT COUNT() FROM Account];");
    defer if (converted) |value| gpa.free(value);
    try std.testing.expect(converted != null);
    try std.testing.expectEqualStrings(
        "return Database.countQuery(\"SELECT COUNT() FROM Account\");",
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
        "Database.countQueryWithBinds(\"SELECT Id FROM Account WHERE Name = :name\", ApexCollections.bindMap(\"name\", name))",
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

    const query_get_as = try convertApexExpressionToJava(
        gpa,
        "Database.query([SELECT Id FROM Profile WHERE Name = :profile]).getAs('Id')",
    );
    defer gpa.free(query_get_as);
    try std.testing.expectEqualStrings(
        "ApexCollections.firstOrThrow(Database.queryWithBinds(\"SELECT Id FROM Profile WHERE Name = :profile\", ApexCollections.bindMap(\"profile\", profile))).getAs(\"Id\")",
        query_get_as,
    );

    const escaped_quote_literal = try convertApexExpressionToJava(
        gpa,
        "'AND Name = ''{1}'''",
    );
    defer gpa.free(escaped_quote_literal);
    try std.testing.expectEqualStrings(
        "\"AND Name = '{1}'\"",
        escaped_quote_literal,
    );

    const escaped_double_quote_literal = try convertApexExpressionToJava(
        gpa,
        "'{\\\"name\\\":\\\"value\\\"}'",
    );
    defer gpa.free(escaped_double_quote_literal);
    try std.testing.expectEqualStrings(
        "\"{\\\"name\\\":\\\"value\\\"}\"",
        escaped_double_quote_literal,
    );

    const idempotent_java_literal = try convertApexExpressionToJava(
        gpa,
        "\"AND Name = '{1}'\"",
    );
    defer gpa.free(idempotent_java_literal);
    try std.testing.expectEqualStrings(
        "\"AND Name = '{1}'\"",
        idempotent_java_literal,
    );
}

test "rewriteDynamicWhereClauseQueryBinds generalizes dynamic where bind propagation" {
    const gpa = std.testing.allocator;
    const source =
        \\public class Demo {
        \\  public static void run() {
        \\    String key = null, whereClause = "";
        \\    List<String> criteria = new ArrayList<String>();
        \\    criteria.add("Name LIKE :key");
        \\    whereClause = "WHERE " + ApexStrings.join(criteria, " AND ");
        \\    Integer total = Database.countQuery("SELECT count() FROM Account " + whereClause);
        \\    List<ApexSObject> rows = Database.queryWithBinds("SELECT Id FROM Account " + whereClause + " ORDER BY Name LIMIT :limit", ApexCollections.bindMap("limit", 10));
        \\  }
        \\}
    ;

    const rewritten = try rewriteDynamicWhereClauseQueryBinds(gpa, source);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Database.countQueryWithBinds(\"SELECT count() FROM Account \" + whereClause, ApexCollections.bindMap(\"key\", key))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Database.queryWithBinds(\"SELECT Id FROM Account \" + whereClause + \" ORDER BY Name LIMIT :limit\", ApexCollections.bindMap(\"limit\", 10, \"key\", key))") != null);
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
        "ApexStrings.join(new ArrayList<String>(ApexCollections.listOf(\"A\", \"B\")), \",\")",
        join_call,
    );

    const escape_call = try convertApexExpressionToJava(gpa, "String.escapeSingleQuotes(lastName)");
    defer gpa.free(escape_call);
    try std.testing.expectEqualStrings("ApexStrings.escapeSingleQuotes(lastName)", escape_call);

    const valueof_fix = try convertApexExpressionToJava(gpa, "Integer.valueof(x)");
    defer gpa.free(valueof_fix);
    try std.testing.expectEqualStrings("Integer.valueOf(x)", valueof_fix);

    const valueof_numeric = try convertApexExpressionToJava(
        gpa,
        "Integer.valueof((Math.random() * 100000))",
    );
    defer gpa.free(valueof_numeric);
    try std.testing.expectEqualStrings(
        "Integer.valueOf((int) ((Math.random() * 100000)))",
        valueof_numeric,
    );

    const call_index = try convertApexExpressionToJava(gpa, "createAccounts(1)[0].Id");
    defer gpa.free(call_index);
    try std.testing.expectEqualStrings(
        "createAccounts(1).get(0).getAs(\"Id\")",
        call_index,
    );

    const nested_index = try convertApexExpressionToJava(
        gpa,
        "alloWrapper.oppsAllocations.get(oppIds[7])[0]",
    );
    defer gpa.free(nested_index);
    try std.testing.expectEqualStrings(
        "alloWrapper.oppsAllocations.get(oppIds.get(7)).get(0)",
        nested_index,
    );

    const null_coalescing = try convertApexExpressionToJava(gpa, "maxPrice ?? DEFAULT_MAX_PRICE");
    defer gpa.free(null_coalescing);
    try std.testing.expectEqualStrings(
        "((maxPrice) != null ? (maxPrice) : (DEFAULT_MAX_PRICE))",
        null_coalescing,
    );

    const cast_and_class_literal = try convertApexExpressionToJava(
        gpa,
        "(List<Broker__c>) JSON.deserialize(payload, List<Broker__c>.class)",
    );
    defer gpa.free(cast_and_class_literal);
    try std.testing.expectEqualStrings(
        "(List<ApexSObject>) JSON.deserializeList(payload, ApexSObject.class)",
        cast_and_class_literal,
    );

    const typed_list_deserialize = try convertApexExpressionToJava(
        gpa,
        "(List<Coordinates>) JSON.deserialize(payload, List<Coordinates>.class)",
    );
    defer gpa.free(typed_list_deserialize);
    try std.testing.expectEqualStrings(
        "(List<Coordinates>) JSON.deserializeList(payload, Coordinates.class)",
        typed_list_deserialize,
    );

    const sosl = try convertApexExpressionToJava(
        gpa,
        "[ FIND :keyword IN ALL FIELDS RETURNING Account(Name), Contact(LastName, Account.Name) ]",
    );
    defer gpa.free(sosl);
    try std.testing.expectEqualStrings(
        "Database.searchWithBinds(\"FIND :keyword IN ALL FIELDS RETURNING Account(Name), Contact(LastName, Account.Name)\", ApexCollections.bindMap(\"keyword\", keyword))",
        sosl,
    );

    const system_today = try convertApexExpressionToJava(gpa, "System.today() - 7");
    defer gpa.free(system_today);
    try std.testing.expectEqualStrings(
        "apexemu.runtime.System.today().addDays(-(7))",
        system_today,
    );

    const inline_system_assert = try convertApexExpressionToJava(
        gpa,
        "if(UserInfo.isMultiCurrencyOrganization()) system.assert(fieldSet.contains(\"CurrencyIsoCode\"))",
    );
    defer gpa.free(inline_system_assert);
    try std.testing.expectEqualStrings(
        "if(UserInfo.isMultiCurrencyOrganization()) SystemAssert.assertTrue(fieldSet.contains(\"CurrencyIsoCode\"))",
        inline_system_assert,
    );

    const system_type_ref = try convertApexExpressionToJava(gpa, "System.Type.forName('Account')");
    defer gpa.free(system_type_ref);
    try std.testing.expectEqualStrings(
        "apexemu.runtime.System.Type.forName(\"Account\")",
        system_type_ref,
    );

    const fully_qualified_today = try convertApexExpressionToJava(gpa, "apexemu.runtime.System.today()");
    defer gpa.free(fully_qualified_today);
    try std.testing.expectEqualStrings(
        "apexemu.runtime.System.today()",
        fully_qualified_today,
    );

    const safe_nav = try convertApexExpressionToJava(gpa, "error?.getMessage()");
    defer gpa.free(safe_nav);
    try std.testing.expectEqualStrings(
        "((error) == null ? null : (error).getMessage())",
        safe_nav,
    );

    const safe_nav_with_getas = try convertApexExpressionToJava(gpa, "acct.ShippingState?.length()");
    defer gpa.free(safe_nav_with_getas);
    try std.testing.expectEqualStrings(
        "((acct.getAs(\"ShippingState\")) == null ? null : (ApexStrings.length(acct.getAs(\"ShippingState\"))))",
        safe_nav_with_getas,
    );

    const strict_equality = try convertApexExpressionToJava(gpa, "current === expected");
    defer gpa.free(strict_equality);
    try std.testing.expectEqualStrings(
        "current == expected",
        strict_equality,
    );

    const trigger_context = try convertApexExpressionToJava(gpa, "Trigger.newMap.get(id)");
    defer gpa.free(trigger_context);
    try std.testing.expectEqualStrings(
        "Trigger.getNewMap().get(id)",
        trigger_context,
    );

    const type_like_chain = try convertApexExpressionToJava(gpa, "Messaging.inboundEmail.BinaryAttachment");
    defer gpa.free(type_like_chain);
    try std.testing.expectEqualStrings(
        "Messaging.InboundEmail.BinaryAttachment",
        type_like_chain,
    );

    const inbound_email_result = try convertApexExpressionToJava(gpa, "new Messaging.InboundEmailresult()");
    defer gpa.free(inbound_email_result);
    try std.testing.expectEqualStrings(
        "new Messaging.InboundEmailResult()",
        inbound_email_result,
    );

    const type_sobject_constant = try convertApexExpressionToJava(gpa, "Schema.Account.SObjectType");
    defer gpa.free(type_sobject_constant);
    try std.testing.expectEqualStrings(
        "new Schema.SObjectType(\"Account\")",
        type_sobject_constant,
    );

    const type_get_sobject = try convertApexExpressionToJava(gpa, "Account.getSObjectType()");
    defer gpa.free(type_get_sobject);
    try std.testing.expectEqualStrings(
        "new Schema.SObjectType(\"Account\")",
        type_get_sobject,
    );

    const non_sobject_get_sobject = try convertApexExpressionToJava(gpa, "MetadataTriggerService.getSobjectType()");
    defer gpa.free(non_sobject_get_sobject);
    try std.testing.expectEqualStrings(
        "MetadataTriggerService.getSObjectType()",
        non_sobject_get_sobject,
    );

    const instance_get_sobject = try convertApexExpressionToJava(gpa, "sObj.getSObjectType()");
    defer gpa.free(instance_get_sobject);
    try std.testing.expectEqualStrings(
        "ApexSwitch.getSObjectType(sObj)",
        instance_get_sobject,
    );

    const schema_type_namespace_chain = try convertApexExpressionToJava(gpa, "Schema.SObjectType.Account.fields.Name");
    defer gpa.free(schema_type_namespace_chain);
    try std.testing.expectEqualStrings(
        "Schema.SObjectType.Account.fields.getAs(\"Name\")",
        schema_type_namespace_chain,
    );

    const trigger_operation_case = try convertApexExpressionToJava(gpa, "System.TriggerOperation.After_UPDATE");
    defer gpa.free(trigger_operation_case);
    try std.testing.expectEqualStrings(
        "System.TriggerOperation.AFTER_UPDATE",
        trigger_operation_case,
    );

    const trigger_operation_bare_case = try convertApexExpressionToJava(gpa, "TriggerOperation.After_UPDATE");
    defer gpa.free(trigger_operation_bare_case);
    try std.testing.expectEqualStrings(
        "System.TriggerOperation.AFTER_UPDATE",
        trigger_operation_bare_case,
    );

    const contains_ignore_case = try convertApexExpressionToJava(gpa, "message.containsIgnoreCase('error')");
    defer gpa.free(contains_ignore_case);
    try std.testing.expectEqualStrings(
        "ApexStrings.containsIgnoreCase(message, \"error\")",
        contains_ignore_case,
    );

    const bind_static_getter = try convertApexExpressionToJava(
        gpa,
        "[SELECT Id FROM User WHERE Username = :UserInfo.getUsername()]",
    );
    defer gpa.free(bind_static_getter);
    try std.testing.expectEqualStrings(
        "Database.queryWithBinds(\"SELECT Id FROM User WHERE Username = :UserInfo.getUsername()\", ApexCollections.bindMap(\"UserInfo.getUsername\", UserInfo.getUsername()))",
        bind_static_getter,
    );
}

test "convertApexExpressionToJava preserves cast target before chained call" {
    const gpa = std.testing.allocator;
    const cast_input = "((List<Object>) responseMap.get(\"Contacts\")).size()";

    const cast_only = try rewriteApexTypeCasts(gpa, cast_input);
    defer gpa.free(cast_only);
    try std.testing.expectEqualStrings(
        cast_input,
        cast_only,
    );

    const converted = try convertApexExpressionToJava(
        gpa,
        "((List<Object>) responseMap.get('Contacts')).size()",
    );
    defer gpa.free(converted);
    try std.testing.expectEqualStrings(
        "((List<Object>) responseMap.get(\"Contacts\")).size()",
        converted,
    );
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

test "transpileAbstractMethodDeclarationLine converts abstract signatures" {
    const gpa = std.testing.allocator;
    const converted =
        (try transpileAbstractMethodDeclarationLine(gpa, "protected abstract void verify(fflib_QualifiedMethod qm, fflib_MethodArgValues methodArg);", "Demo")).?;
    defer gpa.free(converted);
    try std.testing.expectEqualStrings(
        "protected abstract void verify(fflib_QualifiedMethod qm, fflib_MethodArgValues methodArg);",
        converted,
    );
}

test "transpileClassMemberLine converts fields and properties" {
    const gpa = std.testing.allocator;

    const field_line = try transpileClassMemberLine(gpa, "private static final List<Account> cache = new List<Account>();", false);
    defer if (field_line) |value| gpa.free(value);
    try std.testing.expect(field_line != null);
    try std.testing.expectEqualStrings(
        "private static final List<ApexSObject> cache = new ArrayList<ApexSObject>();",
        field_line.?,
    );

    const lowercase_type_field = try transpileClassMemberLine(gpa, "private final fflib_MethodCountRecorder methodCountRecorder;", false);
    defer if (lowercase_type_field) |value| gpa.free(value);
    try std.testing.expect(lowercase_type_field != null);
    try std.testing.expectEqualStrings(
        "private final fflib_MethodCountRecorder methodCountRecorder;",
        lowercase_type_field.?,
    );

    const property_line = try transpileClassMemberLine(gpa, "public String Name { get; set; }", false);
    defer if (property_line) |value| gpa.free(value);
    try std.testing.expect(property_line != null);
    try std.testing.expectEqualStrings(
        "public String Name; // Apex property { get; set; }",
        property_line.?,
    );

    const array_property = try transpileClassMemberLine(gpa, "public Property__c[] records { get; set; }", false);
    defer if (array_property) |value| gpa.free(value);
    try std.testing.expect(array_property != null);
    try std.testing.expectEqualStrings(
        "public List<ApexSObject> records; // Apex property { get; set; }",
        array_property.?,
    );

    const static_block = try transpileClassMemberLine(
        gpa,
        "static { loopCountMap = new Map<String, LoopCount>(); bypassedHandlers = new Set<String>(); }",
        false,
    );
    defer if (static_block) |value| gpa.free(value);
    try std.testing.expect(static_block != null);
    try std.testing.expectEqualStrings(
        "static {\n    loopCountMap = new LinkedHashMap<String, LoopCount>();\n    bypassedHandlers = new LinkedHashSet<String>();\n  }",
        static_block.?,
    );

    const object_array_property = try transpileClassMemberLine(gpa, "public Object[] rows { get; set; }", false);
    defer if (object_array_property) |value| gpa.free(value);
    try std.testing.expect(object_array_property != null);
    try std.testing.expectEqualStrings(
        "public List<ApexSObject> rows; // Apex property { get; set; }",
        object_array_property.?,
    );

    const test_visible_field = try transpileClassMemberLine(
        gpa,
        "@TestVisible private static final String invalid = 'The {0} class is invalid.';",
        false,
    );
    defer if (test_visible_field) |value| gpa.free(value);
    try std.testing.expect(test_visible_field != null);
    try std.testing.expectEqualStrings(
        "public static final String invalid = \"The {0} class is invalid.\";",
        test_visible_field.?,
    );

    const exception_inner =
        try transpileClassMemberLine(gpa, "public class AccountUpdateException extends Exception {", false);
    defer if (exception_inner) |value| gpa.free(value);
    try std.testing.expect(exception_inner != null);
    try std.testing.expectEqualStrings(
        "public static class AccountUpdateException extends apexemu.runtime.System.Exception { public AccountUpdateException() { super(); } public AccountUpdateException(String message) { super(message); } }",
        exception_inner.?,
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

    const static_property_assign = try transpileGenericStatementLine(gpa, "fflib_ApexMocksConfig.HasIndependentMocks = true;");
    defer if (static_property_assign) |value| gpa.free(value);
    try std.testing.expect(static_property_assign != null);
    try std.testing.expectEqualStrings(
        "fflib_ApexMocksConfig.HasIndependentMocks = true;",
        static_property_assign.?,
    );

    const this_assign = try transpileGenericStatementLine(gpa, "this.Name = name;");
    defer if (this_assign) |value| gpa.free(value);
    try std.testing.expect(this_assign != null);
    try std.testing.expectEqualStrings("this.Name = name;", this_assign.?);

    const camel_assign = try transpileGenericStatementLine(gpa, "link.shareType = 'V';");
    defer if (camel_assign) |value| gpa.free(value);
    try std.testing.expect(camel_assign != null);
    try std.testing.expectEqualStrings("link.set(\"shareType\", \"V\");", camel_assign.?);

    const query_single_assign = try transpileGenericStatementLine(
        gpa,
        "contentVersion = Database.query('SELECT Id FROM ContentVersion WHERE Id = :recordId');",
    );
    defer if (query_single_assign) |value| gpa.free(value);
    try std.testing.expect(query_single_assign != null);
    try std.testing.expectEqualStrings(
        "contentVersion = ApexCollections.firstOrNull(Database.queryWithBinds(\"SELECT Id FROM ContentVersion WHERE Id = :recordId\", ApexCollections.bindMap(\"recordId\", recordId)));",
        query_single_assign.?,
    );

    const query_plural_assign = try transpileGenericStatementLine(
        gpa,
        "records = Database.query('SELECT Id FROM Account');",
    );
    defer if (query_plural_assign) |value| gpa.free(value);
    try std.testing.expect(query_plural_assign != null);
    try std.testing.expectEqualStrings(
        "records = Database.query(\"SELECT Id FROM Account\");",
        query_plural_assign.?,
    );

    const multi_decl = try transpileGenericStatementLine(
        gpa,
        "String[] categories, materials, levels, criteria = new List<String>{};",
    );
    defer if (multi_decl) |value| gpa.free(value);
    try std.testing.expect(multi_decl != null);
    try std.testing.expectEqualStrings(
        "List<String> categories, materials, levels, criteria = new ArrayList<String>();",
        multi_decl.?,
    );

    const member_price_assign =
        try transpileGenericStatementLine(gpa, "filters.maxPrice = 2000;");
    defer if (member_price_assign) |value| gpa.free(value);
    try std.testing.expect(member_price_assign != null);
    try std.testing.expectEqualStrings("filters.maxPrice = 2000.0;", member_price_assign.?);

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

    const safe_nav_call = try transpileGenericStatementLine(
        gpa,
        "instanceToFinalize?.finalizeDmlOperation();",
    );
    defer if (safe_nav_call) |value| gpa.free(value);
    try std.testing.expect(safe_nav_call != null);
    try std.testing.expectEqualStrings(
        "if ((instanceToFinalize) != null) { instanceToFinalize.finalizeDmlOperation(); }",
        safe_nav_call.?,
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

    const update_user = try transpileDmlLine(gpa, "update as user acc;");
    defer if (update_user) |value| gpa.free(value);
    try std.testing.expect(update_user != null);
    try std.testing.expectEqualStrings(
        "Database.update(acc); // Apex DML mode: user",
        update_user.?,
    );
}

test "convertApexExpressionToJava converts collection literals and sobject constructor args" {
    const gpa = std.testing.allocator;

    const list_literal = try convertApexExpressionToJava(gpa, "new List<Id>{'a', 'b'}");
    defer gpa.free(list_literal);
    try std.testing.expectEqualStrings(
        "new ArrayList<String>(ApexCollections.listOf(\"a\", \"b\"))",
        list_literal,
    );

    const map_literal = try convertApexExpressionToJava(gpa, "new Map<Id, Account>{'001' => record}");
    defer gpa.free(map_literal);
    try std.testing.expectEqualStrings(
        "new LinkedHashMap<String, ApexSObject>(ApexCollections.mapOfEntries(ApexCollections.mapEntry(\"001\", record)))",
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
        "new ArrayList<ApexSObject>(ApexCollections.listOf(ApexSObject.of(\"Task\").set(\"WhatId\", records.get(0).getAs(\"Id\"))))",
        nested_literal,
    );

    const escaped_apex_string = try convertApexExpressionToJava(
        gpa,
        "'Couldn\\'t update account with ID ' + accountId",
    );
    defer gpa.free(escaped_apex_string);
    try std.testing.expectEqualStrings(
        "\"Couldn't update account with ID \" + accountId",
        escaped_apex_string,
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
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), statements.items.len);
    const converted = try transpileExecutableLine(gpa, statements.items[0].text);
    defer if (converted) |value| gpa.free(value);
    try std.testing.expect(converted != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.mapById(Database.query(\"SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10\"));",
        converted.?,
    );
}

test "collectLogicalStatements keeps multiline assignment with string concatenation" {
    const gpa = std.testing.allocator;
    const body =
        \\String queryString =
        \\  'SELECT Id, Name ' +
        \\  'FROM Account ' +
        \\  'WHERE Name LIKE \'Acme%\'';
    ;
    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), statements.items.len);
    try std.testing.expect(std.mem.indexOf(u8, statements.items[0].text, "String queryString =") != null);
    try std.testing.expect(std.mem.indexOf(u8, statements.items[0].text, "'FROM Account '") != null);
}

test "collectLogicalStatements strips block and line comments" {
    const gpa = std.testing.allocator;
    const body =
        \\// leading comment
        \\String a = 'x'; // trailing comment
        \\/* block
        \\ * comment
        \\ */
        \\String b = "http://example.invalid";
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expectEqualStrings("String a = 'x';", statements.items[0].text);
    try std.testing.expectEqualStrings("String b = \"http://example.invalid\";", statements.items[1].text);
}

test "collectLogicalStatements splits leading brace from else/catch lines" {
    const gpa = std.testing.allocator;
    const body =
        \\if (ok) {
        \\  doWork();
        \\} else { return; }
        \\try {
        \\  risky();
        \\} catch (Exception e) { handle(e); }
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 12), statements.items.len);
    try std.testing.expectEqualStrings("if (ok) {", statements.items[0].text);
    try std.testing.expectEqualStrings("doWork();", statements.items[1].text);
    try std.testing.expectEqualStrings("}", statements.items[2].text);
    try std.testing.expectEqualStrings("else {", statements.items[3].text);
    try std.testing.expectEqualStrings("return;", statements.items[4].text);
    try std.testing.expectEqualStrings("}", statements.items[5].text);
    try std.testing.expectEqualStrings("try {", statements.items[6].text);
    try std.testing.expectEqualStrings("risky();", statements.items[7].text);
    try std.testing.expectEqualStrings("}", statements.items[8].text);
    try std.testing.expectEqualStrings("catch (Exception e) {", statements.items[9].text);
    try std.testing.expectEqualStrings("handle(e);", statements.items[10].text);
    try std.testing.expectEqualStrings("}", statements.items[11].text);
}

test "collectLogicalStatements splits compact one-line runAs try/catch blocks" {
    const gpa = std.testing.allocator;
    const body =
        \\System.runAs(u1) { Test.startTest(); try { run(); } catch (Exception e) { handle(e); } Test.stopTest(); }
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 10), statements.items.len);
    try std.testing.expectEqualStrings("System.runAs(u1) {", statements.items[0].text);
    try std.testing.expectEqualStrings("Test.startTest();", statements.items[1].text);
    try std.testing.expectEqualStrings("try {", statements.items[2].text);
    try std.testing.expectEqualStrings("run();", statements.items[3].text);
    try std.testing.expectEqualStrings("}", statements.items[4].text);
    try std.testing.expectEqualStrings("catch (Exception e) {", statements.items[5].text);
    try std.testing.expectEqualStrings("handle(e);", statements.items[6].text);
    try std.testing.expectEqualStrings("}", statements.items[7].text);
    try std.testing.expectEqualStrings("Test.stopTest();", statements.items[8].text);
    try std.testing.expectEqualStrings("}", statements.items[9].text);
}

test "collectLogicalStatements handles escaped apostrophe in compact string literals" {
    const gpa = std.testing.allocator;
    const body =
        \\System.assert(true, 'doesn\'t fail'); System.debug('ok');
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expectEqualStrings(
        "System.assert(true, 'doesn\\'t fail');",
        statements.items[0].text,
    );
    try std.testing.expectEqualStrings("System.debug('ok');", statements.items[1].text);
}

test "collectLogicalStatements keeps do-while tail together" {
    const gpa = std.testing.allocator;
    const body =
        \\do {
        \\  i++;
        \\} while (i < 3);
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 3), statements.items.len);
    try std.testing.expectEqualStrings("do {", statements.items[0].text);
    try std.testing.expectEqualStrings("i++;", statements.items[1].text);
    try std.testing.expectEqualStrings("} while (i < 3);", statements.items[2].text);
}

test "startsWithWordIgnoreCase accepts punctuation boundaries" {
    try std.testing.expect(startsWithWordIgnoreCase("else{", "else"));
    try std.testing.expect(startsWithWordIgnoreCase("try{", "try"));
    try std.testing.expect(!startsWithWordIgnoreCase("elseif", "else"));
}

test "transpileControlFlowLine converts System.runAs scoped block header" {
    const gpa = std.testing.allocator;
    const converted = try transpileControlFlowLine(gpa, "System.runAs(testUser) {");
    defer if (converted) |value| gpa.free(value);

    try std.testing.expect(converted != null);
    try std.testing.expectEqualStrings(
        "Test.beginRunAs(testUser); try { // RUNAS_BLOCK",
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
    var summary = try run(std.testing.allocator, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
        .strict = false,
    });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
    try std.testing.expect(summary.unsupported_statements > 0);
    try std.testing.expect(summary.unsupported_examples.items.len > 0);
    try std.testing.expect(summary.unsupported_examples.items[0].line_no > 0);
    try std.testing.expect(summary.unsupported_examples.items[0].reason.len > 0);
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

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "if (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "    }\n  }\n") != null);
}

test "renderJavaClass emits inner enum and interface declarations" {
    const gpa = std.testing.allocator;

    const source =
        \\public class Demo {
        \\  public enum HttpVerb {
        \\    GET,
        \\    POST,
        \\    PATCH;
        \\  }
        \\  public interface Worker {
        \\    void run();
        \\  }
        \\  public static void use() {
        \\    HttpVerb verb = HttpVerb.GET;
        \\  }
        \\}
    ;
    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static enum HttpVerb { GET, POST, PATCH }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static interface Worker {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public void run();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "HttpVerb verb = HttpVerb.GET;") != null);
}

test "renderJavaClass emits inner class with field-only body" {
    const gpa = std.testing.allocator;

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "private static class Inner") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public Boolean enabled = true;") != null);
}

test "run transpiles file with field-only inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{root};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "run transpiles direct file input with field-only inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Direct.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Direct.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "run transpiles package-private top-level class with inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Demo.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "rewriteKnownCompatibilityFixups preserves unit of work registration state" {
    const gpa = std.testing.allocator;
    const input =
        \\private List<String> m_commitWorkEventsFired = new ArrayList<String>();
        \\private Set<Schema.SObjectType> m_registeredTypes = new LinkedHashSet<Schema.SObjectType>();
        \\if (m_registeredTypes.contains(sObjectType)) {
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "private List<String> m_commitWorkEventsFired;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "private Set<Schema.SObjectType> m_registeredTypes;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (m_registeredTypes == null) m_registeredTypes = new LinkedHashSet<Schema.SObjectType>();") != null);
}

test "rewriteKnownCompatibilityFixups rewrites custom schema and page namespace access" {
    const gpa = std.testing.allocator;
    const input =
        \\String settingsName = Schema.SObjectType.Addr_Verification_Settings__c.getLabel();
        \\PageReference pageRef = Page.STG_PanelAddrVerification;
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"Addr_Verification_Settings__c\").getLabel()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new PageReference(\"/apex/STG_PanelAddrVerification\")") != null);
}

test "rewriteKnownCompatibilityFixups rewrites getAs boolean inequality and record type map declarations" {
    const gpa = std.testing.allocator;
    const input =
        \\Map<String, ApexSObject> recordTypes = objectType.getDescribe().getRecordTypeInfosById();
        \\if (contactRecord.getAs("npe01__Private__c") != true) {
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Map<String, apexemu.runtime.RecordTypeInfo> recordTypes = objectType.getDescribe().getRecordTypeInfosById();") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "!Boolean.TRUE.equals(contactRecord.getAs(\"npe01__Private__c\"))") != null);
}

test "rewriteKnownCompatibilityFixups rewrites type path getAs and keySet property access" {
    const gpa = std.testing.allocator;
    const input =
        \\TDTM_ProcessControl.setRecursionFlag(TDTM_ProcessControl.flag.getAs("ADDR_hasRunValidation"), true);
        \\if (STG_Panel.stgService.stgErr.getAs("DisableRecordDataHealthChecks__c") == true) {}
        \\List<ApexSObject> jobs = Database.queryWithBinds("SELECT Id FROM CronTrigger WHERE CronJobDetail.Name IN :UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet", ApexCollections.bindMap("UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet", UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet));
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "TDTM_ProcessControl.flag.ADDR_hasRunValidation") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "STG_Panel.stgService.stgErr.getAs(\"DisableRecordDataHealthChecks__c\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet()") != null);
}

test "rewriteKnownCompatibilityFixups rewrites report fallbacks and datetime double deltas" {
    const gpa = std.testing.allocator;
    const input =
        \\Double msec = dtEnd.getTime() - dtStart.getTime();
        \\List<Report> listRpt = Database.query("SELECT Id FROM Report");
        \\Report r = new Report();
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Double msec = Double.valueOf(dtEnd.getTime() - dtStart.getTime());") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "List<ApexSObject> listRpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSObject r = ApexSObject.of(\"Report\");") != null);
}

test "convertApexExpressionToJava rewrites nested id relational comparisons" {
    const gpa = std.testing.allocator;
    const input = "(currentEndId == null || lastIdInScope > currentEndId) ? lastIdInScope : currentEndId";

    const rewritten = try convertApexExpressionToJava(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.compareTo(lastIdInScope, currentEndId) > 0") != null);
}

test "convertApexExpressionToJava keeps numeric guards out of string relational rewrites" {
    const gpa = std.testing.allocator;
    const input = "ich < strNameSpec.length()-1 && strNameSpec.substring(ich+1, ich+2) != \" \"";

    const rewritten = try convertApexExpressionToJava(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.compareTo(ich,") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ich < strNameSpec.length()-1") != null);
}

test "rewriteNumericValueOfObjectIdentifiers rewrites object valueOf calls" {
    const gpa = std.testing.allocator;
    const input =
        \\public void run() {
        \\  Object fieldValue = record.get(field);
        \\  result.add(Integer.valueOf(fieldValue));
        \\}
    ;

    const rewritten = try rewriteNumericValueOfObjectIdentifiers(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.toInteger(fieldValue)") != null);
}

test "rewriteObjectEqualityWithDeclaredObjects rewrites object numeric equality" {
    const gpa = std.testing.allocator;
    const input =
        \\public void run() {
        \\  Object currentValue = record.get('Count__c');
        \\  if (currentValue != null && currentValue != 0) {
        \\    return currentValue != members.size();
        \\  }
        \\}
    ;

    const rewritten = try rewriteObjectEqualityWithDeclaredObjects(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexEquals.ne(currentValue, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return ApexEquals.ne(currentValue, members.size());") != null);
}

test "renderJavaClass preserves abstract inner class modifier" {
    const gpa = std.testing.allocator;
    const source =
        \\public class Demo {
        \\  private abstract class InnerBase {
        \\    protected abstract String render();
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "private static abstract class InnerBase") != null);
}

test "run promotes multiline test visible inner type visibility" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  @TestVisible
        \\  private without sharing class Inner {
        \\    public void ping() {
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Demo.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);
    const output_path = try std.fs.path.join(gpa, &.{ out_dir, "Demo.java" });
    defer gpa.free(output_path);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    const output = try std.fs.cwd().readFileAlloc(gpa, output_path, 1024 * 1024);
    defer gpa.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "public static class Inner") != null);
}

test "parseTriggerRegistration extracts fflib trigger manifest entry" {
    const gpa = std.testing.allocator;
    const source =
        \\trigger Opportunities on Opportunity (
        \\  after delete, after insert, after update, before delete, before insert, before update
        \\) {
        \\  fflib_SObjectDomain.triggerHandler(OpportunitiesTriggerHandler.class);
        \\}
    ;

    var registration = (try parseTriggerRegistration(gpa, "Opportunities.trigger", source)).?;
    defer registration.deinit(gpa);

    try std.testing.expectEqualStrings("Opportunities.trigger", registration.source_path);
    try std.testing.expectEqualStrings("Opportunity", registration.sobject_type);
    try std.testing.expectEqualStrings("OpportunitiesTriggerHandler", registration.handler_class);
    try std.testing.expectEqual(@as(usize, 6), registration.events.items.len);
    try std.testing.expectEqual(TriggerEvent.after_delete, registration.events.items[0]);
    try std.testing.expectEqual(TriggerEvent.before_update, registration.events.items[5]);
}
