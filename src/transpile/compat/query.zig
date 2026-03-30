//! query — SOQL/SOSL クエリ式の Java 変換。
//!
//! `[SELECT ...]` インライン SOQL や SOSL を Java の
//! `Database.query()` / `Database.getQueryLocator()` 呼び出しに変換する。

const stmt_mod = @import("../statements.zig");
const std = @import("std");
const util = @import("../util.zig");

const getas = @import("getas.zig");
const helpers = @import("helpers.zig");

const CompatibilityState = helpers.CompatibilityState;
const skipNonNormal = helpers.skipNonNormal;
const appendUniqueOwnedName = helpers.appendUniqueOwnedName;
const collectSoqlBindNamesFromJavaLiteral = helpers.collectSoqlBindNamesFromJavaLiteral;
const containsIgnoreCaseNameSlice = helpers.containsIgnoreCaseNameSlice;
const countByte = helpers.countByte;
const extractParameterizedTypeVariableName = helpers.extractParameterizedTypeVariableName;
const extractTypedVariableName = helpers.extractTypedVariableName;
const isJavaStringLiteral = helpers.isJavaStringLiteral;
const isMethodLikeSignatureLine = helpers.isMethodLikeSignatureLine;
const looksLikePublicMethodSignatureLine = helpers.looksLikePublicMethodSignatureLine;

const appendFmt = util.appendFmt;
const buildDatabaseQueryCall = stmt_mod.buildDatabaseQueryCall;
const containsWordIgnoreCase = util.containsWordIgnoreCase;
const convertBindReferenceToJava = stmt_mod.convertBindReferenceToJava;
const findMatchingBrace = util.findMatchingBrace;
const findMatchingParen = util.findMatchingParen;
const findMatchingSquareBracket = util.findMatchingSquareBracket;
const isIdentifierChar = util.isIdentifierChar;
const lastIdentifier = util.lastIdentifier;
const normalizeSoqlQueryForEmulation = stmt_mod.normalizeSoqlQueryForEmulation;
const quoteJavaStringLiteral = util.quoteJavaStringLiteral;
const splitCallArguments = stmt_mod.splitCallArguments;
const splitTopLevelCommaExpressions = stmt_mod.splitTopLevelCommaExpressions;
const splitTypeArguments = stmt_mod.splitTypeArguments;
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;

