//! scope — クラス・トリガーおよびループのスコープ管理。
//!
//! ブレース深さに基づくオーナースコープ (class/trigger/enum) の
//! 開始・終了追跡と、ループスコープのプッシュ・ポップを行い、
//! 解析中に「現在どのクラスのどのループ内にいるか」を管理する。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

const OwnerScope = types.OwnerScope;
const LoopScope = types.LoopScope;
const extract_leading_identifier = utils.extract_leading_identifier;

pub fn maybe_enter_owner_scope(
    allocator: std.mem.Allocator,
    scopes: *std.ArrayList(OwnerScope),
    brace_depth: i32,
    line: []const u8,
) !void {
    const owner = parse_owner_start(line) orelse return;
    try scopes.append(allocator, .{
        .name = owner,
        .end_depth = brace_depth + 1,
    });
}

pub fn pop_closed_owners(scopes: *std.ArrayList(OwnerScope), brace_depth: i32) void {
    while (scopes.items.len > 0 and scopes.items[scopes.items.len - 1].end_depth > brace_depth) {
        _ = scopes.pop();
    }
}

pub fn pop_closed_scopes(scopes: *std.ArrayList(LoopScope), brace_depth: i32) void {
    while (scopes.items.len > 0 and scopes.items[scopes.items.len - 1].end_depth > brace_depth) {
        _ = scopes.pop();
    }
}

pub fn parse_owner_start(line: []const u8) ?[]const u8 {
    return parse_class_start(line) orelse parse_trigger_start(line);
}

pub fn parse_class_start(line: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;

    var start: ?usize = null;
    if (std.mem.startsWith(u8, line, "class ")) {
        start = 6;
    } else if (std.mem.indexOf(u8, line, " class ")) |idx| {
        start = idx + 7;
    }
    const class_start = start orelse return null;
    const rest = std.mem.trimStart(u8, line[class_start..], " \t");
    return extract_leading_identifier(rest);
}

pub fn parse_trigger_start(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "trigger ")) return null;
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;
    const rest = std.mem.trimStart(u8, line[8..], " \t");
    return extract_leading_identifier(rest);
}
