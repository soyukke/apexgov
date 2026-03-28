const std = @import("std");

// ─── String comparison ───────────────────────────────────────────────

pub fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

pub fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(
        haystack[haystack.len - needle.len ..],
        needle,
    );
}

pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    return indexOfIgnoreCasePos(haystack, 0, needle);
}

pub fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn startsWithWordIgnoreCase(haystack: []const u8, keyword: []const u8) bool {
    if (!startsWithIgnoreCase(haystack, keyword)) return false;
    if (haystack.len == keyword.len) return true;
    const next = haystack[keyword.len];
    return !isIdentifierChar(next);
}

pub fn containsIgnoreCaseSubstring(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

pub fn containsWordIgnoreCase(text: []const u8, word: []const u8) bool {
    return indexOfWordIgnoreCase(text, word) != null;
}

pub fn containsWord(text: []const u8, word: []const u8) bool {
    return indexOfWord(text, word) != null;
}

pub fn indexOfWord(text: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or text.len < word.len) return null;
    var i: usize = 0;
    while (i + word.len <= text.len) : (i += 1) {
        if (!std.mem.eql(u8, text[i .. i + word.len], word)) continue;
        const left_ok = i == 0 or !isIdentifierChar(text[i - 1]);
        const right_idx = i + word.len;
        const right_ok = right_idx == text.len or !isIdentifierChar(text[right_idx]);
        if (left_ok and right_ok) return i;
    }
    return null;
}

pub fn indexOfWordIgnoreCase(text: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or text.len < word.len) return null;
    var i: usize = 0;
    while (i + word.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) continue;
        const left_ok = i == 0 or !isIdentifierChar(text[i - 1]);
        const right_idx = i + word.len;
        const right_ok = right_idx == text.len or !isIdentifierChar(text[right_idx]);
        if (left_ok and right_ok) return i;
    }
    return null;
}

// ─── Identifier utilities ────────────────────────────────────────────

pub fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

pub fn isSimpleIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return false;
    for (value[1..]) |ch| {
        if (!isIdentifierChar(ch)) return false;
    }
    return true;
}

pub fn isSimpleIdentifierOrPath(text: []const u8) bool {
    if (text.len == 0) return false;
    var parts = std.mem.tokenizeScalar(u8, text, '.');
    var seen_part = false;
    while (parts.next()) |part| {
        if (!isSimpleIdentifier(part)) return false;
        seen_part = true;
    }
    return seen_part;
}

pub fn firstIdentifier(text: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < text.len and !isIdentifierChar(text[idx])) : (idx += 1) {}
    if (idx == text.len) return null;
    const start = idx;
    while (idx < text.len and isIdentifierChar(text[idx])) : (idx += 1) {}
    return text[start..idx];
}

pub fn leadingIdentifier(text: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < text.len and std.ascii.isWhitespace(text[idx])) : (idx += 1) {}
    if (idx >= text.len or !isIdentifierChar(text[idx])) return null;
    const start = idx;
    while (idx < text.len and isIdentifierChar(text[idx])) : (idx += 1) {}
    return text[start..idx];
}

pub fn lastIdentifier(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    var end = text.len;
    while (end > 0 and !isIdentifierChar(text[end - 1])) : (end -= 1) {}
    if (end == 0) return null;
    var start = end;
    while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
    return text[start..end];
}

pub const IdentifierSpan = struct {
    value: []const u8,
    start: usize,
    end: usize,
};

pub fn baseIdentifierBeforeDot(text: []const u8, dot_pos: usize) ?IdentifierSpan {
    if (dot_pos == 0) return null;
    var idx = dot_pos;
    while (idx > 0 and std.ascii.isWhitespace(text[idx - 1])) : (idx -= 1) {}
    if (idx == 0) return null;
    if (!isIdentifierChar(text[idx - 1])) return null;

    var start = idx - 1;
    while (start > 0 and isIdentifierChar(text[start - 1])) : (start -= 1) {}
    return .{
        .value = text[start..idx],
        .start = start,
        .end = idx,
    };
}

pub fn isLikelyTypeReferenceIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isUpper(name[0])) return true;

    if (startsWithIgnoreCase(name, "fflib_")) {
        var idx: usize = "fflib_".len;
        while (idx < name.len) : (idx += 1) {
            if (std.ascii.isUpper(name[idx])) return true;
        }
    }
    return false;
}

pub fn isLikelyQualifiedTypeChain(text: []const u8, base: IdentifierSpan) bool {
    if (base.start == 0) return false;
    if (text[base.start - 1] != '.') return false;

    const prev_span = baseIdentifierBeforeDot(text, base.start - 1) orelse return false;
    if (prev_span.value.len == 0 or base.value.len == 0) return false;

    if (!isLikelyTypeReferenceIdentifier(prev_span.value)) return false;
    if (isLikelyTypeReferenceIdentifier(base.value)) return true;
    return startsWithIgnoreCase(base.value, "inboundEmail");
}

pub fn isLikelyTypeReferencePathExpression(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfAny(u8, trimmed, "()[]{}")) |_| return false;
    if (!isSimpleIdentifierOrPath(trimmed)) return false;

    var parts = std.mem.tokenizeScalar(u8, trimmed, '.');
    const first = parts.next() orelse return false;
    if (!isLikelyTypeReferenceIdentifier(first)) return false;
    return true;
}

// ─── Type/keyword identification ─────────────────────────────────────

pub fn looksLikeTypeName(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '<') != null) return true;
    if (std.mem.indexOf(u8, trimmed, "[]") != null) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "int")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "long")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "double")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "float")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "short")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "byte")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "boolean")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "char")) return true;
    return isTypeIdentifierPath(trimmed);
}

pub fn isTypeIdentifierPath(raw: []const u8) bool {
    var parts = std.mem.splitScalar(u8, raw, '.');
    var saw_segment = false;
    while (parts.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) return false;
        saw_segment = true;
        if (!std.ascii.isAlphabetic(segment[0]) and segment[0] != '_') return false;
        for (segment[1..]) |ch| {
            if (!isIdentifierChar(ch)) return false;
        }
    }
    return saw_segment;
}

pub fn isIdentifierPathExpression(raw: []const u8) bool {
    var parts = std.mem.splitScalar(u8, raw, '.');
    var saw_segment = false;
    while (parts.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (!isSimpleIdentifier(segment)) return false;
        saw_segment = true;
    }
    return saw_segment;
}

pub fn isDeclarationModifier(token: []const u8, allow_visibility: bool) bool {
    if (std.ascii.eqlIgnoreCase(token, "final")) return true;
    if (std.ascii.eqlIgnoreCase(token, "static")) return true;
    if (std.ascii.eqlIgnoreCase(token, "transient")) return true;
    if (!allow_visibility) return false;
    return std.ascii.eqlIgnoreCase(token, "public") or
        std.ascii.eqlIgnoreCase(token, "private") or
        std.ascii.eqlIgnoreCase(token, "protected") or
        std.ascii.eqlIgnoreCase(token, "global");
}

pub fn normalizeDeclarationModifier(token: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(token, "global")) return "public";
    if (std.ascii.eqlIgnoreCase(token, "public")) return "public";
    if (std.ascii.eqlIgnoreCase(token, "private")) return "private";
    if (std.ascii.eqlIgnoreCase(token, "protected")) return "protected";
    if (std.ascii.eqlIgnoreCase(token, "final")) return "final";
    if (std.ascii.eqlIgnoreCase(token, "static")) return "static";
    if (std.ascii.eqlIgnoreCase(token, "transient")) return "transient";
    return token;
}

pub fn isControlKeyword(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, "if") or
        std.ascii.eqlIgnoreCase(word, "for") or
        std.ascii.eqlIgnoreCase(word, "while") or
        std.ascii.eqlIgnoreCase(word, "switch") or
        std.ascii.eqlIgnoreCase(word, "catch") or
        std.ascii.eqlIgnoreCase(word, "else") or
        std.ascii.eqlIgnoreCase(word, "return") or
        std.ascii.eqlIgnoreCase(word, "do");
}

