//! numeric — Apex 数値型の Java 互換変換。
//!
//! Apex の Decimal/Integer/Double リテラルやメソッド呼び出しを
//! Java の BigDecimal / int / double 相当の式に変換する。

const stmt_mod = @import("../statements.zig");
const std = @import("std");
const util = @import("../util.zig");

const getas = @import("getas.zig");
const helpers = @import("helpers.zig");

const CompatibilityState = helpers.CompatibilityState;
const skipNonNormal = helpers.skipNonNormal;
const containsFieldKeywordToken = helpers.containsFieldKeywordToken;
const containsIgnoreCaseNameSlice = helpers.containsIgnoreCaseNameSlice;
const containsKnownObjectIdentifier = helpers.containsKnownObjectIdentifier;
const countByte = helpers.countByte;
const extractTypedDeclarationSection = helpers.extractTypedDeclarationSection;
const extractTypedVariableName = helpers.extractTypedVariableName;
const findCastOperandEnd = helpers.findCastOperandEnd;
const findTopLevelTernary = helpers.findTopLevelTernary;
const isLikelyCastFollowToken = helpers.isLikelyCastFollowToken;
const isLikelyCastStart = helpers.isLikelyCastStart;
const isMethodLikeSignatureLine = helpers.isMethodLikeSignatureLine;
const isSignedDecimalZeroLiteral = helpers.isSignedDecimalZeroLiteral;
const isSignedIntegerLiteral = helpers.isSignedIntegerLiteral;
const replaceLiteralAll = helpers.replaceLiteralAll;

const appendFmt = util.appendFmt;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const findMatchingParen = util.findMatchingParen;
const indexOfWordIgnoreCase = util.indexOfWordIgnoreCase;
const isIdentifierChar = util.isIdentifierChar;
const isSimpleIdentifier = util.isSimpleIdentifier;
const leadingIdentifier = util.leadingIdentifier;
const nextNonSpace = util.nextNonSpace;
const splitCallArguments = stmt_mod.splitCallArguments;
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;

pub fn rewriteLongAssignmentsFromIntegerIdentifiers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub const BoxedNumericKind = enum {
    double,
    long,
    integer,
};

pub const MethodReturnKind = enum {
    none,
    double,
    long,
    integer,
};

