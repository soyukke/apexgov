const line_and_expr = @import("../line_and_expr.zig");
const std = @import("std");
const util = @import("../util.zig");

const getas = @import("getas.zig");

const CompatibilityState = getas.CompatibilityState;

const containsIgnoreCaseSubstring = util.containsIgnoreCaseSubstring;
const containsWordIgnoreCase = util.containsWordIgnoreCase;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const findMatchingAngle = util.findMatchingAngle;
const findMatchingAngleBackward = util.findMatchingAngleBackward;
const findMatchingBrace = util.findMatchingBrace;
const findMatchingParen = util.findMatchingParen;
const findMatchingParenBackward = util.findMatchingParenBackward;
const indexOfWordIgnoreCase = util.indexOfWordIgnoreCase;
const isIdentifierChar = util.isIdentifierChar;
const isLikelyTypeReferenceIdentifier = util.isLikelyTypeReferenceIdentifier;
const isSimpleBindReference = line_and_expr.isSimpleBindReference;
const isSimpleIdentifierOrPath = util.isSimpleIdentifierOrPath;
const isSoqlBindNameChar = line_and_expr.isSoqlBindNameChar;
const lastIdentifier = util.lastIdentifier;
const leadingIdentifier = util.leadingIdentifier;
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;

pub fn isMethodLikeSignatureLine(line: []const u8) bool {
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
    return close + 1 < line.len;
}

pub fn extractTypedDeclarationSection(line: []const u8, type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (startsWithWordIgnoreCase(trimmed, "for")) return null;

    const semi = std.mem.lastIndexOfScalar(u8, trimmed, ';') orelse return null;
    const type_pos = indexOfWordIgnoreCase(trimmed, type_name) orelse return null;
    if (type_pos > 0 and isIdentifierChar(trimmed[type_pos - 1])) return null;

    const after_type = type_pos + type_name.len;
    if (after_type >= semi or !std.ascii.isWhitespace(trimmed[after_type])) return null;

    const section = std.mem.trim(u8, trimmed[after_type..semi], " \t");
    if (section.len == 0) return null;
    return section;
}

pub fn isSignedIntegerLiteral(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[0] == '+' or text[0] == '-') {
        if (text.len == 1) return false;
        i = 1;
    }
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isDigit(text[i])) return false;
    }
    return true;
}

pub fn isSignedDecimalZeroLiteral(text: []const u8) bool {
    if (text.len < 3) return false;
    var i: usize = 0;
    if (text[0] == '+' or text[0] == '-') {
        if (text.len < 4) return false;
        i = 1;
    }
    var dot: ?usize = null;
    while (i < text.len) : (i += 1) {
        if (text[i] == '.') {
            if (dot != null) return false;
            dot = i;
            continue;
        }
        if (!std.ascii.isDigit(text[i])) return false;
    }
    const point = dot orelse return false;
    if (point == 0 or point + 1 >= text.len) return false;
    for (text[(point + 1)..]) |ch| {
        if (ch != '0') return false;
    }
    return true;
}

pub fn parseStringLiteralContents(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return null;
    return trimmed[1 .. trimmed.len - 1];
}

pub fn countUppercaseChars(text: []const u8) usize {
    var count: usize = 0;
    for (text) |ch| {
        if (std.ascii.isUpper(ch)) count += 1;
    }
    return count;
}

pub fn lowercaseIdentifier(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, text);
    _ = std.ascii.lowerString(out, out);
    return out;
}

pub fn isImportOrPackageLineAt(text: []const u8, index: usize) bool {
    const line_start = blk: {
        if (std.mem.lastIndexOfScalar(u8, text[0..@min(index, text.len)], '\n')) |pos| break :blk pos + 1;
        break :blk 0;
    };
    var line_end = index;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line = std.mem.trim(u8, text[line_start..line_end], " \t\r");
    return startsWithWordIgnoreCase(line, "import") or startsWithWordIgnoreCase(line, "package");
}

