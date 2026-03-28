const line_and_expr = @import("../line_and_expr.zig");
const std = @import("std");
const util = @import("../util.zig");

const getas = @import("getas.zig");
const helpers = @import("helpers.zig");

const CompatibilityState = getas.CompatibilityState;
const rewriteSObjectGetAsLengthFallback = getas.rewriteSObjectGetAsLengthFallback;
const containsGetAsLikeCall = helpers.containsGetAsLikeCall;
const containsKnownObjectIdentifier = helpers.containsKnownObjectIdentifier;
const extractTypedVariableName = helpers.extractTypedVariableName;
const findExpressionEnd = helpers.findExpressionEnd;
const findLeftOperandStart = helpers.findLeftOperandStart;
const findMemberAccessBaseStart = helpers.findMemberAccessBaseStart;
const findPreviousNonWhitespace = helpers.findPreviousNonWhitespace;
const findSimpleEqualityOperator = helpers.findSimpleEqualityOperator;
const findTopLevelLogicalOperator = helpers.findTopLevelLogicalOperator;
const findTopLevelNullCoalescingOperator = helpers.findTopLevelNullCoalescingOperator;
const findTopLevelRelationalMatch = helpers.findTopLevelRelationalMatch;
const findTopLevelTernary = helpers.findTopLevelTernary;
const isLikelyCastFollowToken = helpers.isLikelyCastFollowToken;
const isLikelyCastStart = helpers.isLikelyCastStart;
const isLikelyCastType = helpers.isLikelyCastType;
const isLikelyDateishComparisonOperand = helpers.isLikelyDateishComparisonOperand;
const isLikelySObjectTypeForInstanceof = helpers.isLikelySObjectTypeForInstanceof;
const isLikelyStringishComparisonOperand = helpers.isLikelyStringishComparisonOperand;
const isNumericLiteral = helpers.isNumericLiteral;
const isSignedIntegerLiteral = helpers.isSignedIntegerLiteral;

const appendFmt = util.appendFmt;
const convertApexType = line_and_expr.convertApexType;
const findMatchingParen = util.findMatchingParen;
const isIdentifierChar = util.isIdentifierChar;
const looksLikeTypeName = util.looksLikeTypeName;
const nextNonSpace = util.nextNonSpace;
const splitTopLevelCommaExpressions = line_and_expr.splitTopLevelCommaExpressions;
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;

pub fn rewriteBooleanEqualsIsEmptyArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const negated = startsWithIgnoreCase(text[i..], "!Boolean.TRUE.equals(");
        const prefix = if (negated) "!Boolean.TRUE.equals(" else if (startsWithIgnoreCase(text[i..], "Boolean.TRUE.equals(")) "Boolean.TRUE.equals(" else "";
        if (prefix.len == 0) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;

        const open = i + prefix.len - 1;
        const close = findMatchingParen(text, open) orelse continue;
        const expr = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (expr.len == 0) continue;
        if (!startsWithIgnoreCase(text[close + 1 ..], ".isEmpty()")) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "ApexCollections.size({s}) {s} 0", .{ expr, if (negated) "!=" else "==" });
        replaced = true;
        last_emit = close + 1 + ".isEmpty()".len;
        i = last_emit - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteBooleanEqualsTrailingInvocationArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const prefix = if (startsWithIgnoreCase(text[i..], "Boolean.TRUE.equals("))
            "Boolean.TRUE.equals("
        else if (startsWithIgnoreCase(text[i..], "Boolean.FALSE.equals("))
            "Boolean.FALSE.equals("
        else
            "";
        if (prefix.len == 0) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;

        const open = i + prefix.len - 1;
        const close = findMatchingParen(text, open) orelse continue;
        const invoke_start = nextNonSpace(text, close + 1);
        if (invoke_start + 1 >= text.len) continue;
        if (text[invoke_start] != '(' or text[invoke_start + 1] != ')') continue;

        try out.appendSlice(gpa, text[last_emit..invoke_start]);
        replaced = true;
        last_emit = invoke_start + 2;
        i = last_emit - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn isComparisonRightOperandContext(text: []const u8, expr_start: usize) bool {
    const prev = findPreviousNonWhitespace(text, expr_start) orelse return false;
    const ch = text[prev];
    if (ch == '>' or ch == '<') return true;
    if (ch == '=') {
        if (prev > 0 and (text[prev - 1] == '>' or text[prev - 1] == '<' or text[prev - 1] == '=' or text[prev - 1] == '!')) {
            return true;
        }
    }
    return false;
}

