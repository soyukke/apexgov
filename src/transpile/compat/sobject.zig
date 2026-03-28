const line_and_expr = @import("../line_and_expr.zig");
const std = @import("std");
const util = @import("../util.zig");

const getas = @import("getas.zig");
const helpers = @import("helpers.zig");

const CompatibilityState = getas.CompatibilityState;
const appendUniqueIdentifier = helpers.appendUniqueIdentifier;
const extractDeclaredVariableName = helpers.extractDeclaredVariableName;
const extractForEachVariableNameOfType = helpers.extractForEachVariableNameOfType;
const extractSimpleAssignment = helpers.extractSimpleAssignment;
const extractTypedVariableName = helpers.extractTypedVariableName;
const findExpressionEnd = helpers.findExpressionEnd;
const findMemberAccessBaseStart = helpers.findMemberAccessBaseStart;
const findPreviousNonWhitespace = helpers.findPreviousNonWhitespace;
const identifierInList = helpers.identifierInList;
const isLikelySObjectTypeForInstanceof = helpers.isLikelySObjectTypeForInstanceof;
const isStaticValueAccessPathExpression = helpers.isStaticValueAccessPathExpression;
const isWithinAnnotationQualifiedChain = helpers.isWithinAnnotationQualifiedChain;
const isWithinImportOrPackageDeclaration = helpers.isWithinImportOrPackageDeclaration;
const replaceLiteralAll = helpers.replaceLiteralAll;
const typeReferenceObjectName = helpers.typeReferenceObjectName;

const appendFmt = util.appendFmt;
const baseIdentifierBeforeDot = util.baseIdentifierBeforeDot;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const findMatchingParen = util.findMatchingParen;
const isIdentifierChar = util.isIdentifierChar;
const isLikelyQualifiedTypeChain = util.isLikelyQualifiedTypeChain;
const isLikelySObjectFieldName = util.isLikelySObjectFieldName;
const isLikelyTypeReferenceIdentifier = util.isLikelyTypeReferenceIdentifier;
const isLikelyTypeReferencePathExpression = util.isLikelyTypeReferencePathExpression;
const isSimpleIdentifier = util.isSimpleIdentifier;
const nextNonSpace = util.nextNonSpace;
const splitCallArguments = line_and_expr.splitCallArguments;
const startsWithIgnoreCase = util.startsWithIgnoreCase;

pub fn rewriteVisualforceComponentQualifiedAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteConstructedSObjectTypeClassGetNameCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn isLikelySObjectNamespaceToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.indexOf(u8, token, "__") != null) return true;
    return std.ascii.isUpper(token[0]);
}

pub fn rewritePseudoSObjectNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteLabelNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteLowercaseDatabaseNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteCustomSchemaSObjectTypeAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteBareCustomSObjectTypeAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                const suffix = blk: {
                    if (startsWithIgnoreCase(text[i..], ".sObjectType")) break :blk ".sObjectType";
                    if (startsWithIgnoreCase(text[i..], ".fields")) break :blk ".fields";
                    if (startsWithIgnoreCase(text[i..], ".fieldSets")) break :blk ".fieldSets";
                    break :blk "";
                };
                if (suffix.len == 0) {
                    i += 1;
                    continue;
                }

                const suffix_end = i + suffix.len;
                if (suffix_end < text.len and isIdentifierChar(text[suffix_end])) {
                    i += 1;
                    continue;
                }

                const base_start = findMemberAccessBaseStart(text, i) orelse {
                    i += 1;
                    continue;
                };
                const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
                if (base_expr.len == 0 or std.mem.indexOf(u8, base_expr, "__") == null) {
                    i = suffix_end;
                    continue;
                }
                if (std.mem.indexOfScalar(u8, base_expr, '(') != null) {
                    i = suffix_end;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..base_start]);
                try appendFmt(gpa, &out, "new Schema.SObjectType(\"{s}\")", .{base_expr});
                replaced = true;
                const drop_suffix = std.ascii.eqlIgnoreCase(suffix, ".sObjectType");
                last_emit = if (drop_suffix) suffix_end else i;
                i = suffix_end;
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

