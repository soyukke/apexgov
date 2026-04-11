//! types — LSP プロトコル型定義。
//!
//! JSON-RPC メッセージおよび LSP 仕様のデータ型を Zig struct で表現する。
//! `std.json` で直接シリアライズ/デシリアライズ可能。

const std = @import("std");

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

/// JSON-RPC リクエスト/通知の ID。string | integer | null。
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    none,

    pub fn jsonStringify(self: RequestId, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (self) {
            .integer => |v| try jw.write(v),
            .string => |v| try jw.write(v),
            .none => try jw.write(null),
        }
    }
};

// ---------------------------------------------------------------------------
// LSP 基本型
// ---------------------------------------------------------------------------

/// 0-indexed, UTF-16 code unit ベース。
pub const Position = struct {
    line: u32 = 0,
    character: u32 = 0,
};

pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

pub const Location = struct {
    uri: []const u8,
    range: Range = .{},
};

// ---------------------------------------------------------------------------
// Diagnostic
// ---------------------------------------------------------------------------

pub const DiagnosticSeverity = enum(u32) {
    @"error" = 1,
    warning = 2,
    information = 3,
    hint = 4,

    pub fn jsonStringify(self: DiagnosticSeverity, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.write(@intFromEnum(self));
    }
};

pub const Diagnostic = struct {
    range: Range = .{},
    severity: ?DiagnosticSeverity = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8 = "",
};

// ---------------------------------------------------------------------------
// TextDocument
// ---------------------------------------------------------------------------

pub const TextDocumentIdentifier = struct {
    uri: []const u8 = "",
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8 = "",
    version: i64 = 0,
};

pub const TextDocumentItem = struct {
    uri: []const u8 = "",
    languageId: []const u8 = "",
    version: i64 = 0,
    text: []const u8 = "",
};

// ---------------------------------------------------------------------------
// didOpen / didChange / didClose パラメータ
// ---------------------------------------------------------------------------

pub const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem = .{},
};

pub const TextDocumentContentChangeEvent = struct {
    text: []const u8 = "",
};

pub const DidChangeTextDocumentParams = struct {
    textDocument: VersionedTextDocumentIdentifier = .{},
    contentChanges: []const TextDocumentContentChangeEvent = &.{},
};

pub const DidCloseTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier = .{},
};

// ---------------------------------------------------------------------------
// PublishDiagnostics
// ---------------------------------------------------------------------------

pub const PublishDiagnosticsParams = struct {
    uri: []const u8 = "",
    diagnostics: []const Diagnostic = &.{},
};

// ---------------------------------------------------------------------------
// Initialize
// ---------------------------------------------------------------------------

pub const InitializeParams = struct {
    processId: ?i64 = null,
    rootUri: ?[]const u8 = null,
    capabilities: std.json.Value = .null,
};

pub const TextDocumentSyncKind = enum(u32) {
    none = 0,
    full = 1,
    incremental = 2,

    pub fn jsonStringify(self: TextDocumentSyncKind, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.write(@intFromEnum(self));
    }
};

pub const SemanticTokensOptions = struct {
    legend: SemanticTokensLegend = .{},
    full: bool = true,
};

pub const ServerCapabilities = struct {
    textDocumentSync: TextDocumentSyncKind = .incremental,
    documentSymbolProvider: bool = true,
    semanticTokensProvider: SemanticTokensOptions = .{},
    foldingRangeProvider: bool = true,
    documentFormattingProvider: bool = true,
    workspaceSymbolProvider: bool = true,
    hoverProvider: bool = true,
    completionProvider: CompletionOptions = .{},
    definitionProvider: bool = true,
    referencesProvider: bool = true,
    signatureHelpProvider: SignatureHelpOptions = .{},
    renameProvider: bool = true,
    documentHighlightProvider: bool = true,
    codeActionProvider: bool = true,
    codeLensProvider: CodeLensOptions = .{},
    executeCommandProvider: ExecuteCommandOptions = .{},
};

pub const ServerInfo = struct {
    name: []const u8 = "apexgov-lsp",
    version: []const u8 = "0.1.0",
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities = .{},
    serverInfo: ServerInfo = .{},
};

// ---------------------------------------------------------------------------
// DocumentSymbol
// ---------------------------------------------------------------------------

pub const SymbolKind = enum(u32) {
    file = 1,
    module = 2,
    namespace = 3,
    package = 4,
    class = 5,
    method = 6,
    property = 7,
    field = 8,
    constructor = 9,
    @"enum" = 10,
    interface = 11,
    function = 12,
    variable = 13,
    constant = 14,
    string = 15,
    number = 16,
    boolean = 17,
    array = 18,
    object = 19,
    key = 20,
    null = 21,
    enum_member = 22,
    @"struct" = 23,
    event = 24,
    operator = 25,
    type_parameter = 26,

    pub fn jsonStringify(self: SymbolKind, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.write(@intFromEnum(self));
    }
};

