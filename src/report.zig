const std = @import("std");
const model = @import("model.zig");

pub fn writeCheck(writer: *std.Io.Writer, format: model.OutputFormat, findings: []const model.Finding) !void {
    switch (format) {
        .text => try writeCheckText(writer, findings),
        .json => try writeCheckJson(writer, findings),
        .sarif => try writeCheckSarif(writer, findings),
    }
}

pub fn writeProfile(writer: *std.Io.Writer, format: model.OutputFormat, profiles: []const model.ProfileResult) !void {
    switch (format) {
        .text => try writeProfileText(writer, profiles),
        .json => try writeProfileJson(writer, profiles),
        .sarif => try writeProfileSarif(writer, profiles),
    }
}

fn writeCheckText(writer: *std.Io.Writer, findings: []const model.Finding) !void {
    if (findings.len == 0) {
        try writer.writeAll("No findings.");
        return;
    }

    try writer.print("Found {d} finding(s):\n", .{findings.len});
    for (findings) |finding| {
        try writer.print(
            "[{s}] [{s}] {s} {s}:{d} {s} - {s}\n",
            .{
                finding.severity.asString(),
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

fn writeCheckJson(writer: *std.Io.Writer, findings: []const model.Finding) !void {
    try writer.writeAll("{\"tool\":\"apexgov\",\"kind\":\"check\",\"findings\":[");
    for (findings, 0..) |finding, i| {
        if (i != 0) try writer.writeAll(",");

        try writer.writeAll("{\"rule_id\":");
        try writeJsonString(writer, finding.rule_id);
        try writer.writeAll(",\"title\":");
        try writeJsonString(writer, finding.title);
        try writer.writeAll(",\"message\":");
        try writeJsonString(writer, finding.message);
        try writer.writeAll(",\"severity\":");
        try writeJsonString(writer, finding.severity.asString());
        try writer.writeAll(",\"category\":");
        try writeJsonString(writer, finding.category);
        try writer.writeAll(",\"file\":");
        try writeJsonString(writer, finding.file);
        try writer.print(",\"line\":{d}}}", .{finding.line});
    }
    try writer.writeAll("]}");
}

fn writeCheckSarif(writer: *std.Io.Writer, findings: []const model.Finding) !void {
    try writer.writeAll("{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"apexgov\"}},\"results\":[");

    for (findings, 0..) |finding, i| {
        if (i != 0) try writer.writeAll(",");
        try writer.writeAll("{\"ruleId\":");
        try writeJsonString(writer, finding.rule_id);
        try writer.writeAll(",\"level\":");
        try writeJsonString(writer, sarifLevelFromSeverity(finding.severity));
        try writer.writeAll(",\"message\":{\"text\":");
        try writeJsonString(writer, finding.message);
        try writer.writeAll("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
        try writeJsonString(writer, finding.file);
        try writer.writeAll("},\"region\":{\"startLine\":");
        try writer.print("{d}", .{finding.line});
        try writer.writeAll("}}}]}");
    }

    try writer.writeAll("]}]}");
}

fn writeProfileText(writer: *std.Io.Writer, profiles: []const model.ProfileResult) !void {
    if (profiles.len == 0) {
        try writer.writeAll("No CPU/Heap metrics found in logs.");
        return;
    }

    var violations: usize = 0;
    try writer.print("Parsed {d} log transaction(s):\n", .{profiles.len});
    for (profiles) |profile| {
        if (profile.anyExceeded()) violations += 1;
        try writer.print(
            "- {s} [{s}] cpu={d}/{d} heap={d}/{d} {s}\n",
            .{
                profile.source,
                if (profile.is_async) "async" else "sync",
                profile.cpu_ms,
                profile.cpu_budget,
                profile.heap_bytes,
                profile.heap_budget,
                if (profile.anyExceeded()) "OVER_BUDGET" else "OK",
            },
        );
    }
    try writer.print("Violations: {d}", .{violations});
}

fn writeProfileJson(writer: *std.Io.Writer, profiles: []const model.ProfileResult) !void {
    var violations: usize = 0;
    for (profiles) |profile| {
        if (profile.anyExceeded()) violations += 1;
    }

    try writer.writeAll("{\"tool\":\"apexgov\",\"kind\":\"profile\",\"profiles\":[");
    for (profiles, 0..) |profile, i| {
        if (i != 0) try writer.writeAll(",");

        try writer.writeAll("{\"source\":");
        try writeJsonString(writer, profile.source);
        try writer.writeAll(",\"label\":");
        try writeJsonString(writer, profile.label);
        try writer.writeAll(",\"mode\":");
        try writeJsonString(writer, if (profile.is_async) "async" else "sync");
        try writer.print(",\"cpu_ms\":{d},\"cpu_budget\":{d},\"heap_bytes\":{d},\"heap_budget\":{d},\"cpu_exceeded\":{s},\"heap_exceeded\":{s}}}", .{
            profile.cpu_ms,
            profile.cpu_budget,
            profile.heap_bytes,
            profile.heap_budget,
            if (profile.cpuExceeded()) "true" else "false",
            if (profile.heapExceeded()) "true" else "false",
        });
    }
    try writer.writeAll("],\"summary\":{\"total\":");
    try writer.print("{d}", .{profiles.len});
    try writer.writeAll(",\"violations\":");
    try writer.print("{d}", .{violations});
    try writer.writeAll("}}");
}

fn writeProfileSarif(writer: *std.Io.Writer, profiles: []const model.ProfileResult) !void {
    try writer.writeAll("{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"apexgov\"}},\"results\":[");

    var emitted: usize = 0;
    for (profiles) |profile| {
        if (profile.cpuExceeded()) {
            if (emitted != 0) try writer.writeAll(",");
            emitted += 1;
            try writer.writeAll("{\"ruleId\":\"AG_CPU_BUDGET\",\"level\":\"error\",\"message\":{\"text\":");
            try writeJsonString(writer, "CPU budget exceeded");
            try writer.writeAll("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
            try writeJsonString(writer, profile.source);
            try writer.writeAll("},\"region\":{\"startLine\":1}}}]}");
        }

        if (profile.heapExceeded()) {
            if (emitted != 0) try writer.writeAll(",");
            emitted += 1;
            try writer.writeAll("{\"ruleId\":\"AG_HEAP_BUDGET\",\"level\":\"error\",\"message\":{\"text\":");
            try writeJsonString(writer, "Heap budget exceeded");
            try writer.writeAll("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
            try writeJsonString(writer, profile.source);
            try writer.writeAll("},\"region\":{\"startLine\":1}}}]}");
        }
    }

    try writer.writeAll("]}]}");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn sarifLevelFromSeverity(severity: model.Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .info => "note",
    };
}
