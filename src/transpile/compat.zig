//! compat — Apex 固有構文の Java 互換変換ファサード。
//!
//! 演算子・数値・クエリ・ SObject アクセス・型キャストなど、
//! Apex 特有の式を Java 互換のコードに変換するサブモジュール群を再エクスポートする。

// Auto-generated facade - re-exports from compat/ sub-modules
// Do not edit directly; edit the sub-modules instead.

const std = @import("std");

const getas = @import("compat/getas.zig");
const helpers = @import("compat/helpers.zig");
const misc = @import("compat/misc.zig");
const numeric = @import("compat/numeric.zig");
const operator = @import("compat/operator.zig");
const patterns = @import("compat/patterns.zig");
const query = @import("compat/query.zig");
const sobject = @import("compat/sobject.zig");

pub const rewriteKnownCompatibilityFixups = patterns.rewriteKnownCompatibilityFixups;
pub const rewriteVisualforceComponentQualifiedAccess = sobject.rewriteVisualforceComponentQualifiedAccess;
pub const rewriteConstructedSObjectTypeClassGetNameCalls = sobject.rewriteConstructedSObjectTypeClassGetNameCalls;
pub const isLikelySObjectNamespaceToken = sobject.isLikelySObjectNamespaceToken;
pub const rewritePseudoSObjectNamespaceAccess = sobject.rewritePseudoSObjectNamespaceAccess;
pub const rewriteResidualCompatibilityArtifacts = patterns.rewriteResidualCompatibilityArtifacts;
pub const rewriteErasedOverloadCompatibility = patterns.rewriteErasedOverloadCompatibility;
pub const rewriteNpspAliasCompat = patterns.rewriteNpspAliasCompat;
pub const rewriteLateCompatibilityFixups = patterns.rewriteLateCompatibilityFixups;
pub const rewriteLabelNamespaceAccess = sobject.rewriteLabelNamespaceAccess;
pub const rewriteLowercaseDatabaseNamespaceAccess = sobject.rewriteLowercaseDatabaseNamespaceAccess;
pub const rewriteCustomSchemaSObjectTypeAccess = sobject.rewriteCustomSchemaSObjectTypeAccess;
pub const rewriteBareCustomSObjectTypeAccess = sobject.rewriteBareCustomSObjectTypeAccess;
pub const isLikelyBareStandardSObjectTypeToken = sobject.isLikelyBareStandardSObjectTypeToken;
pub const rewriteBareStandardSObjectTypeAccess = sobject.rewriteBareStandardSObjectTypeAccess;
pub const rewriteBareCustomSettingsSingletonAccess = sobject.rewriteBareCustomSettingsSingletonAccess;
pub const rewritePageNamespaceAccess = sobject.rewritePageNamespaceAccess;
pub const rewriteTypePathGetAsAccess = getas.rewriteTypePathGetAsAccess;
pub const rewriteSObjectTypeVariableGetAsAccess = getas.rewriteSObjectTypeVariableGetAsAccess;
pub const rewriteApexPagesNestedTypeAliases = sobject.rewriteApexPagesNestedTypeAliases;
pub const rewriteBareCustomSObjectTypeArgCalls = sobject.rewriteBareCustomSObjectTypeArgCalls;
pub const rewriteFieldDisplayTypeCalls = sobject.rewriteFieldDisplayTypeCalls;
pub const rewriteCollectionViewPropertyAccess = misc.rewriteCollectionViewPropertyAccess;
pub const rewriteValuesFieldPseudoCalls = misc.rewriteValuesFieldPseudoCalls;
pub const rewriteValueOfRemoveCalls = misc.rewriteValueOfRemoveCalls;
pub const rewriteApexStringInstanceMethods = misc.rewriteApexStringInstanceMethods;
pub const baseExprLikelyString = misc.baseExprLikelyString;
pub const rewriteBrokenZeroLengthListInitializers = misc.rewriteBrokenZeroLengthListInitializers;
pub const rewriteQuerySingletonCallsAssignedToLists = query.rewriteQuerySingletonCallsAssignedToLists;
pub const rewriteQuerySingletonAssignmentsToDeclaredListVars = query.rewriteQuerySingletonAssignmentsToDeclaredListVars;
pub const rewriteDeclaredListQuerySingletonLine = query.rewriteDeclaredListQuerySingletonLine;
pub const rewriteDeclaredSObjectQueryAssignments = query.rewriteDeclaredSObjectQueryAssignments;
pub const rewriteDeclaredSObjectQueryAssignmentLine = query.rewriteDeclaredSObjectQueryAssignmentLine;
pub const rewriteLegacyLiteralTokens = sobject.rewriteLegacyLiteralTokens;
pub const rewriteBareSchemaEnumConstantAccess = sobject.rewriteBareSchemaEnumConstantAccess;
pub const isMethodLikeSignatureLine = helpers.isMethodLikeSignatureLine;
pub const rewriteBareSObjectTypeAccess = sobject.rewriteBareSObjectTypeAccess;
pub const rewriteSObjectFieldNameObjectNameUses = sobject.rewriteSObjectFieldNameObjectNameUses;
pub const rewriteInstanceListDeepCloneCalls = misc.rewriteInstanceListDeepCloneCalls;
pub const rewriteLongAssignmentsFromIntegerIdentifiers = numeric.rewriteLongAssignmentsFromIntegerIdentifiers;
pub const BoxedNumericKind = numeric.BoxedNumericKind;
pub const MethodReturnKind = numeric.MethodReturnKind;
pub const rewriteBoxedNumericLiteralCompatibility = numeric.rewriteBoxedNumericLiteralCompatibility;
pub const appendTypedNamesFromLine = numeric.appendTypedNamesFromLine;
pub const appendTypedParameterNamesFromSignatureLine = numeric.appendTypedParameterNamesFromSignatureLine;
pub const extractTypedDeclarationSection = helpers.extractTypedDeclarationSection;
pub const rewriteTypedDeclarationIntegerInitializers = numeric.rewriteTypedDeclarationIntegerInitializers;
pub const rewriteTypedNameLiteralAssignments = numeric.rewriteTypedNameLiteralAssignments;
pub const rewriteLongMathMaxAssignments = numeric.rewriteLongMathMaxAssignments;
pub const rewriteIntegerTypedDoubleAssignments = numeric.rewriteIntegerTypedDoubleAssignments;
pub const memberNameLikelyDouble = numeric.memberNameLikelyDouble;
pub const rewriteLikelyDoubleMemberLiteralAssignments = numeric.rewriteLikelyDoubleMemberLiteralAssignments;
pub const detectMethodReturnKind = numeric.detectMethodReturnKind;
pub const rewriteMethodReturnLiterals = numeric.rewriteMethodReturnLiterals;
pub const rewriteBoxedNumericCasts = numeric.rewriteBoxedNumericCasts;
pub const lhsContainsTypedName = numeric.lhsContainsTypedName;
pub const normalizeExpressionForKind = numeric.normalizeExpressionForKind;
pub const normalizeLiteralForKind = numeric.normalizeLiteralForKind;
pub const isSignedIntegerLiteral = helpers.isSignedIntegerLiteral;
pub const isSignedDecimalZeroLiteral = helpers.isSignedDecimalZeroLiteral;
pub const rewriteDoubleDateTimeDeltaAssignments = numeric.rewriteDoubleDateTimeDeltaAssignments;
pub const rewriteGetAsCollectionAccessors = getas.rewriteGetAsCollectionAccessors;
pub const parseStringLiteralContents = helpers.parseStringLiteralContents;
pub const countUppercaseChars = helpers.countUppercaseChars;
pub const lowercaseIdentifier = helpers.lowercaseIdentifier;
pub const isScreamingSnakeIdentifier = misc.isScreamingSnakeIdentifier;
pub const isCaseVariantCandidate = misc.isCaseVariantCandidate;
pub const isImportOrPackageLineAt = helpers.isImportOrPackageLineAt;
pub const rewriteCaseInsensitiveIdentifierVariants = misc.rewriteCaseInsensitiveIdentifierVariants;
pub const findTopLevelStatementSemicolon = helpers.findTopLevelStatementSemicolon;
pub const rewriteGetAsMutationAssignments = getas.rewriteGetAsMutationAssignments;
pub const argLikelyNeedsStringKeyWrap = getas.argLikelyNeedsStringKeyWrap;
pub const rewriteSObjectGetPutAmbiguousArgs = getas.rewriteSObjectGetPutAmbiguousArgs;
pub const rewriteUnaryPlusStringLiterals = misc.rewriteUnaryPlusStringLiterals;
pub const rewriteGetAsNumericCompatibility = getas.rewriteGetAsNumericCompatibility;
pub const rewriteGetAsStringConcatenationCompatibility = getas.rewriteGetAsStringConcatenationCompatibility;
pub const rewriteGetAsStringConcatenationLine = getas.rewriteGetAsStringConcatenationLine;
pub const rewriteNumericGetAsLine = getas.rewriteNumericGetAsLine;
pub const getAsCallNeedsNumericCompatibility = getas.getAsCallNeedsNumericCompatibility;
pub const extractGetAsCallStringLiteralFieldName = helpers.extractGetAsCallStringLiteralFieldName;
pub const containsFieldKeywordToken = helpers.containsFieldKeywordToken;
pub const fieldNameLooksNumeric = helpers.fieldNameLooksNumeric;
pub const fieldNameLooksNonNumeric = helpers.fieldNameLooksNonNumeric;
pub const fieldNameLooksIdLike = helpers.fieldNameLooksIdLike;
pub const fieldNameLooksBoolean = helpers.fieldNameLooksBoolean;
pub const lineLikelyNeedsNumericGetAsRewrite = getas.lineLikelyNeedsNumericGetAsRewrite;
pub const getAsCallIsNullCompared = getas.getAsCallIsNullCompared;
pub const rewriteGetAsFieldAddErrorCalls = getas.rewriteGetAsFieldAddErrorCalls;
pub const rewriteBooleanEqualsIsEmptyArtifacts = operator.rewriteBooleanEqualsIsEmptyArtifacts;
pub const rewriteBooleanEqualsTrailingInvocationArtifacts = operator.rewriteBooleanEqualsTrailingInvocationArtifacts;
pub const rewriteApexStringsToIntegerIntCast = numeric.rewriteApexStringsToIntegerIntCast;
pub const rewriteStringCollectionListOfArguments = misc.rewriteStringCollectionListOfArguments;
pub const shouldWrapStringCollectionArgument = misc.shouldWrapStringCollectionArgument;
pub const rewriteApexStringsValueOfCollectionWrappers = misc.rewriteApexStringsValueOfCollectionWrappers;
pub const rewriteNumericObjectCasts = numeric.rewriteNumericObjectCasts;
pub const rewriteFinalCompatibilityCleanup = patterns.rewriteFinalCompatibilityCleanup;
pub const rewriteTrailingDatabaseQueryAssignmentParens = query.rewriteTrailingDatabaseQueryAssignmentParens;
pub const normalizeDatabaseQueryAssignmentLine = query.normalizeDatabaseQueryAssignmentLine;
pub const rewriteListMethodQuerySingletonReturns = query.rewriteListMethodQuerySingletonReturns;
pub const countByte = helpers.countByte;
pub const isListMethodSignatureLine = query.isListMethodSignatureLine;
pub const normalizeListMethodQuerySingletonReturnLine = query.normalizeListMethodQuerySingletonReturnLine;
pub const rewriteValuesMethodCollectionViews = misc.rewriteValuesMethodCollectionViews;
pub const rewriteSchemaFieldNamespaceGetAsMethodCalls = sobject.rewriteSchemaFieldNamespaceGetAsMethodCalls;
pub const rewriteDescribeFieldNamespaceAliases = sobject.rewriteDescribeFieldNamespaceAliases;
pub const rewriteDescribeGetAsAliases = sobject.rewriteDescribeGetAsAliases;
pub const rewriteGetAsEnumNameCalls = getas.rewriteGetAsEnumNameCalls;
pub const rewriteQueryWithBindsListChaining = query.rewriteQueryWithBindsListChaining;
pub const rewriteGetAsDateMethodCalls = getas.rewriteGetAsDateMethodCalls;
pub const rewriteApexStringsValueOfDateGetAs = getas.rewriteApexStringsValueOfDateGetAs;
pub const rewriteDynamicFieldNameGetCalls = getas.rewriteDynamicFieldNameGetCalls;
pub const isLikelyCustomFieldSegment = sobject.isLikelyCustomFieldSegment;
pub const isSObjectTypeNamespaceBase = sobject.isSObjectTypeNamespaceBase;
pub const rewriteCustomSObjectMemberAccess = sobject.rewriteCustomSObjectMemberAccess;
pub const rewriteKnownSObjectBooleanPropertyAccess = sobject.rewriteKnownSObjectBooleanPropertyAccess;
pub const isComparisonRightOperandContext = operator.isComparisonRightOperandContext;
pub const rewriteBooleanGetOperands = operator.rewriteBooleanGetOperands;
pub const isBooleanEqualsCallLiteral = operator.isBooleanEqualsCallLiteral;
pub const isBooleanLiteralAt = operator.isBooleanLiteralAt;
pub const rewriteBooleanEqualsComparisonArtifacts = operator.rewriteBooleanEqualsComparisonArtifacts;
pub const extractGeneratedJavaClassName = helpers.extractGeneratedJavaClassName;
pub const rewritePrivateStaticNestedTestClasses = misc.rewritePrivateStaticNestedTestClasses;
pub const rewriteLocalStaticWaitCalls = misc.rewriteLocalStaticWaitCalls;
pub const rewriteBrokenInlineMethodAssignmentsInSObjectSet = misc.rewriteBrokenInlineMethodAssignmentsInSObjectSet;
pub const rewriteNegatedSizeEqualityArtifacts = numeric.rewriteNegatedSizeEqualityArtifacts;
pub const rewriteIntegerCompareToDoubleReturns = numeric.rewriteIntegerCompareToDoubleReturns;
pub const rewriteDecimalSetScaleCalls = getas.rewriteDecimalSetScaleCalls;
pub const rewriteGetErrorsArrayAccess = getas.rewriteGetErrorsArrayAccess;
pub const rewriteRecordTypeInfoMapDeclarations = sobject.rewriteRecordTypeInfoMapDeclarations;
pub const rewriteRecordTypeInfoUsages = sobject.rewriteRecordTypeInfoUsages;
pub const extractDeclaredVariableName = helpers.extractDeclaredVariableName;
pub const extractTypedVariableName = helpers.extractTypedVariableName;
pub const extractParameterizedTypeVariableName = helpers.extractParameterizedTypeVariableName;
pub const appendUniqueIdentifier = helpers.appendUniqueIdentifier;
pub const identifierInList = helpers.identifierInList;
pub const extractForEachVariableNameOfType = helpers.extractForEachVariableNameOfType;
pub const SimpleAssignment = helpers.SimpleAssignment;
pub const extractSimpleAssignment = helpers.extractSimpleAssignment;
pub const lineContainsRecordTypeInfoHelperCall = sobject.lineContainsRecordTypeInfoHelperCall;
pub const lineContainsRecordTypeInfoGetter = sobject.lineContainsRecordTypeInfoGetter;
pub const CompatibilityState = getas.CompatibilityState;
pub const GetAsLikeCall = helpers.GetAsLikeCall;
pub const rewriteGetAsBooleanCompatibility = getas.rewriteGetAsBooleanCompatibility;
pub const rewriteGetAsStringMethodCalls = getas.rewriteGetAsStringMethodCalls;
pub const rewriteOverloadedStringIdCallArgs = getas.rewriteOverloadedStringIdCallArgs;
pub const rewriteEnhancedForGetAsIterables = getas.rewriteEnhancedForGetAsIterables;
pub const rewriteEnhancedForCompareArtifacts = getas.rewriteEnhancedForCompareArtifacts;
pub const rewriteDatabaseDeleteQueryCalls = query.rewriteDatabaseDeleteQueryCalls;
pub const rewriteLinewiseRelationalComparisons = operator.rewriteLinewiseRelationalComparisons;
pub const rewriteFirstOrNullScalarWrappers = query.rewriteFirstOrNullScalarWrappers;
pub const isIdGetAsSuffix = getas.isIdGetAsSuffix;
pub const rewriteNestedIdApexSwitchGetAs = getas.rewriteNestedIdApexSwitchGetAs;
pub const rewriteBrokenApexEqualsTernaryComparisons = operator.rewriteBrokenApexEqualsTernaryComparisons;
pub const rewriteStringCastBooleanEqualsArtifacts = operator.rewriteStringCastBooleanEqualsArtifacts;
pub const rewriteValueOfGetNameArtifacts = operator.rewriteValueOfGetNameArtifacts;
pub const isLikelyClassLiteralToken = misc.isLikelyClassLiteralToken;
pub const collectSystemTypeVariableNames = misc.collectSystemTypeVariableNames;
pub const rewriteSystemTypeClassLiteralAssignments = misc.rewriteSystemTypeClassLiteralAssignments;
pub const rewriteCollectionGenericInstanceof = misc.rewriteCollectionGenericInstanceof;
pub const rewriteDatabaseQueryIndexCompatibility = query.rewriteDatabaseQueryIndexCompatibility;
pub const matchGetAsLikeCall = helpers.matchGetAsLikeCall;
pub const BooleanLiteralComparison = getas.BooleanLiteralComparison;
pub const parseBooleanLiteralComparison = getas.parseBooleanLiteralComparison;
pub const isBooleanOperandContext = getas.isBooleanOperandContext;
pub const isReturnKeywordContext = getas.isReturnKeywordContext;
pub const isBooleanIntroducerBeforeParen = getas.isBooleanIntroducerBeforeParen;
pub const assignmentContextExpectsBoolean = getas.assignmentContextExpectsBoolean;
pub const findPreviousNonWhitespace = helpers.findPreviousNonWhitespace;
pub const findNextNonWhitespace = helpers.findNextNonWhitespace;
pub const containsGetAsLikeCall = helpers.containsGetAsLikeCall;
pub const findTopLevelColon = helpers.findTopLevelColon;
pub const inferEnhancedForElementType = getas.inferEnhancedForElementType;
pub const rewriteUtilFinderInnerSearchBuilder = patterns.rewriteUtilFinderInnerSearchBuilder;
pub const rewriteEpManageTemplateCompat = patterns.rewriteEpManageTemplateCompat;
pub const replaceLiteralAll = helpers.replaceLiteralAll;
pub const replaceSectionBetweenMarkers = helpers.replaceSectionBetweenMarkers;
pub const rewriteApexMocksUtilsMethodFixups = patterns.rewriteApexMocksUtilsMethodFixups;
pub const replaceMethodBodyBySignature = helpers.replaceMethodBodyBySignature;
pub const DynamicBindEntry = query.DynamicBindEntry;
pub const rewriteDynamicWhereClauseQueryBinds = query.rewriteDynamicWhereClauseQueryBinds;
pub const looksLikePublicMethodSignatureLine = helpers.looksLikePublicMethodSignatureLine;
pub const collectDynamicQueryBindEntriesForMethod = query.collectDynamicQueryBindEntriesForMethod;
pub const initializeBindVariablesInMethod = query.initializeBindVariablesInMethod;
pub const maybeInitializeBindDeclarationLine = query.maybeInitializeBindDeclarationLine;
pub const isBindVariableName = query.isBindVariableName;
pub const isLikelyLocalDeclarationType = query.isLikelyLocalDeclarationType;
pub const rewriteMethodQueryCallsWithDynamicBinds = query.rewriteMethodQueryCallsWithDynamicBinds;
pub const collectBindNamesFromQueryExpression = query.collectBindNamesFromQueryExpression;
pub const buildBindMapArgument = query.buildBindMapArgument;
pub const rewriteBindMapArgumentWithMissingBinds = query.rewriteBindMapArgumentWithMissingBinds;
pub const appendUniqueOwnedName = helpers.appendUniqueOwnedName;
pub const containsIgnoreCaseOwnedName = helpers.containsIgnoreCaseOwnedName;
pub const containsIgnoreCaseNameSlice = helpers.containsIgnoreCaseNameSlice;
pub const getOrCreateDynamicBindEntry = query.getOrCreateDynamicBindEntry;
pub const dynamicBindEntryIndex = query.dynamicBindEntryIndex;
pub const deinitOwnedNameList = query.deinitOwnedNameList;
pub const deinitDynamicBindEntries = query.deinitDynamicBindEntries;
pub const rewriteInterfaceCompatibilityFixups = patterns.rewriteInterfaceCompatibilityFixups;
pub const rewriteApexSystemUtilityCalls = misc.rewriteApexSystemUtilityCalls;
pub const rewriteDateArithmetic = operator.rewriteDateArithmetic;
pub const rewriteApexStrictEqualityOperators = operator.rewriteApexStrictEqualityOperators;
pub const rewriteApexNotEqualsOperator = operator.rewriteApexNotEqualsOperator;
pub const rewriteSystemStatusCodeConstants = operator.rewriteSystemStatusCodeConstants;
pub const RelationalOperator = helpers.RelationalOperator;
pub const RelationalMatch = helpers.RelationalMatch;
pub const rewriteStringRelationalComparisons = operator.rewriteStringRelationalComparisons;
pub const rewriteNestedParenStringRelationalComparisons = operator.rewriteNestedParenStringRelationalComparisons;
pub const rewriteTernaryStringRelationalComparisons = operator.rewriteTernaryStringRelationalComparisons;
pub const findTopLevelTernary = helpers.findTopLevelTernary;
pub const findTopLevelRelationalMatch = helpers.findTopLevelRelationalMatch;
pub const isLikelyGenericCloseAngle = helpers.isLikelyGenericCloseAngle;
pub const nextNonWhitespaceChar = helpers.nextNonWhitespaceChar;
pub const prevNonWhitespaceChar = helpers.prevNonWhitespaceChar;
pub const hasWhitespaceAroundOperator = helpers.hasWhitespaceAroundOperator;
pub const isLikelyStringishComparisonOperand = helpers.isLikelyStringishComparisonOperand;
pub const isLikelyDateishComparisonOperand = helpers.isLikelyDateishComparisonOperand;
pub const wrapNullSafeComparisons = operator.wrapNullSafeComparisons;
pub const findTopLevelLogicalOperator = helpers.findTopLevelLogicalOperator;
pub const rewriteTriggerContextPropertyAccess = sobject.rewriteTriggerContextPropertyAccess;
pub const SafeNavigationRewrite = operator.SafeNavigationRewrite;
pub const rewriteApexSafeNavigationOperators = operator.rewriteApexSafeNavigationOperators;
pub const rewriteFirstApexSafeNavigationOperator = operator.rewriteFirstApexSafeNavigationOperator;
pub const findSafeNavigationLeftStart = operator.findSafeNavigationLeftStart;
pub const isSafeNavigationBoundaryChar = operator.isSafeNavigationBoundaryChar;
pub const rewriteNullCoalescingOperator = operator.rewriteNullCoalescingOperator;
pub const findTopLevelNullCoalescingOperator = helpers.findTopLevelNullCoalescingOperator;
pub const rewriteApexTypeCasts = operator.rewriteApexTypeCasts;
pub const rewriteSObjectGetAsLengthFallback = getas.rewriteSObjectGetAsLengthFallback;
pub const isLikelyCastStart = helpers.isLikelyCastStart;
pub const isLikelyCastFollowToken = helpers.isLikelyCastFollowToken;
pub const isLikelyCastType = helpers.isLikelyCastType;
pub const rewriteGenericClassLiterals = misc.rewriteGenericClassLiterals;
pub const rewriteJsonDeserializeListCasts = misc.rewriteJsonDeserializeListCasts;
pub const rewriteSObjectGetAsMethodCalls = getas.rewriteSObjectGetAsMethodCalls;
pub const rewriteStringInstanceMethodCalls = misc.rewriteStringInstanceMethodCalls;
pub const rewritePrintlnGetAsCalls = getas.rewritePrintlnGetAsCalls;
pub const specificIdentifierReplacement = misc.specificIdentifierReplacement;
pub const hasUpperAfterFirst = misc.hasUpperAfterFirst;
pub const isPrecededByKeywordIgnoreCase = misc.isPrecededByKeywordIgnoreCase;
pub const rewriteSpecificIdentifierCase = misc.rewriteSpecificIdentifierCase;
pub const rewriteTestDoubleClassCtorCalls = misc.rewriteTestDoubleClassCtorCalls;
pub const isSelfQualifiedTypeReference = helpers.isSelfQualifiedTypeReference;
pub const rewriteSystemTypeListOfClassLiterals = misc.rewriteSystemTypeListOfClassLiterals;
pub const rewriteSystemTypeMethodClassLiteralArgs = misc.rewriteSystemTypeMethodClassLiteralArgs;
pub const rewriteNoArgCloneCalls = misc.rewriteNoArgCloneCalls;
pub const rewriteStringKeyedSetMethodCalls = misc.rewriteStringKeyedSetMethodCalls;
pub const rewriteNoArgSortCalls = misc.rewriteNoArgSortCalls;
pub const rewriteIdGetSObjectTypeCalls = sobject.rewriteIdGetSObjectTypeCalls;
pub const rewriteTypeSObjectTypeConstants = sobject.rewriteTypeSObjectTypeConstants;
pub const rewriteTypeSObjectFieldConstants = sobject.rewriteTypeSObjectFieldConstants;
pub const rewriteSObjectTypeFieldSetConstants = sobject.rewriteSObjectTypeFieldSetConstants;
pub const typeReferenceObjectName = helpers.typeReferenceObjectName;
pub const rewriteTriggerOperationEnumConstantCase = sobject.rewriteTriggerOperationEnumConstantCase;
pub const canonicalTriggerOperationConstant = sobject.canonicalTriggerOperationConstant;
pub const isStaticValueAccessPathExpression = helpers.isStaticValueAccessPathExpression;
pub const findMemberAccessBaseStart = helpers.findMemberAccessBaseStart;
pub const rewriteQueryGetAsAccess = getas.rewriteQueryGetAsAccess;
pub const rewriteFirstOrNullGetAs = getas.rewriteFirstOrNullGetAs;
pub const rewriteDatabaseQueryCallsWithBinds = query.rewriteDatabaseQueryCallsWithBinds;
pub const collectSoqlBindNamesFromJavaLiteral = helpers.collectSoqlBindNamesFromJavaLiteral;
pub const isJavaStringLiteral = helpers.isJavaStringLiteral;
pub const rewriteIntegerValueOfNumericCasts = numeric.rewriteIntegerValueOfNumericCasts;
pub const shouldForceIntegerValueOfCast = numeric.shouldForceIntegerValueOfCast;
pub const containsGetAsCall = numeric.containsGetAsCall;
pub const rewriteNumericValueOfObjectIdentifiers = numeric.rewriteNumericValueOfObjectIdentifiers;
pub const convertBracketIndexAccessPass = misc.convertBracketIndexAccessPass;
pub const convertBracketIndexAccess = misc.convertBracketIndexAccess;
pub const looksLikeApexSizedArrayConstructorBase = misc.looksLikeApexSizedArrayConstructorBase;
pub const findIndexAccessBaseStart = helpers.findIndexAccessBaseStart;
pub const extendOverConstructorNewKeyword = helpers.extendOverConstructorNewKeyword;
pub const extendQualifiedIdentifierPathLeft = helpers.extendQualifiedIdentifierPathLeft;
pub const extendIndexBaseLeft = helpers.extendIndexBaseLeft;
pub const convertInlineCollectionConstructors = misc.convertInlineCollectionConstructors;
pub const isIdSObjectMapType = misc.isIdSObjectMapType;
pub const isIdSObjectMapGeneric = misc.isIdSObjectMapGeneric;
pub const convertInlineCollectionLiterals = misc.convertInlineCollectionLiterals;
pub const convertInlineSObjectConstructors = misc.convertInlineSObjectConstructors;
pub const rewriteObjectEqualityWithDeclaredObjects = operator.rewriteObjectEqualityWithDeclaredObjects;
pub const rewriteObjectEqualityLine = operator.rewriteObjectEqualityLine;
pub const rewriteEqualityOperators = operator.rewriteEqualityOperators;
pub const containsKnownObjectIdentifier = helpers.containsKnownObjectIdentifier;
pub const rewriteSimpleObjectEqualityExpression = operator.rewriteSimpleObjectEqualityExpression;
pub const findSimpleEqualityOperator = helpers.findSimpleEqualityOperator;
pub const containsStandaloneIdentifier = helpers.containsStandaloneIdentifier;
pub const findLeftOperandStart = helpers.findLeftOperandStart;
pub const skipWhitespace = helpers.skipWhitespace;
pub const findExpressionEnd = helpers.findExpressionEnd;
pub const findCastOperandEnd = helpers.findCastOperandEnd;
pub const isNumericLiteral = helpers.isNumericLiteral;
pub const rewriteApexInstanceofChecks = operator.rewriteApexInstanceofChecks;
pub const isTypeNameTokenChar = operator.isTypeNameTokenChar;
pub const findInstanceofLhsStart = operator.findInstanceofLhsStart;
pub const isInstanceofKeywordAt = operator.isInstanceofKeywordAt;
pub const isInstanceofOperandBoundary = operator.isInstanceofOperandBoundary;
pub const isLikelySObjectTypeForInstanceof = helpers.isLikelySObjectTypeForInstanceof;
pub const isLikelyCustomSObjectTypeName = helpers.isLikelyCustomSObjectTypeName;
pub const convertInlineSoqlQueries = query.convertInlineSoqlQueries;
pub const convertInlineSoslQueries = query.convertInlineSoslQueries;
pub const normalizeSoslQueryForEmulation = query.normalizeSoslQueryForEmulation;
pub const buildDatabaseSearchCall = query.buildDatabaseSearchCall;
pub const rewriteDatabaseQueryStringConsumers = query.rewriteDatabaseQueryStringConsumers;
pub const rewriteApexStringUtilityCalls = misc.rewriteApexStringUtilityCalls;
pub const unwrapDatabaseQueryCall = query.unwrapDatabaseQueryCall;
pub const DatabaseQuerySource = query.DatabaseQuerySource;
pub const parseDatabaseQuerySource = query.parseDatabaseQuerySource;
pub const convertSObjectFieldAccess = sobject.convertSObjectFieldAccess;
pub const shouldSkipSObjectFieldAccessBase = sobject.shouldSkipSObjectFieldAccessBase;
pub const isWithinImportOrPackageDeclaration = helpers.isWithinImportOrPackageDeclaration;
pub const isWithinAnnotationQualifiedChain = helpers.isWithinAnnotationQualifiedChain;
// ---------------------------------------------------------------------------
// Tests (moved from root.zig)
// ---------------------------------------------------------------------------

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

