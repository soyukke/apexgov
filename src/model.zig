const std = @import("std");

pub const Severity = enum {
    info,
    warning,
    err,

    pub fn fromString(value: []const u8) ?Severity {
        if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(value, "warning")) return .warning;
        if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
        return null;
    }

    pub fn asString(self: Severity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .err => "error",
        };
    }

    pub fn rank(self: Severity) u8 {
        return switch (self) {
            .info => 0,
            .warning => 1,
            .err => 2,
        };
    }
};

pub const OutputFormat = enum {
    text,
    json,
    sarif,

    pub fn fromString(value: []const u8) ?OutputFormat {
        if (std.ascii.eqlIgnoreCase(value, "text")) return .text;
        if (std.ascii.eqlIgnoreCase(value, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(value, "sarif")) return .sarif;
        return null;
    }
};

pub const Finding = struct {
    rule_id: []const u8,
    title: []const u8,
    message: []const u8,
    severity: Severity,
    category: []const u8,
    file: []const u8,
    line: usize,
};

pub const ProfileResult = struct {
    source: []const u8,
    label: []const u8,
    is_async: bool,
    cpu_ms: u32,
    heap_bytes: u64,
    cpu_budget: u32,
    heap_budget: u64,

    pub fn cpuExceeded(self: ProfileResult) bool {
        return self.cpu_ms > self.cpu_budget;
    }

    pub fn heapExceeded(self: ProfileResult) bool {
        return self.heap_bytes > self.heap_budget;
    }

    pub fn anyExceeded(self: ProfileResult) bool {
        return self.cpuExceeded() or self.heapExceeded();
    }
};

pub fn deinitFindings(gpa: std.mem.Allocator, findings: *std.ArrayList(Finding)) void {
    for (findings.items) |finding| {
        gpa.free(finding.title);
        gpa.free(finding.message);
        gpa.free(finding.file);
    }
    findings.deinit(gpa);
}

pub fn deinitProfiles(gpa: std.mem.Allocator, profiles: *std.ArrayList(ProfileResult)) void {
    for (profiles.items) |profile| {
        gpa.free(profile.source);
        gpa.free(profile.label);
    }
    profiles.deinit(gpa);
}
