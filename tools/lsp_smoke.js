#!/usr/bin/env node
"use strict";

const cp = require("child_process");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const repoRoot = path.resolve(__dirname, "..");
const args = parseArgs(process.argv.slice(2));
const serverPath = path.resolve(
  repoRoot,
  args.server || process.env.APEXGOV_LSP_SERVER || "zig-out/bin/apexgov"
);

class LspClient {
  constructor(command, rootUri) {
    this.proc = cp.spawn(command, ["lsp"], {
      cwd: repoRoot,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.rootUri = rootUri;
    this.nextId = 1;
    this.buffer = Buffer.alloc(0);
    this.pending = new Map();
    this.notifications = [];
    this.stderr = "";
    this.proc.stdout.on("data", (chunk) => this.onStdout(chunk));
    this.proc.stderr.on("data", (chunk) => {
      this.stderr += chunk.toString("utf8");
    });
  }

  async initialize() {
    const result = await this.request("initialize", {
      processId: process.pid,
      rootUri: this.rootUri,
      capabilities: {},
    });
    this.notify("initialized", {});
    return result;
  }

  async shutdown() {
    try {
      await this.request("shutdown", null, 5000);
    } catch (_) {
      // Best-effort shutdown.
    }
    this.notify("exit", {});
    this.proc.kill();
  }

  notify(method, params) {
    this.send({ jsonrpc: "2.0", method, params });
  }

  request(method, params, timeoutMs = 15000) {
    const id = this.nextId++;
    this.send({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
    });
  }

  send(message) {
    const body = Buffer.from(JSON.stringify(message), "utf8");
    this.proc.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.proc.stdin.write(body);
  }

  onStdout(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const sep = this.buffer.indexOf("\r\n\r\n");
      if (sep < 0) return;
      const header = this.buffer.slice(0, sep).toString("utf8");
      const match = /Content-Length: (\d+)/i.exec(header);
      if (!match) throw new Error(`bad LSP header: ${header}`);
      const len = Number(match[1]);
      const start = sep + 4;
      if (this.buffer.length < start + len) return;
      const body = this.buffer.slice(start, start + len).toString("utf8");
      this.buffer = this.buffer.slice(start + len);
      this.onMessage(JSON.parse(body));
    }
  }

  onMessage(message) {
    if (message.id !== undefined && this.pending.has(message.id)) {
      const entry = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error) {
        entry.reject(new Error(`${entry.method}: ${JSON.stringify(message.error)}`));
      } else {
        entry.resolve(message.result);
      }
      return;
    }
    if (message.method) this.notifications.push(message);
  }

  async waitForNotification(method, predicate, timeoutMs = 5000) {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
      const found = this.notifications.find((n) => {
        return n.method === method && (!predicate || predicate(n.params));
      });
      if (found) return found.params;
      await sleep(25);
    }
    throw new Error(`timeout waiting for notification ${method}`);
  }
}

async function main() {
  if (!fs.existsSync(serverPath)) {
    throw new Error(`LSP server not found: ${serverPath}`);
  }

  const rootUri = pathToFileURL(path.join(repoRoot, "tmp/lsp-smoke-workspace")).toString();
  const client = new LspClient(serverPath, rootUri);
  const report = [];
  try {
    const init = await client.initialize();
    ok(init.capabilities && init.capabilities.definitionProvider, "initialize capabilities", report);

    const docs = syntheticDocuments();
    for (const doc of docs) openDoc(client, doc);
    await sleep(150);

    await checkDefinition(client, docs, report);
    await checkReferences(client, docs, report);
    await checkHover(client, docs, report);
    await checkCompletion(client, docs, report);
    await checkLanguageServices(client, docs, report);
    await checkWorkspaceSymbol(client, report);
    await checkRename(client, docs, report);
    await checkDiagnosticsAndCodeAction(client, docs, report);
    await checkFullSyncChange(client, docs, report);
    await checkFixtureIfPresent(client, report);

    for (const line of report) console.log(line);
    console.log("LSP smoke: OK");
  } finally {
    await client.shutdown();
  }
}

