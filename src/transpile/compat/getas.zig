const line_and_expr = @import("../line_and_expr.zig");
const std = @import("std");
const util = @import("../util.zig");

const helpers = @import("helpers.zig");
const query = @import("query.zig");

const containsGetAsLikeCall = helpers.containsGetAsLikeCall;
const extractGetAsCallStringLiteralFieldName = helpers.extractGetAsCallStringLiteralFieldName;
const extractTypedVariableName = helpers.extractTypedVariableName;
const fieldNameLooksBoolean = helpers.fieldNameLooksBoolean;
const fieldNameLooksIdLike = helpers.fieldNameLooksIdLike;
const fieldNameLooksNonNumeric = helpers.fieldNameLooksNonNumeric;
const fieldNameLooksNumeric = helpers.fieldNameLooksNumeric;
const findMemberAccessBaseStart = helpers.findMemberAccessBaseStart;
const findNextNonWhitespace = helpers.findNextNonWhitespace;
const findPreviousNonWhitespace = helpers.findPreviousNonWhitespace;
const findTopLevelColon = helpers.findTopLevelColon;
const findTopLevelStatementSemicolon = helpers.findTopLevelStatementSemicolon;
const matchGetAsLikeCall = helpers.matchGetAsLikeCall;
const parseStringLiteralContents = helpers.parseStringLiteralContents;
const parseDatabaseQuerySource = query.parseDatabaseQuerySource;

const appendFmt = util.appendFmt;
const containsIgnoreCaseSubstring = util.containsIgnoreCaseSubstring;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const findMatchingParen = util.findMatchingParen;
const findMatchingParenBackward = util.findMatchingParenBackward;
const indexOfIgnoreCase = util.indexOfIgnoreCase;
const isIdentifierChar = util.isIdentifierChar;
const isLikelyTypeReferencePathExpression = util.isLikelyTypeReferencePathExpression;
const isSimpleIdentifierOrPath = util.isSimpleIdentifierOrPath;
const leadingIdentifier = util.leadingIdentifier;
const nextNonSpace = util.nextNonSpace;
const splitCallArguments = line_and_expr.splitCallArguments;
const splitTopLevelCommaExpressions = line_and_expr.splitTopLevelCommaExpressions;
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;

pub fn rewriteTypePathGetAsAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (endsWithIgnoreCase(base_expr, ".fields") or endsWithIgnoreCase(base_expr, ".fieldSets")) continue;

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

pub fn rewriteSObjectTypeVariableGetAsAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        if (text[i] != '.') continue;
        if (!startsWithIgnoreCase(text[i..], ".getAs")) continue;

        const method_end = i + ".getAs".len;
        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (!std.ascii.eqlIgnoreCase(base_expr, "sObjectType")) continue;

        const arg = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (arg.len < 3 or arg[0] != '"' or arg[arg.len - 1] != '"') continue;
        const member = arg[1 .. arg.len - 1];
        if (member.len == 0 or !isSimpleIdentifierOrPath(member)) continue;
        if (std.mem.indexOfScalar(u8, member, '.') != null) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "Schema.SObjectType.{s}", .{member});
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

pub fn rewriteGetAsCollectionAccessors(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

        if (startsWithIgnoreCase(text[accessor_start..], ".intValue()")) {
            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "ApexStrings.toInteger({s})", .{get_as_call});
            replaced = true;
            last_emit = accessor_start + ".intValue()".len;
            i = last_emit - 1;
            continue;
        }

        if (startsWithIgnoreCase(text[accessor_start..], ".Date()") or startsWithIgnoreCase(text[accessor_start..], ".date()")) {
            const method_len: usize = if (startsWithIgnoreCase(text[accessor_start..], ".Date()")) ".Date()".len else ".date()".len;
            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "Date.valueOf({s})", .{get_as_call});
            replaced = true;
            last_emit = accessor_start + method_len;
            i = last_emit - 1;
            continue;
        }

        if (startsWithIgnoreCase(text[accessor_start..], ".get(")) {
            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "((java.util.List<ApexSObject>) {s})", .{get_as_call});
            replaced = true;
            last_emit = accessor_start;
            i = accessor_start - 1;
            continue;
        }

        if (startsWithIgnoreCase(text[accessor_start..], ".add(") or
            startsWithIgnoreCase(text[accessor_start..], ".addAll(") or
            startsWithIgnoreCase(text[accessor_start..], ".clear()"))
        {
            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "((java.util.List<Object>) {s})", .{get_as_call});
            replaced = true;
            last_emit = accessor_start;
            i = accessor_start - 1;
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

