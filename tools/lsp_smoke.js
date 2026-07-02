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
        "    public void run(Id recordId, List<SObject> records) {",
        "        Integer localValue = 1;",
        "        Integer copy = localValue;",
        "        this.recordCount = localValue;",
        "        helper();",
        "        this.helper();",
        "        Foo.helper();",
        "        recordId.getSObjectType();",
        "        records[0]?.getSObjectType();",
        "        Account.getSObjectType();",
        "        Schema.getGlobalDescribe();",
        "    }",
        "    /**",
        "     * Computes a value.",
        "     * @param label input label",
        "     * @return computed number",
        "     */",
        "    private static Integer helper(String label) { return 1; }",
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
  ];
}

async function checkDefinition(client, docs, report) {
  const foo = docs[0];
  const fieldDef = await definitionAt(client, foo, "recordCount = localValue");
  assertLine(fieldDef, foo, "recordCount;", "this.field definition");

  const helperDef = await definitionAt(client, foo, "helper();");
  assertLine(helperDef, foo, "helper(String label)", "bare same-class method definition");

  const caller = docs[1];
  const qualifiedDef = await definitionAt(client, caller, "helper('x')");
  assertLine(qualifiedDef, foo, "helper(String label)", "cross-file qualified method definition");
  report.push("definition: OK");
}

async function checkReferences(client, docs, report) {
  const foo = docs[0];
  const refsFromDef = await referencesAt(client, foo, "helper(String label)");
  assertEqual(refsFromDef.length, 5, "helper references from definition");
  const refsFromCall = await referencesAt(client, foo, "helper();");
  assertEqual(refsFromCall.length, 5, "helper references from call");

  const fieldRefs = await referencesAt(client, foo, "recordCount;");
  assertEqual(fieldRefs.length, 2, "field references");
  report.push("references: OK");
}

async function checkHover(client, docs, report) {
  const foo = docs[0];
  const hover = await hoverAt(client, foo, "helper(String label)");
  const value = hover && hover.contents && hover.contents.value;
  assertIncludes(value, "(method) helper: Integer", "hover signature");
  assertIncludes(value, "**Parameters**", "hover @param section");
  assertIncludes(value, "**Returns**", "hover @return section");
  report.push("hover: OK");
}

async function checkCompletion(client, docs, report) {
  const foo = docs[0];
  await expectCompletionLabels(client, foo, "recordId.", ["getSObjectType"]);
  await expectCompletionLabels(client, foo, "records[0]?.", ["getSObjectType"]);
  await expectCompletionLabels(client, foo, "Account.", ["getSObjectType", "SObjectType"]);
  await expectCompletionLabels(client, foo, "Schema.", ["getGlobalDescribe", "describeSObjects"]);
  report.push("completion: OK");
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