pub fn findTopLevelStatementSemicolon(text: []const u8, start: usize) ?usize {
    var i = start;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var state: CompatibilityState = .normal;
    while (i < text.len) : (i += 1) {
        switch (state) {
            .normal => {
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .line_comment;
                    i += 1;
                    continue;
                }
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    state = .block_comment;
                    i += 1;
                    continue;
                }
                if (text[i] == '"') {
                    state = .string_literal;
                    continue;
                }
                if (text[i] == '\'') {
                    state = .char_literal;
                    continue;
                }
                if (text[i] == '(') {
                    paren_depth += 1;
                    continue;
                }
                if (text[i] == ')' and paren_depth > 0) {
                    paren_depth -= 1;
                    continue;
                }
                if (text[i] == '[') {
                    bracket_depth += 1;
                    continue;
                }
                if (text[i] == ']' and bracket_depth > 0) {
                    bracket_depth -= 1;
                    continue;
                }
                if (text[i] == '{') {
                    brace_depth += 1;
                    continue;
                }
                if (text[i] == '}' and brace_depth > 0) {
                    brace_depth -= 1;
                    continue;
                }
                if (text[i] == ';' and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    return i;
                }
            },
            .line_comment => {
                if (text[i] == '\n') state = .normal;
            },
            .block_comment => {
                if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    state = .normal;
                    i += 1;
                    continue;
                }
            },
            .string_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 1;
                    continue;
                }
                if (text[i] == '"') state = .normal;
            },
            .char_literal => {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 1;
                    continue;
                }
                if (text[i] == '\'') state = .normal;
            },
        }
    }
    return null;
}

pub fn extractGetAsCallStringLiteralFieldName(call_text: []const u8) ?[]const u8 {
    const open = blk: {
        if (std.mem.indexOf(u8, call_text, ".getAs")) |dot| {
            const open_idx = std.mem.indexOfScalarPos(u8, call_text, dot + ".getAs".len, '(') orelse return null;
            break :blk open_idx;
        }
        if (startsWithIgnoreCase(call_text, "ApexSwitch.getAs")) {
            const open_idx = std.mem.indexOfScalar(u8, call_text, '(') orelse return null;
            break :blk open_idx;
        }
        return null;
    };
    const close = findMatchingParen(call_text, open) orelse return null;
    const args = std.mem.trim(u8, call_text[(open + 1)..close], " \t");
    if (args.len < 2 or args[0] != '"' or args[args.len - 1] != '"') return null;
    return args[1 .. args.len - 1];
}

pub fn containsFieldKeywordToken(field_name: []const u8, keyword: []const u8) bool {
    if (field_name.len == 0 or keyword.len == 0 or keyword.len > field_name.len) return false;

    var i: usize = 0;
    while (i + keyword.len <= field_name.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(field_name[i .. i + keyword.len], keyword)) continue;

        const left_ok = if (i == 0)
            true
        else blk: {
            const prev = field_name[i - 1];
            const cur = field_name[i];
            if (!std.ascii.isAlphabetic(prev)) break :blk true;
            break :blk std.ascii.isLower(prev) and std.ascii.isUpper(cur);
        };
        if (!left_ok) continue;

        const right = i + keyword.len;
        const right_ok = if (right >= field_name.len)
            true
        else blk: {
            const prev = field_name[right - 1];
            const next = field_name[right];
            if (!std.ascii.isAlphabetic(next)) break :blk true;
            break :blk std.ascii.isLower(prev) and std.ascii.isUpper(next);
        };
        if (!right_ok) continue;

        return true;
    }
    return false;
}

pub fn fieldNameLooksNumeric(field_name: []const u8) bool {
    if (containsFieldKeywordToken(field_name, "account") or
        containsFieldKeywordToken(field_name, "contact") or
        containsFieldKeywordToken(field_name, "name") or
        containsFieldKeywordToken(field_name, "country") or
        containsFieldKeywordToken(field_name, "state") or
        containsFieldKeywordToken(field_name, "city") or
        containsFieldKeywordToken(field_name, "street"))
    {
        return false;
    }
    return containsFieldKeywordToken(field_name, "amount") or
        containsFieldKeywordToken(field_name, "percent") or
        containsFieldKeywordToken(field_name, "total") or
        containsFieldKeywordToken(field_name, "balance") or
        containsFieldKeywordToken(field_name, "ratio") or
        containsFieldKeywordToken(field_name, "rate") or
        containsFieldKeywordToken(field_name, "cost") or
        containsFieldKeywordToken(field_name, "price") or
        containsFieldKeywordToken(field_name, "quantity") or
        containsFieldKeywordToken(field_name, "count") or
        containsFieldKeywordToken(field_name, "number") or
        containsFieldKeywordToken(field_name, "day") or
        containsFieldKeywordToken(field_name, "version") or
        containsFieldKeywordToken(field_name, "integer") or
        containsFieldKeywordToken(field_name, "frequency") or
        containsFieldKeywordToken(field_name, "sort") or
        containsFieldKeywordToken(field_name, "forecast");
}