pub fn isLikelyNonMethodLeadKeyword(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, "select") or
        std.ascii.eqlIgnoreCase(word, "from") or
        std.ascii.eqlIgnoreCase(word, "where") or
        std.ascii.eqlIgnoreCase(word, "order") or
        std.ascii.eqlIgnoreCase(word, "group") or
        std.ascii.eqlIgnoreCase(word, "having") or
        std.ascii.eqlIgnoreCase(word, "limit") or
        std.ascii.eqlIgnoreCase(word, "offset") or
        std.ascii.eqlIgnoreCase(word, "insert") or
        std.ascii.eqlIgnoreCase(word, "update") or
        std.ascii.eqlIgnoreCase(word, "upsert") or
        std.ascii.eqlIgnoreCase(word, "delete") or
        std.ascii.eqlIgnoreCase(word, "undelete") or
        std.ascii.eqlIgnoreCase(word, "merge");
}

pub fn isMethodModifierToken(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "public") or
        std.ascii.eqlIgnoreCase(token, "private") or
        std.ascii.eqlIgnoreCase(token, "protected") or
        std.ascii.eqlIgnoreCase(token, "global") or
        std.ascii.eqlIgnoreCase(token, "static") or
        std.ascii.eqlIgnoreCase(token, "final") or
        std.ascii.eqlIgnoreCase(token, "virtual") or
        std.ascii.eqlIgnoreCase(token, "override") or
        std.ascii.eqlIgnoreCase(token, "abstract") or
        std.ascii.eqlIgnoreCase(token, "testmethod") or
        std.ascii.eqlIgnoreCase(token, "webservice") or
        std.ascii.eqlIgnoreCase(token, "transient");
}

// ─── Annotation detection ────────────────────────────────────────────

pub fn isIsTestAnnotation(line: []const u8) bool {
    if (line.len < 7) return false;
    if (line[0] != '@') return false;
    return startsWithIgnoreCase(line, "@istest");
}

pub fn isTestAnnotationSeeAllDataTrue(annotation_line: []const u8) bool {
    if (!isIsTestAnnotation(annotation_line)) return false;
    const open = std.mem.indexOfScalar(u8, annotation_line, '(') orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, annotation_line, ')') orelse return false;
    if (close <= open + 1) return false;

    const args = annotation_line[(open + 1)..close];
    const key_idx = indexOfIgnoreCase(args, "seealldata") orelse return false;
    var cursor = key_idx + "seealldata".len;
    while (cursor < args.len and (args[cursor] == ' ' or args[cursor] == '\t')) : (cursor += 1) {}
    if (cursor >= args.len or args[cursor] != '=') return false;
    cursor += 1;
    while (cursor < args.len and (args[cursor] == ' ' or args[cursor] == '\t')) : (cursor += 1) {}
    return startsWithWordIgnoreCase(args[cursor..], "true");
}

pub fn isTestSetupAnnotation(line: []const u8) bool {
    if (line.len < 10) return false;
    if (line[0] != '@') return false;
    return startsWithIgnoreCase(line, "@testsetup");
}

pub fn isTestVisibleAnnotation(line: []const u8) bool {
    if (line.len < 12) return false;
    if (line[0] != '@') return false;
    return startsWithIgnoreCase(line, "@testvisible");
}

// ─── Matching/parsing ────────────────────────────────────────────────

pub fn findMatchingParen(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '(') return null;

    var depth: i32 = 0;
    var in_single = false;
    var single_escaped = false;
    var in_double = false;
    var i: usize = open_index;
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

        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

pub fn findMatchingParenBackward(text: []const u8, close_index: usize) ?usize {
    if (close_index >= text.len or text[close_index] != ')') return null;

    var i: usize = close_index + 1;
    while (i > 0) {
        i -= 1;
        if (text[i] != '(') continue;
        const close = findMatchingParen(text, i) orelse continue;
        if (close == close_index) return i;
    }
    return null;
}