pub fn isLikelyBareStandardSObjectTypeToken(token: []const u8) bool {
    if (!isSimpleIdentifier(token)) return false;
    if (std.mem.indexOf(u8, token, "__") != null) return false;
    if (!std.ascii.isUpper(token[0])) return false;

    const deny = [_][]const u8{
        "Schema",
        "System",
        "Database",
        "Apex",
        "ApexSObject",
        "ApexSwitch",
        "ApexStrings",
        "ApexCollections",
        "Math",
        "String",
        "Object",
        "Boolean",
        "Integer",
        "Long",
        "Double",
        "Date",
        "DateTime",
        "Time",
        "URL",
        "JSON",
    };
    for (deny) |name| {
        if (std.ascii.eqlIgnoreCase(token, name)) return false;
    }
    return true;
}

pub fn rewriteBareStandardSObjectTypeAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                const suffix = blk: {
                    if (startsWithIgnoreCase(text[i..], ".sObjectType")) break :blk ".sObjectType";
                    if (startsWithIgnoreCase(text[i..], ".fields")) break :blk ".fields";
                    if (startsWithIgnoreCase(text[i..], ".fieldSets")) break :blk ".fieldSets";
                    break :blk "";
                };
                if (suffix.len == 0) {
                    i += 1;
                    continue;
                }

                const suffix_end = i + suffix.len;
                if (suffix_end < text.len and isIdentifierChar(text[suffix_end])) {
                    i += 1;
                    continue;
                }

                const base_start = findMemberAccessBaseStart(text, i) orelse {
                    i += 1;
                    continue;
                };
                const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
                if (!isLikelyBareStandardSObjectTypeToken(base_expr)) {
                    i = suffix_end;
                    continue;
                }
                if (std.mem.indexOfScalar(u8, base_expr, '(') != null) {
                    i = suffix_end;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..base_start]);
                try appendFmt(gpa, &out, "new Schema.SObjectType(\"{s}\")", .{base_expr});
                replaced = true;
                const drop_suffix = std.ascii.eqlIgnoreCase(suffix, ".sObjectType");
                last_emit = if (drop_suffix) suffix_end else i;
                i = suffix_end;
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

pub fn rewriteBareCustomSettingsSingletonAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                if (!isIdentifierChar(text[i])) {
                    i += 1;
                    continue;
                }
                if (i > 0 and isIdentifierChar(text[i - 1])) {
                    i += 1;
                    continue;
                }

                var name_end = i;
                while (name_end < text.len and isIdentifierChar(text[name_end])) : (name_end += 1) {}
                const type_name = text[i..name_end];
                const is_custom_token = endsWithIgnoreCase(type_name, "__c") or endsWithIgnoreCase(type_name, "__mdt");
                if (!is_custom_token) {
                    i = name_end;
                    continue;
                }
                if (i > 0) {
                    const prev = findPreviousNonWhitespace(text, i) orelse null;
                    if (prev != null and text[prev.?] == '.') {
                        i = name_end;
                        continue;
                    }
                }

                const dot_idx = nextNonSpace(text, name_end);
                if (dot_idx >= text.len or text[dot_idx] != '.') {
                    i = name_end;
                    continue;
                }
                const method_start = nextNonSpace(text, dot_idx + 1);
                const method = blk: {
                    if (startsWithIgnoreCase(text[method_start..], "getInstance")) break :blk "getInstance";
                    if (startsWithIgnoreCase(text[method_start..], "getOrgDefaults")) break :blk "getOrgDefaults";
                    if (startsWithIgnoreCase(text[method_start..], "getAll")) break :blk "getAll";
                    break :blk "";
                };
                if (method.len == 0) {
                    i = name_end;
                    continue;
                }
                const open_idx = nextNonSpace(text, method_start + method.len);
                if (open_idx >= text.len or text[open_idx] != '(') {
                    i = name_end;
                    continue;
                }
                const close_idx = findMatchingParen(text, open_idx) orelse {
                    i = name_end;
                    continue;
                };
                const args = std.mem.trim(u8, text[(open_idx + 1)..close_idx], " \t\r\n");
                if (args.len != 0) {
                    i = close_idx + 1;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..i]);
                if (std.ascii.eqlIgnoreCase(method, "getAll")) {
                    try appendFmt(gpa, &out, "ApexSObject.getAll(\"{s}\")", .{type_name});
                } else {
                    try appendFmt(gpa, &out, "ApexSObject.of(\"{s}\")", .{type_name});
                }
                replaced = true;
                last_emit = close_idx + 1;
                i = close_idx + 1;
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