pub fn fieldNameLooksNonNumeric(field_name: []const u8) bool {
    return containsIgnoreCaseSubstring(field_name, "enabled") or
        containsIgnoreCaseSubstring(field_name, "active") or
        containsIgnoreCaseSubstring(field_name, "paid") or
        containsIgnoreCaseSubstring(field_name, "written_off") or
        endsWithIgnoreCase(field_name, "__r") or
        containsFieldKeywordToken(field_name, "type") or
        containsIgnoreCaseSubstring(field_name, "_id") or
        endsWithIgnoreCase(field_name, "Id") or
        std.mem.eql(u8, field_name, "Id");
}

pub fn fieldNameLooksIdLike(field_name: []const u8) bool {
    return std.mem.eql(u8, field_name, "Id") or
        endsWithIgnoreCase(field_name, "Id") or
        containsIgnoreCaseSubstring(field_name, "_id") or
        endsWithIgnoreCase(field_name, "__c");
}

pub fn fieldNameLooksBoolean(field_name: []const u8) bool {
    return containsIgnoreCaseSubstring(field_name, "enabled") or
        containsIgnoreCaseSubstring(field_name, "active") or
        containsIgnoreCaseSubstring(field_name, "paid") or
        containsIgnoreCaseSubstring(field_name, "primary") or
        containsIgnoreCaseSubstring(field_name, "default") or
        containsIgnoreCaseSubstring(field_name, "individual") or
        containsIgnoreCaseSubstring(field_name, "viewed") or
        containsIgnoreCaseSubstring(field_name, "_on") or
        containsIgnoreCaseSubstring(field_name, "private") or
        containsIgnoreCaseSubstring(field_name, "written_off") or
        containsIgnoreCaseSubstring(field_name, "deleted") or
        containsIgnoreCaseSubstring(field_name, "closed") or
        containsIgnoreCaseSubstring(field_name, "won") or
        containsIgnoreCaseSubstring(field_name, "html") or
        startsWithIgnoreCase(field_name, "is") or
        startsWithIgnoreCase(field_name, "has") or
        startsWithIgnoreCase(field_name, "can");
}

pub fn countByte(text: []const u8, needle: u8) isize {
    var count: isize = 0;
    for (text) |ch| {
        if (ch == needle) count += 1;
    }
    return count;
}

pub fn extractGeneratedJavaClassName(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        const prefixes = [_][]const u8{ "public class ", "public interface ", "public enum " };
        for (prefixes) |prefix| {
            if (!startsWithIgnoreCase(line, prefix)) continue;
            return leadingIdentifier(line[prefix.len..]);
        }
    }
    return null;
}

pub fn extractDeclaredVariableName(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(line, prefix)) return null;
    var cursor = prefix.len;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    const name_start = cursor;
    while (cursor < line.len and isIdentifierChar(line[cursor])) : (cursor += 1) {}
    if (cursor == name_start) return null;
    return line[name_start..cursor];
}

pub fn extractTypedVariableName(line: []const u8, type_name: []const u8) ?[]const u8 {
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

pub fn extractParameterizedTypeVariableName(line: []const u8, type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;

    var i: usize = 0;
    while (i + type_name.len < trimmed.len) : (i += 1) {
        if (!startsWithIgnoreCase(trimmed[i..], type_name)) continue;
        if (i > 0 and isIdentifierChar(trimmed[i - 1])) continue;

        var cursor = i + type_name.len;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        if (cursor >= trimmed.len or trimmed[cursor] != '<') continue;
        const close = findMatchingAngle(trimmed, cursor) orelse continue;

        cursor = close + 1;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        const name_start = cursor;
        while (cursor < trimmed.len and isIdentifierChar(trimmed[cursor])) : (cursor += 1) {}
        if (cursor == name_start) return null;
        return trimmed[name_start..cursor];
    }
    return null;
}

pub fn appendUniqueIdentifier(gpa: std.mem.Allocator, names: *std.ArrayList([]u8), candidate: []const u8) !void {
    for (names.items) |name| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return;
    }
    try names.append(gpa, try gpa.dupe(u8, candidate));
}

