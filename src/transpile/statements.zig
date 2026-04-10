//! statements — 行単位の式変換エンジン。
//!
//! Apex の各行を解析し、式レベルでの Apex→Java 構文変換を適用する。
//! 文字列リテラル、型キャスト、メソッド呼び出しなどの式変換を担当する。

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const compat = @import("compat.zig");
const renderer = @import("renderer.zig");
const parser = @import("parser.zig");

// Cross-module references
const rewriteApexInstanceofChecks = compat.rewriteApexInstanceofChecks;
const rewriteTriggerOperationEnumConstantCase = compat.rewriteTriggerOperationEnumConstantCase;
const rewriteDatabaseQueryCallsWithBinds = compat.rewriteDatabaseQueryCallsWithBinds;
const rewriteDynamicWhereClauseQueryBinds = compat.rewriteDynamicWhereClauseQueryBinds;
const rewriteFirstOrNullGetAs = compat.rewriteFirstOrNullGetAs;
const rewriteNoArgSortCalls = compat.rewriteNoArgSortCalls;
const rewriteStringKeyedSetMethodCalls = compat.rewriteStringKeyedSetMethodCalls;
const rewriteNoArgCloneCalls = compat.rewriteNoArgCloneCalls;
const rewriteStringInstanceMethodCalls = compat.rewriteStringInstanceMethodCalls;
const rewriteIntegerValueOfNumericCasts = compat.rewriteIntegerValueOfNumericCasts;
const rewriteSObjectGetAsMethodCalls = compat.rewriteSObjectGetAsMethodCalls;
const rewriteIdGetSObjectTypeCalls = compat.rewriteIdGetSObjectTypeCalls;
const rewriteSObjectTypeFieldSetConstants = compat.rewriteSObjectTypeFieldSetConstants;
const rewriteTypeSObjectFieldConstants = compat.rewriteTypeSObjectFieldConstants;
const rewriteTypeSObjectTypeConstants = compat.rewriteTypeSObjectTypeConstants;
const rewriteSystemStatusCodeConstants = compat.rewriteSystemStatusCodeConstants;
const convertSObjectFieldAccess = compat.convertSObjectFieldAccess;
const convertInlineSObjectConstructors = compat.convertInlineSObjectConstructors;
const convertInlineCollectionLiterals = compat.convertInlineCollectionLiterals;
const convertInlineCollectionConstructors = compat.convertInlineCollectionConstructors;
const convertBracketIndexAccess = compat.convertBracketIndexAccess;
const rewriteJsonDeserializeListCasts = compat.rewriteJsonDeserializeListCasts;
const rewriteGenericClassLiterals = compat.rewriteGenericClassLiterals;
const rewriteApexTypeCasts = compat.rewriteApexTypeCasts;
const rewriteNullCoalescingOperator = compat.rewriteNullCoalescingOperator;
const wrapNullSafeComparisons = compat.wrapNullSafeComparisons;
const rewriteApexSafeNavigationOperators = compat.rewriteApexSafeNavigationOperators;
const rewriteStringRelationalComparisons = compat.rewriteStringRelationalComparisons;
const rewriteApexNotEqualsOperator = compat.rewriteApexNotEqualsOperator;
const rewriteApexStrictEqualityOperators = compat.rewriteApexStrictEqualityOperators;
const rewriteDateArithmetic = compat.rewriteDateArithmetic;
const rewriteApexSystemUtilityCalls = compat.rewriteApexSystemUtilityCalls;
const rewriteApexStringUtilityCalls = compat.rewriteApexStringUtilityCalls;
const rewriteQueryGetAsAccess = compat.rewriteQueryGetAsAccess;
const rewriteDatabaseQueryStringConsumers = compat.rewriteDatabaseQueryStringConsumers;
const isLikelySObjectTypeForInstanceof = compat.isLikelySObjectTypeForInstanceof;
const convertInlineSoslQueries = compat.convertInlineSoslQueries;
const rewriteTriggerContextPropertyAccess = compat.rewriteTriggerContextPropertyAccess;
const LogicalStatement = renderer.LogicalStatement;
const NestingState = renderer.NestingState;
const isIntegerLiteral = parser.isIntegerLiteral;
const transpileTypedDeclarationLine = parser.transpileTypedDeclarationLine;
const convertInlineSoqlQueries = compat.convertInlineSoqlQueries;
const isIdSObjectMapType = compat.isIdSObjectMapType;
const isLikelyCustomSObjectTypeName = compat.isLikelyCustomSObjectTypeName;

// types
const SwitchMode = types.SwitchMode;

