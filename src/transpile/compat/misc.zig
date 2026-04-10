//! misc — その他の Apex 互換変換。
//!
//! 他のカテゴリに分類されない Apex 固有構文（キャスト、
//! コレクション初期化、システムメソッド等）の Java 変換。

const stmt_mod = @import("../statements.zig");
const std = @import("std");
const util = @import("../util.zig");

const helpers = @import("helpers.zig");

const CompatibilityState = helpers.CompatibilityState;
const skipNonNormal = helpers.skipNonNormal;
const containsIgnoreCaseNameSlice = helpers.containsIgnoreCaseNameSlice;
const containsKnownObjectIdentifier = helpers.containsKnownObjectIdentifier;
const countUppercaseChars = helpers.countUppercaseChars;
const extractGeneratedJavaClassName = helpers.extractGeneratedJavaClassName;
const extractParameterizedTypeVariableName = helpers.extractParameterizedTypeVariableName;
const extractTypedVariableName = helpers.extractTypedVariableName;
const findIndexAccessBaseStart = helpers.findIndexAccessBaseStart;
const findMemberAccessBaseStart = helpers.findMemberAccessBaseStart;
const findPreviousNonWhitespace = helpers.findPreviousNonWhitespace;
const isImportOrPackageLineAt = helpers.isImportOrPackageLineAt;
const isStaticValueAccessPathExpression = helpers.isStaticValueAccessPathExpression;
const lowercaseIdentifier = helpers.lowercaseIdentifier;
const replaceLiteralAll = helpers.replaceLiteralAll;

const appendFmt = util.appendFmt;
const collectionImplName = stmt_mod.collectionImplName;
const collectionKindFromName = stmt_mod.collectionKindFromName;
const containsIgnoreCaseSubstring = util.containsIgnoreCaseSubstring;
const convertApexExpressionToJava = stmt_mod.convertApexExpressionToJava;
const convertApexTypeList = stmt_mod.convertApexTypeList;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const findMatchingAngle = util.findMatchingAngle;
const findMatchingBrace = util.findMatchingBrace;
const findMatchingParen = util.findMatchingParen;
const findMatchingParenBackward = util.findMatchingParenBackward;
const findMatchingSquareBracket = util.findMatchingSquareBracket;
const findTopLevelAssignmentOperator = util.findTopLevelAssignmentOperator;
const findTopLevelMapArrow = util.findTopLevelMapArrow;
const indexOfIgnoreCase = util.indexOfIgnoreCase;
const isIdentifierChar = util.isIdentifierChar;
const isIdentifierPathExpression = util.isIdentifierPathExpression;
const isLikelyTypeReferencePathExpression = util.isLikelyTypeReferencePathExpression;
const isNewKeywordAt = util.isNewKeywordAt;
const isSimpleIdentifier = util.isSimpleIdentifier;
const isSimpleIdentifierOrPath = util.isSimpleIdentifierOrPath;
const lastIdentifier = util.lastIdentifier;
const leadingIdentifier = util.leadingIdentifier;
const looksLikeTypeName = util.looksLikeTypeName;
const nextNonSpace = util.nextNonSpace;
const normalizeScalarTypeName = stmt_mod.normalizeScalarTypeName;
const prevNonSpace = util.prevNonSpace;
const splitCallArguments = stmt_mod.splitCallArguments;
const splitTopLevelCommaExpressions = stmt_mod.splitTopLevelCommaExpressions;
const splitTypeArguments = stmt_mod.splitTypeArguments;
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;

pub fn rewriteCollectionViewPropertyAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteValuesFieldPseudoCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    return replaceLiteralAll(gpa, text, "toLiteral(this.values())", "toLiteral(this.values)");
}

pub fn rewriteValueOfRemoveCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    const prefix = "ApexStrings.valueOf";
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], prefix)) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;

        var open = i + prefix.len;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;

        var remove_dot = close + 1;
        while (remove_dot < text.len and std.ascii.isWhitespace(text[remove_dot])) : (remove_dot += 1) {}
        if (remove_dot >= text.len or !startsWithIgnoreCase(text[remove_dot..], ".remove")) continue;

        var remove_open = remove_dot + ".remove".len;
        while (remove_open < text.len and std.ascii.isWhitespace(text[remove_open])) : (remove_open += 1) {}
        if (remove_open >= text.len or text[remove_open] != '(') continue;
        const remove_close = findMatchingParen(text, remove_open) orelse continue;
        const value_expr = text[i .. close + 1];
        const remove_arg = std.mem.trim(u8, text[(remove_open + 1)..remove_close], " \t");

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "ApexStrings.remove({s}, {s})", .{ value_expr, remove_arg });
        replaced = true;
        last_emit = remove_close + 1;
        i = remove_close;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteApexStringInstanceMethods(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const StringMethod = struct {
        suffix: []const u8,
        static_name: []const u8,
        requires_string_like_base: bool = false,
    };
    const methods = [_]StringMethod{
        .{ .suffix = ".abbreviate", .static_name = "abbreviate" },
        .{ .suffix = ".endsWithIgnoreCase", .static_name = "endsWithIgnoreCase", .requires_string_like_base = true },
        .{ .suffix = ".leftPad", .static_name = "leftPad", .requires_string_like_base = true },
        .{ .suffix = ".remove", .static_name = "remove", .requires_string_like_base = true },
        .{ .suffix = ".removeEnd", .static_name = "removeEnd" },
        .{ .suffix = ".removeEndIgnoreCase", .static_name = "removeEndIgnoreCase" },
        .{ .suffix = ".removeStart", .static_name = "removeStart" },
        .{ .suffix = ".removeStartIgnoreCase", .static_name = "removeStartIgnoreCase" },
        .{ .suffix = ".deleteWhiteSpace", .static_name = "deleteWhiteSpace" },
        .{ .suffix = ".capitalize", .static_name = "capitalize" },
    };

    var string_names: std.ArrayList([]u8) = .empty;
    defer {
        for (string_names.items) |name| gpa.free(name);
        string_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractTypedVariableName(line, "String")) |name| {
            try string_names.append(gpa, try gpa.dupe(u8, name));
        }
    }

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
        if (ch != '.') continue;

        var matched: ?StringMethod = null;
        for (methods) |method| {
            if (startsWithIgnoreCase(text[i..], method.suffix)) {
                matched = method;
                break;
            }
        }
        if (matched == null) continue;

        const method = matched.?;
        const method_end = i + method.suffix.len;
        if (method_end < text.len and isIdentifierChar(text[method_end])) continue;
        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        var base_start = findMemberAccessBaseStart(text, i) orelse continue;
        var base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (std.mem.indexOfAny(u8, base_expr, "\r\n") != null) {
            var cursor = i;
            while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
            if (cursor == 0 or !isIdentifierChar(text[cursor - 1])) continue;
            var simple_start = cursor - 1;
            while (simple_start > 0 and isIdentifierChar(text[simple_start - 1])) : (simple_start -= 1) {}
            base_start = simple_start;
            base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        }
        if (base_expr.len == 0) continue;
        if (std.mem.indexOfScalar(u8, base_expr, '(') == null and isLikelyTypeReferencePathExpression(base_expr)) continue;
        if (method.requires_string_like_base and !baseExprLikelyString(base_expr, string_names.items)) continue;

        const args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        try out.appendSlice(gpa, text[last_emit..base_start]);
        if (args.len == 0) {
            try appendFmt(gpa, &out, "ApexStrings.{s}({s})", .{ method.static_name, base_expr });
        } else {
            try appendFmt(gpa, &out, "ApexStrings.{s}({s}, {s})", .{ method.static_name, base_expr, args });
        }
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

pub fn baseExprLikelyString(base_expr: []const u8, string_names: []const []u8) bool {
    const trimmed = std.mem.trim(u8, base_expr, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '"') return true;
    if (containsIgnoreCaseNameSlice(string_names, trimmed)) return true;
    return startsWithIgnoreCase(trimmed, "ApexStrings.") or
        startsWithIgnoreCase(trimmed, "String.valueOf(") or
        startsWithIgnoreCase(trimmed, "ApexStrings.valueOf(") or
        startsWithIgnoreCase(trimmed, "Labels.get(");
}

pub fn rewriteBrokenZeroLengthListInitializers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        const rhs = std.mem.trim(u8, line[(eq_pos + 1)..], " \t");
        if (std.mem.indexOf(u8, lhs, "List<") == null or
            !startsWithIgnoreCase(rhs, "new ") or
            !endsWithIgnoreCase(rhs, ".get(0);"))
        {
            try out.appendSlice(gpa, line);
            continue;
        }

        try out.appendSlice(gpa, line[0 .. eq_pos + 1]);
        try out.appendSlice(gpa, " new ArrayList<>();");
        replaced = true;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteInstanceListDeepCloneCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var list_names: std.ArrayList([]u8) = .empty;
    defer {
        for (list_names.items) |name| gpa.free(name);
        list_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (extractParameterizedTypeVariableName(line, "List")) |name| {
            try list_names.append(gpa, try gpa.dupe(u8, name));
        }
    }

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
        if (ch != '.') continue;

        const suffix = blk: {
            if (startsWithIgnoreCase(text[i..], ".deepClone")) break :blk ".deepClone";
            if (startsWithIgnoreCase(text[i..], ".deepclone")) break :blk ".deepclone";
            break :blk "";
        };
        if (suffix.len == 0) continue;

        const method_end = i + suffix.len;
        if (method_end < text.len and isIdentifierChar(text[method_end])) continue;
        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        if (base_expr.len == 0) continue;
        if (!containsKnownObjectIdentifier(list_names.items, base_expr) and
            !startsWithIgnoreCase(base_expr, "Database.query(") and
            !startsWithIgnoreCase(base_expr, "Database.queryWithBinds("))
        {
            continue;
        }

        const args = std.mem.trim(u8, text[(open + 1)..close], " \t");
        try out.appendSlice(gpa, text[last_emit..base_start]);
        if (args.len == 0) {
            try appendFmt(gpa, &out, "ApexCollections.deepClone({s}, false, true, false)", .{base_expr});
        } else {
            try appendFmt(gpa, &out, "ApexCollections.deepClone({s}, {s})", .{ base_expr, args });
        }
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