pub fn findMatchingAngleBackward(text: []const u8, close_index: usize) ?usize {
    if (close_index >= text.len or text[close_index] != '>') return null;

    var i: usize = close_index + 1;
    while (i > 0) {
        i -= 1;
        if (text[i] != '<') continue;
        const close = findMatchingAngle(text, i) orelse continue;
        if (close == close_index) return i;
    }
    return null;
}

pub fn findMatchingAngle(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '<') return null;
    var depth: i32 = 0;
    var i: usize = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '<') {
            depth += 1;
        } else if (ch == '>') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

pub fn findMatchingBrace(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '{') return null;

    var depth: i32 = 0;
    var in_single = false;
    var single_escaped = false;
    var in_double = false;
    var i: usize = open_index;
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

        if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

pub fn findMatchingSquareBracket(text: []const u8, open_index: usize) ?usize {
    if (open_index >= text.len or text[open_index] != '[') return null;

    var depth: i32 = 0;
    var in_single = false;
    var single_escaped = false;
    var in_double = false;
    var i: usize = open_index;
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

        if (ch == '[') {
            depth += 1;
        } else if (ch == ']') {
            depth -= 1;
            if (depth == 0) return i;
            if (depth < 0) return null;
        }
    }
    return null;
}

pub fn findTopLevelMapArrow(text: []const u8) ?usize {
    var in_single = false;
    var single_escaped = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
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
            if (in_single and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
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
            '=' => {
                if (text[i + 1] == '>' and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn findTopLevelAssignmentOperator(text: []const u8) ?usize {
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
            '=' => {
                if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0 or angle_depth != 0) continue;
                const prev = if (i > 0) text[i - 1] else 0;
                const next = if (i + 1 < text.len) text[i + 1] else 0;
                if (prev == '=' or prev == '!' or prev == '<' or prev == '>') continue;
                if (prev == '+' or prev == '-' or prev == '*' or prev == '/' or prev == '%' or prev == '&' or prev == '|' or prev == '^') continue;
                if (next == '=' or next == '>') continue;
                return i;
            },
            else => {},
        }
    }
    return null;
}

pub fn findTopLevelSafeNavigationOperator(text: []const u8) ?usize {
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
            '?' => {
                if (text[i + 1] == '.' and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn findLastTopLevelDot(text: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var last_dot: ?usize = null;

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
            '.' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    last_dot = i;
                }
            },
            else => {},
        }
    }
    return last_dot;
}

// ─── Deltas ──────────────────────────────────────────────────────────

pub fn braceDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var in_single = false;
    var in_double = false;
    var single_escaped = false;
    var double_escaped = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];

        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < line.len and line[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') {
                in_single = false;
            }
            continue;
        }

        if (in_double) {
            if (double_escaped) {
                double_escaped = false;
                continue;
            }
            if (ch == '\\') {
                double_escaped = true;
                continue;
            }
            if (ch == '"') {
                in_double = false;
            }
            continue;
        }

        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '{' => delta += 1,
            '}' => delta -= 1,
            else => {},
        }
    }
    return delta;
}

pub fn parenDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var in_single = false;
    var in_double = false;
    var single_escaped = false;
    var double_escaped = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];

        if (in_single) {
            if (single_escaped) {
                single_escaped = false;
                continue;
            }
            if (ch == '\\') {
                single_escaped = true;
                continue;
            }
            if (ch == '\'' and i + 1 < line.len and line[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }

        if (in_double) {
            if (double_escaped) {
                double_escaped = false;
                continue;
            }
            if (ch == '\\') {
                double_escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }

        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '(' => delta += 1,
            ')' => delta -= 1,
            else => {},
        }
    }
    return delta;
}

// ─── String processing ──────────────────────────────────────────────

pub fn splitWhitespace(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        try out.append(gpa, token);
    }
    return out;
}

pub fn appendFmt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
}

pub fn appendEscapedJavaStringChar(gpa: std.mem.Allocator, out: *std.ArrayList(u8), ch: u8) !void {
    switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, ch),
    }
}

