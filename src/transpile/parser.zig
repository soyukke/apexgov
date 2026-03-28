const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const compat = @import("compat.zig");
const line_and_expr = @import("line_and_expr.zig");
const root = @import("root.zig");
const renderer = @import("renderer.zig");

const ApexFile = types.ApexFile;
const ParsedMethod = types.ParsedMethod;
const ParsedField = types.ParsedField;
const InnerTypeKind = types.InnerTypeKind;
const TopLevelKind = types.TopLevelKind;
const ParsedClass = types.ParsedClass;
const MethodSignature = types.MethodSignature;
const SwitchMode = types.SwitchMode;
const ActiveSwitchContext = types.ActiveSwitchContext;
const UnsupportedLine = types.UnsupportedLine;
const RenderedClass = types.RenderedClass;

// Util aliases
const maybeWrapSingleQueryAssignment = line_and_expr.maybeWrapSingleQueryAssignment;
const maybeUnwrapCollectionQueryResult = line_and_expr.maybeUnwrapCollectionQueryResult;
const hasTopLevelComma = line_and_expr.hasTopLevelComma;
const parseTypedVariableDeclaration = line_and_expr.parseTypedVariableDeclaration;
const NestingState = renderer.NestingState;
const transpileExecutableLine = line_and_expr.transpileExecutableLine;
const convertApexExpressionToJava = line_and_expr.convertApexExpressionToJava;
const transpileGenericStatementLine = line_and_expr.transpileGenericStatementLine;
const collectLogicalStatements = renderer.collectLogicalStatements;
const isSelfQualifiedTypeReference = compat.isSelfQualifiedTypeReference;
const renderJavaClass = renderer.renderJavaClass;
const isLikelySObjectTypeForInstanceof = compat.isLikelySObjectTypeForInstanceof;
const splitCallArguments = line_and_expr.splitCallArguments;
const isKnownSchemaHelperTypeName = line_and_expr.isKnownSchemaHelperTypeName;
const splitTypeArguments = line_and_expr.splitTypeArguments;
const convertApexType = line_and_expr.convertApexType;
const stripApexCommentsFromLine = line_and_expr.stripApexCommentsFromLine;
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const indexOfIgnoreCase = util.indexOfIgnoreCase;
const indexOfIgnoreCasePos = util.indexOfIgnoreCasePos;
const startsWithWordIgnoreCase = util.startsWithWordIgnoreCase;
const containsIgnoreCaseSubstring = util.containsIgnoreCaseSubstring;
const containsWordIgnoreCase = util.containsWordIgnoreCase;
const containsWord = util.containsWord;
const indexOfWord = util.indexOfWord;
const indexOfWordIgnoreCase = util.indexOfWordIgnoreCase;
const isIdentifierChar = util.isIdentifierChar;
const isSimpleIdentifier = util.isSimpleIdentifier;
const isSimpleIdentifierOrPath = util.isSimpleIdentifierOrPath;
const firstIdentifier = util.firstIdentifier;
const leadingIdentifier = util.leadingIdentifier;
const lastIdentifier = util.lastIdentifier;
const IdentifierSpan = util.IdentifierSpan;
const baseIdentifierBeforeDot = util.baseIdentifierBeforeDot;
const isLikelyTypeReferenceIdentifier = util.isLikelyTypeReferenceIdentifier;
const isLikelyQualifiedTypeChain = util.isLikelyQualifiedTypeChain;
const isLikelyTypeReferencePathExpression = util.isLikelyTypeReferencePathExpression;
const looksLikeTypeName = util.looksLikeTypeName;
const isTypeIdentifierPath = util.isTypeIdentifierPath;
const isIdentifierPathExpression = util.isIdentifierPathExpression;
const isDeclarationModifier = util.isDeclarationModifier;
const normalizeDeclarationModifier = util.normalizeDeclarationModifier;
const isControlKeyword = util.isControlKeyword;
const isLikelyNonMethodLeadKeyword = util.isLikelyNonMethodLeadKeyword;
const isMethodModifierToken = util.isMethodModifierToken;
const isIsTestAnnotation = util.isIsTestAnnotation;
const isTestAnnotationSeeAllDataTrue = util.isTestAnnotationSeeAllDataTrue;
const isTestSetupAnnotation = util.isTestSetupAnnotation;
const isTestVisibleAnnotation = util.isTestVisibleAnnotation;
const findMatchingParen = util.findMatchingParen;
const findMatchingParenBackward = util.findMatchingParenBackward;
const findMatchingAngle = util.findMatchingAngle;
const findMatchingBrace = util.findMatchingBrace;
const findMatchingSquareBracket = util.findMatchingSquareBracket;
const findTopLevelMapArrow = util.findTopLevelMapArrow;
const findTopLevelAssignmentOperator = util.findTopLevelAssignmentOperator;
const findTopLevelSafeNavigationOperator = util.findTopLevelSafeNavigationOperator;
const findLastTopLevelDot = util.findLastTopLevelDot;
const braceDelta = util.braceDelta;
const parenDelta = util.parenDelta;
const splitWhitespace = util.splitWhitespace;
const appendFmt = util.appendFmt;
const appendEscapedJavaStringChar = util.appendEscapedJavaStringChar;
const quoteJavaStringLiteral = util.quoteJavaStringLiteral;
const indexOfSoqlBracketSelect = util.indexOfSoqlBracketSelect;
const isInsideComment = util.isInsideComment;
const skipApexCommentsAndWhitespace = util.skipApexCommentsAndWhitespace;
const skipInlineWhitespace = util.skipInlineWhitespace;
const skipAsciiWhitespace = util.skipAsciiWhitespace;
const isControlFlowLine = util.isControlFlowLine;
const isDoWhileTailLine = util.isDoWhileTailLine;
const TrailingIdentifierSplit = util.TrailingIdentifierSplit;
const splitTrailingIdentifierAtTopLevel = util.splitTrailingIdentifierAtTopLevel;
const SObjectFieldLvalue = util.SObjectFieldLvalue;
const IndexedLvalue = util.IndexedLvalue;
const parseIndexedLvalue = util.parseIndexedLvalue;
const parseSObjectFieldLvalue = util.parseSObjectFieldLvalue;
const parseJavaKeywordMemberLvalue = util.parseJavaKeywordMemberLvalue;
const isLikelySObjectFieldName = util.isLikelySObjectFieldName;
const isJavaReservedWord = util.isJavaReservedWord;
const isNewKeywordAt = util.isNewKeywordAt;
const nextNonSpace = util.nextNonSpace;
const prevNonSpace = util.prevNonSpace;

pub const AnnotationPrefix = struct {
    annotations: [8][]const u8 = [_][]const u8{""} ** 8,
    count: usize = 0,
    consumed_len: usize = 0,
    saw_annotation: bool = false,
    incomplete: bool = false,
};

pub fn consumeLeadingInlineAnnotations(text: []const u8) AnnotationPrefix {
    var result = AnnotationPrefix{};
    var cursor: usize = 0;
    const trimmed = std.mem.trimLeft(u8, text, " \t");
    const offset = text.len - trimmed.len;
    cursor = offset;

    while (cursor < text.len and text[cursor] == '@') {
        result.saw_annotation = true;
        const start = cursor;
        cursor += 1;
        while (cursor < text.len and (isIdentifierChar(text[cursor]) or text[cursor] == '.')) : (cursor += 1) {}
        if (cursor < text.len and text[cursor] == '(') {
            const close = findMatchingParen(text, cursor) orelse {
                result.incomplete = true;
                return result;
            };
            cursor = close + 1;
        }
        if (result.count < result.annotations.len) {
            result.annotations[result.count] = text[start..cursor];
            result.count += 1;
        }
        cursor = skipInlineWhitespace(text, cursor);
    }

    result.consumed_len = cursor;
    return result;
}