pub fn rewritePageNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteApexPagesNestedTypeAliases(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try replaceLiteralAll(gpa, text, "ApexPages.addmessage(", "ApexPages.addMessage(");
    var next = try replaceLiteralAll(gpa, current, "new ApexPages.message(", "new ApexPages.Message(");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, "ApexPages.severity.", "ApexPages.Severity.");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, "ApexPages.CurrentPage()", "ApexPages.currentPage()");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, "ApexPages.Standardsetcontroller", "ApexPages.StandardSetController");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, "ApexPages.Standardcontroller", "ApexPages.StandardController");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, "ApexPages.PageReference", "PageReference");
    gpa.free(current);
    return next;
}

pub fn rewriteBareCustomSObjectTypeArgCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], "ApexSwitch.getSObjectType(")) continue;
        const open = i + "ApexSwitch.getSObjectType".len;
        const close = findMatchingParen(text, open) orelse continue;
        const arg = std.mem.trim(u8, text[(open + 1)..close], " \t");
        if (!isSimpleIdentifier(arg) or std.mem.indexOf(u8, arg, "__c") == null) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "ApexSwitch.getSObjectType(new Schema.SObjectType(\"{s}\"))", .{arg});
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

pub fn rewriteFieldDisplayTypeCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], "UTIL_Describe.getFieldDisplaytype(")) continue;
        const open = i + "UTIL_Describe.getFieldDisplaytype".len;
        const close = findMatchingParen(text, open) orelse continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try appendFmt(gpa, &out, "UTIL_Describe.getFieldDescribe({s}).getType()", .{text[(open + 1)..close]});
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