pub fn rewriteBoxedNumericLiteralCompatibility(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var double_names: std.ArrayList([]u8) = .empty;
    defer {
        for (double_names.items) |name| gpa.free(name);
        double_names.deinit(gpa);
    }
    var long_names: std.ArrayList([]u8) = .empty;
    defer {
        for (long_names.items) |name| gpa.free(name);
        long_names.deinit(gpa);
    }
    var integer_names: std.ArrayList([]u8) = .empty;
    defer {
        for (integer_names.items) |name| gpa.free(name);
        integer_names.deinit(gpa);
    }

    var collect_lines = std.mem.splitScalar(u8, text, '\n');
    while (collect_lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        try appendTypedNamesFromLine(gpa, line, "Double", &double_names);
        try appendTypedNamesFromLine(gpa, line, "Long", &long_names);
        try appendTypedNamesFromLine(gpa, line, "Integer", &integer_names);
        try appendTypedParameterNamesFromSignatureLine(gpa, line, "Double", &double_names);
        try appendTypedParameterNamesFromSignatureLine(gpa, line, "Long", &long_names);
        try appendTypedParameterNamesFromSignatureLine(gpa, line, "Integer", &integer_names);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var changed = false;

    var method_return_kind: MethodReturnKind = .none;
    var method_depth: ?isize = null;
    var brace_depth: isize = 0;

    var render_lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (render_lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (method_depth == null) {
            const detected = detectMethodReturnKind(trimmed);
            if (detected != .none) {
                method_return_kind = detected;
                method_depth = brace_depth;
            }
        }

        var rendered = try gpa.dupe(u8, line);
        defer gpa.free(rendered);

        var next = try rewriteTypedDeclarationIntegerInitializers(gpa, rendered, "Double", .double);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteTypedDeclarationIntegerInitializers(gpa, rendered, "Long", .long);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteTypedDeclarationIntegerInitializers(gpa, rendered, "Integer", .integer);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteTypedNameLiteralAssignments(gpa, rendered, double_names.items, .double);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteTypedNameLiteralAssignments(gpa, rendered, long_names.items, .long);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteLongMathMaxAssignments(gpa, rendered, long_names.items);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteIntegerTypedDoubleAssignments(gpa, rendered, integer_names.items);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteLikelyDoubleMemberLiteralAssignments(gpa, rendered);
        gpa.free(rendered);
        rendered = next;

        next = try rewriteBoxedNumericCasts(gpa, rendered);
        gpa.free(rendered);
        rendered = next;

        if (method_return_kind != .none and method_depth != null) {
            next = try rewriteMethodReturnLiterals(gpa, rendered, method_return_kind);
            gpa.free(rendered);
            rendered = next;
        }

        if (!std.mem.eql(u8, rendered, line)) changed = true;
        try out.appendSlice(gpa, rendered);

        brace_depth += countByte(line, '{');
        brace_depth -= countByte(line, '}');
        if (method_depth != null and brace_depth <= method_depth.?) {
            method_depth = null;
            method_return_kind = .none;
        }
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn appendTypedNamesFromLine(gpa: std.mem.Allocator, line: []const u8, type_name: []const u8, names: *std.ArrayList([]u8)) !void {
    const declaration = extractTypedDeclarationSection(line, type_name) orelse return;
    var parts = try splitCallArguments(gpa, declaration);
    defer parts.deinit(gpa);
    for (parts.items) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const lhs = std.mem.trim(u8, part[0..eq], " \t");
        const name = leadingIdentifier(lhs) orelse continue;
        if (containsIgnoreCaseNameSlice(names.items, name)) continue;
        try names.append(gpa, try gpa.dupe(u8, name));
    }
}

pub fn appendTypedParameterNamesFromSignatureLine(gpa: std.mem.Allocator, line: []const u8, type_name: []const u8, names: *std.ArrayList([]u8)) !void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!isMethodLikeSignatureLine(trimmed)) return;
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return;
    const close = findMatchingParen(trimmed, open) orelse return;
    if (close <= open + 1) return;

    const params_raw = std.mem.trim(u8, trimmed[(open + 1)..close], " \t");
    if (params_raw.len == 0) return;
    var params = try splitCallArguments(gpa, params_raw);
    defer params.deinit(gpa);
    for (params.items) |param_raw| {
        var param = std.mem.trim(u8, param_raw, " \t");
        while (startsWithWordIgnoreCase(param, "final")) {
            param = std.mem.trimLeft(u8, param["final".len..], " \t");
        }
        var tokens = std.mem.tokenizeAny(u8, param, " \t");
        var prev: ?[]const u8 = null;
        var current: ?[]const u8 = null;
        while (tokens.next()) |token| {
            prev = current;
            current = token;
        }
        const type_token = prev orelse continue;
        const name = current orelse continue;
        if (!std.ascii.eqlIgnoreCase(type_token, type_name)) continue;
        if (!isSimpleIdentifier(name)) continue;
        if (containsIgnoreCaseNameSlice(names.items, name)) continue;
        try names.append(gpa, try gpa.dupe(u8, name));
    }
}

pub fn rewriteTypedDeclarationIntegerInitializers(gpa: std.mem.Allocator, line: []const u8, type_name: []const u8, kind: BoxedNumericKind) ![]u8 {
    const declaration = extractTypedDeclarationSection(line, type_name) orelse return gpa.dupe(u8, line);
    const trimmed = std.mem.trim(u8, line, " \t");
    const semi = std.mem.lastIndexOfScalar(u8, trimmed, ';').?;
    const type_pos = indexOfWordIgnoreCase(trimmed, type_name).?;
    const after_type = type_pos + type_name.len;

    var parts = try splitCallArguments(gpa, declaration);
    defer parts.deinit(gpa);
    var changed = false;

    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    for (parts.items, 0..) |part_raw, idx| {
        if (idx != 0) try rebuilt.appendSlice(gpa, ", ");
        const part = std.mem.trim(u8, part_raw, " \t");
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse {
            try rebuilt.appendSlice(gpa, part);
            continue;
        };
        const lhs = std.mem.trimRight(u8, part[0..eq], " \t");
        const rhs = std.mem.trim(u8, part[(eq + 1)..], " \t");
        const normalized = try normalizeExpressionForKind(gpa, rhs, kind);
        defer if (normalized) |value| gpa.free(value);
        if (normalized) |literal| {
            try appendFmt(gpa, &rebuilt, "{s} = {s}", .{ lhs, literal });
            changed = true;
        } else {
            try appendFmt(gpa, &rebuilt, "{s} = {s}", .{ lhs, rhs });
        }
    }

    if (!changed) return gpa.dupe(u8, line);

    const left_ws_len = line.len - std.mem.trimLeft(u8, line, " \t").len;
    const left_ws = line[0..left_ws_len];
    const prefix = std.mem.trimRight(u8, trimmed[0..after_type], " \t");
    const suffix = std.mem.trimLeft(u8, trimmed[(semi + 1)..], " \t");
    if (suffix.len == 0) {
        return std.fmt.allocPrint(gpa, "{s}{s} {s};", .{ left_ws, prefix, rebuilt.items });
    }
    return std.fmt.allocPrint(gpa, "{s}{s} {s}; {s}", .{ left_ws, prefix, rebuilt.items, suffix });
}