pub fn rewriteGetAsMutationAssignments(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var state: CompatibilityState = .normal;
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
                const current_line_start = blk: {
                    if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |line_break| {
                        break :blk line_break + 1;
                    }
                    break :blk 0;
                };
                const call_start = if (call.start < current_line_start) current_line_start else call.start;
                if (call_start < last_emit) {
                    i = @max(i + 1, call.end);
                    continue;
                }
                if (call_start >= call.end) {
                    i = call.end;
                    continue;
                }

                const call_text = text[call_start..call.end];
                var base_expr: []const u8 = "";
                var field_literal: ?[]const u8 = null;
                if (startsWithIgnoreCase(call_text, "ApexSwitch.getAs(")) {
                    const open = std.mem.indexOfScalar(u8, call_text, '(') orelse {
                        i = call.end;
                        continue;
                    };
                    const close = findMatchingParen(call_text, open) orelse {
                        i = call.end;
                        continue;
                    };
                    const args_raw = std.mem.trim(u8, call_text[(open + 1)..close], " \t");
                    var args = try splitCallArguments(gpa, args_raw);
                    defer args.deinit(gpa);
                    if (args.items.len < 2) {
                        i = call.end;
                        continue;
                    }
                    base_expr = std.mem.trim(u8, args.items[0], " \t");
                    field_literal = parseStringLiteralContents(args.items[1]);
                } else {
                    const dot = std.mem.lastIndexOf(u8, call_text, ".getAs(") orelse std.mem.lastIndexOf(u8, call_text, ".get(") orelse {
                        i = call.end;
                        continue;
                    };
                    base_expr = std.mem.trim(u8, call_text[0..dot], " \t");
                    field_literal = extractGetAsCallStringLiteralFieldName(call_text);
                }
                if (base_expr.len == 0 or field_literal == null) {
                    i = call.end;
                    continue;
                }

                const op_idx = nextNonSpace(text, call.end);
                if (op_idx >= text.len) {
                    i = call.end;
                    continue;
                }

                if (op_idx + 1 < text.len and text[op_idx] == '=' and text[op_idx + 1] != '=') {
                    const rhs_start = nextNonSpace(text, op_idx + 1);
                    const semi = findTopLevelStatementSemicolon(text, rhs_start) orelse {
                        i = call.end;
                        continue;
                    };
                    const rhs_expr = std.mem.trim(u8, text[rhs_start..semi], " \t");
                    if (rhs_expr.len == 0) {
                        i = call.end;
                        continue;
                    }

                    try out.appendSlice(gpa, text[last_emit..call_start]);
                    try appendFmt(gpa, &out, "ApexSwitch.set({s}, \"{s}\", {s});", .{ base_expr, field_literal.?, rhs_expr });
                    replaced = true;
                    last_emit = semi + 1;
                    i = semi + 1;
                    continue;
                }

                if (op_idx + 1 < text.len and text[op_idx] == '+' and text[op_idx + 1] == '+') {
                    const semi = nextNonSpace(text, op_idx + 2);
                    if (semi >= text.len or text[semi] != ';') {
                        i = call.end;
                        continue;
                    }
                    try out.appendSlice(gpa, text[last_emit..call_start]);
                    try appendFmt(
                        gpa,
                        &out,
                        "ApexSwitch.set({s}, \"{s}\", ApexStrings.toInteger({s}) + 1);",
                        .{ base_expr, field_literal.?, call_text },
                    );
                    replaced = true;
                    last_emit = semi + 1;
                    i = semi + 1;
                    continue;
                }

                if (op_idx + 1 < text.len and text[op_idx] == '-' and text[op_idx + 1] == '-') {
                    const semi = nextNonSpace(text, op_idx + 2);
                    if (semi >= text.len or text[semi] != ';') {
                        i = call.end;
                        continue;
                    }
                    try out.appendSlice(gpa, text[last_emit..call_start]);
                    try appendFmt(
                        gpa,
                        &out,
                        "ApexSwitch.set({s}, \"{s}\", ApexStrings.toInteger({s}) - 1);",
                        .{ base_expr, field_literal.?, call_text },
                    );
                    replaced = true;
                    last_emit = semi + 1;
                    i = semi + 1;
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

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn argLikelyNeedsStringKeyWrap(arg_raw: []const u8) bool {
    const arg = std.mem.trim(u8, arg_raw, " \t");
    if (arg.len == 0) return false;
    if (parseStringLiteralContents(arg) != null) return false;
    if (startsWithIgnoreCase(arg, "ApexStrings.valueOf(")) return false;
    if (startsWithIgnoreCase(arg, "new Schema.SObjectField(")) return false;
    if (startsWithIgnoreCase(arg, "Schema.SObjectField.")) return false;
    if (startsWithIgnoreCase(arg, "(String)")) return false;
    return std.mem.indexOf(u8, arg, ".getAs(") != null or
        std.mem.indexOf(u8, arg, "ApexSwitch.getAs(") != null;
}

pub fn rewriteSObjectGetPutAmbiguousArgs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var state: CompatibilityState = .normal;
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
                if (text[i] != '.') {
                    i += 1;
                    continue;
                }

                const method_name = blk: {
                    if (startsWithIgnoreCase(text[i..], ".get(")) break :blk "get";
                    break :blk "";
                };
                if (method_name.len == 0) {
                    i += 1;
                    continue;
                }

                const open = i + method_name.len + 1;
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };
                const args_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
                if (args_raw.len == 0) {
                    i = close + 1;
                    continue;
                }
                var args = try splitCallArguments(gpa, args_raw);
                defer args.deinit(gpa);
                if (args.items.len == 0) {
                    i = close + 1;
                    continue;
                }

                if (!argLikelyNeedsStringKeyWrap(args.items[0])) {
                    i = close + 1;
                    continue;
                }

                var rebuilt: std.ArrayList(u8) = .empty;
                defer rebuilt.deinit(gpa);
                for (args.items, 0..) |arg, idx| {
                    if (idx != 0) try rebuilt.appendSlice(gpa, ", ");
                    if (idx == 0) {
                        const trimmed = std.mem.trim(u8, arg, " \t");
                        try appendFmt(gpa, &rebuilt, "ApexStrings.valueOf({s})", .{trimmed});
                    } else {
                        try rebuilt.appendSlice(gpa, std.mem.trim(u8, arg, " \t"));
                    }
                }

                try out.appendSlice(gpa, text[last_emit .. open + 1]);
                try out.appendSlice(gpa, rebuilt.items);
                try out.append(gpa, ')');
                replaced = true;
                last_emit = close + 1;
                i = close + 1;
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

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteGetAsNumericCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var double_names: std.ArrayList([]u8) = .empty;
    defer {
        for (double_names.items) |name| gpa.free(name);
        double_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractTypedVariableName(line, "Double")) |name| {
            try double_names.append(gpa, try gpa.dupe(u8, name));
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
        const rewritten = try rewriteNumericGetAsLine(gpa, line, double_names.items);
        defer gpa.free(rewritten);
        if (!std.mem.eql(u8, rewritten, line)) changed = true;
        try out.appendSlice(gpa, rewritten);
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteGetAsStringConcatenationCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const rewritten = try rewriteGetAsStringConcatenationLine(gpa, line);
        defer gpa.free(rewritten);
        if (!std.mem.eql(u8, rewritten, line)) changed = true;
        try out.appendSlice(gpa, rewritten);
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteGetAsStringConcatenationLine(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, line, ".getAs(") == null and std.mem.indexOf(u8, line, "ApexSwitch.getAs(") == null) {
        return gpa.dupe(u8, line);
    }
    if (std.mem.indexOf(u8, line, " + ") == null and std.mem.indexOfScalar(u8, line, '+') == null) {
        return gpa.dupe(u8, line);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const call = matchGetAsLikeCall(line, i) orelse {
            i += 1;
            continue;
        };
        if (call.start < last_emit) {
            i = @max(i + 1, call.end);
            continue;
        }
        const call_text = line[call.start..call.end];
        if (extractGetAsCallStringLiteralFieldName(call_text)) |field_name| {
            if (fieldNameLooksNumeric(field_name)) {
                i = call.end;
                continue;
            }
        }

        const prev_idx = findPreviousNonWhitespace(line, call.start);
        const next_idx = findNextNonWhitespace(line, call.end);
        const touches_plus = (prev_idx != null and line[prev_idx.?] == '+') or
            (next_idx != null and line[next_idx.?] == '+');
        if (!touches_plus) {
            i = call.end;
            continue;
        }

        try out.appendSlice(gpa, line[last_emit..call.start]);
        try appendFmt(gpa, &out, "ApexStrings.valueOf({s})", .{call_text});
        replaced = true;
        last_emit = call.end;
        i = call.end;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, line);
    }
    try out.appendSlice(gpa, line[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteNumericGetAsLine(gpa: std.mem.Allocator, line: []const u8, double_names: []const []u8) ![]u8 {
    if (std.mem.indexOf(u8, line, ".getAs(") == null and std.mem.indexOf(u8, line, "ApexSwitch.getAs(") == null) {
        return gpa.dupe(u8, line);
    }
    if (!lineLikelyNeedsNumericGetAsRewrite(gpa, line, double_names)) {
        return gpa.dupe(u8, line);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const call = matchGetAsLikeCall(line, i) orelse {
            i += 1;
            continue;
        };
        if (call.start < last_emit) {
            i = @max(i + 1, call.end);
            continue;
        }
        if (getAsCallIsNullCompared(line, call.end) or parseBooleanLiteralComparison(line, call.end) != null) {
            i = call.end;
            continue;
        }

        const call_text = line[call.start..call.end];
        if (!getAsCallNeedsNumericCompatibility(gpa, line, call_text, double_names)) {
            i = call.end;
            continue;
        }
        try out.appendSlice(gpa, line[last_emit..call.start]);
        try appendFmt(gpa, &out, "ApexStrings.toDouble({s})", .{call_text});
        replaced = true;
        last_emit = call.end;
        i = call.end;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, line);
    }
    try out.appendSlice(gpa, line[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn getAsCallNeedsNumericCompatibility(gpa: std.mem.Allocator, line: []const u8, call_text: []const u8, double_names: []const []u8) bool {
    if (std.mem.indexOf(u8, call_text, ".fields.getAs(") != null or
        startsWithIgnoreCase(call_text, "Schema.SObjectType.") or
        startsWithIgnoreCase(call_text, "new Schema.SObjectType("))
    {
        return false;
    }
    if (extractGetAsCallStringLiteralFieldName(call_text)) |field_name| {
        if (fieldNameLooksNumeric(field_name)) return true;
        if (fieldNameLooksNonNumeric(field_name)) return false;
    }

    const trimmed = std.mem.trim(u8, line, " \t");
    if (startsWithIgnoreCase(trimmed, "Double ")) return true;
    for (double_names) |name| {
        const add_eq = std.fmt.allocPrint(gpa, "{s} +=", .{name}) catch continue;
        defer gpa.free(add_eq);
        if (std.mem.indexOf(u8, trimmed, add_eq) != null) return true;

        const sub_eq = std.fmt.allocPrint(gpa, "{s} -=", .{name}) catch continue;
        defer gpa.free(sub_eq);
        if (std.mem.indexOf(u8, trimmed, sub_eq) != null) return true;

        const assign = std.fmt.allocPrint(gpa, "{s} =", .{name}) catch continue;
        defer gpa.free(assign);
        if (std.mem.indexOf(u8, trimmed, assign) != null) return true;
    }
    return false;
}

pub fn lineLikelyNeedsNumericGetAsRewrite(gpa: std.mem.Allocator, line: []const u8, double_names: []const []u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (startsWithIgnoreCase(trimmed, "Double ")) return true;
    if ((std.mem.indexOfScalar(u8, trimmed, '<') != null or std.mem.indexOfScalar(u8, trimmed, '>') != null) and
        (std.mem.indexOf(u8, trimmed, ".getAs(\"") != null or std.mem.indexOf(u8, trimmed, "ApexSwitch.getAs(") != null))
    {
        return true;
    }
    if ((std.mem.indexOfScalar(u8, trimmed, '<') != null or std.mem.indexOfScalar(u8, trimmed, '>') != null) and
        std.mem.indexOfAny(u8, trimmed, "0123456789") != null)
    {
        return true;
    }
    if ((startsWithIgnoreCase(trimmed, "if ") or startsWithIgnoreCase(trimmed, "if(") or
        startsWithIgnoreCase(trimmed, "else if ") or startsWithIgnoreCase(trimmed, "else if(") or
        startsWithIgnoreCase(trimmed, "while ") or startsWithIgnoreCase(trimmed, "while(")) and
        (std.mem.indexOfScalar(u8, trimmed, '<') != null or std.mem.indexOfScalar(u8, trimmed, '>') != null))
    {
        return true;
    }
    if (std.mem.indexOfScalar(u8, trimmed, '*') != null or
        std.mem.indexOfScalar(u8, trimmed, '/') != null or
        std.mem.indexOf(u8, trimmed, "+=") != null or
        std.mem.indexOf(u8, trimmed, "-=") != null)
    {
        return true;
    }
    if ((std.mem.indexOf(u8, trimmed, " + ") != null or std.mem.indexOf(u8, trimmed, " - ") != null) and
        (std.mem.indexOf(u8, trimmed, "\"Amount") != null or std.mem.indexOf(u8, trimmed, "\"Percent") != null))
    {
        return true;
    }
    if ((std.mem.indexOf(u8, trimmed, " + ") != null or std.mem.indexOf(u8, trimmed, " - ") != null) and
        std.mem.indexOf(u8, trimmed, ".getAs(\"") != null)
    {
        return true;
    }
    if ((std.mem.indexOf(u8, trimmed, "==") != null or std.mem.indexOf(u8, trimmed, "!=") != null) and
        std.mem.indexOfAny(u8, trimmed, "0123456789") != null)
    {
        return true;
    }
    for (double_names) |name| {
        const add_eq = std.fmt.allocPrint(gpa, "{s} +=", .{name}) catch continue;
        defer gpa.free(add_eq);
        if (std.mem.indexOf(u8, trimmed, add_eq) != null) return true;

        const sub_eq = std.fmt.allocPrint(gpa, "{s} -=", .{name}) catch continue;
        defer gpa.free(sub_eq);
        if (std.mem.indexOf(u8, trimmed, sub_eq) != null) return true;

        const assign = std.fmt.allocPrint(gpa, "{s} =", .{name}) catch continue;
        defer gpa.free(assign);
        if (std.mem.indexOf(u8, trimmed, assign) != null) return true;
    }
    return false;
}

pub fn getAsCallIsNullCompared(line: []const u8, call_end: usize) bool {
    var i = call_end;
    while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
    if (i + 1 < line.len and ((line[i] == '=' and line[i + 1] == '=') or (line[i] == '!' and line[i + 1] == '='))) {
        i += 2;
    } else {
        return false;
    }
    while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
    return startsWithWordIgnoreCase(line[i..], "null");
}

pub fn rewriteGetAsFieldAddErrorCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], ".getAs")) continue;

        const get_as_open = std.mem.indexOfScalarPos(u8, text, i + ".getAs".len, '(') orelse continue;
        const get_as_close = findMatchingParen(text, get_as_open) orelse continue;
        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        const field_arg = std.mem.trim(u8, text[(get_as_open + 1)..get_as_close], " \t");
        if (field_arg.len < 2 or field_arg[0] != '"' or field_arg[field_arg.len - 1] != '"') continue;

        const add_error_dot = nextNonSpace(text, get_as_close + 1);
        if (add_error_dot >= text.len or text[add_error_dot] != '.') continue;
        if (!startsWithIgnoreCase(text[add_error_dot..], ".addError")) continue;

        var add_error_open = add_error_dot + ".addError".len;
        while (add_error_open < text.len and std.ascii.isWhitespace(text[add_error_open])) : (add_error_open += 1) {}
        if (add_error_open >= text.len or text[add_error_open] != '(') continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(
            gpa,
            &out,
            "{s}.addError(new Schema.SObjectField(ApexSwitch.getSObjectType({s}).getName(), {s}), ",
            .{ base_expr, base_expr, field_arg },
        );
        replaced = true;
        last_emit = add_error_open + 1;
        i = add_error_open;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteGetAsEnumNameCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const call = matchGetAsLikeCall(text, i) orelse continue;
        if (!startsWithIgnoreCase(text[call.end..], ".name()")) continue;

        try out.appendSlice(gpa, text[last_emit..call.start]);
        try appendFmt(gpa, &out, "ApexStrings.valueOf({s})", .{text[call.start..call.end]});
        replaced = true;
        last_emit = call.end + ".name()".len;
        i = last_emit - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteGetAsDateMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const methods = [_][]const u8{ ".addDays(", ".addMonths(", ".addYears(", ".daysBetween(", ".year()", ".month()", ".day()" };
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], ".getAs(")) continue;
        const open = i + ".getAs".len;
        const close = findMatchingParen(text, open) orelse continue;

        const method_suffix = blk: {
            for (methods) |candidate| {
                if (startsWithIgnoreCase(text[(close + 1)..], candidate)) break :blk candidate;
            }
            break :blk null;
        };
        if (method_suffix == null) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        const field_expr = std.mem.trim(u8, text[(open + 1)..close], " \t");

        var suffix_end = close + 1 + method_suffix.?.len;
        if (method_suffix.?[method_suffix.?.len - 1] == '(') {
            const method_open = close + 1 + method_suffix.?.len - 1;
            const method_close = findMatchingParen(text, method_open) orelse continue;
            suffix_end = method_close + 1;
        }

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "Date.valueOf({s}.getAs({s})){s}", .{ base_expr, field_expr, text[(close + 1)..suffix_end] });
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

