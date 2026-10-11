//! model — 解析結果の共通データ型。
//!
//! `Finding` (静的解析の検出結果), `ProfileResult` (デバッグログプロファイル結果),
//! `Severity`, `OutputFormat` など、check / profile / report モジュール間で
//! 共有されるデータ型を定義する。

const std = @import("std");

pub const Severity = enum {
    info,
    warning,
    err,

    pub fn from_string(value: []const u8) ?Severity {
        if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(value, "warning")) return .warning;
        if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
        return null;
    }

    pub fn as_string(self: Severity) []const u8 {
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

    pub fn from_string(value: []const u8) ?OutputFormat {
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
    transaction_index: u32,
    is_async: bool,
    cpu_ms: u32,
    heap_bytes: u64,
    cpu_budget: u32,
    heap_budget: u64,

    pub fn cpu_exceeded(self: ProfileResult) bool {
        return self.cpu_ms > self.cpu_budget;
    }

    pub fn heap_exceeded(self: ProfileResult) bool {
        return self.heap_bytes > self.heap_budget;
    }

    pub fn any_exceeded(self: ProfileResult) bool {
        return self.cpu_exceeded() or self.heap_exceeded();
    }
};

pub fn deinit_findings(gpa: std.mem.Allocator, findings: *std.ArrayList(Finding)) void {
    for (findings.items) |finding| {
        gpa.free(finding.title);
        gpa.free(finding.message);
        gpa.free(finding.file);
    }
    findings.deinit(gpa);
}

pub fn deinit_profiles(gpa: std.mem.Allocator, profiles: *std.ArrayList(ProfileResult)) void {
    for (profiles.items) |profile| {
        gpa.free(profile.source);
        gpa.free(profile.label);
    }
    profiles.deinit(gpa);
}