pub fn rewriteLegacyLiteralTokens(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                if (!isIdentifierChar(text[i])) {
                    i += 1;
                    continue;
                }

                const start = i;
                while (i < text.len and isIdentifierChar(text[i])) : (i += 1) {}
                const token = text[start..i];
                const replacement: ?[]const u8 = if (std.ascii.eqlIgnoreCase(token, "NULL") or std.ascii.eqlIgnoreCase(token, "Null"))
                    "null"
                else if (std.ascii.eqlIgnoreCase(token, "TRUE"))
                    "true"
                else if (std.ascii.eqlIgnoreCase(token, "FALSE"))
                    "false"
                else
                    null;
                if (replacement) |next| {
                    try out.appendSlice(gpa, text[last_emit..start]);
                    try out.appendSlice(gpa, next);
                    replaced = true;
                    last_emit = i;
                }
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

pub fn rewriteBareSchemaEnumConstantAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const mappings = [_]struct {
        prefix: []const u8,
        replacement: []const u8,
    }{
        .{ .prefix = "DisplayType.", .replacement = "Schema.DisplayType." },
        .{ .prefix = "SoapType.", .replacement = "Schema.SoapType." },
    };

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

                var did_replace = false;
                for (mappings) |mapping| {
                    if (!startsWithIgnoreCase(text[i..], mapping.prefix)) continue;
                    if (i > 0 and (isIdentifierChar(text[i - 1]) or text[i - 1] == '.')) continue;

                    const const_start = i + mapping.prefix.len;
                    if (const_start >= text.len or !isIdentifierChar(text[const_start])) continue;
                    var const_end = const_start;
                    while (const_end < text.len and isIdentifierChar(text[const_end])) : (const_end += 1) {}

                    try out.appendSlice(gpa, text[last_emit..i]);
                    try out.appendSlice(gpa, mapping.replacement);
                    try out.appendSlice(gpa, text[const_start..const_end]);
                    replaced = true;
                    last_emit = const_end;
                    i = const_end;
                    did_replace = true;
                    break;
                }
                if (did_replace) continue;
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

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteBareSObjectTypeAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    var state: CompatibilityState = .normal;
    const prefix = "SObjectType.";
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
                var cursor = name_start;
                while (cursor < text.len and isIdentifierChar(text[cursor])) : (cursor += 1) {}
                if (cursor == name_start) {
                    i += 1;
                    continue;
                }
                const after_type = nextNonSpace(text, cursor);
                if (after_type < text.len and text[after_type] == '(') {
                    i += 1;
                    continue;
                }
                const type_name = text[name_start..cursor];
                try out.appendSlice(gpa, text[last_emit..i]);
                try appendFmt(gpa, &out, "new Schema.SObjectType(\"{s}\")", .{type_name});
                replaced = true;
                last_emit = cursor;
                i = cursor;
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

pub fn rewriteSObjectFieldNameObjectNameUses(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const prefix = "new Schema.SObjectField";

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
                if (!startsWithIgnoreCase(text[i..], prefix)) {
                    i += 1;
                    continue;
                }
                if (i > 0 and isIdentifierChar(text[i - 1])) {
                    i += 1;
                    continue;
                }

                var open = i + prefix.len;
                while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
                if (open >= text.len or text[open] != '(') {
                    i += 1;
                    continue;
                }
                const close = findMatchingParen(text, open) orelse {
                    i += 1;
                    continue;
                };

                var args = try splitCallArguments(gpa, text[(open + 1)..close]);
                defer args.deinit(gpa);
                if (args.items.len != 2) {
                    i = close + 1;
                    continue;
                }
                const owner_arg = std.mem.trim(u8, args.items[0], " \t");
                const field_arg = std.mem.trim(u8, args.items[1], " \t");
                if (field_arg.len < 2 or field_arg[0] != '"' or field_arg[field_arg.len - 1] != '"') {
                    i = close + 1;
                    continue;
                }
                const field_name = field_arg[1 .. field_arg.len - 1];
                if (!std.ascii.eqlIgnoreCase(field_name, "name")) {
                    i = close + 1;
                    continue;
                }

                const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |pos| pos + 1 else 0;
                const prefix_line = std.mem.trim(u8, text[line_start..i], " \t");
                const expects_object_name =
                    std.mem.indexOf(u8, prefix_line, "UTIL_Describe.getFieldName(") != null or
                    std.mem.indexOf(u8, prefix_line, "UTIL_Describe.getFieldDescribe(") != null or
                    std.mem.indexOf(u8, prefix_line, "UTIL_Describe.getAllFieldsDescribe(") != null or
                    std.mem.indexOf(u8, prefix_line, "constructSimulatedObjectMapping(") != null or
                    blk: {
                        const eq_pos = std.mem.lastIndexOfScalar(u8, prefix_line, '=') orelse break :blk false;
                        const lhs = std.mem.trim(u8, prefix_line[0..eq_pos], " \t");
                        break :blk extractTypedVariableName(lhs, "String") != null;
                    };
                if (!expects_object_name) {
                    i = close + 1;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..i]);
                try appendFmt(gpa, &out, "new Schema.SObjectType({s}).getName()", .{owner_arg});
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

pub fn rewriteSchemaFieldNamespaceGetAsMethodCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const methods = [_][]const u8{
        ".isAccessible()",
        ".isUpdateable()",
        ".isCreateable()",
        ".isEncrypted()",
        ".isFilterable()",
        ".getSObjectField()",
        ".getDescribe()",
        ".getPicklistValues()",
        ".getName()",
        ".getLabel()",
    };
    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '.') continue;
        if (!startsWithIgnoreCase(text[i..], ".fields")) continue;

        const base_start = findMemberAccessBaseStart(text, i) orelse continue;
        const field_namespace_end = i + ".fields".len;
        var next = field_namespace_end;
        while (next < text.len and std.ascii.isWhitespace(text[next])) : (next += 1) {}
        if (next >= text.len or text[next] != '.') continue;
        if (!startsWithIgnoreCase(text[next..], ".getAs(")) continue;
        const get_as_open = next + ".getAs".len;
        const get_as_close = findMatchingParen(text, get_as_open) orelse continue;

        const method_suffix = blk: {
            for (methods) |candidate| {
                if (startsWithIgnoreCase(text[(get_as_close + 1)..], candidate)) break :blk candidate;
            }
            break :blk null;
        };
        if (method_suffix == null) continue;

        const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
        const arg_expr = std.mem.trim(u8, text[(get_as_open + 1)..get_as_close], " \t");
        try out.appendSlice(gpa, text[last_emit..base_start]);
        try appendFmt(gpa, &out, "((Schema.SObjectField) {s}.fields.getAs({s})){s}", .{ base_expr, arg_expr, method_suffix.? });
        replaced = true;
        last_emit = get_as_close + 1 + method_suffix.?.len;
        i = last_emit - 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteDescribeFieldNamespaceAliases(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try replaceLiteralAll(gpa, text, ".getDescribe().getAs(\"Fields\")", ".getDescribe().fields");
    var next = try replaceLiteralAll(gpa, current, ".getDescribe().getAs(\"fields\")", ".getDescribe().fields");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, ".getDescribe().getAs(\"FieldSets\")", ".getDescribe().fieldSets");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, ".getDescribe().getAs(\"fieldsets\")", ".getDescribe().fieldSets");
    gpa.free(current);
    return next;
}