pub fn parseApexClass(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) anyerror!ParsedClass {
    const class_name = try parseClassName(gpa, source_path, content);
    errdefer gpa.free(class_name);
    const top_level_kind = try parseTopLevelDeclarationKind(gpa, content, class_name);
    const class_declaration_suffix = try parseClassDeclarationSuffix(gpa, content, class_name);
    errdefer if (class_declaration_suffix) |suffix| gpa.free(suffix);
    const top_level_enum_constants = try parseTopLevelEnumConstants(gpa, content, class_name);
    errdefer if (top_level_enum_constants) |constants| gpa.free(constants);
    const class_is_test = detectClassIsTest(content);
    const class_is_test_see_all_data = detectClassSeeAllData(content);
    const class_is_global = detectClassIsGlobal(content);

    var parsed = ParsedClass{
        .class_name = class_name,
        .source_path = try gpa.dupe(u8, source_path),
        .top_level_kind = top_level_kind,
        .class_declaration_suffix = class_declaration_suffix,
        .top_level_enum_constants = top_level_enum_constants,
        .is_global = class_is_global,
    };
    errdefer parsed.deinit(gpa);

    var pending_test_annotation = false;
    var pending_test_setup_annotation = false;
    var pending_test_see_all_data = false;
    var pending_test_visible_annotation = false;
    var in_method = false;
    var brace_depth: i32 = 0;
    var current_signature: MethodSignature = undefined;
    var current_is_test = false;
    var current_is_test_setup = false;
    var current_is_test_see_all_data = false;
    var current_body_base_line: usize = 0;
    var current_body: std.ArrayList(u8) = .empty;
    var pending_signature: std.ArrayList(u8) = .empty;
    var inner_type_block: std.ArrayList(u8) = .empty;
    var pending_member: std.ArrayList(u8) = .empty;
    var pending_property_header: std.ArrayList(u8) = .empty;
    var line_buffer: std.ArrayList(u8) = .empty;
    var collecting_inner_type = false;
    var collecting_member = false;
    var awaiting_property_block = false;
    var inner_type_kind: InnerTypeKind = .class;
    var inner_type_test_visible = false;
    var inner_type_brace_depth: i32 = 0;
    var inner_type_seen_open_brace = false;
    var member_brace_depth: i32 = 0;
    var annotation_paren_depth: i32 = 0;
    var in_block_comment = false;
    var in_type_declaration_header = false;
    defer pending_signature.deinit(gpa);
    defer inner_type_block.deinit(gpa);
    defer pending_member.deinit(gpa);
    defer pending_property_header.deinit(gpa);
    defer line_buffer.deinit(gpa);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed_raw = std.mem.trim(u8, code_only, " \t");
        var logical_code_only = code_only;
        var logical_trimmed = trimmed_raw;

        if (!in_method and annotation_paren_depth == 0 and logical_trimmed.len > 0 and logical_trimmed[0] == '@') {
            const annotation_prefix = consumeLeadingInlineAnnotations(logical_trimmed);
            if (annotation_prefix.saw_annotation and !annotation_prefix.incomplete) {
                for (annotation_prefix.annotations) |annotation| {
                    if (isIsTestAnnotation(annotation)) {
                        pending_test_annotation = true;
                        if (isTestAnnotationSeeAllDataTrue(annotation)) {
                            pending_test_see_all_data = true;
                        }
                    }
                    if (isTestSetupAnnotation(annotation)) {
                        pending_test_setup_annotation = true;
                    }
                    if (isTestVisibleAnnotation(annotation)) {
                        pending_test_visible_annotation = true;
                    }
                }
                logical_trimmed = std.mem.trimLeft(u8, logical_trimmed[annotation_prefix.consumed_len..], " \t");
                logical_code_only = logical_trimmed;
            }
        }

        if (!in_method) {
            if (annotation_paren_depth > 0) {
                if (pending_test_annotation and isTestAnnotationSeeAllDataTrue(code_only)) {
                    pending_test_see_all_data = true;
                }
                annotation_paren_depth += parenDelta(code_only);
                if (annotation_paren_depth < 0) annotation_paren_depth = 0;
                continue;
            }

            if (logical_trimmed.len > 0 and logical_trimmed[0] == '@') {
                if (isIsTestAnnotation(logical_trimmed)) {
                    pending_test_annotation = true;
                    if (isTestAnnotationSeeAllDataTrue(logical_trimmed)) {
                        pending_test_see_all_data = true;
                    }
                }
                if (isTestSetupAnnotation(logical_trimmed)) {
                    pending_test_setup_annotation = true;
                }
                if (isTestVisibleAnnotation(logical_trimmed)) {
                    pending_test_visible_annotation = true;
                }
                annotation_paren_depth += parenDelta(logical_code_only);
                if (annotation_paren_depth < 0) annotation_paren_depth = 0;
                continue;
            }

            if (awaiting_property_block) {
                if (logical_trimmed.len == 0) continue;
                if (std.mem.eql(u8, logical_trimmed, "{")) {
                    collecting_member = true;
                    member_brace_depth = braceDelta(logical_code_only);
                    pending_member.clearRetainingCapacity();
                    try pending_member.appendSlice(gpa, std.mem.trim(u8, pending_property_header.items, " \t"));
                    if (pending_member.items.len > 0) try pending_member.append(gpa, ' ');
                    try pending_member.appendSlice(gpa, logical_trimmed);
                    pending_property_header.clearRetainingCapacity();
                    awaiting_property_block = false;

                    const member_done = member_brace_depth <= 0 and (std.mem.endsWith(u8, logical_trimmed, ";") or std.mem.endsWith(u8, logical_trimmed, "}"));
                    if (member_done) {
                        const member_candidate = std.mem.trim(u8, pending_member.items, " \t");
                        if (try transpileClassMemberLine(gpa, member_candidate, pending_test_visible_annotation)) |declaration| {
                            try parsed.fields.append(gpa, .{ .declaration = declaration });
                        }
                        collecting_member = false;
                        member_brace_depth = 0;
                        pending_member.clearRetainingCapacity();
                        pending_test_annotation = false;
                        pending_test_setup_annotation = false;
                        pending_test_see_all_data = false;
                        pending_test_visible_annotation = false;
                    }
                    continue;
                }

                awaiting_property_block = false;
                pending_property_header.clearRetainingCapacity();
            }

            if (in_type_declaration_header) {
                if (logical_trimmed.len == 0) continue;
                if (std.mem.indexOfScalar(u8, logical_trimmed, '{') != null) {
                    in_type_declaration_header = false;
                }
                continue;
            }

            if (collecting_inner_type) {
                try inner_type_block.appendSlice(gpa, line);
                try inner_type_block.append(gpa, '\n');
                if (std.mem.indexOfScalar(u8, code_only, '{') != null) {
                    inner_type_seen_open_brace = true;
                }
                inner_type_brace_depth += braceDelta(code_only);
                if (inner_type_seen_open_brace and inner_type_brace_depth <= 0) {
                    collecting_inner_type = false;
                    const block_source = try inner_type_block.toOwnedSlice(gpa);
                    defer gpa.free(block_source);
                    inner_type_block.clearRetainingCapacity();

                    if (try transpileInnerTypeBlock(
                        gpa,
                        source_path,
                        block_source,
                        parsed.class_name,
                        inner_type_kind,
                    )) |inner_decl_raw| {
                        var inner_decl = inner_decl_raw;
                        if (inner_type_test_visible) {
                            const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, inner_decl_raw);
                            gpa.free(inner_decl_raw);
                            inner_decl = promoted;
                        }
                        try parsed.fields.append(gpa, .{ .declaration = inner_decl });
                    }
                    inner_type_test_visible = false;
                    pending_test_visible_annotation = false;
                }
                continue;
            }

            if (collecting_member) {
                if (logical_trimmed.len > 0) {
                    if (pending_member.items.len > 0) try pending_member.append(gpa, ' ');
                    try pending_member.appendSlice(gpa, logical_trimmed);
                }
                member_brace_depth += braceDelta(logical_code_only);

                const member_done = member_brace_depth <= 0 and (std.mem.endsWith(u8, logical_trimmed, ";") or std.mem.endsWith(u8, logical_trimmed, "}"));
                if (!member_done) continue;

                const member_candidate = std.mem.trim(u8, pending_member.items, " \t");
                if (try transpileClassMemberLine(gpa, member_candidate, pending_test_visible_annotation)) |declaration| {
                    try parsed.fields.append(gpa, .{ .declaration = declaration });
                }
                collecting_member = false;
                member_brace_depth = 0;
                pending_member.clearRetainingCapacity();
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
                continue;
            }

            if (innerTypeKindFromDeclarationLine(logical_trimmed, parsed.class_name)) |kind| {
                if (kind == .class and isExceptionLikeInnerClassDeclaration(logical_trimmed)) {
                    // Keep legacy single-line Exception conversion path to preserve constructor shape.
                    pending_signature.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                } else {
                    collecting_inner_type = true;
                    inner_type_kind = kind;
                    inner_type_test_visible = pending_test_visible_annotation;
                    inner_type_brace_depth = braceDelta(logical_code_only);
                    inner_type_seen_open_brace = std.mem.indexOfScalar(u8, logical_code_only, '{') != null;
                    inner_type_block.clearRetainingCapacity();
                    try inner_type_block.appendSlice(gpa, line);
                    try inner_type_block.append(gpa, '\n');
                    if (inner_type_seen_open_brace and inner_type_brace_depth <= 0) {
                        collecting_inner_type = false;
                        const block_source = try inner_type_block.toOwnedSlice(gpa);
                        defer gpa.free(block_source);
                        inner_type_block.clearRetainingCapacity();

                        if (try transpileInnerTypeBlock(
                            gpa,
                            source_path,
                            block_source,
                            parsed.class_name,
                            inner_type_kind,
                        )) |inner_decl_raw| {
                            var inner_decl = inner_decl_raw;
                            if (inner_type_test_visible) {
                                const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, inner_decl_raw);
                                gpa.free(inner_decl_raw);
                                inner_decl = promoted;
                            }
                            try parsed.fields.append(gpa, .{ .declaration = inner_decl });
                        }
                        inner_type_test_visible = false;
                        pending_test_visible_annotation = false;
                    }
                    pending_signature.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                    pending_test_visible_annotation = false;
                    continue;
                }
            }

            if (pending_signature.items.len > 0) {
                if (logical_trimmed.len == 0) continue;
                if (pending_signature.items.len > 0) try pending_signature.append(gpa, ' ');
                try pending_signature.appendSlice(gpa, logical_trimmed);
                const signature_candidate = std.mem.trim(u8, pending_signature.items, " \t");

                if (try parseMethodSignature(gpa, signature_candidate, parsed.class_name)) |signature| {
                    in_method = try beginMethodFromSignature(
                        gpa,
                        &parsed,
                        signature,
                        signature_candidate,
                        code_only,
                        line_no,
                        class_is_test,
                        class_is_test_see_all_data,
                        &pending_test_annotation,
                        &pending_test_setup_annotation,
                        &pending_test_see_all_data,
                        &current_signature,
                        &current_is_test,
                        &current_is_test_setup,
                        &current_is_test_see_all_data,
                        &current_body_base_line,
                        &current_body,
                        &brace_depth,
                    );
                    pending_signature.clearRetainingCapacity();
                    pending_test_visible_annotation = false;
                    continue;
                }
                if (try parseConstructorSignature(gpa, signature_candidate, parsed.class_name)) |signature| {
                    in_method = try beginMethodFromSignature(
                        gpa,
                        &parsed,
                        signature,
                        signature_candidate,
                        code_only,
                        line_no,
                        class_is_test,
                        class_is_test_see_all_data,
                        &pending_test_annotation,
                        &pending_test_setup_annotation,
                        &pending_test_see_all_data,
                        &current_signature,
                        &current_is_test,
                        &current_is_test_setup,
                        &current_is_test_see_all_data,
                        &current_body_base_line,
                        &current_body,
                        &brace_depth,
                    );
                    pending_signature.clearRetainingCapacity();
                    pending_test_visible_annotation = false;
                    continue;
                }

                if (try transpileAbstractMethodDeclarationLine(gpa, signature_candidate, parsed.class_name)) |declaration| {
                    try parsed.fields.append(gpa, .{ .declaration = declaration });
                    pending_signature.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                    pending_test_visible_annotation = false;
                    continue;
                }

                if (std.mem.indexOfScalar(u8, signature_candidate, '{') == null) continue;
                pending_signature.clearRetainingCapacity();
            }

            if (try parseMethodSignature(gpa, logical_trimmed, parsed.class_name)) |signature| {
                in_method = try beginMethodFromSignature(
                    gpa,
                    &parsed,
                    signature,
                    logical_trimmed,
                    logical_code_only,
                    line_no,
                    class_is_test,
                    class_is_test_see_all_data,
                    &pending_test_annotation,
                    &pending_test_setup_annotation,
                    &pending_test_see_all_data,
                    &current_signature,
                    &current_is_test,
                    &current_is_test_setup,
                    &current_is_test_see_all_data,
                    &current_body_base_line,
                    &current_body,
                    &brace_depth,
                );
                pending_test_visible_annotation = false;
                continue;
            }

            if (try parseConstructorSignature(gpa, logical_trimmed, parsed.class_name)) |signature| {
                in_method = try beginMethodFromSignature(
                    gpa,
                    &parsed,
                    signature,
                    logical_trimmed,
                    logical_code_only,
                    line_no,
                    class_is_test,
                    class_is_test_see_all_data,
                    &pending_test_annotation,
                    &pending_test_setup_annotation,
                    &pending_test_see_all_data,
                    &current_signature,
                    &current_is_test,
                    &current_is_test_setup,
                    &current_is_test_see_all_data,
                    &current_body_base_line,
                    &current_body,
                    &brace_depth,
                );
                pending_test_visible_annotation = false;
                continue;
            }

            if (try transpileAbstractMethodDeclarationLine(gpa, logical_trimmed, parsed.class_name)) |declaration| {
                try parsed.fields.append(gpa, .{ .declaration = declaration });
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
                continue;
            }

            if (try transpileClassMemberLine(gpa, logical_trimmed, pending_test_visible_annotation)) |declaration| {
                try parsed.fields.append(gpa, .{ .declaration = declaration });
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
                continue;
            }

            if (looksLikeTypeDeclarationLine(logical_trimmed)) {
                if (std.mem.indexOfScalar(u8, logical_trimmed, '{') == null) {
                    in_type_declaration_header = true;
                }
                // Class-level annotations (e.g. @isTest) should not leak into
                // the first method as a method-level annotation.
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                continue;
            }

            if (try looksLikePropertyDeclarationHeader(gpa, logical_trimmed)) {
                awaiting_property_block = true;
                pending_property_header.clearRetainingCapacity();
                try pending_property_header.appendSlice(gpa, logical_trimmed);
                continue;
            }

            if (std.mem.eql(u8, logical_trimmed, "{") or std.mem.eql(u8, logical_trimmed, "}")) {
                continue;
            }

            const starts_multiline_member = (std.mem.indexOfScalar(u8, logical_trimmed, '{') != null and std.mem.indexOfScalar(u8, logical_trimmed, '(') == null) or
                std.mem.endsWith(u8, logical_trimmed, "=") or
                (std.mem.indexOfScalar(u8, logical_trimmed, '=') != null and !std.mem.endsWith(u8, logical_trimmed, ";"));
            if (starts_multiline_member and
                !looksLikeTypeDeclarationLine(logical_trimmed) and
                !looksLikeTypeDeclarationContinuationLine(logical_trimmed))
            {
                collecting_member = true;
                member_brace_depth = braceDelta(logical_code_only);
                pending_member.clearRetainingCapacity();
                if (logical_trimmed.len > 0) try pending_member.appendSlice(gpa, logical_trimmed);

                const member_done = member_brace_depth <= 0 and (std.mem.endsWith(u8, logical_trimmed, ";") or std.mem.endsWith(u8, logical_trimmed, "}"));
                if (member_done) {
                    const member_candidate = std.mem.trim(u8, pending_member.items, " \t");
                    if (try transpileClassMemberLine(gpa, member_candidate, pending_test_visible_annotation)) |declaration| {
                        try parsed.fields.append(gpa, .{ .declaration = declaration });
                    }
                    collecting_member = false;
                    member_brace_depth = 0;
                    pending_member.clearRetainingCapacity();
                    pending_test_annotation = false;
                    pending_test_setup_annotation = false;
                    pending_test_see_all_data = false;
                    pending_test_visible_annotation = false;
                }
                continue;
            }

            if (shouldStartMethodSignatureBuffer(logical_trimmed, parsed.class_name)) {
                pending_signature.clearRetainingCapacity();
                try pending_signature.appendSlice(gpa, logical_trimmed);
                continue;
            }

            if (try looksLikeMethodSignaturePrefix(gpa, logical_trimmed)) {
                pending_signature.clearRetainingCapacity();
                try pending_signature.appendSlice(gpa, logical_trimmed);
                continue;
            }

            if (logical_trimmed.len > 0 and logical_trimmed[0] != '@') {
                pending_test_annotation = false;
                pending_test_setup_annotation = false;
                pending_test_see_all_data = false;
                pending_test_visible_annotation = false;
            }
            continue;
        }

        try current_body.appendSlice(gpa, code_only);
        try current_body.append(gpa, '\n');
        brace_depth += braceDelta(code_only);
        if (brace_depth > 0) continue;

        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_signature.name,
            .java_return_type = current_signature.java_return_type,
            .java_parameters = current_signature.java_parameters,
            .is_static = current_signature.is_static,
            .is_constructor = current_signature.is_constructor,
            .is_test = current_is_test,
            .is_test_setup = current_is_test_setup,
            .is_test_see_all_data = current_is_test_see_all_data,
            .body = body,
            .start_line = current_body_base_line,
        });
        in_method = false;
    }

    if (in_method) {
        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_signature.name,
            .java_return_type = current_signature.java_return_type,
            .java_parameters = current_signature.java_parameters,
            .is_static = current_signature.is_static,
            .is_constructor = current_signature.is_constructor,
            .is_test = current_is_test,
            .is_test_setup = current_is_test_setup,
            .is_test_see_all_data = current_is_test_see_all_data,
            .body = body,
            .start_line = current_body_base_line,
        });
    }

    return parsed;
}

pub const InnerTypeHeader = struct {
    visibility: []const u8,
    type_name: []u8,
    suffix: []u8,
    kind: InnerTypeKind,
    is_abstract: bool = false,
    is_global: bool = false,
};

pub const InnerTypeKeyword = struct {
    kind: InnerTypeKind,
    pos: usize,
    keyword: []const u8,
};

pub fn innerTypeKeywordFromLine(trimmed: []const u8) ?InnerTypeKeyword {
    var best: ?InnerTypeKeyword = null;

    if (indexOfWordIgnoreCase(trimmed, "class")) |pos| {
        best = .{ .kind = .class, .pos = pos, .keyword = "class" };
    }
    if (indexOfWordIgnoreCase(trimmed, "interface")) |pos| {
        if (best == null or pos < best.?.pos) {
            best = .{ .kind = .interface, .pos = pos, .keyword = "interface" };
        }
    }
    if (indexOfWordIgnoreCase(trimmed, "enum")) |pos| {
        if (best == null or pos < best.?.pos) {
            best = .{ .kind = .enum_type, .pos = pos, .keyword = "enum" };
        }
    }

    return best;
}

pub fn innerTypeKindFromDeclarationLine(line: []const u8, outer_class_name: []const u8) ?InnerTypeKind {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;

    const keyword = innerTypeKeywordFromLine(trimmed) orelse return null;
    const prefix = std.mem.trim(u8, trimmed[0..keyword.pos], " \t");
    if (!looksLikeInnerTypeDeclarationPrefix(prefix)) return null;
    const after_keyword = std.mem.trimLeft(u8, trimmed[(keyword.pos + keyword.keyword.len)..], " \t");
    const type_name = leadingIdentifier(after_keyword) orelse return null;
    if (type_name.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(type_name, outer_class_name)) return null;
    return keyword.kind;
}

pub fn looksLikeTypeDeclarationLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;

    const keyword = innerTypeKeywordFromLine(trimmed) orelse return false;
    const prefix = std.mem.trim(u8, trimmed[0..keyword.pos], " \t");
    if (!looksLikeInnerTypeDeclarationPrefix(prefix)) return false;
    const after_keyword = std.mem.trimLeft(u8, trimmed[(keyword.pos + keyword.keyword.len)..], " \t");
    const type_name = leadingIdentifier(after_keyword) orelse return false;
    return type_name.len > 0;
}

pub fn looksLikeTypeDeclarationContinuationLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;
    if (startsWithWordIgnoreCase(trimmed, "implements")) return true;
    if (startsWithWordIgnoreCase(trimmed, "extends")) return true;
    return false;
}

