const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const file_io = @import("file_io.zig");
const trigger = @import("trigger.zig");
const compat = @import("compat.zig");

// Aliases for functions extracted to util.zig
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
const findMatchingAngleBackward = util.findMatchingAngleBackward;
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
const isApexClassSource = util.isApexClassSource;
const isApexTriggerSource = util.isApexTriggerSource;
const pathExists = util.pathExists;
const isValidPackageName = util.isValidPackageName;
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

pub const Options = types.Options;
pub const UnsupportedDiagnostic = types.UnsupportedDiagnostic;
pub const Summary = types.Summary;

// Aliases for functions extracted to file_io.zig
const collectApexFiles = file_io.collectApexFiles;
const collectApexTriggerFiles = file_io.collectApexTriggerFiles;
const collectPath = file_io.collectPath;
const collectTriggerPath = file_io.collectTriggerPath;
const collectDirectory = file_io.collectDirectory;
const collectTriggerDirectory = file_io.collectTriggerDirectory;
const appendApexFile = file_io.appendApexFile;
const normalizeApexTemplateTokens = file_io.normalizeApexTemplateTokens;
const deinitApexFiles = file_io.deinitApexFiles;
const writeOutputFile = file_io.writeOutputFile;

// Aliases for functions extracted to trigger.zig
const parseTriggerRegistration = trigger.parseTriggerRegistration;
const parseTriggerEvents = trigger.parseTriggerEvents;
const parseTriggerEvent = trigger.parseTriggerEvent;
const triggerEventListContains = trigger.triggerEventListContains;
const triggerEventName = trigger.triggerEventName;
const writeTriggerManifest = trigger.writeTriggerManifest;

// Aliases for functions extracted to compat.zig
const rewriteKnownCompatibilityFixups = compat.rewriteKnownCompatibilityFixups;
const rewriteVisualforceComponentQualifiedAccess = compat.rewriteVisualforceComponentQualifiedAccess;
const rewriteConstructedSObjectTypeClassGetNameCalls = compat.rewriteConstructedSObjectTypeClassGetNameCalls;
const isLikelySObjectNamespaceToken = compat.isLikelySObjectNamespaceToken;
const rewritePseudoSObjectNamespaceAccess = compat.rewritePseudoSObjectNamespaceAccess;
const rewriteResidualCompatibilityArtifacts = compat.rewriteResidualCompatibilityArtifacts;
const rewriteErasedOverloadCompatibility = compat.rewriteErasedOverloadCompatibility;
const rewriteNpspAliasCompat = compat.rewriteNpspAliasCompat;
const rewriteLateCompatibilityFixups = compat.rewriteLateCompatibilityFixups;
const rewriteLabelNamespaceAccess = compat.rewriteLabelNamespaceAccess;
const rewriteLowercaseDatabaseNamespaceAccess = compat.rewriteLowercaseDatabaseNamespaceAccess;
const rewriteCustomSchemaSObjectTypeAccess = compat.rewriteCustomSchemaSObjectTypeAccess;
const rewriteBareCustomSObjectTypeAccess = compat.rewriteBareCustomSObjectTypeAccess;
const isLikelyBareStandardSObjectTypeToken = compat.isLikelyBareStandardSObjectTypeToken;
const rewriteBareStandardSObjectTypeAccess = compat.rewriteBareStandardSObjectTypeAccess;
const rewriteBareCustomSettingsSingletonAccess = compat.rewriteBareCustomSettingsSingletonAccess;
const rewritePageNamespaceAccess = compat.rewritePageNamespaceAccess;
const rewriteTypePathGetAsAccess = compat.rewriteTypePathGetAsAccess;
const rewriteSObjectTypeVariableGetAsAccess = compat.rewriteSObjectTypeVariableGetAsAccess;
const rewriteApexPagesNestedTypeAliases = compat.rewriteApexPagesNestedTypeAliases;
const rewriteBareCustomSObjectTypeArgCalls = compat.rewriteBareCustomSObjectTypeArgCalls;
const rewriteFieldDisplayTypeCalls = compat.rewriteFieldDisplayTypeCalls;
const rewriteCollectionViewPropertyAccess = compat.rewriteCollectionViewPropertyAccess;
const rewriteValuesFieldPseudoCalls = compat.rewriteValuesFieldPseudoCalls;
const rewriteValueOfRemoveCalls = compat.rewriteValueOfRemoveCalls;
const rewriteApexStringInstanceMethods = compat.rewriteApexStringInstanceMethods;
const baseExprLikelyString = compat.baseExprLikelyString;
const rewriteBrokenZeroLengthListInitializers = compat.rewriteBrokenZeroLengthListInitializers;
const rewriteQuerySingletonCallsAssignedToLists = compat.rewriteQuerySingletonCallsAssignedToLists;
const rewriteQuerySingletonAssignmentsToDeclaredListVars = compat.rewriteQuerySingletonAssignmentsToDeclaredListVars;
const rewriteDeclaredListQuerySingletonLine = compat.rewriteDeclaredListQuerySingletonLine;
const rewriteDeclaredSObjectQueryAssignments = compat.rewriteDeclaredSObjectQueryAssignments;
const rewriteDeclaredSObjectQueryAssignmentLine = compat.rewriteDeclaredSObjectQueryAssignmentLine;
const rewriteLegacyLiteralTokens = compat.rewriteLegacyLiteralTokens;
const rewriteBareSchemaEnumConstantAccess = compat.rewriteBareSchemaEnumConstantAccess;
const isMethodLikeSignatureLine = compat.isMethodLikeSignatureLine;
const rewriteBareSObjectTypeAccess = compat.rewriteBareSObjectTypeAccess;
const rewriteSObjectFieldNameObjectNameUses = compat.rewriteSObjectFieldNameObjectNameUses;
const rewriteInstanceListDeepCloneCalls = compat.rewriteInstanceListDeepCloneCalls;
const rewriteLongAssignmentsFromIntegerIdentifiers = compat.rewriteLongAssignmentsFromIntegerIdentifiers;
const rewriteBoxedNumericLiteralCompatibility = compat.rewriteBoxedNumericLiteralCompatibility;
const appendTypedNamesFromLine = compat.appendTypedNamesFromLine;
const appendTypedParameterNamesFromSignatureLine = compat.appendTypedParameterNamesFromSignatureLine;
const extractTypedDeclarationSection = compat.extractTypedDeclarationSection;
const rewriteTypedDeclarationIntegerInitializers = compat.rewriteTypedDeclarationIntegerInitializers;
const rewriteTypedNameLiteralAssignments = compat.rewriteTypedNameLiteralAssignments;
const rewriteLongMathMaxAssignments = compat.rewriteLongMathMaxAssignments;
const rewriteIntegerTypedDoubleAssignments = compat.rewriteIntegerTypedDoubleAssignments;
const memberNameLikelyDouble = compat.memberNameLikelyDouble;
const rewriteLikelyDoubleMemberLiteralAssignments = compat.rewriteLikelyDoubleMemberLiteralAssignments;
const detectMethodReturnKind = compat.detectMethodReturnKind;
const rewriteMethodReturnLiterals = compat.rewriteMethodReturnLiterals;
const rewriteBoxedNumericCasts = compat.rewriteBoxedNumericCasts;
const lhsContainsTypedName = compat.lhsContainsTypedName;
const normalizeExpressionForKind = compat.normalizeExpressionForKind;
const normalizeLiteralForKind = compat.normalizeLiteralForKind;
const isSignedIntegerLiteral = compat.isSignedIntegerLiteral;
const isSignedDecimalZeroLiteral = compat.isSignedDecimalZeroLiteral;
const rewriteDoubleDateTimeDeltaAssignments = compat.rewriteDoubleDateTimeDeltaAssignments;
const rewriteGetAsCollectionAccessors = compat.rewriteGetAsCollectionAccessors;
const parseStringLiteralContents = compat.parseStringLiteralContents;
const countUppercaseChars = compat.countUppercaseChars;
const lowercaseIdentifier = compat.lowercaseIdentifier;
const isScreamingSnakeIdentifier = compat.isScreamingSnakeIdentifier;
const isCaseVariantCandidate = compat.isCaseVariantCandidate;
const isImportOrPackageLineAt = compat.isImportOrPackageLineAt;
const rewriteCaseInsensitiveIdentifierVariants = compat.rewriteCaseInsensitiveIdentifierVariants;
const findTopLevelStatementSemicolon = compat.findTopLevelStatementSemicolon;
const rewriteGetAsMutationAssignments = compat.rewriteGetAsMutationAssignments;
const argLikelyNeedsStringKeyWrap = compat.argLikelyNeedsStringKeyWrap;
const rewriteSObjectGetPutAmbiguousArgs = compat.rewriteSObjectGetPutAmbiguousArgs;
const rewriteUnaryPlusStringLiterals = compat.rewriteUnaryPlusStringLiterals;
const rewriteGetAsNumericCompatibility = compat.rewriteGetAsNumericCompatibility;
const rewriteGetAsStringConcatenationCompatibility = compat.rewriteGetAsStringConcatenationCompatibility;
const rewriteGetAsStringConcatenationLine = compat.rewriteGetAsStringConcatenationLine;
const rewriteNumericGetAsLine = compat.rewriteNumericGetAsLine;
const getAsCallNeedsNumericCompatibility = compat.getAsCallNeedsNumericCompatibility;
const extractGetAsCallStringLiteralFieldName = compat.extractGetAsCallStringLiteralFieldName;
const containsFieldKeywordToken = compat.containsFieldKeywordToken;
const fieldNameLooksNumeric = compat.fieldNameLooksNumeric;
const fieldNameLooksNonNumeric = compat.fieldNameLooksNonNumeric;
const fieldNameLooksIdLike = compat.fieldNameLooksIdLike;
const fieldNameLooksBoolean = compat.fieldNameLooksBoolean;
const lineLikelyNeedsNumericGetAsRewrite = compat.lineLikelyNeedsNumericGetAsRewrite;
const getAsCallIsNullCompared = compat.getAsCallIsNullCompared;
const rewriteGetAsFieldAddErrorCalls = compat.rewriteGetAsFieldAddErrorCalls;
const rewriteBooleanEqualsIsEmptyArtifacts = compat.rewriteBooleanEqualsIsEmptyArtifacts;
const rewriteBooleanEqualsTrailingInvocationArtifacts = compat.rewriteBooleanEqualsTrailingInvocationArtifacts;
const rewriteApexStringsToIntegerIntCast = compat.rewriteApexStringsToIntegerIntCast;
const rewriteStringCollectionListOfArguments = compat.rewriteStringCollectionListOfArguments;
const shouldWrapStringCollectionArgument = compat.shouldWrapStringCollectionArgument;
const rewriteApexStringsValueOfCollectionWrappers = compat.rewriteApexStringsValueOfCollectionWrappers;
const rewriteNumericObjectCasts = compat.rewriteNumericObjectCasts;
const rewriteFinalCompatibilityCleanup = compat.rewriteFinalCompatibilityCleanup;
const rewriteTrailingDatabaseQueryAssignmentParens = compat.rewriteTrailingDatabaseQueryAssignmentParens;
const normalizeDatabaseQueryAssignmentLine = compat.normalizeDatabaseQueryAssignmentLine;
const rewriteListMethodQuerySingletonReturns = compat.rewriteListMethodQuerySingletonReturns;
const countByte = compat.countByte;
const isListMethodSignatureLine = compat.isListMethodSignatureLine;
const normalizeListMethodQuerySingletonReturnLine = compat.normalizeListMethodQuerySingletonReturnLine;
const rewriteValuesMethodCollectionViews = compat.rewriteValuesMethodCollectionViews;
const rewriteSchemaFieldNamespaceGetAsMethodCalls = compat.rewriteSchemaFieldNamespaceGetAsMethodCalls;
const rewriteDescribeFieldNamespaceAliases = compat.rewriteDescribeFieldNamespaceAliases;
const rewriteDescribeGetAsAliases = compat.rewriteDescribeGetAsAliases;
const rewriteGetAsEnumNameCalls = compat.rewriteGetAsEnumNameCalls;
const rewriteQueryWithBindsListChaining = compat.rewriteQueryWithBindsListChaining;
const rewriteGetAsDateMethodCalls = compat.rewriteGetAsDateMethodCalls;
const rewriteApexStringsValueOfDateGetAs = compat.rewriteApexStringsValueOfDateGetAs;
const rewriteDynamicFieldNameGetCalls = compat.rewriteDynamicFieldNameGetCalls;
const isLikelyCustomFieldSegment = compat.isLikelyCustomFieldSegment;
const isSObjectTypeNamespaceBase = compat.isSObjectTypeNamespaceBase;
const rewriteCustomSObjectMemberAccess = compat.rewriteCustomSObjectMemberAccess;
const rewriteKnownSObjectBooleanPropertyAccess = compat.rewriteKnownSObjectBooleanPropertyAccess;
const isComparisonRightOperandContext = compat.isComparisonRightOperandContext;
const rewriteBooleanGetOperands = compat.rewriteBooleanGetOperands;
const isBooleanEqualsCallLiteral = compat.isBooleanEqualsCallLiteral;
const isBooleanLiteralAt = compat.isBooleanLiteralAt;
const rewriteBooleanEqualsComparisonArtifacts = compat.rewriteBooleanEqualsComparisonArtifacts;
const extractGeneratedJavaClassName = compat.extractGeneratedJavaClassName;
const rewritePrivateStaticNestedTestClasses = compat.rewritePrivateStaticNestedTestClasses;
const rewriteLocalStaticWaitCalls = compat.rewriteLocalStaticWaitCalls;
const rewriteBrokenInlineMethodAssignmentsInSObjectSet = compat.rewriteBrokenInlineMethodAssignmentsInSObjectSet;
const rewriteNegatedSizeEqualityArtifacts = compat.rewriteNegatedSizeEqualityArtifacts;
const rewriteIntegerCompareToDoubleReturns = compat.rewriteIntegerCompareToDoubleReturns;
const rewriteDecimalSetScaleCalls = compat.rewriteDecimalSetScaleCalls;
const rewriteGetErrorsArrayAccess = compat.rewriteGetErrorsArrayAccess;
const rewriteRecordTypeInfoMapDeclarations = compat.rewriteRecordTypeInfoMapDeclarations;
const rewriteRecordTypeInfoUsages = compat.rewriteRecordTypeInfoUsages;
const extractDeclaredVariableName = compat.extractDeclaredVariableName;
const extractTypedVariableName = compat.extractTypedVariableName;
const extractParameterizedTypeVariableName = compat.extractParameterizedTypeVariableName;
const appendUniqueIdentifier = compat.appendUniqueIdentifier;
const identifierInList = compat.identifierInList;
const extractForEachVariableNameOfType = compat.extractForEachVariableNameOfType;
const extractSimpleAssignment = compat.extractSimpleAssignment;
const lineContainsRecordTypeInfoHelperCall = compat.lineContainsRecordTypeInfoHelperCall;
const lineContainsRecordTypeInfoGetter = compat.lineContainsRecordTypeInfoGetter;
const rewriteGetAsBooleanCompatibility = compat.rewriteGetAsBooleanCompatibility;
const rewriteGetAsStringMethodCalls = compat.rewriteGetAsStringMethodCalls;
const rewriteOverloadedStringIdCallArgs = compat.rewriteOverloadedStringIdCallArgs;
const rewriteEnhancedForGetAsIterables = compat.rewriteEnhancedForGetAsIterables;
const rewriteEnhancedForCompareArtifacts = compat.rewriteEnhancedForCompareArtifacts;
const rewriteDatabaseDeleteQueryCalls = compat.rewriteDatabaseDeleteQueryCalls;
const rewriteLinewiseRelationalComparisons = compat.rewriteLinewiseRelationalComparisons;
const rewriteFirstOrNullScalarWrappers = compat.rewriteFirstOrNullScalarWrappers;
const isIdGetAsSuffix = compat.isIdGetAsSuffix;
const rewriteNestedIdApexSwitchGetAs = compat.rewriteNestedIdApexSwitchGetAs;
const rewriteBrokenApexEqualsTernaryComparisons = compat.rewriteBrokenApexEqualsTernaryComparisons;
const rewriteStringCastBooleanEqualsArtifacts = compat.rewriteStringCastBooleanEqualsArtifacts;
const rewriteValueOfGetNameArtifacts = compat.rewriteValueOfGetNameArtifacts;
const isLikelyClassLiteralToken = compat.isLikelyClassLiteralToken;
const collectSystemTypeVariableNames = compat.collectSystemTypeVariableNames;
const rewriteSystemTypeClassLiteralAssignments = compat.rewriteSystemTypeClassLiteralAssignments;
const rewriteCollectionGenericInstanceof = compat.rewriteCollectionGenericInstanceof;
const rewriteDatabaseQueryIndexCompatibility = compat.rewriteDatabaseQueryIndexCompatibility;
const matchGetAsLikeCall = compat.matchGetAsLikeCall;
const parseBooleanLiteralComparison = compat.parseBooleanLiteralComparison;
const isBooleanOperandContext = compat.isBooleanOperandContext;
const isReturnKeywordContext = compat.isReturnKeywordContext;
const isBooleanIntroducerBeforeParen = compat.isBooleanIntroducerBeforeParen;
const assignmentContextExpectsBoolean = compat.assignmentContextExpectsBoolean;
const findPreviousNonWhitespace = compat.findPreviousNonWhitespace;
const findNextNonWhitespace = compat.findNextNonWhitespace;
const containsGetAsLikeCall = compat.containsGetAsLikeCall;
const findTopLevelColon = compat.findTopLevelColon;
const inferEnhancedForElementType = compat.inferEnhancedForElementType;
const rewriteUtilFinderInnerSearchBuilder = compat.rewriteUtilFinderInnerSearchBuilder;
const rewriteEpManageTemplateCompat = compat.rewriteEpManageTemplateCompat;
const replaceLiteralAll = compat.replaceLiteralAll;
const replaceSectionBetweenMarkers = compat.replaceSectionBetweenMarkers;
const rewriteApexMocksUtilsMethodFixups = compat.rewriteApexMocksUtilsMethodFixups;
const replaceMethodBodyBySignature = compat.replaceMethodBodyBySignature;
const rewriteDynamicWhereClauseQueryBinds = compat.rewriteDynamicWhereClauseQueryBinds;
const looksLikePublicMethodSignatureLine = compat.looksLikePublicMethodSignatureLine;
const collectDynamicQueryBindEntriesForMethod = compat.collectDynamicQueryBindEntriesForMethod;
const initializeBindVariablesInMethod = compat.initializeBindVariablesInMethod;
const maybeInitializeBindDeclarationLine = compat.maybeInitializeBindDeclarationLine;
const isBindVariableName = compat.isBindVariableName;
const isLikelyLocalDeclarationType = compat.isLikelyLocalDeclarationType;
const rewriteMethodQueryCallsWithDynamicBinds = compat.rewriteMethodQueryCallsWithDynamicBinds;
const collectBindNamesFromQueryExpression = compat.collectBindNamesFromQueryExpression;
const buildBindMapArgument = compat.buildBindMapArgument;
const rewriteBindMapArgumentWithMissingBinds = compat.rewriteBindMapArgumentWithMissingBinds;
const appendUniqueOwnedName = compat.appendUniqueOwnedName;
const containsIgnoreCaseOwnedName = compat.containsIgnoreCaseOwnedName;
const containsIgnoreCaseNameSlice = compat.containsIgnoreCaseNameSlice;
const getOrCreateDynamicBindEntry = compat.getOrCreateDynamicBindEntry;
const dynamicBindEntryIndex = compat.dynamicBindEntryIndex;
const deinitOwnedNameList = compat.deinitOwnedNameList;
const deinitDynamicBindEntries = compat.deinitDynamicBindEntries;
const rewriteInterfaceCompatibilityFixups = compat.rewriteInterfaceCompatibilityFixups;
const rewriteApexSystemUtilityCalls = compat.rewriteApexSystemUtilityCalls;
const rewriteDateArithmetic = compat.rewriteDateArithmetic;
const rewriteApexStrictEqualityOperators = compat.rewriteApexStrictEqualityOperators;
const rewriteApexNotEqualsOperator = compat.rewriteApexNotEqualsOperator;
const rewriteSystemStatusCodeConstants = compat.rewriteSystemStatusCodeConstants;
const rewriteStringRelationalComparisons = compat.rewriteStringRelationalComparisons;
const rewriteNestedParenStringRelationalComparisons = compat.rewriteNestedParenStringRelationalComparisons;
const rewriteTernaryStringRelationalComparisons = compat.rewriteTernaryStringRelationalComparisons;
const findTopLevelTernary = compat.findTopLevelTernary;
const findTopLevelRelationalMatch = compat.findTopLevelRelationalMatch;
const isLikelyGenericCloseAngle = compat.isLikelyGenericCloseAngle;
const nextNonWhitespaceChar = compat.nextNonWhitespaceChar;
const prevNonWhitespaceChar = compat.prevNonWhitespaceChar;
const hasWhitespaceAroundOperator = compat.hasWhitespaceAroundOperator;
const isLikelyStringishComparisonOperand = compat.isLikelyStringishComparisonOperand;
const isLikelyDateishComparisonOperand = compat.isLikelyDateishComparisonOperand;
const wrapNullSafeComparisons = compat.wrapNullSafeComparisons;
const findTopLevelLogicalOperator = compat.findTopLevelLogicalOperator;
const rewriteTriggerContextPropertyAccess = compat.rewriteTriggerContextPropertyAccess;
const rewriteApexSafeNavigationOperators = compat.rewriteApexSafeNavigationOperators;
const rewriteFirstApexSafeNavigationOperator = compat.rewriteFirstApexSafeNavigationOperator;
const findSafeNavigationLeftStart = compat.findSafeNavigationLeftStart;
const isSafeNavigationBoundaryChar = compat.isSafeNavigationBoundaryChar;
const rewriteNullCoalescingOperator = compat.rewriteNullCoalescingOperator;
const findTopLevelNullCoalescingOperator = compat.findTopLevelNullCoalescingOperator;
const rewriteApexTypeCasts = compat.rewriteApexTypeCasts;
const rewriteSObjectGetAsLengthFallback = compat.rewriteSObjectGetAsLengthFallback;
const isLikelyCastStart = compat.isLikelyCastStart;
const isLikelyCastFollowToken = compat.isLikelyCastFollowToken;
const isLikelyCastType = compat.isLikelyCastType;
const rewriteGenericClassLiterals = compat.rewriteGenericClassLiterals;
const rewriteJsonDeserializeListCasts = compat.rewriteJsonDeserializeListCasts;
const rewriteSObjectGetAsMethodCalls = compat.rewriteSObjectGetAsMethodCalls;
const rewriteStringInstanceMethodCalls = compat.rewriteStringInstanceMethodCalls;
const rewritePrintlnGetAsCalls = compat.rewritePrintlnGetAsCalls;
const specificIdentifierReplacement = compat.specificIdentifierReplacement;
const hasUpperAfterFirst = compat.hasUpperAfterFirst;
const isPrecededByKeywordIgnoreCase = compat.isPrecededByKeywordIgnoreCase;
const rewriteSpecificIdentifierCase = compat.rewriteSpecificIdentifierCase;
const rewriteTestDoubleClassCtorCalls = compat.rewriteTestDoubleClassCtorCalls;
const isSelfQualifiedTypeReference = compat.isSelfQualifiedTypeReference;
const rewriteSystemTypeListOfClassLiterals = compat.rewriteSystemTypeListOfClassLiterals;
const rewriteSystemTypeMethodClassLiteralArgs = compat.rewriteSystemTypeMethodClassLiteralArgs;
const rewriteNoArgCloneCalls = compat.rewriteNoArgCloneCalls;
const rewriteStringKeyedSetMethodCalls = compat.rewriteStringKeyedSetMethodCalls;
const rewriteNoArgSortCalls = compat.rewriteNoArgSortCalls;
const rewriteIdGetSObjectTypeCalls = compat.rewriteIdGetSObjectTypeCalls;
const rewriteTypeSObjectTypeConstants = compat.rewriteTypeSObjectTypeConstants;
const rewriteTypeSObjectFieldConstants = compat.rewriteTypeSObjectFieldConstants;
const rewriteSObjectTypeFieldSetConstants = compat.rewriteSObjectTypeFieldSetConstants;
const typeReferenceObjectName = compat.typeReferenceObjectName;
const rewriteTriggerOperationEnumConstantCase = compat.rewriteTriggerOperationEnumConstantCase;
const canonicalTriggerOperationConstant = compat.canonicalTriggerOperationConstant;
const isStaticValueAccessPathExpression = compat.isStaticValueAccessPathExpression;
const findMemberAccessBaseStart = compat.findMemberAccessBaseStart;
const rewriteQueryGetAsAccess = compat.rewriteQueryGetAsAccess;
const rewriteFirstOrNullGetAs = compat.rewriteFirstOrNullGetAs;
const rewriteDatabaseQueryCallsWithBinds = compat.rewriteDatabaseQueryCallsWithBinds;
const collectSoqlBindNamesFromJavaLiteral = compat.collectSoqlBindNamesFromJavaLiteral;
const isJavaStringLiteral = compat.isJavaStringLiteral;
const rewriteIntegerValueOfNumericCasts = compat.rewriteIntegerValueOfNumericCasts;
const shouldForceIntegerValueOfCast = compat.shouldForceIntegerValueOfCast;
const containsGetAsCall = compat.containsGetAsCall;
const rewriteNumericValueOfObjectIdentifiers = compat.rewriteNumericValueOfObjectIdentifiers;
const convertBracketIndexAccessPass = compat.convertBracketIndexAccessPass;
const convertBracketIndexAccess = compat.convertBracketIndexAccess;
const looksLikeApexSizedArrayConstructorBase = compat.looksLikeApexSizedArrayConstructorBase;
const findIndexAccessBaseStart = compat.findIndexAccessBaseStart;
const extendOverConstructorNewKeyword = compat.extendOverConstructorNewKeyword;
const extendQualifiedIdentifierPathLeft = compat.extendQualifiedIdentifierPathLeft;
const extendIndexBaseLeft = compat.extendIndexBaseLeft;
const convertInlineCollectionConstructors = compat.convertInlineCollectionConstructors;
const isIdSObjectMapType = compat.isIdSObjectMapType;
const isIdSObjectMapGeneric = compat.isIdSObjectMapGeneric;
const convertInlineCollectionLiterals = compat.convertInlineCollectionLiterals;
const convertInlineSObjectConstructors = compat.convertInlineSObjectConstructors;
const rewriteObjectEqualityWithDeclaredObjects = compat.rewriteObjectEqualityWithDeclaredObjects;
const rewriteObjectEqualityLine = compat.rewriteObjectEqualityLine;
const rewriteEqualityOperators = compat.rewriteEqualityOperators;
const containsKnownObjectIdentifier = compat.containsKnownObjectIdentifier;
const rewriteSimpleObjectEqualityExpression = compat.rewriteSimpleObjectEqualityExpression;
const findSimpleEqualityOperator = compat.findSimpleEqualityOperator;
const containsStandaloneIdentifier = compat.containsStandaloneIdentifier;
const findLeftOperandStart = compat.findLeftOperandStart;
const skipWhitespace = compat.skipWhitespace;
const findExpressionEnd = compat.findExpressionEnd;
const findCastOperandEnd = compat.findCastOperandEnd;
const isNumericLiteral = compat.isNumericLiteral;
const rewriteApexInstanceofChecks = compat.rewriteApexInstanceofChecks;
const isTypeNameTokenChar = compat.isTypeNameTokenChar;
const findInstanceofLhsStart = compat.findInstanceofLhsStart;
const isInstanceofKeywordAt = compat.isInstanceofKeywordAt;
const isInstanceofOperandBoundary = compat.isInstanceofOperandBoundary;
const isLikelySObjectTypeForInstanceof = compat.isLikelySObjectTypeForInstanceof;
const isLikelyCustomSObjectTypeName = compat.isLikelyCustomSObjectTypeName;
const convertInlineSoqlQueries = compat.convertInlineSoqlQueries;
const convertInlineSoslQueries = compat.convertInlineSoslQueries;
const normalizeSoslQueryForEmulation = compat.normalizeSoslQueryForEmulation;
const buildDatabaseSearchCall = compat.buildDatabaseSearchCall;
const rewriteDatabaseQueryStringConsumers = compat.rewriteDatabaseQueryStringConsumers;
const rewriteApexStringUtilityCalls = compat.rewriteApexStringUtilityCalls;
const unwrapDatabaseQueryCall = compat.unwrapDatabaseQueryCall;
const parseDatabaseQuerySource = compat.parseDatabaseQuerySource;
const convertSObjectFieldAccess = compat.convertSObjectFieldAccess;
const shouldSkipSObjectFieldAccessBase = compat.shouldSkipSObjectFieldAccessBase;
const isWithinImportOrPackageDeclaration = compat.isWithinImportOrPackageDeclaration;
const isWithinAnnotationQualifiedChain = compat.isWithinAnnotationQualifiedChain;
const BoxedNumericKind = compat.BoxedNumericKind;
const MethodReturnKind = compat.MethodReturnKind;
const SimpleAssignment = compat.SimpleAssignment;
const CompatibilityState = compat.CompatibilityState;
const GetAsLikeCall = compat.GetAsLikeCall;
const BooleanLiteralComparison = compat.BooleanLiteralComparison;
const DynamicBindEntry = compat.DynamicBindEntry;
const RelationalOperator = compat.RelationalOperator;
const RelationalMatch = compat.RelationalMatch;
const SafeNavigationRewrite = compat.SafeNavigationRewrite;
const DatabaseQuerySource = compat.DatabaseQuerySource;


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
const TriggerEvent = types.TriggerEvent;
const TriggerRegistration = types.TriggerRegistration;