pub fn identifierInList(names: []const []u8, candidate: []const u8) bool {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

pub fn extractForEachVariableNameOfType(line: []const u8, type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!startsWithIgnoreCase(trimmed, "for")) return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    var cursor = open + 1;
    while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
    if (!startsWithIgnoreCase(trimmed[cursor..], type_name)) return null;
    cursor += type_name.len;
    if (cursor >= trimmed.len or !std.ascii.isWhitespace(trimmed[cursor])) return null;

    while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
    const name_start = cursor;
    while (cursor < trimmed.len and isIdentifierChar(trimmed[cursor])) : (cursor += 1) {}
    if (cursor == name_start) return null;
    return trimmed[name_start..cursor];
}

pub const SimpleAssignment = struct {
    lhs: []const u8,
    rhs: []const u8,
};

pub fn extractSimpleAssignment(line: []const u8) ?SimpleAssignment {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;

    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    if (eq + 1 < trimmed.len and trimmed[eq + 1] == '=') return null;
    if (eq > 0 and (trimmed[eq - 1] == '=' or trimmed[eq - 1] == '!' or trimmed[eq - 1] == '<' or trimmed[eq - 1] == '>')) return null;

    const lhs_expr = std.mem.trim(u8, trimmed[0..eq], " \t");
    if (lhs_expr.len == 0) return null;
    var lhs_end = lhs_expr.len;
    while (lhs_end > 0 and std.ascii.isWhitespace(lhs_expr[lhs_end - 1])) : (lhs_end -= 1) {}
    if (lhs_end == 0) return null;
    var lhs_start = lhs_end;
    while (lhs_start > 0 and isIdentifierChar(lhs_expr[lhs_start - 1])) : (lhs_start -= 1) {}
    if (lhs_start == lhs_end) return null;
    const lhs_name = lhs_expr[lhs_start..lhs_end];

    const rhs_full = trimmed[(eq + 1)..];
    const semicolon = std.mem.indexOfScalar(u8, rhs_full, ';') orelse rhs_full.len;
    const rhs_expr = std.mem.trim(u8, rhs_full[0..semicolon], " \t");
    if (rhs_expr.len == 0) return null;

    return .{ .lhs = lhs_name, .rhs = rhs_expr };
}

pub const GetAsLikeCall = struct {
    start: usize,
    end: usize,
};

pub fn matchGetAsLikeCall(text: []const u8, i: usize) ?GetAsLikeCall {
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

pub fn findPreviousNonWhitespace(text: []const u8, before: usize) ?usize {
    var i = before;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return i;
    }
    return null;
}

pub fn findNextNonWhitespace(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isWhitespace(text[i])) return i;
    }
    return null;
}

pub fn containsGetAsLikeCall(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (matchGetAsLikeCall(text, i) != null) return true;
    }
    return false;
}

pub fn findTopLevelColon(text: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '(' or text[i] == '[' or text[i] == '{') depth += 1;
        if (text[i] == ')' or text[i] == ']' or text[i] == '}') depth -= 1;
        if (depth == 0 and text[i] == ':') return i;
    }
    return null;
}

pub fn replaceLiteralAll(gpa: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
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

pub fn replaceSectionBetweenMarkers(
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

pub fn replaceMethodBodyBySignature(
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

pub fn looksLikePublicMethodSignatureLine(line: []const u8) bool {
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

pub fn appendUniqueOwnedName(
    gpa: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    name: []const u8,
) !void {
    if (containsIgnoreCaseOwnedName(names.items, name)) return;
    try names.append(gpa, try gpa.dupe(u8, name));
}

pub fn containsIgnoreCaseOwnedName(items: []const []u8, name: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item, name)) return true;
    }
    return false;
}

pub fn containsIgnoreCaseNameSlice(items: []const []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item, name)) return true;
    }
    return false;
}

pub const RelationalOperator = enum {
    gt,
    lt,
    gte,
    lte,
};

pub const RelationalMatch = struct {
    op: RelationalOperator,
    start: usize,
    len: usize,
};

pub fn findTopLevelTernary(text: []const u8) ?struct { question: usize, colon: usize } {
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

pub fn findTopLevelRelationalMatch(text: []const u8) ?RelationalMatch {
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

pub fn isLikelyGenericCloseAngle(text: []const u8, angle_index: usize) bool {
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

pub fn nextNonWhitespaceChar(text: []const u8, start: usize) ?u8 {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isWhitespace(text[i])) return text[i];
    }
    return null;
}

pub fn prevNonWhitespaceChar(text: []const u8, before: usize) ?u8 {
    var i = before;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return text[i];
    }
    return null;
}