pub fn isExceptionLikeInnerClassDeclaration(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;

    const class_pos = indexOfWordIgnoreCase(trimmed, "class") orelse return false;
    const after_class = std.mem.trimLeft(u8, trimmed[(class_pos + "class".len)..], " \t");
    const class_name = leadingIdentifier(after_class) orelse return false;

    if (endsWithIgnoreCase(class_name, "Exception")) return true;
    if (indexOfWordIgnoreCase(after_class, "extends")) |extends_pos| {
        const after_extends =
            std.mem.trimLeft(u8, after_class[(extends_pos + "extends".len)..], " \t");
        if (leadingIdentifier(after_extends)) |extends_name| {
            if (endsWithIgnoreCase(extends_name, "Exception")) return true;
        }
    }
    return false;
}

pub fn isExceptionLikeTypeHeader(type_name: []const u8, suffix: []const u8) bool {
    if (endsWithIgnoreCase(type_name, "Exception")) return true;
    if (indexOfWordIgnoreCase(suffix, "extends")) |extends_pos| {
        const after_extends =
            std.mem.trimLeft(u8, suffix[(extends_pos + "extends".len)..], " \t");
        if (leadingIdentifier(after_extends)) |extends_name| {
            return endsWithIgnoreCase(extends_name, "Exception");
        }
    }
    return false;
}

pub fn parseInnerTypeHeader(
    gpa: std.mem.Allocator,
    outer_class_name: []const u8,
    block_source: []const u8,
) !?InnerTypeHeader {
    var found_header = false;
    var header_kind: InnerTypeKind = .class;
    var header_visibility: []const u8 = "public";
    var header_type_name: ?[]u8 = null;
    var header_is_abstract = false;
    var header_is_global = false;
    errdefer if (header_type_name) |value| gpa.free(value);
    var saw_open_brace = false;
    var suffix_head: std.ArrayList(u8) = .empty;
    defer suffix_head.deinit(gpa);

    var lines = std.mem.splitScalar(u8, block_source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (!found_header) {
            const keyword = innerTypeKeywordFromLine(trimmed) orelse continue;
            const prefix = std.mem.trim(u8, trimmed[0..keyword.pos], " \t");
            if (!looksLikeInnerTypeDeclarationPrefix(prefix)) continue;
            const after_keyword_full = trimmed[(keyword.pos + keyword.keyword.len)..];
            const after_keyword = std.mem.trimLeft(u8, after_keyword_full, " \t");
            const type_name = leadingIdentifier(after_keyword) orelse continue;
            if (type_name.len == 0 or std.ascii.eqlIgnoreCase(type_name, outer_class_name)) continue;

            const lead_ws_len = after_keyword_full.len - after_keyword.len;
            const type_name_start = keyword.pos + keyword.keyword.len + lead_ws_len;
            const type_name_end = type_name_start + type_name.len;
            if (type_name_end > trimmed.len) continue;

            var header_tail = std.mem.trim(u8, trimmed[type_name_end..], " \t");
            if (std.mem.indexOfScalar(u8, header_tail, '{')) |brace_pos| {
                header_tail = std.mem.trim(u8, header_tail[0..brace_pos], " \t");
                saw_open_brace = true;
            }
            if (header_tail.len > 0) {
                try suffix_head.appendSlice(gpa, header_tail);
            }

            found_header = true;
            header_kind = keyword.kind;
            header_visibility = visibilityModifierForInnerClass(prefix);
            header_is_abstract = containsWordIgnoreCase(prefix, "abstract");
            header_is_global = containsWordIgnoreCase(prefix, "global");
            header_type_name = try gpa.dupe(u8, type_name);
            if (saw_open_brace) break;
            continue;
        }

        var continuation = trimmed;
        if (std.mem.indexOfScalar(u8, continuation, '{')) |brace_pos| {
            continuation = std.mem.trim(u8, continuation[0..brace_pos], " \t");
            saw_open_brace = true;
        }
        if (continuation.len > 0) {
            if (suffix_head.items.len > 0) try suffix_head.append(gpa, ' ');
            try suffix_head.appendSlice(gpa, continuation);
        }
        if (saw_open_brace) break;
    }

    if (!found_header or header_type_name == null) return null;

    const suffix = try normalizeInnerClassSuffix(gpa, std.mem.trim(u8, suffix_head.items, " \t"));
    errdefer gpa.free(suffix);

    return .{
        .visibility = header_visibility,
        .type_name = header_type_name.?,
        .suffix = suffix,
        .kind = header_kind,
        .is_abstract = header_is_abstract,
        .is_global = header_is_global,
    };
}

pub fn normalizeInnerClassSuffix(gpa: std.mem.Allocator, suffix: []const u8) ![]u8 {
    if (suffix.len == 0) return gpa.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var tokens = std.mem.tokenizeAny(u8, suffix, " \t\r\n");
    var first = true;
    while (tokens.next()) |token| {
        if (!first) try out.append(gpa, ' ');
        first = false;

        const converted = try convertApexType(gpa, token);
        defer gpa.free(converted);
        try out.appendSlice(gpa, converted);
    }
    return try out.toOwnedSlice(gpa);
}

pub fn extractRenderedJavaClassBody(rendered_java: []const u8) ?[]const u8 {
    const class_pos = std.mem.indexOf(u8, rendered_java, "public class") orelse
        std.mem.indexOf(u8, rendered_java, "public final class") orelse
        std.mem.indexOf(u8, rendered_java, "public abstract class") orelse return null;
    const open_brace = std.mem.indexOfScalarPos(u8, rendered_java, class_pos, '{') orelse return null;
    const close_brace = std.mem.lastIndexOfScalar(u8, rendered_java, '}') orelse return null;
    if (close_brace <= open_brace) return null;
    return std.mem.trim(u8, rendered_java[(open_brace + 1)..close_brace], " \t\r\n");
}

pub fn rewriteClassSuffixInnerTypeRefs(
    gpa: std.mem.Allocator,
    suffix_raw: []const u8,
    class_name: []const u8,
    fields: []const ParsedField,
) ![]u8 {
    if (suffix_raw.len == 0) return gpa.dupe(u8, "");

    var inner_names: std.ArrayList([]const u8) = .empty;
    defer inner_names.deinit(gpa);

    for (fields) |field| {
        const declaration = field.declaration;
        if (declaration.len == 0) continue;

        const KeywordMatch = struct {
            pos: usize,
            len: usize,
        };
        const keyword_match = blk: {
            const class_pos = indexOfWordIgnoreCase(declaration, "class");
            const interface_pos = indexOfWordIgnoreCase(declaration, "interface");
            const enum_pos = indexOfWordIgnoreCase(declaration, "enum");

            if (class_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "class".len };
            if (interface_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "interface".len };
            if (enum_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "enum".len };
            continue;
        };

        const after_keyword = std.mem.trimLeft(u8, declaration[(keyword_match.pos + keyword_match.len)..], " \t");
        const inner_name = leadingIdentifier(after_keyword) orelse continue;
        if (inner_name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(inner_name, class_name)) continue;

        var seen = false;
        for (inner_names.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, inner_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try inner_names.append(gpa, inner_name);
    }

    if (inner_names.items.len == 0) return gpa.dupe(u8, suffix_raw);

    var current = try gpa.dupe(u8, suffix_raw);
    errdefer gpa.free(current);

    for (inner_names.items) |inner_name| {
        const replacement = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ class_name, inner_name });
        defer gpa.free(replacement);

        const rewritten = try replaceStandaloneTypeName(gpa, current, inner_name, replacement);
        gpa.free(current);
        current = rewritten;
    }
    return current;
}

pub fn collectInnerTypeNames(
    gpa: std.mem.Allocator,
    class_name: []const u8,
    fields: []const ParsedField,
) !std.ArrayList([]const u8) {
    var inner_names: std.ArrayList([]const u8) = .empty;
    errdefer inner_names.deinit(gpa);

    for (fields) |field| {
        const declaration = field.declaration;
        if (declaration.len == 0) continue;

        // Only check the declaration header (before '{') to avoid matching
        // 'class'/'interface'/'enum' keywords inside method bodies.
        const header_end = std.mem.indexOfScalar(u8, declaration, '{') orelse declaration.len;
        const header = declaration[0..header_end];

        const KeywordMatch = struct {
            pos: usize,
            len: usize,
        };
        const keyword_match = blk: {
            const class_pos = indexOfWordIgnoreCase(header, "class");
            const interface_pos = indexOfWordIgnoreCase(header, "interface");
            const enum_pos = indexOfWordIgnoreCase(header, "enum");

            if (class_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "class".len };
            if (interface_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "interface".len };
            if (enum_pos) |pos| break :blk KeywordMatch{ .pos = pos, .len = "enum".len };
            continue;
        };

        const after_keyword = std.mem.trimLeft(u8, header[(keyword_match.pos + keyword_match.len)..], " \t");
        const inner_name = leadingIdentifier(after_keyword) orelse continue;
        if (inner_name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(inner_name, class_name)) continue;

        var seen = false;
        for (inner_names.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, inner_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try inner_names.append(gpa, inner_name);
    }

    return inner_names;
}

pub fn stripSelfInnerImplementsFromClassSuffix(
    gpa: std.mem.Allocator,
    suffix_raw: []const u8,
    class_name: []const u8,
    fields: []const ParsedField,
) ![]u8 {
    if (suffix_raw.len == 0) return gpa.dupe(u8, "");
    const implements_pos = indexOfWordIgnoreCase(suffix_raw, "implements") orelse return gpa.dupe(u8, suffix_raw);

    var inner_names = try collectInnerTypeNames(gpa, class_name, fields);
    defer inner_names.deinit(gpa);
    if (inner_names.items.len == 0) return gpa.dupe(u8, suffix_raw);

    const impl_keyword_end = implements_pos + "implements".len;
    if (impl_keyword_end > suffix_raw.len) return gpa.dupe(u8, suffix_raw);
    const before_impl = std.mem.trimRight(u8, suffix_raw[0..implements_pos], " \t");
    const impl_segment = std.mem.trimLeft(u8, suffix_raw[impl_keyword_end..], " \t");
    if (impl_segment.len == 0) return gpa.dupe(u8, before_impl);

    var impl_items = try splitTypeArguments(gpa, impl_segment);
    defer impl_items.deinit(gpa);
    if (impl_items.items.len == 0) return gpa.dupe(u8, before_impl);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, before_impl);

    var emitted_any = false;
    for (impl_items.items) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t");
        if (item.len == 0) continue;

        const generic_pos = std.mem.indexOfScalar(u8, item, '<');
        const base = if (generic_pos) |pos| item[0..pos] else item;
        const base_trimmed = std.mem.trim(u8, base, " \t");
        if (base_trimmed.len == 0) continue;

        var skip = false;
        for (inner_names.items) |inner_name| {
            if (std.ascii.eqlIgnoreCase(base_trimmed, inner_name)) {
                skip = true;
                break;
            }
            const qualified = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ class_name, inner_name });
            defer gpa.free(qualified);
            if (std.ascii.eqlIgnoreCase(base_trimmed, qualified)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        if (!emitted_any) {
            try out.appendSlice(gpa, " implements ");
            emitted_any = true;
        } else {
            try out.appendSlice(gpa, ", ");
        }
        try out.appendSlice(gpa, item);
    }

    return try out.toOwnedSlice(gpa);
}

pub fn replaceStandaloneTypeName(
    gpa: std.mem.Allocator,
    text: []const u8,
    target: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (target.len == 0) return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var i: usize = 0;
    while (i < text.len) {
        if (i + target.len <= text.len and
            std.ascii.eqlIgnoreCase(text[i .. i + target.len], target))
        {
            const left_ok = i == 0 or !isIdentifierChar(text[i - 1]);
            const right_idx = i + target.len;
            const right_ok = right_idx == text.len or !isIdentifierChar(text[right_idx]);
            const already_qualified = i > 0 and text[i - 1] == '.';

            if (left_ok and right_ok and !already_qualified) {
                try out.appendSlice(gpa, replacement);
                replaced = true;
                i += target.len;
                continue;
            }
        }

        try out.append(gpa, text[i]);
        i += 1;
    }

    const base = blk: {
        if (!replaced) {
            out.deinit(gpa);
            break :blk try gpa.dupe(u8, text);
        }
        break :blk try out.toOwnedSlice(gpa);
    };

    const schema_rewritten = try rewriteSchemaObjectNamespaceAccess(gpa, base);
    gpa.free(base);

    const token_rewritten = try rewriteTokenOverloadCalls(gpa, schema_rewritten);
    gpa.free(schema_rewritten);
    const array_rewritten = try rewriteApexArrayStyleListLiterals(gpa, token_rewritten);
    gpa.free(token_rewritten);
    return array_rewritten;
}

pub fn rewriteSchemaObjectNamespaceAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (!startsWithIgnoreCase(text[i..], "Schema.")) continue;

        const object_start = i + "Schema.".len;
        var cursor = object_start;
        while (cursor < text.len and isIdentifierChar(text[cursor])) : (cursor += 1) {}
        if (cursor == object_start or cursor >= text.len or text[cursor] != '.') continue;

        const object_name = text[object_start..cursor];
        if (isKnownSchemaHelperTypeName(object_name)) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, object_name);
        try out.append(gpa, '.');
        replaced = true;
        i = cursor;
        last_emit = cursor + 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return try out.toOwnedSlice(gpa);
}

pub fn rewriteFieldNamespacePropertyAccess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (!startsWithIgnoreCase(text[i..], ".fields.")) continue;

        const field_start = i + ".fields.".len;
        var field_end = field_start;
        while (field_end < text.len and isIdentifierChar(text[field_end])) : (field_end += 1) {}
        if (field_end == field_start) continue;
        if (field_end < text.len and text[field_end] == '(') continue;

        const field_name = text[field_start..field_end];
        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, ".fields.<Schema.SObjectField>getAs(\"");
        try out.appendSlice(gpa, field_name);
        try out.appendSlice(gpa, "\")");
        replaced = true;
        i = field_end - 1;
        last_emit = field_end;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteTokenOverloadCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const select_fixed = try rewriteMethodCallByArgumentHint(gpa, text, "selectFields", "selectFieldsByToken", "Schema.SObjectField");
    defer gpa.free(select_fixed);

    const changed_fixed = try rewriteMethodCallByArgumentHint(gpa, select_fixed, "getChangedRecords", "getChangedRecordsByToken", "Schema.SObjectField");
    defer gpa.free(changed_fixed);

    const insert_fixed = try rewriteMethodCallByArgumentHint(gpa, changed_fixed, "checkInsert", "checkInsertByToken", "Schema.SObjectField");
    defer gpa.free(insert_fixed);

    const read_fixed = try rewriteMethodCallByArgumentHint(gpa, insert_fixed, "checkRead", "checkReadByToken", "Schema.SObjectField");
    defer gpa.free(read_fixed);

    return rewriteMethodCallByArgumentHint(gpa, read_fixed, "checkUpdate", "checkUpdateByToken", "Schema.SObjectField");
}