pub fn run(gpa: std.mem.Allocator, opts: Options) !Summary {
    if (opts.input_paths.len == 0) return error.MissingInputPath;

    var files = try collectApexFiles(gpa, opts.input_paths);
    defer deinitApexFiles(gpa, &files);

    var trigger_files = try collectApexTriggerFiles(gpa, opts.input_paths);
    defer deinitApexFiles(gpa, &trigger_files);

    if (files.items.len == 0) return error.NoApexClassSourceFound;
    if (!isValidPackageName(opts.package_name)) return error.InvalidPackageName;

    try std.fs.cwd().makePath(opts.out_dir);

    var summary = Summary{
        .files_scanned = files.items.len,
    };
    errdefer summary.deinit(gpa);

    for (files.items) |file| {
        var parsed = try parseApexClass(gpa, file.path, file.content);
        defer parsed.deinit(gpa);

        var rendered = try renderJavaClass(gpa, parsed, opts.package_name);
        defer rendered.deinit(gpa);

        if (opts.strict and rendered.unsupported_statements > 0) {
            return error.UnsupportedApexSyntax;
        }

        const output_name = try std.fmt.allocPrint(gpa, "{s}.java", .{parsed.class_name});
        defer gpa.free(output_name);

        const output_path = try std.fs.path.join(gpa, &.{ opts.out_dir, output_name });
        defer gpa.free(output_path);

        if (!opts.overwrite and pathExists(output_path)) {
            return error.OutputAlreadyExists;
        }

        try writeOutputFile(output_path, rendered.java);

        summary.files_generated += 1;
        summary.methods_generated += parsed.methods.items.len;
        summary.unsupported_statements += rendered.unsupported_statements;
        for (rendered.unsupported_lines.items) |line| {
            if (summary.unsupported_examples.items.len >= 64) break;

            const source_copy = try gpa.dupe(u8, parsed.source_path);
            errdefer gpa.free(source_copy);
            const method_copy = try gpa.dupe(u8, line.method_name);
            errdefer {
                gpa.free(source_copy);
                gpa.free(method_copy);
            }
            const statement_copy = try gpa.dupe(u8, line.statement);
            errdefer {
                gpa.free(source_copy);
                gpa.free(method_copy);
                gpa.free(statement_copy);
            }
            try summary.unsupported_examples.append(gpa, .{
                .source_path = source_copy,
                .method_name = method_copy,
                .line_no = line.source_line,
                .reason = line.reason,
                .statement = statement_copy,
            });
        }
    }

    var trigger_registrations: std.ArrayList(TriggerRegistration) = .empty;
    defer {
        for (trigger_registrations.items) |*registration| {
            registration.deinit(gpa);
        }
        trigger_registrations.deinit(gpa);
    }

    for (trigger_files.items) |file| {
        const maybe_registration = try parseTriggerRegistration(gpa, file.path, file.content);
        if (maybe_registration) |registration| {
            try trigger_registrations.append(gpa, registration);
            continue;
        }
        if (opts.strict) {
            return error.UnsupportedApexSyntax;
        }
    }

    if (trigger_registrations.items.len > 0) {
        try writeTriggerManifest(gpa, opts.out_dir, trigger_registrations.items, opts.overwrite);
    }

    return summary;
}


















const AnnotationPrefix = struct {
    annotations: [8][]const u8 = [_][]const u8{""} ** 8,
    count: usize = 0,
    consumed_len: usize = 0,
    saw_annotation: bool = false,
    incomplete: bool = false,
};

