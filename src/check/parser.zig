//! parser — メソッド宣言・型宣言のパース。
//!
//! ソース行からメソッドシグネチャ（名前・パラメータ型）を抽出する
//! `parse_method_start` と、クラス/インターフェース/列挙型の宣言を認識して
//! 継承・実装関係を登録する `parse_type_decl` / `register_type_decl` を提供する。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

const MethodDecl = types.MethodDecl;
const TypeDecl = types.TypeDecl;
const extract_last_identifier = utils.extract_last_identifier;
const extract_leading_identifier = utils.extract_leading_identifier;
const is_ident_char = utils.is_ident_char;
const is_control_keyword = utils.is_control_keyword;
const extract_parameter_type_part = utils.extract_parameter_type_part;
const append_canonical_type = utils.append_canonical_type;
const sat_add_u16 = utils.sat_add_u16;

pub fn parse_method_start(line: []const u8) ?MethodDecl {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    const open_idx = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
        if (eq_idx < open_idx) return null;
    }
    if (std.mem.indexOf(u8, trimmed, " class ") != null or
        std.mem.startsWith(u8, trimmed, "class "))
    {
        return null;
    }
    if (std.mem.startsWith(u8, trimmed, "if(") or
        std.mem.startsWith(u8, trimmed, "if ") or
        std.mem.startsWith(u8, trimmed, "for(") or
        std.mem.startsWith(u8, trimmed, "for ") or
        std.mem.startsWith(u8, trimmed, "while(") or
        std.mem.startsWith(u8, trimmed, "while ") or
        std.mem.startsWith(u8, trimmed, "switch(") or
        std.mem.startsWith(u8, trimmed, "switch ") or
        std.mem.startsWith(u8, trimmed, "catch(") or
        std.mem.startsWith(u8, trimmed, "catch ") or
        std.mem.startsWith(u8, trimmed, "else"))
    {
        return null;
    }

    const left = std.mem.trim(u8, trimmed[0..open_idx], " \t");
    const name = extract_last_identifier(left) orelse return null;
    if (is_control_keyword(name)) return null;
    const params_raw = trimmed[(open_idx + 1)..close_idx];
    const param_count = count_parameters(params_raw) orelse return null;
    return .{
        .name = name,
        .param_count = param_count,
        .params_raw = params_raw,
    };
}

pub fn count_parameters(params_raw: []const u8) ?u16 {
    const params = std.mem.trim(u8, params_raw, " \t");
    if (params.len == 0) return 0;

    var count: u16 = 1;
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;

    for (params) |c| {
        switch (c) {
            '<' => {
                angle_depth += 1;
            },
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '(' => {
                paren_depth += 1;
            },
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => {
                bracket_depth += 1;
            },
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => {
                brace_depth += 1;
            },
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            ',' => {
                if (angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    count = sat_add_u16(count, 1);
                }
            },
            else => {},
        }
    }

    return count;
}

pub fn build_param_type_signature(
    arena_allocator: std.mem.Allocator,
    params_raw: []const u8,
) ![]const u8 {
    const params = std.mem.trim(u8, params_raw, " \t");
    if (params.len == 0) return try arena_allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;

    var seg_start: usize = 0;
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var i: usize = 0;
    while (i <= params.len) : (i += 1) {
        const at_end = i == params.len;
        const c = if (at_end) ',' else params[i];

        if (!at_end) {
            switch (c) {
                '<' => {
                    angle_depth += 1;
                },
                '>' => {
                    if (angle_depth > 0) angle_depth -= 1;
                },
                '(' => {
                    paren_depth += 1;
                },
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                '[' => {
                    bracket_depth += 1;
                },
                ']' => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                },
                '{' => {
                    brace_depth += 1;
                },
                '}' => {
                    if (brace_depth > 0) brace_depth -= 1;
                },
                else => {},
            }
        }

        if (c == ',' and
            angle_depth == 0 and paren_depth == 0 and
            bracket_depth == 0 and brace_depth == 0)
        {
            const segment = std.mem.trim(u8, params[seg_start..i], " \t");
            const type_part = extract_parameter_type_part(segment);
            if (out.items.len > 0) try out.append(arena_allocator, '|');
            try append_canonical_type(arena_allocator, &out, type_part);
            seg_start = i + 1;
        }
    }

    return try out.toOwnedSlice(arena_allocator);
}