function syntheticDocuments() {
  const root = path.join(repoRoot, "tmp/lsp-smoke-workspace");
  return [
    {
      uri: pathToFileURL(path.join(root, "Foo.cls")).toString(),
      text: [
        "public class Foo {",
        "    private Integer recordCount;",
        "    public static Integer staticCount;",
        "    public class Inner {",
        "        public void nestedRun() {",
        "            nestedHelper();",
        "        }",
        "        private void nestedHelper() {}",
        "    }",
        "    public void run(Id recordId, List<SObject> records) {",
        "        Integer localValue = 1;",
        "        Integer copy = localValue;",
        "        this.recordCount = localValue;",
        "        recordCount = copy;",
        "        Foo.staticCount = this.recordCount;",
        "        helper('local');",
        "        this.helper('this');",
        "        Foo.helper('qualified');",
        "        Integer zeroValue = helper();",
        "        recordId.getSObjectType();",
        "        records[0]?.getSObjectType();",
        "        Account.getSObjectType();",
        "        Schema.getGlobalDescribe();",
        "        Type dynamicMapType = Type.forName('Map<Id,' + String.valueOf(recordId) + '>');",
        "        System.debug(dynamicMapType);",
        "    }",
        "    /**",
        "     * Computes a value.",
        "     * @param label input label",
        "     * @return computed number",
        "     */",
        "    private static Integer helper(String label) { return 1; }",
        "    private static Integer helper() { return 0; }",
        "    @AuraEnabled(cacheable=true)",
        "    public static List<Account> exposedAccounts() { return null; }",
        "}",
        "",
      ].join("\n"),
    },
    {
      uri: pathToFileURL(path.join(root, "Caller.cls")).toString(),
      text: [
        "public class Caller {",
        "    public void run() {",
        "        Foo.helper('x');",
        "        Foo.exposedAccounts();",
        "        Foo.staticCount = 2;",
        "    }",
        "}",
        "",
      ].join("\n"),
    },
    {
      uri: pathToFileURL(path.join(root, "DiagnosticsProbe.cls")).toString(),
      text: [
        "public class DiagnosticsProbe {",
        "    public void bad() {",
        "        for (Integer i = 0; i < 3; i++) {",
        "            List<Account> accs = [SELECT Id FROM Account];",
        "        }",
        "    }",
        "}",
        "",
      ].join("\n"),
    },
    {
      uri: pathToFileURL(path.join(root, "EditProbe.cls")).toString(),
      text: "public class EditProbe { public void run() { Integer beforeName = 1; System.debug(beforeName); } }",
    },
    {
      uri: pathToFileURL(path.join(root, "TestProbe.cls")).toString(),
      text: [
        "@IsTest",
        "private class TestProbe {",
        "    @IsTest",
        "    static void shouldPass() {",
        "        System.assert(true);",
        "    }",
        "}",
        "",
      ].join("\n"),
    },
  ];
}

async function checkDefinition(client, docs, report) {
  const foo = docs[0];
  const fieldDef = await definitionAt(client, foo, "recordCount = localValue");
  assertLine(fieldDef, foo, "recordCount;", "this.field definition");

  const bareFieldDef = await definitionAt(client, foo, "recordCount = copy");
  assertLine(bareFieldDef, foo, "recordCount;", "bare field definition");

  const staticFieldDef = await definitionAt(client, docs[1], "staticCount = 2");
  assertLine(staticFieldDef, foo, "staticCount;", "cross-file static field definition");

  const localDef = await definitionAt(client, foo, "dynamicMapType);");
  assertLine(localDef, foo, "dynamicMapType = Type.forName", "Type local variable definition");

  const helperDef = await definitionAt(client, foo, "helper('local')");
  assertLine(helperDef, foo, "helper(String label)", "bare same-class method definition");

  const thisHelperDef = await definitionAt(client, foo, "helper('this')");
  assertLine(thisHelperDef, foo, "helper(String label)", "this.method definition");

  const innerHelperDef = await definitionAt(client, foo, "nestedHelper();");
  assertLine(innerHelperDef, foo, "nestedHelper() {}", "inner-class method definition");

  const overloadDef = await definitionAt(client, foo, "helper();");
  assertLine(overloadDef, foo, "helper() { return 0", "overloaded method definition by arity");

  const caller = docs[1];
  const qualifiedDef = await definitionAt(client, caller, "helper('x')");
  assertLine(qualifiedDef, foo, "helper(String label)", "cross-file qualified method definition");

  const auraStaticDef = await definitionAfter(client, caller, "exposedAccounts");
  assertLine(
    auraStaticDef,
    foo,
    "exposedAccounts()",
    "cross-file AuraEnabled static method definition at token end"
  );
  report.push("definition: OK");
}

