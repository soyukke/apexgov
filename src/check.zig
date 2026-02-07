const std = @import("std");
const model = @import("model.zig");

pub fn run(gpa: std.mem.Allocator, roots: []const []const u8) !std.ArrayList(model.Finding) {
    var findings: std.ArrayList(model.Finding) = .empty;
    errdefer model.deinitFindings(gpa, &findings);

    for (roots) |root| {
        try scanPath(gpa, root, &findings);
    }

    return findings;
}

fn scanPath(gpa: std.mem.Allocator, path: []const u8, findings: *std.ArrayList(model.Finding)) !void {
    scanDirectory(gpa, path, findings) catch |err| switch (err) {
        error.NotDir => {
            if (isApexSource(path)) {
                try scanFile(gpa, path, findings);
            }
        },
        else => return err,
    };
}

fn scanDirectory(gpa: std.mem.Allocator, root: []const u8, findings: *std.ArrayList(model.Finding)) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isApexSource(entry.path)) continue;

        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        defer gpa.free(joined);

        try scanFile(gpa, joined, findings);
    }
}

fn scanFile(gpa: std.mem.Allocator, path: []const u8, findings: *std.ArrayList(model.Finding)) !void {
    const content = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    defer gpa.free(content);

    var loop_scopes: std.ArrayList(i32) = .empty;
    defer loop_scopes.deinit(gpa);

    var brace_depth: i32 = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw| {
        line_no += 1;

        popClosedScopes(&loop_scopes, brace_depth);

        const code_line = stripLineComment(raw);
        const trimmed = std.mem.trim(u8, code_line, " \t\r");
        if (trimmed.len == 0) {
            brace_depth = updateBraceDepth(brace_depth, code_line);
            popClosedScopes(&loop_scopes, brace_depth);
            continue;
        }

        const loop_started = isLoopStart(trimmed);
        const loop_level = loop_scopes.items.len;
        const in_loop = loop_started or loop_level > 0;

        if (loop_started and loop_level > 0) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG001",
                "Nested loop can burn CPU quickly",
                "Nested loops often amplify CPU usage and governor risk.",
                .warning,
                "cpu",
            );
        }

        if (in_loop and containsSoql(trimmed)) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG002",
                "SOQL executed inside loop",
                "Move query outside the loop and batch by IDs.",
                .err,
                "governor",
            );
        }

        if (in_loop and containsDml(trimmed)) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG003",
                "DML executed inside loop",
                "Accumulate records and issue one bulk DML statement.",
                .err,
                "governor",
            );
        }

        if (in_loop and containsJsonWork(trimmed)) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG004",
                "JSON processing inside loop",
                "Serialize/deserialize outside loops where possible.",
                .warning,
                "cpu",
            );
        }

        if (in_loop and containsCloneWork(trimmed)) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG005",
                "Clone/deepClone inside loop",
                "Repeated cloning can increase heap and CPU cost.",
                .warning,
                "heap",
            );
        }

        if (in_loop and containsCollectionAlloc(trimmed)) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG006",
                "Collection allocation inside loop",
                "Reuse collections or move allocation outside the loop.",
                .warning,
                "heap",
            );
        }

        if (in_loop and containsStringAppend(trimmed)) {
            try appendFinding(
                gpa,
                findings,
                path,
                line_no,
                "AG007",
                "String concatenation inside loop",
                "Prefer StringBuilder-style batching patterns to reduce CPU.",
                .info,
                "cpu",
            );
        }

        if (loop_started and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            try loop_scopes.append(gpa, brace_depth + 1);
        }

        brace_depth = updateBraceDepth(brace_depth, code_line);
        popClosedScopes(&loop_scopes, brace_depth);
    }
}

fn appendFinding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(model.Finding),
    path: []const u8,
    line_no: usize,
    rule_id: []const u8,
    title: []const u8,
    message: []const u8,
    severity: model.Severity,
    category: []const u8,
) !void {
    try findings.append(gpa, .{
        .rule_id = rule_id,
        .title = title,
        .message = message,
        .severity = severity,
        .category = category,
        .file = try gpa.dupe(u8, path),
        .line = line_no,
    });
}

fn popClosedScopes(scopes: *std.ArrayList(i32), brace_depth: i32) void {
    while (scopes.items.len > 0 and scopes.items[scopes.items.len - 1] > brace_depth) {
        _ = scopes.pop();
    }
}

fn updateBraceDepth(current: i32, line: []const u8) i32 {
    var depth = current;
    depth += @intCast(countByte(line, '{'));
    depth -= @intCast(countByte(line, '}'));
    if (depth < 0) return 0;
    return depth;
}

fn countByte(buf: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (buf) |b| {
        if (b == needle) count += 1;
    }
    return count;
}

fn stripLineComment(raw: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, raw, "//") orelse return raw;
    return raw[0..idx];
}

fn isLoopStart(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "for(") != null or
        std.mem.indexOf(u8, line, "for (") != null or
        std.mem.indexOf(u8, line, "while(") != null or
        std.mem.indexOf(u8, line, "while (") != null;
}

fn containsSoql(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "[SELECT ") != null or
        std.mem.indexOf(u8, line, "[select ") != null or
        std.mem.indexOf(u8, line, "Database.query(") != null;
}

fn containsDml(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "insert ") or
        std.mem.startsWith(u8, trimmed, "update ") or
        std.mem.startsWith(u8, trimmed, "upsert ") or
        std.mem.startsWith(u8, trimmed, "delete ") or
        std.mem.indexOf(u8, line, "Database.insert(") != null or
        std.mem.indexOf(u8, line, "Database.update(") != null or
        std.mem.indexOf(u8, line, "Database.upsert(") != null or
        std.mem.indexOf(u8, line, "Database.delete(") != null;
}

fn containsJsonWork(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "JSON.serialize(") != null or
        std.mem.indexOf(u8, line, "JSON.deserialize(") != null;
}

fn containsCloneWork(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ".clone(") != null or
        std.mem.indexOf(u8, line, ".deepClone(") != null;
}

fn containsCollectionAlloc(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "new List<") != null or
        std.mem.indexOf(u8, line, "new Map<") != null or
        std.mem.indexOf(u8, line, "new Set<") != null;
}

fn containsStringAppend(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "+=") != null and
        (std.mem.indexOf(u8, line, "\"") != null or
            std.mem.indexOf(u8, line, "String") != null);
}

fn isApexSource(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".cls") or
        std.ascii.eqlIgnoreCase(ext, ".trigger") or
        std.ascii.eqlIgnoreCase(ext, ".apex");
}