pub fn rewriteTypedNullSchemaFieldCollections(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const prefixes = [_][]const u8{
        "new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf(",
        "new ArrayList<Schema.SObjectField>(ApexCollections.listOf(",
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var replaced = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var matched_prefix: ?[]const u8 = null;
        for (prefixes) |prefix| {
            if (i + prefix.len <= text.len and startsWithIgnoreCase(text[i..], prefix)) {
                matched_prefix = prefix;
                break;
            }
        }
        const prefix = matched_prefix orelse continue;
        const args_start = i + prefix.len;
        const open_paren = args_start - 1;
        const close_paren = findMatchingParen(text, open_paren) orelse continue;
        const args_raw = text[args_start..close_paren];
        var args = try splitCallArguments(gpa, args_raw);
        defer args.deinit(gpa);

        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(gpa);
        var local_replaced = false;
        for (args.items, 0..) |arg, idx| {
            const trimmed = std.mem.trim(u8, arg, " \t");
            const normalized = if (std.ascii.eqlIgnoreCase(trimmed, "(Object) null"))
                "(Schema.SObjectField) null"
            else if (std.ascii.eqlIgnoreCase(trimmed, "null"))
                "(Schema.SObjectField) null"
            else
                trimmed;
            if (!std.mem.eql(u8, normalized, trimmed)) {
                local_replaced = true;
            }
            if (idx != 0) try rebuilt.appendSlice(gpa, ", ");
            try rebuilt.appendSlice(gpa, normalized);
        }
        if (!local_replaced) continue;

        try out.appendSlice(gpa, text[last_emit..args_start]);
        try out.appendSlice(gpa, rebuilt.items);
        replaced = true;
        i = close_paren - 1;
        last_emit = close_paren;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteMethodLocalDefaultInitializers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var brace_depth: i32 = 0;
    var method_body_depth: ?i32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        const inside_method = method_body_depth != null and brace_depth >= method_body_depth.?;
        if (inside_method) {
            if (try defaultInitializedLocalDeclaration(gpa, line, trimmed)) |rewritten_line| {
                defer gpa.free(rewritten_line);
                try out.appendSlice(gpa, rewritten_line);
            } else {
                try out.appendSlice(gpa, line);
            }
        } else {
            try out.appendSlice(gpa, line);
        }
        try out.append(gpa, '\n');

        if (method_body_depth == null and isMethodOpeningLine(trimmed)) {
            method_body_depth = brace_depth + braceDelta(line);
        }

        brace_depth += braceDelta(line);
        if (method_body_depth != null and brace_depth < method_body_depth.?) {
            method_body_depth = null;
        }
    }

    return out.toOwnedSlice(gpa);
}

pub fn defaultInitializedLocalDeclaration(
    gpa: std.mem.Allocator,
    line: []const u8,
    trimmed: []const u8,
) !?[]u8 {
    if (trimmed.len == 0 or !std.mem.endsWith(u8, trimmed, ";")) return null;
    var prefix: []const u8 = "";
    var declaration = trimmed;
    if (declaration[0] == '{') {
        prefix = "{ ";
        declaration = std.mem.trim(u8, declaration[1..], " \t");
        if (declaration.len == 0) return null;
    }

    if (std.mem.indexOfScalar(u8, declaration, '=') != null) return null;
    if (std.mem.indexOfScalar(u8, declaration, '(') != null or std.mem.indexOfScalar(u8, declaration, ')') != null) return null;
    if (startsWithIgnoreCase(declaration, "return ") or
        startsWithIgnoreCase(declaration, "throw ") or
        startsWithIgnoreCase(declaration, "break") or
        startsWithIgnoreCase(declaration, "continue"))
    {
        return null;
    }

    const body = std.mem.trimRight(u8, declaration[0 .. declaration.len - 1], " \t");
    const split_index = std.mem.lastIndexOfAny(u8, body, " \t") orelse return null;
    const name = std.mem.trim(u8, body[(split_index + 1)..], " \t");
    if (!isSimpleIdentifier(name)) return null;

    var type_text = std.mem.trim(u8, body[0..split_index], " \t");
    if (type_text.len == 0) return null;
    if (startsWithIgnoreCase(type_text, "final ")) {
        type_text = std.mem.trim(u8, type_text["final ".len..], " \t");
    }
    if (type_text.len == 0 or !looksLikeTypeName(type_text)) return null;

    const initializer = defaultInitializerForType(type_text) orelse return null;
    const indent_len = line.len - std.mem.trimLeft(u8, line, " \t").len;
    const indent = line[0..indent_len];
    return try std.fmt.allocPrint(gpa, "{s}{s}{s} = {s};", .{ indent, prefix, body, initializer });
}

pub fn defaultInitializerForType(type_text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_text, " \t");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "boolean")) return "false";
    if (std.ascii.eqlIgnoreCase(trimmed, "char")) return "'\\0'";
    if (std.ascii.eqlIgnoreCase(trimmed, "byte") or
        std.ascii.eqlIgnoreCase(trimmed, "short") or
        std.ascii.eqlIgnoreCase(trimmed, "int") or
        std.ascii.eqlIgnoreCase(trimmed, "long") or
        std.ascii.eqlIgnoreCase(trimmed, "float") or
        std.ascii.eqlIgnoreCase(trimmed, "double"))
    {
        return "0";
    }
    return "null";
}

pub fn isMethodOpeningLine(trimmed: []const u8) bool {
    if (trimmed.len == 0 or !std.mem.endsWith(u8, trimmed, "{")) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') == null) return false;
    if (indexOfWordIgnoreCase(trimmed, "class") != null or
        indexOfWordIgnoreCase(trimmed, "interface") != null or
        indexOfWordIgnoreCase(trimmed, "enum") != null)
    {
        return false;
    }
    const block_keywords = [_][]const u8{
        "if",
        "for",
        "while",
        "switch",
        "catch",
        "try",
        "else",
        "do",
        "synchronized",
    };
    for (block_keywords) |keyword| {
        if (startsWithIgnoreCase(trimmed, keyword)) return false;
    }
    return true;
}

pub fn rewriteMethodCallByArgumentHint(
    gpa: std.mem.Allocator,
    text: []const u8,
    method_name: []const u8,
    replacement_name: []const u8,
    hint: []const u8,
) ![]u8 {
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
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        if (!startsWithIgnoreCase(text[i..], method_name)) continue;

        const method_end = i + method_name.len;
        if (method_end < text.len and isIdentifierChar(text[method_end])) continue;

        var open = method_end;
        while (open < text.len and std.ascii.isWhitespace(text[open])) : (open += 1) {}
        if (open >= text.len or text[open] != '(') continue;
        const close = findMatchingParen(text, open) orelse continue;
        const args = text[(open + 1)..close];
        if (std.mem.indexOf(u8, args, hint) == null) continue;

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement_name);
        replaced = true;
        i = method_end - 1;
        last_emit = method_end;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn rewriteApexArrayStyleListLiterals(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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
        if (!isNewKeywordAt(text, i)) continue;

        var cursor = i + "new".len;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len) continue;

        const type_start = cursor;
        while (cursor < text.len and (isIdentifierChar(text[cursor]) or text[cursor] == '.')) : (cursor += 1) {}
        if (cursor == type_start) continue;
        const raw_type = std.mem.trim(u8, text[type_start..cursor], " \t");

        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor + 1 >= text.len or text[cursor] != '[' or text[cursor + 1] != ']') continue;
        cursor += 2;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != '{') continue;

        const close_brace = findMatchingBrace(text, cursor) orelse continue;
        const items_raw = std.mem.trim(u8, text[(cursor + 1)..close_brace], " \t");
        const java_type = if (isLikelySObjectTypeForInstanceof(raw_type))
            try gpa.dupe(u8, "ApexSObject")
        else
            try convertApexType(gpa, raw_type);
        defer gpa.free(java_type);

        var replacement: []u8 = undefined;
        if (items_raw.len == 0) {
            replacement = try std.fmt.allocPrint(gpa, "new ArrayList<{s}>()", .{java_type});
        } else {
            var items = try splitCallArguments(gpa, items_raw);
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
                "new ArrayList<{s}>(ApexCollections.listOf({s}))",
                .{ java_type, joined.items },
            );
        }
        defer gpa.free(replacement);

        try out.appendSlice(gpa, text[last_emit..i]);
        try out.appendSlice(gpa, replacement);
        replaced = true;
        i = close_brace;
        last_emit = close_brace + 1;
    }

    if (!replaced) {
        out.deinit(gpa);
        return gpa.dupe(u8, text);
    }
    try out.appendSlice(gpa, text[last_emit..]);
    return out.toOwnedSlice(gpa);
}

pub fn appendIndentedBlock(gpa: std.mem.Allocator, out: *std.ArrayList(u8), block: []const u8, indent: []const u8) !void {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) {
            try out.append(gpa, '\n');
            continue;
        }
        try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
}

pub fn appendInnerEnumConstantFromSegment(
    gpa: std.mem.Allocator,
    constants: *std.ArrayList([]u8),
    segment: []const u8,
) !void {
    var trimmed = std.mem.trim(u8, segment, " \t\r\n");
    if (trimmed.len == 0) return;

    if (std.mem.indexOfScalar(u8, trimmed, '(')) |paren_pos| {
        trimmed = std.mem.trim(u8, trimmed[0..paren_pos], " \t\r\n");
    }
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
        trimmed = std.mem.trim(u8, trimmed[0..eq_pos], " \t\r\n");
    }

    const name = leadingIdentifier(trimmed) orelse return;
    if (name.len == 0) return;

    for (constants.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try constants.append(gpa, try gpa.dupe(u8, name));
}

pub fn collectInnerEnumConstants(gpa: std.mem.Allocator, block_source: []const u8) ![]u8 {
    const open_brace = std.mem.indexOfScalar(u8, block_source, '{') orelse return gpa.dupe(u8, "PLACEHOLDER");
    const close_brace = findMatchingBrace(block_source, open_brace) orelse return gpa.dupe(u8, "PLACEHOLDER");
    const body = block_source[(open_brace + 1)..close_brace];

    var constants: std.ArrayList([]u8) = .empty;
    defer {
        for (constants.items) |item| gpa.free(item);
        constants.deinit(gpa);
    }

    var in_single = false;
    var in_double = false;
    var in_line_comment = false;
    var in_block_comment = false;
    var escaped = false;
    var reset_segment_after_comment = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var segment_start: usize = 0;
    var saw_terminator = false;

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (in_line_comment) {
            if (ch == '\n') {
                in_line_comment = false;
                if (reset_segment_after_comment) {
                    segment_start = i + 1;
                }
                reset_segment_after_comment = false;
            }
            continue;
        }
        if (in_block_comment) {
            if (ch == '*' and i + 1 < body.len and body[i + 1] == '/') {
                in_block_comment = false;
                if (reset_segment_after_comment) {
                    segment_start = i + 2;
                }
                reset_segment_after_comment = false;
                i += 1;
            }
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
        if (in_single) {
            if (ch == '\'' and i + 1 < body.len and body[i + 1] == '\'') {
                i += 1;
                continue;
            }
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            escaped = false;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '/' and i + 1 < body.len) {
            if (body[i + 1] == '/') {
                reset_segment_after_comment = std.mem.trim(u8, body[segment_start..i], " \t\r\n").len == 0;
                in_line_comment = true;
                i += 1;
                continue;
            }
            if (body[i + 1] == '*') {
                reset_segment_after_comment = std.mem.trim(u8, body[segment_start..i], " \t\r\n").len == 0;
                in_block_comment = true;
                i += 1;
                continue;
            }
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
            ',' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    try appendInnerEnumConstantFromSegment(gpa, &constants, body[segment_start..i]);
                    segment_start = i + 1;
                }
            },
            ';' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    try appendInnerEnumConstantFromSegment(gpa, &constants, body[segment_start..i]);
                    saw_terminator = true;
                    break;
                }
            },
            else => {},
        }
    }

    if (!saw_terminator) {
        try appendInnerEnumConstantFromSegment(gpa, &constants, body[segment_start..]);
    }

    if (constants.items.len == 0) {
        return gpa.dupe(u8, "PLACEHOLDER");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (constants.items, 0..) |name, idx| {
        if (idx != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, name);
    }
    return out.toOwnedSlice(gpa);
}