// util
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const indexOfIgnoreCasePos = util.indexOfIgnoreCasePos;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;
const containsIgnoreCaseSubstring = util.containsIgnoreCaseSubstring;
const indexOfWordIgnoreCase = util.indexOfWordIgnoreCase;
const isIdentifierChar = util.isIdentifierChar;
const isSimpleIdentifier = util.isSimpleIdentifier;
const isSimpleIdentifierOrPath = util.isSimpleIdentifierOrPath;
const leadingIdentifier = util.leadingIdentifier;
const lastIdentifier = util.lastIdentifier;
const baseIdentifierBeforeDot = util.baseIdentifierBeforeDot;
const isLikelyTypeReferenceIdentifier = util.isLikelyTypeReferenceIdentifier;
const looksLikeTypeName = util.looksLikeTypeName;
const isDeclarationModifier = util.isDeclarationModifier;
const normalizeDeclarationModifier = util.normalizeDeclarationModifier;
const findMatchingParen = util.findMatchingParen;
const findMatchingAngle = util.findMatchingAngle;
const findTopLevelAssignmentOperator = util.findTopLevelAssignmentOperator;
const findTopLevelSafeNavigationOperator = util.findTopLevelSafeNavigationOperator;
const findLastTopLevelDot = util.findLastTopLevelDot;
const braceDelta = util.braceDelta;
const splitWhitespace = util.splitWhitespace;
const appendFmt = util.appendFmt;
const appendEscapedJavaStringChar = util.appendEscapedJavaStringChar;
const quoteJavaStringLiteral = util.quoteJavaStringLiteral;
const indexOfSoqlBracketSelect = util.indexOfSoqlBracketSelect;
const isControlFlowLine = util.isControlFlowLine;
const isDoWhileTailLine = util.isDoWhileTailLine;
const splitTrailingIdentifierAtTopLevel = util.splitTrailingIdentifierAtTopLevel;
const parseIndexedLvalue = util.parseIndexedLvalue;
const parseSObjectFieldLvalue = util.parseSObjectFieldLvalue;
const parseJavaKeywordMemberLvalue = util.parseJavaKeywordMemberLvalue;
const isLikelySObjectFieldName = util.isLikelySObjectFieldName;
const isJavaReservedWord = util.isJavaReservedWord;
const isNewKeywordAt = util.isNewKeywordAt;
const nextNonSpace = util.nextNonSpace;
const prevNonSpace = util.prevNonSpace;