pub fn quoteJavaStringLiteral(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.append(gpa, '"');
    for (raw) |ch| {
        try appendEscapedJavaStringChar(gpa, &out, ch);
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

pub fn indexOfSoqlBracketSelect(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '[') continue;
        const tail = line[(i + 1)..];
        const trimmed = std.mem.trimLeft(u8, tail, " \t");
        if (startsWithIgnoreCase(trimmed, "SELECT")) return i;
    }
    return null;
}

pub fn isInsideComment(text: []const u8, pos: usize) bool {
    // Check if pos is inside a // or /* */ comment by scanning from the last newline
    var line_start: usize = 0;
    if (pos > 0) {
        var i = pos - 1;
        while (i > 0) : (i -= 1) {
            if (text[i] == '\n') {
                line_start = i + 1;
                break;
            }
        }
    }
    // Check for // comment
    const line_to_pos = text[line_start..pos];
    if (std.mem.indexOf(u8, line_to_pos, "//")) |slash_pos| {
        // Ensure the // is not inside a string
        var in_string = false;
        for (line_to_pos[0..slash_pos]) |ch| {
            if (ch == '\'') in_string = !in_string;
        }
        if (!in_string) return true;
    }
    // Check for /* */ block comment
    var i: usize = 0;
    var in_block = false;
    while (i < pos) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            in_block = true;
            i += 2;
            continue;
        }
        if (in_block and i + 1 < text.len and text[i] == '*' and text[i + 1] == '/') {
            in_block = false;
            i += 2;
            continue;
        }
        i += 1;
    }
    return in_block;
}

// ─── File utilities ──────────────────────────────────────────────────

pub fn isApexClassSource(path: []const u8) bool {
    return std.fs.path.extension(path).len == 4 and std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".cls");
}

pub fn isApexTriggerSource(path: []const u8) bool {
    return std.fs.path.extension(path).len == 8 and std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".trigger");
}

pub fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn isValidPackageName(name: []const u8) bool {
    if (name.len == 0) return false;
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (!std.ascii.isAlphabetic(part[0]) and part[0] != '_') return false;
        for (part[1..]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        }
    }
    return true;
}

// ─── Whitespace ──────────────────────────────────────────────────────

pub fn skipApexCommentsAndWhitespace(text: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < text.len) {
        if (std.ascii.isWhitespace(text[cursor])) {
            cursor += 1;
            continue;
        }
        if (cursor + 1 < text.len and text[cursor] == '/' and text[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < text.len and text[cursor] != '\n') : (cursor += 1) {}
            continue;
        }
        if (cursor + 1 < text.len and text[cursor] == '/' and text[cursor + 1] == '*') {
            cursor += 2;
            while (cursor + 1 < text.len and !(text[cursor] == '*' and text[cursor + 1] == '/')) : (cursor += 1) {}
            if (cursor + 1 < text.len) {
                cursor += 2;
            }
            continue;
        }
        break;
    }
    return cursor;
}

pub fn skipInlineWhitespace(text: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
    return cursor;
}

pub fn skipAsciiWhitespace(text: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
    return cursor;
}

// ─── Control flow detection ──────────────────────────────────────────

pub fn isControlFlowLine(line: []const u8) bool {
    if (isDoWhileTailLine(line)) return true;
    if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) return true;
    const keywords = [_][]const u8{
        "if",       "else",    "for",    "while", "do",     "try",
        "catch",    "finally", "switch", "when",  "return", "break",
        "continue",
    };
    for (keywords) |keyword| {
        if (startsWithWordIgnoreCase(line, keyword)) return true;
    }
    return false;
}

pub fn isDoWhileTailLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 8 or trimmed[0] != '}') return false;

    var rest = std.mem.trimLeft(u8, trimmed[1..], " \t");
    if (!startsWithWordIgnoreCase(rest, "while")) return false;
    rest = std.mem.trimLeft(u8, rest["while".len..], " \t");
    if (rest.len == 0 or rest[0] != '(') return false;

    const close = findMatchingParen(rest, 0) orelse return false;
    const after = std.mem.trim(u8, rest[(close + 1)..], " \t");
    return after.len == 0 or std.mem.eql(u8, after, ";");
}