pub fn rewriteApexStringsValueOfDateGetAs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    const marker = "ApexStrings.valueOf(";

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
                if (!startsWithIgnoreCase(text[i..], marker)) {
                    i += 1;
                    continue;
                }
                if (i > 0 and isIdentifierChar(text[i - 1])) {
                    i += 1;
                    continue;
                }

                const open = i + marker.len - 1;
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };
                const inner = std.mem.trim(u8, text[(open + 1)..close], " \t");
                const field_name = extractGetAsCallStringLiteralFieldName(inner) orelse {
                    i = close + 1;
                    continue;
                };
                if (!std.ascii.eqlIgnoreCase(field_name, "CloseDate") and !containsIgnoreCaseSubstring(field_name, "close_date")) {
                    i = close + 1;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..i]);
                try out.appendSlice(gpa, inner);
                replaced = true;
                last_emit = close + 1;
                i = close + 1;
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

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteDynamicFieldNameGetCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], ".get(")) continue;
        const open = i + ".get".len;
        const close = findMatchingParen(text, open) orelse continue;
        const arg = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (!startsWithIgnoreCase(arg, "ApexSwitch.getAs(")) continue;
        if (std.mem.indexOf(u8, arg, ", \"Name\")") == null and std.mem.indexOf(u8, arg, ", \"name\")") == null) continue;

        try out.appendSlice(gpa, text[last_emit..(open + 1)]);
        try appendFmt(gpa, &out, "ApexStrings.valueOf({s})", .{arg});
        replaced = true;
        last_emit = close;
        i = close - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteDecimalSetScaleCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], ".setScale")) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const method_end = i + ".setScale".len;
        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        const args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (base_expr.len == 0 or args.len == 0) continue;

        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "ApexMath.setScale({s}, {s})", .{ base_expr, args });
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

pub fn rewriteGetErrorsArrayAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub const CompatibilityState = enum {
    normal,
    line_comment,
    block_comment,
    string_literal,
    char_literal,
};

pub fn rewriteGetAsBooleanCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                const field_name = extractGetAsCallStringLiteralFieldName(call_text);
                const field_is_booleanish = if (field_name) |name| fieldNameLooksBoolean(name) else true;
                const field_allows_boolean_context = if (field_name) |name| !fieldNameLooksNonNumeric(name) else true;
                const return_context = isReturnKeywordContext(text, prev_idx);

                var replacement: ?[]u8 = null;
                var replace_start = call.start;
                var replace_end = call.end;

                if (field_is_booleanish) {
                    if (prev_idx) |prev| {
                        if (text[prev] == '!' and (prev == 0 or text[prev - 1] != '=')) {
                            replacement = try std.fmt.allocPrint(gpa, "!Boolean.TRUE.equals({s})", .{call_text});
                            replace_start = prev;
                        }
                    }
                }

                if (replacement == null and field_is_booleanish) {
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

                if (replacement == null and field_allows_boolean_context and (!return_context or field_is_booleanish) and isBooleanOperandContext(text, call.start, call.end, prev_idx, next_idx)) {
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

pub fn rewriteGetAsStringMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const RewriteKind = enum {
        wrap_valueof,
        apex_static,
    };
    const StringMethod = struct {
        suffix: []const u8,
        method_name: []const u8,
        kind: RewriteKind,
    };
    const methods = [_]StringMethod{
        .{ .suffix = ".indexOf", .method_name = "indexOf", .kind = .wrap_valueof },
        .{ .suffix = ".substringAfterLast", .method_name = "substringAfterLast", .kind = .apex_static },
        .{ .suffix = ".substringBeforeLast", .method_name = "substringBeforeLast", .kind = .apex_static },
        .{ .suffix = ".substring", .method_name = "substring", .kind = .wrap_valueof },
        .{ .suffix = ".contains", .method_name = "contains", .kind = .wrap_valueof },
        .{ .suffix = ".startsWith", .method_name = "startsWith", .kind = .wrap_valueof },
        .{ .suffix = ".endsWith", .method_name = "endsWith", .kind = .wrap_valueof },
        .{ .suffix = ".trim", .method_name = "trim", .kind = .wrap_valueof },
        .{ .suffix = ".toLowerCase", .method_name = "toLowerCase", .kind = .wrap_valueof },
        .{ .suffix = ".toUpperCase", .method_name = "toUpperCase", .kind = .wrap_valueof },
        .{ .suffix = ".replaceFirst", .method_name = "replaceFirst", .kind = .wrap_valueof },
        .{ .suffix = ".replace", .method_name = "replace", .kind = .wrap_valueof },
        .{ .suffix = ".charAt", .method_name = "charAt", .kind = .wrap_valueof },
        .{ .suffix = ".length", .method_name = "length", .kind = .wrap_valueof },
        .{ .suffix = ".isAlpha", .method_name = "isAlpha", .kind = .apex_static },
        .{ .suffix = ".abbreviate", .method_name = "abbreviate", .kind = .apex_static },
        .{ .suffix = ".endsWithIgnoreCase", .method_name = "endsWithIgnoreCase", .kind = .apex_static },
        .{ .suffix = ".leftPad", .method_name = "leftPad", .kind = .apex_static },
        .{ .suffix = ".rightPad", .method_name = "rightPad", .kind = .apex_static },
        .{ .suffix = ".removeEndIgnoreCase", .method_name = "removeEndIgnoreCase", .kind = .apex_static },
        .{ .suffix = ".removeEnd", .method_name = "removeEnd", .kind = .apex_static },
        .{ .suffix = ".removeStartIgnoreCase", .method_name = "removeStartIgnoreCase", .kind = .apex_static },
        .{ .suffix = ".removeStart", .method_name = "removeStart", .kind = .apex_static },
        .{ .suffix = ".remove", .method_name = "remove", .kind = .apex_static },
        .{ .suffix = ".deleteWhiteSpace", .method_name = "deleteWhiteSpace", .kind = .apex_static },
        .{ .suffix = ".capitalize", .method_name = "capitalize", .kind = .apex_static },
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

                const call = matchGetAsLikeCall(text, i) orelse {
                    i += 1;
                    continue;
                };
                if (call.start < last_emit) {
                    i = @max(i + 1, call.end);
                    continue;
                }

                const method_dot = findNextNonWhitespace(text, call.end) orelse {
                    i = call.end;
                    continue;
                };
                if (method_dot >= text.len or text[method_dot] != '.') {
                    i = call.end;
                    continue;
                }

                var matched: ?StringMethod = null;
                for (methods) |method| {
                    if (startsWithIgnoreCase(text[method_dot..], method.suffix)) {
                        matched = method;
                        break;
                    }
                }
                if (matched == null) {
                    i = call.end;
                    continue;
                }

                const method = matched.?;
                const method_end = method_dot + method.suffix.len;
                if (method_end < text.len and isIdentifierChar(text[method_end])) {
                    i = call.end;
                    continue;
                }

                var open = method_end;
                while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
                if (open >= text.len or text[open] != '(') {
                    i = call.end;
                    continue;
                }
                const close = findMatchingParen(text, open) orelse {
                    i = call.end;
                    continue;
                };

                const call_text = text[call.start..call.end];
                const args = std.mem.trim(u8, text[(open + 1)..close], " \t");
                const replacement = switch (method.kind) {
                    .wrap_valueof => if (args.len == 0)
                        try std.fmt.allocPrint(gpa, "ApexStrings.valueOf({s}).{s}()", .{ call_text, method.method_name })
                    else
                        try std.fmt.allocPrint(gpa, "ApexStrings.valueOf({s}).{s}({s})", .{ call_text, method.method_name, args }),
                    .apex_static => if (args.len == 0)
                        try std.fmt.allocPrint(gpa, "ApexStrings.{s}({s})", .{ method.method_name, call_text })
                    else
                        try std.fmt.allocPrint(gpa, "ApexStrings.{s}({s}, {s})", .{ method.method_name, call_text, args }),
                };
                defer gpa.free(replacement);

                try out.appendSlice(gpa, text[last_emit..call.start]);
                try out.appendSlice(gpa, replacement);
                replaced = true;
                last_emit = close + 1;
                i = close + 1;
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

pub fn rewriteOverloadedStringIdCallArgs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

                const marker = blk: {
                    if (startsWithIgnoreCase(text[i..], ".withContact(")) break :blk ".withContact(";
                    if (startsWithIgnoreCase(text[i..], ".withAccount(")) break :blk ".withAccount(";
                    if (startsWithIgnoreCase(text[i..], "withContact(")) break :blk "withContact(";
                    if (startsWithIgnoreCase(text[i..], "withAccount(")) break :blk "withAccount(";
                    if (startsWithIgnoreCase(text[i..], ".getOppContactRoles(")) break :blk ".getOppContactRoles(";
                    if (startsWithIgnoreCase(text[i..], "getOppContactRoles(")) break :blk "getOppContactRoles(";
                    if (startsWithIgnoreCase(text[i..], ".getContacts(")) break :blk ".getContacts(";
                    if (startsWithIgnoreCase(text[i..], "getContacts(")) break :blk "getContacts(";
                    if (startsWithIgnoreCase(text[i..], ".getOCRs(")) break :blk ".getOCRs(";
                    if (startsWithIgnoreCase(text[i..], "getOCRs(")) break :blk "getOCRs(";
                    if (startsWithIgnoreCase(text[i..], ".retrieveSchedulesUsingApi(")) break :blk ".retrieveSchedulesUsingApi(";
                    if (startsWithIgnoreCase(text[i..], "retrieveSchedulesUsingApi(")) break :blk "retrieveSchedulesUsingApi(";
                    if (startsWithIgnoreCase(text[i..], "getRecurringDonationBuilder(")) break :blk "getRecurringDonationBuilder(";
                    break :blk "";
                };
                if (marker.len == 0) {
                    i += 1;
                    continue;
                }
                if (marker[0] != '.' and i > 0 and (isIdentifierChar(text[i - 1]) or text[i - 1] == '.')) {
                    i += 1;
                    continue;
                }

                const open = i + marker.len - 1;
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };
                const arg_raw = text[(open + 1)..close];
                const arg = std.mem.trim(u8, arg_raw, " \t");
                if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, ',') != null) {
                    i = close + 1;
                    continue;
                }
                if (startsWithIgnoreCase(arg, "ApexStrings.valueOf(")) {
                    i = close + 1;
                    continue;
                }
                var looks_like_id_getter = std.mem.indexOf(u8, arg, ".getAs(\"Id\")") != null or
                    std.mem.indexOf(u8, arg, ".getAs(\"id\")") != null;
                if (!looks_like_id_getter) {
                    if (extractGetAsCallStringLiteralFieldName(arg)) |field_name| {
                        looks_like_id_getter = fieldNameLooksIdLike(field_name);
                    }
                }
                if (!looks_like_id_getter) {
                    i = close + 1;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit .. open + 1]);
                try appendFmt(gpa, &out, "ApexStrings.valueOf({s})", .{arg});
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

