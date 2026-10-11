import * as vscode from "vscode";

const APEX_REF_BASE =
  "https://developer.salesforce.com/docs/atlas.en-us.apexref.meta/apexref/";

type ApexReferenceDoc = {
  name: string;
  url: string;
};

const APEX_REFERENCE_DOCS: Record<string, ApexReferenceDoc> = {
  Blob: doc("Blob", "apex_methods_system_blob.htm"),
  Boolean: doc("Boolean", "apex_methods_system_boolean.htm"),
  Crypto: doc("Crypto", "apex_classes_restful_crypto.htm"),
  Database: doc("Database", "apex_methods_system_database.htm"),
  Date: doc("Date", "apex_methods_system_date.htm"),
  Datetime: doc("Datetime", "apex_methods_system_datetime.htm"),
  Decimal: doc("Decimal", "apex_methods_system_decimal.htm"),
  Double: doc("Double", "apex_methods_system_double.htm"),
  EncodingUtil: doc("EncodingUtil", "apex_classes_restful_encodingUtil.htm"),
  Id: doc("Id", "apex_methods_system_id.htm"),
  Integer: doc("Integer", "apex_methods_system_integer.htm"),
  JSON: doc("JSON", "apex_methods_system_json.htm"),
  JSONGenerator: doc("JSONGenerator", "apex_methods_system_jsongenerator.htm"),
  JSONParser: doc("JSONParser", "apex_methods_system_jsonparser.htm"),
  Limits: doc("Limits", "apex_methods_system_limits.htm"),
  List: doc("List", "apex_methods_system_list.htm"),
  Long: doc("Long", "apex_methods_system_long.htm"),
  Map: doc("Map", "apex_methods_system_map.htm"),
  Math: doc("Math", "apex_methods_system_math.htm"),
  Messaging: doc("Messaging", "apex_classes_email_outbound_messaging.htm"),
  Object: doc("Object", "apex_methods_system_object.htm"),
  Pattern: doc("Pattern", "apex_classes_pattern_and_matcher_pattern_methods.htm"),
  Schema: doc("Schema", "apex_methods_system_schema.htm"),
  ChildRelationship: doc(
    "Schema.ChildRelationship",
    "apex_class_Schema_ChildRelationship.htm"
  ),
  DescribeFieldResult: doc(
    "Schema.DescribeFieldResult",
    "apex_methods_system_fields_describe.htm"
  ),
  "Schema.DescribeFieldResult": doc(
    "Schema.DescribeFieldResult",
    "apex_methods_system_fields_describe.htm"
  ),
  DescribeSObjectResult: doc(
    "Schema.DescribeSObjectResult",
    "apex_methods_system_sobject_describe.htm"
  ),
  "Schema.DescribeSObjectResult": doc(
    "Schema.DescribeSObjectResult",
    "apex_methods_system_sobject_describe.htm"
  ),
  FieldSet: doc("Schema.FieldSet", "apex_methods_system_fieldsets_describe.htm"),
  RecordTypeInfo: doc(
    "Schema.RecordTypeInfo",
    "apex_class_Schema_RecordTypeInfo.htm"
  ),
  Set: doc("Set", "apex_methods_system_set.htm"),
  SObject: doc("SObject", "apex_methods_system_sobject.htm"),
  SObjectField: doc("Schema.SObjectField", "apex_class_Schema_SObjectField.htm"),
  "Schema.SObjectField": doc(
    "Schema.SObjectField",
    "apex_class_Schema_SObjectField.htm"
  ),
  SObjectType: doc("Schema.SObjectType", "apex_class_Schema_SObjectType.htm"),
  "Schema.SObjectType": doc(
    "Schema.SObjectType",
    "apex_class_Schema_SObjectType.htm"
  ),
  String: doc("String", "apex_methods_system_string.htm"),
  System: doc("System", "apex_methods_system_system.htm"),
  Test: doc("Test", "apex_testing_tools_start_stop_test.htm"),
  Time: doc("Time", "apex_methods_system_time.htm"),
  Trigger: doc("Trigger", "apex_triggers_context_variables.htm"),
  Type: doc("Type", "apex_methods_system_type.htm"),
  URL: doc("URL", "apex_methods_system_url.htm"),
  Url: doc("URL", "apex_methods_system_url.htm"),
  UserInfo: doc("UserInfo", "apex_methods_system_userinfo.htm"),
};

