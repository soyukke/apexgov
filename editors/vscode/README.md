# apexgov — Apex Governor Limit Checker

Offline static analysis and language server for Salesforce Apex. Detects Governor limit violations in real-time as you code.

## Features

- **Governor Limit Diagnostics** — SOQL/DML/SOSL/Callout/Messaging inside loops (AG001-AG011)
- **Code Completion** — Apex standard library, SObject fields (standard + custom `__c` / `__mdt`)
- **Go to Definition** — Jump to symbol definitions
- **Find References** — Search symbol references
- **Hover** — Symbol information on hover
- **Rename** — Rename symbols across the file
- **Syntax Highlighting** — Full TextMate grammar for Apex and embedded SOQL
- **Document Symbols** — Outline view for classes and methods
- **Formatting** — Code formatting
- **Folding** — Code folding support

## How It Works

The extension automatically downloads the `apexgov` binary from GitHub Releases on first activation. No additional dependencies (Zig, JDK, etc.) are required.

## Detected Rules

| ID | Detection Target |
|---|---|
| AG001 | Nested loops |
| AG002 | SOQL inside loops |
| AG003 | DML inside loops |
| AG004 | JSON serialize/deserialize inside loops |
| AG005 | clone/deepClone inside loops |
| AG006 | Collection allocation inside loops |
| AG007 | String concatenation inside loops |
| AG008 | SOSL inside loops |
| AG009 | Heuristic CPU estimate |
| AG010 | HTTP callout inside loops |
| AG011 | Messaging.sendEmail inside loops |

## Settings

| Setting | Description | Default |
|---|---|---|
| `apexgov.serverPath` | Path to apexgov binary. If empty, downloaded automatically. | `""` |

## Requirements

- No external dependencies required
- Supported platforms: macOS (ARM/Intel), Linux (x86_64/aarch64)

## Links

- [GitHub Repository](https://github.com/soyukke/apexgov)
- [Setup Guide (Neovim / VS Code)](https://github.com/soyukke/apexgov/blob/main/docs/lsp-setup.md)

## License

MIT