pub fn rewriteTypedNameLiteralAssignments(gpa: std.mem.Allocator, line: []const u8, names: []const []u8, kind: BoxedNumericKind) ![]u8 {
    if (names.len == 0) return gpa.dupe(u8, line);
    const semi = std.mem.lastIndexOfScalar(u8, line, ';') orelse return gpa.dupe(u8, line);
    const eq = std.mem.lastIndexOfScalar(u8, line[0..semi], '=') orelse return gpa.dupe(u8, line);
    if (eq + 1 >= semi) return gpa.dupe(u8, line);

    const lhs = line[0..eq];
    if (!lhsContainsTypedName(lhs, names)) return gpa.dupe(u8, line);

    var rhs_start = eq + 1;
    while (rhs_start < semi and std.ascii.isWhitespace(line[rhs_start])) : (rhs_start += 1) {}
    var rhs_end = semi;
    while (rhs_end > rhs_start and std.ascii.isWhitespace(line[rhs_end - 1])) : (rhs_end -= 1) {}
    if (rhs_end <= rhs_start) return gpa.dupe(u8, line);

    const rhs = line[rhs_start..rhs_end];
    const normalized = try normalizeExpressionForKind(gpa, rhs, kind);
    defer if (normalized) |value| gpa.free(value);
    if (normalized == null) return gpa.dupe(u8, line);

    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        line[0..rhs_start],
        normalized.?,
        line[rhs_end..],
    });
}

pub fn rewriteLongMathMaxAssignments(gpa: std.mem.Allocator, line: []const u8, long_names: []const []u8) ![]u8 {
    if (long_names.len == 0 or std.mem.indexOf(u8, line, "Math.max(") == null) return gpa.dupe(u8, line);

    const semi = std.mem.lastIndexOfScalar(u8, line, ';') orelse return gpa.dupe(u8, line);
    const eq = std.mem.lastIndexOfScalar(u8, line[0..semi], '=') orelse return gpa.dupe(u8, line);
    if (!lhsContainsTypedName(line[0..eq], long_names)) return gpa.dupe(u8, line);

    const call_start = std.mem.indexOfPos(u8, line, eq, "Math.max(") orelse return gpa.dupe(u8, line);
    const open = call_start + "Math.max".len;
    const close = findMatchingParen(line, open) orelse return gpa.dupe(u8, line);
    if (close >= semi) return gpa.dupe(u8, line);

    const args_raw = std.mem.trim(u8, line[(open + 1)..close], " \t");
    var args = try splitCallArguments(gpa, args_raw);
    defer args.deinit(gpa);
    if (args.items.len != 2) return gpa.dupe(u8, line);

    const second = std.mem.trim(u8, args.items[1], " \t");
    if (!isSignedIntegerLiteral(second)) return gpa.dupe(u8, line);
    const second_long = try std.fmt.allocPrint(gpa, "{s}L", .{second});
    defer gpa.free(second_long);
    const replacement = try std.fmt.allocPrint(gpa, "Math.max({s}, {s})", .{
        std.mem.trim(u8, args.items[0], " \t"),
        second_long,
    });
    defer gpa.free(replacement);

    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        line[0..call_start],
        replacement,
        line[close + 1 ..],
    });
}