test "rewriteLateCompatibilityFixups rewrites ApexGlobal and NPSP state artifacts" {
    const gpa = std.testing.allocator;
    const input =
        \\@ApexGlobal
        \\public class Sample {
        \\  private final String context;
        \\  public Sample(String context, ApexSObject state) {
        \\    this.context = context.name();
        \\    state.isMetaConfirmed = false;
        \\  }
        \\}
    ;

    const rewritten = try rewriteLateCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "@apexemu.annotations.ApexGlobal") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "this.context = context;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "state.set(\"isMetaConfirmed\", false);") != null);
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

test "rewriteKnownCompatibilityFixups rewrites ERR_Handler contexts and preserves RD2 override members" {
    const gpa = std.testing.allocator;
    const input =
        \\public class Sample {
        \\  public void run(apexemu.runtime.System.Exception e, Boolean dryRunMode) {
        \\    if (!RD2_EnablementService.isRecurringDonations2Enabled && dryRunMode) {
        \\      RD2_EnablementService.isRecurringDonations2EnabledOverride = true;
        \\      ERR_Handler.processError(e, ERR_Handler_API.Context.STTG);
        \\      ERR_LogService.Logger logger = new ERR_LogService.Logger(ERR_Handler_API.Context.Elevate, new Schema.SObjectType("Contact"));
        \\    }
        \\  }
        \\}
    ;

    const rewritten = try rewriteKnownCompatibilityFixups(gpa, input);
    defer gpa.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "if (!false && dryRunMode)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "RD2_EnablementService.isRecurringDonations2EnabledOverride = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ERR_Handler.processError(e, \"STTG\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new ERR_LogService.Logger(\"Elevate\", new Schema.SObjectType(\"Contact\"))") != null);
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