const APEX_IDENTIFIER = /[A-Za-z_][A-Za-z0-9_]*/;

export function registerApexReferenceHoverProvider(
  context: vscode.ExtensionContext
) {
  context.subscriptions.push(
    vscode.languages.registerHoverProvider(
      [
        { scheme: "file", language: "apex" },
        { scheme: "file", pattern: "**/*.cls" },
        { scheme: "file", pattern: "**/*.trigger" },
      ],
      new ApexReferenceHoverProvider()
    )
  );
}

class ApexReferenceHoverProvider implements vscode.HoverProvider {
  provideHover(
    document: vscode.TextDocument,
    position: vscode.Position
  ): vscode.ProviderResult<vscode.Hover> {
    const enabled = vscode.workspace
      .getConfiguration("apexgov")
      .get<boolean>("standardLibraryDocs.enabled", true);
    if (!enabled) return undefined;

    const range = document.getWordRangeAtPosition(position, APEX_IDENTIFIER);
    if (!range) return undefined;

    const word = document.getText(range);
    const target = resolveApexReferenceTarget(document, range, word);
    if (!target) return undefined;

    const markdown = new vscode.MarkdownString();
    markdown.supportHtml = false;
    markdown.isTrusted = false;
    markdown.appendMarkdown(`**Apex Reference: ${escapeMarkdown(target.label)}**\n\n`);
    markdown.appendMarkdown(`[Open official Salesforce docs](${target.doc.url})`);

    return new vscode.Hover(markdown, range);
  }
}

type ResolvedApexReference = {
  label: string;
  doc: ApexReferenceDoc;
};

function resolveApexReferenceTarget(
  document: vscode.TextDocument,
  range: vscode.Range,
  word: string
): ResolvedApexReference | undefined {
  const direct = resolveDoc(word);
  const memberReceiverType = inferReceiverTypeBeforeMember(document, range);

  if (memberReceiverType) {
    const receiverDoc = resolveDoc(memberReceiverType);
    const returnType = standardMemberReturnType(memberReceiverType, word);
    const returnDoc = returnType ? resolveDoc(returnType) : undefined;
    const docTarget = receiverDoc ?? returnDoc;
    if (docTarget) {
      return {
        label: `${docTarget.name}.${word}`,
        doc: docTarget,
      };
    }
  }

  if (direct) {
    return {
      label: direct.name,
      doc: direct,
    };
  }

  return undefined;
}

function inferReceiverTypeBeforeMember(
  document: vscode.TextDocument,
  range: vscode.Range
): string | undefined {
  const line = document.lineAt(range.start.line).text;
  const expression = receiverExpressionBeforeMember(line, range.start.character);
  if (!expression) return undefined;
  return inferExpressionType(document, range.start, expression);
}

function receiverExpressionBeforeMember(
  line: string,
  memberStart: number
): string | undefined {
  let i = memberStart - 1;
  while (i >= 0 && /\s/.test(line[i])) i--;
  if (i < 0 || line[i] !== ".") return undefined;

  i--;
  if (i >= 0 && line[i] === "?") i--;
  while (i >= 0 && /\s/.test(line[i])) i--;
  const end = i + 1;
  const start = expressionStart(line, i);
  if (start >= end) return undefined;
  return line.slice(start, end).trim();
}

function expressionStart(line: string, index: number): number {
  let i = index;
  let parenDepth = 0;
  let bracketDepth = 0;
  while (i >= 0) {
    const ch = line[i];
    if (ch === ")") parenDepth++;
    else if (ch === "(") {
      if (parenDepth === 0) break;
      parenDepth--;
    } else if (ch === "]") bracketDepth++;
    else if (ch === "[") {
      if (bracketDepth === 0) break;
      bracketDepth--;
    }

    if (parenDepth === 0 && bracketDepth === 0 && isExpressionBoundary(ch)) {
      break;
    }
    i--;
  }
  return i + 1;
}

function isExpressionBoundary(ch: string): boolean {
  return /[\s,;{}=:+\-*/%<>!&|]/.test(ch);
}