pub fn rewriteBooleanGetOperands(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        const call_start = blk: {
            if (startsWithIgnoreCase(text[i..], ".getAs(")) break :blk i;
            if (startsWithIgnoreCase(text[i..], ".get(")) break :blk i;
            break :blk null;
        };
        if (call_start == null) continue;

        const open = if (startsWithIgnoreCase(text[call_start.?..], ".getAs("))
            call_start.? + ".getAs".len
        else
            call_start.? + ".get".len;
        const close = findMatchingParen(text, open) orelse continue;
        const after_call = nextNonSpace(text, close + 1);
        if (after_call < text.len and text[after_call] == '.') continue;
        const base_start = findMemberAccessBaseStart(text, call_start.?) orelse continue;
        const call_text = text[base_start .. close + 1];

        var replace_start = base_start;
        var replace_end = close + 1;
        var replacement: ?[]u8 = null;
        const next_idx = nextNonSpace(text, close + 1);
        const right_of_comparison = isComparisonRightOperandContext(text, base_start);

        if (next_idx + 1 < text.len and text[next_idx] == '=' and text[next_idx + 1] == '=') {
            const after_eq = nextNonSpace(text, next_idx + 2);
            if (startsWithWordIgnoreCase(text[after_eq..], "true")) {
                replacement = try std.fmt.allocPrint(gpa, "Boolean.TRUE.equals({s})", .{call_text});
                replace_end = after_eq + 4;
            } else if (startsWithWordIgnoreCase(text[after_eq..], "false")) {
                replacement = try std.fmt.allocPrint(gpa, "Boolean.FALSE.equals({s})", .{call_text});
                replace_end = after_eq + 5;
            } else {
                continue;
            }
        } else if (next_idx + 1 < text.len and text[next_idx] == '!' and text[next_idx + 1] == '=') {
            const after_ne = nextNonSpace(text, next_idx + 2);
            if (startsWithWordIgnoreCase(text[after_ne..], "true")) {
                replacement = try std.fmt.allocPrint(gpa, "!Boolean.TRUE.equals({s})", .{call_text});
                replace_end = after_ne + 4;
            } else if (startsWithWordIgnoreCase(text[after_ne..], "false")) {
                replacement = try std.fmt.allocPrint(gpa, "!Boolean.FALSE.equals({s})", .{call_text});
                replace_end = after_ne + 5;
            } else {
                continue;
            }
        } else if (next_idx < text.len and (text[next_idx] == '<' or text[next_idx] == '>')) {
            continue;
        }

        if (replacement == null and right_of_comparison) continue;

        const prev_idx = findPreviousNonWhitespace(text, base_start);
        if (replacement == null) {
            if (prev_idx) |prev| {
                if (text[prev] == '!' and (prev == 0 or text[prev - 1] != '=')) {
                    replacement = try std.fmt.allocPrint(gpa, "!Boolean.TRUE.equals({s})", .{call_text});
                    replace_start = prev;
                } else if (text[prev] == '|' and prev > 0 and text[prev - 1] == '|') {
                    replacement = try std.fmt.allocPrint(gpa, "Boolean.TRUE.equals({s})", .{call_text});
                } else if (text[prev] == '&' and prev > 0 and text[prev - 1] == '&') {
                    replacement = try std.fmt.allocPrint(gpa, "Boolean.TRUE.equals({s})", .{call_text});
                }
            }
        }

        if (replacement == null) {
            if (next_idx + 1 < text.len and text[next_idx] == '|' and text[next_idx + 1] == '|') {
                replacement = try std.fmt.allocPrint(gpa, "Boolean.TRUE.equals({s})", .{call_text});
            } else if (next_idx + 1 < text.len and text[next_idx] == '&' and text[next_idx + 1] == '&') {
                replacement = try std.fmt.allocPrint(gpa, "Boolean.TRUE.equals({s})", .{call_text});
            }
        }

        if (replacement == null) continue;

        try out.appendSlice(gpa, text[last_emit..replace_start]);
        try out.appendSlice(gpa, replacement.?);
        gpa.free(replacement.?);
        replaced = true;
        last_emit = replace_end;
        i = replace_end - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn isBooleanEqualsCallLiteral(text: []const u8) bool {
    return startsWithIgnoreCase(text, "Boolean.TRUE.equals(") or
        startsWithIgnoreCase(text, "Boolean.FALSE.equals(");
}

pub fn isBooleanLiteralAt(text: []const u8, from: usize) bool {
    if (from >= text.len) return false;
    return startsWithWordIgnoreCase(text[from..], "true") or startsWithWordIgnoreCase(text[from..], "false");
}

pub fn rewriteBooleanEqualsComparisonArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                if (!isBooleanEqualsCallLiteral(text[i..])) {
                    i += 1;
                    continue;
                }
                if (i > 0 and isIdentifierChar(text[i - 1])) {
                    i += 1;
                    continue;
                }

                const open = i + "Boolean.TRUE.equals".len;
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };
                const inner = std.mem.trim(u8, text[(open + 1)..close], " \t");
                if (inner.len == 0) {
                    i = close + 1;
                    continue;
                }

                var should_unwrap = false;
                const next_idx = nextNonSpace(text, close + 1);
                if (next_idx + 1 < text.len and text[next_idx] == '=' and text[next_idx + 1] == '=') {
                    const rhs_start = nextNonSpace(text, next_idx + 2);
                    if (!isBooleanLiteralAt(text, rhs_start) and !isBooleanEqualsCallLiteral(text[rhs_start..])) {
                        should_unwrap = true;
                    }
                } else if (next_idx + 1 < text.len and text[next_idx] == '!' and text[next_idx + 1] == '=') {
                    const rhs_start = nextNonSpace(text, next_idx + 2);
                    if (!isBooleanLiteralAt(text, rhs_start) and !isBooleanEqualsCallLiteral(text[rhs_start..])) {
                        should_unwrap = true;
                    }
                }

                if (!should_unwrap) {
                    const prev_idx = findPreviousNonWhitespace(text, i);
                    if (prev_idx) |prev| {
                        if (text[prev] == '=' and prev > 0 and (text[prev - 1] == '=' or text[prev - 1] == '!')) {
                            const lhs_end = findPreviousNonWhitespace(text, prev - 1);
                            const lhs_start = if (lhs_end) |end_idx| blk: {
                                var start_idx = end_idx;
                                while (start_idx > 0 and isIdentifierChar(text[start_idx - 1])) : (start_idx -= 1) {}
                                break :blk start_idx;
                            } else null;
                            if (lhs_end == null or lhs_start == null or !isBooleanLiteralAt(text, lhs_start.?)) {
                                should_unwrap = true;
                            }
                        }
                    }
                }

                if (!should_unwrap) {
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

pub fn rewriteLinewiseRelationalComparisons(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const relational = try rewriteStringRelationalComparisons(gpa, line);
        defer gpa.free(relational);
        const null_safe = try wrapNullSafeComparisons(gpa, relational);
        defer gpa.free(null_safe);

        if (!std.mem.eql(u8, null_safe, line)) changed = true;
        try out.appendSlice(gpa, null_safe);
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteBrokenApexEqualsTernaryComparisons(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "ApexEquals.eq";
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
                if (args.items.len != 2) {
                    i = close + 1;
                    continue;
                }

                const lhs = std.mem.trim(u8, args.items[0], " \t");
                const rhs = std.mem.trim(u8, args.items[1], " \t");
                const ternary = findTopLevelTernary(rhs) orelse {
                    i = close + 1;
                    continue;
                };

                const cond = std.mem.trim(u8, rhs[0..ternary.question], " \t");
                if (!isSignedIntegerLiteral(cond) and
                    !std.ascii.eqlIgnoreCase(cond, "true") and
                    !std.ascii.eqlIgnoreCase(cond, "false"))
                {
                    i = close + 1;
                    continue;
                }

                const when_true = std.mem.trim(u8, rhs[(ternary.question + 1)..ternary.colon], " \t");
                const when_false = std.mem.trim(u8, rhs[(ternary.colon + 1)..], " \t");
                if (lhs.len == 0 or when_true.len == 0 or when_false.len == 0) {
                    i = close + 1;
                    continue;
                }

                const replacement = try std.fmt.allocPrint(
                    gpa,
                    "(ApexEquals.eq({s}, {s}) ? {s} : {s})",
                    .{ lhs, cond, when_true, when_false },
                );
                defer gpa.free(replacement);

                try out.appendSlice(gpa, text[last_emit..i]);
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

pub fn rewriteStringCastBooleanEqualsArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                if (!startsWithIgnoreCase(text[i..], "(String)")) {
                    i += 1;
                    continue;
                }
                var cursor = i + "(String)".len;
                while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}

                const true_marker = "Boolean.TRUE.equals(";
                const false_marker = "Boolean.FALSE.equals(";
                const marker = if (startsWithIgnoreCase(text[cursor..], true_marker))
                    true_marker
                else if (startsWithIgnoreCase(text[cursor..], false_marker))
                    false_marker
                else {
                    i += 1;
                    continue;
                };

                const open = cursor + marker.len - 1;
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };
                const inner = std.mem.trim(u8, text[(open + 1)..close], " \t");
                if (inner.len == 0) {
                    i = close + 1;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..i]);
                try appendFmt(gpa, &out, "(String) {s}", .{inner});
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

