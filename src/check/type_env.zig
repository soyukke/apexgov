//! type_env — 変数の型環境追跡。
//!
//! ローカル変数・パラメータの型バインディングを管理し、
//! `for-each` ループの要素型推論やコレクション型引数の追跡を行う。
//! メソッド呼び出し解決時のレシーバー型マッチングに使用される。

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

const TypeBinding = types.TypeBinding;
const extract_last_identifier = utils.extract_last_identifier;
const is_ident_char = utils.is_ident_char;
const is_ident_start = utils.is_ident_start;
const append_canonical_type = utils.append_canonical_type;
const trim_trailing_delimiter = utils.trim_trailing_delimiter;
const extract_type_from_new_expression = utils.extract_type_from_new_expression;

pub fn register_method_param_types(
    arena_allocator: std.mem.Allocator,
    type_env: *std.StringHashMap([]const u8),
    params_raw: []const u8,
) !void {
    const params = std.mem.trim(u8, params_raw, " \t");
    if (params.len == 0) return;

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
            if (parse_typed_binding(segment)) |binding| {
                try bind_type(arena_allocator, type_env, binding);
            }
            seg_start = i + 1;
        }
    }
}

pub fn apply_local_type_updates(
    arena_allocator: std.mem.Allocator,
    type_env: *std.StringHashMap([]const u8),
    line: []const u8,
) !void {
    if (parse_for_each_binding(line)) |binding| {
        try bind_type(arena_allocator, type_env, binding);
        return;
    }
    if (parse_for_init_assigned_new_binding(line)) |binding| {
        try bind_type(arena_allocator, type_env, binding);
        return;
    }
    if (parse_for_init_binding(line)) |binding| {
        try bind_type(arena_allocator, type_env, binding);
        return;
    }
    if (parse_local_declared_new_binding(line)) |binding| {
        try bind_type(arena_allocator, type_env, binding);
        return;
    }
    if (parse_assignment_new_binding(line)) |binding| {
        try bind_type(arena_allocator, type_env, binding);
        return;
    }
    if (parse_local_typed_binding(line)) |binding| {
        try bind_type(arena_allocator, type_env, binding);
    }
}

pub fn parse_for_each_binding(line: []const u8) ?TypeBinding {
    if (!std.mem.startsWith(u8, line, "for(") and
        !std.mem.startsWith(u8, line, "for (")) return null;
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    const inside = std.mem.trim(u8, line[(open_idx + 1)..close_idx], " \t");
    const colon_idx = std.mem.indexOfScalar(u8, inside, ':') orelse return null;
    const left = std.mem.trim(u8, inside[0..colon_idx], " \t");
    return parse_typed_binding(left);
}

fn parse_for_init_binding(line: []const u8) ?TypeBinding {
    if (!std.mem.startsWith(u8, line, "for(") and
        !std.mem.startsWith(u8, line, "for (")) return null;
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    const inside = std.mem.trim(u8, line[(open_idx + 1)..close_idx], " \t");
    if (std.mem.indexOfScalar(u8, inside, ':') != null) return null;
    const semi_idx = std.mem.indexOfScalar(u8, inside, ';') orelse return null;
    const init = std.mem.trim(u8, inside[0..semi_idx], " \t");
    if (init.len == 0) return null;
    const eq_idx = std.mem.indexOfScalar(u8, init, '=') orelse init.len;
    const left = std.mem.trim(u8, init[0..eq_idx], " \t");
    return parse_typed_binding(left);
}

fn parse_for_init_assigned_new_binding(line: []const u8) ?TypeBinding {
    if (!std.mem.startsWith(u8, line, "for(") and
        !std.mem.startsWith(u8, line, "for (")) return null;
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    const inside = std.mem.trim(u8, line[(open_idx + 1)..close_idx], " \t");
    if (std.mem.indexOfScalar(u8, inside, ':') != null) return null;
    const semi_idx = std.mem.indexOfScalar(u8, inside, ';') orelse return null;
    const init = std.mem.trim(u8, inside[0..semi_idx], " \t");
    return parse_declared_new_binding(init);
}

fn parse_local_declared_new_binding(line: []const u8) ?TypeBinding {
    if (std.mem.startsWith(u8, line, "if(") or
        std.mem.startsWith(u8, line, "if ") or
        std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for ") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while ") or
        std.mem.startsWith(u8, line, "switch(") or
        std.mem.startsWith(u8, line, "switch ") or
        std.mem.startsWith(u8, line, "catch(") or
        std.mem.startsWith(u8, line, "catch ") or
        std.mem.startsWith(u8, line, "return") or
        std.mem.startsWith(u8, line, "throw"))
    {
        return null;
    }
    return parse_declared_new_binding(line);
}

fn parse_declared_new_binding(line: []const u8) ?TypeBinding {
    if (std.mem.indexOf(u8, line, "==") != null) return null;
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trim_trailing_delimiter(right);
    if (!std.mem.startsWith(u8, right, "new ")) return null;

    const declared = parse_typed_binding(left) orelse return null;
    const type_raw = extract_type_from_new_expression(right[4..]) orelse return null;
    return .{
        .name = declared.name,
        .type_raw = type_raw,
    };
}

