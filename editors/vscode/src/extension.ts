import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";
import * as os from "os";
import * as https from "https";
import { execSync } from "child_process";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

const outputChannel = vscode.window.createOutputChannel("apexgov");

export async function activate(context: vscode.ExtensionContext) {
  outputChannel.appendLine("apexgov: activating...");

  let serverPath: string | undefined;
  try {
    serverPath = await ensureServer(context);
  } catch (e) {
    outputChannel.appendLine(`apexgov: ensureServer failed: ${e}`);
    vscode.window.showErrorMessage(`apexgov: ${e}`);
    return;
  }

  if (!serverPath) {
    outputChannel.appendLine("apexgov: server binary not found");
    vscode.window.showErrorMessage(
      "apexgov: Failed to find or download the server binary."
    );
    return;
  }

  outputChannel.appendLine(`apexgov: using server at ${serverPath}`);

  const serverOptions: ServerOptions = {
    command: serverPath,
    args: ["lsp"],
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "apex" },
      { scheme: "file", pattern: "**/*.cls" },
      { scheme: "file", pattern: "**/*.trigger" },
    ],
    outputChannel,
    middleware: {
      provideDocumentSemanticTokens: () => undefined,
      provideDocumentSemanticTokensEdits: () => undefined,
    },
  };

  client = new LanguageClient(
    "apexgov",
    "apexgov LSP",
    serverOptions,
    clientOptions
  );

  try {
    await client.start();
    outputChannel.appendLine("apexgov: LSP client started");
  } catch (e) {
    outputChannel.appendLine(`apexgov: LSP client failed to start: ${e}`);
    vscode.window.showErrorMessage(`apexgov: LSP failed to start: ${e}`);
  }
}

export async function deactivate() {
  if (client) {
    await client.stop();
  }
}

async function ensureServer(
  context: vscode.ExtensionContext
): Promise<string | undefined> {
  // 1. User-configured path
  const configPath = vscode.workspace
    .getConfiguration("apexgov")
    .get<string>("serverPath");
  if (configPath && fs.existsSync(configPath)) {
    return configPath;
  }

  // 2. Already downloaded binary (re-download if extension version changed)
  const binDir = path.join(context.globalStorageUri.fsPath, "bin");
  const binName = process.platform === "win32" ? "apexgov.exe" : "apexgov";
  const binPath = path.join(binDir, binName);
  const versionFile = path.join(binDir, ".version");
  const currentVersion = context.extension.packageJSON.version as string;

  if (fs.existsSync(binPath)) {
    const storedVersion = fs.existsSync(versionFile)
      ? fs.readFileSync(versionFile, "utf-8").trim()
      : "";
    if (storedVersion === currentVersion) {
      return binPath;
    }
    outputChannel.appendLine(
      `apexgov: version mismatch (${storedVersion || "unknown"} -> ${currentVersion}), re-downloading...`
    );
  }

  // 3. Download from GitHub Releases
  return await downloadServer(binDir, binPath, versionFile, currentVersion);
}

async function downloadServer(
  binDir: string,
  binPath: string,
  versionFile: string,
  currentVersion: string
): Promise<string | undefined> {
  const platformMap: Record<string, string> = {
    "darwin-arm64": "apexgov-darwin-aarch64",
    "darwin-x64": "apexgov-darwin-x86_64",
    "linux-arm64": "apexgov-linux-aarch64",
    "linux-x64": "apexgov-linux-x86_64",
  };

  const key = `${process.platform}-${process.arch}`;
  const asset = platformMap[key];
  if (!asset) {
    vscode.window.showErrorMessage(
      `apexgov: Unsupported platform: ${key}`
    );
    return undefined;
  }

  const url = `https://github.com/soyukke/apexgov/releases/latest/download/${asset}.tar.gz`;

  return vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "apexgov: Downloading server...",
      cancellable: false,
    },
    async () => {
      try {
        fs.mkdirSync(binDir, { recursive: true });
        const tarPath = path.join(binDir, `${asset}.tar.gz`);

        await downloadFile(url, tarPath);
        execSync(`tar xzf "${tarPath}" -C "${binDir}"`, { stdio: "ignore" });
        fs.unlinkSync(tarPath);

        // Ensure executable
        if (process.platform !== "win32") {
          fs.chmodSync(binPath, 0o755);
        }

        if (fs.existsSync(binPath)) {
          fs.writeFileSync(versionFile, currentVersion, "utf-8");
          return binPath;
        }
      } catch (e) {
        vscode.window.showErrorMessage(
          `apexgov: Download failed: ${e}`
        );
      }
      return undefined;
    }
  );
}

function downloadFile(url: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const follow = (u: string) => {
      https
        .get(u, (res) => {
          if (res.statusCode === 301 || res.statusCode === 302) {
            const loc = res.headers.location;
            if (loc) {
              follow(loc);
              return;
            }
          }
          if (res.statusCode !== 200) {
            reject(new Error(`HTTP ${res.statusCode}`));
            return;
          }
          const file = fs.createWriteStream(dest);
          res.pipe(file);
          file.on("finish", () => {
            file.close();
            resolve();
          });
        })
        .on("error", reject);
    };
    follow(url);
  });
}
