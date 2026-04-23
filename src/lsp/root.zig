//! lsp — Apex 言語サーバープロトコル (LSP) 実装。

const std = @import("std");
const Io = std.Io;

pub const types = @import("types.zig");
pub const transport = @import("transport.zig");
pub const document_store = @import("document_store.zig");
pub const server = @import("server.zig");
pub const symbols = @import("symbols.zig");
pub const semantic_tokens = @import("semantic_tokens.zig");
pub const governor_diagnostics = @import("governor_diagnostics.zig");
pub const folding_range = @import("folding_range.zig");
pub const formatting = @import("formatting.zig");
pub const workspace_symbol = @import("workspace_symbol.zig");
pub const position = @import("position.zig");
pub const binder = @import("binder.zig");
pub const hover = @import("hover.zig");
pub const definition = @import("definition.zig");
pub const references = @import("references.zig");
pub const completion = @import("completion.zig");
pub const signature_help = @import("signature_help.zig");
pub const rename = @import("rename.zig");
pub const document_highlight = @import("document_highlight.zig");
pub const code_action = @import("code_action.zig");
pub const code_lens = @import("code_lens.zig");
pub const sobject_schema = @import("sobject_schema.zig");
pub const apex_stdlib = @import("apex_stdlib.zig");

pub const Server = server.Server;
pub const Transport = transport.Transport;
pub const DocumentStore = document_store.DocumentStore;

/// LSP サーバーを起動する（stdio）。
pub fn serve(allocator: std.mem.Allocator, io: Io) !void {
    const stdin = Io.File.stdin();
    const stdout = Io.File.stdout();
    var srv = Server.init(allocator, io, stdin, stdout);
    defer srv.deinit();
    try srv.run();
}

test {
    _ = types;
    _ = transport;
    _ = document_store;
    _ = server;
    _ = symbols;
    _ = semantic_tokens;
    _ = governor_diagnostics;
    _ = folding_range;
    _ = formatting;
    _ = workspace_symbol;
    _ = position;
    _ = binder;
    _ = hover;
    _ = definition;
    _ = references;
    _ = completion;
    _ = signature_help;
    _ = rename;
    _ = document_highlight;
    _ = code_action;
    _ = code_lens;
    _ = sobject_schema;
    _ = apex_stdlib;
}