pub fn rewriteEnhancedForGetAsIterables(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                const right_is_query = startsWithIgnoreCase(right, "Database.query(") or startsWithIgnoreCase(right, "Database.queryWithBinds(");
                if (right.len == 0 or (!containsGetAsLikeCall(right) and !right_is_query)) {
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

pub fn rewriteEnhancedForCompareArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        const prefix = "for (ApexStrings.compareTo(";
        if (!startsWithIgnoreCase(trimmed, prefix)) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const open = std.mem.indexOf(u8, trimmed, prefix) orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        const compare_open = open + prefix.len - 1;
        const compare_close = findMatchingParen(trimmed, compare_open) orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        const inner = trimmed[(compare_open + 1)..compare_close];
        const colon = std.mem.indexOfScalar(u8, inner, ':') orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        const comma = std.mem.lastIndexOfScalar(u8, inner[0..colon], ',') orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        const left = std.mem.trim(u8, inner[0..comma], " \t");
        const right = std.mem.trim(u8, inner[(comma + 1)..], " \t");
        if (left.len == 0 or right.len == 0) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const suffix = std.mem.trimLeft(u8, trimmed[(compare_close + 1)..], " \t");
        if (!startsWithIgnoreCase(suffix, "> 0)") and !startsWithIgnoreCase(suffix, ">0)")) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const indent_len = line.len - std.mem.trimLeft(u8, line, " \t").len;
        const indent = line[0..indent_len];
        const after_suffix = blk: {
            if (startsWithIgnoreCase(suffix, "> 0)")) break :blk suffix[4..];
            break :blk suffix[3..];
        };
        try appendFmt(gpa, &out, "{s}for ({s}> {s}){s}", .{ indent, left, right, after_suffix });
        changed = true;
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn isIdGetAsSuffix(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    return endsWithIgnoreCase(trimmed, ".getAs(\"Id\")") or endsWithIgnoreCase(trimmed, ".getAs(\"id\")");
}

pub fn rewriteNestedIdApexSwitchGetAs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "ApexSwitch.getAs";
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
                if (args.items.len < 2) {
                    i = close + 1;
                    continue;
                }

                const first = std.mem.trim(u8, args.items[0], " \t");
                if (!isIdGetAsSuffix(first)) {
                    i = close + 1;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..i]);
                try out.appendSlice(gpa, first);
                replaced = true;
                last_emit = close + 1;
                i = close + 1;
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

pub const BooleanLiteralComparison = struct {
    value: bool,
    negated: bool,
    end: usize,
};

pub fn parseBooleanLiteralComparison(text: []const u8, from: usize) ?BooleanLiteralComparison {
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

pub fn isBooleanOperandContext(text: []const u8, call_start: usize, call_end: usize, prev_idx: ?usize, next_idx: ?usize) bool {
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
        if (ch == '.' or ch == ')' or ch == ']') return false;
        if (isIdentifierChar(ch)) {
            var start = prev;
            while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
            const token = text[start .. prev + 1];
            return std.ascii.eqlIgnoreCase(token, "return");
        }
        if (ch == '(') return isBooleanIntroducerBeforeParen(text, prev);
        if (ch == '=') {
            return assignmentContextExpectsBoolean(text, prev);
        }
        return ch == '&' or ch == '|' or ch == ';';
    }

    return true;
}

pub fn isReturnKeywordContext(text: []const u8, prev_idx: ?usize) bool {
    const prev = prev_idx orelse return false;
    if (!isIdentifierChar(text[prev])) return false;

    var start = prev;
    while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
    return std.ascii.eqlIgnoreCase(text[start .. prev + 1], "return");
}

pub fn isBooleanIntroducerBeforeParen(text: []const u8, paren_idx: usize) bool {
    const prev = findPreviousNonWhitespace(text, paren_idx) orelse return true;
    const ch = text[prev];
    if (ch == '(' or ch == '&' or ch == '|' or ch == '?' or ch == ':' or ch == ';') return true;
    if (!isIdentifierChar(ch)) return false;

    var start = prev;
    while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
    const token = text[start .. prev + 1];
    return std.ascii.eqlIgnoreCase(token, "if") or
        std.ascii.eqlIgnoreCase(token, "while") or
        std.ascii.eqlIgnoreCase(token, "return") or
        std.ascii.eqlIgnoreCase(token, "assertTrue") or
        std.ascii.eqlIgnoreCase(token, "assertFalse");
}

pub fn assignmentContextExpectsBoolean(text: []const u8, eq_idx: usize) bool {
    if (eq_idx > 0 and (text[eq_idx - 1] == '=' or text[eq_idx - 1] == '!' or text[eq_idx - 1] == '<' or text[eq_idx - 1] == '>')) {
        return false;
    }
    const line_start = std.mem.lastIndexOfScalar(u8, text[0..eq_idx], '\n') orelse 0;
    const lhs = std.mem.trim(u8, text[line_start..eq_idx], " \t\r\n");
    return extractTypedVariableName(lhs, "Boolean") != null or
        extractTypedVariableName(lhs, "boolean") != null;
}

pub fn inferEnhancedForElementType(left: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, left, " \t");
    if (startsWithWordIgnoreCase(trimmed, "final")) {
        trimmed = std.mem.trim(u8, trimmed["final".len..], " \t");
    }
    const space = std.mem.lastIndexOfAny(u8, trimmed, " \t") orelse return null;
    return std.mem.trim(u8, trimmed[0..space], " \t");
}

pub fn rewriteSObjectGetAsLengthFallback(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteSObjectGetAsMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        } else if (std.ascii.eqlIgnoreCase(called_method, "set")) {
            replacement = try std.fmt.allocPrint(gpa, "((ApexSObject) {s}).set({s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "formatGMT")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexSwitch.formatGMT({s}, {s})", .{ get_as_call, called_args });
        } else if (std.ascii.eqlIgnoreCase(called_method, "toLowerCase") and called_args.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.valueOf({s}).toLowerCase()", .{get_as_call});
        } else if (std.ascii.eqlIgnoreCase(called_method, "toUpperCase") and called_args.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.valueOf({s}).toUpperCase()", .{get_as_call});
        } else if (std.ascii.eqlIgnoreCase(called_method, "trim") and called_args.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.valueOf({s}).trim()", .{get_as_call});
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

pub fn rewritePrintlnGetAsCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteQueryGetAsAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteFirstOrNullGetAs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