async function checkReferences(client, docs, report) {
  const foo = docs[0];
  const refsFromDef = await referencesAt(client, foo, "helper(String label)");
  assertEqual(refsFromDef.length, 5, "helper references from definition");
  const refsFromCall = await referencesAt(client, foo, "helper('local')");
  assertEqual(refsFromCall.length, 5, "helper references from bare call");
  const refsFromThisCall = await referencesAt(client, foo, "helper('this')");
  assertEqual(refsFromThisCall.length, 5, "helper references from this call");
  const refsFromQualifiedCall = await referencesAt(client, docs[1], "helper('x')");
  assertEqual(refsFromQualifiedCall.length, 5, "helper references from cross-file call");

  const innerRefs = await referencesAt(client, foo, "nestedHelper() {}");
  assertEqual(innerRefs.length, 2, "inner-class method references");

  const refsFromDynamicType = await referencesAt(client, foo, "dynamicMapType);");
  assertEqual(refsFromDynamicType.length, 2, "Type local variable references");

  const refsFromStaticField = await referencesAt(client, docs[1], "staticCount = 2");
  assertEqual(refsFromStaticField.length, 3, "static field references");

  const refsFromZeroArgHelper = await referencesAt(client, foo, "helper() { return 0");
  assertEqual(refsFromZeroArgHelper.length, 2, "zero-arg overload references");

  const fieldRefs = await referencesAt(client, foo, "recordCount;");
  assertEqual(fieldRefs.length, 4, "field references");
  report.push("references: OK");
}

async function checkHover(client, docs, report) {
  const foo = docs[0];
  const hover = await hoverAt(client, foo, "helper(String label)");
  const value = hover && hover.contents && hover.contents.value;
  assertIncludes(value, "(method) helper: Integer", "hover signature");
  assertIncludes(value, "**Parameters**", "hover @param section");
  assertIncludes(value, "**Returns**", "hover @return section");

  const usageHover = await hoverAt(client, foo, "helper('local')");
  const usageValue = usageHover && usageHover.contents && usageHover.contents.value;
  assertIncludes(usageValue, "(method) helper: Integer", "hover on same-class call");
  assertIncludes(usageValue, "**Returns**", "hover docs on same-class call");

  const crossFileHover = await hoverAt(client, docs[1], "helper('x')");
  const crossFileValue = crossFileHover && crossFileHover.contents && crossFileHover.contents.value;
  assertIncludes(crossFileValue, "(method) helper: Integer", "hover on cross-file call");
  assertIncludes(crossFileValue, "**Parameters**", "hover docs on cross-file call");

  const fieldHover = await hoverAt(client, foo, "recordCount = copy");
  const fieldValue = fieldHover && fieldHover.contents && fieldHover.contents.value;
  assertIncludes(fieldValue, "(field) recordCount: Integer", "hover on bare field");
  report.push("hover: OK");
}

async function checkCompletion(client, docs, report) {
  const foo = docs[0];
  await expectCompletionLabels(client, foo, "recordId.", ["getSObjectType"]);
  await expectCompletionLabels(client, foo, "records[0]?.", ["getSObjectType"]);
  await expectCompletionLabels(client, foo, "Account.", ["getSObjectType", "SObjectType"]);
  await expectCompletionLabels(client, foo, "Schema.", ["getGlobalDescribe", "describeSObjects"]);
  await expectCompletionLabels(client, foo, "Type.", ["forName", "newInstance"]);
  report.push("completion: OK");
}