// ─── Additional structs and functions ────────────────────────────────

pub const TrailingIdentifierSplit = struct {
    head: []const u8,
    tail: []const u8,
};

pub fn splitTrailingIdentifierAtTopLevel(text: []const u8) ?TrailingIdentifierSplit {
    var in_single = false;
    var in_double = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var split_idx: ?usize = null;

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
            else => {
                if (std.ascii.isWhitespace(ch) and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    split_idx = i;
                }
            },
        }
    }

    if (split_idx == null) return null;
    const head = std.mem.trim(u8, text[0..split_idx.?], " \t");
    const tail = std.mem.trim(u8, text[(split_idx.? + 1)..], " \t");
    if (head.len == 0 or tail.len == 0) return null;
    if (!isSimpleIdentifier(tail)) return null;
    return .{
        .head = head,
        .tail = tail,
    };
}

pub const SObjectFieldLvalue = struct {
    base_expr: []const u8,
    field_name: []const u8,
};

pub const IndexedLvalue = struct {
    base_expr: []const u8,
    index_expr: []const u8,
};

pub fn parseJavaKeywordMemberLvalue(lhs: []const u8) ?SObjectFieldLvalue {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len == 0) return null;

    const dot_pos = findLastTopLevelDot(trimmed) orelse return null;
    const base_expr = std.mem.trim(u8, trimmed[0..dot_pos], " \t");
    const field_name = std.mem.trim(u8, trimmed[(dot_pos + 1)..], " \t");
    if (base_expr.len == 0 or field_name.len == 0) return null;
    if (!isSimpleIdentifier(field_name)) return null;
    if (!isJavaReservedWord(field_name)) return null;
    if (isLikelyTypeReferencePathExpression(base_expr)) return null;
    return .{
        .base_expr = base_expr,
        .field_name = field_name,
    };
}

pub fn parseIndexedLvalue(lhs: []const u8) ?IndexedLvalue {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len < 4 or trimmed[trimmed.len - 1] != ']') return null;

    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] != '[') continue;
        const close = findMatchingSquareBracket(trimmed, i) orelse continue;
        if (close != trimmed.len - 1) continue;
        const base_expr = std.mem.trim(u8, trimmed[0..i], " \t");
        const index_expr = std.mem.trim(u8, trimmed[(i + 1)..close], " \t");
        if (base_expr.len == 0 or index_expr.len == 0) return null;
        return .{
            .base_expr = base_expr,
            .index_expr = index_expr,
        };
    }
    return null;
}

pub fn parseSObjectFieldLvalue(lhs: []const u8) ?SObjectFieldLvalue {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len == 0) return null;

    const dot_pos = findLastTopLevelDot(trimmed) orelse return null;
    const base_expr = std.mem.trim(u8, trimmed[0..dot_pos], " \t");
    const field_name = std.mem.trim(u8, trimmed[(dot_pos + 1)..], " \t");
    if (base_expr.len == 0 or field_name.len == 0) return null;
    if (!isSimpleIdentifier(field_name)) return null;
    if (!isLikelySObjectFieldName(field_name)) return null;
    if (isLikelyTypeReferencePathExpression(base_expr)) return null;
    if (std.ascii.eqlIgnoreCase(base_expr, "this") or std.ascii.eqlIgnoreCase(base_expr, "super")) return null;
    return .{
        .base_expr = base_expr,
        .field_name = field_name,
    };
}