pub fn parseInterfaceMethodDeclaration(
    gpa: std.mem.Allocator,
    statement: []const u8,
    interface_name: []const u8,
) !?[]u8 {
    var trimmed = std.mem.trim(u8, statement, " \t");
    if (trimmed.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, ")")) return null;
    if (containsWordIgnoreCase(trimmed, "class")) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return null;

    if (trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }
    if (trimmed.len == 0) return null;

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, trimmed[0..open_paren], '=')) |_| return null;

    const prefix = std.mem.trim(u8, trimmed[0..open_paren], " \t");
    if (prefix.len == 0) return null;

    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return null;
        if (isLikelyNonMethodLeadKeyword(first)) return null;
    }

    const candidate = lastIdentifier(prefix) orelse return null;
    if (isControlKeyword(candidate)) return null;
    if (isLikelyNonMethodLeadKeyword(candidate)) return null;
    if (std.mem.eql(u8, candidate, interface_name)) return null;

    const name_pos = std.mem.lastIndexOf(u8, prefix, candidate) orelse return null;
    const before_name = std.mem.trimRight(u8, prefix[0..name_pos], " \t");
    if (before_name.len == 0) return null;

    var before_tokens = try splitWhitespace(gpa, before_name);
    defer before_tokens.deinit(gpa);
    if (before_tokens.items.len == 0) return null;

    var return_raw: std.ArrayList(u8) = .empty;
    errdefer return_raw.deinit(gpa);

    for (before_tokens.items) |token| {
        if (isMethodModifierToken(token)) continue;
        if (return_raw.items.len != 0) try return_raw.append(gpa, ' ');
        try return_raw.appendSlice(gpa, token);
    }
    if (return_raw.items.len == 0) return null;

    const return_type_raw = try return_raw.toOwnedSlice(gpa);
    defer gpa.free(return_type_raw);

    const java_return_type = try convertApexType(gpa, return_type_raw);
    defer gpa.free(java_return_type);

    const close_paren = findMatchingParen(trimmed, open_paren) orelse return null;
    const param_segment = std.mem.trim(u8, trimmed[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    defer gpa.free(java_parameters);

    const declaration = try std.fmt.allocPrint(
        gpa,
        "public {s} {s}({s});",
        .{ java_return_type, candidate, java_parameters },
    );
    return declaration;
}

pub fn transpileAbstractMethodDeclarationLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    class_name: []const u8,
) !?[]u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[trimmed.len - 1] != ';') return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, ")")) return null;
    if (containsWordIgnoreCase(trimmed, "class")) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return null;

    trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    if (trimmed.len == 0) return null;

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, trimmed[0..open_paren], '=')) |_| return null;
    const close_paren = findMatchingParen(trimmed, open_paren) orelse return null;
    const trailing = std.mem.trim(u8, trimmed[(close_paren + 1)..], " \t");
    if (trailing.len != 0) return null;

    const prefix = std.mem.trim(u8, trimmed[0..open_paren], " \t");
    if (prefix.len == 0) return null;
    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return null;
        if (isLikelyNonMethodLeadKeyword(first)) return null;
    }

    const candidate = lastIdentifier(prefix) orelse return null;
    if (isControlKeyword(candidate)) return null;
    if (isLikelyNonMethodLeadKeyword(candidate)) return null;
    if (std.mem.eql(u8, candidate, class_name)) return null;

    const name_pos = std.mem.lastIndexOf(u8, prefix, candidate) orelse return null;
    const before_name = std.mem.trimRight(u8, prefix[0..name_pos], " \t");
    if (before_name.len == 0) return null;

    var before_tokens = try splitWhitespace(gpa, before_name);
    defer before_tokens.deinit(gpa);
    if (before_tokens.items.len == 0) return null;

    var modifiers_out: std.ArrayList(u8) = .empty;
    defer modifiers_out.deinit(gpa);
    var return_raw: std.ArrayList(u8) = .empty;
    defer return_raw.deinit(gpa);
    var has_abstract = false;

    for (before_tokens.items) |token| {
        if (std.ascii.eqlIgnoreCase(token, "abstract")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "abstract");
            has_abstract = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "public")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "public");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "private")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "private");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "protected")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "protected");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "global")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "public");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "static")) {
            if (modifiers_out.items.len > 0) try modifiers_out.append(gpa, ' ');
            try modifiers_out.appendSlice(gpa, "static");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "final") or
            std.ascii.eqlIgnoreCase(token, "virtual") or
            std.ascii.eqlIgnoreCase(token, "override") or
            std.ascii.eqlIgnoreCase(token, "testmethod") or
            std.ascii.eqlIgnoreCase(token, "webservice") or
            std.ascii.eqlIgnoreCase(token, "transient"))
        {
            continue;
        }

        if (return_raw.items.len > 0) try return_raw.append(gpa, ' ');
        try return_raw.appendSlice(gpa, token);
    }

    if (!has_abstract) return null;
    if (return_raw.items.len == 0) return null;
    const return_type_raw = try return_raw.toOwnedSlice(gpa);
    defer gpa.free(return_type_raw);
    if (!looksLikeTypeName(return_type_raw)) return null;

    const java_return_type = try convertApexType(gpa, return_type_raw);
    defer gpa.free(java_return_type);

    const param_segment = std.mem.trim(u8, trimmed[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    defer gpa.free(java_parameters);

    if (modifiers_out.items.len == 0) {
        const declaration = try std.fmt.allocPrint(gpa, "abstract {s} {s}({s});", .{ java_return_type, candidate, java_parameters });
        return declaration;
    }
    const declaration = try std.fmt.allocPrint(gpa, "{s} {s} {s}({s});", .{ modifiers_out.items, java_return_type, candidate, java_parameters });
    return declaration;
}

pub fn collectInterfaceMethodDeclarations(
    gpa: std.mem.Allocator,
    block_source: []const u8,
    interface_name: []const u8,
) ![]u8 {
    const open_brace = std.mem.indexOfScalar(u8, block_source, '{') orelse return gpa.dupe(u8, "");
    const close_brace = findMatchingBrace(block_source, open_brace) orelse return gpa.dupe(u8, "");
    const body = block_source[(open_brace + 1)..close_brace];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var statement: std.ArrayList(u8) = .empty;
    defer statement.deinit(gpa);
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);

    var in_block_comment = false;
    var annotation_paren_depth: i32 = 0;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) continue;

        if (annotation_paren_depth > 0) {
            annotation_paren_depth += parenDelta(code_only);
            if (annotation_paren_depth < 0) annotation_paren_depth = 0;
            continue;
        }

        if (trimmed[0] == '@') {
            annotation_paren_depth += parenDelta(code_only);
            if (annotation_paren_depth < 0) annotation_paren_depth = 0;
            continue;
        }

        if (trimmed[0] == '{' or trimmed[0] == '}') continue;

        if (statement.items.len > 0) try statement.append(gpa, ' ');
        try statement.appendSlice(gpa, trimmed);

        if (std.mem.indexOfScalar(u8, trimmed, ';') == null) continue;

        const candidate = std.mem.trim(u8, statement.items, " \t");
        if (try parseInterfaceMethodDeclaration(gpa, candidate, interface_name)) |decl| {
            defer gpa.free(decl);
            try out.appendSlice(gpa, "  ");
            try out.appendSlice(gpa, decl);
            try out.append(gpa, '\n');
        }
        statement.clearRetainingCapacity();
    }

    return out.toOwnedSlice(gpa);
}

pub fn transpileInnerTypeBlock(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    block_source: []const u8,
    outer_class_name: []const u8,
    kind_hint: InnerTypeKind,
) !?[]u8 {
    _ = source_path;
    _ = kind_hint;
    const header = (try parseInnerTypeHeader(gpa, outer_class_name, block_source)) orelse return null;
    defer {
        gpa.free(header.type_name);
        gpa.free(header.suffix);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    switch (header.kind) {
        .class => {
            const synthetic_source_path = try std.fmt.allocPrint(gpa, "{s}.cls", .{header.type_name});
            defer gpa.free(synthetic_source_path);
            var parsed_inner = try parseApexClass(gpa, synthetic_source_path, block_source);
            defer parsed_inner.deinit(gpa);

            var rendered_inner = try renderJavaClass(gpa, parsed_inner, "generated");
            defer rendered_inner.deinit(gpa);

            const body = extractRenderedJavaClassBody(rendered_inner.java) orelse return null;
            const abstract_keyword = if (header.is_abstract) " abstract" else "";

            if (header.is_global) {
                try out.appendSlice(gpa, "  @ApexGlobal\n");
            }
            if (header.suffix.len == 0) {
                try appendFmt(gpa, &out, "{s} static{s} class {s} {{\n", .{ header.visibility, abstract_keyword, header.type_name });
            } else {
                try appendFmt(
                    gpa,
                    &out,
                    "{s} static{s} class {s} {s} {{\n",
                    .{ header.visibility, abstract_keyword, header.type_name, header.suffix },
                );
            }
            if (body.len > 0) {
                try appendIndentedBlock(gpa, &out, body, "  ");
            }
            const exception_like = isExceptionLikeTypeHeader(header.type_name, header.suffix);
            if (exception_like) {
                const noarg_pattern = try std.fmt.allocPrint(gpa, "public {s}()", .{header.type_name});
                defer gpa.free(noarg_pattern);
                const string_pattern = try std.fmt.allocPrint(gpa, "public {s}(String", .{header.type_name});
                defer gpa.free(string_pattern);
                const has_noarg_ctor = std.mem.indexOf(u8, body, noarg_pattern) != null;
                const has_string_ctor = std.mem.indexOf(u8, body, string_pattern) != null;
                if (!has_noarg_ctor) {
                    try appendFmt(gpa, &out, "  public {s}() {{ super(); }}\n", .{header.type_name});
                }
                if (!has_string_ctor) {
                    try appendFmt(gpa, &out, "  public {s}(String message) {{ super(message); }}\n", .{header.type_name});
                }
            }
            try out.appendSlice(gpa, "}");
        },
        .interface => {
            const methods = try collectInterfaceMethodDeclarations(gpa, block_source, header.type_name);
            defer gpa.free(methods);
            if (header.suffix.len == 0) {
                try appendFmt(gpa, &out, "{s} static interface {s} {{\n", .{ header.visibility, header.type_name });
            } else {
                try appendFmt(
                    gpa,
                    &out,
                    "{s} static interface {s} {s} {{\n",
                    .{ header.visibility, header.type_name, header.suffix },
                );
            }
            if (methods.len > 0) try out.appendSlice(gpa, methods);
            try out.appendSlice(gpa, "}");
        },
        .enum_type => {
            const constants = try collectInnerEnumConstants(gpa, block_source);
            defer gpa.free(constants);
            try appendFmt(
                gpa,
                &out,
                "{s} static enum {s} {{ {s} }}",
                .{ header.visibility, header.type_name, constants },
            );
        },
    }

    const rendered = try out.toOwnedSlice(gpa);
    return rendered;
}

pub fn beginMethodFromSignature(
    gpa: std.mem.Allocator,
    parsed: *ParsedClass,
    signature: MethodSignature,
    signature_source: []const u8,
    line: []const u8,
    line_no: usize,
    class_is_test: bool,
    class_is_test_see_all_data: bool,
    pending_test_annotation: *bool,
    pending_test_setup_annotation: *bool,
    pending_test_see_all_data: *bool,
    current_signature: *MethodSignature,
    current_is_test: *bool,
    current_is_test_setup: *bool,
    current_is_test_see_all_data: *bool,
    current_body_base_line: *usize,
    current_body: *std.ArrayList(u8),
    brace_depth: *i32,
) !bool {
    brace_depth.* = braceDelta(line);
    current_signature.* = signature;
    const explicit_test_setup = pending_test_setup_annotation.* or containsWordIgnoreCase(signature_source, "testSetup");
    const explicit_test = pending_test_annotation.* or containsWordIgnoreCase(signature_source, "testMethod");
    const explicit_test_see_all_data = pending_test_see_all_data.*;
    const class_level_implicit_test = class_is_test and
        signature.is_static and
        std.ascii.eqlIgnoreCase(signature.java_return_type, "void") and
        std.mem.trim(u8, signature.java_parameters, " \t").len == 0 and
        startsWithIgnoreCase(signature.name, "test");
    current_is_test_setup.* = explicit_test_setup;
    current_is_test.* = (explicit_test or class_level_implicit_test) and !current_is_test_setup.*;
    current_is_test_see_all_data.* = current_is_test.* and (explicit_test_see_all_data or class_is_test_see_all_data);
    current_body_base_line.* = line_no + 1;
    current_body.* = .empty;
    pending_test_annotation.* = false;
    pending_test_setup_annotation.* = false;
    pending_test_see_all_data.* = false;

    if (std.mem.indexOfScalar(u8, line, '{')) |brace_idx| {
        var tail = std.mem.trim(u8, line[(brace_idx + 1)..], " \t");
        if (tail.len > 0 and tail[tail.len - 1] == '}') {
            tail = std.mem.trimRight(u8, tail[0 .. tail.len - 1], " \t");
        }
        if (tail.len > 0) {
            current_body_base_line.* = line_no;
            try current_body.appendSlice(gpa, tail);
            try current_body.append(gpa, '\n');
        }
    }

    if (brace_depth.* <= 0) {
        const body = try current_body.toOwnedSlice(gpa);
        try parsed.methods.append(gpa, .{
            .name = current_signature.name,
            .java_return_type = current_signature.java_return_type,
            .java_parameters = current_signature.java_parameters,
            .is_static = current_signature.is_static,
            .is_constructor = current_signature.is_constructor,
            .is_test = current_is_test.*,
            .is_test_setup = current_is_test_setup.*,
            .is_test_see_all_data = current_is_test_see_all_data.*,
            .body = body,
            .start_line = current_body_base_line.*,
        });
        return false;
    }
    return true;
}

pub fn shouldStartMethodSignatureBuffer(line: []const u8, class_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '@') return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') == null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return false;
    if (containsWordIgnoreCase(trimmed, "class")) return false;

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return false;
    if (std.mem.indexOfScalar(u8, trimmed[0..open_paren], '=')) |_| return false;
    const prefix = std.mem.trim(u8, trimmed[0..open_paren], " \t");
    if (prefix.len == 0) return false;

    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return false;
        if (isLikelyNonMethodLeadKeyword(first)) return false;
    }

    const candidate = lastIdentifier(prefix) orelse return false;
    if (isControlKeyword(candidate)) return false;
    if (isLikelyNonMethodLeadKeyword(candidate)) return false;
    _ = class_name;
    return true;
}

pub fn looksLikeMethodSignaturePrefix(gpa: std.mem.Allocator, line: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '@') return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '=') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '}') != null) return false;
    if (containsWordIgnoreCase(trimmed, "class")) return false;

    var tokens = try splitWhitespace(gpa, trimmed);
    defer tokens.deinit(gpa);
    if (tokens.items.len < 2) return false;

    if (firstIdentifier(trimmed)) |first| {
        if (isControlKeyword(first) or isLikelyNonMethodLeadKeyword(first)) return false;
    }

    var saw_type = false;
    for (tokens.items) |token| {
        if (isMethodModifierToken(token)) continue;
        if (!looksLikeTypeName(token)) return false;
        saw_type = true;
    }

    return saw_type;
}

pub fn parseClassName(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) ![]u8 {
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) continue;

        if (indexOfWordIgnoreCase(trimmed, "class")) |class_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..class_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
            const after = std.mem.trimLeft(u8, trimmed[(class_pos + 5)..], " \t");
            if (leadingIdentifier(after)) |name| {
                return gpa.dupe(u8, name);
            }
        }
    }

    const base = std.fs.path.basename(source_path);
    const stem = std.fs.path.stem(base);
    if (stem.len == 0) return error.InvalidClassName;
    return gpa.dupe(u8, stem);
}