pub fn inferUnsupportedReason(statement: []const u8) []const u8 {
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

pub fn shouldFlushLogicalStatement(statement: []const u8) bool {
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

pub fn stripApexCommentsFromLine(
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

pub fn scanNestingState(text: []const u8) NestingState {
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

pub fn isControlBlockHeader(statement: []const u8) bool {
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

pub fn looksLikeControlHeaderWithoutBrace(statement: []const u8) bool {
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

pub fn transpileExecutableLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    return transpileExecutableLineWithContext(gpa, line, null, .value, null);
}

pub fn transpileExecutableLineWithContext(
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

pub fn transpileControlFlowLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    return transpileControlFlowLineWithContext(gpa, line, null, .value, null);
}

pub fn transpileControlFlowLineWithContext(
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

pub fn transpileInlineControlFlowStatement(
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

pub fn normalizeLeadingControlKeywordCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn transpileScopedInvocationBlockHeader(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub fn transpileSoqlLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub fn isSoqlLikelySingleRow(query_segment: []const u8) bool {
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

pub fn isSoqlCountQuery(query_segment: []const u8) bool {
    return startsWithIgnoreCase(query_segment, "SELECT COUNT(");
}

pub fn isLikelyJavaCollectionType(java_type: []const u8) bool {
    const trimmed = std.mem.trim(u8, java_type, " \t");
    if (trimmed.len == 0) return false;
    return startsWithIgnoreCase(trimmed, "List<") or
        startsWithIgnoreCase(trimmed, "Set<") or
        startsWithIgnoreCase(trimmed, "Map<");
}

pub fn normalizeSoqlQueryForEmulation(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
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

pub fn buildDatabaseQueryCall(
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

pub fn buildDatabaseCountQueryCall(
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

pub fn collectSoqlBindNames(gpa: std.mem.Allocator, query_segment: []const u8) !std.ArrayList([]const u8) {
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

pub fn isSimpleBindReference(bind_name: []const u8) bool {
    if (bind_name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(bind_name, "new")) return false;
    if (!isSimpleIdentifierOrPath(bind_name)) return false;
    return true;
}

pub fn isSoqlBindNameChar(ch: u8) bool {
    return isIdentifierChar(ch) or std.ascii.isDigit(ch) or ch == '.';
}

pub fn convertBindReferenceToJava(gpa: std.mem.Allocator, bind_name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, bind_name, " \t");
    if (!isSimpleIdentifierOrPath(trimmed)) return gpa.dupe(u8, trimmed);
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
        var parts = std.mem.tokenizeScalar(u8, trimmed, '.');
        const root_part = parts.next() orelse return gpa.dupe(u8, trimmed);
        if (isLikelyTypeReferenceIdentifier(root_part)) {
            var static_out: std.ArrayList(u8) = .empty;
            errdefer static_out.deinit(gpa);
            try static_out.appendSlice(gpa, root_part);

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
        try out.appendSlice(gpa, root_part);

        var last_part: []const u8 = root_part;
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

pub fn isLikelyBindMethodReferenceName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(name, "trim")) return true;
    if (startsWithIgnoreCase(name, "get") and name.len > 3 and std.ascii.isUpper(name[3])) return true;
    return false;
}

pub fn transpileDmlLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub const ApexDmlAccessMode = enum {
    none,
    user,
    system,
};

pub const ParsedDmlPayload = struct {
    payload: []const u8,
    mode: ApexDmlAccessMode,
};

pub fn parseApexDmlAccessMode(raw_payload: []const u8) ParsedDmlPayload {
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

pub fn buildDatabaseDmlCallWithMode(
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

pub fn transpileAssertionLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub fn transpileSystemDebugLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub fn transpileCollectionDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub fn transpileGenericStatementLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub fn transpileSafeNavigationInvocationStatement(gpa: std.mem.Allocator, statement_no_semicolon: []const u8) !?[]u8 {
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

pub fn findTopLevelPlusAssignmentOperator(text: []const u8) ?usize {
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

pub fn maybeWrapSingleQueryAssignment(
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

pub fn maybeUnwrapCollectionQueryResult(
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

pub fn maybeWrapSingleQueryResult(gpa: std.mem.Allocator, rhs: []const u8) ![]u8 {
    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    if (!startsWithIgnoreCase(trimmed_rhs, "Database.query(") and
        !startsWithIgnoreCase(trimmed_rhs, "Database.queryWithBinds("))
    {
        return gpa.dupe(u8, rhs);
    }
    return std.fmt.allocPrint(gpa, "ApexCollections.firstOrNull({s})", .{trimmed_rhs});
}

pub fn looksLikeCollectionVariableName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0) return false;
    if (endsWithIgnoreCase(trimmed, "List")) return true;
    if (endsWithIgnoreCase(trimmed, "Map")) return true;
    if (endsWithIgnoreCase(trimmed, "Set")) return true;
    return std.ascii.toLower(trimmed[trimmed.len - 1]) == 's';
}

pub fn coerceLiteralForAssignmentContext(
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

pub const CollectionKind = enum {
    list,
    map,
    set,
};

pub const CollectionDeclaration = struct {
    kind: CollectionKind,
    java_type: []u8,
    variable_name: []u8,
};

pub const TypedVariableDeclaration = struct {
    declaration_head: []u8,
    variable_name: []u8,
    java_type: []u8,
};

pub fn parseCollectionDeclaration(gpa: std.mem.Allocator, left: []const u8) !?CollectionDeclaration {
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

pub fn parseTypedVariableDeclaration(
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

pub fn transpileCollectionInitializer(
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

pub fn convertApexTypeList(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
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

pub fn convertApexType(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
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

pub fn splitTypeArguments(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!std.ArrayList([]const u8) {
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

pub fn normalizeScalarTypeName(raw: []const u8) []const u8 {
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

pub fn normalizeQualifiedTypeName(raw: []const u8) ?[]const u8 {
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

pub fn isKnownSchemaHelperTypeName(raw: []const u8) bool {
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

pub fn collectionKindFromName(type_name: []const u8) ?CollectionKind {
    if (std.ascii.eqlIgnoreCase(type_name, "List")) return .list;
    if (std.ascii.eqlIgnoreCase(type_name, "Map")) return .map;
    if (std.ascii.eqlIgnoreCase(type_name, "Set")) return .set;
    return null;
}

pub fn collectionInterfaceName(kind: CollectionKind) []const u8 {
    return switch (kind) {
        .list => "List",
        .map => "Map",
        .set => "Set",
    };
}

pub fn collectionImplName(kind: CollectionKind) []const u8 {
    return switch (kind) {
        .list => "ArrayList",
        .map => "LinkedHashMap",
        .set => "LinkedHashSet",
    };
}

pub fn splitCallArguments(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
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

pub fn splitMergeArguments(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
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

pub fn findFirstTopLevelWhitespace(text: []const u8) ?usize {
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

pub fn hasTopLevelComma(text: []const u8) bool {
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

pub fn splitTopLevelCommaExpressions(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
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
    var token_start: usize = 0;

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
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    const piece = std.mem.trim(u8, trimmed[token_start..i], " \t");
                    if (piece.len > 0) try out.append(gpa, piece);
                    token_start = i + 1;
                }
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, trimmed[token_start..], " \t");
    if (tail.len > 0) try out.append(gpa, tail);
    return out;
}

pub fn splitTopLevelWhitespaceExpressions(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
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

pub fn buildSystemAssertCall(gpa: std.mem.Allocator, method_name: []const u8, args: []const []const u8) ![]u8 {
    return buildAssertCall(gpa, "SystemAssert", method_name, args);
}

pub fn buildApexAssertCall(gpa: std.mem.Allocator, method_name: []const u8, args: []const []const u8) ![]u8 {
    return buildAssertCall(gpa, "ApexAssert", method_name, args);
}

pub fn normalizeApexAssertTypeArg(gpa: std.mem.Allocator, raw_arg: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_arg, " \t");
    if (trimmed.len < 7) return try gpa.dupe(u8, raw_arg);
    if (!std.mem.endsWith(u8, trimmed, ".class")) return try gpa.dupe(u8, raw_arg);

    const type_expr = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - ".class".len], " \t");
    const simple_name = extractSimpleTypeName(type_expr) orelse return try gpa.dupe(u8, raw_arg);
    return try std.fmt.allocPrint(gpa, "\"{s}\"", .{simple_name});
}

pub fn extractSimpleTypeName(type_expr_raw: []const u8) ?[]const u8 {
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

pub fn buildAssertCall(gpa: std.mem.Allocator, class_name: []const u8, method_name: []const u8, args: []const []const u8) ![]u8 {
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

pub fn convertApexExpressionToJava(gpa: std.mem.Allocator, expression: []const u8) anyerror![]u8 {
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

pub fn rewriteCommonJavaMethodCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const patterns = [_]struct {
        from: []const u8,
        to: []const u8,
    }{
        .{ .from = "Integer.valueof(", .to = "Integer.valueOf(" },
        .{ .from = "Long.valueof(", .to = "Long.valueOf(" },
        .{ .from = "Double.valueof(", .to = "Double.valueOf(" },
        .{ .from = "String.valueof(", .to = "ApexStrings.valueOf(" },
        .{ .from = "ApexCollections.newlistWithSize(", .to = "ApexCollections.newListWithSize(" },
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

pub fn rewriteKnownQualifiedTypeCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteMathModCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn normalizeApexDoWhileTailLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

pub fn normalizeForHeaderTypes(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
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

pub fn normalizeApexSwitchHeader(gpa: std.mem.Allocator, line: []const u8, mode: SwitchMode) ![]u8 {
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

pub const ApexWhenTypePattern = struct {
    type_name: []const u8,
    binding_name: []const u8,
};

pub fn parseApexWhenTypePattern(gpa: std.mem.Allocator, text: []const u8) !?ApexWhenTypePattern {
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

pub fn normalizeApexWhenLine(
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

pub fn parseSwitchSubjectExpression(line: []const u8) ?[]const u8 {
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

pub fn detectSwitchMode(
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

// ---------------------------------------------------------------------------
// Tests (moved from root.zig)
// ---------------------------------------------------------------------------

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

    const sized_array_decl = try transpileGenericStatementLine(
        gpa,
        "List<Id> fixedSearchResults = new Id[contactSize];",
    );
    defer if (sized_array_decl) |value| gpa.free(value);
    try std.testing.expect(sized_array_decl != null);
    try std.testing.expectEqualStrings(
        "List<String> fixedSearchResults = ApexCollections.newListWithSize(contactSize);",
        sized_array_decl.?,
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

    const sized_array_expr = try convertApexExpressionToJava(gpa, "new Id[contactSize]");
    defer gpa.free(sized_array_expr);
    try std.testing.expectEqualStrings(
        "ApexCollections.newListWithSize(contactSize)",
        sized_array_expr,
    );
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

test "convertApexExpressionToJava rewrites date relational comparisons with ApexCompare" {
    const gpa = std.testing.allocator;
    const input = "closeDate <= Date.newInstance(2019, 11, 1)";

    const rewritten = try convertApexExpressionToJava(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexCompare.lte(closeDate, Date.newInstance(2019, 11, 1))") != null);
}