pub fn rewriteIntegerTypedDoubleAssignments(gpa: std.mem.Allocator, line: []const u8, integer_names: []const []u8) ![]u8 {
    if (integer_names.len == 0 or std.mem.indexOf(u8, line, "ApexStrings.toDouble(") == null) return gpa.dupe(u8, line);
    const semi = std.mem.lastIndexOfScalar(u8, line, ';') orelse return gpa.dupe(u8, line);
    const eq = std.mem.lastIndexOfScalar(u8, line[0..semi], '=') orelse return gpa.dupe(u8, line);
    if (!lhsContainsTypedName(line[0..eq], integer_names)) return gpa.dupe(u8, line);

    var rhs_start = eq + 1;
    while (rhs_start < semi and std.ascii.isWhitespace(line[rhs_start])) : (rhs_start += 1) {}
    var rhs_end = semi;
    while (rhs_end > rhs_start and std.ascii.isWhitespace(line[rhs_end - 1])) : (rhs_end -= 1) {}
    if (rhs_end <= rhs_start) return gpa.dupe(u8, line);
    const rhs = std.mem.trim(u8, line[rhs_start..rhs_end], " \t");
    if (startsWithIgnoreCase(rhs, "ApexStrings.toInteger(") or startsWithIgnoreCase(rhs, "(Integer)")) {
        return gpa.dupe(u8, line);
    }
    const wrapped = try std.fmt.allocPrint(gpa, "ApexStrings.toInteger({s})", .{rhs});
    defer gpa.free(wrapped);
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        line[0..rhs_start],
        wrapped,
        line[rhs_end..],
    });
}

pub fn memberNameLikelyDouble(name: []const u8) bool {
    const value_like = containsFieldKeywordToken(name, "value") and
        (containsFieldKeywordToken(name, "donation") or
            containsFieldKeywordToken(name, "payment") or
            containsFieldKeywordToken(name, "amount"));
    return containsFieldKeywordToken(name, "amount") or
        value_like or
        containsFieldKeywordToken(name, "percent") or
        containsFieldKeywordToken(name, "rate") or
        containsFieldKeywordToken(name, "cost") or
        containsFieldKeywordToken(name, "price");
}

pub fn rewriteLikelyDoubleMemberLiteralAssignments(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    const semi = std.mem.lastIndexOfScalar(u8, line, ';') orelse return gpa.dupe(u8, line);
    const eq = std.mem.lastIndexOfScalar(u8, line[0..semi], '=') orelse return gpa.dupe(u8, line);
    if (eq == 0) return gpa.dupe(u8, line);

    var rhs_start = eq + 1;
    while (rhs_start < semi and std.ascii.isWhitespace(line[rhs_start])) : (rhs_start += 1) {}
    var rhs_end = semi;
    while (rhs_end > rhs_start and std.ascii.isWhitespace(line[rhs_end - 1])) : (rhs_end -= 1) {}
    if (rhs_end <= rhs_start) return gpa.dupe(u8, line);
    const rhs = line[rhs_start..rhs_end];
    const normalized = try normalizeExpressionForKind(gpa, rhs, .double);
    defer if (normalized) |value| gpa.free(value);
    if (normalized == null) return gpa.dupe(u8, line);

    const lhs_trimmed = std.mem.trim(u8, line[0..eq], " \t");
    const dot = std.mem.lastIndexOfScalar(u8, lhs_trimmed, '.') orelse return gpa.dupe(u8, line);
    if (dot + 1 >= lhs_trimmed.len) return gpa.dupe(u8, line);
    const member = leadingIdentifier(lhs_trimmed[dot + 1 ..]) orelse return gpa.dupe(u8, line);
    if (!memberNameLikelyDouble(member)) return gpa.dupe(u8, line);

    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        line[0..rhs_start],
        normalized.?,
        line[rhs_end..],
    });
}

pub fn detectMethodReturnKind(line: []const u8) MethodReturnKind {
    if (!isMethodLikeSignatureLine(line)) return .none;
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return .none;
    const before = std.mem.trim(u8, line[0..open], " \t");
    var tokens = std.mem.tokenizeAny(u8, before, " \t");
    var prev: ?[]const u8 = null;
    var current: ?[]const u8 = null;
    while (tokens.next()) |token| {
        prev = current;
        current = token;
    }
    const return_token = prev orelse return .none;
    if (std.ascii.eqlIgnoreCase(return_token, "Double")) return .double;
    if (std.ascii.eqlIgnoreCase(return_token, "Long")) return .long;
    if (std.ascii.eqlIgnoreCase(return_token, "Integer") or std.ascii.eqlIgnoreCase(return_token, "int")) return .integer;
    return .none;
}