pub fn parseClassDeclarationSuffix(
    gpa: std.mem.Allocator,
    content: []const u8,
    class_name: []const u8,
) !?[]u8 {
    const DeclKind = enum {
        class,
        interface,
    };
    const DeclMatch = struct {
        kind: DeclKind,
        pos: usize,
        keyword: []const u8,
    };

    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;
    var declaration: std.ArrayList(u8) = .empty;
    defer declaration.deinit(gpa);
    var collecting = false;
    var brace_depth: i32 = 0;
    var declaration_kind: DeclKind = .class;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");

        if (brace_depth == 0) {
            if (!collecting) {
                const decl_match = blk: {
                    if (indexOfWordIgnoreCase(trimmed, "class")) |class_pos| {
                        const class_prefix = std.mem.trim(u8, trimmed[0..class_pos], " \t");
                        if (looksLikeTopLevelDeclarationPrefix(class_prefix)) {
                            break :blk DeclMatch{ .kind = .class, .pos = class_pos, .keyword = "class" };
                        }
                    }
                    if (indexOfWordIgnoreCase(trimmed, "interface")) |interface_pos| {
                        const interface_prefix = std.mem.trim(u8, trimmed[0..interface_pos], " \t");
                        if (looksLikeTopLevelDeclarationPrefix(interface_prefix)) {
                            break :blk DeclMatch{ .kind = .interface, .pos = interface_pos, .keyword = "interface" };
                        }
                    }
                    break :blk null;
                };

                if (decl_match) |decl| {
                    const after = std.mem.trimLeft(u8, trimmed[(decl.pos + decl.keyword.len)..], " \t");
                    const found_name = leadingIdentifier(after) orelse {
                        brace_depth += braceDelta(code_only);
                        continue;
                    };
                    if (!std.ascii.eqlIgnoreCase(found_name, class_name)) {
                        brace_depth += braceDelta(code_only);
                        continue;
                    }

                    collecting = true;
                    declaration_kind = decl.kind;
                    declaration.clearRetainingCapacity();
                    try declaration.appendSlice(gpa, trimmed);
                    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) break;
                    brace_depth += braceDelta(code_only);
                    continue;
                }
            } else {
                if (trimmed.len > 0) {
                    if (declaration.items.len > 0) try declaration.append(gpa, ' ');
                    try declaration.appendSlice(gpa, trimmed);
                    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) break;
                }
            }
        }

        brace_depth += braceDelta(code_only);
    }

    if (!collecting or declaration.items.len == 0) return null;

    var declaration_text = std.mem.trim(u8, declaration.items, " \t");
    if (std.mem.indexOfScalar(u8, declaration_text, '{')) |brace_pos| {
        declaration_text = std.mem.trimRight(u8, declaration_text[0..brace_pos], " \t");
    }

    const keyword = if (declaration_kind == .interface) "interface" else "class";
    const keyword_pos = indexOfWordIgnoreCase(declaration_text, keyword) orelse return null;
    const after_decl = std.mem.trimLeft(u8, declaration_text[(keyword_pos + keyword.len)..], " \t");
    const found_name = leadingIdentifier(after_decl) orelse return null;
    if (!std.ascii.eqlIgnoreCase(found_name, class_name)) return null;

    const after_name = std.mem.trimLeft(u8, after_decl[found_name.len..], " \t");
    if (after_name.len == 0) return null;

    const extends_len = "extends".len;
    const implements_len = "implements".len;
    const extends_pos = indexOfWordIgnoreCase(after_name, "extends");
    const implements_pos = if (declaration_kind == .class)
        indexOfWordIgnoreCase(after_name, "implements")
    else
        null;

    const extends_segment: []const u8 = blk: {
        if (extends_pos == null) break :blk "";
        const ext_start = extends_pos.? + extends_len;
        if (ext_start > after_name.len) break :blk "";
        const ext_end = if (implements_pos) |impl_pos|
            if (impl_pos > ext_start) impl_pos else after_name.len
        else
            after_name.len;
        if (ext_end > after_name.len or ext_end <= ext_start) break :blk "";
        break :blk std.mem.trim(u8, after_name[ext_start..ext_end], " \t");
    };

    const implements_segment: []const u8 = blk: {
        if (implements_pos == null) break :blk "";
        const impl_start = implements_pos.? + implements_len;
        break :blk std.mem.trimLeft(u8, after_name[impl_start..], " \t");
    };

    var suffix: std.ArrayList(u8) = .empty;
    errdefer suffix.deinit(gpa);

    if (extends_segment.len > 0) {
        var extends_items = try splitTypeArguments(gpa, extends_segment);
        defer extends_items.deinit(gpa);
        if (extends_items.items.len > 0) {
            try suffix.appendSlice(gpa, " extends ");
            for (extends_items.items, 0..) |ext_item, idx| {
                const converted_extends = try convertApexType(gpa, ext_item);
                defer gpa.free(converted_extends);
                if (idx != 0) try suffix.appendSlice(gpa, ", ");
                try suffix.appendSlice(gpa, converted_extends);
            }
        }
    }

    if (declaration_kind == .class and implements_segment.len > 0) {
        var impl_items = try splitTypeArguments(gpa, implements_segment);
        defer impl_items.deinit(gpa);
        if (impl_items.items.len > 0) {
            var emitted_any = false;
            for (impl_items.items) |impl_item| {
                if (isSelfQualifiedTypeReference(impl_item, class_name)) continue;
                const converted_impl = try convertApexType(gpa, impl_item);
                defer gpa.free(converted_impl);
                if (!emitted_any) {
                    try suffix.appendSlice(gpa, " implements ");
                    emitted_any = true;
                } else {
                    try suffix.appendSlice(gpa, ", ");
                }
                try suffix.appendSlice(gpa, converted_impl);
            }
        }
    }

    if (suffix.items.len == 0) {
        suffix.deinit(gpa);
        return null;
    }
    const owned = try suffix.toOwnedSlice(gpa);
    return owned;
}

pub fn parseTopLevelDeclarationKind(
    gpa: std.mem.Allocator,
    content: []const u8,
    class_name: []const u8,
) !TopLevelKind {
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) continue;

        if (indexOfWordIgnoreCase(trimmed, "class")) |class_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..class_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
            const after = std.mem.trimLeft(u8, trimmed[(class_pos + "class".len)..], " \t");
            if (leadingIdentifier(after)) |name| {
                if (std.ascii.eqlIgnoreCase(name, class_name)) return .class;
            }
        }

        if (indexOfWordIgnoreCase(trimmed, "interface")) |interface_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..interface_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
            const after = std.mem.trimLeft(u8, trimmed[(interface_pos + "interface".len)..], " \t");
            if (leadingIdentifier(after)) |name| {
                if (std.ascii.eqlIgnoreCase(name, class_name)) return .interface;
            }
        }

        if (indexOfWordIgnoreCase(trimmed, "enum")) |enum_pos| {
            const prefix = std.mem.trim(u8, trimmed[0..enum_pos], " \t");
            if (!looksLikeTopLevelDeclarationPrefix(prefix)) continue;
            const after = std.mem.trimLeft(u8, trimmed[(enum_pos + "enum".len)..], " \t");
            if (leadingIdentifier(after)) |name| {
                if (std.ascii.eqlIgnoreCase(name, class_name)) return .enum_type;
            }
        }
    }
    return .class;
}

pub fn parseTopLevelEnumConstants(
    gpa: std.mem.Allocator,
    content: []const u8,
    class_name: []const u8,
) !?[]u8 {
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(gpa);

    var lines_for_strip = std.mem.splitScalar(u8, content, '\n');
    while (lines_for_strip.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            line,
            &in_block_comment,
            &line_buffer,
        );
        try stripped.appendSlice(gpa, code_only);
        try stripped.append(gpa, '\n');
    }

    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, stripped.items, '\n');
    while (lines.next()) |line| {
        const line_trimmed_left = std.mem.trimLeft(u8, line, " \t");
        const trim_left_len = line.len - line_trimmed_left.len;
        const trimmed = std.mem.trim(u8, line_trimmed_left, " \t");
        if (trimmed.len == 0) {
            offset += line.len + 1;
            continue;
        }

        const enum_pos = indexOfWordIgnoreCase(trimmed, "enum") orelse {
            offset += line.len + 1;
            continue;
        };
        const prefix = std.mem.trim(u8, trimmed[0..enum_pos], " \t");
        if (!looksLikeTopLevelDeclarationPrefix(prefix)) {
            offset += line.len + 1;
            continue;
        }

        const after_enum = std.mem.trimLeft(u8, trimmed[(enum_pos + "enum".len)..], " \t");
        const enum_name = leadingIdentifier(after_enum) orelse {
            offset += line.len + 1;
            continue;
        };
        if (!std.ascii.eqlIgnoreCase(enum_name, class_name)) {
            offset += line.len + 1;
            continue;
        }

        const line_start = offset + trim_left_len;
        const open_brace = std.mem.indexOfScalarPos(u8, stripped.items, line_start, '{') orelse return null;
        const close_brace = findMatchingBrace(stripped.items, open_brace) orelse return null;
        const enum_block = stripped.items[line_start .. close_brace + 1];
        const constants = try collectInnerEnumConstants(gpa, enum_block);
        return constants;
    }

    return null;
}

pub fn looksLikeClassDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;

    var found_token = false;
    var it = std.mem.tokenizeAny(u8, prefix, " \t\r\n");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        found_token = true;
        if (!isClassDeclarationPrefixToken(token)) return false;
    }
    return found_token;
}

pub fn looksLikeTopLevelDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return looksLikeClassDeclarationPrefix(prefix);
}

pub fn looksLikeInnerTypeDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return looksLikeClassDeclarationPrefix(prefix);
}

pub fn isClassDeclarationPrefixToken(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "public") or
        std.ascii.eqlIgnoreCase(token, "private") or
        std.ascii.eqlIgnoreCase(token, "protected") or
        std.ascii.eqlIgnoreCase(token, "global") or
        std.ascii.eqlIgnoreCase(token, "with") or
        std.ascii.eqlIgnoreCase(token, "without") or
        std.ascii.eqlIgnoreCase(token, "sharing") or
        std.ascii.eqlIgnoreCase(token, "inherited") or
        std.ascii.eqlIgnoreCase(token, "virtual") or
        std.ascii.eqlIgnoreCase(token, "abstract") or
        std.ascii.eqlIgnoreCase(token, "final") or
        std.ascii.eqlIgnoreCase(token, "static") or
        std.ascii.eqlIgnoreCase(token, "testmethod");
}

pub fn detectClassIsGlobal(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        // Look for the top-level class/interface declaration line containing 'global'.
        if (containsWordIgnoreCase(trimmed, "class") or containsWordIgnoreCase(trimmed, "interface")) {
            return containsWordIgnoreCase(trimmed, "global");
        }
    }
    return false;
}

pub fn detectClassIsTest(content: []const u8) bool {
    var pending_annotation = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (isIsTestAnnotation(trimmed)) {
            pending_annotation = true;
            continue;
        }

        if (containsWordIgnoreCase(trimmed, "class")) {
            return pending_annotation;
        }

        if (trimmed[0] != '@') {
            pending_annotation = false;
        }
    }
    return false;
}

pub fn detectClassSeeAllData(content: []const u8) bool {
    var pending_see_all_data = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (isIsTestAnnotation(trimmed)) {
            pending_see_all_data = isTestAnnotationSeeAllDataTrue(trimmed);
            continue;
        }

        if (containsWordIgnoreCase(trimmed, "class")) {
            return pending_see_all_data;
        }

        if (trimmed[0] != '@') {
            pending_see_all_data = false;
        }
    }
    return false;
}

pub fn parseMethodSignature(gpa: std.mem.Allocator, line: []const u8, class_name: []const u8) !?MethodSignature {
    if (line.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, ")")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "{")) return null;
    if (line[line.len - 1] == ';') return null;
    if (containsWordIgnoreCase(line, "class")) return null;

    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, line[0..open_paren], '=')) |_| return null;

    const prefix = std.mem.trim(u8, line[0..open_paren], " \t");
    if (prefix.len == 0) return null;

    if (firstIdentifier(prefix)) |first| {
        if (isControlKeyword(first)) return null;
        if (isLikelyNonMethodLeadKeyword(first)) return null;
    }

    const candidate = lastIdentifier(prefix) orelse return null;
    if (isControlKeyword(candidate)) return null;
    if (isLikelyNonMethodLeadKeyword(candidate)) return null;
    if (std.mem.eql(u8, candidate, class_name)) return null;

    var tokens = try splitWhitespace(gpa, prefix);
    defer tokens.deinit(gpa);
    if (tokens.items.len < 2) return null;

    const name_token = tokens.items[tokens.items.len - 1];
    if (!std.mem.eql(u8, name_token, candidate)) return null;
    if (tokens.items.len < 2) return null;

    const name_pos = std.mem.lastIndexOf(u8, prefix, candidate) orelse return null;
    const before_name = std.mem.trimRight(u8, prefix[0..name_pos], " \t");
    if (before_name.len == 0) return null;

    var before_tokens = try splitWhitespace(gpa, before_name);
    defer before_tokens.deinit(gpa);
    if (before_tokens.items.len == 0) return null;

    var return_raw: std.ArrayList(u8) = .empty;
    errdefer return_raw.deinit(gpa);

    var is_static = false;
    for (before_tokens.items) |token| {
        if (isMethodModifierToken(token)) {
            if (std.ascii.eqlIgnoreCase(token, "static")) is_static = true;
            continue;
        }
        if (return_raw.items.len != 0) try return_raw.append(gpa, ' ');
        try return_raw.appendSlice(gpa, token);
    }
    if (return_raw.items.len == 0) return null;

    const return_type_raw = try return_raw.toOwnedSlice(gpa);
    defer gpa.free(return_type_raw);

    const java_return_type = try convertApexType(gpa, return_type_raw);
    errdefer gpa.free(java_return_type);

    const close_paren = findMatchingParen(line, open_paren) orelse return null;
    const param_segment = std.mem.trim(u8, line[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    errdefer gpa.free(java_parameters);

    return .{
        .name = try gpa.dupe(u8, candidate),
        .java_return_type = java_return_type,
        .java_parameters = java_parameters,
        .is_static = is_static,
        .is_constructor = false,
    };
}

pub fn parseConstructorSignature(gpa: std.mem.Allocator, line: []const u8, class_name: []const u8) !?MethodSignature {
    if (line.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "(")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, ")")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "{")) return null;
    if (line[line.len - 1] == ';') return null;
    if (containsWordIgnoreCase(line, "class")) return null;

    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, line[0..open_paren], '=')) |_| return null;

    const prefix = std.mem.trim(u8, line[0..open_paren], " \t");
    if (prefix.len == 0) return null;

    const candidate = lastIdentifier(prefix) orelse return null;
    if (!std.mem.eql(u8, candidate, class_name)) return null;

    var tokens = try splitWhitespace(gpa, prefix);
    defer tokens.deinit(gpa);
    if (tokens.items.len == 0) return null;

    for (tokens.items[0 .. tokens.items.len - 1]) |token| {
        if (!isMethodModifierToken(token)) return null;
    }

    const close_paren = findMatchingParen(line, open_paren) orelse return null;
    const param_segment = std.mem.trim(u8, line[(open_paren + 1)..close_paren], " \t");
    const java_parameters = try convertMethodParameters(gpa, param_segment);
    errdefer gpa.free(java_parameters);

    return .{
        .name = try gpa.dupe(u8, class_name),
        .java_return_type = try gpa.dupe(u8, ""),
        .java_parameters = java_parameters,
        .is_static = false,
        .is_constructor = true,
    };
}