pub fn rewriteDescribeGetAsAliases(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var current = try replaceLiteralAll(gpa, text, ".getDescribe().getAs(\"name\")", ".getDescribe().getName()");
    var next = try replaceLiteralAll(gpa, current, ".getDescribe().getAs(\"Name\")", ".getDescribe().getName()");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, ".getDescribe().getAs(\"label\")", ".getDescribe().getLabel()");
    gpa.free(current);
    current = next;

    next = try replaceLiteralAll(gpa, current, ".getDescribe().getAs(\"Label\")", ".getDescribe().getLabel()");
    gpa.free(current);
    current = next;

    next = try rewriteDescribeFieldNamespaceAliases(gpa, current);
    gpa.free(current);
    return next;
}

pub fn isLikelyCustomFieldSegment(segment: []const u8) bool {
    if (!isSimpleIdentifier(segment)) return false;
    return endsWithIgnoreCase(segment, "__c") or endsWithIgnoreCase(segment, "__r");
}

pub fn isSObjectTypeNamespaceBase(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "SObjectType")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "Schema.SObjectType")) return true;
    if (endsWithIgnoreCase(trimmed, ".SObjectType")) return true;
    if (endsWithIgnoreCase(trimmed, ".sObjectType")) return true;
    return false;
}

pub fn rewriteCustomSObjectMemberAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
                if (i + 1 >= text.len or !isIdentifierChar(text[i + 1])) {
                    i += 1;
                    continue;
                }

                const base_start = findMemberAccessBaseStart(text, i) orelse {
                    i += 1;
                    continue;
                };
                const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
                if (base_expr.len == 0) {
                    i += 1;
                    continue;
                }
                if (isSObjectTypeNamespaceBase(base_expr)) {
                    i += 1;
                    continue;
                }

                var segments: std.ArrayList([]const u8) = .empty;
                defer segments.deinit(gpa);

                var scan = i;
                var chain_end = i;
                var saw_custom = false;
                var first_segment = true;
                while (scan < text.len) {
                    while (scan < text.len and std.ascii.isWhitespace(text[scan])) : (scan += 1) {}
                    if (scan >= text.len or text[scan] != '.') break;
                    if (scan + 1 >= text.len or !isIdentifierChar(text[scan + 1])) break;

                    const name_start = scan + 1;
                    var name_end = name_start;
                    while (name_end < text.len and isIdentifierChar(text[name_end])) : (name_end += 1) {}
                    const segment = text[name_start..name_end];

                    const after_name = nextNonSpace(text, name_end);
                    if (after_name < text.len and text[after_name] == '(') break;

                    if (first_segment) {
                        if (!isLikelyCustomFieldSegment(segment)) break;
                        saw_custom = true;
                        first_segment = false;
                    }

                    try segments.append(gpa, segment);
                    chain_end = name_end;
                    scan = name_end;
                }

                if (!saw_custom or segments.items.len == 0) {
                    i += 1;
                    continue;
                }

                const after_chain = nextNonSpace(text, chain_end);
                if (segments.items.len == 1 and after_chain < text.len and text[after_chain] == '=' and (after_chain + 1 >= text.len or text[after_chain + 1] != '=')) {
                    const rhs_start = nextNonSpace(text, after_chain + 1);
                    const rhs_end = findExpressionEnd(text, rhs_start);
                    if (rhs_end <= rhs_start) {
                        i = chain_end;
                        continue;
                    }
                    const rhs_expr = std.mem.trim(u8, text[rhs_start..rhs_end], " \t");
                    if (rhs_expr.len == 0) {
                        i = chain_end;
                        continue;
                    }

                    try out.appendSlice(gpa, text[last_emit..base_start]);
                    try appendFmt(
                        gpa,
                        &out,
                        "ApexSwitch.set({s}, \"{s}\", {s})",
                        .{ base_expr, segments.items[0], rhs_expr },
                    );
                    replaced = true;
                    last_emit = rhs_end;
                    i = rhs_end;
                    continue;
                }

                var current = try gpa.dupe(u8, base_expr);
                defer gpa.free(current);
                for (segments.items) |segment| {
                    const next = try std.fmt.allocPrint(gpa, "ApexSwitch.getAs({s}, \"{s}\")", .{ current, segment });
                    gpa.free(current);
                    current = next;
                }

                try out.appendSlice(gpa, text[last_emit..base_start]);
                try out.appendSlice(gpa, current);
                replaced = true;
                last_emit = chain_end;
                i = chain_end;
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