pub fn rewriteMethodReturnLiterals(gpa: std.mem.Allocator, line: []const u8, kind: MethodReturnKind) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (!startsWithWordIgnoreCase(line[i..], "return")) continue;
        if (i > 0 and isIdentifierChar(line[i - 1])) continue;

        var expr_start = i + "return".len;
        while (expr_start < line.len and std.ascii.isWhitespace(line[expr_start])) : (expr_start += 1) {}
        if (expr_start >= line.len) continue;

        const semi = std.mem.indexOfScalarPos(u8, line, expr_start, ';') orelse continue;
        var expr_end = semi;
        while (expr_end > expr_start and std.ascii.isWhitespace(line[expr_end - 1])) : (expr_end -= 1) {}
        if (expr_end <= expr_start) continue;
        const expr = line[expr_start..expr_end];

        const target_kind: BoxedNumericKind = switch (kind) {
            .double => .double,
            .long => .long,
            .integer => .integer,
            .none => continue,
        };
        const normalized = try normalizeExpressionForKind(gpa, expr, target_kind);
        defer if (normalized) |value| gpa.free(value);
        if (normalized == null) continue;

        try out.appendSlice(gpa, line[last_emit..expr_start]);
        try out.appendSlice(gpa, normalized.?);
        changed = true;
        last_emit = expr_end;
        i = semi;
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, line);
    }
    try out.appendSlice(gpa, line[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteBoxedNumericCasts(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    const mappings = [_]struct {
        prefix: []const u8,
        kind: BoxedNumericKind,
    }{
        .{ .prefix = "(Double)", .kind = .double },
        .{ .prefix = "(Long)", .kind = .long },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var changed = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        var matched = false;
        for (mappings) |mapping| {
            if (!startsWithIgnoreCase(line[i..], mapping.prefix)) continue;
            const lit_start = nextNonSpace(line, i + mapping.prefix.len);
            if (lit_start >= line.len) continue;
            var lit_end = lit_start;
            if (line[lit_end] == '+' or line[lit_end] == '-') lit_end += 1;
            while (lit_end < line.len and std.ascii.isDigit(line[lit_end])) : (lit_end += 1) {}
            if (lit_end <= lit_start) continue;
            const literal = line[lit_start..lit_end];
            if (!isSignedIntegerLiteral(literal)) continue;
            const normalized = try normalizeExpressionForKind(gpa, literal, mapping.kind);
            defer if (normalized) |value| gpa.free(value);
            if (normalized == null) continue;

            try out.appendSlice(gpa, line[last_emit..lit_start]);
            try out.appendSlice(gpa, normalized.?);
            last_emit = lit_end;
            i = lit_end - 1;
            changed = true;
            matched = true;
            break;
        }
        if (matched) continue;
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, line);
    }
    try out.appendSlice(gpa, line[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn lhsContainsTypedName(lhs: []const u8, names: []const []u8) bool {
    for (names) |name| {
        if (indexOfWordIgnoreCase(lhs, name) != null) return true;
    }
    return false;
}

pub fn normalizeExpressionForKind(gpa: std.mem.Allocator, expr: []const u8, kind: BoxedNumericKind) !?[]u8 {
    if (try normalizeLiteralForKind(gpa, expr, kind)) |literal| {
        return literal;
    }
    if (kind == .integer) return null;

    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len >= 3 and trimmed[0] == '(') {
        if (findMatchingParen(trimmed, 0)) |close| {
            if (close == trimmed.len - 1) {
                if (try normalizeExpressionForKind(gpa, trimmed[1..close], kind)) |inner| {
                    defer gpa.free(inner);
                    return try std.fmt.allocPrint(gpa, "({s})", .{inner});
                }
            }
        }
    }

    const ternary = findTopLevelTernary(trimmed) orelse return null;
    const condition = std.mem.trim(u8, trimmed[0..ternary.question], " \t");
    const when_true = std.mem.trim(u8, trimmed[(ternary.question + 1)..ternary.colon], " \t");
    const when_false = std.mem.trim(u8, trimmed[(ternary.colon + 1)..], " \t");
    if (condition.len == 0 or when_true.len == 0 or when_false.len == 0) return null;

    const true_literal = try normalizeLiteralForKind(gpa, when_true, kind);
    defer if (true_literal) |value| gpa.free(value);
    const false_literal = try normalizeLiteralForKind(gpa, when_false, kind);
    defer if (false_literal) |value| gpa.free(value);
    if (true_literal == null and false_literal == null) return null;

    return try std.fmt.allocPrint(gpa, "{s} ? {s} : {s}", .{
        condition,
        if (true_literal) |value| value else when_true,
        if (false_literal) |value| value else when_false,
    });
}

pub fn normalizeLiteralForKind(gpa: std.mem.Allocator, literal: []const u8, kind: BoxedNumericKind) !?[]u8 {
    const trimmed = std.mem.trim(u8, literal, " \t");
    if (trimmed.len == 0) return null;

    switch (kind) {
        .double => {
            if (!isSignedIntegerLiteral(trimmed)) return null;
            return try std.fmt.allocPrint(gpa, "{s}.0", .{trimmed});
        },
        .long => {
            if (!isSignedIntegerLiteral(trimmed)) return null;
            return try std.fmt.allocPrint(gpa, "{s}L", .{trimmed});
        },
        .integer => {
            if (!isSignedDecimalZeroLiteral(trimmed)) return null;
            return try std.fmt.allocPrint(gpa, "{s}", .{trimmed[0 .. trimmed.len - 2]});
        },
    }
}

pub fn rewriteDoubleDateTimeDeltaAssignments(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteApexStringsToIntegerIntCast(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const marker = "ApexStrings.toInteger(";
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var state: CompatibilityState = .normal;

    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            if (!startsWithIgnoreCase(text[i..], marker)) {
                i += 1;
                continue;
            }

            const open = i + marker.len - 1;
            const close = findMatchingParen(text, open) orelse {
                i += 1;
                continue;
            };
            const arg_raw = std.mem.trim(u8, text[(open + 1)..close], " \t");
            if (!startsWithIgnoreCase(arg_raw, "(int)")) {
                i = close + 1;
                continue;
            }

            var rest = std.mem.trim(u8, arg_raw["(int)".len..], " \t");
            if (rest.len == 0) {
                i = close + 1;
                continue;
            }
            if (rest[0] == '(' and rest[rest.len - 1] == ')') {
                const inner_close = findMatchingParen(rest, 0) orelse {
                    i = close + 1;
                    continue;
                };
                if (inner_close == rest.len - 1) {
                    rest = std.mem.trim(u8, rest[1 .. rest.len - 1], " \t");
                }
            }
            if (rest.len == 0) {
                i = close + 1;
                continue;
            }

            try out.appendSlice(gpa, text[last_emit..i]);
            try appendFmt(gpa, &out, "ApexStrings.toInteger({s})", .{rest});
            replaced = true;
            last_emit = close + 1;
            i = close + 1;
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteNumericObjectCasts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        const cast_kind = blk: {
            if (std.ascii.eqlIgnoreCase(raw_type, "Double")) break :blk "Double";
            if (std.ascii.eqlIgnoreCase(raw_type, "Long")) break :blk "Long";
            break :blk "";
        };
        if (cast_kind.len == 0) continue;
        if (!isLikelyCastFollowToken(text, close + 1)) continue;

        const rhs_start = nextNonSpace(text, close + 1);
        if (rhs_start >= text.len) continue;
        const rhs_end = findCastOperandEnd(text, rhs_start);
        if (rhs_end <= rhs_start) continue;
        const rhs = std.mem.trim(u8, text[rhs_start..rhs_end], " \t");
        if (rhs.len == 0) continue;
        if (std.mem.indexOf(u8, rhs, ".get(") == null and
            std.mem.indexOf(u8, rhs, ".getAs(") == null and
            std.mem.indexOf(u8, rhs, "ApexSwitch.getAs(") == null)
        {
            continue;
        }
        if (std.mem.indexOf(u8, rhs, "!=") != null or
            std.mem.indexOf(u8, rhs, "==") != null or
            std.mem.indexOf(u8, rhs, " > ") != null or
            std.mem.indexOf(u8, rhs, " < ") != null or
            std.mem.indexOf(u8, rhs, ">=") != null or
            std.mem.indexOf(u8, rhs, "<=") != null)
        {
            continue;
        }

        try out.appendSlice(gpa, text[last_emit..i]);
        if (std.mem.eql(u8, cast_kind, "Double")) {
            try appendFmt(gpa, &out, "ApexStrings.toDouble({s})", .{rhs});
        } else {
            try appendFmt(gpa, &out, "ApexStrings.toLong({s})", .{rhs});
        }
        replaced = true;
        i = rhs_end - 1;
        last_emit = rhs_end;
        in_double = false;
        escaped = false;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteNegatedSizeEqualityArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], "!ApexCollections.size(")) continue;
        const open = i + "!ApexCollections.size".len;
        const close = findMatchingParen(text, open) orelse continue;

        var cmp = close + 1;
        while (cmp < text.len and std.ascii.isWhitespace(text[cmp])) : (cmp += 1) {}
        if (cmp + 1 >= text.len or text[cmp] != '=' or text[cmp + 1] != '=') continue;
        cmp += 2;
        while (cmp < text.len and std.ascii.isWhitespace(text[cmp])) : (cmp += 1) {}
        if (cmp >= text.len or text[cmp] != '0') continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "{s} != 0", .{text[(i + 1) .. close + 1]});
        replaced = true;
        last_emit = cmp + 1;
        i = cmp;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteIntegerCompareToDoubleReturns(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var in_compare_to = false;
    var brace_depth: i32 = 0;
    var changed = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (!in_compare_to and std.mem.indexOf(u8, trimmed, "compareTo(") != null and
            (std.mem.indexOf(u8, trimmed, " Integer ") != null or startsWithIgnoreCase(trimmed, "public Integer ") or startsWithIgnoreCase(trimmed, "public int ")))
        {
            in_compare_to = true;
            brace_depth = 0;
        }

        if (in_compare_to and (std.mem.indexOf(u8, line, "return 1.0;") != null or
            std.mem.indexOf(u8, line, "return -1.0;") != null or
            std.mem.indexOf(u8, line, "return 0.0;") != null))
        {
            var rewritten_line = try replaceLiteralAll(gpa, line, "return 1.0;", "return 1;");
            var next = try replaceLiteralAll(gpa, rewritten_line, "return -1.0;", "return -1;");
            gpa.free(rewritten_line);
            rewritten_line = next;
            next = try replaceLiteralAll(gpa, rewritten_line, "return 0.0;", "return 0;");
            gpa.free(rewritten_line);
            rewritten_line = next;
            defer gpa.free(rewritten_line);
            try out.appendSlice(gpa, rewritten_line);
            changed = true;
        } else {
            try out.appendSlice(gpa, line);
        }

        if (in_compare_to) {
            for (line) |ch| {
                if (ch == '{') brace_depth += 1;
                if (ch == '}') brace_depth -= 1;
            }
            if (brace_depth <= 0) {
                in_compare_to = false;
                brace_depth = 0;
            }
        }
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteIntegerValueOfNumericCasts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn shouldForceIntegerValueOfCast(arg: []const u8) bool {
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

pub fn containsGetAsCall(arg: []const u8) bool {
    var i: usize = 0;
    while (i + 6 <= arg.len) : (i += 1) {
        if (startsWithIgnoreCase(arg[i..], ".getAs(") or
            startsWithIgnoreCase(arg[i..], "ApexSwitch.getAs("))
            return true;
    }
    return false;
}

pub fn rewriteNumericValueOfObjectIdentifiers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
    if (object_names.items.len == 0 and
        std.mem.indexOf(u8, text, ".get(") == null and
        std.mem.indexOf(u8, text, ".getAs(") == null)
    {
        return gpa.dupe(u8, text);
    }

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
            const object_identifier = isSimpleIdentifier(arg_raw) and containsKnownObjectIdentifier(object_names.items, arg_raw);
            const object_accessor =
                std.mem.indexOf(u8, arg_raw, ".get(") != null or
                std.mem.indexOf(u8, arg_raw, ".getAs(") != null;
            if (!object_identifier and !object_accessor) continue;

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