async function checkLanguageServices(client, docs, report) {
  const foo = docs[0];

  const docSymbols = await client.request("textDocument/documentSymbol", {
    textDocument: { uri: foo.uri },
  });
  assert(docSymbols.some((s) => s.name === "Foo"), "documentSymbol includes Foo");
  const fooSymbol = docSymbols.find((s) => s.name === "Foo");
  const childNames = (fooSymbol.children || []).map((s) => s.name);
  assert(childNames.includes("Inner"), "documentSymbol includes inner class");
  assert(childNames.includes("helper"), "documentSymbol includes helper method");

  const semantic = await client.request("textDocument/semanticTokens/full", {
    textDocument: { uri: foo.uri },
  });
  assert(Array.isArray(semantic.data) && semantic.data.length > 0, "semanticTokens returns data");

  const folds = await client.request("textDocument/foldingRange", {
    textDocument: { uri: foo.uri },
  });
  assert(folds.length >= 3, "foldingRange returns nested ranges");

  const edits = await client.request("textDocument/formatting", {
    textDocument: { uri: foo.uri },
    options: { tabSize: 4, insertSpaces: true },
  });
  assert(Array.isArray(edits) && edits.length === 1, "formatting returns one full-document edit");
  assertIncludes(edits[0].newText, "public class Foo", "formatting edit contains source");

  const signature = await client.request("textDocument/signatureHelp", {
    textDocument: { uri: foo.uri },
    position: positionAfter(foo.text, "helper('"),
  });
  assert(signature && signature.signatures && signature.signatures.length > 0, "signatureHelp returns helper signature");
  assertIncludes(signature.signatures[0].label, "helper", "signatureHelp labels helper");
  assertEqual(signature.signatures[0].parameters[0].label, "String label", "signatureHelp selects arity-matched overload");

  const highlights = await client.request("textDocument/documentHighlight", {
    textDocument: { uri: foo.uri },
    position: positionOf(foo.text, "helper('local')"),
  });
  assertEqual(highlights.length, 4, "documentHighlight returns same-file helper occurrences");

  const lenses = await client.request("textDocument/codeLens", {
    textDocument: { uri: docs[4].uri },
  });
  assert(lenses.some((l) => l.command && l.command.command === "apexgov.runTest"), "codeLens includes runTest");
  assert(lenses.some((l) => l.command && l.command.command === "apexgov.runAllTests"), "codeLens includes runAllTests");

  const commandResult = await client.request("workspace/executeCommand", {
    command: "apexgov.unknownCommand",
    arguments: [],
  });
  assert(commandResult === null || commandResult === undefined, "executeCommand ignores unknown command");

  report.push("languageServices: OK");
}

async function checkWorkspaceSymbol(client, report) {
  const symbols = await client.request("workspace/symbol", { query: "helper" });
  const names = symbols.map((s) => s.name);
  assert(names.includes("helper"), "workspace symbol finds helper");
  report.push("workspaceSymbol: OK");
}

async function checkRename(client, docs, report) {
  const foo = docs[0];
  const localEdit = await client.request("textDocument/rename", {
    textDocument: { uri: foo.uri },
    position: positionOf(foo.text, "localValue = 1"),
    newName: "renamedLocal",
  });
  const localEdits = localEdit && localEdit.changes && localEdit.changes[foo.uri];
  assertEqual(localEdits.length, 3, "local variable rename edit count");

  const memberEdit = await client.request("textDocument/rename", {
    textDocument: { uri: foo.uri },
    position: positionOf(foo.text, "helper(String label)"),
    newName: "renamedHelper",
  });
  assertEqual(
    editCount(memberEdit, foo.uri),
    4,
    "same-file member rename edit count"
  );
  assertEqual(
    editCount(memberEdit, docs[1].uri),
    1,
    "cross-file member rename edit count"
  );

  const fieldEdit = await client.request("textDocument/rename", {
    textDocument: { uri: foo.uri },
    position: positionOf(foo.text, "recordCount;"),
    newName: "renamedCount",
  });
  assertEqual(editCount(fieldEdit, foo.uri), 4, "field rename edit count");

  const staticFieldEdit = await client.request("textDocument/rename", {
    textDocument: { uri: foo.uri },
    position: positionOf(foo.text, "staticCount;"),
    newName: "renamedStaticCount",
  });
  assertEqual(editCount(staticFieldEdit, foo.uri), 2, "same-file static field rename edit count");
  assertEqual(editCount(staticFieldEdit, docs[1].uri), 1, "cross-file static field rename edit count");

  const zeroArgEdit = await client.request("textDocument/rename", {
    textDocument: { uri: foo.uri },
    position: positionOf(foo.text, "helper() { return 0"),
    newName: "renamedZeroHelper",
  });
  assertEqual(editCount(zeroArgEdit, foo.uri), 2, "zero-arg overload rename edit count");

  report.push("rename: OK");
}

async function checkDiagnosticsAndCodeAction(client, docs, report) {
  const diagDoc = docs[2];
  const params = await client.waitForNotification(
    "textDocument/publishDiagnostics",
    (p) => p.uri === diagDoc.uri && p.diagnostics.some((d) => d.code === "AG002"),
    5000
  );
  const ag002 = params.diagnostics.find((d) => d.code === "AG002");
  assert(ag002, "AG002 diagnostic is published");

  const actions = await client.request("textDocument/codeAction", {
    textDocument: { uri: diagDoc.uri },
    range: ag002.range,
    context: { diagnostics: params.diagnostics },
  });
  assert(actions.some((a) => a.title.includes("SOQL")), "SOQL quickfix is returned");
  report.push("diagnostics/codeAction: OK");
}

