//! report — 解析結果のフォーマッター。
//!
//! `Finding` や `ProfileResult` を text / JSON / SARIF 形式で出力する。

const std = @import("std");
const model = @import("model.zig");

pub fn write_check(writer: *std.Io.Writer, format: model.OutputFormat, findings: []const model.Finding) !void {
    switch (format) {
        .text => try write_check_text(writer, findings),
        .json => try write_check_json(writer, findings),
        .sarif => try write_check_sarif(writer, findings),
    }
}

pub fn write_profile(writer: *std.Io.Writer, format: model.OutputFormat, profiles: []const model.ProfileResult) !void {
    switch (format) {
        .text => try write_profile_text(writer, profiles),
        .json => try write_profile_json(writer, profiles),
        .sarif => try write_profile_sarif(writer, profiles),
    }
}

fn write_check_text(writer: *std.Io.Writer, findings: []const model.Finding) !void {
    if (findings.len == 0) {
        try writer.writeAll("No findings.");
        return;
    }

    try writer.print("Found {d} finding(s):\n", .{findings.len});
    for (findings) |finding| {
        try writer.print(
            "[{s}] [{s}] {s} {s}:{d} {s} - {s}\n",
            .{
                finding.severity.as_string(),
                finding.category,
                finding.rule_id,
                finding.file,
                finding.line,
                finding.title,
                finding.message,
            },
        );
    }
}

fn write_check_json(writer: *std.Io.Writer, findings: []const model.Finding) !void {
    try writer.writeAll("{\"tool\":\"apexgov\",\"kind\":\"check\",\"findings\":[");
    for (findings, 0..) |finding, i| {
        if (i != 0) try writer.writeAll(",");

        try writer.writeAll("{\"rule_id\":");
        try write_json_string(writer, finding.rule_id);
        try writer.writeAll(",\"title\":");
        try write_json_string(writer, finding.title);
        try writer.writeAll(",\"message\":");
        try write_json_string(writer, finding.message);
        try writer.writeAll(",\"severity\":");
        try write_json_string(writer, finding.severity.as_string());
        try writer.writeAll(",\"category\":");
        try write_json_string(writer, finding.category);
        try writer.writeAll(",\"file\":");
        try write_json_string(writer, finding.file);
        try writer.print(",\"line\":{d}}}", .{finding.line});
    }
    try writer.writeAll("]}");
}

fn write_check_sarif(writer: *std.Io.Writer, findings: []const model.Finding) !void {
    try writer.writeAll("{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"apexgov\"}},\"results\":[");

    for (findings, 0..) |finding, i| {
        if (i != 0) try writer.writeAll(",");
        try writer.writeAll("{\"ruleId\":");
        try write_json_string(writer, finding.rule_id);
        try writer.writeAll(",\"level\":");
        try write_json_string(writer, sarif_level_from_severity(finding.severity));
        try writer.writeAll(",\"message\":{\"text\":");
        try write_json_string(writer, finding.message);
        try writer.writeAll("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
        try write_json_string(writer, finding.file);
        try writer.writeAll("},\"region\":{\"startLine\":");
        try writer.print("{d}", .{finding.line});
        try writer.writeAll("}}}]}");
    }

    try writer.writeAll("]}]}");
}

fn write_profile_text(writer: *std.Io.Writer, profiles: []const model.ProfileResult) !void {
    if (profiles.len == 0) {
        try writer.writeAll("No CPU/Heap metrics found in logs.");
        return;
    }

    var violations: usize = 0;
    try writer.print("Parsed {d} log transaction(s):\n", .{profiles.len});
    for (profiles) |profile| {
        if (profile.any_exceeded()) violations += 1;
        try writer.print(
            "- {s}#tx{d} [{s}] cpu={d}/{d} heap={d}/{d} {s}\n",
            .{
                profile.source,
                profile.transaction_index,
                if (profile.is_async) "async" else "sync",
                profile.cpu_ms,
                profile.cpu_budget,
                profile.heap_bytes,
                profile.heap_budget,
                if (profile.any_exceeded()) "OVER_BUDGET" else "OK",
            },
        );
    }
    try writer.print("Violations: {d}", .{violations});
}

fn write_profile_json(writer: *std.Io.Writer, profiles: []const model.ProfileResult) !void {
    var violations: usize = 0;
    for (profiles) |profile| {
        if (profile.any_exceeded()) violations += 1;
    }

    try writer.writeAll("{\"tool\":\"apexgov\",\"kind\":\"profile\",\"profiles\":[");
    for (profiles, 0..) |profile, i| {
        if (i != 0) try writer.writeAll(",");

        try writer.writeAll("{\"source\":");
        try write_json_string(writer, profile.source);
        try writer.print(",\"transaction_index\":{d}", .{profile.transaction_index});
        try writer.writeAll(",\"label\":");
        try write_json_string(writer, profile.label);
        try writer.writeAll(",\"mode\":");
        try write_json_string(writer, if (profile.is_async) "async" else "sync");
        try writer.print(",\"cpu_ms\":{d},\"cpu_budget\":{d},\"heap_bytes\":{d}," ++
            "\"heap_budget\":{d},\"cpu_exceeded\":{s},\"heap_exceeded\":{s}}}", .{
            profile.cpu_ms,
            profile.cpu_budget,
            profile.heap_bytes,
            profile.heap_budget,
            if (profile.cpu_exceeded()) "true" else "false",
            if (profile.heap_exceeded()) "true" else "false",
        });
    }
    try writer.writeAll("],\"summary\":{\"total\":");
    try writer.print("{d}", .{profiles.len});
    try writer.writeAll(",\"violations\":");
    try writer.print("{d}", .{violations});
    try writer.writeAll("}}");
}

fn write_profile_sarif(writer: *std.Io.Writer, profiles: []const model.ProfileResult) !void {
    try writer.writeAll("{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"apexgov\"}},\"results\":[");

    var emitted: usize = 0;
    for (profiles) |profile| {
        if (profile.cpu_exceeded()) {
            if (emitted != 0) try writer.writeAll(",");
            emitted += 1;
            try writer.writeAll("{\"ruleId\":\"AG_CPU_BUDGET\",\"level\":\"error\",\"message\":{\"text\":");
            try write_json_string(writer, "CPU budget exceeded");
            try writer.writeAll("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
            try write_json_string(writer, profile.source);
            try writer.writeAll("},\"region\":{\"startLine\":1}}}]}");
        }

        if (profile.heap_exceeded()) {
            if (emitted != 0) try writer.writeAll(",");
            emitted += 1;
            try writer.writeAll("{\"ruleId\":\"AG_HEAP_BUDGET\",\"level\":\"error\",\"message\":{\"text\":");
            try write_json_string(writer, "Heap budget exceeded");
            try writer.writeAll("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
            try write_json_string(writer, profile.source);
            try writer.writeAll("},\"region\":{\"startLine\":1}}}]}");
        }
    }

    try writer.writeAll("]}]}");
}

fn write_json_string(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn sarif_level_from_severity(severity: model.Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .info => "note",
    };
}
