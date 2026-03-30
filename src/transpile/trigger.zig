//! trigger — Apex トリガーの Java 変換。
//!
//! `trigger ... on Object (before insert, ...)` 構文を解析し、
//! Java クラスとして再構成する。

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const file_io = @import("file_io.zig");

const TriggerEvent = types.TriggerEvent;
const TriggerRegistration = types.TriggerRegistration;

pub fn parseTriggerRegistration(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    content: []const u8,
) !?TriggerRegistration {
    var cursor = util.skipApexCommentsAndWhitespace(content, 0);
    if (cursor >= content.len or !util.startsWithWordIgnoreCase(content[cursor..], "trigger")) {
        return null;
    }
    cursor += "trigger".len;
    cursor = util.skipInlineWhitespace(content, cursor);
    cursor = readTriggerToken(content, cursor) orelse return null; // trigger name
    cursor = util.skipInlineWhitespace(content, cursor);
    if (cursor >= content.len or !util.startsWithWordIgnoreCase(content[cursor..], "on")) {
        return null;
    }
    cursor += "on".len;
    cursor = util.skipInlineWhitespace(content, cursor);
    const object_start = cursor;
    cursor = readTriggerToken(content, cursor) orelse return null;
    const sobject_type = std.mem.trim(u8, content[object_start..cursor], " \t\r\n");
    if (sobject_type.len == 0) return null;

    cursor = util.skipInlineWhitespace(content, cursor);
    if (cursor >= content.len or content[cursor] != '(') return null;
    const events_start = cursor + 1;
    const events_end = std.mem.indexOfScalarPos(u8, content, events_start, ')') orelse return null;
    var events = parseTriggerEvents(gpa, content[events_start..events_end]) catch return null;
    errdefer events.deinit(gpa);

    // Try fflib_SObjectDomain.triggerHandler(X.class) pattern first
    const handler_prefix = "fflib_SObjectDomain.triggerHandler(";
    var handler_class: ?[]const u8 = null;
    if (util.indexOfIgnoreCase(content, handler_prefix)) |handler_idx| {
        if (std.mem.indexOfScalarPos(u8, content, handler_idx, '(')) |handler_open| {
            if (std.mem.indexOfScalarPos(u8, content, handler_open + 1, ')')) |handler_close| {
                const raw_handler = std.mem.trim(u8, content[handler_open + 1 .. handler_close], " \t\r\n");
                if (util.endsWithIgnoreCase(raw_handler, ".class") and raw_handler.len > ".class".len) {
                    handler_class = std.mem.trim(u8, raw_handler[0 .. raw_handler.len - ".class".len], " \t\r\n");
                }
            }
        }
    }
    // Fallback: new X().run() pattern (skip comments)
    if (handler_class == null or handler_class.?.len == 0) {
        const new_prefix = "new ";
        var search_pos: usize = events_end;
        while (util.indexOfIgnoreCasePos(content, search_pos, new_prefix)) |new_idx| {
            // Skip if inside a comment
            if (util.isInsideComment(content, new_idx)) {
                search_pos = new_idx + 1;
                continue;
            }
            const name_start = new_idx + new_prefix.len;
            if (name_start >= content.len) break;
            // Skip whitespace after "new "
            var ns = name_start;
            while (ns < content.len and (content[ns] == ' ' or content[ns] == '\t')) ns += 1;
            // Read identifier
            var ne = ns;
            while (ne < content.len and (std.ascii.isAlphanumeric(content[ne]) or content[ne] == '_')) ne += 1;
            if (ne > ns) {
                // Check for ().run() pattern
                var check = ne;
                while (check < content.len and (content[check] == ' ' or content[check] == '\t')) check += 1;
                if (check + 1 < content.len and content[check] == '(' and content[check + 1] == ')') {
                    check += 2;
                    while (check < content.len and (content[check] == ' ' or content[check] == '\t')) check += 1;
                    if (check < content.len and content[check] == '.') {
                        check += 1;
                        while (check < content.len and (content[check] == ' ' or content[check] == '\t')) check += 1;
                        if (check + 3 <= content.len and util.startsWithWordIgnoreCase(content[check..], "run")) {
                            handler_class = content[ns..ne];
                            break;
                        }
                    }
                }
            }
            search_pos = new_idx + 1;
        }
    }
    if (handler_class == null or handler_class.?.len == 0) {
        events.deinit(gpa);
        return null;
    }

    return TriggerRegistration{
        .source_path = try gpa.dupe(u8, source_path),
        .sobject_type = try gpa.dupe(u8, sobject_type),
        .handler_class = try gpa.dupe(u8, handler_class.?),
        .events = events,
    };
}

