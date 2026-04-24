//! tools/rename_identifiers.zig — AST-safe identifier renamer.
//!
//! Usage:
//!   zig run tools/rename_identifiers.zig -- <map-file> <file1> [file2 ...]
//!
//! `<map-file>` must contain one `old_name<TAB>new_name` entry per line.
//! Lines that are empty or start with `#` are ignored.
//!
//! For each `.zig` file on the command line we tokenize with
//! `std.zig.Tokenizer` and replace only tokens whose tag is
//! `.identifier` AND whose text exactly matches an entry in the map.
//! Everything else — string literals, multiline string literals,
//! comments, keywords, whitespace — is preserved verbatim.
//!
//! Why this matters: the PR #90 snake_case drain used a textual regex
//! and accidentally rewrote Apex method-name string literals like
//! "getFields" → "get_fields", regressing 678 NebulaLogger tests. A
//! tokenizer-based renamer makes that class of bug structurally
//! impossible: tokens with tag `.string_literal` or
//! `.multiline_string_literal_line` are never even considered for
//! replacement.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;

const RenameMap = std.StringHashMap([]const u8);

fn parse_map(gpa: mem.Allocator, io: Io, path: []const u8) !RenameMap {
    var map = RenameMap.init(gpa);
    errdefer map.deinit();

    const bytes = try Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(bytes);

    var it = mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const tab = mem.indexOfScalar(u8, line, '\t') orelse continue;
        const old = mem.trim(u8, line[0..tab], " \t");
        const new = mem.trim(u8, line[tab + 1 ..], " \t");
        if (old.len == 0 or new.len == 0) continue;
        if (mem.eql(u8, old, new)) continue;
        // dupe into gpa because `bytes` will be freed.
        const old_dup = try gpa.dupe(u8, old);
        const new_dup = try gpa.dupe(u8, new);
        const gop = try map.getOrPut(old_dup);
        if (gop.found_existing) {
            // later entries win (but also free the loser's `old` dup)
            gpa.free(old_dup);
            gpa.free(@constCast(gop.value_ptr.*));
        }
        gop.value_ptr.* = new_dup;
    }
    return map;
}

fn rename_file(gpa: mem.Allocator, io: Io, path: []const u8, map: *const RenameMap) !usize {
    const bytes = Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch |e| {
        std.debug.print("skip {s}: read failed ({s})\n", .{ path, @errorName(e) });
        return 0;
    };
    defer gpa.free(bytes);

    const src_z = try gpa.dupeZ(u8, bytes);
    defer gpa.free(src_z);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);

    var tokenizer = std.zig.Tokenizer.init(src_z);
    var cursor: usize = 0;
    var replaced: usize = 0;
    while (true) {
        const tok = tokenizer.next();
        // Anything between the previous end-of-token and this token's
        // start is whitespace / comments. Preserve verbatim.
        if (tok.loc.start > cursor) {
            try out.appendSlice(gpa, src_z[cursor..tok.loc.start]);
        }

        if (tok.tag == .eof) {
            cursor = tok.loc.end;
            break;
        }

        const text = src_z[tok.loc.start..tok.loc.end];
        if (tok.tag == .identifier) {
            if (map.get(text)) |replacement| {
                try out.appendSlice(gpa, replacement);
                replaced += 1;
            } else {
                try out.appendSlice(gpa, text);
            }
        } else {
            // string_literal, multiline_string_literal_line, keywords,
            // builtins, punctuation — all copied verbatim.
            try out.appendSlice(gpa, text);
        }
        cursor = tok.loc.end;
    }

    // Any trailing bytes after the final EOF token (shouldn't really
    // happen, but be paranoid).
    if (cursor < bytes.len) {
        try out.appendSlice(gpa, src_z[cursor..bytes.len]);
    }

    if (replaced == 0) return 0;

    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    return replaced;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const arena = init.arena.allocator();
    const argv_raw = init.minimal.args.toSlice(arena) catch std.process.exit(2);
    if (argv_raw.len < 3) {
        std.debug.print(
            \\Usage: rename_identifiers <map-file> <file1.zig> [file2.zig ...]
            \\  <map-file> lines: old_name<TAB>new_name
            \\
        , .{});
        std.process.exit(2);
    }

    const map_path = argv_raw[1];
    var map = try parse_map(gpa, io, map_path);
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(@constCast(e.value_ptr.*));
        }
        map.deinit();
    }

    var total_files: usize = 0;
    var total_replacements: usize = 0;
    for (argv_raw[2..]) |path_z| {
        // `path_z` is [:0]const u8 but coerces to []const u8 directly.
        const path: []const u8 = path_z;
        if (!mem.endsWith(u8, path, ".zig")) continue;
        const n = try rename_file(gpa, io, path, &map);
        if (n > 0) {
            std.debug.print("{s}: {d} replacement(s)\n", .{ path, n });
            total_files += 1;
            total_replacements += n;
        }
    }
    std.debug.print(
        "done: {d} replacement(s) across {d} file(s)\n",
        .{ total_replacements, total_files },
    );
}