pub fn hasWhitespaceAroundOperator(text: []const u8, start: usize, len: usize) bool {
    if (start + len > text.len) return false;
    const left_ok = if (start == 0) false else std.ascii.isWhitespace(text[start - 1]);
    const right_idx = start + len;
    const right_ok = if (right_idx >= text.len) false else std.ascii.isWhitespace(text[right_idx]);
    return left_ok or right_ok;
}

pub fn isLikelyStringishComparisonOperand(expr: []const u8) bool {
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

pub fn isLikelyDateishComparisonOperand(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOf(u8, trimmed, "Date.") != null or
        std.mem.indexOf(u8, trimmed, "DateTime.") != null or
        std.mem.indexOf(u8, trimmed, ".addDays(") != null or
        std.mem.indexOf(u8, trimmed, ".addMonths(") != null or
        std.mem.indexOf(u8, trimmed, ".addYears(") != null or
        std.mem.indexOf(u8, trimmed, ".year()") != null or
        std.mem.indexOf(u8, trimmed, ".month()") != null or
        std.mem.indexOf(u8, trimmed, ".day()") != null)
    {
        return true;
    }
    if (std.mem.indexOf(u8, trimmed, ".getAs(\"") != null and
        (std.mem.indexOf(u8, trimmed, "Date") != null or std.mem.indexOf(u8, trimmed, "date") != null))
    {
        return true;
    }
    if (lastIdentifier(trimmed)) |identifier| {
        if (endsWithIgnoreCase(identifier, "Date") or
            endsWithIgnoreCase(identifier, "Datetime") or
            endsWithIgnoreCase(identifier, "Day"))
            return true;
    }
    return false;
}

/// Wraps comparisons involving safe-navigation ternary results with ApexCompare
/// to avoid NPE from Java auto-unboxing of null.
/// e.g. `((x) == null ? null : (x).length()) > 2` → `ApexCompare.gt(((x) == null ? null : (x).length()), 2)`

pub fn findTopLevelLogicalOperator(text: []const u8) ?struct { start: usize } {
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

pub fn findTopLevelNullCoalescingOperator(text: []const u8) ?usize {
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

pub fn isLikelyCastStart(text: []const u8, open_paren: usize) bool {
    if (open_paren == 0) return true;
    var cursor = open_paren;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor == 0) return true;
    const prev = text[cursor - 1];
    if (isIdentifierChar(prev) or prev == ')' or prev == ']' or prev == '.') return false;
    return true;
}

pub fn isLikelyCastFollowToken(text: []const u8, start: usize) bool {
    var cursor = start;
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
    if (cursor >= text.len) return false;
    const next = text[cursor];
    if (next == ';' or next == ',' or next == ':' or next == '?' or next == ')' or next == ']' or next == '}') {
        return false;
    }
    return true;
}

pub fn isLikelyCastType(raw: []const u8) bool {
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

pub fn isSelfQualifiedTypeReference(type_name: []const u8, owner_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_name, " \t");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, owner_name)) return true;
    if (trimmed.len <= owner_name.len) return false;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..owner_name.len], owner_name)) return false;
    return trimmed[owner_name.len] == '.';
}

pub fn typeReferenceObjectName(path: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, path, " \t");
    if (trimmed.len == 0) return "";

    if (startsWithIgnoreCase(trimmed, "Schema.")) {
        const after_schema = std.mem.trimLeft(u8, trimmed["Schema.".len..], " \t");
        if (leadingIdentifier(after_schema)) |name| return name;
    }

    return lastIdentifier(trimmed) orelse "";
}