pub fn parseTriggerEvents(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(TriggerEvent) {
    var events: std.ArrayList(TriggerEvent) = .empty;
    errdefer events.deinit(gpa);

    var start: usize = 0;
    while (start <= text.len) {
        const comma = std.mem.indexOfScalarPos(u8, text, start, ',') orelse text.len;
        const token = std.mem.trim(u8, text[start..comma], " \t\r\n");
        if (token.len > 0) {
            const event = parseTriggerEvent(token) orelse return error.UnsupportedApexSyntax;
            if (!triggerEventListContains(events.items, event)) {
                try events.append(gpa, event);
            }
        }
        if (comma == text.len) break;
        start = comma + 1;
    }
    return events;
}

pub fn parseTriggerEvent(token: []const u8) ?TriggerEvent {
    if (std.ascii.eqlIgnoreCase(token, "before insert")) return .before_insert;
    if (std.ascii.eqlIgnoreCase(token, "before update")) return .before_update;
    if (std.ascii.eqlIgnoreCase(token, "before delete")) return .before_delete;
    if (std.ascii.eqlIgnoreCase(token, "after insert")) return .after_insert;
    if (std.ascii.eqlIgnoreCase(token, "after update")) return .after_update;
    if (std.ascii.eqlIgnoreCase(token, "after delete")) return .after_delete;
    if (std.ascii.eqlIgnoreCase(token, "after undelete")) return .after_undelete;
    return null;
}

pub fn triggerEventListContains(events: []const TriggerEvent, needle: TriggerEvent) bool {
    for (events) |event| {
        if (event == needle) return true;
    }
    return false;
}

pub fn triggerEventName(event: TriggerEvent) []const u8 {
    return switch (event) {
        .before_insert => "before_insert",
        .before_update => "before_update",
        .before_delete => "before_delete",
        .after_insert => "after_insert",
        .after_update => "after_update",
        .after_delete => "after_delete",
        .after_undelete => "after_undelete",
    };
}

pub fn writeTriggerManifest(
    gpa: std.mem.Allocator,
    out_dir: []const u8,
    registrations: []const TriggerRegistration,
    overwrite: bool,
) !void {
    if (registrations.len == 0) return;

    const manifest_path = try std.fs.path.join(gpa, &.{ out_dir, "apex-triggers.txt" });
    defer gpa.free(manifest_path);

    if (!overwrite and util.pathExists(manifest_path)) {
        return error.OutputAlreadyExists;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    for (registrations) |registration| {
        try util.appendFmt(gpa, &out, "{s}|", .{registration.sobject_type});
        for (registration.events.items, 0..) |event, idx| {
            if (idx > 0) {
                try out.append(gpa, ',');
            }
            try out.appendSlice(gpa, triggerEventName(event));
        }
        try util.appendFmt(gpa, &out, "|{s}\n", .{registration.handler_class});
    }

    try file_io.writeOutputFile(manifest_path, out.items);
}

fn readTriggerToken(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    var cursor = start;
    while (cursor < text.len) : (cursor += 1) {
        const ch = text[cursor];
        if (util.isIdentifierChar(ch) or ch == '.') continue;
        break;
    }
    return if (cursor > start) cursor else null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseTriggerRegistration extracts fflib trigger manifest entry" {
    const gpa = std.testing.allocator;
    const source =
        \\trigger Opportunities on Opportunity (
        \\  after delete, after insert, after update, before delete, before insert, before update
        \\) {
        \\  fflib_SObjectDomain.triggerHandler(OpportunitiesTriggerHandler.class);
        \\}
    ;

    var registration = (try parseTriggerRegistration(gpa, "Opportunities.trigger", source)).?;
    defer registration.deinit(gpa);

    try std.testing.expectEqualStrings("Opportunities.trigger", registration.source_path);
    try std.testing.expectEqualStrings("Opportunity", registration.sobject_type);
    try std.testing.expectEqualStrings("OpportunitiesTriggerHandler", registration.handler_class);
    try std.testing.expectEqual(@as(usize, 6), registration.events.items.len);
    try std.testing.expectEqual(TriggerEvent.after_delete, registration.events.items[0]);
    try std.testing.expectEqual(TriggerEvent.before_update, registration.events.items[5]);
}