pub fn convertMethodParameters(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return gpa.dupe(u8, "");

    var params = try splitTypeArguments(gpa, trimmed);
    defer params.deinit(gpa);
    if (params.items.len == 0) return gpa.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (params.items, 0..) |param, idx| {
        var part = std.mem.trim(u8, param, " \t");
        if (part.len == 0) continue;
        if (startsWithIgnoreCase(part, "final ")) {
            part = std.mem.trimLeft(u8, part["final".len..], " \t");
        }
        const param_name = lastIdentifier(part) orelse continue;
        const type_segment = std.mem.trimRight(u8, part[0..(part.len - param_name.len)], " \t");
        if (type_segment.len == 0) continue;

        const java_type = try convertApexType(gpa, type_segment);
        defer gpa.free(java_type);

        if (idx != 0) try out.appendSlice(gpa, ", ");
        try appendFmt(gpa, &out, "{s} {s}", .{ java_type, param_name });
    }

    return try out.toOwnedSlice(gpa);
}

pub fn transpileClassMemberLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    test_visible_hint: bool,
) !?[]u8 {
    const trimmed_raw = std.mem.trim(u8, line, " \t");
    const annotation_info = try stripLeadingAnnotationsFromMemberLine(gpa, trimmed_raw);
    defer if (annotation_info.stripped) |value| gpa.free(value);
    const trimmed = if (annotation_info.stripped) |value| std.mem.trim(u8, value, " \t") else trimmed_raw;
    const test_visible = test_visible_hint or annotation_info.has_test_visible;
    if (trimmed.len == 0) return null;
    if (isIsTestAnnotation(trimmed)) return null;
    if (try transpileExceptionClassDeclarationLine(gpa, trimmed)) |exception_decl| {
        if (!test_visible) return exception_decl;
        const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, exception_decl);
        gpa.free(exception_decl);
        return promoted;
    }
    if (looksLikeTypeDeclarationLine(trimmed)) return null;
    if (looksLikeTypeDeclarationContinuationLine(trimmed)) return null;
    if (std.mem.eql(u8, trimmed, "{") or std.mem.eql(u8, trimmed, "}")) return null;
    if (try transpileStaticInitializerBlock(gpa, trimmed)) |static_block| {
        return static_block;
    }

    if (try transpilePropertyDeclarationLine(gpa, trimmed)) |property_line| {
        if (!test_visible) return property_line;
        const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, property_line);
        gpa.free(property_line);
        return promoted;
    }

    if (trimmed[trimmed.len - 1] != ';') return null;
    const without_semicolon = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    if (without_semicolon.len == 0) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "return")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "insert")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "update")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "upsert")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "delete")) return null;
    if (startsWithWordIgnoreCase(without_semicolon, "undelete")) return null;

    const declaration = (try transpileTypedDeclarationLine(gpa, without_semicolon, true)) orelse return null;
    if (!test_visible) return declaration;
    const promoted = try promoteDeclarationVisibilityForTestVisible(gpa, declaration);
    gpa.free(declaration);
    return promoted;
}

pub fn transpileStaticInitializerBlock(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!startsWithWordIgnoreCase(trimmed, "static")) return null;

    const static_len = "static".len;
    if (static_len < trimmed.len and isIdentifierChar(trimmed[static_len])) return null;

    var open_brace = static_len;
    while (open_brace < trimmed.len and std.ascii.isWhitespace(trimmed[open_brace])) : (open_brace += 1) {}
    if (open_brace >= trimmed.len or trimmed[open_brace] != '{') return null;
    const close_brace = findMatchingBrace(trimmed, open_brace) orelse return null;
    if (std.mem.trim(u8, trimmed[(close_brace + 1)..], " \t").len != 0) return null;

    const body_raw = std.mem.trim(u8, trimmed[(open_brace + 1)..close_brace], " \t");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "static {\n");

    if (body_raw.len > 0) {
        var statements = try collectLogicalStatements(gpa, body_raw);
        defer {
            for (statements.items) |statement| gpa.free(statement.text);
            statements.deinit(gpa);
        }

        for (statements.items) |statement| {
            const stmt = std.mem.trim(u8, statement.text, " \t");
            if (stmt.len == 0) continue;
            if (try transpileExecutableLine(gpa, stmt)) |converted| {
                defer gpa.free(converted);
                try appendFmt(gpa, &out, "    {s}\n", .{converted});
            } else {
                try appendFmt(gpa, &out, "    // {s}\n", .{stmt});
            }
        }
    }

    try out.appendSlice(gpa, "  }");
    const rendered = try out.toOwnedSlice(gpa);
    return rendered;
}

pub const LeadingMemberAnnotations = struct {
    stripped: ?[]u8 = null,
    has_test_visible: bool = false,
};

pub fn stripLeadingAnnotationsFromMemberLine(
    gpa: std.mem.Allocator,
    line: []const u8,
) !LeadingMemberAnnotations {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] != '@') return .{};

    var cursor: usize = 0;
    var changed = false;
    var has_test_visible = false;
    while (cursor < trimmed.len and trimmed[cursor] == '@') {
        changed = true;
        cursor += 1;
        const annotation_name = leadingIdentifier(trimmed[cursor..]) orelse break;
        if (std.ascii.eqlIgnoreCase(annotation_name, "TestVisible")) {
            has_test_visible = true;
        }
        cursor += annotation_name.len;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        if (cursor < trimmed.len and trimmed[cursor] == '(') {
            const close = findMatchingParen(trimmed, cursor) orelse break;
            cursor = close + 1;
        }
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
    }

    if (!changed) return .{ .has_test_visible = has_test_visible };
    const stripped = std.mem.trim(u8, trimmed[cursor..], " \t");
    const owned = try gpa.dupe(u8, stripped);
    return .{
        .stripped = owned,
        .has_test_visible = has_test_visible,
    };
}

pub fn promoteDeclarationVisibilityForTestVisible(
    gpa: std.mem.Allocator,
    declaration: []const u8,
) ![]u8 {
    const trimmed = std.mem.trimLeft(u8, declaration, " \t");
    const leading_ws = declaration.len - trimmed.len;
    const private_prefix = "private ";
    const protected_prefix = "protected ";

    var replace_len: usize = 0;
    if (startsWithIgnoreCase(trimmed, private_prefix)) {
        replace_len = private_prefix.len;
    } else if (startsWithIgnoreCase(trimmed, protected_prefix)) {
        replace_len = protected_prefix.len;
    } else {
        return gpa.dupe(u8, declaration);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, declaration[0..leading_ws]);
    try out.appendSlice(gpa, "public ");
    try out.appendSlice(gpa, trimmed[replace_len..]);
    return out.toOwnedSlice(gpa);
}

pub fn transpileExceptionClassDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const class_pos = indexOfWordIgnoreCase(line, "class") orelse return null;
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;

    const after_class = std.mem.trimLeft(u8, line[(class_pos + "class".len)..], " \t");
    const class_name = leadingIdentifier(after_class) orelse return null;
    if (class_name.len == 0) return null;

    var exception_like = endsWithIgnoreCase(class_name, "Exception");
    if (!exception_like) {
        if (indexOfWordIgnoreCase(after_class, "extends")) |extends_pos| {
            const after_extends = std.mem.trimLeft(
                u8,
                after_class[(extends_pos + "extends".len)..],
                " \t",
            );
            if (leadingIdentifier(after_extends)) |extends_name| {
                exception_like = endsWithIgnoreCase(extends_name, "Exception");
            }
        }
    }
    if (!exception_like) return null;

    const prefix = std.mem.trim(u8, line[0..class_pos], " \t");
    const visibility = visibilityModifierForInnerClass(prefix);
    return try std.fmt.allocPrint(
        gpa,
        "{s} static class {s} extends apexemu.runtime.System.Exception {{ public {s}() {{ super(); }} public {s}(String message) {{ super(message); }} }}",
        .{ visibility, class_name, class_name, class_name },
    );
}

pub fn visibilityModifierForInnerClass(prefix: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, prefix, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "private")) return "private";
        if (std.ascii.eqlIgnoreCase(token, "protected")) return "protected";
        if (std.ascii.eqlIgnoreCase(token, "public")) return "public";
        if (std.ascii.eqlIgnoreCase(token, "global")) return "public";
    }
    return "public";
}

pub fn transpilePropertyDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const open_brace = std.mem.indexOfScalar(u8, line, '{') orelse return null;
    const close_brace = std.mem.lastIndexOfScalar(u8, line, '}') orelse return null;
    if (close_brace <= open_brace) return null;

    const body = std.mem.trim(u8, line[(open_brace + 1)..close_brace], " \t");
    if (!containsWordIgnoreCase(body, "get") or !containsWordIgnoreCase(body, "set")) return null;

    const head = std.mem.trim(u8, line[0..open_brace], " \t");
    if (head.len == 0) return null;
    const declaration = (try transpileTypedDeclarationLine(gpa, head, true)) orelse return null;
    defer gpa.free(declaration);

    const inferred_initializer = try inferPropertyGetterInitializer(gpa, line, declaration);
    defer if (inferred_initializer) |value| gpa.free(value);

    const initialized = try defaultInitializedApexPropertyDeclaration(gpa, declaration, inferred_initializer);
    defer gpa.free(initialized);
    const with_comment = try std.fmt.allocPrint(gpa, "{s} // Apex property {{ get; set; }}", .{initialized});
    return with_comment;
}

pub fn inferPropertyGetterInitializer(gpa: std.mem.Allocator, property_line: []const u8, declaration: []const u8) !?[]u8 {
    const declaration_trimmed = std.mem.trim(u8, declaration, " \t");
    if (declaration_trimmed.len == 0 or !std.mem.endsWith(u8, declaration_trimmed, ";")) return null;
    const declaration_body = std.mem.trimRight(u8, declaration_trimmed[0 .. declaration_trimmed.len - 1], " \t");
    const property_name = lastIdentifier(declaration_body) orelse return null;
    if (!isSimpleIdentifier(property_name)) return null;

    const property_open = std.mem.indexOfScalar(u8, property_line, '{') orelse return null;
    const property_close = std.mem.lastIndexOfScalar(u8, property_line, '}') orelse return null;
    if (property_close <= property_open) return null;
    const property_body = property_line[(property_open + 1)..property_close];

    const getter_body = findPropertyAccessorBody(property_body, "get") orelse return null;
    if (!containsNullEqualityForIdentifier(getter_body, property_name)) return null;
    if (!containsReturnOfIdentifier(getter_body, property_name)) return null;
    const assignment_rhs_raw = extractIdentifierAssignmentExpression(getter_body, property_name) orelse return null;
    if (assignment_rhs_raw.len == 0) return null;

    const assign_stmt = try std.fmt.allocPrint(gpa, "{s} = {s};", .{ property_name, assignment_rhs_raw });
    defer gpa.free(assign_stmt);

    const transpiled_assign_stmt = (try transpileGenericStatementLine(gpa, assign_stmt)) orelse return null;
    defer gpa.free(transpiled_assign_stmt);

    const assign_pos = std.mem.indexOfScalar(u8, transpiled_assign_stmt, '=') orelse return null;
    const semicolon_pos = std.mem.lastIndexOfScalar(u8, transpiled_assign_stmt, ';') orelse return null;
    if (semicolon_pos <= assign_pos) return null;
    const rhs = std.mem.trim(u8, transpiled_assign_stmt[(assign_pos + 1)..semicolon_pos], " \t");
    if (rhs.len == 0) return null;
    if (!isSafeInlinePropertyInitializer(rhs, property_name)) return null;
    const owned_rhs = try gpa.dupe(u8, rhs);
    return owned_rhs;
}

pub fn findPropertyAccessorBody(property_body: []const u8, accessor_name: []const u8) ?[]const u8 {
    if (property_body.len == 0 or accessor_name.len == 0) return null;

    var cursor: usize = 0;
    while (cursor < property_body.len) {
        if (!isIdentifierChar(property_body[cursor])) {
            cursor += 1;
            continue;
        }

        const token_start = cursor;
        while (cursor < property_body.len and isIdentifierChar(property_body[cursor])) : (cursor += 1) {}
        const token = property_body[token_start..cursor];
        if (!std.ascii.eqlIgnoreCase(token, accessor_name)) continue;

        const after_token = skipAsciiWhitespace(property_body, cursor);
        if (after_token >= property_body.len) return null;
        if (property_body[after_token] == ';') return null;
        if (property_body[after_token] != '{') continue;

        const close_brace = findMatchingBrace(property_body, after_token) orelse return null;
        return property_body[(after_token + 1)..close_brace];
    }
    return null;
}

