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
  Set: doc("Set", "apex_methods_system_set.htm"),
  SObject: doc("SObject", "apex_methods_system_sobject.htm"),
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
  const memberReceiver = receiverBeforeDot(document, range);

  if (memberReceiver) {
    const receiverType = resolveDoc(memberReceiver) ? memberReceiver : inferVariableType(
      document,
      range.start,
      memberReceiver
    );
    const docTarget = receiverType ? resolveDoc(receiverType) : undefined;
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

function receiverBeforeDot(
  document: vscode.TextDocument,
  range: vscode.Range
): string | undefined {
  const line = document.lineAt(range.start.line).text;
  let i = range.start.character - 1;
  while (i >= 0 && /\s/.test(line[i])) i--;
  if (i < 0 || line[i] !== ".") return undefined;

  i--;
  while (i >= 0 && /\s/.test(line[i])) i--;
  const end = i + 1;
  while (i >= 0 && /[A-Za-z0-9_]/.test(line[i])) i--;
  const start = i + 1;
  if (start >= end) return undefined;
  return line.slice(start, end);
}

function inferVariableType(
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
    typeName = baseTypeName(match[1]);
  }
  return typeName;
}

function baseTypeName(raw: string): string {
  return raw.replace(/\s+/g, "").replace(/<.*$/, "");
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