fn parse_assignment_new_binding(line: []const u8) ?TypeBinding {
    if (std.mem.indexOf(u8, line, "==") != null) return null;
    if (std.mem.startsWith(u8, line, "if(") or
        std.mem.startsWith(u8, line, "if ") or
        std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for ") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while ") or
        std.mem.startsWith(u8, line, "switch(") or
        std.mem.startsWith(u8, line, "switch ") or
        std.mem.startsWith(u8, line, "catch(") or
        std.mem.startsWith(u8, line, "catch ") or
        std.mem.startsWith(u8, line, "return") or
        std.mem.startsWith(u8, line, "throw") or
        std.mem.startsWith(u8, line, "insert ") or
        std.mem.startsWith(u8, line, "update ") or
        std.mem.startsWith(u8, line, "delete ") or
        std.mem.startsWith(u8, line, "upsert "))
    {
        return null;
    }

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const left = std.mem.trim(u8, line[0..eq_idx], " \t");
    var right = std.mem.trim(u8, line[(eq_idx + 1)..], " \t");
    right = trim_trailing_delimiter(right);
    if (!std.mem.startsWith(u8, right, "new ")) return null;

    const target = parse_simple_assignment_target(left) orelse return null;
    const type_raw = extract_type_from_new_expression(right[4..]) orelse return null;
    return .{
        .name = target,
        .type_raw = type_raw,
    };
}

fn parse_simple_assignment_target(left_raw: []const u8) ?[]const u8 {
    const left = std.mem.trim(u8, left_raw, " \t");
    if (left.len == 0) return null;
    if (!is_ident_start(left[0])) return null;
    for (left) |c| {
        if (!is_ident_char(c)) return null;
    }
    return left;
}

pub fn parse_local_typed_binding(line: []const u8) ?TypeBinding {
    if (std.mem.startsWith(u8, line, "if(") or
        std.mem.startsWith(u8, line, "if ") or
        std.mem.startsWith(u8, line, "for(") or
        std.mem.startsWith(u8, line, "for ") or
        std.mem.startsWith(u8, line, "while(") or
        std.mem.startsWith(u8, line, "while ") or
        std.mem.startsWith(u8, line, "switch(") or
        std.mem.startsWith(u8, line, "switch ") or
        std.mem.startsWith(u8, line, "catch(") or
        std.mem.startsWith(u8, line, "catch ") or
        std.mem.startsWith(u8, line, "return") or
        std.mem.startsWith(u8, line, "throw") or
        std.mem.startsWith(u8, line, "insert ") or
        std.mem.startsWith(u8, line, "update ") or
        std.mem.startsWith(u8, line, "delete ") or
        std.mem.startsWith(u8, line, "upsert "))
    {
        return null;
    }

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse line.len;
    const semi_idx = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const end_idx = @min(eq_idx, semi_idx);
    if (end_idx == 0 or end_idx > line.len) return null;
    const left = std.mem.trim(u8, line[0..end_idx], " \t");
    if (left.len == 0) return null;
    return parse_typed_binding(left);
}

pub fn parse_typed_binding(segment_raw: []const u8) ?TypeBinding {
    const segment = std.mem.trim(u8, segment_raw, " \t");
    if (segment.len == 0) return null;
    const name = extract_last_identifier(segment) orelse return null;
    if (!is_ident_start(name[0])) return null;

    var i = segment.len;
    while (i > 0 and !is_ident_char(segment[i - 1])) : (i -= 1) {}
    const end = i;
    if (end == 0) return null;
    while (i > 0 and is_ident_char(segment[i - 1])) : (i -= 1) {}
    const start = i;
    if (start == 0) return null;
    if (!std.ascii.isWhitespace(segment[start - 1])) return null;

    var type_part = std.mem.trimEnd(u8, segment[0..start], " \t");
    type_part = strip_leading_type_modifiers(type_part);
    if (type_part.len == 0) return null;

    return .{
        .name = name,
        .type_raw = type_part,
    };
}

pub fn strip_leading_type_modifiers(raw: []const u8) []const u8 {
    var out = std.mem.trim(u8, raw, " \t");
    while (true) {
        if (std.mem.startsWith(u8, out, "final ")) {
            out = std.mem.trimStart(u8, out[6..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "public ")) {
            out = std.mem.trimStart(u8, out[7..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "private ")) {
            out = std.mem.trimStart(u8, out[8..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "protected ")) {
            out = std.mem.trimStart(u8, out[10..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "global ")) {
            out = std.mem.trimStart(u8, out[7..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "static ")) {
            out = std.mem.trimStart(u8, out[7..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, out, "transient ")) {
            out = std.mem.trimStart(u8, out[10..], " \t");
            continue;
        }
        break;
    }
    return out;
}

pub fn bind_type(
    arena_allocator: std.mem.Allocator,
    type_env: *std.StringHashMap([]const u8),
    binding: TypeBinding,
) !void {
    const canonical = try canonicalize_type(arena_allocator, binding.type_raw);
    if (type_env.getPtr(binding.name)) |existing| {
        existing.* = canonical;
        return;
    }
    const key = try arena_allocator.dupe(u8, binding.name);
    try type_env.put(key, canonical);
}

pub fn canonicalize_type(arena_allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const stripped = strip_leading_type_modifiers(raw);
    try append_canonical_type(arena_allocator, &out, stripped);
    return try out.toOwnedSlice(arena_allocator);
}
