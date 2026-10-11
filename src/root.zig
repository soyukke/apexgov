pub const model = @import("model.zig");
pub const config = @import("config.zig");
pub const check = @import("check.zig");
pub const profile = @import("profile.zig");
pub const report = @import("report.zig");
pub const interpret = @import("interpret/root.zig");
pub const apex_parser = @import("apex_parser/root.zig");
pub const lsp = @import("lsp/root.zig");
pub const typegen = @import("typegen/root.zig");

test {
    _ = model;
    _ = config;
    _ = check;
    _ = profile;
    _ = report;
    _ = interpret;
    _ = apex_parser;
    _ = lsp;
    _ = typegen;
}