pub fn containsNullEqualityForIdentifier(text: []const u8, identifier: []const u8) bool {
    if (text.len == 0 or identifier.len == 0) return false;

    var search_from: usize = 0;
    while (search_from < text.len) {
        const rel = indexOfWordIgnoreCase(text[search_from..], identifier) orelse break;
        const hit = search_from + rel;

        var cursor = skipAsciiWhitespace(text, hit + identifier.len);
        if (cursor + 1 < text.len and text[cursor] == '=' and text[cursor + 1] == '=') {
            cursor = skipAsciiWhitespace(text, cursor + 2);
            if (startsWithWordIgnoreCase(text[cursor..], "null")) return true;
        }

        search_from = hit + identifier.len;
    }

    search_from = 0;
    while (search_from < text.len) {
        const rel = indexOfWordIgnoreCase(text[search_from..], "null") orelse break;
        const hit = search_from + rel;

        var cursor = skipAsciiWhitespace(text, hit + "null".len);
        if (cursor + 1 < text.len and text[cursor] == '=' and text[cursor + 1] == '=') {
            cursor = skipAsciiWhitespace(text, cursor + 2);
            if (startsWithWordIgnoreCase(text[cursor..], identifier)) return true;
        }

        search_from = hit + "null".len;
    }

    return false;
}

pub fn containsReturnOfIdentifier(text: []const u8, identifier: []const u8) bool {
    if (text.len == 0 or identifier.len == 0) return false;

    var search_from: usize = 0;
    while (search_from < text.len) {
        const rel = indexOfWordIgnoreCase(text[search_from..], "return") orelse break;
        const hit = search_from + rel;

        var cursor = skipAsciiWhitespace(text, hit + "return".len);
        if (startsWithWordIgnoreCase(text[cursor..], "this")) {
            const after_this = skipAsciiWhitespace(text, cursor + "this".len);
            if (after_this < text.len and text[after_this] == '.') {
                cursor = skipAsciiWhitespace(text, after_this + 1);
            }
        }

        if (startsWithWordIgnoreCase(text[cursor..], identifier)) {
            const after_identifier = skipAsciiWhitespace(text, cursor + identifier.len);
            if (after_identifier < text.len and text[after_identifier] == ';') return true;
        }

        search_from = hit + "return".len;
    }

    return false;
}

pub fn extractIdentifierAssignmentExpression(text: []const u8, identifier: []const u8) ?[]const u8 {
    if (text.len == 0 or identifier.len == 0) return null;

    var search_from: usize = 0;
    while (search_from < text.len) {
        const rel = indexOfWordIgnoreCase(text[search_from..], identifier) orelse break;
        const hit = search_from + rel;

        var cursor = skipAsciiWhitespace(text, hit + identifier.len);
        if (cursor >= text.len or text[cursor] != '=') {
            search_from = hit + identifier.len;
            continue;
        }
        if (cursor + 1 < text.len and text[cursor + 1] == '=') {
            search_from = hit + identifier.len;
            continue;
        }

        cursor = skipAsciiWhitespace(text, cursor + 1);
        const end = findTopLevelSemicolonIndex(text, cursor) orelse return null;
        const rhs = std.mem.trim(u8, text[cursor..end], " \t");
        if (rhs.len == 0) return null;
        return rhs;
    }
    return null;
}

pub fn findTopLevelSemicolonIndex(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;

    var state = NestingState{};
    var i: usize = start;
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
            ';' => {
                if (state.paren == 0 and state.bracket == 0 and state.brace == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

pub fn isSafeInlinePropertyInitializer(rhs: []const u8, property_name: []const u8) bool {
    var candidate = std.mem.trim(u8, rhs, " \t");
    if (candidate.len == 0) return false;
    if (containsWord(candidate, property_name)) return false;
    if (std.mem.indexOf(u8, candidate, ".getAs(") != null) return false;

    while (candidate.len > 0 and candidate[0] == '(') {
        const close = findMatchingParen(candidate, 0) orelse break;
        candidate = std.mem.trimLeft(u8, candidate[(close + 1)..], " \t");
    }
    if (!startsWithWordIgnoreCase(candidate, "new")) return false;

    const rest = std.mem.trimLeft(u8, candidate["new".len..], " \t");
    if (rest.len == 0) return false;
    const ctor_open = std.mem.indexOfScalar(u8, rest, '(') orelse return false;
    const ctor_close = findMatchingParen(rest, ctor_open) orelse return false;

    const ctor_type = std.mem.trim(u8, rest[0..ctor_open], " \t");
    if (ctor_type.len == 0 or !looksLikeTypeName(ctor_type)) return false;

    const ctor_args = std.mem.trim(u8, rest[(ctor_open + 1)..ctor_close], " \t");
    if (ctor_args.len != 0) return false;

    const tail = std.mem.trim(u8, rest[(ctor_close + 1)..], " \t");
    return tail.len == 0;
}


pub fn defaultInitializedApexPropertyDeclaration(
    gpa: std.mem.Allocator,
    declaration: []const u8,
    inferred_initializer: ?[]const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, declaration, " \t");
    if (trimmed.len == 0) return gpa.dupe(u8, declaration);
    if (!std.mem.endsWith(u8, trimmed, ";")) return gpa.dupe(u8, declaration);
    if (std.mem.indexOfScalar(u8, trimmed, '=') != null) return gpa.dupe(u8, declaration);
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null or std.mem.indexOfScalar(u8, trimmed, ')') != null) return gpa.dupe(u8, declaration);

    const body = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");
    const split_index = std.mem.lastIndexOfAny(u8, body, " \t") orelse return gpa.dupe(u8, declaration);
    const name = std.mem.trim(u8, body[(split_index + 1)..], " \t");
    if (!isSimpleIdentifier(name)) return gpa.dupe(u8, declaration);

    var type_text = std.mem.trim(u8, body[0..split_index], " \t");
    if (type_text.len == 0) return gpa.dupe(u8, declaration);
    while (stripLeadingDeclarationModifier(type_text)) |stripped| {
        type_text = stripped;
    }
    if (type_text.len == 0) return gpa.dupe(u8, declaration);

    const declaration_has_static = containsWordIgnoreCase(body, "static");
    const initializer = inferred_initializer orelse
        (defaultInitializerForApexPropertyType(type_text, declaration_has_static) orelse return gpa.dupe(u8, declaration));
    const indent_len = declaration.len - std.mem.trimLeft(u8, declaration, " \t").len;
    const indent = declaration[0..indent_len];
    return std.fmt.allocPrint(gpa, "{s}{s} = {s};", .{ indent, body, initializer });
}

pub fn stripLeadingDeclarationModifier(type_text: []const u8) ?[]const u8 {
    const modifiers = [_][]const u8{
        "public",
        "private",
        "protected",
        "global",
        "static",
        "final",
        "transient",
        "volatile",
    };
    for (modifiers) |modifier| {
        if (!startsWithWordIgnoreCase(type_text, modifier)) continue;
        return std.mem.trimLeft(u8, type_text[modifier.len..], " \t");
    }
    return null;
}

pub fn defaultInitializerForApexPropertyType(type_text: []const u8, declaration_has_static: bool) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_text, " \t");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "Boolean")) return "false";
    if (declaration_has_static and std.ascii.eqlIgnoreCase(trimmed, "ApexSObject")) return "ApexSObject.of(\"SObject\")";
    if (std.ascii.eqlIgnoreCase(trimmed, "Map") or startsWithIgnoreCase(trimmed, "Map<")) {
        return "new LinkedHashMap<>()";
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "List") or startsWithIgnoreCase(trimmed, "List<")) {
        return "new ArrayList<>()";
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "Set") or startsWithIgnoreCase(trimmed, "Set<")) {
        return "new LinkedHashSet<>()";
    }
    return null;
}

pub fn looksLikePropertyDeclarationHeader(gpa: std.mem.Allocator, line: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    const first = firstIdentifier(trimmed) orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, "public") and
        !std.ascii.eqlIgnoreCase(first, "private") and
        !std.ascii.eqlIgnoreCase(first, "protected") and
        !std.ascii.eqlIgnoreCase(first, "global"))
    {
        return false;
    }
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '=') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '}') != null) return false;
    if (containsWordIgnoreCase(trimmed, "class")) return false;
    if (containsWordIgnoreCase(trimmed, "interface")) return false;
    if (containsWordIgnoreCase(trimmed, "enum")) return false;
    if (containsWordIgnoreCase(trimmed, "implements")) return false;
    if (containsWordIgnoreCase(trimmed, "extends")) return false;

    const parsed = (try parseTypedVariableDeclaration(gpa, trimmed, true)) orelse return false;
    defer {
        gpa.free(parsed.declaration_head);
        gpa.free(parsed.variable_name);
        gpa.free(parsed.java_type);
    }
    return true;
}

pub fn transpileTypedDeclarationLine(gpa: std.mem.Allocator, line: []const u8, allow_visibility: bool) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |_| {
        if (startsWithWordIgnoreCase(trimmed, "for")) return null;
    }

    const eq_pos = findTopLevelAssignmentOperator(trimmed);
    const left = std.mem.trim(u8, if (eq_pos) |pos| trimmed[0..pos] else trimmed, " \t");
    if (left.len == 0) return null;

    if (hasTopLevelComma(left)) {
        if (try transpileTypedMultiDeclarationLine(gpa, left, if (eq_pos) |pos| std.mem.trim(u8, trimmed[(pos + 1)..], " \t") else null, allow_visibility)) |multi| {
            return multi;
        }
    }

    var tokens = try splitWhitespace(gpa, left);
    defer tokens.deinit(gpa);
    if (tokens.items.len < 2) return null;

    const name = tokens.items[tokens.items.len - 1];
    if (!isSimpleIdentifier(name)) return null;

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
    defer gpa.free(java_type);

    const has_initializer = eq_pos != null;
    if (!has_initializer) {
        if (modifier_out.items.len == 0) {
            return try std.fmt.allocPrint(gpa, "{s} {s};", .{ java_type, name });
        }
        return try std.fmt.allocPrint(gpa, "{s} {s} {s};", .{ modifier_out.items, java_type, name });
    }

    const rhs = std.mem.trim(u8, trimmed[(eq_pos.? + 1)..], " \t");
    if (rhs.len == 0) return null;
    const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
    defer gpa.free(converted_rhs);
    const collection_unwrapped_rhs = try maybeUnwrapCollectionQueryResult(gpa, java_type, converted_rhs);
    defer gpa.free(collection_unwrapped_rhs);
    const normalized_rhs = try maybeWrapSingleQueryAssignment(gpa, name, collection_unwrapped_rhs);
    defer gpa.free(normalized_rhs);
    const coerced_rhs = try coerceLiteralForDeclaredType(gpa, java_type, normalized_rhs);
    defer gpa.free(coerced_rhs);

    if (modifier_out.items.len == 0) {
        return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ java_type, name, coerced_rhs });
    }
    return try std.fmt.allocPrint(gpa, "{s} {s} {s} = {s};", .{ modifier_out.items, java_type, name, coerced_rhs });
}

pub fn transpileTypedMultiDeclarationLine(
    gpa: std.mem.Allocator,
    left: []const u8,
    rhs_opt: ?[]const u8,
    allow_visibility: bool,
) !?[]u8 {
    var pieces = try splitCallArguments(gpa, left);
    defer pieces.deinit(gpa);
    if (pieces.items.len < 2) return null;

    const first_piece = std.mem.trim(u8, pieces.items[0], " \t");
    const first = (try parseTypedVariableDeclaration(gpa, first_piece, allow_visibility)) orelse return null;
    defer {
        gpa.free(first.declaration_head);
        gpa.free(first.variable_name);
        gpa.free(first.java_type);
    }

    var names_out: std.ArrayList(u8) = .empty;
    defer names_out.deinit(gpa);
    try names_out.appendSlice(gpa, first.variable_name);

    for (pieces.items[1..]) |raw_name| {
        const name = std.mem.trim(u8, raw_name, " \t");
        if (!isSimpleIdentifier(name)) return null;
        try names_out.appendSlice(gpa, ", ");
        try names_out.appendSlice(gpa, name);
    }

    const var_pos = std.mem.lastIndexOf(u8, first.declaration_head, first.variable_name) orelse return null;
    const decl_prefix = std.mem.trimRight(u8, first.declaration_head[0..var_pos], " \t");
    if (decl_prefix.len == 0) return null;

    if (rhs_opt) |rhs| {
        if (rhs.len == 0) return null;
        const converted_rhs = try convertApexExpressionToJava(gpa, rhs);
        defer gpa.free(converted_rhs);
        const coerced_rhs = try coerceLiteralForDeclaredType(gpa, first.java_type, converted_rhs);
        defer gpa.free(coerced_rhs);
        return try std.fmt.allocPrint(gpa, "{s} {s} = {s};", .{ decl_prefix, names_out.items, coerced_rhs });
    }

    return try std.fmt.allocPrint(gpa, "{s} {s};", .{ decl_prefix, names_out.items });
}

pub fn coerceLiteralForDeclaredType(
    gpa: std.mem.Allocator,
    declared_java_type: []const u8,
    rhs: []const u8,
) ![]u8 {
    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    if (std.ascii.eqlIgnoreCase(declared_java_type, "Double") and isIntegerLiteral(trimmed_rhs)) {
        return std.fmt.allocPrint(gpa, "{s}.0", .{trimmed_rhs});
    }
    if (std.ascii.eqlIgnoreCase(declared_java_type, "String") and shouldCoerceExpressionToString(trimmed_rhs)) {
        return std.fmt.allocPrint(gpa, "String.valueOf({s})", .{trimmed_rhs});
    }
    return gpa.dupe(u8, rhs);
}

pub fn shouldCoerceExpressionToString(rhs: []const u8) bool {
    const trimmed = std.mem.trim(u8, rhs, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '"') return false;
    if (std.mem.indexOfScalar(u8, trimmed, '+') != null) return false;

    const known_non_string_producers = [_][]const u8{
        "System.now(",
        "DateTime.now(",
        "Date.today(",
        "System.today(",
    };
    for (known_non_string_producers) |prefix| {
        if (startsWithIgnoreCase(trimmed, prefix)) return true;
    }
    return false;
}

pub fn isIntegerLiteral(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return false;

    var idx: usize = 0;
    if (trimmed[idx] == '+' or trimmed[idx] == '-') {
        idx += 1;
    }
    if (idx >= trimmed.len) return false;

    while (idx < trimmed.len) : (idx += 1) {
        if (!std.ascii.isDigit(trimmed[idx])) return false;
    }
    return true;
}

pub fn appendImportUnlessClassNameConflicts(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    class_name: []const u8,
    import_line: []const u8,
    imported_simple_name: []const u8,
) !void {
    if (std.ascii.eqlIgnoreCase(class_name, imported_simple_name)) return;
    try out.appendSlice(gpa, import_line);
}