pub fn isStaticValueAccessPathExpression(expr: []const u8) bool {
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

pub fn findMemberAccessBaseStart(text: []const u8, dot_pos: usize) ?usize {
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

pub fn collectSoqlBindNamesFromJavaLiteral(
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

pub fn isJavaStringLiteral(text: []const u8) bool {
    return text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"';
}

pub fn findIndexAccessBaseStart(text: []const u8, bracket_pos: usize) ?usize {
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

pub fn extendOverConstructorNewKeyword(text: []const u8, initial_start: usize) usize {
    if (initial_start == 0) return initial_start;
    var cursor = initial_start;
    while (cursor > 0 and std.ascii.isWhitespace(text[cursor - 1])) : (cursor -= 1) {}
    if (cursor < "new".len) return initial_start;

    const keyword_start = cursor - "new".len;
    if (!startsWithIgnoreCase(text[keyword_start..], "new")) return initial_start;
    if (keyword_start > 0 and isIdentifierChar(text[keyword_start - 1])) return initial_start;
    return keyword_start;
}

pub fn extendQualifiedIdentifierPathLeft(text: []const u8, initial_start: usize) usize {
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

pub fn extendIndexBaseLeft(text: []const u8, initial_start: usize) usize {
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

pub fn containsKnownObjectIdentifier(object_names: []const []u8, expr: []const u8) bool {
    for (object_names) |name| {
        if (containsStandaloneIdentifier(expr, name)) return true;
    }
    return false;
}

pub fn findSimpleEqualityOperator(expr: []const u8) ?struct { start: usize, is_ne: bool } {
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

pub fn containsStandaloneIdentifier(text: []const u8, identifier: []const u8) bool {
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

pub fn findLeftOperandStart(text: []const u8, op_pos: usize) usize {
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
            return skipWhitespace(text, pos + 1, op_pos);
        }
        if (paren_depth > 0) continue;
        if (ch == '&' and pos > 0 and text[pos - 1] == '&') return skipWhitespace(text, pos + 1, op_pos);
        if (ch == '|' and pos > 0 and text[pos - 1] == '|') return skipWhitespace(text, pos + 1, op_pos);
        if (ch == ',' or ch == ';' or ch == '{') return skipWhitespace(text, pos + 1, op_pos);
        if (ch == '!') return skipWhitespace(text, pos + 1, op_pos);
        // Stop at assignment = (single = not part of ==, !=, <=, >=)
        if (ch == '=' and
            (pos + 1 >= text.len or text[pos + 1] != '=') and
            (pos == 0 or (text[pos - 1] != '!' and text[pos - 1] != '<' and text[pos - 1] != '>' and text[pos - 1] != '=')))
            return skipWhitespace(text, pos + 1, op_pos);
    }
    return 0;
}

pub fn skipWhitespace(text: []const u8, start: usize, limit: usize) usize {
    var pos = start;
    while (pos < limit and (text[pos] == ' ' or text[pos] == '\t')) pos += 1;
    return pos;
}

pub fn findExpressionEnd(text: []const u8, start: usize) usize {
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

pub fn findCastOperandEnd(text: []const u8, start: usize) usize {
    var pos = start;
    var paren_depth: i32 = 0;
    var in_single = false;
    var in_double = false;
    var escaped = false;
    while (pos < text.len) : (pos += 1) {
        const ch = text[pos];
        if (in_single) {
            if (ch == '\'' and pos + 1 < text.len and text[pos + 1] == '\'') {
                pos += 1;
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

        if (paren_depth == 0) {
            if (ch == ')' or ch == ',' or ch == ';' or ch == ':') return pos;
            if (ch == '&' and pos + 1 < text.len and text[pos + 1] == '&') return pos;
            if (ch == '|' and pos + 1 < text.len and text[pos + 1] == '|') return pos;
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
    }
    return pos;
}

pub fn isNumericLiteral(text: []const u8) bool {
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

pub fn isLikelySObjectTypeForInstanceof(type_name: []const u8) bool {
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

pub fn isLikelyCustomSObjectTypeName(type_name: []const u8) bool {
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

pub fn isWithinImportOrPackageDeclaration(text: []const u8, pos: usize) bool {
    if (pos >= text.len) return false;
    var line_start = pos;
    while (line_start > 0 and text[line_start - 1] != '\n') : (line_start -= 1) {}
    var line_end = pos;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line = std.mem.trim(u8, text[line_start..line_end], " \t");
    if (line.len == 0) return false;
    return startsWithWordIgnoreCase(line, "import") or startsWithWordIgnoreCase(line, "package");
}

pub fn isWithinAnnotationQualifiedChain(text: []const u8, dot_pos: usize) bool {
    if (dot_pos == 0 or dot_pos >= text.len) return false;
    var cursor = dot_pos;
    while (cursor > 0 and (isIdentifierChar(text[cursor - 1]) or text[cursor - 1] == '.')) : (cursor -= 1) {}
    return cursor > 0 and text[cursor - 1] == '@';
}