pub fn rewriteValueOfGetNameArtifacts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "ApexStrings.valueOf";
    const suffix = ".getName()";
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

                var after = close + 1;
                while (after < text.len and std.ascii.isWhitespace(text[after])) : (after += 1) {}
                if (!startsWithIgnoreCase(text[after..], suffix)) {
                    i = close + 1;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..i]);
                try out.appendSlice(gpa, text[i .. close + 1]);
                replaced = true;
                last_emit = after + suffix.len;
                i = last_emit;
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

pub fn rewriteDateArithmetic(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteApexStrictEqualityOperators(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteApexNotEqualsOperator(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteSystemStatusCodeConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteStringRelationalComparisons(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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
    const lhs_stringish = isLikelyStringishComparisonOperand(lhs);
    const rhs_stringish = isLikelyStringishComparisonOperand(rhs);
    if (lhs_stringish or rhs_stringish) {
        const predicate = switch (op_match.op) {
            .gt => "> 0",
            .lt => "< 0",
            .gte => ">= 0",
            .lte => "<= 0",
        };
        return std.fmt.allocPrint(gpa, "ApexStrings.compareTo({s}, {s}) {s}", .{ lhs, rhs, predicate });
    }
    if (!isLikelyDateishComparisonOperand(lhs) and !isLikelyDateishComparisonOperand(rhs)) {
        return gpa.dupe(u8, text);
    }

    const compare_method = switch (op_match.op) {
        .gt => "gt",
        .lt => "lt",
        .gte => "gte",
        .lte => "lte",
    };
    return std.fmt.allocPrint(gpa, "ApexCompare.{s}({s}, {s})", .{ compare_method, lhs, rhs });
}

pub fn rewriteNestedParenStringRelationalComparisons(gpa: std.mem.Allocator, text: []const u8) anyerror!?[]u8 {
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

pub fn rewriteTernaryStringRelationalComparisons(gpa: std.mem.Allocator, text: []const u8) anyerror!?[]u8 {
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

pub fn wrapNullSafeComparisons(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub const SafeNavigationRewrite = struct {
    text: []u8,
    replaced: bool,
};

pub fn rewriteApexSafeNavigationOperators(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, text);
    while (true) {
        const rewrite = try rewriteFirstApexSafeNavigationOperator(gpa, current);
        gpa.free(current);
        current = rewrite.text;
        if (!rewrite.replaced) return current;
    }
}

pub fn rewriteFirstApexSafeNavigationOperator(gpa: std.mem.Allocator, text: []const u8) !SafeNavigationRewrite {
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

pub fn findSafeNavigationLeftStart(text: []const u8, op_pos: usize) usize {
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

pub fn isSafeNavigationBoundaryChar(ch: u8) bool {
    return switch (ch) {
        ',', ';', ':', '+', '-', '*', '/', '%', '&', '|', '^', '=', '!', '<', '>', '?' => true,
        else => false,
    };
}

pub fn rewriteNullCoalescingOperator(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteApexTypeCasts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteObjectEqualityWithDeclaredObjects(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteObjectEqualityLine(gpa: std.mem.Allocator, line: []const u8, object_names: []const []u8) ![]u8 {
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

    // Fallback: rewrite equality operators in for-each, else-if, and assignment statements.
    // Check for 'else if' or 'for' patterns not caught above.
    if (startsWithWordIgnoreCase(trimmed, "else") or startsWithWordIgnoreCase(trimmed, "for")) {
        if (std.mem.indexOfScalar(u8, trimmed, '(')) |open| {
            if (findMatchingParen(trimmed, open)) |close| {
                if (close > open + 1) {
                    var condition = trimmed[open + 1 .. close];
                    // For for-each loops (Type var : expr), only rewrite the expr part
                    var for_each_prefix: []const u8 = "";
                    if (startsWithWordIgnoreCase(trimmed, "for")) {
                        if (std.mem.indexOf(u8, condition, " : ")) |colon_pos| {
                            for_each_prefix = condition[0 .. colon_pos + " : ".len];
                            condition = condition[colon_pos + " : ".len ..];
                        }
                    }
                    const rewritten = try rewriteEqualityOperators(gpa, condition, object_names);
                    defer gpa.free(rewritten);
                    if (!std.mem.eql(u8, rewritten, condition)) {
                        const leading = line[0 .. @intFromPtr(trimmed.ptr) - @intFromPtr(line.ptr)];
                        var out: std.ArrayList(u8) = .empty;
                        errdefer out.deinit(gpa);
                        try out.appendSlice(gpa, leading);
                        try out.appendSlice(gpa, trimmed[0 .. open + 1]);
                        try out.appendSlice(gpa, for_each_prefix);
                        try out.appendSlice(gpa, rewritten);
                        try out.append(gpa, ')');
                        if (close + 1 < trimmed.len) try out.appendSlice(gpa, trimmed[close + 1 ..]);
                        return out.toOwnedSlice(gpa);
                    }
                }
            }
        }
    }

    // Fallback: rewrite == / != in variable assignments, ternary, etc.
    // Skip lines already containing ApexEquals (rewritten by earlier passes).
    if ((std.mem.indexOf(u8, trimmed, " == ") != null or std.mem.indexOf(u8, trimmed, " != ") != null) and
        std.mem.indexOf(u8, trimmed, "ApexEquals") == null)
    {
        const rewritten = try rewriteEqualityOperators(gpa, trimmed, object_names);
        defer gpa.free(rewritten);
        if (!std.mem.eql(u8, rewritten, trimmed)) {
            const leading = line[0 .. @intFromPtr(trimmed.ptr) - @intFromPtr(line.ptr)];
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.appendSlice(gpa, leading);
            try out.appendSlice(gpa, rewritten);
            return out.toOwnedSlice(gpa);
        }
    }

    return gpa.dupe(u8, line);
}

pub fn rewriteEqualityOperators(gpa: std.mem.Allocator, condition: []const u8, object_names: []const []u8) ![]u8 {
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

        // Skip deeply nested parens (depth > 1) to avoid breaking method call arguments.
        // Allow depth 0 (top-level) and depth 1 (inside one level of parens, e.g. assertTrue(a == b)).
        if (paren_depth > 1) continue;

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

        // Skip if the right operand contains a ternary operator (e.g. x == EnumVal ? a : b).
        // The equality rewriter incorrectly includes ternary branches in the right operand.
        if (std.mem.indexOfScalar(u8, right_raw, '?') != null) continue;

        // Skip if either side is null
        if (std.mem.eql(u8, left_raw, "null") or std.mem.eql(u8, right_raw, "null")) continue;
        if (startsWithWordIgnoreCase(right_raw, "null")) continue;

        const left_has_object = containsKnownObjectIdentifier(object_names, left_raw);
        const right_has_object = containsKnownObjectIdentifier(object_names, right_raw);
        const left_has_get_as = containsGetAsLikeCall(left_raw);
        const right_has_get_as = containsGetAsLikeCall(right_raw);
        const left_has_call = std.mem.indexOfScalar(u8, left_raw, '(') != null;
        const right_has_call = std.mem.indexOfScalar(u8, right_raw, '(') != null;
        if (!left_has_object and !right_has_object and !left_has_get_as and !right_has_get_as and !left_has_call and !right_has_call) continue;

        // Skip if either side is true/false unless this is an object comparison.
        if (!left_has_object and !right_has_object and !left_has_get_as and !right_has_get_as) {
            if (std.mem.eql(u8, left_raw, "true") or std.mem.eql(u8, left_raw, "false")) continue;
            if (std.mem.eql(u8, right_raw, "true") or std.mem.eql(u8, right_raw, "false")) continue;
            if (isNumericLiteral(left_raw) or isNumericLiteral(right_raw)) continue;
        }

        // Extract the real left operand from last_emit (might include && or ||)
        const left_start = findLeftOperandStart(condition, i);
        const left_operand = std.mem.trim(u8, condition[left_start..i], " \t");
        if (left_operand.len == 0) continue;
        if (std.mem.eql(u8, left_operand, "null")) continue;
        if (isNumericLiteral(left_operand) and !containsKnownObjectIdentifier(object_names, left_operand) and !containsGetAsLikeCall(left_operand)) continue;

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

pub fn rewriteSimpleObjectEqualityExpression(
    gpa: std.mem.Allocator,
    expr: []const u8,
    object_names: []const []u8,
) !?[]u8 {
    if (std.mem.indexOf(u8, expr, "&&") != null or std.mem.indexOf(u8, expr, "||") != null) return null;
    const op = findSimpleEqualityOperator(expr) orelse return null;
    const lhs = std.mem.trim(u8, expr[0..op.start], " \t");
    const rhs = std.mem.trim(u8, expr[(op.start + 2)..], " \t");
    if (lhs.len == 0 or rhs.len == 0) return null;
    if (std.mem.eql(u8, lhs, "null") or std.mem.eql(u8, rhs, "null")) return null;
    if (startsWithWordIgnoreCase(rhs, "null")) return null;
    if (!containsKnownObjectIdentifier(object_names, lhs) and
        !containsKnownObjectIdentifier(object_names, rhs) and
        !containsGetAsLikeCall(lhs) and
        !containsGetAsLikeCall(rhs))
        return null;

    const method = if (op.is_ne) "ApexEquals.ne" else "ApexEquals.eq";
    return try std.fmt.allocPrint(gpa, "{s}({s}, {s})", .{ method, lhs, rhs });
}

pub fn rewriteApexInstanceofChecks(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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

pub fn isTypeNameTokenChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

pub fn findInstanceofLhsStart(text: []const u8, lhs_end: usize) ?usize {
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

pub fn isInstanceofKeywordAt(text: []const u8, index: usize) bool {
    const keyword = "instanceof";
    if (index + keyword.len > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[index .. index + keyword.len], keyword)) return false;
    if (index > 0 and isTypeNameTokenChar(text[index - 1])) return false;
    if (index + keyword.len < text.len and isTypeNameTokenChar(text[index + keyword.len])) return false;
    return true;
}

pub fn isInstanceofOperandBoundary(ch: u8) bool {
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