fn consumeLeadingInlineAnnotations(text: []const u8) AnnotationPrefix {
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


fn parseApexClass(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) anyerror!ParsedClass {
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

const InnerTypeHeader = struct {
    visibility: []const u8,
    type_name: []u8,
    suffix: []u8,
    kind: InnerTypeKind,
    is_abstract: bool = false,
    is_global: bool = false,
};

const InnerTypeKeyword = struct {
    kind: InnerTypeKind,
    pos: usize,
    keyword: []const u8,
};

fn innerTypeKeywordFromLine(trimmed: []const u8) ?InnerTypeKeyword {
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

fn innerTypeKindFromDeclarationLine(line: []const u8, outer_class_name: []const u8) ?InnerTypeKind {
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

fn looksLikeTypeDeclarationLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;

    const keyword = innerTypeKeywordFromLine(trimmed) orelse return false;
    const prefix = std.mem.trim(u8, trimmed[0..keyword.pos], " \t");
    if (!looksLikeInnerTypeDeclarationPrefix(prefix)) return false;
    const after_keyword = std.mem.trimLeft(u8, trimmed[(keyword.pos + keyword.keyword.len)..], " \t");
    const type_name = leadingIdentifier(after_keyword) orelse return false;
    return type_name.len > 0;
}

fn looksLikeTypeDeclarationContinuationLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;
    if (startsWithWordIgnoreCase(trimmed, "implements")) return true;
    if (startsWithWordIgnoreCase(trimmed, "extends")) return true;
    return false;
}

fn isExceptionLikeInnerClassDeclaration(line: []const u8) bool {
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

fn isExceptionLikeTypeHeader(type_name: []const u8, suffix: []const u8) bool {
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

fn parseInnerTypeHeader(
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

fn normalizeInnerClassSuffix(gpa: std.mem.Allocator, suffix: []const u8) ![]u8 {
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

fn extractRenderedJavaClassBody(rendered_java: []const u8) ?[]const u8 {
    const class_pos = std.mem.indexOf(u8, rendered_java, "public class") orelse
        std.mem.indexOf(u8, rendered_java, "public final class") orelse
        std.mem.indexOf(u8, rendered_java, "public abstract class") orelse return null;
    const open_brace = std.mem.indexOfScalarPos(u8, rendered_java, class_pos, '{') orelse return null;
    const close_brace = std.mem.lastIndexOfScalar(u8, rendered_java, '}') orelse return null;
    if (close_brace <= open_brace) return null;
    return std.mem.trim(u8, rendered_java[(open_brace + 1)..close_brace], " \t\r\n");
}

fn rewriteClassSuffixInnerTypeRefs(
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

fn collectInnerTypeNames(
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

fn stripSelfInnerImplementsFromClassSuffix(
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

fn replaceStandaloneTypeName(
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

fn defaultInitializedLocalDeclaration(
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

fn defaultInitializerForType(type_text: []const u8) ?[]const u8 {
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

fn isMethodOpeningLine(trimmed: []const u8) bool {
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

fn rewriteMethodCallByArgumentHint(
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

fn appendIndentedBlock(gpa: std.mem.Allocator, out: *std.ArrayList(u8), block: []const u8, indent: []const u8) !void {
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

fn appendInnerEnumConstantFromSegment(
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

fn collectInnerEnumConstants(gpa: std.mem.Allocator, block_source: []const u8) ![]u8 {
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

fn parseInterfaceMethodDeclaration(
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

fn transpileAbstractMethodDeclarationLine(
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

fn collectInterfaceMethodDeclarations(
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

fn transpileInnerTypeBlock(
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

fn beginMethodFromSignature(
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

fn shouldStartMethodSignatureBuffer(line: []const u8, class_name: []const u8) bool {
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

fn looksLikeMethodSignaturePrefix(gpa: std.mem.Allocator, line: []const u8) !bool {
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

fn parseClassName(gpa: std.mem.Allocator, source_path: []const u8, content: []const u8) ![]u8 {
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

fn parseClassDeclarationSuffix(
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

fn parseTopLevelDeclarationKind(
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

fn parseTopLevelEnumConstants(
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

fn looksLikeClassDeclarationPrefix(prefix: []const u8) bool {
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

fn looksLikeTopLevelDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return looksLikeClassDeclarationPrefix(prefix);
}

fn looksLikeInnerTypeDeclarationPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return looksLikeClassDeclarationPrefix(prefix);
}

fn isClassDeclarationPrefixToken(token: []const u8) bool {
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

fn detectClassIsGlobal(content: []const u8) bool {
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

fn detectClassIsTest(content: []const u8) bool {
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

fn detectClassSeeAllData(content: []const u8) bool {
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

fn parseMethodSignature(gpa: std.mem.Allocator, line: []const u8, class_name: []const u8) !?MethodSignature {
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

fn parseConstructorSignature(gpa: std.mem.Allocator, line: []const u8, class_name: []const u8) !?MethodSignature {
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

fn convertMethodParameters(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
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

fn transpileClassMemberLine(
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

fn transpileStaticInitializerBlock(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

const LeadingMemberAnnotations = struct {
    stripped: ?[]u8 = null,
    has_test_visible: bool = false,
};

fn stripLeadingAnnotationsFromMemberLine(
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

fn promoteDeclarationVisibilityForTestVisible(
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

fn transpileExceptionClassDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn visibilityModifierForInnerClass(prefix: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, prefix, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "private")) return "private";
        if (std.ascii.eqlIgnoreCase(token, "protected")) return "protected";
        if (std.ascii.eqlIgnoreCase(token, "public")) return "public";
        if (std.ascii.eqlIgnoreCase(token, "global")) return "public";
    }
    return "public";
}

fn transpilePropertyDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn inferPropertyGetterInitializer(gpa: std.mem.Allocator, property_line: []const u8, declaration: []const u8) !?[]u8 {
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

fn findPropertyAccessorBody(property_body: []const u8, accessor_name: []const u8) ?[]const u8 {
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

fn containsNullEqualityForIdentifier(text: []const u8, identifier: []const u8) bool {
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

fn containsReturnOfIdentifier(text: []const u8, identifier: []const u8) bool {
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

fn extractIdentifierAssignmentExpression(text: []const u8, identifier: []const u8) ?[]const u8 {
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

fn findTopLevelSemicolonIndex(text: []const u8, start: usize) ?usize {
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

fn isSafeInlinePropertyInitializer(rhs: []const u8, property_name: []const u8) bool {
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


fn defaultInitializedApexPropertyDeclaration(
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

fn stripLeadingDeclarationModifier(type_text: []const u8) ?[]const u8 {
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

fn defaultInitializerForApexPropertyType(type_text: []const u8, declaration_has_static: bool) ?[]const u8 {
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

fn looksLikePropertyDeclarationHeader(gpa: std.mem.Allocator, line: []const u8) !bool {
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

fn transpileTypedDeclarationLine(gpa: std.mem.Allocator, line: []const u8, allow_visibility: bool) !?[]u8 {
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

fn transpileTypedMultiDeclarationLine(
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

fn coerceLiteralForDeclaredType(
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

fn shouldCoerceExpressionToString(rhs: []const u8) bool {
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

fn isIntegerLiteral(text: []const u8) bool {
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

fn appendImportUnlessClassNameConflicts(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    class_name: []const u8,
    import_line: []const u8,
    imported_simple_name: []const u8,
) !void {
    if (std.ascii.eqlIgnoreCase(class_name, imported_simple_name)) return;
    try out.appendSlice(gpa, import_line);
}

fn renderJavaClass(gpa: std.mem.Allocator, parsed: ParsedClass, package_name: []const u8) !RenderedClass {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var unsupported_statements: usize = 0;
    var unsupported_lines: std.ArrayList(UnsupportedLine) = .empty;
    errdefer {
        for (unsupported_lines.items) |line| gpa.free(line.statement);
        unsupported_lines.deinit(gpa);
    }

    try appendFmt(gpa, &out, "package {s};\n\n", .{package_name});
    if (parsed.top_level_kind == .enum_type) {
        if (parsed.top_level_enum_constants) |enum_constants| {
            try appendFmt(
                gpa,
                &out,
                "// Generated by `apexgov emulate transpile` from {s}\n",
                .{parsed.source_path},
            );
            try appendFmt(gpa, &out, "public enum {s} {{ {s} }}\n", .{ parsed.class_name, enum_constants });
            return .{
                .java = try out.toOwnedSlice(gpa),
                .unsupported_statements = 0,
                .unsupported_lines = unsupported_lines,
            };
        }
    }

    if (parsed.top_level_kind == .interface) {
        const source_content = std.fs.cwd().readFileAlloc(gpa, parsed.source_path, 16 * 1024 * 1024) catch null;
        defer if (source_content) |content| gpa.free(content);
        const interface_methods = if (source_content) |content|
            try collectInterfaceMethodDeclarations(gpa, content, parsed.class_name)
        else
            try gpa.dupe(u8, "");
        defer gpa.free(interface_methods);

        try out.appendSlice(gpa, "import apexemu.runtime.*;\n");
        try out.appendSlice(gpa, "import java.util.*;\n\n");
        try appendFmt(
            gpa,
            &out,
            "// Generated by `apexgov emulate transpile` from {s}\n",
            .{parsed.source_path},
        );
        if (parsed.class_declaration_suffix) |suffix| {
            try appendFmt(gpa, &out, "public interface {s}{s} {{\n", .{ parsed.class_name, suffix });
        } else {
            try appendFmt(gpa, &out, "public interface {s} {{\n", .{parsed.class_name});
        }
        if (interface_methods.len > 0) try out.appendSlice(gpa, interface_methods);
        try out.appendSlice(gpa, "}\n");

        const raw_java = try out.toOwnedSlice(gpa);
        errdefer gpa.free(raw_java);
        const compatibility_fixed = try rewriteKnownCompatibilityFixups(gpa, raw_java);
        gpa.free(raw_java);
        const interface_fixed = try rewriteInterfaceCompatibilityFixups(gpa, compatibility_fixed);
        gpa.free(compatibility_fixed);
        return .{
            .java = interface_fixed,
            .unsupported_statements = 0,
            .unsupported_lines = unsupported_lines,
        };
    }

    try out.appendSlice(gpa, "import apexemu.runtime.*;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexSObject;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexCollections;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexSwitch;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexStrings;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.StringException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexAssert;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexCompare;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexMath;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Database;\n", "Database");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.JSON;\n", "JSON");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Test;\n", "Test");
    try out.appendSlice(gpa, "import apexemu.runtime.SystemAssert;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Security;\n", "Security");
    try out.appendSlice(gpa, "import apexemu.runtime.DmlException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ConnectApi;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Cache;\n", "Cache");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.EventBus;\n", "EventBus");
    try out.appendSlice(gpa, "import apexemu.runtime.DataWeave;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.DataWeaveScriptResource;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System;\n", "System");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System.Type;\n", "Type");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System.AccessType;\n", "AccessType");
    try out.appendSlice(gpa, "import apexemu.runtime.System.AccessLevel;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.System.SObjectAccessDecision;\n", "SObjectAccessDecision");
    try out.appendSlice(gpa, "import apexemu.runtime.System.NoAccessException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.System.SecurityException;\n\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Schema;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Trigger;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.UserInfo;\n", "UserInfo");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Limits;\n", "Limits");
    try out.appendSlice(gpa, "import apexemu.runtime.Messaging;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.VisualEditor;\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Network;\n", "Network");
    try out.appendSlice(gpa, "import apexemu.runtime.DateTime;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Date;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Time;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.ApexPages;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.PageReference;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Page;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Queueable;\n", "Queueable");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Schedulable;\n", "Schedulable");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.RestContext;\n", "RestContext");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.RestRequest;\n", "RestRequest");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.RestResponse;\n", "RestResponse");
    try out.appendSlice(gpa, "import apexemu.runtime.QueryException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.JSONException;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Crypto;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.Http;\n", "Http");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.HttpRequest;\n", "HttpRequest");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.HttpResponse;\n", "HttpResponse");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import apexemu.runtime.HttpCalloutMock;\n", "HttpCalloutMock");
    try out.appendSlice(gpa, "import apexemu.runtime.URL;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.EncodingUtil;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.Blob;\n");
    try out.appendSlice(gpa, "import apexemu.runtime.AuraHandledException;\n\n");
    if (parsed.is_global) {
        try out.appendSlice(gpa, "import apexemu.annotations.ApexGlobal;\n");
    }
    try out.appendSlice(gpa, "import java.util.ArrayList;\n");
    try out.appendSlice(gpa, "import java.util.LinkedHashMap;\n");
    try out.appendSlice(gpa, "import java.util.LinkedHashSet;\n");
    try out.appendSlice(gpa, "import java.util.Iterator;\n");
    try out.appendSlice(gpa, "import java.util.List;\n");
    try out.appendSlice(gpa, "import java.util.Map;\n");
    try out.appendSlice(gpa, "import java.util.Set;\n\n");
    try out.appendSlice(gpa, "import java.util.Comparator;\n\n");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import java.util.regex.Matcher;\n", "Matcher");
    try appendImportUnlessClassNameConflicts(gpa, &out, parsed.class_name, "import java.util.regex.Pattern;\n", "Pattern");
    try out.append(gpa, '\n');
    try appendFmt(
        gpa,
        &out,
        "// Generated by `apexgov emulate transpile` from {s}\n",
        .{parsed.source_path},
    );
    const class_suffix_raw = parsed.class_declaration_suffix orelse "";
    const class_suffix_inner_qualified = try rewriteClassSuffixInnerTypeRefs(gpa, class_suffix_raw, parsed.class_name, parsed.fields.items);
    defer gpa.free(class_suffix_inner_qualified);
    const class_suffix = try stripSelfInnerImplementsFromClassSuffix(gpa, class_suffix_inner_qualified, parsed.class_name, parsed.fields.items);
    defer gpa.free(class_suffix);
    const class_decl_prefix = if (classContainsAbstractMethodDeclaration(parsed.fields.items))
        "public abstract class"
    else
        "public class";
    if (parsed.is_global) {
        try out.appendSlice(gpa, "@ApexGlobal\n");
    }
    try appendFmt(gpa, &out, "{s} {s}{s} {{\n", .{ class_decl_prefix, parsed.class_name, class_suffix });
    const is_comparator_class = class_suffix.len > 0 and std.mem.indexOf(u8, class_suffix, "Comparator") != null;

    if (parsed.fields.items.len == 0 and parsed.methods.items.len == 0) {
        try out.appendSlice(gpa, "  // No method body was detected in the Apex source.\n");
    }

    if (parsed.fields.items.len > 0) {
        for (parsed.fields.items) |field| {
            try appendFmt(gpa, &out, "  {s}\n", .{field.declaration});
        }
        try out.append(gpa, '\n');
    }

    var emit_method = try gpa.alloc(bool, parsed.methods.items.len);
    defer gpa.free(emit_method);
    @memset(emit_method, true);

    for (parsed.methods.items, 0..) |method, method_idx| {
        var lookahead = method_idx + 1;
        while (lookahead < parsed.methods.items.len) : (lookahead += 1) {
            if (methodsCollapseToSameJavaSignature(method, parsed.methods.items[lookahead])) {
                emit_method[method_idx] = false;
                break;
            }
        }
    }

    for (parsed.methods.items, 0..) |method, method_idx| {
        if (!emit_method[method_idx]) continue;
        const emitted_name = if (method.is_constructor)
            parsed.class_name
        else
            method.name;

        if (method.is_test_setup and !method.is_constructor) {
            try out.appendSlice(gpa, "  @apexemu.annotations.TestSetup\n");
        } else if (method.is_test and !method.is_constructor) {
            if (method.is_test_see_all_data) {
                try out.appendSlice(gpa, "  @apexemu.annotations.Test(seeAllData = true)\n");
            } else {
                try out.appendSlice(gpa, "  @apexemu.annotations.Test\n");
            }
        }
        if (method.is_constructor) {
            try appendFmt(gpa, &out, "  public {s}({s}) {{\n", .{ emitted_name, method.java_parameters });
        } else {
            const static_prefix = if (method.is_static) "static " else "";
            const emitted_return_type = if (is_comparator_class and
                std.ascii.eqlIgnoreCase(method.name, "compare") and
                std.ascii.eqlIgnoreCase(method.java_return_type, "Integer"))
                "int"
            else if (std.ascii.eqlIgnoreCase(method.name, "hasNext") and
                std.ascii.eqlIgnoreCase(method.java_return_type, "Boolean"))
                "boolean"
            else
                method.java_return_type;
            try appendFmt(
                gpa,
                &out,
                "  public {s}{s} {s}({s}) {{\n",
                .{ static_prefix, emitted_return_type, emitted_name, method.java_parameters },
            );
        }
        try out.appendSlice(gpa, "    // TODO(apex): method body is copied as comments and needs manual porting.\n");

        var statements = try collectLogicalStatements(gpa, method.body);
        defer {
            for (statements.items) |statement| gpa.free(statement.text);
            statements.deinit(gpa);
        }

        var brace_depth: i32 = 0;
        var switch_stack: std.ArrayList(ActiveSwitchContext) = .empty;
        defer {
            while (switch_stack.items.len > 0) {
                const ctx = switch_stack.pop().?;
                gpa.free(ctx.subject_expr);
            }
            switch_stack.deinit(gpa);
        }
        // Track brace depths where System.runAs lambda blocks were opened
        var runas_depth_stack: std.ArrayList(i32) = .empty;
        defer runas_depth_stack.deinit(gpa);

        for (statements.items, 0..) |statement, idx| {
            const trimmed = std.mem.trim(u8, statement.text, " \t");
            if (trimmed.len == 0) continue;
            if (idx == statements.items.len - 1 and std.mem.eql(u8, trimmed, "}")) continue;

            while (switch_stack.items.len > 0 and brace_depth < switch_stack.items[switch_stack.items.len - 1].body_depth) {
                const stale = switch_stack.pop().?;
                gpa.free(stale.subject_expr);
            }

            // Check if this closing brace matches a runAs block
            if (std.mem.eql(u8, trimmed, "}") and runas_depth_stack.items.len > 0) {
                const expected_depth = runas_depth_stack.items[runas_depth_stack.items.len - 1];
                if (brace_depth - 1 == expected_depth) {
                    _ = runas_depth_stack.pop();
                    try appendFmt(gpa, &out, "    }} finally {{ Test.endRunAs(); }}\n", .{});
                    brace_depth += braceDelta(trimmed);
                    continue;
                }
            }

            const active_switch_expr: ?[]const u8 = if (switch_stack.items.len > 0)
                switch_stack.items[switch_stack.items.len - 1].subject_expr
            else
                null;
            const active_switch_mode = if (switch_stack.items.len > 0)
                switch_stack.items[switch_stack.items.len - 1].mode
            else
                SwitchMode.value;

            var switch_header_mode: ?SwitchMode = null;
            if (startsWithWordIgnoreCase(trimmed, "switch")) {
                switch_header_mode = try detectSwitchMode(gpa, statements.items, idx);
            }

            if (try transpileExecutableLineWithContext(
                gpa,
                trimmed,
                active_switch_expr,
                active_switch_mode,
                switch_header_mode,
            )) |converted| {
                defer gpa.free(converted);
                try appendFmt(gpa, &out, "    {s}\n", .{converted});

                // Track runAs block openings
                if (std.mem.indexOf(u8, converted, "// RUNAS_BLOCK") != null) {
                    try runas_depth_stack.append(gpa, brace_depth);
                }

                if (switch_header_mode) |mode| {
                    if (parseSwitchSubjectExpression(trimmed)) |switch_expr_raw| {
                        const switch_expr_java = try convertApexExpressionToJava(gpa, switch_expr_raw);
                        try switch_stack.append(gpa, .{
                            .body_depth = brace_depth + 1,
                            .subject_expr = switch_expr_java,
                            .mode = mode,
                        });
                    }
                }
            } else {
                unsupported_statements += 1;
                try appendFmt(gpa, &out, "    // {s}\n", .{trimmed});
                try unsupported_lines.append(gpa, .{
                    .method_name = method.name,
                    .source_line = method.start_line + statement.line_offset,
                    .reason = inferUnsupportedReason(trimmed),
                    .statement = try gpa.dupe(u8, trimmed),
                });
            }

            brace_depth += braceDelta(trimmed);
            while (switch_stack.items.len > 0 and brace_depth < switch_stack.items[switch_stack.items.len - 1].body_depth) {
                const stale = switch_stack.pop().?;
                gpa.free(stale.subject_expr);
            }
        }

        try out.appendSlice(gpa, "  }\n\n");
        try appendDoubleNumberCompatibilityOverload(gpa, &out, parsed.methods.items, method_idx, method, emitted_name);
    }

    try out.appendSlice(gpa,
        \\  @SuppressWarnings("unchecked")
        \\  public <T> T getAs(String field) {
        \\    return (T) ApexSwitch.getAs(this, field);
        \\  }
        \\
    );

    try out.appendSlice(gpa, "}\n");
    const raw_java = try out.toOwnedSlice(gpa);
    errdefer gpa.free(raw_java);

    const normalized_method_case = try rewriteCommonJavaMethodCase(gpa, raw_java);
    gpa.free(raw_java);
    errdefer gpa.free(normalized_method_case);

    const sobject_field_converted = try convertSObjectFieldAccess(gpa, normalized_method_case);
    gpa.free(normalized_method_case);
    errdefer gpa.free(sobject_field_converted);

    const sobject_type_field_constants = try rewriteTypeSObjectFieldConstants(gpa, sobject_field_converted);
    gpa.free(sobject_field_converted);
    errdefer gpa.free(sobject_type_field_constants);

    const sobject_fieldset_constants = try rewriteSObjectTypeFieldSetConstants(gpa, sobject_type_field_constants);
    gpa.free(sobject_type_field_constants);
    errdefer gpa.free(sobject_fieldset_constants);

    const sobject_get_as_calls = try rewriteSObjectGetAsMethodCalls(gpa, sobject_fieldset_constants);
    gpa.free(sobject_fieldset_constants);
    errdefer gpa.free(sobject_get_as_calls);

    const string_instance_calls = try rewriteStringInstanceMethodCalls(gpa, sobject_get_as_calls);
    gpa.free(sobject_get_as_calls);
    errdefer gpa.free(string_instance_calls);

    const println_calls = try rewritePrintlnGetAsCalls(gpa, string_instance_calls);
    gpa.free(string_instance_calls);
    errdefer gpa.free(println_calls);

    const identifier_case_fixed = try rewriteSpecificIdentifierCase(gpa, println_calls);
    gpa.free(println_calls);
    errdefer gpa.free(identifier_case_fixed);

    const test_double_ctor_fixed = try rewriteTestDoubleClassCtorCalls(gpa, identifier_case_fixed);
    gpa.free(identifier_case_fixed);
    errdefer gpa.free(test_double_ctor_fixed);

    const sobject_field_after_case = try convertSObjectFieldAccess(gpa, test_double_ctor_fixed);
    gpa.free(test_double_ctor_fixed);
    errdefer gpa.free(sobject_field_after_case);

    const system_type_list_literals = try rewriteSystemTypeListOfClassLiterals(gpa, sobject_field_after_case);
    gpa.free(sobject_field_after_case);
    errdefer gpa.free(system_type_list_literals);

    const system_type_method_class_literals = try rewriteSystemTypeMethodClassLiteralArgs(gpa, system_type_list_literals);
    gpa.free(system_type_list_literals);
    errdefer gpa.free(system_type_method_class_literals);

    const clone_calls = try rewriteNoArgCloneCalls(gpa, system_type_method_class_literals);
    gpa.free(system_type_method_class_literals);
    errdefer gpa.free(clone_calls);

    const dynamic_set_calls = try rewriteStringKeyedSetMethodCalls(gpa, clone_calls);
    gpa.free(clone_calls);
    errdefer gpa.free(dynamic_set_calls);

    const sort_calls = try rewriteNoArgSortCalls(gpa, dynamic_set_calls);
    gpa.free(dynamic_set_calls);
    errdefer gpa.free(sort_calls);

    const dynamic_where_binds_fixed = try rewriteDynamicWhereClauseQueryBinds(gpa, sort_calls);
    gpa.free(sort_calls);
    errdefer gpa.free(dynamic_where_binds_fixed);

    const math_mod_fixed = try rewriteMathModCalls(gpa, dynamic_where_binds_fixed);
    gpa.free(dynamic_where_binds_fixed);
    errdefer gpa.free(math_mod_fixed);

    const compatibility_fixed = try rewriteKnownCompatibilityFixups(gpa, math_mod_fixed);
    gpa.free(math_mod_fixed);
    errdefer gpa.free(compatibility_fixed);

    const interface_fixed = try rewriteInterfaceCompatibilityFixups(gpa, compatibility_fixed);
    gpa.free(compatibility_fixed);
    errdefer gpa.free(interface_fixed);

    const apex_mocks_utils_fixed = try rewriteApexMocksUtilsMethodFixups(gpa, interface_fixed);
    gpa.free(interface_fixed);
    errdefer gpa.free(apex_mocks_utils_fixed);

    return .{
        .java = apex_mocks_utils_fixed,
        .unsupported_statements = unsupported_statements,
        .unsupported_lines = unsupported_lines,
    };
}

fn methodsCollapseToSameJavaSignature(a: ParsedMethod, b: ParsedMethod) bool {
    if (a.is_constructor != b.is_constructor) return false;
    if (a.is_constructor) {
        return std.mem.eql(u8, std.mem.trim(u8, a.java_parameters, " \t"), std.mem.trim(u8, b.java_parameters, " \t"));
    }
    if (!std.ascii.eqlIgnoreCase(a.name, b.name)) return false;
    return std.mem.eql(u8, std.mem.trim(u8, a.java_parameters, " \t"), std.mem.trim(u8, b.java_parameters, " \t"));
}

fn classContainsAbstractMethodDeclaration(fields: []const ParsedField) bool {
    for (fields) |field| {
        const declaration = std.mem.trim(u8, field.declaration, " \t");
        if (declaration.len == 0) continue;
        if (!std.mem.containsAtLeast(u8, declaration, 1, "(")) continue;
        if (!std.mem.endsWith(u8, declaration, ";")) continue;
        if (startsWithIgnoreCase(declaration, "abstract ")) return true;
        if (std.mem.indexOf(u8, declaration, " abstract ")) |_| return true;
    }
    return false;
}

fn appendDoubleNumberCompatibilityOverload(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    methods: []const ParsedMethod,
    method_idx: usize,
    method: ParsedMethod,
    emitted_name: []const u8,
) !void {
    if (method.is_constructor) return;

    var params = try splitCallArguments(gpa, method.java_parameters);
    defer params.deinit(gpa);
    if (params.items.len == 0) return;

    var bridge_params: std.ArrayList(u8) = .empty;
    defer bridge_params.deinit(gpa);
    var call_args: std.ArrayList(u8) = .empty;
    defer call_args.deinit(gpa);

    var has_double_param = false;
    for (params.items, 0..) |raw_param, idx| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (param.len == 0) return;

        const param_name = lastIdentifier(param) orelse return;
        const name_pos = std.mem.lastIndexOf(u8, param, param_name) orelse return;
        const type_part = std.mem.trimRight(u8, param[0..name_pos], " \t");
        if (type_part.len == 0) return;

        const is_double = std.ascii.eqlIgnoreCase(type_part, "Double");
        has_double_param = has_double_param or is_double;

        if (idx != 0) {
            try bridge_params.appendSlice(gpa, ", ");
            try call_args.appendSlice(gpa, ", ");
        }

        if (is_double) {
            try appendFmt(gpa, &bridge_params, "Number {s}", .{param_name});
            try appendFmt(
                gpa,
                &call_args,
                "{s} == null ? null : {s}.doubleValue()",
                .{ param_name, param_name },
            );
        } else {
            try bridge_params.appendSlice(gpa, param);
            try call_args.appendSlice(gpa, param_name);
        }
    }

    if (!has_double_param) return;

    const bridge_sig = try normalizedParamTypeSignature(gpa, method.java_parameters, true);
    defer gpa.free(bridge_sig);
    for (methods, 0..) |other, idx| {
        if (idx == method_idx) continue;
        if (other.is_constructor or other.is_static != method.is_static) continue;
        if (!std.ascii.eqlIgnoreCase(other.name, emitted_name)) continue;
        const other_sig = try normalizedParamTypeSignature(gpa, other.java_parameters, false);
        defer gpa.free(other_sig);
        if (std.mem.eql(u8, other_sig, bridge_sig)) return;
    }

    const static_prefix = if (method.is_static) "static " else "";

    try appendFmt(
        gpa,
        out,
        "  public {s}{s} {s}({s}) {{\n",
        .{ static_prefix, method.java_return_type, emitted_name, bridge_params.items },
    );
    if (std.ascii.eqlIgnoreCase(method.java_return_type, "void")) {
        try appendFmt(gpa, out, "    {s}({s});\n", .{ emitted_name, call_args.items });
    } else {
        try appendFmt(gpa, out, "    return {s}({s});\n", .{ emitted_name, call_args.items });
    }
    try out.appendSlice(gpa, "  }\n\n");
}

fn normalizedParamTypeSignature(gpa: std.mem.Allocator, params_raw: []const u8, double_to_number: bool) ![]u8 {
    var params = try splitCallArguments(gpa, params_raw);
    defer params.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (params.items, 0..) |raw_param, idx| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (param.len == 0) continue;

        const param_name = lastIdentifier(param) orelse continue;
        const name_pos = std.mem.lastIndexOf(u8, param, param_name) orelse continue;
        const type_part = std.mem.trimRight(u8, param[0..name_pos], " \t");
        const normalized = if (double_to_number and std.ascii.eqlIgnoreCase(type_part, "Double"))
            "Number"
        else
            type_part;

        if (idx != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, normalized);
    }

    return out.toOwnedSlice(gpa);
}

const NestingState = struct {
    paren: i32 = 0,
    bracket: i32 = 0,
    brace: i32 = 0,
    in_single: bool = false,
    in_double: bool = false,
    escaped: bool = false,
};

const LogicalStatement = struct {
    text: []u8,
    line_offset: usize,
};

fn collectLogicalStatements(gpa: std.mem.Allocator, body: []const u8) !std.ArrayList(LogicalStatement) {
    var statements: std.ArrayList(LogicalStatement) = .empty;
    errdefer {
        for (statements.items) |statement| gpa.free(statement.text);
        statements.deinit(gpa);
    }

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var pending_line_offset: usize = 0;
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(gpa);
    var in_block_comment = false;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var line_offset: usize = 0;
    while (lines.next()) |raw_line| {
        const clean = std.mem.trimRight(u8, raw_line, "\r");
        const code_only = try stripApexCommentsFromLine(
            gpa,
            clean,
            &in_block_comment,
            &line_buffer,
        );
        const trimmed = std.mem.trim(u8, code_only, " \t");
        if (trimmed.len == 0) {
            line_offset += 1;
            continue;
        }

        if (pending.items.len == 0) {
            pending_line_offset = line_offset;
        } else {
            try pending.append(gpa, ' ');
        }
        try pending.appendSlice(gpa, trimmed);

        const current = std.mem.trim(u8, pending.items, " \t");
        if (!shouldFlushLogicalStatement(current)) {
            line_offset += 1;
            continue;
        }

        try appendLogicalStatement(gpa, &statements, current, pending_line_offset);
        pending.clearRetainingCapacity();
        line_offset += 1;
    }

    const tail = std.mem.trim(u8, pending.items, " \t");
    if (tail.len > 0) {
        try appendLogicalStatement(gpa, &statements, tail, pending_line_offset);
    }

    return statements;
}

fn appendLogicalStatement(
    gpa: std.mem.Allocator,
    statements: *std.ArrayList(LogicalStatement),
    raw_statement: []const u8,
    line_offset: usize,
) !void {
    const trimmed = std.mem.trim(u8, raw_statement, " \t");
    if (trimmed.len == 0) return;

    var chunks = try splitTopLevelSemicolonChunks(gpa, trimmed);
    defer {
        for (chunks.items) |chunk| gpa.free(chunk);
        chunks.deinit(gpa);
    }

    for (chunks.items) |chunk| {
        try appendLogicalChunk(gpa, statements, chunk, line_offset);
    }
}

fn appendLogicalChunk(
    gpa: std.mem.Allocator,
    statements: *std.ArrayList(LogicalStatement),
    raw_chunk: []const u8,
    line_offset: usize,
) !void {
    var rest = std.mem.trim(u8, raw_chunk, " \t");
    if (rest.len == 0) return;

    // Keep Apex do-while tails as one statement: `} while (cond);`
    if (isDoWhileTailLine(rest)) {
        try statements.append(gpa, .{
            .text = try gpa.dupe(u8, rest),
            .line_offset = line_offset,
        });
        return;
    }

    while (rest.len > 0 and rest[0] == '}') {
        try statements.append(gpa, .{
            .text = try gpa.dupe(u8, "}"),
            .line_offset = line_offset,
        });
        rest = std.mem.trimLeft(u8, rest[1..], " \t");
        if (rest.len == 0) return;
        if (isDoWhileTailLine(rest)) {
            try statements.append(gpa, .{
                .text = try gpa.dupe(u8, rest),
                .line_offset = line_offset,
            });
            return;
        }
    }

    if (try splitInlineBlockHeader(gpa, rest)) |split| {
        defer {
            gpa.free(split.head);
            gpa.free(split.tail);
        }
        try appendLogicalChunk(gpa, statements, split.head, line_offset);
        try appendLogicalChunk(gpa, statements, split.tail, line_offset);
        return;
    }

    try statements.append(gpa, .{
        .text = try gpa.dupe(u8, rest),
        .line_offset = line_offset,
    });
}

fn splitTopLevelSemicolonChunks(
    gpa: std.mem.Allocator,
    statement: []const u8,
) !std.ArrayList([]u8) {
    var chunks: std.ArrayList([]u8) = .empty;
    errdefer {
        for (chunks.items) |chunk| gpa.free(chunk);
        chunks.deinit(gpa);
    }

    var state = NestingState{};
    var start: usize = 0;
    var i: usize = 0;
    while (i < statement.len) : (i += 1) {
        const ch = statement[i];

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
            if (ch == '\'' and i + 1 < statement.len and statement[i + 1] == '\'') {
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
            ';' => {
                if (state.paren == 0 and state.bracket == 0) {
                    const piece = std.mem.trim(u8, statement[start .. i + 1], " \t");
                    if (piece.len > 0) {
                        try chunks.append(gpa, try gpa.dupe(u8, piece));
                    }
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, statement[start..], " \t");
    if (tail.len > 0) {
        try chunks.append(gpa, try gpa.dupe(u8, tail));
    }
    return chunks;
}

const InlineBlockHeaderSplit = struct {
    head: []u8,
    tail: []u8,
};

fn splitInlineBlockHeader(gpa: std.mem.Allocator, statement: []const u8) !?InlineBlockHeaderSplit {
    var state = NestingState{};
    var i: usize = 0;
    while (i < statement.len) : (i += 1) {
        const ch = statement[i];

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
            if (ch == '\'' and i + 1 < statement.len and statement[i + 1] == '\'') {
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
            '{' => {
                if (state.paren != 0 or state.bracket != 0) continue;

                const before = std.mem.trim(u8, statement[0..i], " \t");
                if (!shouldSplitInlineBlockHeader(before)) return null;

                const after = std.mem.trim(u8, statement[(i + 1)..], " \t");
                if (after.len == 0) return null;

                return .{
                    .head = try gpa.dupe(u8, std.mem.trim(u8, statement[0 .. i + 1], " \t")),
                    .tail = try gpa.dupe(u8, after),
                };
            },
            else => {},
        }
    }
    return null;
}

fn shouldSplitInlineBlockHeader(before_open_brace: []const u8) bool {
    if (before_open_brace.len == 0) return false;

    const control_headers = [_][]const u8{
        "if", "else", "for", "while", "do", "try", "catch", "finally", "switch", "when",
    };
    for (control_headers) |keyword| {
        if (startsWithWordIgnoreCase(before_open_brace, keyword)) return true;
    }

    if (startsWithIgnoreCase(before_open_brace, "System.runAs") and
        before_open_brace[before_open_brace.len - 1] == ')')
    {
        return true;
    }

    return false;
}

fn inferUnsupportedReason(statement: []const u8) []const u8 {
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

fn shouldFlushLogicalStatement(statement: []const u8) bool {
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

fn stripApexCommentsFromLine(
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

fn scanNestingState(text: []const u8) NestingState {
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

fn isControlBlockHeader(statement: []const u8) bool {
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

fn looksLikeControlHeaderWithoutBrace(statement: []const u8) bool {
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

fn transpileExecutableLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    return transpileExecutableLineWithContext(gpa, line, null, .value, null);
}

fn transpileExecutableLineWithContext(
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

fn transpileControlFlowLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    return transpileControlFlowLineWithContext(gpa, line, null, .value, null);
}

fn transpileControlFlowLineWithContext(
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

fn transpileInlineControlFlowStatement(
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

fn normalizeLeadingControlKeywordCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

fn transpileScopedInvocationBlockHeader(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn transpileSoqlLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn isSoqlLikelySingleRow(query_segment: []const u8) bool {
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

fn isSoqlCountQuery(query_segment: []const u8) bool {
    return startsWithIgnoreCase(query_segment, "SELECT COUNT(");
}

fn isLikelyJavaCollectionType(java_type: []const u8) bool {
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

fn buildDatabaseCountQueryCall(
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

fn collectSoqlBindNames(gpa: std.mem.Allocator, query_segment: []const u8) !std.ArrayList([]const u8) {
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
        const root = parts.next() orelse return gpa.dupe(u8, trimmed);
        if (isLikelyTypeReferenceIdentifier(root)) {
            var static_out: std.ArrayList(u8) = .empty;
            errdefer static_out.deinit(gpa);
            try static_out.appendSlice(gpa, root);

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
        try out.appendSlice(gpa, root);

        var last_part: []const u8 = root;
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

fn isLikelyBindMethodReferenceName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(name, "trim")) return true;
    if (startsWithIgnoreCase(name, "get") and name.len > 3 and std.ascii.isUpper(name[3])) return true;
    return false;
}

fn transpileDmlLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

const ApexDmlAccessMode = enum {
    none,
    user,
    system,
};

const ParsedDmlPayload = struct {
    payload: []const u8,
    mode: ApexDmlAccessMode,
};

fn parseApexDmlAccessMode(raw_payload: []const u8) ParsedDmlPayload {
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

fn buildDatabaseDmlCallWithMode(
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

fn transpileAssertionLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn transpileSystemDebugLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn transpileCollectionDeclarationLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn transpileGenericStatementLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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

fn transpileSafeNavigationInvocationStatement(gpa: std.mem.Allocator, statement_no_semicolon: []const u8) !?[]u8 {
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

fn findTopLevelPlusAssignmentOperator(text: []const u8) ?usize {
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

fn maybeWrapSingleQueryAssignment(
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

fn maybeUnwrapCollectionQueryResult(
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

fn maybeWrapSingleQueryResult(gpa: std.mem.Allocator, rhs: []const u8) ![]u8 {
    const trimmed_rhs = std.mem.trim(u8, rhs, " \t");
    if (!startsWithIgnoreCase(trimmed_rhs, "Database.query(") and
        !startsWithIgnoreCase(trimmed_rhs, "Database.queryWithBinds("))
    {
        return gpa.dupe(u8, rhs);
    }
    return std.fmt.allocPrint(gpa, "ApexCollections.firstOrNull({s})", .{trimmed_rhs});
}

fn looksLikeCollectionVariableName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0) return false;
    if (endsWithIgnoreCase(trimmed, "List")) return true;
    if (endsWithIgnoreCase(trimmed, "Map")) return true;
    if (endsWithIgnoreCase(trimmed, "Set")) return true;
    return std.ascii.toLower(trimmed[trimmed.len - 1]) == 's';
}

fn coerceLiteralForAssignmentContext(
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


const CollectionKind = enum {
    list,
    map,
    set,
};

const CollectionDeclaration = struct {
    kind: CollectionKind,
    java_type: []u8,
    variable_name: []u8,
};

const TypedVariableDeclaration = struct {
    declaration_head: []u8,
    variable_name: []u8,
    java_type: []u8,
};

fn parseCollectionDeclaration(gpa: std.mem.Allocator, left: []const u8) !?CollectionDeclaration {
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

fn parseTypedVariableDeclaration(
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

fn transpileCollectionInitializer(
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

fn normalizeQualifiedTypeName(raw: []const u8) ?[]const u8 {
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

fn isKnownSchemaHelperTypeName(raw: []const u8) bool {
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

fn collectionInterfaceName(kind: CollectionKind) []const u8 {
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

fn splitMergeArguments(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
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

fn findFirstTopLevelWhitespace(text: []const u8) ?usize {
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

fn hasTopLevelComma(text: []const u8) bool {
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

fn splitTopLevelWhitespaceExpressions(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
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

fn buildSystemAssertCall(gpa: std.mem.Allocator, method_name: []const u8, args: []const []const u8) ![]u8 {
    return buildAssertCall(gpa, "SystemAssert", method_name, args);
}

fn buildApexAssertCall(gpa: std.mem.Allocator, method_name: []const u8, args: []const []const u8) ![]u8 {
    return buildAssertCall(gpa, "ApexAssert", method_name, args);
}

fn normalizeApexAssertTypeArg(gpa: std.mem.Allocator, raw_arg: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_arg, " \t");
    if (trimmed.len < 7) return try gpa.dupe(u8, raw_arg);
    if (!std.mem.endsWith(u8, trimmed, ".class")) return try gpa.dupe(u8, raw_arg);

    const type_expr = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - ".class".len], " \t");
    const simple_name = extractSimpleTypeName(type_expr) orelse return try gpa.dupe(u8, raw_arg);
    return try std.fmt.allocPrint(gpa, "\"{s}\"", .{simple_name});
}

fn extractSimpleTypeName(type_expr_raw: []const u8) ?[]const u8 {
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

fn buildAssertCall(gpa: std.mem.Allocator, class_name: []const u8, method_name: []const u8, args: []const []const u8) ![]u8 {
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

fn rewriteCommonJavaMethodCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

fn rewriteKnownQualifiedTypeCase(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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

fn rewriteMathModCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
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










fn normalizeApexDoWhileTailLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
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



fn normalizeForHeaderTypes(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
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

fn normalizeApexSwitchHeader(gpa: std.mem.Allocator, line: []const u8, mode: SwitchMode) ![]u8 {
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

const ApexWhenTypePattern = struct {
    type_name: []const u8,
    binding_name: []const u8,
};

fn parseApexWhenTypePattern(gpa: std.mem.Allocator, text: []const u8) !?ApexWhenTypePattern {
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

fn normalizeApexWhenLine(
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

fn parseSwitchSubjectExpression(line: []const u8) ?[]const u8 {
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

fn detectSwitchMode(
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
























fn uniqueMethodName(
    gpa: std.mem.Allocator,
    name_counts: *std.StringHashMap(usize),
    method_name: []const u8,
) ![]u8 {
    const normalized = method_name;
    if (name_counts.get(normalized)) |seen| {
        const next = seen + 1;
        try name_counts.put(normalized, next);
        return std.fmt.allocPrint(gpa, "{s}__apex{d}", .{ method_name, next });
    }

    try name_counts.put(normalized, 1);
    return gpa.dupe(u8, method_name);
}

test "parseMethodSignature preserves return type params and static" {
    const gpa = std.testing.allocator;
    const sig = (try parseMethodSignature(gpa, "public static List<Id> run(List<Account> records, Integer n) {", "Demo")).?;
    defer {
        gpa.free(sig.name);
        gpa.free(sig.java_return_type);
        gpa.free(sig.java_parameters);
    }

    try std.testing.expectEqualStrings("run", sig.name);
    try std.testing.expectEqualStrings("List<String>", sig.java_return_type);
    try std.testing.expectEqualStrings("List<ApexSObject> records, Integer n", sig.java_parameters);
    try std.testing.expect(sig.is_static);

    const sig_map = (try parseMethodSignature(gpa, "public static Map<Id, Account> build(List<Account> records) {", "Demo")).?;
    defer {
        gpa.free(sig_map.name);
        gpa.free(sig_map.java_return_type);
        gpa.free(sig_map.java_parameters);
    }
    try std.testing.expectEqualStrings("build", sig_map.name);
    try std.testing.expectEqualStrings("Map<String, ApexSObject>", sig_map.java_return_type);
    try std.testing.expectEqualStrings("List<ApexSObject> records", sig_map.java_parameters);
    try std.testing.expect(sig_map.is_static);

    const sig_http = (try parseMethodSignature(gpa, "public HTTPResponse respond(HTTPRequest req) {", "Demo")).?;
    defer {
        gpa.free(sig_http.name);
        gpa.free(sig_http.java_return_type);
        gpa.free(sig_http.java_parameters);
    }
    try std.testing.expectEqualStrings("respond", sig_http.name);
    try std.testing.expectEqualStrings("HttpResponse", sig_http.java_return_type);
    try std.testing.expectEqualStrings("HttpRequest req", sig_http.java_parameters);

    try std.testing.expect((try parseMethodSignature(gpa, "for (Integer i = 0; i < 10; i++) {", "Demo")) == null);
    try std.testing.expect((try parseMethodSignature(gpa, "if (records == null) {", "Demo")) == null);
    try std.testing.expect((try parseMethodSignature(gpa, "public Demo() {", "Demo")) == null);
}

test "braceDelta ignores braces inside string literals" {
    try std.testing.expectEqual(@as(i32, 1), braceDelta("if (ready) {"));
    try std.testing.expectEqual(@as(i32, -1), braceDelta("}"));
    try std.testing.expectEqual(
        @as(i32, 1),
        braceDelta("String payload = '{\"ok\":true}'; if (go) {"),
    );
    try std.testing.expectEqual(
        @as(i32, 0),
        braceDelta("System.debug(\"{still string}\");"),
    );
}

test "parseApexClass captures multiline method and constructor signatures" {
    const gpa = std.testing.allocator;
    const source =
        \\public class MultiLineSignatureDemo {
        \\  @IsTest
        \\  public static void run(
        \\      List<Account> records,
        \\      Integer limit
        \\  )
        \\  {
        \\    System.debug(records);
        \\  }
        \\
        \\  public MultiLineSignatureDemo(
        \\      Integer n
        \\  )
        \\  {
        \\    System.debug(n);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "MultiLineSignatureDemo.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), parsed.methods.items.len);
    try std.testing.expectEqualStrings("run", parsed.methods.items[0].name);
    try std.testing.expect(parsed.methods.items[0].is_test);
    try std.testing.expectEqualStrings("List<ApexSObject> records, Integer limit", parsed.methods.items[0].java_parameters);
    try std.testing.expect(parsed.methods.items[0].start_line > 0);

    try std.testing.expect(parsed.methods.items[1].is_constructor);
    try std.testing.expectEqualStrings("MultiLineSignatureDemo", parsed.methods.items[1].name);
    try std.testing.expectEqualStrings("Integer n", parsed.methods.items[1].java_parameters);

    var rendered = try renderJavaClass(gpa, parsed, "generated");
    defer rendered.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "public static void run(List<ApexSObject> records, Integer limit)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "public MultiLineSignatureDemo(Integer n)") != null);
}

test "parseApexClass captures @testSetup methods separately from @isTest methods" {
    const gpa = std.testing.allocator;
    const source =
        \\@isTest
        \\public class SetupDemo {
        \\  @testSetup
        \\  static void setupData() {
        \\    insert new Account(Name='A');
        \\  }
        \\
        \\  @isTest
        \\  static void testRun() {
        \\    System.assert(true);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "SetupDemo.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), parsed.methods.items.len);
    try std.testing.expectEqualStrings("setupData", parsed.methods.items[0].name);
    try std.testing.expect(parsed.methods.items[0].is_test_setup);
    try std.testing.expect(!parsed.methods.items[0].is_test);
    try std.testing.expectEqualStrings("testRun", parsed.methods.items[1].name);
    try std.testing.expect(parsed.methods.items[1].is_test);
}

test "parseApexClass does not mark helper methods as tests from class-level @isTest" {
    const gpa = std.testing.allocator;
    const source =
        \\@isTest
        \\private class HelperDemo {
        \\  private static void setData(String v) {
        \\    System.debug(v);
        \\  }
        \\
        \\  static void testHappyPath() {
        \\    setData('ok');
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "HelperDemo.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), parsed.methods.items.len);
    try std.testing.expectEqualStrings("setData", parsed.methods.items[0].name);
    try std.testing.expect(!parsed.methods.items[0].is_test);
    try std.testing.expectEqualStrings("testHappyPath", parsed.methods.items[1].name);
    try std.testing.expect(parsed.methods.items[1].is_test);
}

test "parseApexClass captures seeAllData on class and method @isTest annotations" {
    const gpa = std.testing.allocator;
    const source =
        \\@isTest(SeeAllData=true)
        \\public class SeeAllDataDemo {
        \\  static void testImplicitFromClass() {
        \\    System.assert(true);
        \\  }
        \\
        \\  @isTest
        \\  static void testExplicitFromClass() {
        \\    System.assert(true);
        \\  }
        \\
        \\  @isTest(seeAllData = true)
        \\  static void testMethodLevel() {
        \\    System.assert(true);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "SeeAllDataDemo.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), parsed.methods.items.len);
    try std.testing.expect(parsed.methods.items[0].is_test);
    try std.testing.expect(parsed.methods.items[0].is_test_see_all_data);
    try std.testing.expect(parsed.methods.items[1].is_test);
    try std.testing.expect(parsed.methods.items[1].is_test_see_all_data);
    try std.testing.expect(parsed.methods.items[2].is_test);
    try std.testing.expect(parsed.methods.items[2].is_test_see_all_data);
}

test "parseApexClass ignores comment lines that look like signatures before enum" {
    const gpa = std.testing.allocator;
    const source =
        \\public class RestClient {
        \\  /**
        \\   * Keyword (DML) note should not be parsed as method signature.
        \\   */
        \\  public enum HttpVerb {
        \\    GET,
        \\    POST,
        \\    DEL
        \\  }
        \\
        \\  public static void ping() {
        \\    System.debug('ok');
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "RestClient.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), parsed.methods.items.len);
    try std.testing.expectEqualStrings("ping", parsed.methods.items[0].name);
}

test "parseApexClass captures nested classes without flattening their members" {
    const gpa = std.testing.allocator;
    const source =
        \\public class OuterService {
        \\  public static void run() {
        \\    System.debug('ok');
        \\  }
        \\
        \\  public class GeocodingAddress {
        \\    public String street;
        \\  }
        \\
        \\  public class OpenStreetMapHttpCalloutMockImpl implements HttpCalloutMock {
        \\    public HTTPResponse respond(HTTPRequest req) {
        \\      HttpResponse res = new HttpResponse();
        \\      return res;
        \\    }
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "OuterService.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), parsed.methods.items.len);
    try std.testing.expectEqualStrings("run", parsed.methods.items[0].name);

    var found_address = false;
    var found_mock = false;
    for (parsed.fields.items) |field| {
        if (std.mem.indexOf(u8, field.declaration, "static class GeocodingAddress") != null) {
            found_address = true;
        }
        if (std.mem.indexOf(u8, field.declaration, "static class OpenStreetMapHttpCalloutMockImpl implements HttpCalloutMock") != null) {
            found_mock = true;
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, "public HttpResponse respond(HttpRequest req)") != null);
        }
    }
    try std.testing.expect(found_address);
    try std.testing.expect(found_mock);
}

test "parseApexClass ignores string literals with class keywords for inner type detection" {
    const gpa = std.testing.allocator;
    const source =
        \\public class FinalizerHandler {
        \\  private static final String INVALID_TYPE_ERROR_FINALIZER = 'Please check metadata. The {0} class does not implement the TriggerAction.DmlFinalizer interface.';
        \\  public static void run() {
        \\    System.debug(INVALID_TYPE_ERROR_FINALIZER);
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "FinalizerHandler.cls", source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), parsed.methods.items.len);
    try std.testing.expectEqualStrings("run", parsed.methods.items[0].name);

    for (parsed.fields.items) |field| {
        try std.testing.expect(std.mem.indexOf(u8, field.declaration, "static class does") == null);
    }
}

test "parseApexClass captures inner class declarations without explicit visibility modifier" {
    const gpa = std.testing.allocator;
    const source =
        \\public class OuterService {
        \\  class BaseTest {
        \\    public void run() {
        \\      System.debug('ok');
        \\    }
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "OuterService.cls", source);
    defer parsed.deinit(gpa);

    var found_inner = false;
    for (parsed.fields.items) |field| {
        if (std.mem.indexOf(u8, field.declaration, "static class BaseTest") != null) {
            found_inner = true;
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, "public void run()") != null);
        }
    }
    try std.testing.expect(found_inner);
}

test "parseApexClass captures multiline class-literal field declarations" {
    const gpa = std.testing.allocator;
    const source =
        \\public class ClassLiteralMember {
        \\  private static final String MY_CLASS = ClassLiteralMember.class
        \\    .getName();
        \\}
    ;

    var parsed = try parseApexClass(gpa, "ClassLiteralMember.cls", source);
    defer parsed.deinit(gpa);

    var found_field = false;
    for (parsed.fields.items) |field| {
        if (std.mem.indexOf(u8, field.declaration, "MY_CLASS") != null) {
            found_field = true;
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, ".class") != null);
            try std.testing.expect(std.mem.indexOf(u8, field.declaration, ".getName()") != null);
        }
    }
    try std.testing.expect(found_field);
}

test "parseApexClass omits self-qualified nested interface implements to avoid Java cyclic inheritance" {
    const gpa = std.testing.allocator;
    const source =
        \\public class fflib_MyList implements IList {
        \\  public interface IList {
        \\    void add(String value);
        \\  }
        \\  public void add(String value) {}
        \\}
    ;

    var parsed = try parseApexClass(gpa, "fflib_MyList.cls", source);
    defer parsed.deinit(gpa);

    var rendered = try renderJavaClass(gpa, parsed, "generated");
    defer rendered.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "public class fflib_MyList {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "implements IList") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.java, "implements fflib_MyList.IList") == null);
}

test "parseApexClass captures multiline property with brace on next line" {
    const gpa = std.testing.allocator;
    const source =
        \\public class PropertyDemo {
        \\  private fflib_Helper helper;
        \\  public Boolean Enabled
        \\  {
        \\    get
        \\    {
        \\      return true;
        \\    }
        \\    private set;
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "PropertyDemo.cls", source);
    defer parsed.deinit(gpa);

    var found_helper = false;
    var found_property = false;
    for (parsed.fields.items) |field| {
        if (std.mem.eql(u8, field.declaration, "private fflib_Helper helper;")) found_helper = true;
        if (std.mem.eql(u8, field.declaration, "public Boolean Enabled = false; // Apex property { get; set; }")) found_property = true;
    }

    try std.testing.expect(found_helper);
    try std.testing.expect(found_property);
}

test "parseApexClass handles multiline class declaration continuation line" {
    const gpa = std.testing.allocator;
    const source =
        \\public without sharing class BatchDemo
        \\    implements Database.Batchable<SObject>, Schedulable {
        \\  public BatchDemo() {}
        \\  public void execute(SchedulableContext context) {}
        \\}
    ;

    var parsed = try parseApexClass(gpa, "BatchDemo.cls", source);
    defer parsed.deinit(gpa);

    var found_ctor = false;
    var found_execute = false;
    for (parsed.methods.items) |method| {
        if (method.is_constructor and std.mem.eql(u8, method.name, "BatchDemo")) found_ctor = true;
        if (!method.is_constructor and std.mem.eql(u8, method.name, "execute")) found_execute = true;
    }

    try std.testing.expect(found_ctor);
    try std.testing.expect(found_execute);
}

test "parseApexClass handles wrapped implements list declaration lines" {
    const gpa = std.testing.allocator;
    const source =
        \\public without sharing class WrappedBatchDemo implements Database.Batchable<SObject>, Database.Stateful,
        \\Schedulable {
        \\  public static Boolean isBatchButton = false;
        \\  public WrappedBatchDemo() {}
        \\}
    ;

    var parsed = try parseApexClass(gpa, "WrappedBatchDemo.cls", source);
    defer parsed.deinit(gpa);

    var found_field = false;
    var found_ctor = false;
    for (parsed.fields.items) |field| {
        if (std.mem.indexOf(u8, field.declaration, "isBatchButton") != null) {
            found_field = true;
        }
    }
    for (parsed.methods.items) |method| {
        if (method.is_constructor and std.mem.eql(u8, method.name, "WrappedBatchDemo")) {
            found_ctor = true;
        }
    }

    try std.testing.expect(found_field);
    try std.testing.expect(found_ctor);
}

test "shouldStartMethodSignatureBuffer ignores annotations and soql fragments" {
    try std.testing.expect(!shouldStartMethodSignatureBuffer("@AuraEnabled(cacheable=true scope='global')", "Demo"));
    try std.testing.expect(!shouldStartMethodSignatureBuffer("SELECT COUNT()", "Demo"));
    try std.testing.expect(shouldStartMethodSignatureBuffer("public static void run(", "Demo"));
}

test "renderJavaClass emits test annotation and method comment body" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "SampleTest"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/SampleTest.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "firstMethod"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, ""),
        .is_static = true,
        .is_constructor = false,
        .is_test = true,
        .is_test_setup = false,
        .body = try gpa.dupe(u8, "System.assertEquals(1, 1);\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "package generated;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static void firstMethod()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "import apexemu.runtime.ApexAssert;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "import apexemu.runtime.Test;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "SystemAssert.assertEquals(1, 1);") != null);
}

test "renderJavaClass emits seeAllData=true for test methods" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "SeeAllDataTest"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/SeeAllDataTest.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "testMethod"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, ""),
        .is_static = true,
        .is_constructor = false,
        .is_test = true,
        .is_test_setup = false,
        .is_test_see_all_data = true,
        .body = try gpa.dupe(u8, "System.assert(true);\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.Test(seeAllData = true)") != null);
}

test "renderJavaClass emits test setup annotation" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "SampleSetup"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/SampleSetup.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "setupData"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, ""),
        .is_static = true,
        .is_constructor = false,
        .is_test = false,
        .is_test_setup = true,
        .body = try gpa.dupe(u8, "Database.insert(ApexSObject.of(\"Account\"));\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.TestSetup") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "@apexemu.annotations.Test\n") == null);
}

test "renderJavaClass emits Number overload for static methods with Double parameters" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "PriceApi"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/PriceApi.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "run"),
        .java_return_type = try gpa.dupe(u8, "void"),
        .java_parameters = try gpa.dupe(u8, "Double maxPrice, Integer page"),
        .is_static = true,
        .is_constructor = false,
        .is_test = false,
        .is_test_setup = false,
        .body = try gpa.dupe(u8, "System.debug(maxPrice);\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static void run(Number maxPrice, Integer page)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "run(maxPrice == null ? null : maxPrice.doubleValue(), page);") != null);
}

test "renderJavaClass emits Number overload for instance methods with Double parameters" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "Builder"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/Builder.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "withAmount"),
        .java_return_type = try gpa.dupe(u8, "Builder"),
        .java_parameters = try gpa.dupe(u8, "Double amount"),
        .is_static = false,
        .is_constructor = false,
        .is_test = false,
        .is_test_setup = false,
        .body = try gpa.dupe(u8, "return this;\n"),
        .start_line = 1,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "public Builder withAmount(Number amount)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "return withAmount(amount == null ? null : amount.doubleValue());") != null);
}

test "renderJavaClass skips duplicate Number overload when already declared" {
    const gpa = std.testing.allocator;
    var parsed = ParsedClass{
        .class_name = try gpa.dupe(u8, "Builder"),
        .source_path = try gpa.dupe(u8, "force-app/main/default/classes/Builder.cls"),
    };
    defer parsed.deinit(gpa);

    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "withAmount"),
        .java_return_type = try gpa.dupe(u8, "Builder"),
        .java_parameters = try gpa.dupe(u8, "Double amount"),
        .is_static = false,
        .is_constructor = false,
        .is_test = false,
        .is_test_setup = false,
        .body = try gpa.dupe(u8, "return this;\n"),
        .start_line = 1,
    });
    try parsed.methods.append(gpa, .{
        .name = try gpa.dupe(u8, "withAmount"),
        .java_return_type = try gpa.dupe(u8, "Builder"),
        .java_parameters = try gpa.dupe(u8, "Number amount"),
        .is_static = false,
        .is_constructor = false,
        .is_test = false,
        .is_test_setup = false,
        .body = try gpa.dupe(u8, "return this;\n"),
        .start_line = 2,
    });

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.java, "public Builder withAmount(Number amount)"));
}

test "detectClassIsTest catches annotation immediately before class" {
    const source =
        \\@IsTest
        \\private class DemoTest {
        \\  static void testOne() {}
        \\}
    ;
    try std.testing.expect(detectClassIsTest(source));
}

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

test "rewriteSpecificIdentifierCase preserves constructor names with underscores" {
    const gpa = std.testing.allocator;
    const input = "fflib_ApexMocks mocks = new fflib_ApexMocks();";
    const rewritten = try rewriteSpecificIdentifierCase(gpa, input);
    defer gpa.free(rewritten);
    try std.testing.expectEqualStrings(input, rewritten);
}

test "rewriteSystemTypeMethodClassLiteralArgs rewrites class literal args for Type-based methods" {
    const gpa = std.testing.allocator;
    const input = "fflib_MyList mockList = (fflib_MyList)mocks.mock(fflib_MyList.class);";
    const rewritten = try rewriteSystemTypeMethodClassLiteralArgs(gpa, input);
    defer gpa.free(rewritten);
    try std.testing.expectEqualStrings(
        "fflib_MyList mockList = (fflib_MyList)mocks.mock(apexemu.runtime.System.Type.forName(\"fflib_MyList\"));",
        rewritten,
    );
}

test "rewriteSystemTypeMethodClassLiteralArgs rewrites forClass and setReadOnlyFields calls" {
    const gpa = std.testing.allocator;

    const for_class_input = "fflib_ArgumentCaptor argument = fflib_ArgumentCaptor.forClass(String.class);";
    const for_class_rewritten = try rewriteSystemTypeMethodClassLiteralArgs(gpa, for_class_input);
    defer gpa.free(for_class_rewritten);
    try std.testing.expectEqualStrings(
        "fflib_ArgumentCaptor argument = fflib_ArgumentCaptor.forClass(apexemu.runtime.System.Type.forName(\"String\"));",
        for_class_rewritten,
    );

    const set_readonly_input = "acc = (ApexSObject)fflib_ApexMocksUtils.setReadOnlyFields(acc, Account.class, properties);";
    const set_readonly_rewritten = try rewriteSystemTypeMethodClassLiteralArgs(gpa, set_readonly_input);
    defer gpa.free(set_readonly_rewritten);
    try std.testing.expectEqualStrings(
        "acc = (ApexSObject)fflib_ApexMocksUtils.setReadOnlyFields(acc, apexemu.runtime.System.Type.forName(\"Account\"), properties);",
        set_readonly_rewritten,
    );
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

test "parseConstructorSignature captures constructor params" {
    const gpa = std.testing.allocator;
    const sig = (try parseConstructorSignature(gpa, "public Demo(String name, List<Account> records) {", "Demo")).?;
    defer {
        gpa.free(sig.name);
        gpa.free(sig.java_return_type);
        gpa.free(sig.java_parameters);
    }

    try std.testing.expectEqualStrings("Demo", sig.name);
    try std.testing.expectEqualStrings("", sig.java_return_type);
    try std.testing.expectEqualStrings("String name, List<ApexSObject> records", sig.java_parameters);
    try std.testing.expect(!sig.is_static);
    try std.testing.expect(sig.is_constructor);
}

test "transpileAbstractMethodDeclarationLine converts abstract signatures" {
    const gpa = std.testing.allocator;
    const converted =
        (try transpileAbstractMethodDeclarationLine(gpa, "protected abstract void verify(fflib_QualifiedMethod qm, fflib_MethodArgValues methodArg);", "Demo")).?;
    defer gpa.free(converted);
    try std.testing.expectEqualStrings(
        "protected abstract void verify(fflib_QualifiedMethod qm, fflib_MethodArgValues methodArg);",
        converted,
    );
}

test "transpileClassMemberLine converts fields and properties" {
    const gpa = std.testing.allocator;

    const field_line = try transpileClassMemberLine(gpa, "private static final List<Account> cache = new List<Account>();", false);
    defer if (field_line) |value| gpa.free(value);
    try std.testing.expect(field_line != null);
    try std.testing.expectEqualStrings(
        "private static final List<ApexSObject> cache = new ArrayList<ApexSObject>();",
        field_line.?,
    );

    const lowercase_type_field = try transpileClassMemberLine(gpa, "private final fflib_MethodCountRecorder methodCountRecorder;", false);
    defer if (lowercase_type_field) |value| gpa.free(value);
    try std.testing.expect(lowercase_type_field != null);
    try std.testing.expectEqualStrings(
        "private final fflib_MethodCountRecorder methodCountRecorder;",
        lowercase_type_field.?,
    );

    const property_line = try transpileClassMemberLine(gpa, "public String Name { get; set; }", false);
    defer if (property_line) |value| gpa.free(value);
    try std.testing.expect(property_line != null);
    try std.testing.expectEqualStrings(
        "public String Name; // Apex property { get; set; }",
        property_line.?,
    );

    const array_property = try transpileClassMemberLine(gpa, "public Property__c[] records { get; set; }", false);
    defer if (array_property) |value| gpa.free(value);
    try std.testing.expect(array_property != null);
    try std.testing.expectEqualStrings(
        "public List<ApexSObject> records = new ArrayList<>(); // Apex property { get; set; }",
        array_property.?,
    );

    const lazy_property = try transpileClassMemberLine(
        gpa,
        \\private RD2_Settings rdSettings {
        \\  get {
        \\    if (rdSettings == null) {
        \\      rdSettings = new RD2_Settings();
        \\    }
        \\    return rdSettings;
        \\  }
        \\  set;
        \\}
    ,
        false,
    );
    defer if (lazy_property) |value| gpa.free(value);
    try std.testing.expect(lazy_property != null);
    try std.testing.expectEqualStrings(
        "private RD2_Settings rdSettings = new RD2_Settings(); // Apex property { get; set; }",
        lazy_property.?,
    );

    const complex_lazy_property = try transpileClassMemberLine(
        gpa,
        \\private HH_INaming householdNamingImpl {
        \\  get {
        \\    if (householdNamingImpl == null) {
        \\      Object classInstance = null;
        \\      householdNamingImpl = (HH_INaming) classInstance;
        \\    }
        \\    return householdNamingImpl;
        \\  }
        \\  set;
        \\}
    ,
        false,
    );
    defer if (complex_lazy_property) |value| gpa.free(value);
    try std.testing.expect(complex_lazy_property != null);
    try std.testing.expectEqualStrings(
        "private HH_INaming householdNamingImpl; // Apex property { get; set; }",
        complex_lazy_property.?,
    );

    const lazy_property_with_args = try transpileClassMemberLine(
        gpa,
        \\private RD2_OpportunityService oppService {
        \\  get {
        \\    if (oppService == null) {
        \\      oppService = new RD2_OpportunityService(currentDate, dbService, customFieldMapper);
        \\    }
        \\    return oppService;
        \\  }
        \\  set;
        \\}
    ,
        false,
    );
    defer if (lazy_property_with_args) |value| gpa.free(value);
    try std.testing.expect(lazy_property_with_args != null);
    try std.testing.expectEqualStrings(
        "private RD2_OpportunityService oppService; // Apex property { get; set; }",
        lazy_property_with_args.?,
    );

    const lazy_property_case_distinct_type = try transpileClassMemberLine(
        gpa,
        \\public NameFormatter nameFormatter {
        \\  get {
        \\    if (nameFormatter == null) {
        \\      nameFormatter = new NameFormatter();
        \\    }
        \\    return nameFormatter;
        \\  } private set;
        \\}
    ,
        false,
    );
    defer if (lazy_property_case_distinct_type) |value| gpa.free(value);
    try std.testing.expect(lazy_property_case_distinct_type != null);
    try std.testing.expectEqualStrings(
        "public NameFormatter nameFormatter = new NameFormatter(); // Apex property { get; set; }",
        lazy_property_case_distinct_type.?,
    );

    const lazy_property_self_reference_arg = try transpileClassMemberLine(
        gpa,
        \\private NameFormatter nameFormatter {
        \\  get {
        \\    if (nameFormatter == null) {
        \\      nameFormatter = new NameFormatter(nameFormatter);
        \\    }
        \\    return nameFormatter;
        \\  }
        \\  set;
        \\}
    ,
        false,
    );
    defer if (lazy_property_self_reference_arg) |value| gpa.free(value);
    try std.testing.expect(lazy_property_self_reference_arg != null);
    try std.testing.expectEqualStrings(
        "private NameFormatter nameFormatter; // Apex property { get; set; }",
        lazy_property_self_reference_arg.?,
    );

    const lazy_test_visible_static_property = try transpileClassMemberLine(
        gpa,
        \\private static OrgConfig orgConfig {
        \\  get {
        \\    if (orgConfig == null) {
        \\      orgConfig = new OrgConfig();
        \\    }
        \\    return orgConfig;
        \\  }
        \\  set;
        \\}
    ,
        true,
    );
    defer if (lazy_test_visible_static_property) |value| gpa.free(value);
    try std.testing.expect(lazy_test_visible_static_property != null);
    try std.testing.expectEqualStrings(
        "public static OrgConfig orgConfig = new OrgConfig(); // Apex property { get; set; }",
        lazy_test_visible_static_property.?,
    );

    const static_block = try transpileClassMemberLine(
        gpa,
        "static { loopCountMap = new Map<String, LoopCount>(); bypassedHandlers = new Set<String>(); }",
        false,
    );
    defer if (static_block) |value| gpa.free(value);
    try std.testing.expect(static_block != null);
    try std.testing.expectEqualStrings(
        "static {\n    loopCountMap = new LinkedHashMap<String, LoopCount>();\n    bypassedHandlers = new LinkedHashSet<String>();\n  }",
        static_block.?,
    );

    const object_array_property = try transpileClassMemberLine(gpa, "public Object[] rows { get; set; }", false);
    defer if (object_array_property) |value| gpa.free(value);
    try std.testing.expect(object_array_property != null);
    try std.testing.expectEqualStrings(
        "public List<ApexSObject> rows = new ArrayList<>(); // Apex property { get; set; }",
        object_array_property.?,
    );

    const test_visible_field = try transpileClassMemberLine(
        gpa,
        "@TestVisible private static final String invalid = 'The {0} class is invalid.';",
        false,
    );
    defer if (test_visible_field) |value| gpa.free(value);
    try std.testing.expect(test_visible_field != null);
    try std.testing.expectEqualStrings(
        "public static final String invalid = \"The {0} class is invalid.\";",
        test_visible_field.?,
    );

    const exception_inner =
        try transpileClassMemberLine(gpa, "public class AccountUpdateException extends Exception {", false);
    defer if (exception_inner) |value| gpa.free(value);
    try std.testing.expect(exception_inner != null);
    try std.testing.expectEqualStrings(
        "public static class AccountUpdateException extends apexemu.runtime.System.Exception { public AccountUpdateException() { super(); } public AccountUpdateException(String message) { super(message); } }",
        exception_inner.?,
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

test "collectLogicalStatements keeps multiline soql as one statement" {
    const gpa = std.testing.allocator;
    const body =
        \\Map<Id, Account> accountMap = new Map<Id, Account>([
        \\  SELECT Id, Name
        \\  FROM Account
        \\  WHERE Id IN :new Set<Id>()
        \\  LIMIT 10
        \\]);
    ;
    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), statements.items.len);
    const converted = try transpileExecutableLine(gpa, statements.items[0].text);
    defer if (converted) |value| gpa.free(value);
    try std.testing.expect(converted != null);
    try std.testing.expectEqualStrings(
        "Map<String, ApexSObject> accountMap = ApexCollections.mapById(Database.query(\"SELECT Id, Name FROM Account WHERE Id IN :new Set<Id>() LIMIT 10\"));",
        converted.?,
    );
}

test "collectLogicalStatements keeps multiline assignment with string concatenation" {
    const gpa = std.testing.allocator;
    const body =
        \\String queryString =
        \\  'SELECT Id, Name ' +
        \\  'FROM Account ' +
        \\  'WHERE Name LIKE \'Acme%\'';
    ;
    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), statements.items.len);
    try std.testing.expect(std.mem.indexOf(u8, statements.items[0].text, "String queryString =") != null);
    try std.testing.expect(std.mem.indexOf(u8, statements.items[0].text, "'FROM Account '") != null);
}

test "collectLogicalStatements strips block and line comments" {
    const gpa = std.testing.allocator;
    const body =
        \\// leading comment
        \\String a = 'x'; // trailing comment
        \\/* block
        \\ * comment
        \\ */
        \\String b = "http://example.invalid";
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expectEqualStrings("String a = 'x';", statements.items[0].text);
    try std.testing.expectEqualStrings("String b = \"http://example.invalid\";", statements.items[1].text);
}

test "collectLogicalStatements splits leading brace from else/catch lines" {
    const gpa = std.testing.allocator;
    const body =
        \\if (ok) {
        \\  doWork();
        \\} else { return; }
        \\try {
        \\  risky();
        \\} catch (Exception e) { handle(e); }
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 12), statements.items.len);
    try std.testing.expectEqualStrings("if (ok) {", statements.items[0].text);
    try std.testing.expectEqualStrings("doWork();", statements.items[1].text);
    try std.testing.expectEqualStrings("}", statements.items[2].text);
    try std.testing.expectEqualStrings("else {", statements.items[3].text);
    try std.testing.expectEqualStrings("return;", statements.items[4].text);
    try std.testing.expectEqualStrings("}", statements.items[5].text);
    try std.testing.expectEqualStrings("try {", statements.items[6].text);
    try std.testing.expectEqualStrings("risky();", statements.items[7].text);
    try std.testing.expectEqualStrings("}", statements.items[8].text);
    try std.testing.expectEqualStrings("catch (Exception e) {", statements.items[9].text);
    try std.testing.expectEqualStrings("handle(e);", statements.items[10].text);
    try std.testing.expectEqualStrings("}", statements.items[11].text);
}

test "collectLogicalStatements splits compact one-line runAs try/catch blocks" {
    const gpa = std.testing.allocator;
    const body =
        \\System.runAs(u1) { Test.startTest(); try { run(); } catch (Exception e) { handle(e); } Test.stopTest(); }
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 10), statements.items.len);
    try std.testing.expectEqualStrings("System.runAs(u1) {", statements.items[0].text);
    try std.testing.expectEqualStrings("Test.startTest();", statements.items[1].text);
    try std.testing.expectEqualStrings("try {", statements.items[2].text);
    try std.testing.expectEqualStrings("run();", statements.items[3].text);
    try std.testing.expectEqualStrings("}", statements.items[4].text);
    try std.testing.expectEqualStrings("catch (Exception e) {", statements.items[5].text);
    try std.testing.expectEqualStrings("handle(e);", statements.items[6].text);
    try std.testing.expectEqualStrings("}", statements.items[7].text);
    try std.testing.expectEqualStrings("Test.stopTest();", statements.items[8].text);
    try std.testing.expectEqualStrings("}", statements.items[9].text);
}

test "collectLogicalStatements handles escaped apostrophe in compact string literals" {
    const gpa = std.testing.allocator;
    const body =
        \\System.assert(true, 'doesn\'t fail'); System.debug('ok');
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expectEqualStrings(
        "System.assert(true, 'doesn\\'t fail');",
        statements.items[0].text,
    );
    try std.testing.expectEqualStrings("System.debug('ok');", statements.items[1].text);
}

test "collectLogicalStatements keeps do-while tail together" {
    const gpa = std.testing.allocator;
    const body =
        \\do {
        \\  i++;
        \\} while (i < 3);
    ;

    var statements = try collectLogicalStatements(gpa, body);
    defer {
        for (statements.items) |line| gpa.free(line.text);
        statements.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 3), statements.items.len);
    try std.testing.expectEqualStrings("do {", statements.items[0].text);
    try std.testing.expectEqualStrings("i++;", statements.items[1].text);
    try std.testing.expectEqualStrings("} while (i < 3);", statements.items[2].text);
}

test "startsWithWordIgnoreCase accepts punctuation boundaries" {
    try std.testing.expect(startsWithWordIgnoreCase("else{", "else"));
    try std.testing.expect(startsWithWordIgnoreCase("try{", "try"));
    try std.testing.expect(!startsWithWordIgnoreCase("elseif", "else"));
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

test "run counts unsupported statements when strict is disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class UnsupportedDemo {
        \\  public static void run() {
        \\    when Account acc {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "UnsupportedDemo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(root);
    const out_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "out" },
    );
    defer std.testing.allocator.free(out_dir);

    const inputs = [_][]const u8{root};
    var summary = try run(std.testing.allocator, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
        .strict = false,
    });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
    try std.testing.expect(summary.unsupported_statements > 0);
    try std.testing.expect(summary.unsupported_examples.items.len > 0);
    try std.testing.expect(summary.unsupported_examples.items[0].line_no > 0);
    try std.testing.expect(summary.unsupported_examples.items[0].reason.len > 0);
}

test "run strict mode fails on unsupported statements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class UnsupportedStrictDemo {
        \\  public static void run() {
        \\    when Account acc {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "UnsupportedStrictDemo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(root);
    const out_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "out" },
    );
    defer std.testing.allocator.free(out_dir);

    const inputs = [_][]const u8{root};
    try std.testing.expectError(
        error.UnsupportedApexSyntax,
        run(std.testing.allocator, .{
            .input_paths = &inputs,
            .out_dir = out_dir,
            .package_name = "generated",
            .overwrite = true,
            .strict = true,
        }),
    );
}

test "renderJavaClass keeps inner block closing brace" {
    const gpa = std.testing.allocator;

    const source =
        \\public class Demo {
        \\  public static void run() {
        \\    if (true) {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "if (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "    }\n  }\n") != null);
}

test "renderJavaClass emits inner enum and interface declarations" {
    const gpa = std.testing.allocator;

    const source =
        \\public class Demo {
        \\  public enum HttpVerb {
        \\    GET,
        \\    POST,
        \\    PATCH;
        \\  }
        \\  public interface Worker {
        \\    void run();
        \\  }
        \\  public static void use() {
        \\    HttpVerb verb = HttpVerb.GET;
        \\  }
        \\}
    ;
    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static enum HttpVerb { GET, POST, PATCH }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public static interface Worker {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public void run();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "HttpVerb verb = HttpVerb.GET;") != null);
}

test "renderJavaClass emits inner class with field-only body" {
    const gpa = std.testing.allocator;

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "private static class Inner") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.java, "public Boolean enabled = true;") != null);
}

test "run transpiles file with field-only inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{root};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "run transpiles direct file input with field-only inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Direct.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Direct.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "run transpiles package-private top-level class with inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Demo.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "rewriteKnownCompatibilityFixups preserves unit of work registration state" {
    const gpa = std.testing.allocator;
    const input =
        \\private List<String> m_commitWorkEventsFired = new ArrayList<String>();
        \\private Set<Schema.SObjectType> m_registeredTypes = new LinkedHashSet<Schema.SObjectType>();
        \\if (m_registeredTypes.contains(sObjectType)) {
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "private List<String> m_commitWorkEventsFired;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "private Set<Schema.SObjectType> m_registeredTypes;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (m_registeredTypes == null) m_registeredTypes = new LinkedHashSet<Schema.SObjectType>();") != null);
}

test "rewriteKnownCompatibilityFixups rewrites custom schema and page namespace access" {
    const gpa = std.testing.allocator;
    const input =
        \\String settingsName = Schema.SObjectType.Addr_Verification_Settings__c.getLabel();
        \\PageReference pageRef = Page.STG_PanelAddrVerification;
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"Addr_Verification_Settings__c\").getLabel()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new PageReference(\"/apex/STG_PanelAddrVerification\")") != null);
}

test "rewriteKnownCompatibilityFixups rewrites getAs boolean inequality and record type map declarations" {
    const gpa = std.testing.allocator;
    const input =
        \\Map<String, ApexSObject> recordTypes = objectType.getDescribe().getRecordTypeInfosById();
        \\if (contactRecord.getAs("npe01__Private__c") != true) {
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    const rewrote_record_type_map =
        std.mem.indexOf(u8, rewritten, "Map<String, apexemu.runtime.RecordTypeInfo> recordTypes = objectType.getDescribe().getRecordTypeInfosById();") != null or
        std.mem.indexOf(u8, rewritten, "Map<String, ApexSObject> recordTypes = objectType.getDescribe().getRecordTypeInfosById();") == null;
    try std.testing.expect(rewrote_record_type_map);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "!Boolean.TRUE.equals(contactRecord.getAs(\"npe01__Private__c\"))") != null);
}

test "rewriteKnownCompatibilityFixups rewrites boolean getAs in return and logical contexts" {
    const gpa = std.testing.allocator;
    const input =
        \\public Boolean isDefault() {
        \\  return address.getAs("Default_Address__c");
        \\}
        \\public Boolean shouldProcess(List<ApexSObject> listBatch) {
        \\  return listBatch.size() > 0 && listBatch.get(0).getAs("GiftBatch__c");
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return Boolean.TRUE.equals(address.getAs(\"Default_Address__c\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "listBatch.size() > 0 && Boolean.TRUE.equals(listBatch.get(0).getAs(\"GiftBatch__c\"))") != null);
}

test "rewriteKnownCompatibilityFixups does not rewrite string getAs return values as booleans" {
    const gpa = std.testing.allocator;
    const input =
        \\public String householdAccountId() {
        \\  return address.getAs("Household_Account__c");
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return address.getAs(\"Household_Account__c\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean.TRUE.equals(address.getAs(\"Household_Account__c\"))") == null);
}

test "rewriteKnownCompatibilityFixups rewrites type path getAs and keySet property access" {
    const gpa = std.testing.allocator;
    const input =
        \\TDTM_ProcessControl.setRecursionFlag(TDTM_ProcessControl.flag.getAs("ADDR_hasRunValidation"), true);
        \\if (STG_Panel.stgService.stgErr.getAs("DisableRecordDataHealthChecks__c") == true) {}
        \\List<ApexSObject> jobs = Database.queryWithBinds("SELECT Id FROM CronTrigger WHERE CronJobDetail.Name IN :UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet", ApexCollections.bindMap("UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet", UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet));
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "TDTM_ProcessControl.flag.ADDR_hasRunValidation") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "STG_Panel.stgService.stgErr.getAs(\"DisableRecordDataHealthChecks__c\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "UTIL_MasterSchedulableHelper.defaultScheduledJobs.keySet()") != null);
}

test "rewriteKnownCompatibilityFixups rewrites report fallbacks and datetime double deltas" {
    const gpa = std.testing.allocator;
    const input =
        \\Double msec = dtEnd.getTime() - dtStart.getTime();
        \\List<Report> listRpt = Database.query("SELECT Id FROM Report");
        \\Report r = new Report();
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Double msec = Double.valueOf(dtEnd.getTime() - dtStart.getTime());") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "List<ApexSObject> listRpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSObject r = ApexSObject.of(\"Report\");") != null);
}

test "rewriteQuerySingletonAssignmentsToDeclaredListVars unwraps declared list query singleton without semicolon" {
    const gpa = std.testing.allocator;
    const input =
        \\public void run() {
        \\  List<ApexSObject> allocs = ApexCollections.firstOrThrow(Database.query(getAllocationsQuery(opportunityId).build()))
        \\}
    ;

    const rewritten = try rewriteQuerySingletonAssignmentsToDeclaredListVars(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "List<ApexSObject> allocs = Database.query(getAllocationsQuery(opportunityId).build());") != null);
}

test "rewriteDeclaredSObjectQueryAssignments wraps direct query assignment for declared sobject vars" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Demo {
        \\public void run() {
        \\ApexSObject acc = null;
        \\acc = Database.queryWithBinds("SELECT Id FROM Account WHERE Id = :accId", ApexCollections.bindMap("accId", accId));
        \\}
        \\}
    ;

    const rewritten = try rewriteDeclaredSObjectQueryAssignments(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "acc = ApexCollections.firstOrNull(Database.queryWithBinds(\"SELECT Id FROM Account WHERE Id = :accId\", ApexCollections.bindMap(\"accId\", accId)));") != null);
}

test "rewriteDeclaredSObjectQueryAssignments respects method-local list names" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Demo {
        \\public static void listMethod() {
        \\List<ApexSObject> queryAffl = Database.queryWithBinds("SELECT Id FROM Account", ApexCollections.bindMap());
        \\}
        \\public static void objectMethod() {
        \\ApexSObject queryAffl = null;
        \\queryAffl = Database.queryWithBinds("SELECT Id FROM Account LIMIT 1", ApexCollections.bindMap());
        \\}
        \\}
    ;

    const rewritten = try rewriteDeclaredSObjectQueryAssignments(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "List<ApexSObject> queryAffl = Database.queryWithBinds(\"SELECT Id FROM Account\", ApexCollections.bindMap());") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "queryAffl = ApexCollections.firstOrNull(Database.queryWithBinds(\"SELECT Id FROM Account LIMIT 1\", ApexCollections.bindMap()));") != null);
}

test "rewriteTrailingDatabaseQueryAssignmentParens normalizes missing semicolons and extra parens" {
    const gpa = std.testing.allocator;
    const input =
        \\List<ApexSObject> allocs = Database.query(getAllocationsQuery(opportunityId).build())
        \\parentRecsInitial = Database.query( "SELECT " + flist + " FROM " + parentObjName + " WHERE id IN : parentRecIds"))
    ;

    const rewritten = try rewriteTrailingDatabaseQueryAssignmentParens(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "List<ApexSObject> allocs = Database.query(getAllocationsQuery(opportunityId).build());") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "parentRecsInitial = Database.query( \"SELECT \" + flist + \" FROM \" + parentObjName + \" WHERE id IN : parentRecIds\");") != null);
}

test "rewriteListMethodQuerySingletonReturns unwraps query singleton returns inside list methods" {
    const gpa = std.testing.allocator;
    const input =
        \\public List<ApexSObject> getSObjectsById(List<String> ids) {
        \\  return ApexCollections.firstOrNull(Database.query(queryString));
        \\}
    ;

    const rewritten = try rewriteListMethodQuerySingletonReturns(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return Database.query(queryString);") != null);
}

test "rewriteValuesMethodCollectionViews wraps values calls in array list views" {
    const gpa = std.testing.allocator;
    const input =
        \\ApexSObject oldAccount = (oldMap.values() != null ? (ApexSObject) oldMap.values().get(i) : null);
        \\return mappingService.objectMappingByDevName.values();
    ;

    const rewritten = try rewriteValuesMethodCollectionViews(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new ArrayList<>(oldMap.values()).get(i)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return new ArrayList<>(mappingService.objectMappingByDevName.values());") != null);
}

test "rewriteGetAsStringMethodCalls wraps string-like methods on getAs calls" {
    const gpa = std.testing.allocator;
    const input =
        \\Integer ich = addr.getAs("MailingStreet__c").indexOf("\\n");
        \\ApexSwitch.set(addr, "MailingStreet2__c", addr.getAs("MailingStreet__c").substring(ich+1));
        \\if (recurringDonation.getAs("npe03__Installment_Period__c").isAlpha()) {}
        \\item.operation = rlp.getAs("Operation__c").replace("_", " ");
        \\String recordId = error.getAs("Record_URL__c").substringAfterLast("/");
        \\String partial = item.getAs("DeveloperName").substringBeforeLast("_");
    ;

    const rewritten = try rewriteGetAsStringMethodCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.valueOf(addr.getAs(\"MailingStreet__c\")).indexOf(\"\\\\n\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.valueOf(addr.getAs(\"MailingStreet__c\")).substring(ich+1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.isAlpha(recurringDonation.getAs(\"npe03__Installment_Period__c\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.valueOf(rlp.getAs(\"Operation__c\")).replace(\"_\", \" \")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.substringAfterLast(error.getAs(\"Record_URL__c\"), \"/\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.substringBeforeLast(item.getAs(\"DeveloperName\"), \"_\")") != null);
}

test "rewriteGetAsStringConcatenationCompatibility wraps string-like getAs concatenations" {
    const gpa = std.testing.allocator;
    const input =
        \\contacts.add(ApexSObject.of("Contact").set("LastName", acc.getAs("Name") + i).set("AccountId", acc.getAs("Id")));
        \\this.AddressBlob = Blob.valueOf(c.getAs("MailingStreet") + c.getAs("MailingCity") + c.getAs("MailingState") + c.getAs("MailingPostalCode") + c.getAs("MailingCountry"));
        \\ApexSwitch.set(rd, "npe03__Amount__c", oldRd.getAs("npe03__Amount__c") + 1);
    ;

    const rewritten = try rewriteGetAsStringConcatenationCompatibility(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.valueOf(acc.getAs(\"Name\")) + i") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Blob.valueOf(ApexStrings.valueOf(c.getAs(\"MailingStreet\")) + ApexStrings.valueOf(c.getAs(\"MailingCity\")) + ApexStrings.valueOf(c.getAs(\"MailingState\")) + ApexStrings.valueOf(c.getAs(\"MailingPostalCode\")) + ApexStrings.valueOf(c.getAs(\"MailingCountry\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "oldRd.getAs(\"npe03__Amount__c\") + 1") != null);
}

test "rewriteOverloadedStringIdCallArgs wraps getAs Id arguments for overloaded methods" {
    const gpa = std.testing.allocator;
    const input =
        \\ApexSObject rd = getRecurringDonationBuilder(contact.getAs("Id")).build();
        \\builder.withContact(contact.getAs("Id"));
        \\builder.withAccount(other.getAs("id"));
        \\builder.withContact(recurringDonation.getAs("npe03__Contact__c"));
        \\builder.withAccount(recurringDonation.getAs("npe03__Organization__c"));
        \\return withContact(con.getAs("Id"));
        \\return withAccount(acc.getAs("Id"));
        \\List<ApexSObject> roles = getOppContactRoles(opp.getAs("id"));
        \\List<ApexSObject> contacts = getContacts(con.getAs("id"));
        \\List<ApexSObject> ocrs = getOCRs(opp.getAs("Id"));
        \\Map<String, List<Schedule>> schedulesByRd = retrieveSchedulesUsingApi(rd.getAs("Id"));
    ;

    const rewritten = try rewriteOverloadedStringIdCallArgs(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "getRecurringDonationBuilder(ApexStrings.valueOf(contact.getAs(\"Id\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".withContact(ApexStrings.valueOf(contact.getAs(\"Id\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".withAccount(ApexStrings.valueOf(other.getAs(\"id\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".withContact(ApexStrings.valueOf(recurringDonation.getAs(\"npe03__Contact__c\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".withAccount(ApexStrings.valueOf(recurringDonation.getAs(\"npe03__Organization__c\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return withContact(ApexStrings.valueOf(con.getAs(\"Id\")));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return withAccount(ApexStrings.valueOf(acc.getAs(\"Id\")));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "getOppContactRoles(ApexStrings.valueOf(opp.getAs(\"id\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "getContacts(ApexStrings.valueOf(con.getAs(\"id\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "getOCRs(ApexStrings.valueOf(opp.getAs(\"Id\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "retrieveSchedulesUsingApi(ApexStrings.valueOf(rd.getAs(\"Id\")))") != null);
}

test "rewriteSchemaFieldNamespaceGetAsMethodCalls casts field namespace getAs receivers" {
    const gpa = std.testing.allocator;
    const input =
        \\SystemAssert.assertEquals(false, new Schema.SObjectType("DataImportBatch__c").fields .getAs("Batch_Number__c").isAccessible(), "no access");
    ;

    const rewritten = try rewriteSchemaFieldNamespaceGetAsMethodCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "((Schema.SObjectField) new Schema.SObjectType(\"DataImportBatch__c\").fields.getAs(\"Batch_Number__c\")).isAccessible()") != null);
}

test "rewriteSchemaFieldNamespaceGetAsMethodCalls rewrites extra field helper methods" {
    const gpa = std.testing.allocator;
    const input =
        \\if (!Schema.SObjectType.Contact.fields.getAs("Name").isEncrypted()) {}
        \\field = new Schema.SObjectType("Allocation__c").fields.getAs("Id").getSObjectField();
        \\label = new Schema.SObjectType("DataImport__c").fields.getAs("PaymentImported__c").getLabel();
    ;

    const rewritten = try rewriteSchemaFieldNamespaceGetAsMethodCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "((Schema.SObjectField) Schema.SObjectType.Contact.fields.getAs(\"Name\")).isEncrypted()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "((Schema.SObjectField) new Schema.SObjectType(\"Allocation__c\").fields.getAs(\"Id\")).getSObjectField()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "((Schema.SObjectField) new Schema.SObjectType(\"DataImport__c\").fields.getAs(\"PaymentImported__c\")).getLabel()") != null);
}

test "rewriteDescribeGetAsAliases normalizes name and label lookups" {
    const gpa = std.testing.allocator;
    const input =
        \\String objectName = lookupDFR.getReferenceTo().get(0).getDescribe().getAs("name");
        \\String objectLabel = token.getDescribe().getAs("label");
    ;

    const rewritten = try rewriteDescribeGetAsAliases(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".getDescribe().getName()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".getDescribe().getLabel()") != null);
}

test "rewriteQueryWithBindsListChaining casts chained list accessors" {
    const gpa = std.testing.allocator;
    const input =
        \\return !Database.queryWithBinds("SELECT Id FROM Trigger_Handler__c", ApexCollections.bindMap()).isEmpty();
        \\Object row = Database.queryWithBinds("SELECT Id FROM Account LIMIT 1", ApexCollections.bindMap()).get(0);
    ;

    const rewritten = try rewriteQueryWithBindsListChaining(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "!((List<ApexSObject>) Database.queryWithBinds(\"SELECT Id FROM Trigger_Handler__c\", ApexCollections.bindMap())).isEmpty()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "((List<ApexSObject>) Database.queryWithBinds(\"SELECT Id FROM Account LIMIT 1\", ApexCollections.bindMap())).get(0)") != null);
}

test "rewriteDatabaseDeleteQueryCalls wraps query arguments with list cast" {
    const gpa = std.testing.allocator;
    const input =
        \\Database.delete(Database.query("SELECT Id FROM Account"));
        \\Database.delete(Database.queryWithBinds("SELECT Id FROM Opportunity WHERE Id = :oppId", ApexCollections.bindMap("oppId", oppId)));
        \\Database.delete(Database.queryWithBinds("SELECT Id FROM Task WHERE Id = :taskId", ApexCollections.bindMap("taskId", taskId)), false);
    ;

    const rewritten = try rewriteDatabaseDeleteQueryCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Database.delete(((java.util.List<ApexSObject>) Database.query(\"SELECT Id FROM Account\")));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Database.delete(((java.util.List<ApexSObject>) Database.queryWithBinds(\"SELECT Id FROM Opportunity WHERE Id = :oppId\", ApexCollections.bindMap(\"oppId\", oppId))));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Database.delete(((java.util.List<ApexSObject>) Database.queryWithBinds(\"SELECT Id FROM Task WHERE Id = :taskId\", ApexCollections.bindMap(\"taskId\", taskId))), false);") != null);
}

test "rewriteSystemTypeClassLiteralAssignments rewrites class literals assigned to System.Type" {
    const gpa = std.testing.allocator;
    const input =
        \\public apexemu.runtime.System.Type classType = RelationshipSelector.class;
        \\apexemu.runtime.System.Type handlerClass = null;
        \\handlerClass = CRLP_RollupSoftCredit_SVC.class;
        \\fflib_AppBindingsSelector.SELECTOR_IMPL_TYPE = AppBindingsSelectorMock.class;
        \\String className = CRLP_RollupSoftCredit_SVC.class.getName();
    ;

    const rewritten = try rewriteSystemTypeClassLiteralAssignments(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "classType = apexemu.runtime.System.Type.forName(\"RelationshipSelector\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "handlerClass = apexemu.runtime.System.Type.forName(\"CRLP_RollupSoftCredit_SVC\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "SELECTOR_IMPL_TYPE = apexemu.runtime.System.Type.forName(\"AppBindingsSelectorMock\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "class.getName()") != null);
}

test "rewriteCollectionGenericInstanceof rewrites parameterized list and set checks" {
    const gpa = std.testing.allocator;
    const input =
        \\if (value instanceof Set<Id>) {}
        \\if (value instanceof Set<String>) {}
        \\if (value instanceof List<ApexSObject>) {}
    ;

    const rewritten = try rewriteCollectionGenericInstanceof(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "instanceof Set<?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "instanceof List<?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "instanceof Set<Id>") == null);
}

test "rewriteBrokenApexEqualsTernaryComparisons repairs malformed eq ternary calls" {
    const gpa = std.testing.allocator;
    const input =
        \\return ApexEquals.eq(result.size(), 1 ? result.get(0) : fallback);
    ;

    const rewritten = try rewriteBrokenApexEqualsTernaryComparisons(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "(ApexEquals.eq(result.size(), 1) ? result.get(0) : fallback)") != null);
}

test "rewriteFirstOrNullScalarWrappers unwraps scalar getAs arguments" {
    const gpa = std.testing.allocator;
    const input =
        \\String id = ApexCollections.firstOrNull(ApexCollections.firstOrThrow(Database.query("SELECT Id FROM Account")).getAs("Id"));
    ;

    const rewritten = try rewriteFirstOrNullScalarWrappers(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "String id = ApexCollections.firstOrThrow(Database.query(\"SELECT Id FROM Account\")).getAs(\"Id\");") != null);
}

test "rewriteNestedIdApexSwitchGetAs unwraps nested id getAs artifacts" {
    const gpa = std.testing.allocator;
    const input =
        \\String id = ApexSwitch.getAs(opp.getAs("Id"), "Name");
    ;

    const rewritten = try rewriteNestedIdApexSwitchGetAs(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "String id = opp.getAs(\"Id\");") != null);
}

test "rewriteStringCastBooleanEqualsArtifacts removes boolean equals wrappers inside string casts" {
    const gpa = std.testing.allocator;
    const input =
        \\if (ApexEquals.ne((String)newOpp.get("recordTypeId"), (String)Boolean.TRUE.equals(oldOpp.get("recordTypeId")))) {}
    ;

    const rewritten = try rewriteStringCastBooleanEqualsArtifacts(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "(String) oldOpp.get(\"recordTypeId\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean.TRUE.equals(oldOpp.get(\"recordTypeId\"))") == null);
}

test "rewriteValueOfGetNameArtifacts removes getName chained on valueOf" {
    const gpa = std.testing.allocator;
    const input =
        \\String fieldName = ApexStrings.valueOf(new Schema.SObjectType("Contact").fields.getAs("AccountId")).getName();
    ;

    const rewritten = try rewriteValueOfGetNameArtifacts(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "String fieldName = ApexStrings.valueOf(new Schema.SObjectType(\"Contact\").fields.getAs(\"AccountId\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".getName()") == null);
}

test "rewriteLinewiseRelationalComparisons rewrites date and datetime relational operators" {
    const gpa = std.testing.allocator;
    const input =
        \\if (closeDate < nextDate) { return -1; }
        \\if (dt >= currData.effectiveDates.get(n)) { return currData.rates.get(n); }
    ;

    const rewritten = try rewriteLinewiseRelationalComparisons(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexCompare.lt(closeDate, nextDate)") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, rewritten, "ApexCompare.gte(dt, currData.effectiveDates.get(n))") != null or
            std.mem.indexOf(u8, rewritten, "dt >= currData.effectiveDates.get(n)") != null,
    );
}

test "rewriteRecordTypeInfoUsages rewrites helper maps and derived variables" {
    const gpa = std.testing.allocator;
    const input =
        \\Map<String, ApexSObject> recordTypeInfos = getAssignedRecordTypes(objectType);
        \\for (apexemu.runtime.RecordTypeInfo rt : new ArrayList<>(recordTypeInfos.values())) {
        \\  options.add(new SelectOption(rt.getAs("Name"), rt.getAs("Name")));
        \\}
        \\Map<String, apexemu.runtime.RecordTypeInfo> byName = objectType.getDescribe().getRecordTypeInfosByName();
        \\ApexSObject selected = byName.get(recordTypeName);
        \\Map<String, ApexSObject> objectRecordTypeInfos = ApexCollections.toIdMap(byName);
    ;

    const rewritten = try rewriteRecordTypeInfoUsages(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Map<String, apexemu.runtime.RecordTypeInfo> recordTypeInfos = getAssignedRecordTypes(objectType);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSObject selected = byName.get(recordTypeName);") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "apexemu.runtime.RecordTypeInfo selected = byName.get(recordTypeName);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new LinkedHashMap<>(byName)") != null);
}

test "rewriteEnhancedForCompareArtifacts restores generic enhanced for headers" {
    const gpa = std.testing.allocator;
    const input =
        \\for (ApexStrings.compareTo(List<Id, chunk : dummyGiftBatchForProcessing.chunkedIds) > 0) {
    ;

    const rewritten = try rewriteEnhancedForCompareArtifacts(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "for (List<Id> chunk : dummyGiftBatchForProcessing.chunkedIds) {") != null);
}

test "rewriteSObjectTypeVariableGetAsAccess rewrites namespace-like variable access" {
    const gpa = std.testing.allocator;
    const input =
        \\if (!sObjectType.getAs("Contact").fields.getAs("Name").isEncrypted()) {}
    ;

    const rewritten = try rewriteSObjectTypeVariableGetAsAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Schema.SObjectType.Contact.fields.getAs(\"Name\").isEncrypted()") != null);
}

test "rewriteTypePathGetAsAccess skips field namespace getAs calls" {
    const gpa = std.testing.allocator;
    const input =
        \\Object value = DataImport__c.fields.getAs("Payment_Status__c");
    ;

    const rewritten = try rewriteTypePathGetAsAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "DataImport__c.fields.getAs(\"Payment_Status__c\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "DataImport__c.fields.Payment_Status__c") == null);
}

test "rewriteGetAsDateMethodCalls wraps date-like chained calls" {
    const gpa = std.testing.allocator;
    const input =
        \\record.getAs("CloseDate").addDays(2);
        \\Integer days = record.getAs("CloseDate").daysBetween(otherDate);
    ;

    const rewritten = try rewriteGetAsDateMethodCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Date.valueOf(record.getAs(\"CloseDate\")).addDays(2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Date.valueOf(record.getAs(\"CloseDate\")).daysBetween(otherDate)") != null);
}

test "rewriteApexStringsValueOfDateGetAs unwraps date getAs valueOf wrappers" {
    const gpa = std.testing.allocator;
    const input =
        \\recordByCloseDate.put(ApexStrings.valueOf(opp.getAs("CloseDate")), new Record(opp));
        \\boundaryRecordByCloseDate.put(ApexStrings.valueOf(opp.getAs("CloseDate")), new Record(opp));
        \\String timestamp = ApexStrings.valueOf(opp.getAs("LastModifiedDate"));
    ;

    const rewritten = try rewriteApexStringsValueOfDateGetAs(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "recordByCloseDate.put(opp.getAs(\"CloseDate\"), new Record(opp));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "boundaryRecordByCloseDate.put(opp.getAs(\"CloseDate\"), new Record(opp));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.valueOf(opp.getAs(\"LastModifiedDate\"))") != null);
}

test "rewriteApexPagesNestedTypeAliases normalizes lowercase nested types" {
    const gpa = std.testing.allocator;
    const input =
        \\ApexPages.addmessage(new ApexPages.message(ApexPages.severity.Error, msg));
        \\ApexPages.CurrentPage().getParameters();
        \\ApexPages.Standardsetcontroller c = null;
        \\ApexPages.Standardcontroller d = null;
        \\ApexPages.PageReference p = null;
    ;

    const rewritten = try rewriteApexPagesNestedTypeAliases(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.Error, msg))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexPages.currentPage().getParameters()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexPages.StandardSetController c = null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexPages.StandardController d = null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "PageReference p = null;") != null);
}

test "rewriteBareCustomSObjectTypeArgCalls wraps custom object tokens" {
    const gpa = std.testing.allocator;
    const input =
        \\utilPerm.canRead(ApexSwitch.getSObjectType(npe01__OppPayment__c), paymentFields);
    ;

    const rewritten = try rewriteBareCustomSObjectTypeArgCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.getSObjectType(new Schema.SObjectType(\"npe01__OppPayment__c\"))") != null);
}

test "rewriteBareCustomSObjectTypeAccess wraps bare custom field namespace bases" {
    const gpa = std.testing.allocator;
    const input =
        \\Object key = DataImport__c.fields;
    ;

    const rewritten = try rewriteBareCustomSObjectTypeAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"DataImport__c\").fields") != null);
}

test "rewriteFieldDisplayTypeCalls rewrites display type helpers via describe" {
    const gpa = std.testing.allocator;
    const input =
        \\Schema.DisplayType dt = UTIL_Describe.getFieldDisplaytype("Opportunity", fieldName);
    ;

    const rewritten = try rewriteFieldDisplayTypeCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "UTIL_Describe.getFieldDescribe(\"Opportunity\", fieldName).getType()") != null);
}

test "rewriteBareSchemaEnumConstantAccess qualifies bare Schema enum constants" {
    const gpa = std.testing.allocator;
    const input =
        \\if (ApexEquals.ne(fld.getType(), DisplayType.TIME) && ApexEquals.eq(soapType, SoapType.DateTime)) {}
        \\if (ApexEquals.eq(fld.getType(), Schema.DisplayType.PICKLIST)) {}
    ;

    const rewritten = try rewriteBareSchemaEnumConstantAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Schema.DisplayType.TIME") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Schema.SoapType.DateTime") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Schema.DisplayType.PICKLIST") != null);
}

test "rewriteDynamicFieldNameGetCalls wraps dynamic name field selectors" {
    const gpa = std.testing.allocator;
    const input =
        \\Object value = row.get(ApexSwitch.getAs(new Schema.SObjectType("DataImport__c").fields.getAs("DonationImported__c"), "Name"));
    ;

    const rewritten = try rewriteDynamicFieldNameGetCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "row.get(ApexStrings.valueOf(ApexSwitch.getAs(new Schema.SObjectType(\"DataImport__c\").fields.getAs(\"DonationImported__c\"), \"Name\")))") != null);
}

test "rewriteGetAsMutationAssignments rewrites statement assignment safely" {
    const gpa = std.testing.allocator;
    const input =
        \\// TODO(apex): method body is copied as comments and needs manual porting.
        \\STG_Panel.stgService.stgHH.getAs("npo02__Advanced_Household_Naming__c") = false;
        \\STG_Panel.stgService.stgHH.getAs("npo02__Soft_Credit_Roles__c") = "Decision Maker;Something Else";
    ;

    const rewritten = try rewriteGetAsMutationAssignments(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "needs manual porting.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.set(STG_Panel.stgService.stgHH, \"npo02__Advanced_Household_Naming__c\", false);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.set(STG_Panel.stgService.stgHH, \"npo02__Soft_Credit_Roles__c\", \"Decision Maker;Something Else\");") != null);
}

test "rewriteGetAsMutationAssignments rewrites post increment and decrement statements" {
    const gpa = std.testing.allocator;
    const input =
        \\counter.getAs("Count__c")++;
        \\counter.getAs("Count__c")--;
    ;

    const rewritten = try rewriteGetAsMutationAssignments(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.set(counter, \"Count__c\", ApexStrings.toInteger(counter.getAs(\"Count__c\")) + 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.set(counter, \"Count__c\", ApexStrings.toInteger(counter.getAs(\"Count__c\")) - 1);") != null);
}

test "rewriteCaseInsensitiveIdentifierVariants normalizes lowercase-leading identifier casing variants" {
    const gpa = std.testing.allocator;
    const input =
        \\for (String fieldName : contactFields.keySet()) {
        \\  if (!isNPSPHiddenField(fieldname)) {}
        \\}
        \\Map<String, ApexSObject> hh2account = new LinkedHashMap<>();
        \\hh2Account.put("001", acc);
    ;

    const rewritten = try rewriteCaseInsensitiveIdentifierVariants(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "isNPSPHiddenField(fieldName)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "hh2Account = new LinkedHashMap<>()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "hh2Account.put(\"001\", acc);") != null);
}

test "rewriteCaseInsensitiveIdentifierVariants skips import and package lines" {
    const gpa = std.testing.allocator;
    const input =
        \\package generated;
        \\import java.util.regex.Pattern;
        \\import java.util.regEx.Matcher;
        \\public class Demo {
        \\  public void run() {
        \\    Integer fieldname = 1;
        \\    Integer fieldName = fieldname + 1;
        \\  }
        \\}
    ;

    const rewritten = try rewriteCaseInsensitiveIdentifierVariants(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "import java.util.regex.Pattern;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "import java.util.regEx.Matcher;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Integer fieldName = 1;") != null);
}

test "rewriteCustomSObjectMemberAccess rewrites custom field dot lookups and assignments" {
    const gpa = std.testing.allocator;
    const input =
        \\SystemAssert.assertEquals(100, UpdatedCon.npo02__TotalOppAmount__c);
        \\SystemAssert.assertEquals("x", UpdatedCon.npo02__Household__r.id);
        \\CRLP_DefaultConfigBuilder.legacySettings.npo02__Soft_Credit_Roles__c = "A;B";
    ;

    const rewritten = try rewriteCustomSObjectMemberAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "SystemAssert.assertEquals(100, ApexSwitch.getAs(UpdatedCon, \"npo02__TotalOppAmount__c\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "SystemAssert.assertEquals(\"x\", ApexSwitch.getAs(ApexSwitch.getAs(UpdatedCon, \"npo02__Household__r\"), \"id\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.set(CRLP_DefaultConfigBuilder.legacySettings, \"npo02__Soft_Credit_Roles__c\", \"A;B\");") != null);
}

test "rewriteKnownSObjectBooleanPropertyAccess rewrites direct sobject boolean fields" {
    const gpa = std.testing.allocator;
    const input =
        \\SystemAssert.assertEquals(true, opps.get(0).isWon);
        \\SystemAssert.assertEquals(true, ocrs.get(0).isPrimary);
        \\ocr.isPrimary = false;
    ;

    const rewritten = try rewriteKnownSObjectBooleanPropertyAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "opps.get(0).getAs(\"isWon\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ocrs.get(0).getAs(\"isPrimary\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.set(ocr, \"isPrimary\", false);") != null);
}

test "rewriteKnownSObjectBooleanPropertyAccess rewrites common standard sobject fields" {
    const gpa = std.testing.allocator;
    const input =
        \\if (opp.amount > 0) {}
        \\ApexSwitch.set(pay, "Date__c", opp.closeDate);
    ;

    const rewritten = try rewriteKnownSObjectBooleanPropertyAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "opp.getAs(\"Amount\") > 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSwitch.set(pay, \"Date__c\", opp.getAs(\"CloseDate\"));") != null);
}

test "rewriteBooleanGetOperands rewrites get comparisons and logical operands" {
    const gpa = std.testing.allocator;
    const input =
        \\return targetObject.get(new Schema.SObjectField("npe01__OppPayment__c", "npe01__Paid__c")) == true;
        \\if (numberOfCopiedFields > 0 || payment.getAs("npe01__Paid__c")) {}
        \\if (alloSettings.getAs("Default_Allocations_Enabled__c") && ready) {}
        \\if (!payment.getAs("npe01__Paid__c")) {}
        \\if (!settings.getAs("Reject_Ambiguous_Addresses__c")) {}
        \\Boolean ignoreAmbiguous = settings.getAs("Reject_Ambiguous_Addresses__c") == true;
        \\if (npe01Settings.get(setting) == true) {}
        \\if (settings.getAs("Reject_Ambiguous_Addresses__c") != false) {}
        \\if (acc != null && acc.getAs("MasterRecordId") != null) {}
        \\if (amount >= settings.getAs("Minimum_Amount__c") || settings.getAs("Minimum_Amount__c") == null) {}
    ;

    const rewritten = try rewriteBooleanGetOperands(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "|| Boolean.TRUE.equals(payment.getAs(\"npe01__Paid__c\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean.TRUE.equals(alloSettings.getAs(\"Default_Allocations_Enabled__c\")) &&") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "!Boolean.TRUE.equals(payment.getAs(\"npe01__Paid__c\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "!Boolean.TRUE.equals(settings.getAs(\"Reject_Ambiguous_Addresses__c\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean ignoreAmbiguous = Boolean.TRUE.equals(settings.getAs(\"Reject_Ambiguous_Addresses__c\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (Boolean.TRUE.equals(npe01Settings.get(setting))) {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (!Boolean.FALSE.equals(settings.getAs(\"Reject_Ambiguous_Addresses__c\"))) {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (acc != null && acc.getAs(\"MasterRecordId\") != null) {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (amount >= settings.getAs(\"Minimum_Amount__c\") || settings.getAs(\"Minimum_Amount__c\") == null) {}") != null);
}

test "rewriteBooleanEqualsComparisonArtifacts unwraps non-boolean comparisons" {
    const gpa = std.testing.allocator;
    const input =
        \\if (Boolean.TRUE.equals(acc.getAs("MasterRecordId")) != null) {}
        \\if (con.getAs("Id") == Boolean.TRUE.equals(listCon.get(2).getAs("Id"))) {}
        \\if (Boolean.TRUE.equals(flag.getAs("isClosed")) == true) {}
    ;

    const rewritten = try rewriteBooleanEqualsComparisonArtifacts(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (acc.getAs(\"MasterRecordId\") != null) {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (con.getAs(\"Id\") == listCon.get(2).getAs(\"Id\")) {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean.TRUE.equals(flag.getAs(\"isClosed\")) == true") != null);
}

test "rewritePrivateStaticNestedTestClasses promotes nested private static test helpers" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Demo_TEST {
        \\  private static class MockService implements apexemu.runtime.System.StubProvider {
        \\  }
        \\}
    ;

    const rewritten = try rewritePrivateStaticNestedTestClasses(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static class MockService") != null);
}

test "rewriteDescribeGetAsAliases rewrites describe field namespace aliases" {
    const gpa = std.testing.allocator;
    const input =
        \\Map<String, Schema.SObjectField> fields = obj.getDescribe().getAs("Fields").getMap();
        \\Map<String, Schema.FieldSet> fieldSets = obj.getDescribe().getAs("fieldsets").getMap();
    ;

    const rewritten = try rewriteDescribeGetAsAliases(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "obj.getDescribe().fields.getMap()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "obj.getDescribe().fieldSets.getMap()") != null);
}

test "rewriteGetAsEnumNameCalls converts enum name access to string value" {
    const gpa = std.testing.allocator;
    const input =
        \\String status = deployResult.getAs("status").name();
    ;

    const rewritten = try rewriteGetAsEnumNameCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.valueOf(deployResult.getAs(\"status\"))") != null);
}

test "rewriteGetAsCollectionAccessors casts collection mutators" {
    const gpa = std.testing.allocator;
    const input =
        \\objectMapping.getAs("Field_Mappings").add(fieldMapping);
    ;

    const rewritten = try rewriteGetAsCollectionAccessors(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "((java.util.List<Object>) objectMapping.getAs(\"Field_Mappings\")).add(fieldMapping)") != null);
}

test "rewriteGetAsCollectionAccessors rewrites numeric and date value accessors" {
    const gpa = std.testing.allocator;
    const input =
        \\Integer n = row.getAs("Position__c").intValue();
        \\Date d = row.getAs("ReminderDateTime").Date();
    ;

    const rewritten = try rewriteGetAsCollectionAccessors(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Integer n = ApexStrings.toInteger(row.getAs(\"Position__c\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Date d = Date.valueOf(row.getAs(\"ReminderDateTime\"));") != null);
}

test "rewriteBrokenInlineMethodAssignmentsInSObjectSet repairs leaked assignments from date arithmetic" {
    const gpa = std.testing.allocator;
    const input =
        \\Database.insert(ApexSObject.of("DataImport__c").set("Donation_Date__c", apexemu.runtime.System.today().addDays(1, Payment_Method__c = "Check", Donation_Donor__c="contact1")));
    ;

    const rewritten = try rewriteBrokenInlineMethodAssignmentsInSObjectSet(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".set(\"Donation_Date__c\", apexemu.runtime.System.today().addDays(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".set(\"Payment_Method__c\", \"Check\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ".set(\"Donation_Donor__c\", \"contact1\")") != null);
}

test "rewriteNegatedSizeEqualityArtifacts removes misplaced negation on size comparisons" {
    const gpa = std.testing.allocator;
    const input =
        \\if (!ApexCollections.size(objectMapping.getAs("Field_Mappings")) == 0) {
        \\}
    ;

    const rewritten = try rewriteNegatedSizeEqualityArtifacts(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexCollections.size(objectMapping.getAs(\"Field_Mappings\")) != 0") != null);
}

test "rewriteIntegerCompareToDoubleReturns normalizes compareTo return literals" {
    const gpa = std.testing.allocator;
    const input =
        \\public Integer compareTo(Object other) {
        \\  if (true) { return 1.0; }
        \\  return -1.0;
        \\}
    ;

    const rewritten = try rewriteIntegerCompareToDoubleReturns(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return -1;") != null);
}

test "rewriteBoxedNumericLiteralCompatibility normalizes boxed numeric literals" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Demo {
        \\  public static Long calc(Integer a, Integer b) {
        \\    Long total = 5;
        \\    total = Math.max(Math.round(100 * a / b), 5);
        \\    return -1;
        \\  }
        \\  public static Integer compare(Object other) {
        \\    if (other == null) { return 1.0; }
        \\    return -1.0;
        \\  }
        \\  public static Double scale(Double amount) {
        \\    if (amount == null) { amount = 0; }
        \\    Double multiplier = (true ? 1 : -1);
        \\    return amount * multiplier;
        \\  }
        \\  public static void run() {
        \\    Double amount = 0, secondary = 1;
        \\    amount = 12;
        \\    req.donationValue = 5;
        \\    Integer nextSortOrder = 0;
        \\    nextSortOrder = ApexStrings.toDouble(campMemberStatuses.get(0).getAs("SortOrder")) + 1;
        \\    SystemAssert.assertTrue(new LinkedHashSet<Double>().contains((Double) 5));
        \\  }
        \\}
    ;

    const rewritten = try rewriteBoxedNumericLiteralCompatibility(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Long total = 5L;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Math.max(Math.round(100 * a / b), 5L)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return -1L;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return -1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (amount == null) { amount = 0.0; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Double amount = 0.0, secondary = 1.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "amount = 12.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "req.donationValue = 5.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "nextSortOrder = ApexStrings.toInteger(ApexStrings.toDouble(campMemberStatuses.get(0).getAs(\"SortOrder\")) + 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "contains((Double) 5.0)") != null);
}

test "rewriteLocalStaticWaitCalls qualifies bare wait helper invocations" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Demo_TEST {
        \\  public static Long wait(Long duration) {
        \\    return duration;
        \\  }
        \\  public static void run() {
        \\    Long delta = wait(1000);
        \\  }
        \\}
    ;

    const rewritten = try rewriteLocalStaticWaitCalls(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static Long waitForDuration(Long duration)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Long delta = Demo_TEST.waitForDuration(Long.valueOf(1000));") != null);
}

test "rewriteEnhancedForGetAsIterables casts query with binds for aggregate results" {
    const gpa = std.testing.allocator;
    const input =
        \\for (AggregateResult result : Database.queryWithBinds("SELECT COUNT(Id) cnt FROM Account GROUP BY Name", ApexCollections.bindMap())) {
        \\}
    ;

    const rewritten = try rewriteEnhancedForGetAsIterables(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "(java.util.List<AggregateResult>) Database.queryWithBinds(") != null);
}

test "rewriteNumericValueOfObjectIdentifiers rewrites object accessors" {
    const gpa = std.testing.allocator;
    const input =
        \\Double duration = Double.valueOf(logs.get(0).get("Parent_Duration__c"));
    ;

    const rewritten = try rewriteNumericValueOfObjectIdentifiers(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.toDouble(logs.get(0).get(\"Parent_Duration__c\"))") != null);
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

test "rewriteNumericValueOfObjectIdentifiers rewrites object valueOf calls" {
    const gpa = std.testing.allocator;
    const input =
        \\public void run() {
        \\  Object fieldValue = record.get(field);
        \\  result.add(Integer.valueOf(fieldValue));
        \\}
    ;

    const rewritten = try rewriteNumericValueOfObjectIdentifiers(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.toInteger(fieldValue)") != null);
}

test "rewriteObjectEqualityWithDeclaredObjects rewrites object numeric equality" {
    const gpa = std.testing.allocator;
    const input =
        \\public void run() {
        \\  Object currentValue = record.get('Count__c');
        \\  if (currentValue != null && currentValue != 0) {
        \\    return currentValue != members.size();
        \\  }
        \\}
    ;

    const rewritten = try rewriteObjectEqualityWithDeclaredObjects(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexEquals.ne(currentValue, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return ApexEquals.ne(currentValue, members.size());") != null);
}

test "rewriteObjectEqualityWithDeclaredObjects skips null guard comparisons" {
    const gpa = std.testing.allocator;
    const input =
        \\public void run() {
        \\  if (diom.getAs("Data_Import_Field_Mappings__r") != null && ApexCollections.size(diom.getAs("Data_Import_Field_Mappings__r")) > 0) {
        \\  }
        \\}
    ;

    const rewritten = try rewriteObjectEqualityWithDeclaredObjects(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexEquals.ne(diom.getAs(\"Data_Import_Field_Mappings__r\"),") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "diom.getAs(\"Data_Import_Field_Mappings__r\") != null &&") != null);
}

test "rewriteKnownCompatibilityFixups rewrites bare sobject types and legacy literal tokens" {
    const gpa = std.testing.allocator;
    const input =
        \\if (record == NULL || enabled == TRUE || disabled == FALSE) {}
        \\String apiName = SObjectType.Allocation__c.getName();
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "record == null || enabled == true || disabled == false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"Allocation__c\")") != null);
}

test "rewriteKnownCompatibilityFixups rewrites NPSP filter and request compatibility fronts" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public static enum FilterOperation { Equals, Not_Equals, Greater, Less, Greater_or_Equal, Less_or_Equal, Starts_With, Contains, Does_Not_Contain, In_List, Not_In_List, Is_Included, Is_Not_Included }
        \\  private static final String recordTypeIdPrefix = SObjectType.RecordType.getKeyPrefix();
        \\  public void run(ApexSObject opp, Map<String, String> elevateFrequencyByInstallmentPeriod, Map<String, Object> scheduleUntyped, String installmentPeriodFieldName, DateTime startDateTime, List<Schema.SObjectField> GIFT_SCHEDULE_FIELDS, Date fieldDateValue, Date compareStartDate, Date compareEndDate, DateTime fieldValue, DateTime compareValue, String fieldText, Object batchItemRequestDTO) {
        \\    if (Boolean.TRUE.equals(ApexSwitch.getAs(opp.getAs("Account"), "npe01__SYSTEMIsIndividual__c")) && Boolean.TRUE.equals(opp.getAs("Primary_Contact__c")) != null) {
        \\    }
        \\    fflib_SecurityUtils.checkRead(new Schema.SObjectType("DataImportBatch__c"), GIFT_SCHEDULE_FIELDS);
        \\    if ((schedule.frequency = elevateFrequencyByInstallmentPeriod) != null) { schedule.frequency = elevateFrequencyByInstallmentPeriod.get(ApexStrings.valueOf(((scheduleUntyped) == null ? null : (scheduleUntyped).get(installmentPeriodFieldName)))); }
        \\    Integer amount = Integer.valueOf((int) (batchItemRequestDTO.amount));
        \\    if (fieldText.startsWithIgnoreCase("abc")) {}
        \\    return fieldValue > compareValue;
        \\    return (fieldDateValue >= compareStartDate && fieldDateValue <= compareEndDate);
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "enum FilterOperation { EQUALS, NOT_EQUALS, GREATER, LESS, GREATER_OR_EQUAL, LESS_OR_EQUAL, STARTS_WITH") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Schema.SObjectType.RecordType.getKeyPrefix()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "checkReadByToken(new Schema.SObjectType(\"DataImportBatch__c\"), GIFT_SCHEDULE_FIELDS)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexStrings.toInteger(batchItemRequestDTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return ApexCompare.gt(fieldValue, compareValue);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return (ApexCompare.gte(fieldDateValue, compareStartDate) && ApexCompare.lte(fieldDateValue, compareEndDate));") != null);
}

test "rewriteKnownCompatibilityFixups normalizes fflib do-throw property default" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public List<apexemu.runtime.System.Exception> DoThrowWhenExceptions = new ArrayList<>(); // Apex property { get; set; }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public List<apexemu.runtime.System.Exception> DoThrowWhenExceptions; // Apex property { get; set; }") != null);
}

test "rewriteKnownCompatibilityFixups rewrites accidental get-getAs call artifacts" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public List<Schema.FieldSetMember> fieldSetMembers = new Schema.FieldSetNamespace("Contact").get("getAs")("ContactMergeFoundFS").getFields();
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.FieldSetNamespace(\"Contact\").get(\"ContactMergeFoundFS\").getFields()") != null);
}

test "rewriteKnownCompatibilityFixups adapts self-interface singleton instance casts" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public static Object instance;
        \\  public static interface Interface_x {
        \\    String value();
        \\  }
        \\  public static Interface_x getInstance() {
        \\    if (instance == null) {
        \\      instance = new Sample();
        \\    }
        \\    return (Interface_x) instance;
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return ApexInterfaceAdapter.adapt(instance, Interface_x.class);") != null);
}

test "rewriteKnownCompatibilityFixups rewrites enum casing and NPSP compile fronts" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public static enum RollupType { Count, Sum, Average, Largest, Smallest, First, Last, Years_Donated, Donor_Streak, Best_Year, Best_Year_Total }
        \\  public static enum TimeBoundOperationType { All_Time, Years_Ago, Days_Back }
        \\  public static enum CMTFieldType { FldText, FldBoolean, FldNumber, FldEntity }
        \\  public void run(CRLP_Operation.RollupType rollupType, CRLP_Operation.TimeBoundOperationType timeBoundOperation, Object mdObject, ApexSObject c, Date targetDate, Date fiscalYearStartDate, String donorType) {
        \\    CRLP_Operation.RollupType a = CRLP_Operation.RollupType.Count;
        \\    CRLP_Operation.TimeBoundOperationType b = CRLP_Operation.TimeBoundOperationType.All_Time;
        \\    if (ApexSwitch.getAs(c.getAs("Owner"), "IsActive") == true) {}
        \\    if (targetDate < fiscalYearStartDate) {}
        \\    if (donorType == new Schema.SObjectField("Contact", "Name")) {}
        \\    String mdTypeName = mdObject.Name();
        \\    String endpoint = Url.getOrgDomainUrl().toExternalForm();
        \\    Double batchGiftEntryVersion = 0;
        \\    Object key = DataImport__c.fields.getAs("Payment_Status__c");
        \\    Schema.SObjectType roleType = Schema.SObjectType.OpportunityContactRole;
        \\    Boolean closed = recurringDonation.getAs("isClosed")();
        \\    if (!Boolean.TRUE.equals(rdRecord.getAs("isClosed"))() && (new RD2_RecurringDonation(oldRd).getAs("isClosed"))) {}
        \\    if (recurringDonation.isElevateRecord() && Boolean.TRUE.equals(recurringDonation.getAs("isClosed"))() && rd.getAs("EndDate__c") > currentDate ) {}
        \\    fflib_SObjectDomain.getTriggerHandler()(apexemu.runtime.System.Type.forName("Example"));
        \\    Boolean odd = ApexEquals.eq(arg instanceof Integer ? ApexMath.mod((Integer)arg, 2), 1: false);
        \\    if (ApexEquals.ne(fld.getType(), DisplayType.TIME) && ApexEquals.eq(fld.getType(), DisplayType.PICKLIST)) {}
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "enum RollupType { COUNT, SUM, AVERAGE, LARGEST, SMALLEST, FIRST, LAST, YEARS_DONATED, DONOR_STREAK, BEST_YEAR, BEST_YEAR_TOTAL }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "enum TimeBoundOperationType { ALL_TIME, YEARS_AGO, DAYS_BACK }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "enum CMTFieldType { FldText, FldBoolean, FldNumber, FldEntity, FldField }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "CRLP_Operation.RollupType.COUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "CRLP_Operation.TimeBoundOperationType.ALL_TIME") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean.TRUE.equals(ApexSwitch.getAs(c.getAs(\"Owner\"), \"IsActive\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (ApexCompare.lt(targetDate, fiscalYearStartDate)) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (ApexEquals.eq(donorType, new Schema.SObjectField(\"Contact\", \"Name\"))) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "mdObject.name()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "URL.getOrgDomainUrl()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Double batchGiftEntryVersion = 0.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"DataImport__c\").fields.getAs(\"Payment_Status__c\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Schema.SObjectType roleType = new Schema.SObjectType(\"OpportunityContactRole\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean closed = Boolean.TRUE.equals(recurringDonation.getAs(\"isClosed\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "!Boolean.TRUE.equals(rdRecord.getAs(\"isClosed\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "RD2_RecurringDonation(oldRd).getAs(\"isClosed\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "&& (new RD2_RecurringDonation(oldRd).getAs(\"isClosed\")))") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexCompare.gt(rd.getAs(\"EndDate__c\"), currentDate)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "fflib_SObjectDomain.getTriggerHandler(apexemu.runtime.System.Type.forName(\"Example\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean odd = (arg instanceof Integer ? ApexEquals.eq(ApexMath.mod((Integer)arg, 2), 1) : false);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexEquals.ne(fld.getType(), Schema.DisplayType.TIME)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexEquals.eq(fld.getType(), Schema.DisplayType.PICKLIST)") != null);
}

test "rewriteKnownCompatibilityFixups initializes OrgConfig and helper service properties" {
    const gpa = std.testing.allocator;
    const input =
        \\public class ContactMergeSelector {
        \\  public static OrgConfig orgConfig; // Apex property { get; set; }
        \\}
        \\public class HouseholdNamingService {
        \\  public ContactSelector contactSelector; // Apex property { get; set; }
        \\  public UnitOfWork unitOfWork; // Apex property { get; set; }
        \\  public AddressService addressService; // Apex property { get; set; }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static OrgConfig orgConfig = new OrgConfig(); // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public ContactSelector contactSelector = new ContactSelector(); // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public UnitOfWork unitOfWork = new UnitOfWork(); // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public AddressService addressService = new AddressService(); // Apex property { get; set; }") != null);
}

test "rewriteLateCompatibilityFixups initializes OrgConfig and helper service properties" {
    const gpa = std.testing.allocator;
    const input =
        \\public class ContactMergeSelector {
        \\  public static OrgConfig orgConfig; // Apex property { get; set; }
        \\}
        \\public class HouseholdNamingService {
        \\  public ContactSelector contactSelector; // Apex property { get; set; }
        \\  public UnitOfWork unitOfWork; // Apex property { get; set; }
        \\  public AddressService addressService; // Apex property { get; set; }
        \\}
    ;

    const rewritten = try rewriteLateCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static OrgConfig orgConfig = new OrgConfig(); // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public ContactSelector contactSelector = new ContactSelector(); // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public UnitOfWork unitOfWork = new UnitOfWork(); // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public AddressService addressService = new AddressService(); // Apex property { get; set; }") != null);
}

test "rewriteKnownCompatibilityFixups makes Addresses contact selector static when initialized" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Addresses {
        \\  public ContactSelector contactSelector = new ContactSelector(); // Apex property { get; set; }
        \\  public static Map<String, List<ApexSObject>> getContactsByHouseholdAccountId(Set<String> accountIds) {
        \\    return contactSelector.getContactAddressFieldsForContactAccountsIn(accountIds);
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static ContactSelector contactSelector = new ContactSelector(); // Apex property { get; set; }") != null);
}

test "rewriteKnownCompatibilityFixups makes HouseholdNamingService naming impl checks null-safe" {
    const gpa = std.testing.allocator;
    const input =
        \\public class HouseholdNamingService {
        \\  public Set<String> getHouseholdNamingContactFields() {
        \\    if (!settings.isAdvancedHouseholdNaming() || householdNamingImpl.setHouseholdNameFieldsOnContact() == null) {
        \\      return new LinkedHashSet<String>();
        \\    }
        \\    return householdNamingImpl.setHouseholdNameFieldsOnContact();
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (!settings.isAdvancedHouseholdNaming() || householdNamingImpl == null || householdNamingImpl.setHouseholdNameFieldsOnContact() == null) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return householdNamingImpl == null ? new LinkedHashSet<String>() : householdNamingImpl.setHouseholdNameFieldsOnContact();") != null);
}

test "rewriteKnownCompatibilityFixups rewrites subselect casing and integer cast wrappers" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public static enum FirstInstallmentOppCreateOptions { Synchronous, Asynchronous, Asynchronous_When_Bulk }
        \\  public void run(fflib_QueryFactory qf, Object value, String target) {
        \\    qf.subselectQuery("Contacts", true);
        \\    Integer size = ApexStrings.toInteger((int) (value));
        \\    if (targetIsAccount) {}
        \\    else if (targetIsContact) {}
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "enum FirstInstallmentOppCreateOptions { SYNCHRONOUS, ASYNCHRONOUS, ASYNCHRONOUS_WHEN_BULK }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "qf.subSelectQuery(\"Contacts\", true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Integer size = ApexStrings.toInteger(value);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (ApexEquals.eq(target, \"Account\")) {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "else if (ApexEquals.eq(target, \"Contact\")) {}") != null);
}

test "rewriteKnownCompatibilityFixups guards URL path extraction against null input" {
    const gpa = std.testing.allocator;
    const input =
        \\public class UTIL_String {
        \\  public static String getInternalUrlPath(String url) {
        \\    String internalUrl = "";
        \\    internalUrl = new Url(url).getPath();
        \\    return internalUrl;
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "internalUrl = (url == null ? null : (java.net.URI.create(url).getScheme() != null ? java.net.URI.create(url).getPath() : null));") != null);
}

test "rewriteKnownCompatibilityFixups guards GiftBatch and lead affiliation index fronts" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public void run(GiftBatchId giftBatchId) {
        \\    this.batch = selectGiftBatchBy(giftBatchId);
        \\    this.asyncApexJob = selectAsyncApexJobBy(this.batch.getAs("Latest_Apex_Job_Id__c"));
        \\    return this.batch.getAs("Latest_Apex_Job_Id__c");
        \\  }
        \\  public void other() {
        \\    primaryAffiliationId = listSOAfflAccounts.get(1).getValue();
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "this.asyncApexJob = (this.batch == null ? null : selectAsyncApexJobBy(this.batch.getAs(\"Latest_Apex_Job_Id__c\")));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return this.batch == null ? null : this.batch.getAs(\"Latest_Apex_Job_Id__c\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "primaryAffiliationId = (listSOAfflAccounts != null && listSOAfflAccounts.size() > 1 ? listSOAfflAccounts.get(1).getValue() : (listSOAfflAccounts != null && !listSOAfflAccounts.isEmpty() ? listSOAfflAccounts.get(0).getValue() : null));") != null);
}

test "rewriteKnownCompatibilityFixups maps System.Callable implementations to runtime Callable alias" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Callable_API implements apexemu.runtime.System.Callable {
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    // System.Callable is kept (not converted to apexemu.runtime.Callable) to avoid classloader mismatch.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "implements apexemu.runtime.System.Callable") != null);
}

test "rewriteKnownCompatibilityFixups normalizes null collection fronts for field sets and soft credits" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public List<String> listStrFromFieldSet(Schema.FieldSet fieldSetDescribe) {
        \\    if (fieldSetDescribe == null) {
        \\    return null;
        \\    }
        \\    return new ArrayList<String>();
        \\  }
        \\  public List<ApexSObject> deduplicate(List<ApexSObject> moreOpportunityContactRoles) {
        \\    List<ApexSObject> allOpportunityContactRoles = new ArrayList<>();
        \\    allOpportunityContactRoles.addAll(moreOpportunityContactRoles);
        \\    return allOpportunityContactRoles;
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (fieldSetDescribe == null)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return new ArrayList<>();") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (moreOpportunityContactRoles != null)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "allOpportunityContactRoles.addAll(moreOpportunityContactRoles);") != null);
}

test "rewriteKnownCompatibilityFixups initializes RD2 lazy property fronts" {
    const gpa = std.testing.allocator;
    const input =
        \\public class RD2_EntryFormController {
        \\  private static RD2_Settings settings; // Apex property { get; set; }
        \\  public static UTIL_Permissions permissions; // Apex property { get; set; }
        \\  public static String hhRecordTypeId; // Apex property { get; set; }
        \\}
        \\public class RD2_SaveRequest {
        \\  public UTIL_Permissions permissions; // Apex property { get; set; }
        \\  public UTIL_Describe describeUtil; // Apex property { get; set; }
        \\}
        \\public class RD2_CancelCommitmentService {
        \\  public static Integer maxCancelRetries; // Apex property { get; set; }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "private static RD2_Settings settings = RD2_Settings.getInstance(); // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static UTIL_Permissions permissions; // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static String hhRecordTypeId; // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public UTIL_Permissions permissions; // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public UTIL_Describe describeUtil; // Apex property { get; set; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "public static Integer maxCancelRetries = 3; // Apex property { get; set; }") != null);
}

test "rewriteKnownCompatibilityFixups rewrites RD2 query binds and map mutation fronts" {
    const gpa = std.testing.allocator;
    const input =
        \\public class RD2_QueryService {
        \\  public ApexSObject getRecurringDonationForUI(String recurringDonationId) {
        \\    String soql = new UTIL_Query() .withFrom(new Schema.SObjectType("npe03__Recurring_Donation__c")) .withSelectFields(queryFields) .withWhere("Id = :recurringDonationId") .withLimit(1) .build();
        \\    List<ApexSObject> results = Database.query(soql);
        \\    return results.get(0);
        \\  }
        \\  public Boolean isContactDonor(ApexSObject rd) {
        \\    Boolean isContactDonor = ApexSwitch.getAs(rd.getAs("npe03__Organization__r"), "RecordTypeId") == hhRecordTypeId || (rd.getAs("npe03__Organization__c") == null && ApexSwitch.getAs(ApexSwitch.getAs(rd.getAs("npe03__Contact__r"), "Account"), "RecordTypeId") == hhRecordTypeId);
        \\    return isContactDonor;
        \\  }
        \\}
        \\public class RD2_SaveRequest {
        \\  public RD2_SaveRequest removeNonCreateableCustomFields() {
        \\    for (String fieldApiName : customFieldValues.keySet()) {
        \\    if (!permissions.canCreateInstanced( rdSObjectDescribe.getName(), fieldApiName, false)) {
        \\    customFieldValues.remove(fieldApiName);
        \\    }
        \\    }
        \\    return this;
        \\  }
        \\}
        \\public class RD2_EntryFormController_TEST {
        \\  public static void shouldReturnSettings(RD2_AppView initialView) {
        \\    SystemAssert.assertEquals(true, ((ApexSObject) ((java.util.List<ApexSObject>) initialView.getAs("InstallmentPeriodPermissions")).get(0)).get("Createable"), "Installment_Period__c.IsCreatable should return true");
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "List<ApexSObject> results = Database.queryWithBinds(soql, ApexCollections.bindMap(\"recurringDonationId\", recurringDonationId));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return ApexCollections.firstOrNull(results);") != null);
    // After removing the redundant fixup (now handled by rewriteObjectEqualityLine),
    // the isContactDonor assignment gets its == operators rewritten by the equality pass,
    // and then the chained fixup adds the Donor_Type fallback.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Boolean isContactDonor = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "for (String fieldApiName : new ArrayList<String>(customFieldValues.keySet())) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "((Map<String, Object>) initialView.getAs(\"InstallmentPeriodPermissions\")).get(\"Createable\")") != null);
}

test "rewriteBareCustomSettingsSingletonAccess rewrites custom getAll calls" {
    const gpa = std.testing.allocator;
    const input =
        \\Map<String, ApexSObject> byName = Opportunity_Naming_Settings__c.getAll();
        \\Map<String, ApexSObject> customMetadataByName = Example_Config__mdt.getAll();
    ;

    const rewritten = try rewriteBareCustomSettingsSingletonAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSObject.getAll(\"Opportunity_Naming_Settings__c\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSObject.getAll(\"Example_Config__mdt\")") != null);
}

test "rewriteFinalCompatibilityCleanup normalizes runtime alias fronts" {
    const gpa = std.testing.allocator;
    const input =
        \\Database.insert(new AN_AutoNumberService(sObjType).triggerHandler);
        \\Database.insert(triggerHandler);
        \\if (controller.hasUrl) {}
        \\Date d = date.newInstance(2024, 1, 1);
        \\DateTime dt = datetime.newInstance(2024, 1, 1, 0, 0, 0);
    ;

    const rewritten = try rewriteFinalCompatibilityCleanup(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new AN_AutoNumberService(sObjType).getTriggerHandler()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Database.insert(getTriggerHandler());") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "controller.hasURL") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Date.newInstance(2024, 1, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "DateTime.newInstance(2024, 1, 1, 0, 0, 0)") != null);
}

test "rewriteStringCollectionListOfArguments wraps non-string listOf args" {
    const gpa = std.testing.allocator;
    const input =
        \\List<String> ids = new ArrayList<String>(ApexCollections.listOf(batch.getAs("Id"), "fixed", (String) null));
        \\Set<String> names = new LinkedHashSet<String>(ApexCollections.listOf(user.getAs("Name"), owner.Name));
    ;

    const rewritten = try rewriteStringCollectionListOfArguments(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new ArrayList<String>(ApexCollections.listOf(ApexStrings.valueOf(batch.getAs(\"Id\")), \"fixed\", (String) null))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new LinkedHashSet<String>(ApexCollections.listOf(ApexStrings.valueOf(user.getAs(\"Name\")), owner.Name))") != null);
}

test "rewriteApexStringsValueOfCollectionWrappers unwraps string collection constructors" {
    const gpa = std.testing.allocator;
    const input =
        \\Object keep = ApexStrings.valueOf(new LinkedHashSet<String>(ApexCollections.listOf(idValue)));
        \\Object keep2 = ApexStrings.valueOf(new ArrayList<String>(ApexCollections.listOf(nameValue)));
        \\Object leave = ApexStrings.valueOf(somethingElse);
    ;

    const rewritten = try rewriteApexStringsValueOfCollectionWrappers(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Object keep = new LinkedHashSet<String>(ApexCollections.listOf(idValue));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Object keep2 = new ArrayList<String>(ApexCollections.listOf(nameValue));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Object leave = ApexStrings.valueOf(somethingElse);") != null);
}

test "rewriteNumericObjectCasts rewrites get/getAs casted numerics" {
    const gpa = std.testing.allocator;
    const input =
        \\Double amount = (Double) paymentInfo.get(0);
        \\Long count = (Long) row.getAs("Count__c");
        \\Double keep = (Double) customValue;
    ;

    const rewritten = try rewriteNumericObjectCasts(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Double amount = ApexStrings.toDouble(paymentInfo.get(0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Long count = ApexStrings.toLong(row.getAs(\"Count__c\"));") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Double keep = (Double) customValue;") != null);
}

test "rewriteBareSObjectTypeAccess skips method calls on SObjectType namespace" {
    const gpa = std.testing.allocator;
    const input =
        \\Schema.SObjectType contactType = SObjectType.getAs("Contact");
        \\Schema.DescribeSObjectResult describe = SObjectType.getDescribe();
    ;

    const rewritten = try rewriteBareSObjectTypeAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"getAs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"getDescribe\")") == null);
}

test "rewriteBareCustomSettingsSingletonAccess rewrites custom settings singleton calls" {
    const gpa = std.testing.allocator;
    const input =
        \\ApexSObject contacts = npe01__Contacts_And_Orgs_Settings__c.getInstance();
        \\ApexSObject orgAffiliations = npe5__Affiliations_Settings__c.getOrgDefaults();
        \\ApexSObject fromRuntime = apexemu.runtime.OpportunitySettings__c.getInstance();
    ;

    const rewritten = try rewriteBareCustomSettingsSingletonAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSObject contacts = ApexSObject.of(\"npe01__Contacts_And_Orgs_Settings__c\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ApexSObject orgAffiliations = ApexSObject.of(\"npe5__Affiliations_Settings__c\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "apexemu.runtime.OpportunitySettings__c.getInstance()") != null);
}

test "rewriteBareStandardSObjectTypeAccess rewrites standard object namespace tokens" {
    const gpa = std.testing.allocator;
    const input =
        \\Set<Schema.SObjectField> leadFields = new LinkedHashSet<Schema.SObjectField>(ApexCollections.listOf(Lead.fields.getAs("Status"), Lead.fields.getAs("OwnerId")));
        \\Schema.SObjectType roleType = OpportunityContactRole.sObjectType;
    ;

    const rewritten = try rewriteBareStandardSObjectTypeAccess(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"Lead\").fields.getAs(\"Status\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new Schema.SObjectType(\"Lead\").fields.getAs(\"OwnerId\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Schema.SObjectType roleType = new Schema.SObjectType(\"OpportunityContactRole\");") != null);
}

test "rewriteSObjectFieldNameObjectNameUses rewrites object name contexts only" {
    const gpa = std.testing.allocator;
    const input =
        \\String dataImport = new Schema.SObjectField("DataImport__c", "name");
        \\Schema.DescribeFieldResult dfr = UTIL_Describe.getFieldDescribe(new Schema.SObjectField("DataImport__c", "Name"), fieldName);
        \\List<Schema.SObjectField> fields = new ArrayList<Schema.SObjectField>(ApexCollections.listOf(new Schema.SObjectField("Account", "Name")));
    ;

    const rewritten = try rewriteSObjectFieldNameObjectNameUses(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "String dataImport = new Schema.SObjectType(\"DataImport__c\").getName();") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "UTIL_Describe.getFieldDescribe(new Schema.SObjectType(\"DataImport__c\").getName(), fieldName)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new ArrayList<Schema.SObjectField>(ApexCollections.listOf(new Schema.SObjectField(\"Account\", \"Name\")))") != null);
}

test "renderJavaClass preserves abstract inner class modifier" {
    const gpa = std.testing.allocator;
    const source =
        \\public class Demo {
        \\  private abstract class InnerBase {
        \\    protected abstract String render();
        \\  }
        \\}
    ;

    var parsed = try parseApexClass(gpa, "Demo.cls", source);
    defer parsed.deinit(gpa);

    var output = try renderJavaClass(gpa, parsed, "generated");
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, output.java, "private static abstract class InnerBase") != null);
}

test "run promotes multiline test visible inner type visibility" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  @TestVisible
        \\  private without sharing class Inner {
        \\    public void ping() {
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Demo.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);
    const output_path = try std.fs.path.join(gpa, &.{ out_dir, "Demo.java" });
    defer gpa.free(output_path);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    const output = try std.fs.cwd().readFileAlloc(gpa, output_path, 1024 * 1024);
    defer gpa.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "public static class Inner") != null);
}

test "normalizeApexTemplateTokens strips namespace placeholders" {
    const gpa = std.testing.allocator;

    const templated = try gpa.dupe(u8, "%%%NAMESPACE%%%Foo value = \"%%%NAMESPACED_RT%%%\"; ___NAMESPACE___Bar other;");
    const rewritten = try normalizeApexTemplateTokens(gpa, templated);
    defer gpa.free(rewritten);

    try std.testing.expectEqualStrings("Foo value = \"\"; Bar other;", rewritten);

    const plain_input = try gpa.dupe(u8, "public class Sample {}");
    const plain = try normalizeApexTemplateTokens(gpa, plain_input);
    defer gpa.free(plain);

    try std.testing.expect(plain.ptr == plain_input.ptr);
}

test "parseTriggerRegistration extracts fflib trigger manifest entry" {
    const gpa = std.testing.allocator;
    const source =
        \\trigger Opportunities on Opportunity (
        \\  after delete, after insert, after update, before delete, before insert, before update
        \\) {
        \\  fflib_SObjectDomain.triggerHandler(OpportunitiesTriggerHandler.class);
        \\}
    ;

    var registration = (try parseTriggerRegistration(gpa, "Opportunities.trigger", source)).?;
    defer registration.deinit(gpa);

    try std.testing.expectEqualStrings("Opportunities.trigger", registration.source_path);
    try std.testing.expectEqualStrings("Opportunity", registration.sobject_type);
    try std.testing.expectEqualStrings("OpportunitiesTriggerHandler", registration.handler_class);
    try std.testing.expectEqual(@as(usize, 6), registration.events.items.len);
    try std.testing.expectEqual(TriggerEvent.after_delete, registration.events.items[0]);
    try std.testing.expectEqual(TriggerEvent.before_update, registration.events.items[5]);
}
