//! root — トランスパイルのエントリポイント。
//!
//! Apex ファイル群を受け取り、パース→式変換→レンダリングの
//! パイプラインを統合制御する。

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const file_io = @import("file_io.zig");
const trigger = @import("trigger.zig");
const parser_mod = @import("parser.zig");
const renderer = @import("renderer.zig");

// Aliases used by run()
const startsWithIgnoreCase = util.startsWithIgnoreCase;
const endsWithIgnoreCase = util.endsWithIgnoreCase;
const isValidPackageName = util.isValidPackageName;
const pathExists = util.pathExists;

pub const Options = types.Options;
pub const UnsupportedDiagnostic = types.UnsupportedDiagnostic;
pub const Summary = types.Summary;

const collectApexFiles = file_io.collectApexFiles;
const collectApexTriggerFiles = file_io.collectApexTriggerFiles;
const deinitApexFiles = file_io.deinitApexFiles;
const writeOutputFile = file_io.writeOutputFile;

const parseTriggerRegistration = trigger.parseTriggerRegistration;
const writeTriggerManifest = trigger.writeTriggerManifest;
const TriggerRegistration = types.TriggerRegistration;

const parseApexClass = parser_mod.parseApexClass;
const renderJavaClass = renderer.renderJavaClass;
pub fn run(gpa: std.mem.Allocator, opts: Options) !Summary {
    if (opts.input_paths.len == 0) return error.MissingInputPath;

    var files = try collectApexFiles(gpa, opts.input_paths);
    defer deinitApexFiles(gpa, &files);

    var trigger_files = try collectApexTriggerFiles(gpa, opts.input_paths);
    defer deinitApexFiles(gpa, &trigger_files);

    if (files.items.len == 0) return error.NoApexClassSourceFound;
    if (!isValidPackageName(opts.package_name)) return error.InvalidPackageName;

    try std.fs.cwd().makePath(opts.out_dir);

    var summary = Summary{
        .files_scanned = files.items.len,
    };
    errdefer summary.deinit(gpa);

    for (files.items) |file| {
        var parsed = try parseApexClass(gpa, file.path, file.content);
        defer parsed.deinit(gpa);

        var rendered = try renderJavaClass(gpa, parsed, opts.package_name);
        defer rendered.deinit(gpa);

        if (opts.strict and rendered.unsupported_statements > 0) {
            return error.UnsupportedApexSyntax;
        }

        const output_name = try std.fmt.allocPrint(gpa, "{s}.java", .{parsed.class_name});
        defer gpa.free(output_name);

        const output_path = try std.fs.path.join(gpa, &.{ opts.out_dir, output_name });
        defer gpa.free(output_path);

        if (!opts.overwrite and pathExists(output_path)) {
            return error.OutputAlreadyExists;
        }

        try writeOutputFile(output_path, rendered.java);

        summary.files_generated += 1;
        summary.methods_generated += parsed.methods.items.len;
        summary.unsupported_statements += rendered.unsupported_statements;
        for (rendered.unsupported_lines.items) |line| {
            if (summary.unsupported_examples.items.len >= 64) break;

            const source_copy = try gpa.dupe(u8, parsed.source_path);
            errdefer gpa.free(source_copy);
            const method_copy = try gpa.dupe(u8, line.method_name);
            errdefer {
                gpa.free(source_copy);
                gpa.free(method_copy);
            }
            const statement_copy = try gpa.dupe(u8, line.statement);
            errdefer {
                gpa.free(source_copy);
                gpa.free(method_copy);
                gpa.free(statement_copy);
            }
            try summary.unsupported_examples.append(gpa, .{
                .source_path = source_copy,
                .method_name = method_copy,
                .line_no = line.source_line,
                .reason = line.reason,
                .statement = statement_copy,
            });
        }
    }

    var trigger_registrations: std.ArrayList(TriggerRegistration) = .empty;
    defer {
        for (trigger_registrations.items) |*registration| {
            registration.deinit(gpa);
        }
        trigger_registrations.deinit(gpa);
    }

    for (trigger_files.items) |file| {
        const maybe_registration = try parseTriggerRegistration(gpa, file.path, file.content);
        if (maybe_registration) |registration| {
            try trigger_registrations.append(gpa, registration);
            continue;
        }
        if (opts.strict) {
            return error.UnsupportedApexSyntax;
        }
    }

    if (trigger_registrations.items.len > 0) {
        try writeTriggerManifest(gpa, opts.out_dir, trigger_registrations.items, opts.overwrite);
    }

    return summary;
}

test "run counts unsupported statements when strict is disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class UnsupportedDemo {
        \\  public static void run() {
        \\    when Account acc {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "UnsupportedDemo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(root);
    const out_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "out" },
    );
    defer std.testing.allocator.free(out_dir);

    const inputs = [_][]const u8{root};
    var summary = try run(std.testing.allocator, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
        .strict = false,
    });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
    try std.testing.expect(summary.unsupported_statements > 0);
    try std.testing.expect(summary.unsupported_examples.items.len > 0);
    try std.testing.expect(summary.unsupported_examples.items[0].line_no > 0);
    try std.testing.expect(summary.unsupported_examples.items[0].reason.len > 0);
}

test "run strict mode fails on unsupported statements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class UnsupportedStrictDemo {
        \\  public static void run() {
        \\    when Account acc {
        \\      System.debug('x');
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "UnsupportedStrictDemo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(root);
    const out_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "out" },
    );
    defer std.testing.allocator.free(out_dir);

    const inputs = [_][]const u8{root};
    try std.testing.expectError(
        error.UnsupportedApexSyntax,
        run(std.testing.allocator, .{
            .input_paths = &inputs,
            .out_dir = out_dir,
            .package_name = "generated",
            .overwrite = true,
            .strict = true,
        }),
    );
}

test "run transpiles file with field-only inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{root};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "run transpiles direct file input with field-only inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Direct.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Direct.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "run transpiles package-private top-level class with inner class" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\class Demo {
        \\  private class Inner {
        \\    public Boolean enabled = true;
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(
        gpa,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Demo.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.files_generated);
}

test "run promotes multiline test visible inner type visibility" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\public class Demo {
        \\  @TestVisible
        \\  private without sharing class Inner {
        \\    public void ping() {
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "Demo.cls", .data = source });
    try tmp.dir.makePath("out");

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const file_path = try std.fs.path.join(gpa, &.{ root, "Demo.cls" });
    defer gpa.free(file_path);
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);
    const output_path = try std.fs.path.join(gpa, &.{ out_dir, "Demo.java" });
    defer gpa.free(output_path);

    const inputs = [_][]const u8{file_path};
    var summary = try run(gpa, .{
        .input_paths = &inputs,
        .out_dir = out_dir,
        .package_name = "generated",
        .overwrite = true,
    });
    defer summary.deinit(gpa);

    const output = try std.fs.cwd().readFileAlloc(gpa, output_path, 1024 * 1024);
    defer gpa.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "public static class Inner") != null);
}