pub const DocumentSymbol = struct {
    name: []const u8 = "",
    kind: SymbolKind = .file,
    range: Range = .{},
    selectionRange: Range = .{},
    children: []const DocumentSymbol = &.{},
};

// ---------------------------------------------------------------------------
// SemanticTokens
// ---------------------------------------------------------------------------

/// SemanticTokens のレスポンス。data は相対エンコードされた u32 配列。
pub const SemanticTokens = struct {
    data: []const u32 = &.{},
};

/// サーバーが返す SemanticTokensLegend。
pub const SemanticTokensLegend = struct {
    tokenTypes: []const []const u8 = &token_types,
    tokenModifiers: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// FoldingRange
// ---------------------------------------------------------------------------

pub const FoldingRange = struct {
    startLine: u32 = 0,
    endLine: u32 = 0,
};

// ---------------------------------------------------------------------------
// TextEdit
// ---------------------------------------------------------------------------

pub const TextEdit = struct {
    range: Range = .{},
    newText: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Hover
// ---------------------------------------------------------------------------

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8 = "",
};

pub const HoverResult = struct {
    contents: MarkupContent = .{},
};

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

pub const CompletionItemKind = enum(u32) {
    text = 1,
    method = 2,
    function = 3,
    constructor = 4,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    @"enum" = 13,
    keyword = 14,
    snippet = 15,
    enum_member = 20,
    constant = 21,

    pub fn jsonStringify(self: CompletionItemKind, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.write(@intFromEnum(self));
    }
};

pub const CompletionItem = struct {
    label: []const u8 = "",
    kind: ?CompletionItemKind = null,
    detail: ?[]const u8 = null,
};

pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem = &.{},
};

pub const CompletionOptions = struct {
    triggerCharacters: []const []const u8 = &.{"."},
};

// ---------------------------------------------------------------------------
// SignatureHelp
// ---------------------------------------------------------------------------

pub const ParameterInformation = struct {
    label: []const u8 = "",
};

pub const SignatureInformation = struct {
    label: []const u8 = "",
    parameters: []const ParameterInformation = &.{},
};

pub const SignatureHelp = struct {
    signatures: []const SignatureInformation = &.{},
    activeSignature: u32 = 0,
    activeParameter: u32 = 0,
};

pub const SignatureHelpOptions = struct {
    triggerCharacters: []const []const u8 = &.{ "(", "," },
};

// ---------------------------------------------------------------------------
// Rename
// ---------------------------------------------------------------------------

pub const WorkspaceEdit = struct {
    changes: ?ChangeMap = null,

    pub const ChangeMap = struct {
        uri: []const u8 = "",
        edits: []const TextEdit = &.{},

        pub fn jsonStringify(self: ChangeMap, jw: *std.json.Stringify) std.json.Stringify.Error!void {
            try jw.beginObject();
            try jw.objectField(self.uri);
            try jw.write(self.edits);
            try jw.endObject();
        }
    };
};

// ---------------------------------------------------------------------------
// DocumentHighlight
// ---------------------------------------------------------------------------

pub const DocumentHighlightKind = enum(u32) {
    text = 1,
    read = 2,
    write = 3,

    pub fn jsonStringify(self: DocumentHighlightKind, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.write(@intFromEnum(self));
    }
};

pub const DocumentHighlight = struct {
    range: Range = .{},
    kind: DocumentHighlightKind = .text,
};

// ---------------------------------------------------------------------------
// CodeAction
// ---------------------------------------------------------------------------

pub const CodeAction = struct {
    title: []const u8 = "",
    kind: []const u8 = "quickfix",
};

// ---------------------------------------------------------------------------
// CodeLens
// ---------------------------------------------------------------------------

pub const Command = struct {
    title: []const u8 = "",
    command: []const u8 = "",
    arguments: ?[]const []const u8 = null,
};

pub const CodeLens = struct {
    range: Range = .{},
    command: ?Command = null,
};

pub const CodeLensOptions = struct {
    resolveProvider: bool = false,
};

// ---------------------------------------------------------------------------
// ExecuteCommand
// ---------------------------------------------------------------------------

pub const ExecuteCommandOptions = struct {
    commands: []const []const u8 = &.{ "apexgov.runTest", "apexgov.runAllTests" },
};

// ---------------------------------------------------------------------------
// window/showMessage
// ---------------------------------------------------------------------------

pub const MessageType = enum(u32) {
    @"error" = 1,
    warning = 2,
    info = 3,
    log = 4,

    pub fn jsonStringify(self: MessageType, jw: anytype) !void {
        try jw.write(@intFromEnum(self));
    }
};

pub const ShowMessageParams = struct {
    type: MessageType = .info,
    message: []const u8 = "",
};

/// サポートするトークンタイプ（LSP 仕様準拠のインデックス順）。
pub const token_types = [_][]const u8{
    "keyword", // 0
    "type", // 1
    "variable", // 2
    "string", // 3
    "number", // 4
    "operator", // 5
    "comment", // 6
    "function", // 7
    "decorator", // 8
};
