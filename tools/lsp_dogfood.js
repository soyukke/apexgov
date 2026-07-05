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
const fixturesRoot = path.resolve(
  repoRoot,
  args.fixturesRoot || ".local-fixtures/apex/repos"
);
const defaultRepos = [
  "apex-recipes-latest",
  "fflib-apex-common-latest",
  "fflib-apex-mocks",
  "apex-trigger-actions-framework-no-formulafilter",
  "NebulaLogger",
  "apex-unified-logging",
];
const repoNames = selectedRepoNames();
const maxFiles = Number(args.maxFiles || 20);
const maxQualified = Number(args.maxQualified || 30);
const maxPerFile = Number(args.maxPerFile || 8);
const maxRenames = Number(args.maxRenames || 12);
const strict = Boolean(args.strict);
const isTestOnly = Boolean(args.isTestOnly);

class LspClient {
  constructor(command, rootUri, cwd) {
    this.proc = cp.spawn(command, ["lsp"], {
      cwd,
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
    this.proc.on("exit", (code, signal) => {
      for (const [id, entry] of this.pending) {
        clearTimeout(entry.timer);
        entry.reject(new Error(`server exited during ${entry.method}: code=${code} signal=${signal}`));
        this.pending.delete(id);
      }
    });
  }

  async initialize() {
    const result = await this.request("initialize", {
      processId: process.pid,
      rootUri: this.rootUri,
      capabilities: {},
    }, 30000);
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
}

async function main() {
  if (!fs.existsSync(serverPath)) throw new Error(`LSP server not found: ${serverPath}`);

  const totals = {
    repos: 0,
    files: 0,
    requests: 0,
    expectedDefinitions: 0,
    missingExpectedDefinitions: 0,
    expectedOwnerDefinitions: 0,
    missingExpectedOwnerDefinitions: 0,
    expectedReferences: 0,
    missingExpectedReferences: 0,
    expectedHovers: 0,
    missingExpectedHovers: 0,
    expectedSignatures: 0,
    missingExpectedSignatures: 0,
    expectedCompletions: 0,
    missingExpectedCompletions: 0,
    expectedRenames: 0,
    missingExpectedRenames: 0,
    expectedCodeLenses: 0,
    missingExpectedCodeLenses: 0,
    documentsWithSymbols: 0,
    emptyDocumentSymbols: 0,
    hardFailures: 0,
  };
  const allFailures = [];
  const allWarnings = [];

  for (const repoName of repoNames) {
    const repoPath = path.join(fixturesRoot, repoName);
    if (!fs.existsSync(repoPath)) {
      allWarnings.push(`${repoName}: missing repo at ${repoPath}`);
      continue;
    }
    const result = await dogfoodRepo(repoName, repoPath);
    totals.repos += 1;
    totals.files += result.files;
    totals.requests += result.requests;
    totals.expectedDefinitions += result.expectedDefinitions;
    totals.missingExpectedDefinitions += result.missingExpectedDefinitions;
    totals.expectedOwnerDefinitions += result.expectedOwnerDefinitions;
    totals.missingExpectedOwnerDefinitions += result.missingExpectedOwnerDefinitions;
    totals.expectedReferences += result.expectedReferences;
    totals.missingExpectedReferences += result.missingExpectedReferences;
    totals.expectedHovers += result.expectedHovers;
    totals.missingExpectedHovers += result.missingExpectedHovers;
    totals.expectedSignatures += result.expectedSignatures;
    totals.missingExpectedSignatures += result.missingExpectedSignatures;
    totals.expectedCompletions += result.expectedCompletions;
    totals.missingExpectedCompletions += result.missingExpectedCompletions;
    totals.expectedRenames += result.expectedRenames;
    totals.missingExpectedRenames += result.missingExpectedRenames;
    totals.expectedCodeLenses += result.expectedCodeLenses;
    totals.missingExpectedCodeLenses += result.missingExpectedCodeLenses;
    totals.documentsWithSymbols += result.documentsWithSymbols;
    totals.emptyDocumentSymbols += result.emptyDocumentSymbols;
    totals.hardFailures += result.failures.length;
    allFailures.push(...result.failures);
    allWarnings.push(...result.warnings);
    console.log(
      `${repoName}: ${result.files} files, ${result.requests} requests, ` +
      `memberDefs=${passed(result.expectedDefinitions, result.missingExpectedDefinitions)} ` +
      `refs=${passed(result.expectedReferences, result.missingExpectedReferences)}`
    );
  }

  for (const warning of allWarnings.slice(0, 80)) console.warn(`warn: ${warning}`);
  if (allWarnings.length > 80) console.warn(`warn: ... ${allWarnings.length - 80} more`);

  for (const failure of allFailures.slice(0, 80)) console.error(`fail: ${failure}`);
  if (allFailures.length > 80) console.error(`fail: ... ${allFailures.length - 80} more`);

  console.log(
    `LSP dogfood: repos=${totals.repos} files=${totals.files} requests=${totals.requests} ` +
    `memberDefs=${passed(totals.expectedDefinitions, totals.missingExpectedDefinitions)} ` +
    `ownerDefs=${passed(totals.expectedOwnerDefinitions, totals.missingExpectedOwnerDefinitions)} ` +
    `refs=${passed(totals.expectedReferences, totals.missingExpectedReferences)} ` +
    `hovers=${passed(totals.expectedHovers, totals.missingExpectedHovers)} ` +
    `signatures=${passed(totals.expectedSignatures, totals.missingExpectedSignatures)} ` +
    `completions=${passed(totals.expectedCompletions, totals.missingExpectedCompletions)} ` +
    `renames=${passed(totals.expectedRenames, totals.missingExpectedRenames)} ` +
    `codeLens=${passed(totals.expectedCodeLenses, totals.missingExpectedCodeLenses)} ` +
    `documentSymbols=${passed(totals.documentsWithSymbols, totals.emptyDocumentSymbols)}`
  );

  if (totals.hardFailures > 0 || (strict && totals.missingExpectedDefinitions > 0)) {
    process.exitCode = 1;
  }
}

function selectedRepoNames() {
  if (args.allRepos) {
    if (!fs.existsSync(fixturesRoot)) return [];
    return fs.readdirSync(fixturesRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
  }
  return (args.repos ? args.repos.split(",") : defaultRepos).filter(Boolean);
}

function passed(total, missing) {
  return `${total - missing}/${total}`;
}

async function dogfoodRepo(repoName, repoPath) {
  const classIndex = buildClassIndex(repoPath);
  const files = isTestOnly
    ? sampleIsTestFiles(collectApexFiles(repoPath), maxFiles)
    : sampleFiles(collectApexFiles(repoPath), maxFiles);
  const client = new LspClient(serverPath, pathToFileURL(repoPath).toString(), repoPath);
  const result = {
    files: files.length,
    requests: 0,
    expectedDefinitions: 0,
    missingExpectedDefinitions: 0,
    expectedOwnerDefinitions: 0,
    missingExpectedOwnerDefinitions: 0,
    expectedReferences: 0,
    missingExpectedReferences: 0,
    expectedHovers: 0,
    missingExpectedHovers: 0,
    expectedSignatures: 0,
    missingExpectedSignatures: 0,
    expectedCompletions: 0,
    missingExpectedCompletions: 0,
    expectedRenames: 0,
    missingExpectedRenames: 0,
    expectedCodeLenses: 0,
    missingExpectedCodeLenses: 0,
    documentsWithSymbols: 0,
    emptyDocumentSymbols: 0,
    failures: [],
    warnings: [],
  };
  let renameChecks = 0;

  try {
    const init = await client.initialize();
    if (!init.capabilities || !init.capabilities.definitionProvider) {
      result.failures.push(`${repoName}: initialize did not advertise definitions`);
    }

    const docs = files.map((file) => ({
      file,
      uri: pathToFileURL(file).toString(),
      text: fs.readFileSync(file, "utf8"),
    }));
    for (const doc of docs) openDoc(client, doc);
    await sleep(150);

    for (const doc of docs) {
      const symbols = await safeRequest(result, repoName, doc, client, "textDocument/documentSymbol", {
        textDocument: { uri: doc.uri },
      });
      const declarationPositions = declarationProbePositions(doc.text);
      if (declarationPositions.length > 0) {
        result.documentsWithSymbols += 1;
        if (!Array.isArray(symbols) || symbols.length === 0) {
          result.emptyDocumentSymbols += 1;
          result.failures.push(
            `${repoName}: empty document symbols for ${relative(repoPath, doc.file)}`
          );
        }
      }

      await safeRequest(result, repoName, doc, client, "textDocument/foldingRange", {
        textDocument: { uri: doc.uri },
      });
      await safeRequest(result, repoName, doc, client, "textDocument/semanticTokens/full", {
        textDocument: { uri: doc.uri },
      });

      const testLensExpectation = expectedCodeLensCounts(doc.text);
      if (testLensExpectation.total > 0) {
        const lenses = await safeRequest(result, repoName, doc, client, "textDocument/codeLens", {
          textDocument: { uri: doc.uri },
        });
        const actual = codeLensCounts(lenses);
        result.expectedCodeLenses += testLensExpectation.total;
        const missing = Math.max(0, testLensExpectation.total - actual.total);
        result.missingExpectedCodeLenses += missing;
        if (missing > 0) {
          result.failures.push(
            `${repoName}: codeLens expected ${testLensExpectation.total} got ${actual.total} ` +
            `for ${relative(repoPath, doc.file)}`
          );
        }
        if (actual.runTest < testLensExpectation.runTest) {
          result.failures.push(
            `${repoName}: codeLens runTest expected ${testLensExpectation.runTest} ` +
            `got ${actual.runTest} for ${relative(repoPath, doc.file)}`
          );
        }
        if (actual.runAllTests < testLensExpectation.runAllTests) {
          result.failures.push(
            `${repoName}: codeLens runAllTests expected ${testLensExpectation.runAllTests} ` +
            `got ${actual.runAllTests} for ${relative(repoPath, doc.file)}`
          );
        }
      }

      for (const pos of declarationPositions.slice(0, maxPerFile)) {
        const hover = await safeRequest(result, repoName, doc, client, "textDocument/hover", {
          textDocument: { uri: doc.uri },
          position: positionAt(doc.text, pos),
        });
        result.expectedHovers += 1;
        if (!hasHoverContent(hover)) {
          result.missingExpectedHovers += 1;
          result.failures.push(
            `${repoName}: empty hover at declaration in ${relative(repoPath, doc.file)}`
          );
        }
      }

      for (const probe of completionProbes(doc.text).slice(0, maxPerFile)) {
        const completion = await safeRequest(result, repoName, doc, client, "textDocument/completion", {
          textDocument: { uri: doc.uri },
          position: positionAt(doc.text, probe.pos),
          context: { triggerKind: 1 },
        });
        const labels = completionLabels(completion);
        for (const label of probe.expectedLabels) {
          result.expectedCompletions += 1;
          if (!labels.has(label)) {
            result.missingExpectedCompletions += 1;
            result.failures.push(
              `${repoName}: completion after ${probe.receiver}. missing ${label} in ` +
              `${relative(repoPath, doc.file)}`
            );
          }
        }
      }

      const qualified = qualifiedCallProbes(doc.text).slice(0, maxQualified);
      for (const probe of qualified) {
        const expectedMember = classIndex.hasMethod(probe.owner, probe.member);

        if (classIndex.hasClass(probe.owner)) {
          const ownerDef = await safeRequest(result, repoName, doc, client, "textDocument/definition", {
            textDocument: { uri: doc.uri },
            position: positionAt(doc.text, probe.ownerEnd),
          });
          result.expectedOwnerDefinitions += 1;
          if (!ownerDef) {
            result.missingExpectedOwnerDefinitions += 1;
            result.failures.push(
              `${repoName}: missing definition for owner ${probe.owner} in ` +
              `${relative(repoPath, doc.file)}`
            );
          }
        }

        const hover = await safeRequest(result, repoName, doc, client, "textDocument/hover", {
          textDocument: { uri: doc.uri },
          position: positionAt(doc.text, probe.memberStart),
        });

        const def = await safeRequest(result, repoName, doc, client, "textDocument/definition", {
          textDocument: { uri: doc.uri },
          position: positionAt(doc.text, probe.memberEnd),
        });
        if (expectedMember) {
          result.expectedHovers += 1;
          if (!hasHoverContent(hover)) {
            result.missingExpectedHovers += 1;
            result.failures.push(
              `${repoName}: empty hover for ${probe.owner}.${probe.member} in ` +
              `${relative(repoPath, doc.file)}`
            );
          }

          result.expectedDefinitions += 1;
          if (!def) {
            result.missingExpectedDefinitions += 1;
            result.failures.push(
              `${repoName}: missing definition for ${probe.owner}.${probe.member} in ${relative(repoPath, doc.file)}`
            );
          }
        }

        const signature = await safeRequest(result, repoName, doc, client, "textDocument/signatureHelp", {
          textDocument: { uri: doc.uri },
          position: positionAt(doc.text, probe.callOpen + 1),
          context: { triggerKind: 1 },
        });
        if (expectedMember) {
          result.expectedSignatures += 1;
          if (!hasSignature(signature)) {
            result.missingExpectedSignatures += 1;
            result.failures.push(
              `${repoName}: missing signatureHelp for ${probe.owner}.${probe.member} in ` +
              `${relative(repoPath, doc.file)}`
            );
          }

          const refs = await safeRequest(result, repoName, doc, client, "textDocument/references", {
            textDocument: { uri: doc.uri },
            position: positionAt(doc.text, probe.memberEnd),
            context: { includeDeclaration: true },
          });
          result.expectedReferences += 1;
          if (!hasLocationAt(refs, doc.uri, positionAt(doc.text, probe.memberStart))) {
            result.missingExpectedReferences += 1;
            result.failures.push(
              `${repoName}: references for ${probe.owner}.${probe.member} do not include use in ` +
              `${relative(repoPath, doc.file)}`
            );
          }

          if (renameChecks < maxRenames) {
            renameChecks += 1;
            const rename = await safeRequest(result, repoName, doc, client, "textDocument/rename", {
              textDocument: { uri: doc.uri },
              position: positionAt(doc.text, probe.memberEnd),
              newName: "__apexgovDogfoodRename",
            });
            result.expectedRenames += 1;
            if (!hasWorkspaceEdit(rename)) {
              result.missingExpectedRenames += 1;
              result.failures.push(
                `${repoName}: rename returned no edits for ${probe.owner}.${probe.member} in ` +
                `${relative(repoPath, doc.file)}`
              );
            }
          }
        }
      }
    }
  } finally {
    await client.shutdown();
  }

  return result;
}

async function safeRequest(result, repoName, doc, client, method, params) {
  result.requests += 1;
  try {
    return await client.request(method, params);
  } catch (err) {
    result.failures.push(`${repoName}: ${method} failed for ${relative(process.cwd(), doc.file)}: ${err.message}`);
    return null;
  }
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

function collectApexFiles(root) {
  const out = [];
  walk(root, (file) => {
    if (file.endsWith(".cls") || file.endsWith(".trigger")) out.push(file);
  });
  return out.sort();
}

function walk(root, visit) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (entry.name === ".git" || entry.name === "node_modules" || entry.name === ".sfdx") continue;
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) walk(full, visit);
    else if (entry.isFile()) visit(full);
  }
}

function sampleFiles(files, limit) {
  if (files.length <= limit) return files;
  const selected = [];
  const step = (files.length - 1) / Math.max(1, limit - 1);
  for (let i = 0; i < limit; i++) {
    selected.push(files[Math.round(i * step)]);
  }
  return [...new Set(selected)];
}

function sampleIsTestFiles(files, limit) {
  const scored = [];
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const expectation = expectedCodeLensCounts(text);
    if (expectation.total === 0) continue;
    scored.push({ file, score: isTestComplexityScore(text, expectation) });
  }
  scored.sort((a, b) => b.score - a.score || a.file.localeCompare(b.file));
  return scored.slice(0, limit).map((entry) => entry.file);
}

function isTestComplexityScore(text, expectation) {
  const lines = text.split(/\r?\n/).length;
  const asserts = (text.match(/\b(?:System\.)?Assert\b|\bSystem\.assert/g) || []).length;
  const mocks = (
    text.match(/\bMock\b|\bStub\b|Test\.startTest|Test\.stopTest|@testSetup/gi) || []
  ).length;
  const soql = (text.match(/\[\s*SELECT\b/gi) || []).length;
  const dml = (text.match(/\b(?:insert|update|upsert|delete|undelete)\b/gi) || []).length;
  return expectation.runTest * 30 + expectation.runAllTests * 20 +
    Math.min(lines, 3000) / 10 + asserts * 2 + mocks * 8 + soql * 4 + dml * 3;
}

function buildClassIndex(root) {
  const classes = new Map();
  for (const file of collectApexFiles(root)) {
    const text = fs.readFileSync(file, "utf8");
    const code = maskNonCode(text);
    for (const block of classBlocks(code)) {
      const methods = new Set();
      for (const method of methodDeclarations(block.body)) methods.add(method.toLowerCase());
      classes.set(block.name.toLowerCase(), { name: block.name, file, methods });
    }
  }
  return {
    hasClass(owner) {
      return classes.has(owner.toLowerCase());
    },
    hasMethod(owner, member) {
      const cls = classes.get(owner.toLowerCase());
      return Boolean(cls && cls.methods.has(member.toLowerCase()));
    },
  };
}

function classBlocks(text) {
  const out = [];
  const re = /\b(?:class|interface)\s+([A-Za-z_][A-Za-z0-9_]*)\b/g;
  let match;
  while ((match = re.exec(text))) {
    const name = match[1];
    const open = text.indexOf("{", re.lastIndex);
    if (open < 0) continue;
    const close = matchingBrace(text, open);
    if (close < 0) continue;
    out.push({ name, body: text.slice(open + 1, close), bodyStart: open + 1 });
    re.lastIndex = close + 1;
  }
  return out;
}

function expectedCodeLensCounts(text) {
  const code = maskNonCode(text);
  let runTest = 0;
  let runAllTests = 0;
  for (const block of classBlocks(code)) {
    const methods = testMethodsInClass(block.body);
    if (methods > 0) {
      runTest += methods;
      runAllTests += 1;
    }
  }
  return { runTest, runAllTests, total: runTest + runAllTests };
}

function testMethodsInClass(body) {
  let count = 0;
  const methodRe = /((?:@\w+(?:\([^)]*\))?\s*)*)(?:public|private|protected|global|static|override|virtual|abstract|webservice|testMethod|final)\b(?:\s+(?:public|private|protected|global|static|override|virtual|abstract|webservice|testMethod|final))*\s+(?:[A-Za-z_][A-Za-z0-9_.<>?,\s\[\]]*|void)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
  let match;
  while ((match = methodRe.exec(body))) {
    const declaration = match[0];
    if (/@isTest\b/i.test(match[1]) || /\btestMethod\b/i.test(declaration)) count += 1;
  }
  return count;
}

function matchingBrace(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === "{") depth += 1;
    else if (c === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function methodDeclarations(text) {
  const out = [];
  const re = /\b(?:public|private|protected|global|static|override|virtual|abstract|webservice|testMethod|final)\b(?:\s+(?:public|private|protected|global|static|override|virtual|abstract|webservice|testMethod|final))*\s+(?:[A-Za-z_][A-Za-z0-9_.<>?,\s\[\]]*|void)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
  let match;
  while ((match = re.exec(text))) {
    const name = match[1];
    if (!controlWords.has(name)) out.push(name);
  }
  return out;
}

const controlWords = new Set(["if", "for", "while", "switch", "catch", "return", "new"]);

function declarationProbePositions(text) {
  const code = maskNonCode(text);
  const positions = [];
  const classRe = /\b(?:class|interface|enum|trigger)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let match;
  while ((match = classRe.exec(code))) positions.push(match.index + match[0].lastIndexOf(match[1]));

  const methodRe = /\b(?:public|private|protected|global|static|override|virtual|abstract|webservice|testMethod|final)\b(?:\s+(?:public|private|protected|global|static|override|virtual|abstract|webservice|testMethod|final))*\s+(?:[A-Za-z_][A-Za-z0-9_.<>?,\s\[\]]*|void)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
  for (const block of classBlocks(code)) {
    methodRe.lastIndex = 0;
    while ((match = methodRe.exec(block.body))) {
      positions.push(block.bodyStart + match.index + match[0].lastIndexOf(match[1]));
    }
  }
  return positions;
}

function completionProbes(text) {
  const code = maskNonCode(text);
  const probes = [];
  const re = /\b(?:System|Schema|Type|Database|Limits|Account|Contact|String|Id)\./g;
  let match;
  while ((match = re.exec(code))) {
    const receiver = match[0].slice(0, -1);
    const expectedLabels = completionExpectedLabels(receiver);
    if (expectedLabels.length === 0) continue;
    probes.push({
      receiver,
      expectedLabels,
      pos: match.index + match[0].length,
    });
  }
  return probes;
}

function completionExpectedLabels(receiver) {
  switch (receiver.toLowerCase()) {
    case "system": return ["debug"];
    case "schema": return ["getGlobalDescribe"];
    case "type": return ["forName"];
    case "database": return ["query"];
    case "limits": return ["getCpuTime"];
    case "account": return ["Id", "Name", "getSObjectType"];
    case "contact": return ["LastName", "Email"];
    case "id": return ["getSObjectType"];
    default: return [];
  }
}

function qualifiedCallProbes(text) {
  const code = maskNonCode(text);
  const probes = [];
  const re = /\b([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
  let match;
  while ((match = re.exec(code))) {
    const owner = match[1];
    const member = match[2];
    if (match.index > 0 && (code[match.index - 1] === "." || code[match.index - 1] === "?")) {
      continue;
    }
    if (stdlibOwners.has(owner)) continue;
    const ownerStart = match.index;
    const memberStart = ownerStart + owner.length + 1;
    probes.push({
      owner,
      member,
      ownerStart,
      ownerEnd: ownerStart + owner.length,
      memberStart,
      memberEnd: memberStart + member.length,
      callOpen: match.index + match[0].lastIndexOf("("),
    });
  }
  return probes;
}

function hasHoverContent(hover) {
  if (!hover || !hover.contents) return false;
  if (typeof hover.contents === "string") return hover.contents.length > 0;
  if (typeof hover.contents.value === "string") return hover.contents.value.length > 0;
  if (Array.isArray(hover.contents)) return hover.contents.length > 0;
  return false;
}

function hasSignature(signature) {
  return Boolean(
    signature &&
    Array.isArray(signature.signatures) &&
    signature.signatures.length > 0
  );
}

function completionLabels(completion) {
  const labels = new Set();
  const items = Array.isArray(completion)
    ? completion
    : completion && Array.isArray(completion.items)
      ? completion.items
      : [];
  for (const item of items) {
    if (item && typeof item.label === "string") labels.add(item.label);
  }
  return labels;
}

function hasLocationAt(locations, uri, pos) {
  if (!Array.isArray(locations)) return false;
  return locations.some((loc) => (
    loc &&
    loc.uri === uri &&
    loc.range &&
    loc.range.start &&
    loc.range.start.line === pos.line &&
    loc.range.start.character === pos.character
  ));
}

function hasWorkspaceEdit(edit) {
  if (!edit || !edit.changes) return false;
  if (Array.isArray(edit.changes.edits)) return edit.changes.edits.length > 0;
  if (Array.isArray(edit.changes.entries)) {
    return edit.changes.entries.some((entry) => Array.isArray(entry.edits) && entry.edits.length > 0);
  }
  if (typeof edit.changes === "object") {
    return Object.values(edit.changes).some((edits) => Array.isArray(edits) && edits.length > 0);
  }
  return false;
}

function codeLensCounts(lenses) {
  const counts = { runTest: 0, runAllTests: 0, total: 0 };
  if (!Array.isArray(lenses)) return counts;
  for (const lens of lenses) {
    const command = lens && lens.command && lens.command.command;
    if (command === "apexgov.runTest") counts.runTest += 1;
    if (command === "apexgov.runAllTests") counts.runAllTests += 1;
  }
  counts.total = counts.runTest + counts.runAllTests;
  return counts;
}

function maskNonCode(text) {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    const next = text[i + 1];
    if (c === "/" && next === "/") {
      out += "  ";
      i += 2;
      while (i < text.length && text[i] !== "\n") {
        out += " ";
        i += 1;
      }
      continue;
    }
    if (c === "/" && next === "*") {
      out += "  ";
      i += 2;
      while (i < text.length) {
        if (text[i] === "*" && text[i + 1] === "/") {
          out += "  ";
          i += 2;
          break;
        }
        out += text[i] === "\n" ? "\n" : " ";
        i += 1;
      }
      continue;
    }
    if (c === "'") {
      out += " ";
      i += 1;
      while (i < text.length) {
        const ch = text[i];
        out += ch === "\n" ? "\n" : " ";
        i += 1;
        if (ch === "'") {
          if (text[i] === "'") {
            out += " ";
            i += 1;
            continue;
          }
          break;
        }
      }
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

const stdlibOwners = new Set([
  "System",
  "Schema",
  "Type",
  "Database",
  "Limits",
  "Test",
  "JSON",
  "Math",
  "String",
  "Datetime",
  "Date",
]);

function positionAt(text, index) {
  const before = text.slice(0, index);
  const lines = before.split(/\r?\n/);
  return { line: lines.length - 1, character: lines[lines.length - 1].length };
}

function relative(root, file) {
  return path.relative(root, file).replaceAll(path.sep, "/");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--server") out.server = argv[++i];
    else if (arg === "--fixtures-root") out.fixturesRoot = argv[++i];
    else if (arg === "--repos") out.repos = argv[++i];
    else if (arg === "--max-files") out.maxFiles = argv[++i];
    else if (arg === "--max-qualified") out.maxQualified = argv[++i];
    else if (arg === "--max-per-file") out.maxPerFile = argv[++i];
    else if (arg === "--max-renames") out.maxRenames = argv[++i];
    else if (arg === "--all-repos") out.allRepos = true;
    else if (arg === "--is-test-only") out.isTestOnly = true;
    else if (arg === "--strict") out.strict = true;
    else if (arg === "--help" || arg === "-h") {
      console.log(
        "usage: node tools/lsp_dogfood.js [--server zig-out/bin/apexgov] " +
        "[--repos a,b|--all-repos] [--max-files N] [--max-qualified N] " +
        "[--max-per-file N] [--max-renames N] [--is-test-only] [--strict]"
      );
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