pub fn isLikelySObjectFieldName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(name, "List")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Map")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Set")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Database")) return false;
    if (std.ascii.eqlIgnoreCase(name, "System")) return false;
    if (std.ascii.eqlIgnoreCase(name, "Schema")) return false;
    if (std.ascii.eqlIgnoreCase(name, "email")) return true;
    if (std.ascii.eqlIgnoreCase(name, "body")) return true;
    if (std.ascii.eqlIgnoreCase(name, "name")) return true;
    if (std.ascii.eqlIgnoreCase(name, "developerName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "filename")) return true;
    if (std.ascii.eqlIgnoreCase(name, "timesTriggered")) return true;
    if (std.ascii.eqlIgnoreCase(name, "nextFireTime")) return true;
    if (std.ascii.eqlIgnoreCase(name, "title")) return true;
    if (std.ascii.eqlIgnoreCase(name, "status")) return true;
    if (std.ascii.eqlIgnoreCase(name, "shippingStreet")) return true;
    if (std.ascii.eqlIgnoreCase(name, "shippingState")) return true;
    if (std.ascii.eqlIgnoreCase(name, "account")) return true;
    if (std.ascii.eqlIgnoreCase(name, "accountId")) return true;
    if (std.ascii.eqlIgnoreCase(name, "ownerId")) return true;
    if (std.ascii.eqlIgnoreCase(name, "firstName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "lastName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "isSandbox")) return true;
    if (std.ascii.eqlIgnoreCase(name, "isReadOnly")) return true;
    if (std.ascii.eqlIgnoreCase(name, "orgType")) return true;
    if (std.ascii.eqlIgnoreCase(name, "instanceName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "podName")) return true;
    if (std.ascii.eqlIgnoreCase(name, "fiscalYearStartMonth")) return true;
    if (std.ascii.eqlIgnoreCase(name, "getFiscalYearStartMonth")) return true;
    if (std.ascii.eqlIgnoreCase(name, "lightningEnabled")) return true;
    if (std.ascii.eqlIgnoreCase(name, "languageLocaleKey")) return true;
    if (std.ascii.eqlIgnoreCase(name, "locale")) return true;
    if (std.ascii.eqlIgnoreCase(name, "for")) return true;
    if (std.ascii.eqlIgnoreCase(name, "timeZoneSidKey")) return true;
    if (std.ascii.eqlIgnoreCase(name, "timeZoneKey")) return true;
    if (std.ascii.eqlIgnoreCase(name, "namespacePrefix")) return true;
    if (std.ascii.eqlIgnoreCase(name, "hasNamespacePrefix")) return true;
    if (std.ascii.eqlIgnoreCase(name, "shareType")) return true;
    if (std.ascii.isUpper(name[0])) return true;
    if (std.mem.indexOf(u8, name, "__") != null) return true;
    if (std.ascii.eqlIgnoreCase(name, "id")) return true;
    return false;
}

pub fn isJavaReservedWord(name: []const u8) bool {
    const reserved = [_][]const u8{
        "abstract", "assert",       "boolean",  "break",     "byte",   "case",      "catch",    "char",
        "class",    "const",        "continue", "default",   "do",     "double",    "else",     "enum",
        "extends",  "final",        "finally",  "float",     "for",    "goto",      "if",       "implements",
        "import",   "instanceof",   "int",      "interface", "long",   "native",    "new",      "package",
        "private",  "protected",    "public",   "return",    "short",  "static",    "strictfp", "super",
        "switch",   "synchronized", "this",     "throw",     "throws", "transient", "try",      "void",
        "volatile", "while",
    };
    for (reserved) |keyword| {
        if (std.ascii.eqlIgnoreCase(name, keyword)) return true;
    }
    return false;
}

pub fn isNewKeywordAt(text: []const u8, pos: usize) bool {
    if (pos + "new".len > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + "new".len], "new")) return false;

    const left_ok = pos == 0 or !isIdentifierChar(text[pos - 1]);
    const right_idx = pos + "new".len;
    const right_ok = right_idx == text.len or !isIdentifierChar(text[right_idx]);
    return left_ok and right_ok;
}

pub fn nextNonSpace(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return i;
}

pub fn prevNonSpace(text: []const u8, from: usize) ?u8 {
    if (from == 0) return null;
    var i = from;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isWhitespace(text[i])) continue;
        return text[i];
    }
    return null;
}