pub fn rewriteQuerySingletonCallsAssignedToLists(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        const lhs = line[0..eq_pos];
        if (std.mem.indexOf(u8, lhs, "List<") == null) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const prefix_first_or_null = "ApexCollections.firstOrNull(";
        const prefix_first_or_throw = "ApexCollections.firstOrThrow(";
        const rhs = std.mem.trim(u8, line[(eq_pos + 1)..], " \t");
        const prefix = if (startsWithIgnoreCase(rhs, prefix_first_or_null))
            prefix_first_or_null
        else if (startsWithIgnoreCase(rhs, prefix_first_or_throw))
            prefix_first_or_throw
        else {
            try out.appendSlice(gpa, line);
            continue;
        };

        const open = eq_pos + 1 + std.mem.indexOf(u8, line[(eq_pos + 1)..], prefix).?;
        const call_open = open + prefix.len - 1;
        const call_close = findMatchingParen(line, call_open) orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        const inner = std.mem.trim(u8, line[(call_open + 1)..call_close], " \t");
        if (!startsWithIgnoreCase(inner, "Database.query(") and !startsWithIgnoreCase(inner, "Database.queryWithBinds(")) {
            try out.appendSlice(gpa, line);
            continue;
        }

        try out.appendSlice(gpa, line[0 .. eq_pos + 1]);
        try appendFmt(gpa, &out, " {s};", .{inner});
        replaced = true;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteQuerySingletonAssignmentsToDeclaredListVars(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var list_names: std.ArrayList([]u8) = .empty;
    defer {
        for (list_names.items) |name| gpa.free(name);
        list_names.deinit(gpa);
    }

    var scan_lines = std.mem.splitScalar(u8, text, '\n');
    while (scan_lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractParameterizedTypeVariableName(line, "List")) |name| {
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

        for (list_names.items) |name| {
            if (try rewriteDeclaredListQuerySingletonLine(gpa, rendered, name)) |next| {
                gpa.free(rendered);
                rendered = next;
                replaced = true;
            }
        }

        try out.appendSlice(gpa, rendered);
        gpa.free(rendered);
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteDeclaredListQuerySingletonLine(gpa: std.mem.Allocator, line: []const u8, list_name: []const u8) !?[]u8 {
    const prefixes = [_][]const u8{
        "ApexCollections.firstOrNull(",
        "ApexCollections.firstOrThrow(",
    };

    for (prefixes) |prefix| {
        const marker = try std.fmt.allocPrint(gpa, "{s} = {s}", .{ list_name, prefix });
        defer gpa.free(marker);
        const start = std.mem.indexOf(u8, line, marker) orelse continue;

        const wrapper_open = start + marker.len - 1;
        const wrapper_close = findMatchingParen(line, wrapper_open) orelse continue;
        const inner = std.mem.trim(u8, line[(wrapper_open + 1)..wrapper_close], " \t");
        if (!startsWithIgnoreCase(inner, "Database.query(") and !startsWithIgnoreCase(inner, "Database.queryWithBinds(")) continue;

        const prefix_text = line[0 .. start + list_name.len + " = ".len];
        const suffix = std.mem.trimLeft(u8, line[(wrapper_close + 1)..], " \t");
        if (suffix.len != 0 and suffix[0] != ';') continue;
        const rendered = if (suffix.len == 0)
            try std.fmt.allocPrint(gpa, "{s}{s};", .{ prefix_text, inner })
        else
            try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix_text, inner, suffix });
        return rendered;
    }
    return null;
}

pub fn rewriteDeclaredSObjectQueryAssignments(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var sobject_names: std.ArrayList([]u8) = .empty;
    defer {
        for (sobject_names.items) |name| gpa.free(name);
        sobject_names.deinit(gpa);
    }

    var list_names: std.ArrayList([]u8) = .empty;
    defer {
        for (list_names.items) |name| gpa.free(name);
        list_names.deinit(gpa);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var replaced = false;
    var brace_depth: isize = 0;
    var method_depth: ?isize = null;
    var render_lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (render_lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (method_depth == null and brace_depth == 1 and isMethodLikeSignatureLine(trimmed)) {
            method_depth = brace_depth + 1;
            for (sobject_names.items) |name| gpa.free(name);
            sobject_names.clearRetainingCapacity();
            for (list_names.items) |name| gpa.free(name);
            list_names.clearRetainingCapacity();
        }

        if (method_depth != null) {
            if (extractParameterizedTypeVariableName(trimmed, "List")) |name| {
                try list_names.append(gpa, try gpa.dupe(u8, name));
            }
            if (extractTypedVariableName(trimmed, "ApexSObject")) |name| {
                try sobject_names.append(gpa, try gpa.dupe(u8, name));
            }
        }

        var rendered = try gpa.dupe(u8, line);
        if (method_depth != null) {
            for (sobject_names.items) |name| {
                if (containsIgnoreCaseNameSlice(list_names.items, name)) continue;
                if (try rewriteDeclaredSObjectQueryAssignmentLine(gpa, rendered, name)) |next| {
                    gpa.free(rendered);
                    rendered = next;
                    replaced = true;
                }
            }
        }

        try out.appendSlice(gpa, rendered);
        gpa.free(rendered);

        brace_depth += countByte(line, '{');
        brace_depth -= countByte(line, '}');
        if (method_depth != null and brace_depth < method_depth.?) {
            method_depth = null;
            for (sobject_names.items) |name| gpa.free(name);
            sobject_names.clearRetainingCapacity();
            for (list_names.items) |name| gpa.free(name);
            list_names.clearRetainingCapacity();
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteDeclaredSObjectQueryAssignmentLine(gpa: std.mem.Allocator, line: []const u8, var_name: []const u8) !?[]u8 {
    const marker = try std.fmt.allocPrint(gpa, "{s} = ", .{var_name});
    defer gpa.free(marker);
    const start = std.mem.indexOf(u8, line, marker) orelse return null;

    const rhs = std.mem.trim(u8, line[(start + marker.len)..], " \t");
    if (rhs.len == 0) return null;
    const expr = std.mem.trimRight(u8, rhs, "; \t");
    const suffix = rhs[expr.len..];
    if (!startsWithIgnoreCase(expr, "Database.query(") and !startsWithIgnoreCase(expr, "Database.queryWithBinds(")) return null;

    const prefix_text = line[0 .. start + marker.len];
    return try std.fmt.allocPrint(gpa, "{s}ApexCollections.firstOrNull({s}){s}", .{ prefix_text, expr, suffix });
}

pub fn rewriteTrailingDatabaseQueryAssignmentParens(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var replaced = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (try normalizeDatabaseQueryAssignmentLine(gpa, line)) |normalized| {
            defer gpa.free(normalized);
            try out.appendSlice(gpa, normalized);
            replaced = true;
            continue;
        }
        try out.appendSlice(gpa, line);
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn normalizeDatabaseQueryAssignmentLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const method = blk: {
        if (std.mem.indexOf(u8, line, " = Database.query(") != null) break :blk "Database.query(";
        if (std.mem.indexOf(u8, line, " = Database.queryWithBinds(") != null) break :blk "Database.queryWithBinds(";
        break :blk null;
    };
    if (method == null) return null;

    const method_start = std.mem.indexOf(u8, line, method.?) orelse return null;
    const open = method_start + method.?.len - 1;
    const close = findMatchingParen(line, open) orelse return null;
    const tail = line[(close + 1)..];
    const trim_idx = std.mem.indexOfNone(u8, tail, " \t") orelse tail.len;
    const trimmed_tail = tail[trim_idx..];

    if (trimmed_tail.len == 0) {
        return try std.fmt.allocPrint(gpa, "{s};", .{line[0 .. close + 1]});
    }
    if (trimmed_tail[0] == ';') return null;

    var extra_close_count: usize = 0;
    while (extra_close_count < trimmed_tail.len and trimmed_tail[extra_close_count] == ')') : (extra_close_count += 1) {}
    if (extra_close_count == 0) return null;

    var rest = trimmed_tail[extra_close_count..];
    const rest_trim_idx = std.mem.indexOfNone(u8, rest, " \t") orelse rest.len;
    rest = rest[rest_trim_idx..];

    if (rest.len == 0) {
        return try std.fmt.allocPrint(gpa, "{s};", .{line[0 .. close + 1]});
    }
    if (rest[0] == ';') {
        return try std.fmt.allocPrint(gpa, "{s}{s}", .{ line[0 .. close + 1], rest });
    }
    if (startsWithIgnoreCase(rest, "//") or startsWithIgnoreCase(rest, "/*")) {
        return try std.fmt.allocPrint(gpa, "{s}; {s}", .{ line[0 .. close + 1], rest });
    }
    return null;
}

pub fn rewriteListMethodQuerySingletonReturns(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var replaced = false;

    var brace_depth: isize = 0;
    var list_method_depth: ?isize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (list_method_depth == null and isListMethodSignatureLine(trimmed)) {
            list_method_depth = brace_depth + 1;
        }

        if (list_method_depth != null) {
            if (try normalizeListMethodQuerySingletonReturnLine(gpa, line)) |normalized| {
                defer gpa.free(normalized);
                try out.appendSlice(gpa, normalized);
                replaced = true;
            } else {
                try out.appendSlice(gpa, line);
            }
        } else {
            try out.appendSlice(gpa, line);
        }

        brace_depth += countByte(line, '{');
        brace_depth -= countByte(line, '}');
        if (list_method_depth != null and brace_depth < list_method_depth.?) {
            list_method_depth = null;
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn isListMethodSignatureLine(line: []const u8) bool {
    if (line.len == 0 or line[line.len - 1] != '{') return false;
    if (startsWithWordIgnoreCase(line, "if") or
        startsWithWordIgnoreCase(line, "for") or
        startsWithWordIgnoreCase(line, "while") or
        startsWithWordIgnoreCase(line, "switch") or
        startsWithWordIgnoreCase(line, "catch") or
        startsWithWordIgnoreCase(line, "else") or
        startsWithWordIgnoreCase(line, "do") or
        startsWithWordIgnoreCase(line, "try") or
        startsWithWordIgnoreCase(line, "class") or
        startsWithWordIgnoreCase(line, "interface") or
        startsWithWordIgnoreCase(line, "enum"))
    {
        return false;
    }

    const open = std.mem.indexOfScalar(u8, line, '(') orelse return false;
    const close = findMatchingParen(line, open) orelse return false;
    if (close + 1 >= line.len) return false;
    return std.mem.indexOf(u8, line[0..open], "List<") != null;
}

pub fn normalizeListMethodQuerySingletonReturnLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const prefixes = [_][]const u8{
        "return ApexCollections.firstOrNull(",
        "return ApexCollections.firstOrThrow(",
    };

    const trimmed = std.mem.trim(u8, line, " \t");
    for (prefixes) |prefix| {
        if (!startsWithIgnoreCase(trimmed, prefix)) continue;
        const wrapper_open = std.mem.indexOf(u8, trimmed, prefix) orelse continue;
        const open = wrapper_open + prefix.len - 1;
        const close = findMatchingParen(trimmed, open) orelse continue;
        const inner = std.mem.trim(u8, trimmed[(open + 1)..close], " \t");
        if (!startsWithIgnoreCase(inner, "Database.query(") and !startsWithIgnoreCase(inner, "Database.queryWithBinds(")) continue;
        const suffix = std.mem.trimLeft(u8, trimmed[(close + 1)..], " \t");
        if (suffix.len != 0 and suffix[0] != ';') continue;

        const indent_len = line.len - std.mem.trimLeft(u8, line, " \t").len;
        const indent = line[0..indent_len];
        return try std.fmt.allocPrint(gpa, "{s}return {s};", .{ indent, inner });
    }
    return null;
}

pub fn rewriteQueryWithBindsListChaining(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const chain_methods = [_][]const u8{ ".isEmpty()", ".size()", ".get(" };
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], "Database.queryWithBinds(")) continue;

        if (i >= 24) {
            const prefix = text[(i - 24)..i];
            if (std.mem.indexOf(u8, prefix, "List<ApexSObject>)") != null or
                std.mem.indexOf(u8, prefix, "java.util.List<ApexSObject>)") != null)
            {
                continue;
            }
        }

        const open = i + "Database.queryWithBinds".len;
        const close = findMatchingParen(text, open) orelse continue;

        const method_suffix = blk: {
            for (chain_methods) |candidate| {
                if (startsWithIgnoreCase(text[(close + 1)..], candidate)) break :blk candidate;
            }
            break :blk null;
        };
        if (method_suffix == null) continue;

        var suffix_end = close + 1 + method_suffix.?.len;
        if (std.mem.eql(u8, method_suffix.?, ".get(")) {
            const get_open = close + 1 + ".get".len;
            const get_close = findMatchingParen(text, get_open) orelse continue;
            suffix_end = get_close + 1;
        }

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "((List<ApexSObject>) {s}){s}", .{ text[i .. close + 1], text[(close + 1)..suffix_end] });
        replaced = true;
        last_emit = suffix_end;
        i = suffix_end - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteDatabaseDeleteQueryCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            const marker = "Database.delete";
            if (!startsWithIgnoreCase(text[i..], marker)) {
                i += 1;
                continue;
            }
            if (i > 0 and isIdentifierChar(text[i - 1])) {
                i += 1;
                continue;
            }
            if (i + marker.len < text.len and isIdentifierChar(text[i + marker.len])) {
                i += 1;
                continue;
            }

            var open = i + marker.len;
            while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
            if (open >= text.len or text[open] != '(') {
                i += 1;
                continue;
            }
            const close = findMatchingParen(text, open) orelse {
                i += 1;
                continue;
            };

            var args = try splitTopLevelCommaExpressions(gpa, text[(open + 1)..close]);
            defer args.deinit(gpa);
            if (args.items.len == 0) {
                i = close + 1;
                continue;
            }

            const first_arg = std.mem.trim(u8, args.items[0], " \t");
            const first_is_query = startsWithIgnoreCase(first_arg, "Database.query(") or
                startsWithIgnoreCase(first_arg, "Database.queryWithBinds(");
            if (!first_is_query) {
                i = close + 1;
                continue;
            }
            if (startsWithIgnoreCase(first_arg, "(java.util.List<ApexSObject>)") or
                startsWithIgnoreCase(first_arg, "((java.util.List<ApexSObject>)"))
            {
                i = close + 1;
                continue;
            }

            var rewritten_args: std.ArrayList(u8) = .empty;
            defer rewritten_args.deinit(gpa);
            try appendFmt(gpa, &rewritten_args, "((java.util.List<ApexSObject>) {s})", .{first_arg});
            if (args.items.len > 1) {
                for (args.items[1..]) |arg| {
                    try appendFmt(gpa, &rewritten_args, ", {s}", .{std.mem.trim(u8, arg, " \t")});
                }
            }

            try out.appendSlice(gpa, text[last_emit .. open + 1]);
            try out.appendSlice(gpa, rewritten_args.items);
            try out.append(gpa, ')');
            replaced = true;
            last_emit = close + 1;
            i = close + 1;
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteFirstOrNullScalarWrappers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "ApexCollections.firstOrNull";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            if (!startsWithIgnoreCase(text[i..], marker)) {
                i += 1;
                continue;
            }
            if (i > 0 and isIdentifierChar(text[i - 1])) {
                i += 1;
                continue;
            }
            if (i + marker.len < text.len and isIdentifierChar(text[i + marker.len])) {
                i += 1;
                continue;
            }

            var open = i + marker.len;
            while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
            if (open >= text.len or text[open] != '(') {
                i += 1;
                continue;
            }
            const close = findMatchingParen(text, open) orelse {
                i += 1;
                continue;
            };

            const inner = std.mem.trim(u8, text[(open + 1)..close], " \t");
            const should_unwrap = std.mem.indexOf(u8, inner, ".getAs(") != null or
                std.mem.indexOf(u8, inner, "ApexSwitch.getAs(") != null;
            if (!should_unwrap) {
                i = close + 1;
                continue;
            }

            try out.appendSlice(gpa, text[last_emit..i]);
            try out.appendSlice(gpa, inner);
            replaced = true;
            last_emit = close + 1;
            i = close + 1;
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteDatabaseQueryIndexCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
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
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub const DynamicBindEntry = struct {
    var_name: []u8,
    bind_names: std.ArrayList([]u8) = .empty,
};

pub fn rewriteDynamicWhereClauseQueryBinds(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn collectDynamicQueryBindEntriesForMethod(
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

pub fn initializeBindVariablesInMethod(
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

pub fn maybeInitializeBindDeclarationLine(
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

pub fn isBindVariableName(bind_entries: []const DynamicBindEntry, name: []const u8) bool {
    for (bind_entries) |entry| {
        for (entry.bind_names.items) |bind_name| {
            if (std.ascii.eqlIgnoreCase(bind_name, name)) return true;
        }
    }
    return false;
}

pub fn isLikelyLocalDeclarationType(type_part: []const u8) bool {
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

pub fn rewriteMethodQueryCallsWithDynamicBinds(
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

pub fn collectBindNamesFromQueryExpression(
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

pub fn buildBindMapArgument(gpa: std.mem.Allocator, bind_names: []const []u8) ![]u8 {
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

pub fn rewriteBindMapArgumentWithMissingBinds(
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

pub fn getOrCreateDynamicBindEntry(
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

pub fn dynamicBindEntryIndex(entries: []const DynamicBindEntry, var_name: []const u8) ?usize {
    for (entries, 0..) |entry, idx| {
        if (std.ascii.eqlIgnoreCase(entry.var_name, var_name)) return idx;
    }
    return null;
}

pub fn deinitOwnedNameList(gpa: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |name| gpa.free(name);
    names.deinit(gpa);
}

pub fn deinitDynamicBindEntries(gpa: std.mem.Allocator, entries: *std.ArrayList(DynamicBindEntry)) void {
    for (entries.items) |*entry| {
        gpa.free(entry.var_name);
        for (entry.bind_names.items) |bind_name| gpa.free(bind_name);
        entry.bind_names.deinit(gpa);
    }
    entries.deinit(gpa);
}

pub fn rewriteDatabaseQueryCallsWithBinds(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn convertInlineSoqlQueries(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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

pub fn convertInlineSoslQueries(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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

pub fn normalizeSoslQueryForEmulation(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
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

pub fn buildDatabaseSearchCall(
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

pub fn rewriteDatabaseQueryStringConsumers(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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

pub fn unwrapDatabaseQueryCall(arg: []const u8) ?[]const u8 {
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

pub const DatabaseQuerySource = struct {
    query_arg: []u8,
    binds_arg: ?[]u8 = null,
};

pub fn parseDatabaseQuerySource(gpa: std.mem.Allocator, arg: []const u8) ?DatabaseQuerySource {
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