async function checkFullSyncChange(client, docs, report) {
  const doc = docs[3];
  const nextText = doc.text.replaceAll("beforeName", "afterName");
  client.notify("textDocument/didChange", {
    textDocument: { uri: doc.uri, version: 2 },
    contentChanges: [{ text: nextText }],
  });
  doc.text = nextText;
  await client.waitForNotification(
    "textDocument/publishDiagnostics",
    (p) => p.uri === doc.uri,
    5000
  );
  const refs = await referencesAt(client, doc, "afterName = 1");
  assertEqual(refs.length, 2, "full-sync change refreshes binding");
  report.push("sync: OK");
}

async function checkFixtureIfPresent(client, report) {
  const fixtureRoot = path.join(repoRoot, ".local-fixtures/apex/repos/apex-recipes");
  const collectionUtils = path.join(
    fixtureRoot,
    "force-app/main/default/classes/Collection Recipes/CollectionUtils.cls"
  );
  if (!fs.existsSync(collectionUtils)) {
    report.push("fixture(apex-recipes): skipped");
    return;
  }

  const doc = {
    uri: pathToFileURL(collectionUtils).toString(),
    text: fs.readFileSync(collectionUtils, "utf8"),
  };
  openDoc(client, doc);
  await sleep(150);
  const refs = await referencesAt(client, doc, "getSobjectTypeFromList(incomingList)");
  assertEqual(refs.length, 4, "fixture getSobjectTypeFromList references");
  await expectCompletionLabels(client, doc, "incomingList[0]?.", ["getSObjectType"]);
  report.push("fixture(apex-recipes): OK");
}

function openDoc(client, doc) {
  client.notify("textDocument/didOpen", {
    textDocument: {
      uri: doc.uri,
      languageId: "apex",
      version: 1,
      text: doc.text,
    },
  });
}

async function definitionAt(client, doc, needle) {
  return client.request("textDocument/definition", {
    textDocument: { uri: doc.uri },
    position: positionOf(doc.text, needle),
  });
}

async function definitionAfter(client, doc, needle) {
  return client.request("textDocument/definition", {
    textDocument: { uri: doc.uri },
    position: positionAfter(doc.text, needle),
  });
}

async function referencesAt(client, doc, needle) {
  return client.request("textDocument/references", {
    textDocument: { uri: doc.uri },
    position: positionOf(doc.text, needle),
    context: { includeDeclaration: true },
  });
}

async function hoverAt(client, doc, needle) {
  return client.request("textDocument/hover", {
    textDocument: { uri: doc.uri },
    position: positionOf(doc.text, needle),
  });
}

async function expectCompletionLabels(client, doc, needle, expectedLabels) {
  const result = await client.request("textDocument/completion", {
    textDocument: { uri: doc.uri },
    position: positionAfter(doc.text, needle),
    context: { triggerKind: 1 },
  });
  const labels = (result.items || result || []).map((item) => item.label);
  for (const label of expectedLabels) {
    assert(labels.includes(label), `completion after ${needle} includes ${label}`);
  }
}

function assertLine(location, expectedDoc, expectedNeedle, label) {
  assert(location, `${label}: missing location`);
  assertEqual(location.uri, expectedDoc.uri, `${label}: uri`);
  assertEqual(
    location.range.start.line,
    positionOf(expectedDoc.text, expectedNeedle).line,
    `${label}: line`
  );
}

function editCount(edit, uri) {
  const edits = edit && edit.changes && edit.changes[uri];
  return Array.isArray(edits) ? edits.length : 0;
}

function positionOf(text, needle) {
  const idx = text.indexOf(needle);
  if (idx < 0) throw new Error(`needle not found: ${needle}`);
  return positionAt(text, idx);
}

function positionAfter(text, needle) {
  const idx = text.indexOf(needle);
  if (idx < 0) throw new Error(`needle not found: ${needle}`);
  return positionAt(text, idx + needle.length);
}

function positionAt(text, index) {
  const before = text.slice(0, index);
  const lines = before.split(/\r?\n/);
  return { line: lines.length - 1, character: lines[lines.length - 1].length };
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertIncludes(value, expected, message) {
  assert(typeof value === "string" && value.includes(expected), `${message}: missing ${expected}`);
}

function ok(condition, message, report) {
  assert(condition, message);
  report.push(`${message}: OK`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--server") out.server = argv[++i];
    else if (arg === "--help" || arg === "-h") {
      console.log("usage: node tools/lsp_smoke.js [--server zig-out/bin/apexgov]");
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return out;
}

main().catch((err) => {
  console.error(err.stack || err.message);
  process.exit(1);
});