function inferExpressionType(
  document: vscode.TextDocument,
  position: vscode.Position,
  expression: string
): string | undefined {
  const trimmed = trimOuterParens(expression.trim());
  if (!trimmed) return undefined;

  if (resolveDoc(trimmed)) return trimmed;

  const indexAccess = splitTrailingIndexAccess(trimmed);
  if (indexAccess) {
    const collectionType = inferExpressionTypeRaw(
      document,
      position,
      indexAccess.receiver
    );
    return collectionType ? elementTypeOf(collectionType) : undefined;
  }

  const methodCall = splitTrailingMethodCall(trimmed);
  if (methodCall) {
    const receiverType = inferExpressionType(document, position, methodCall.receiver);
    return receiverType
      ? standardMemberReturnType(receiverType, methodCall.method)
      : undefined;
  }

  const memberAccess = splitTrailingMemberAccess(trimmed);
  if (memberAccess) {
    const receiverType = inferExpressionType(document, position, memberAccess.receiver);
    return receiverType
      ? standardMemberReturnType(receiverType, memberAccess.member)
      : undefined;
  }

  if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(trimmed)) {
    return baseTypeName(inferVariableTypeRaw(document, position, trimmed) ?? trimmed);
  }

  return undefined;
}

function inferExpressionTypeRaw(
  document: vscode.TextDocument,
  position: vscode.Position,
  expression: string
): string | undefined {
  const trimmed = trimOuterParens(expression.trim());
  if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(trimmed)) {
    return inferVariableTypeRaw(document, position, trimmed) ?? trimmed;
  }
  return inferExpressionType(document, position, trimmed);
}

function splitTrailingIndexAccess(
  expression: string
): { receiver: string } | undefined {
  if (!expression.endsWith("]")) return undefined;
  let depth = 0;
  for (let i = expression.length - 1; i >= 0; i--) {
    const ch = expression[i];
    if (ch === "]") depth++;
    if (ch === "[") {
      depth--;
      if (depth === 0) {
        const receiver = expression.slice(0, i).trim();
        return receiver ? { receiver } : undefined;
      }
    }
  }
  return undefined;
}

function splitTrailingMethodCall(
  expression: string
): { receiver: string; method: string } | undefined {
  if (!expression.endsWith(")")) return undefined;
  const openParen = matchingOpenParen(expression, expression.length - 1);
  if (openParen === undefined) return undefined;

  let nameEnd = openParen;
  let nameStart = nameEnd;
  while (nameStart > 0 && /[A-Za-z0-9_]/.test(expression[nameStart - 1])) {
    nameStart--;
  }
  if (nameStart === nameEnd) return undefined;

  let dot = nameStart - 1;
  while (dot >= 0 && /\s/.test(expression[dot])) dot--;
  if (dot < 0 || expression[dot] !== ".") return undefined;

  const receiver = expression.slice(0, dot).replace(/\?$/, "").trim();
  const method = expression.slice(nameStart, nameEnd);
  return receiver ? { receiver, method } : undefined;
}

function splitTrailingMemberAccess(
  expression: string
): { receiver: string; member: string } | undefined {
  let end = expression.length;
  while (end > 0 && /\s/.test(expression[end - 1])) end--;

  let nameStart = end;
  while (nameStart > 0 && /[A-Za-z0-9_]/.test(expression[nameStart - 1])) {
    nameStart--;
  }
  if (nameStart === end) return undefined;

  let dot = nameStart - 1;
  while (dot >= 0 && /\s/.test(expression[dot])) dot--;
  if (dot < 0 || expression[dot] !== ".") return undefined;

  const receiver = expression.slice(0, dot).replace(/\?$/, "").trim();
  const member = expression.slice(nameStart, end);
  return receiver ? { receiver, member } : undefined;
}