pub fn rewriteKnownSObjectBooleanPropertyAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const fields = [_]struct { property: []const u8, field_name: []const u8 }{
        .{ .property = "isWon", .field_name = "isWon" },
        .{ .property = "isClosed", .field_name = "isClosed" },
        .{ .property = "isPrimary", .field_name = "isPrimary" },
        .{ .property = "isDeleted", .field_name = "isDeleted" },
        .{ .property = "amount", .field_name = "Amount" },
        .{ .property = "closeDate", .field_name = "CloseDate" },
    };
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

                const field = blk: {
                    for (fields) |candidate| {
                        if (startsWithIgnoreCase(text[(i + 1)..], candidate.property)) break :blk candidate;
                    }
                    break :blk null;
                };
                if (field == null) {
                    i += 1;
                    continue;
                }

                const field_end = i + 1 + field.?.property.len;
                if (field_end < text.len and isIdentifierChar(text[field_end])) {
                    i += 1;
                    continue;
                }
                const base_start = findMemberAccessBaseStart(text, i) orelse {
                    i += 1;
                    continue;
                };
                const base_expr = std.mem.trim(u8, text[base_start..i], " \t");
                if (base_expr.len == 0) {
                    i += 1;
                    continue;
                }
                if ((std.mem.eql(u8, field.?.field_name, "Amount") or std.mem.eql(u8, field.?.field_name, "CloseDate")) and
                    (!isSimpleIdentifier(base_expr) or std.ascii.eqlIgnoreCase(base_expr, "this")))
                {
                    i += 1;
                    continue;
                }

                const after_field = nextNonSpace(text, field_end);
                if (after_field < text.len and text[after_field] == '(') {
                    i += 1;
                    continue;
                }

                if (after_field < text.len and text[after_field] == '=' and (after_field + 1 >= text.len or text[after_field + 1] != '=')) {
                    const rhs_start = nextNonSpace(text, after_field + 1);
                    const rhs_end = std.mem.indexOfScalarPos(u8, text, rhs_start, ';') orelse {
                        i += 1;
                        continue;
                    };
                    const rhs_expr = std.mem.trim(u8, text[rhs_start..rhs_end], " \t");
                    if (rhs_expr.len == 0) {
                        i += 1;
                        continue;
                    }

                    try out.appendSlice(gpa, text[last_emit..base_start]);
                    try appendFmt(gpa, &out, "ApexSwitch.set({s}, \"{s}\", {s})", .{ base_expr, field.?.field_name, rhs_expr });
                    replaced = true;
                    last_emit = rhs_end;
                    i = rhs_end;
                    continue;
                }

                try out.appendSlice(gpa, text[last_emit..base_start]);
                try appendFmt(gpa, &out, "{s}.getAs(\"{s}\")", .{ base_expr, field.?.field_name });
                replaced = true;
                last_emit = field_end;
                i = field_end;
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