pub fn count_signature_params(signature: []const u8) u16 {
    if (signature.len == 0) return 0;
    var count: u16 = 1;
    for (signature) |c| {
        if (c == '|') count = sat_add_u16(count, 1);
    }
    return count;
}

pub fn parse_type_decl(line: []const u8) ?TypeDecl {
    const brace_idx = std.mem.indexOfScalar(u8, line, '{') orelse return null;
    const header = std.mem.trimEnd(u8, line[0..brace_idx], " \t");
    if (header.len == 0) return null;

    const class_idx = index_of_word_ignore_case(header, "class");
    const interface_idx = index_of_word_ignore_case(header, "interface");
    if (class_idx == null and interface_idx == null) return null;

    const keyword_idx = if (class_idx == null)
        interface_idx.?
    else if (interface_idx == null)
        class_idx.?
    else
        @min(class_idx.?, interface_idx.?);
    const is_interface = interface_idx != null and interface_idx.? == keyword_idx;
    const keyword_len: usize = if (is_interface) "interface".len else "class".len;

    var after_keyword = std.mem.trimStart(u8, header[(keyword_idx + keyword_len)..], " \t");
    const name = extract_leading_identifier(after_keyword) orelse return null;
    after_keyword = std.mem.trimStart(u8, after_keyword[name.len..], " \t");

    const extends_name = if (!is_interface) parse_single_type_after_keyword(after_keyword, "extends") else null;
    const interfaces_raw = if (is_interface)
        slice_after_keyword(after_keyword, "extends") orelse ""
    else
        slice_after_keyword(after_keyword, "implements") orelse "";

    return .{
        .name = name,
        .extends_name = extends_name,
        .implements_raw = interfaces_raw,
    };
}

fn parse_single_type_after_keyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    const rest = slice_after_keyword(line, keyword) orelse return null;
    return extract_leading_identifier(rest);
}

fn slice_after_keyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    const idx = index_of_word_ignore_case(line, keyword) orelse return null;
    const after = std.mem.trimStart(u8, line[(idx + keyword.len)..], " \t");
    if (after.len == 0) return null;
    return after;
}

pub fn index_of_word_ignore_case(text: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or text.len < word.len) return null;
    var i: usize = 0;
    while (i + word.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) continue;
        const left_ok = i == 0 or !is_ident_char(text[i - 1]);
        const right_idx = i + word.len;
        const right_ok = right_idx == text.len or !is_ident_char(text[right_idx]);
        if (left_ok and right_ok) return i;
    }
    return null;
}

pub fn register_type_decl(
    arena_allocator: std.mem.Allocator,
    relations: *@import("types.zig").TypeRelations,
    decl: TypeDecl,
) !void {
    if (decl.extends_name) |parent| {
        const child_key = try arena_allocator.dupe(u8, decl.name);
        const parent_copy = try arena_allocator.dupe(u8, parent);
        try relations.extends_by_type.put(child_key, parent_copy);
    }

    if (decl.implements_raw.len == 0) return;
    var interfaces = std.mem.splitScalar(u8, decl.implements_raw, ',');
    while (interfaces.next()) |raw_iface| {
        const iface = std.mem.trim(u8, raw_iface, " \t");
        if (iface.len == 0) continue;
        const iface_name = extract_leading_identifier(iface) orelse continue;
        try register_interface_constraint(arena_allocator, relations, decl.name, iface_name);
    }
}

fn register_interface_constraint(
    arena_allocator: std.mem.Allocator,
    relations: *@import("types.zig").TypeRelations,
    type_name: []const u8,
    interface_name: []const u8,
) !void {
    if (relations.interfaces_by_type.getPtr(type_name)) |list| {
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, interface_name)) return;
        }
        try list.append(arena_allocator, try arena_allocator.dupe(u8, interface_name));
        return;
    }

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    try list.append(arena_allocator, try arena_allocator.dupe(u8, interface_name));
    try relations.interfaces_by_type.put(try arena_allocator.dupe(u8, type_name), list);
}