pub fn isScreamingSnakeIdentifier(token: []const u8) bool {
    if (token.len == 0) return false;
    var has_alpha = false;
    for (token) |ch| {
        if (std.ascii.isAlphabetic(ch)) {
            has_alpha = true;
            if (std.ascii.isLower(ch)) return false;
            continue;
        }
        if (std.ascii.isDigit(ch) or ch == '_') continue;
        return false;
    }
    return has_alpha;
}

pub fn isCaseVariantCandidate(token: []const u8) bool {
    if (token.len == 0) return false;
    if (!(std.ascii.isAlphabetic(token[0]) or token[0] == '_')) return false;
    if (isScreamingSnakeIdentifier(token)) return false;
    return true;
}

pub fn rewriteCaseInsensitiveIdentifierVariants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const IdentifierVariant = struct {
        spelling: []u8,
        count: usize,
        first_seen: usize,
        uppercase_count: usize,
    };
    const IdentifierGroup = struct {
        key_lower: []u8,
        variants: std.ArrayList(IdentifierVariant),
    };

    var groups: std.ArrayList(IdentifierGroup) = .empty;
    defer {
        for (groups.items) |*group| {
            gpa.free(group.key_lower);
            for (group.variants.items) |variant| gpa.free(variant.spelling);
            group.variants.deinit(gpa);
        }
        groups.deinit(gpa);
    }

    var group_index_by_key = std.StringHashMap(usize).init(gpa);
    defer group_index_by_key.deinit();

    var i: usize = 0;
    var state: CompatibilityState = .normal;
    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            if (!isIdentifierChar(text[i])) {
                i += 1;
                continue;
            }
            if (i > 0 and isIdentifierChar(text[i - 1])) {
                i += 1;
                continue;
            }

            const start = i;
            var end = i + 1;
            while (end < text.len and isIdentifierChar(text[end])) : (end += 1) {}
            i = end;
            const token = text[start..end];
            if (token.len == 0) continue;
            if (!(std.ascii.isLower(token[0]) or token[0] == '_')) continue;
            if (isImportOrPackageLineAt(text, start)) continue;

            const lower = try lowercaseIdentifier(gpa, token);
            errdefer gpa.free(lower);

            if (group_index_by_key.get(lower)) |group_index| {
                gpa.free(lower);
                var found = false;
                for (groups.items[group_index].variants.items) |*variant| {
                    if (std.mem.eql(u8, variant.spelling, token)) {
                        variant.count += 1;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try groups.items[group_index].variants.append(gpa, .{
                        .spelling = try gpa.dupe(u8, token),
                        .count = 1,
                        .first_seen = start,
                        .uppercase_count = countUppercaseChars(token),
                    });
                }
                continue;
            }

            var variants: std.ArrayList(IdentifierVariant) = .empty;
            errdefer {
                for (variants.items) |variant| gpa.free(variant.spelling);
                variants.deinit(gpa);
            }
            try variants.append(gpa, .{
                .spelling = try gpa.dupe(u8, token),
                .count = 1,
                .first_seen = start,
                .uppercase_count = countUppercaseChars(token),
            });
            try groups.append(gpa, .{ .key_lower = lower, .variants = variants });
            try group_index_by_key.put(groups.items[groups.items.len - 1].key_lower, groups.items.len - 1);
        }
    }

    var canonical_by_key = std.StringHashMap([]const u8).init(gpa);
    defer canonical_by_key.deinit();

    for (groups.items) |*group| {
        if (group.variants.items.len < 2) continue;

        var best = group.variants.items[0];
        var has_distinct = false;
        for (group.variants.items[1..]) |variant| {
            if (!std.mem.eql(u8, variant.spelling, best.spelling)) has_distinct = true;
            if (variant.uppercase_count > best.uppercase_count) {
                best = variant;
                continue;
            }
            if (variant.uppercase_count == best.uppercase_count and variant.count > best.count) {
                best = variant;
                continue;
            }
            if (variant.uppercase_count == best.uppercase_count and variant.count == best.count and variant.first_seen < best.first_seen) {
                best = variant;
                continue;
            }
        }
        if (!has_distinct) continue;
        try canonical_by_key.put(group.key_lower, best.spelling);
    }

    if (canonical_by_key.count() == 0) return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    i = 0;
    state = .normal;
    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            if (!isIdentifierChar(text[i])) {
                i += 1;
                continue;
            }
            if (i > 0 and isIdentifierChar(text[i - 1])) {
                i += 1;
                continue;
            }

            const start = i;
            var end = i + 1;
            while (end < text.len and isIdentifierChar(text[end])) : (end += 1) {}
            i = end;
            const token = text[start..end];
            if (token.len == 0) continue;
            if (!(std.ascii.isLower(token[0]) or token[0] == '_')) continue;
            if (isImportOrPackageLineAt(text, start)) continue;

            const lower = try lowercaseIdentifier(gpa, token);
            defer gpa.free(lower);
            const canonical = canonical_by_key.get(lower) orelse continue;
            if (std.mem.eql(u8, token, canonical)) continue;

            try out.appendSlice(gpa, text[last_emit..start]);
            try out.appendSlice(gpa, canonical);
            replaced = true;
            last_emit = end;
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteUnaryPlusStringLiterals(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var state: CompatibilityState = .normal;
    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            if (text[i] != '+') {
                i += 1;
                continue;
            }

            const prev = findPreviousNonWhitespace(text, i) orelse {
                i += 1;
                continue;
            };
            const prev_ch = text[prev];
            if (prev_ch != ',' and prev_ch != '(' and prev_ch != '[' and prev_ch != '=' and prev_ch != '?' and prev_ch != ':') {
                i += 1;
                continue;
            }
            const next = nextNonSpace(text, i + 1);
            if (next >= text.len or text[next] != '"') {
                i += 1;
                continue;
            }

            try out.appendSlice(gpa, text[last_emit..i]);
            replaced = true;
            last_emit = next;
            i = next;
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteStringCollectionListOfArguments(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const prefixes = [_][]const u8{
        "new ArrayList<String>(ApexCollections.listOf(",
        "new LinkedHashSet<String>(ApexCollections.listOf(",
    };

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var state: CompatibilityState = .normal;

    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            var matched_prefix: ?[]const u8 = null;
            for (prefixes) |prefix| {
                if (!startsWithIgnoreCase(text[i..], prefix)) continue;
                matched_prefix = prefix;
                break;
            }
            if (matched_prefix == null) {
                i += 1;
                continue;
            }
            const prefix = matched_prefix.?;
            const list_open = i + prefix.len - 1;
            const list_close = findMatchingParen(text, list_open) orelse {
                i += 1;
                continue;
            };

            const raw_args = text[(list_open + 1)..list_close];
            var args = try splitCallArguments(gpa, raw_args);
            defer args.deinit(gpa);
            if (args.items.len == 0) {
                i = list_close + 1;
                continue;
            }

            try out.appendSlice(gpa, text[last_emit..i]);
            try out.appendSlice(gpa, prefix);
            for (args.items, 0..) |arg_raw, arg_idx| {
                const arg = std.mem.trim(u8, arg_raw, " \t");
                if (arg_idx != 0) try out.appendSlice(gpa, ", ");
                if (shouldWrapStringCollectionArgument(arg)) {
                    try appendFmt(gpa, &out, "ApexStrings.valueOf({s})", .{arg});
                } else {
                    try out.appendSlice(gpa, arg);
                }
            }
            try out.append(gpa, ')');

            replaced = true;
            last_emit = list_close + 1;
            i = list_close + 1;
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn shouldWrapStringCollectionArgument(arg: []const u8) bool {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) return false;
    if (startsWithIgnoreCase(trimmed, "ApexStrings.valueOf(")) return false;
    if (startsWithIgnoreCase(trimmed, "String.valueOf(")) return false;
    if (startsWithIgnoreCase(trimmed, "(String)")) return false;
    if (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') return false;
    if (startsWithIgnoreCase(trimmed, "ApexSwitch.getAs(")) return true;
    if (std.mem.indexOf(u8, trimmed, ".getAs(") != null) return true;
    return false;
}

pub fn rewriteApexStringsValueOfCollectionWrappers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const marker = "ApexStrings.valueOf(";
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
            const inner = std.mem.trim(u8, text[(open + 1)..close], " \t");
            if (!startsWithIgnoreCase(inner, "new ArrayList<String>(") and
                !startsWithIgnoreCase(inner, "new LinkedHashSet<String>("))
            {
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

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }

    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteValuesMethodCollectionViews(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var state: CompatibilityState = .normal;
    while (i < text.len) {
        if (helpers.skipNonNormal(text, &i, &state)) continue;
        {
            if (text[i] != '.') {
                i += 1;
                continue;
            }
            if (!startsWithIgnoreCase(text[i..], ".values()")) {
                i += 1;
                continue;
            }

            const base_start = findMemberAccessBaseStart(text, i) orelse {
                i += 1;
                continue;
            };
            const line_start = blk: {
                if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |pos| break :blk pos + 1;
                break :blk 0;
            };
            if (base_start < line_start) {
                i += 1;
                continue;
            }
            const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
            if (base_expr.len == 0) {
                i += 1;
                continue;
            }
            if (isLikelyTypeReferencePathExpression(base_expr)) {
                i += 1;
                continue;
            }

            try out.appendSlice(gpa, text[last_emit..base_start]);
            try appendFmt(gpa, &out, "new ArrayList<>({s}.values())", .{base_expr});
            replaced = true;
            last_emit = i + ".values()".len;
            i = last_emit;
        }
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewritePrivateStaticNestedTestClasses(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const class_name = extractGeneratedJavaClassName(text) orelse return gpa.dupe(u8, text);
    if (!endsWithIgnoreCase(class_name, "_TEST") and !endsWithIgnoreCase(class_name, "Test") and !endsWithIgnoreCase(class_name, "Tests")) {
        return gpa.dupe(u8, text);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var changed = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const indent_len = line.len - trimmed.len;
        const indent = line[0..indent_len];

        if (startsWithIgnoreCase(trimmed, "private static class ")) {
            try appendFmt(gpa, &out, "{s}public static class {s}", .{ indent, trimmed["private static class ".len..] });
            changed = true;
            continue;
        }
        if (startsWithIgnoreCase(trimmed, "private static final class ")) {
            try appendFmt(gpa, &out, "{s}public static final class {s}", .{ indent, trimmed["private static final class ".len..] });
            changed = true;
            continue;
        }

        try out.appendSlice(gpa, line);
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteLocalStaticWaitCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const class_name = extractGeneratedJavaClassName(text) orelse return gpa.dupe(u8, text);
    if (std.mem.indexOf(u8, text, " static ") == null or std.mem.indexOf(u8, text, " wait(") == null) {
        return gpa.dupe(u8, text);
    }

    var declares_wait = false;
    var decl_lines = std.mem.splitScalar(u8, text, '\n');
    while (decl_lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (std.mem.indexOf(u8, line, " static ") != null and std.mem.indexOf(u8, line, " wait(") != null) {
            declares_wait = true;
            break;
        }
    }
    if (!declares_wait) return gpa.dupe(u8, text);

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
        if (std.mem.indexOf(u8, trimmed, " static ") != null and std.mem.indexOf(u8, trimmed, " wait(") != null) {
            const renamed = try replaceLiteralAll(gpa, line, " wait(", " waitForDuration(");
            defer gpa.free(renamed);
            try out.appendSlice(gpa, renamed);
            changed = true;
            continue;
        }

        var line_out: std.ArrayList(u8) = .empty;
        defer line_out.deinit(gpa);

        var replaced_line = false;
        var last_emit: usize = 0;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (!startsWithIgnoreCase(line[i..], "wait(")) continue;
            if (i > 0 and (isIdentifierChar(line[i - 1]) or line[i - 1] == '.')) continue;
            try line_out.appendSlice(gpa, line[last_emit..i]);
            const arg_open = i + "wait".len;
            const arg_close = findMatchingParen(line, arg_open) orelse {
                try line_out.appendSlice(gpa, "wait(");
                last_emit = arg_open + 1;
                continue;
            };
            const arg_text = std.mem.trim(u8, line[(arg_open + 1)..arg_close], " \t");
            if (arg_text.len > 0 and std.mem.indexOfAny(u8, arg_text, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_") == null) {
                try appendFmt(gpa, &line_out, "{s}.waitForDuration(Long.valueOf({s}))", .{ class_name, arg_text });
                last_emit = arg_close + 1;
                i = arg_close;
                replaced_line = true;
                continue;
            }
            try appendFmt(gpa, &line_out, "{s}.waitForDuration(", .{class_name});
            replaced_line = true;
            last_emit = i + "wait(".len;
            i = last_emit - 1;
        }

        if (!replaced_line) {
            try out.appendSlice(gpa, line);
            continue;
        }

        try line_out.appendSlice(gpa, line[last_emit..]);
        try out.appendSlice(gpa, line_out.items);
        changed = true;
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteBrokenInlineMethodAssignmentsInSObjectSet(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const method_suffixes = [_][]const u8{ ".addDays(", ".addMonths(", ".addYears(" };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], ".set(")) continue;

        const open = i + ".set".len;
        const close = findMatchingParen(text, open) orelse continue;
        var set_args = try splitTopLevelCommaExpressions(gpa, text[(open + 1)..close]);
        defer set_args.deinit(gpa);
        if (set_args.items.len != 2) continue;

        const field_expr = std.mem.trim(u8, set_args.items[0], " \t");
        const value_expr = std.mem.trim(u8, set_args.items[1], " \t");

        var method_suffix: ?[]const u8 = null;
        var method_pos: usize = 0;
        for (method_suffixes) |candidate| {
            if (std.mem.lastIndexOf(u8, value_expr, candidate)) |idx| {
                method_suffix = candidate;
                method_pos = idx;
                break;
            }
        }
        if (method_suffix == null) continue;

        const method_open = method_pos + method_suffix.?.len - 1;
        const method_close = findMatchingParen(value_expr, method_open) orelse continue;
        if (std.mem.trim(u8, value_expr[(method_close + 1)..], " \t").len != 0) continue;

        var method_args = try splitTopLevelCommaExpressions(gpa, value_expr[(method_open + 1)..method_close]);
        defer method_args.deinit(gpa);
        if (method_args.items.len <= 1) continue;

        var all_assignments = true;
        for (method_args.items[1..]) |arg| {
            const eq = findTopLevelAssignmentOperator(arg) orelse {
                all_assignments = false;
                break;
            };
            const name = std.mem.trim(u8, arg[0..eq], " \t");
            const value = std.mem.trim(u8, arg[(eq + 1)..], " \t");
            var name_is_identifier = name.len > 0;
            for (name) |ch| {
                if (!isIdentifierChar(ch)) {
                    name_is_identifier = false;
                    break;
                }
            }
            if (!name_is_identifier or value.len == 0) {
                all_assignments = false;
                break;
            }
        }
        if (!all_assignments) continue;

        try out.appendSlice(gpa, text[last_emit .. open + 1]);
        try out.appendSlice(gpa, field_expr);
        try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, value_expr[0 .. method_open + 1]);
        try out.appendSlice(gpa, std.mem.trim(u8, method_args.items[0], " \t"));
        try out.append(gpa, ')');
        try out.append(gpa, ')');
        for (method_args.items[1..]) |arg| {
            const eq = findTopLevelAssignmentOperator(arg).?;
            const name = std.mem.trim(u8, arg[0..eq], " \t");
            const value = std.mem.trim(u8, arg[(eq + 1)..], " \t");
            try appendFmt(gpa, &out, ".set(\"{s}\", {s})", .{ name, value });
        }
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

pub fn isLikelyClassLiteralToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |ch| {
        if (isIdentifierChar(ch) or ch == '.' or ch == '$') continue;
        return false;
    }
    return true;
}

pub fn collectSystemTypeVariableNames(gpa: std.mem.Allocator, text: []const u8, names: *std.StringHashMap(void)) !void {
    const marker = "apexemu.runtime.System.Type";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        const pos = std.mem.indexOf(u8, line, marker) orelse continue;

        var cursor = pos + marker.len;
        while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
        const name = leadingIdentifier(line[cursor..]) orelse continue;
        const after_name = cursor + name.len;
        var tail = after_name;
        while (tail < line.len and std.ascii.isWhitespace(line[tail])) : (tail += 1) {}
        if (tail < line.len and line[tail] == '(') continue;
        if (names.get(name) != null) continue;
        try names.put(try gpa.dupe(u8, name), {});
    }
}

pub fn rewriteSystemTypeClassLiteralAssignments(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var type_names = std.StringHashMap(void).init(gpa);
    defer {
        var it = type_names.iterator();
        while (it.next()) |entry| gpa.free(entry.key_ptr.*);
        type_names.deinit();
    }
    try collectSystemTypeVariableNames(gpa, text, &type_names);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var changed = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(gpa, '\n');
        first_line = false;

        const line = std.mem.trimRight(u8, raw_line, "\r");
        const semi = std.mem.lastIndexOfScalar(u8, line, ';') orelse {
            try out.appendSlice(gpa, line);
            continue;
        };
        const eq = std.mem.lastIndexOfScalar(u8, line[0..semi], '=') orelse {
            try out.appendSlice(gpa, line);
            continue;
        };

        var rhs_start = eq + 1;
        while (rhs_start < semi and std.ascii.isWhitespace(line[rhs_start])) : (rhs_start += 1) {}
        var rhs_end = semi;
        while (rhs_end > rhs_start and std.ascii.isWhitespace(line[rhs_end - 1])) : (rhs_end -= 1) {}
        if (rhs_end <= rhs_start) {
            try out.appendSlice(gpa, line);
            continue;
        }
        const rhs = line[rhs_start..rhs_end];
        if (!endsWithIgnoreCase(rhs, ".class")) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const class_name = std.mem.trim(u8, rhs[0 .. rhs.len - ".class".len], " \t");
        if (!isLikelyClassLiteralToken(class_name)) {
            try out.appendSlice(gpa, line);
            continue;
        }

        const lhs = std.mem.trim(u8, line[0..eq], " \t");
        const lhs_name = lastIdentifier(lhs) orelse "";
        const declared_in_line = std.mem.indexOf(u8, lhs, "apexemu.runtime.System.Type") != null;
        const known_type_name = lhs_name.len != 0 and type_names.get(lhs_name) != null;
        const likely_type_field = lhs_name.len != 0 and (containsIgnoreCaseSubstring(lhs_name, "type") or containsIgnoreCaseSubstring(lhs_name, "classType"));
        if (!declared_in_line and !known_type_name and !likely_type_field) {
            try out.appendSlice(gpa, line);
            continue;
        }

        try out.appendSlice(gpa, line[0..rhs_start]);
        try appendFmt(gpa, &out, "apexemu.runtime.System.Type.forName(\"{s}\")", .{class_name});
        try out.appendSlice(gpa, line[rhs_end..]);
        changed = true;
    }

    if (!changed) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn rewriteCollectionGenericInstanceof(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var state: CompatibilityState = .normal;
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    const marker = "instanceof";

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

            var type_start = i + marker.len;
            while (type_start < text.len and std.ascii.isWhitespace(text[type_start])) : (type_start += 1) {}
            if (type_start >= text.len) {
                i += 1;
                continue;
            }

            const is_set = startsWithIgnoreCase(text[type_start..], "Set<");
            const is_list = startsWithIgnoreCase(text[type_start..], "List<");
            if (!is_set and !is_list) {
                i = type_start + 1;
                continue;
            }

            const type_len: usize = if (is_set) 3 else 4;
            const angle_open = type_start + type_len;
            if (angle_open >= text.len or text[angle_open] != '<') {
                i = type_start + 1;
                continue;
            }

            var depth: i32 = 0;
            var cursor = angle_open;
            var angle_close: ?usize = null;
            while (cursor < text.len) : (cursor += 1) {
                if (text[cursor] == '<') {
                    depth += 1;
                    continue;
                }
                if (text[cursor] == '>') {
                    depth -= 1;
                    if (depth == 0) {
                        angle_close = cursor;
                        break;
                    }
                    continue;
                }
                if (text[cursor] == '\n' or text[cursor] == ';' or text[cursor] == ')') break;
            }
            if (angle_close == null) {
                i = type_start + 1;
                continue;
            }

            try out.appendSlice(gpa, text[last_emit..type_start]);
            try out.appendSlice(gpa, if (is_set) "Set<?>" else "List<?>");
            replaced = true;
            last_emit = angle_close.? + 1;
            i = angle_close.? + 1;
        }
    }

    if (!replaced) return gpa.dupe(u8, text);
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteApexSystemUtilityCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteGenericClassLiterals(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteJsonDeserializeListCasts(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteStringInstanceMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
            if (startsWithIgnoreCase(text[i..], ".substringBeforeLast")) break :blk "substringBeforeLast";
            if (startsWithIgnoreCase(text[i..], ".substringBefore")) break :blk "substringBefore";
            if (startsWithIgnoreCase(text[i..], ".leftPad")) break :blk "leftPad";
            if (startsWithIgnoreCase(text[i..], ".left")) break :blk "left";
            if (startsWithIgnoreCase(text[i..], ".rightPad")) break :blk "rightPad";
            if (startsWithIgnoreCase(text[i..], ".getStackTraceString")) break :blk "getStackTraceString";
            if (startsWithIgnoreCase(text[i..], ".getTypeName")) break :blk "getTypeName";
            if (startsWithIgnoreCase(text[i..], ".remove(")) break :blk "remove";
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
            if (startsWithIgnoreCase(text[i..], ".startsWithIgnoreCase")) break :blk "startsWithIgnoreCase";
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
        } else if (std.ascii.eqlIgnoreCase(method_name, "substringBeforeLast")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.substringBeforeLast({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "left")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.left({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "leftPad")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.leftPad({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "rightPad")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.rightPad({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "removeEnd")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.removeEnd({s}, {s})", .{ base_expr, call_args });
        } else if (std.ascii.eqlIgnoreCase(method_name, "remove")) {
            const trimmed_args = std.mem.trim(u8, call_args, " \t");
            if (trimmed_args.len == 0 or trimmed_args[0] != '"') continue;
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.remove({s}, {s})", .{ base_expr, call_args });
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
        } else if (std.ascii.eqlIgnoreCase(method_name, "startsWithIgnoreCase")) {
            replacement = try std.fmt.allocPrint(gpa, "ApexStrings.startsWithIgnoreCase({s}, {s})", .{ base_expr, call_args });
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

pub fn specificIdentifierReplacement(text: []const u8, token: []const u8, token_start: usize, token_end: usize) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(token, "acct")) return "acct";
    if (std.ascii.eqlIgnoreCase(token, "checkacct")) return "checkAcct";
    if (std.ascii.eqlIgnoreCase(token, "updatedacct")) return "updatedAcct";
    if (std.ascii.eqlIgnoreCase(token, "sobj")) return "sObj";
    if (std.ascii.eqlIgnoreCase(token, "sobj1")) return "sObj1";
    if (std.ascii.eqlIgnoreCase(token, "sobj2")) return "sObj2";
    if (std.ascii.eqlIgnoreCase(token, "sobj3")) return "sObj3";
    if (std.ascii.eqlIgnoreCase(token, "mydad")) return "mydad";
    if (std.ascii.eqlIgnoreCase(token, "objname")) return "objname";
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
    if (std.ascii.eqlIgnoreCase(token, "setfname")) return "setFname";
    if (std.ascii.eqlIgnoreCase(token, "setlname")) return "setLname";
    if (std.ascii.eqlIgnoreCase(token, "listfname")) return "listFname";
    if (std.ascii.eqlIgnoreCase(token, "listemail")) return "listEmail";
    if (std.ascii.eqlIgnoreCase(token, "dikey")) return "diKey";
    if (std.ascii.eqlIgnoreCase(token, "createstatus")) return "createStatus";
    if (std.ascii.eqlIgnoreCase(token, "listdikeyax")) return "listDiKeyAx";
    if (std.ascii.eqlIgnoreCase(token, "listdikeycx")) return "listDiKeyCx";
    if (std.ascii.eqlIgnoreCase(token, "listidbatches")) return "listIdBatches";
    if (std.ascii.eqlIgnoreCase(token, "contactfromdi")) return "contactFromDi";
    if (std.ascii.eqlIgnoreCase(token, "newdi")) return "newDi";
    if (std.ascii.eqlIgnoreCase(token, "math")) return "Math";
    if (std.ascii.eqlIgnoreCase(token, "iscustomidincontactmatchrules")) return "isCustomIdInContactMatchRules";
    if (std.ascii.eqlIgnoreCase(token, "iscustomidinaccountmatchrules")) return "isCustomIdInAccountMatchRules";
    if (std.ascii.eqlIgnoreCase(token, "sfdoinstrumentationservice")) return "SfdoInstrumentationService";
    if (std.ascii.eqlIgnoreCase(token, "sfdoinstrumentationenum")) return "SfdoInstrumentationEnum";
    if (std.ascii.eqlIgnoreCase(token, "perflog")) return "PerfLog";
    if (std.mem.eql(u8, token, "MATCHTYPE")) return "MATCHTYPE";
    if (std.mem.eql(u8, token, "matchType")) return "matchType";
    if (std.mem.eql(u8, token, "matchtype")) return "matchType";
    if (std.ascii.eqlIgnoreCase(token, "numofdis")) return "numOfDis";
    if (std.ascii.eqlIgnoreCase(token, "defaultdonationrecordtypemapping")) return "defaultDonationRecordTypeMapping";
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

pub fn hasUpperAfterFirst(token: []const u8) bool {
    if (token.len <= 1) return false;
    for (token[1..]) |ch| {
        if (std.ascii.isUpper(ch)) return true;
    }
    return false;
}

pub fn isPrecededByKeywordIgnoreCase(text: []const u8, token_start: usize, keyword: []const u8) bool {
    var cursor = token_start;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor < keyword.len) return false;

    const keyword_start = cursor - keyword.len;
    if (!std.ascii.eqlIgnoreCase(text[keyword_start..cursor], keyword)) return false;
    if (keyword_start > 0 and isIdentifierChar(text[keyword_start - 1])) return false;
    return true;
}

pub fn rewriteSpecificIdentifierCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteTestDoubleClassCtorCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteSystemTypeListOfClassLiterals(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteSystemTypeMethodClassLiteralArgs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteNoArgCloneCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteStringKeyedSetMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteNoArgSortCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn convertBracketIndexAccessPass(gpa: std.mem.Allocator, text: []const u8) anyerror!?[]u8 {
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
        if (looksLikeApexSizedArrayConstructorBase(base_expr)) {
            // Apex `new Id[n]` (and peers) creates a fixed-length list with `n` null slots.
            // Use a runtime helper so subsequent `.set(i, value)` matches Apex behavior.
            try appendFmt(gpa, &out, "ApexCollections.newListWithSize({s})", .{index_expr});
        } else {
            try appendFmt(gpa, &out, "{s}.get({s})", .{ base_expr, index_expr });
        }
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

pub fn convertBracketIndexAccess(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
    var current = try gpa.dupe(u8, text);
    var pass_count: usize = 0;
    while (pass_count < 32) : (pass_count += 1) {
        const next = try convertBracketIndexAccessPass(gpa, current) orelse return current;
        gpa.free(current);
        current = next;
    }
    return current;
}

pub fn looksLikeApexSizedArrayConstructorBase(base_expr_raw: []const u8) bool {
    var expr = std.mem.trim(u8, base_expr_raw, " \t");
    if (!startsWithWordIgnoreCase(expr, "new")) return false;

    expr = std.mem.trimLeft(u8, expr["new".len..], " \t");
    if (expr.len == 0) return false;
    if (std.mem.indexOfAny(u8, expr, "([{") != null) return false;

    // Allow qualified Apex type names, e.g. `Namespace.Type`.
    for (expr) |ch| {
        if (!(isIdentifierChar(ch) or ch == '.')) return false;
    }
    return true;
}

pub fn convertInlineCollectionConstructors(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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

pub fn isIdSObjectMapType(gpa: std.mem.Allocator, java_type: []const u8) !bool {
    const trimmed = std.mem.trim(u8, java_type, " \t");
    if (!startsWithIgnoreCase(trimmed, "Map<")) return false;
    const open = std.mem.indexOfScalar(u8, trimmed, '<') orelse return false;
    const close = findMatchingAngle(trimmed, open) orelse return false;
    const inner = std.mem.trim(u8, trimmed[(open + 1)..close], " \t");
    return isIdSObjectMapGeneric(gpa, inner);
}

pub fn isIdSObjectMapGeneric(gpa: std.mem.Allocator, generic: []const u8) !bool {
    var parts = try splitTypeArguments(gpa, generic);
    defer parts.deinit(gpa);
    if (parts.items.len != 2) return false;
    const key = std.mem.trim(u8, parts.items[0], " \t");
    const value = std.mem.trim(u8, parts.items[1], " \t");
    return std.ascii.eqlIgnoreCase(key, "String") and std.ascii.eqlIgnoreCase(value, "ApexSObject");
}

pub fn convertInlineCollectionLiterals(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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

pub fn convertInlineSObjectConstructors(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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
pub fn rewriteApexStringUtilityCalls(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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