pub fn rewriteRecordTypeInfoMapDeclarations(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteRecordTypeInfoUsages(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

    var record_type_names: std.ArrayList([]u8) = .empty;
    defer {
        for (record_type_names.items) |name| gpa.free(name);
        record_type_names.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        const is_record_type_source_line = lineContainsRecordTypeInfoGetter(line) or lineContainsRecordTypeInfoHelperCall(line);

        if (extractDeclaredVariableName(line, "Map<String, apexemu.runtime.RecordTypeInfo> ")) |name| {
            try appendUniqueIdentifier(gpa, &map_names, name);
        }
        if (extractDeclaredVariableName(line, "List<apexemu.runtime.RecordTypeInfo> ")) |name| {
            try appendUniqueIdentifier(gpa, &list_names, name);
        }
        if (is_record_type_source_line) {
            if (extractDeclaredVariableName(line, "Map<String, ApexSObject> ")) |name| {
                try appendUniqueIdentifier(gpa, &map_names, name);
            }
            if (extractDeclaredVariableName(line, "List<ApexSObject> ")) |name| {
                try appendUniqueIdentifier(gpa, &list_names, name);
            }
            if (extractDeclaredVariableName(line, "ApexSObject ")) |name| {
                try appendUniqueIdentifier(gpa, &record_type_names, name);
            }
        }
        if (extractDeclaredVariableName(line, "apexemu.runtime.RecordTypeInfo ")) |name| {
            try appendUniqueIdentifier(gpa, &record_type_names, name);
        }
        if (extractForEachVariableNameOfType(line, "apexemu.runtime.RecordTypeInfo")) |name| {
            try appendUniqueIdentifier(gpa, &record_type_names, name);
        }

        if (extractSimpleAssignment(line)) |assignment| {
            var rhs_is_record_type = identifierInList(record_type_names.items, assignment.rhs);
            if (!rhs_is_record_type) {
                for (map_names.items) |map_name| {
                    const map_get = try std.fmt.allocPrint(gpa, "{s}.get(", .{map_name});
                    defer gpa.free(map_get);
                    if (std.mem.indexOf(u8, assignment.rhs, map_get) != null) {
                        rhs_is_record_type = true;
                        break;
                    }
                }
            }
            if (!rhs_is_record_type) {
                for (list_names.items) |list_name| {
                    const list_get = try std.fmt.allocPrint(gpa, "{s}.get(", .{list_name});
                    defer gpa.free(list_get);
                    if (std.mem.indexOf(u8, assignment.rhs, list_get) != null) {
                        rhs_is_record_type = true;
                        break;
                    }

                    const first_or_null = try std.fmt.allocPrint(gpa, "ApexCollections.firstOrNull({s})", .{list_name});
                    defer gpa.free(first_or_null);
                    if (std.mem.indexOf(u8, assignment.rhs, first_or_null) != null) {
                        rhs_is_record_type = true;
                        break;
                    }

                    const first_or_throw = try std.fmt.allocPrint(gpa, "ApexCollections.firstOrThrow({s})", .{list_name});
                    defer gpa.free(first_or_throw);
                    if (std.mem.indexOf(u8, assignment.rhs, first_or_throw) != null) {
                        rhs_is_record_type = true;
                        break;
                    }
                }
            }

            if (rhs_is_record_type) {
                try appendUniqueIdentifier(gpa, &record_type_names, assignment.lhs);
            }
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

        if (lineContainsRecordTypeInfoGetter(rendered) or lineContainsRecordTypeInfoHelperCall(rendered)) {
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

        for (map_names.items) |name| {
            const to_id_map = try std.fmt.allocPrint(gpa, "ApexCollections.toIdMap({s})", .{name});
            defer gpa.free(to_id_map);
            if (std.mem.indexOf(u8, rendered, to_id_map) != null) {
                const replacement = try std.fmt.allocPrint(gpa, "new LinkedHashMap<>({s})", .{name});
                defer gpa.free(replacement);
                const next = try replaceLiteralAll(gpa, rendered, to_id_map, replacement);
                gpa.free(rendered);
                rendered = next;
                replaced = true;
            }
        }

        if (extractTypedVariableName(rendered, "ApexSObject")) |name| {
            if (identifierInList(record_type_names.items, name)) {
                const next = try replaceLiteralAll(gpa, rendered, "ApexSObject ", "apexemu.runtime.RecordTypeInfo ");
                gpa.free(rendered);
                rendered = next;
                replaced = true;
            }
        }

        if (startsWithIgnoreCase(std.mem.trimLeft(u8, rendered, " \t"), "for (ApexSObject ")) {
            var replaced_for_header = false;
            for (map_names.items) |name| {
                const needle = try std.fmt.allocPrint(gpa, ": {s}.values()", .{name});
                defer gpa.free(needle);
                if (std.mem.indexOf(u8, rendered, needle) != null) {
                    const next = try replaceLiteralAll(gpa, rendered, "for (ApexSObject ", "for (apexemu.runtime.RecordTypeInfo ");
                    gpa.free(rendered);
                    rendered = next;
                    replaced = true;
                    replaced_for_header = true;
                    break;
                }
            }
            if (!replaced_for_header and std.mem.indexOf(u8, rendered, "for (ApexSObject ") != null) {
                for (list_names.items) |name| {
                    const needle = try std.fmt.allocPrint(gpa, ": {s})", .{name});
                    defer gpa.free(needle);
                    if (std.mem.indexOf(u8, rendered, needle) != null) {
                        const next = try replaceLiteralAll(gpa, rendered, "for (ApexSObject ", "for (apexemu.runtime.RecordTypeInfo ");
                        gpa.free(rendered);
                        rendered = next;
                        replaced = true;
                        replaced_for_header = true;
                        break;
                    }
                }
            }
            if (!replaced_for_header) {
                if (extractForEachVariableNameOfType(std.mem.trim(u8, rendered, " \t"), "ApexSObject")) |name| {
                    if (identifierInList(record_type_names.items, name)) {
                        const next = try replaceLiteralAll(gpa, rendered, "for (ApexSObject ", "for (apexemu.runtime.RecordTypeInfo ");
                        gpa.free(rendered);
                        rendered = next;
                        replaced = true;
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

pub fn lineContainsRecordTypeInfoHelperCall(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "getObjectRecordTypeInfos(") != null or
        std.mem.indexOf(u8, line, "getAssignedRecordTypes(") != null or
        std.mem.indexOf(u8, line, "getActiveRecordTypes(") != null;
}

pub fn lineContainsRecordTypeInfoGetter(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ".getRecordTypeInfosById()") != null or
        std.mem.indexOf(u8, line, ".getRecordTypeInfosByName()") != null or
        std.mem.indexOf(u8, line, ".getRecordTypeInfosByDeveloperName()") != null or
        std.mem.indexOf(u8, line, ".getRecordTypeInfos()") != null;
}

pub fn rewriteTriggerContextPropertyAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteIdGetSObjectTypeCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteTypeSObjectTypeConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteTypeSObjectFieldConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteSObjectTypeFieldSetConstants(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn rewriteTriggerOperationEnumConstantCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn canonicalTriggerOperationConstant(value: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "BEFORE_INSERT")) return "BEFORE_INSERT";
    if (std.ascii.eqlIgnoreCase(value, "BEFORE_UPDATE")) return "BEFORE_UPDATE";
    if (std.ascii.eqlIgnoreCase(value, "BEFORE_DELETE")) return "BEFORE_DELETE";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_INSERT")) return "AFTER_INSERT";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_UPDATE")) return "AFTER_UPDATE";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_DELETE")) return "AFTER_DELETE";
    if (std.ascii.eqlIgnoreCase(value, "AFTER_UNDELETE")) return "AFTER_UNDELETE";
    return null;
}

pub fn convertSObjectFieldAccess(gpa: std.mem.Allocator, text: []const u8) anyerror![]u8 {
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

pub fn shouldSkipSObjectFieldAccessBase(base_expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, base_expr, " \t");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "Database")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "System")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "Component")) return true;
    if (startsWithIgnoreCase(trimmed, "Component.")) return true;
    return false;
}