function matchingOpenParen(expression: string, closeParen: number): number | undefined {
  let depth = 0;
  for (let i = closeParen; i >= 0; i--) {
    const ch = expression[i];
    if (ch === ")") depth++;
    if (ch === "(") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return undefined;
}

function trimOuterParens(expression: string): string {
  let current = expression;
  while (current.startsWith("(") && current.endsWith(")")) {
    const open = matchingOpenParen(current, current.length - 1);
    if (open !== 0) break;
    current = current.slice(1, -1).trim();
  }
  return current;
}

function inferVariableTypeRaw(
  document: vscode.TextDocument,
  position: vscode.Position,
  variableName: string
): string | undefined {
  const before = document.getText(
    new vscode.Range(new vscode.Position(0, 0), position)
  );
  const escapedName = escapeRegExp(variableName);
  const decl = new RegExp(
    `\\b([A-Za-z_][A-Za-z0-9_]*(?:\\s*<[^;{}()=\\n]+>)?)\\s+${escapedName}\\b`,
    "g"
  );

  let typeName: string | undefined;
  let match: RegExpExecArray | null;
  while ((match = decl.exec(before)) !== null) {
    typeName = match[1];
  }
  return typeName;
}

function baseTypeName(raw: string): string {
  return raw.replace(/\s+/g, "").replace(/<.*$/, "");
}

function elementTypeOf(raw: string): string | undefined {
  const compact = raw.replace(/\s+/g, "");
  const listInner = genericInner(compact, "List");
  if (listInner) return listInner;
  const setInner = genericInner(compact, "Set");
  if (setInner) return setInner;
  if (compact.endsWith("[]")) return compact.slice(0, -2);
  return undefined;
}

function genericInner(typeName: string, base: string): string | undefined {
  const prefix = `${base}<`;
  if (!typeName.startsWith(prefix) || !typeName.endsWith(">")) return undefined;
  return typeName.slice(prefix.length, -1);
}

function standardMemberReturnType(
  receiverType: string,
  memberName: string
): string | undefined {
  const base = baseTypeName(receiverType);
  const key = memberName.toLowerCase();
  if (base === "Map") {
    if (key === "keyset") return "Set";
    if (key === "values") return "List";
    if (key === "get" || key === "put" || key === "remove") return "Object";
  }
  if (base === "List" || base === "Set") {
    if (base === "List" && key === "getsobjecttype") return "Schema.SObjectType";
    if (key === "clone") return base;
    if (key === "get" || key === "remove") return "Object";
  }
  if (base === "Id" && key === "getsobjecttype") return "Schema.SObjectType";
  if (base === "SObject") {
    if (key === "getsobjecttype") return "Schema.SObjectType";
    if (key === "get" || key === "put" || key === "clone") return "Object";
  }
  if (base === "SObjectType" || base === "Schema.SObjectType") {
    if (key === "getdescribe") return "Schema.DescribeSObjectResult";
    if (key === "newsobject") return "SObject";
  }
  if (
    base === "DescribeSObjectResult" ||
    base === "Schema.DescribeSObjectResult"
  ) {
    if (key === "getsobjecttype") return "Schema.SObjectType";
    if (key === "getname" || key === "getlabel" || key === "getlabelplural") return "String";
    if (key === "fields") return "Object";
  }
  if (base === "SObjectField" || base === "Schema.SObjectField") {
    if (key === "getdescribe") return "Schema.DescribeFieldResult";
  }
  if (
    base === "DescribeFieldResult" ||
    base === "Schema.DescribeFieldResult"
  ) {
    if (key === "getsobjectfield") return "Schema.SObjectField";
    if (key === "getreferenceTo") return "List";
  }
  if (base === "Type") {
    if (key === "forname") return "Type";
    if (key === "newinstance") return "Object";
    if (key === "getname") return "String";
  }
  if (base === "Schema") {
    if (key === "sobjecttype") return "Schema.SObjectType";
  }
  if (key === "getsobjecttype" || key === "sobjecttype") {
    return "Schema.SObjectType";
  }
  if (base === "String") return "String";
  return undefined;
}

function resolveDoc(name: string): ApexReferenceDoc | undefined {
  const exact = APEX_REFERENCE_DOCS[name];
  if (exact) return exact;
  const lower = name.toLowerCase();
  return Object.values(APEX_REFERENCE_DOCS).find(
    (entry) => entry.name.toLowerCase() === lower
  );
}

function doc(name: string, page: string): ApexReferenceDoc {
  return {
    name,
    url: `${APEX_REF_BASE}${page}`,
  };
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function escapeMarkdown(value: string): string {
  return value.replace(/([\\`*_{}\[\]()#+\-.!])/g, "\\$1");
}
