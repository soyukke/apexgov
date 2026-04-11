//! sfdx_project — sfdx-project.json から packageDirectories を読み取るユーティリティ。
//!
//! ワークスペースルート配下の sfdx-project.json をパースし、
//! `packageDirectories[].path` のリストを返す。
//! ファイルが無い/パース失敗時はフォールバック候補を返す。

const std = @import("std");

/// sfdx-project.json の packageDirectories[].path を解決する。
/// 戻り値のスライス要素は allocator で確保済み。呼び出し側で解放すること。
/// sfdx-project.json が無い/パース不能の場合はフォールバックパスを返す。
pub fn resolvePackageDirs(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const []const u8 {
    const json_path = try std.fs.path.join(allocator, &.{ workspace_root, "sfdx-project.json" });
    defer allocator.free(json_path);

    const content = std.fs.cwd().readFileAlloc(allocator, json_path, 1024 * 1024) catch {
        return fallbackDirs(allocator, workspace_root);
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return fallbackDirs(allocator, workspace_root);
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return fallbackDirs(allocator, workspace_root),
    };

    const pkg_dirs_val = root_obj.get("packageDirectories") orelse {
        return fallbackDirs(allocator, workspace_root);
    };
    const pkg_dirs = switch (pkg_dirs_val) {
        .array => |a| a,
        else => return fallbackDirs(allocator, workspace_root),
    };

    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |p| allocator.free(p);
        result.deinit(allocator);
    }

    for (pkg_dirs.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const path_val = obj.get("path") orelse continue;
        const rel_path = switch (path_val) {
            .string => |s| s,
            else => continue,
        };
        const full = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
        try result.append(allocator, full);
    }

    if (result.items.len == 0) {
        result.deinit(allocator);
        return fallbackDirs(allocator, workspace_root);
    }

    return result.toOwnedSlice(allocator);
}

/// sfdx-project.json が無い場合のフォールバック。
/// 従来のハードコードパスのうち実在するものを返す。
/// どれも無ければ workspace_root 自体を返す。
fn fallbackDirs(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const []const u8 {
    const candidates = [_][]const u8{
        "force-app",
        "src",
    };

    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |p| allocator.free(p);
        result.deinit(allocator);
    }

    for (&candidates) |rel| {
        const full = try std.fs.path.join(allocator, &.{ workspace_root, rel });
        if (std.fs.openDirAbsolute(full, .{})) |dir| {
            var d = dir;
            d.close();
            try result.append(allocator, full);
        } else |_| {
            allocator.free(full);
        }
    }

    if (result.items.len == 0) {
        const ws_dupe = try allocator.dupe(u8, workspace_root);
        try result.append(allocator, ws_dupe);
    }

    return result.toOwnedSlice(allocator);
}

/// パッケージディレクトリ配下の特定サブディレクトリ（classes, objects 等）のパスリストを返す。
/// 例: pkg_dirs=["ws/force-app"], sub="main/default/classes"
///   → ["ws/force-app/main/default/classes"] (存在する場合のみ)
pub fn resolveSubDirs(
    allocator: std.mem.Allocator,
    pkg_dirs: []const []const u8,
    sub_path: []const u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |p| allocator.free(p);
        result.deinit(allocator);
    }

    for (pkg_dirs) |pkg_dir| {
        const full = try std.fs.path.join(allocator, &.{ pkg_dir, sub_path });
        if (std.fs.openDirAbsolute(full, .{})) |dir| {
            var d = dir;
            d.close();
            try result.append(allocator, full);
        } else |_| {
            allocator.free(full);
        }
    }

    return result.toOwnedSlice(allocator);
}

// ── テスト ──────────────────────────────────────────

test "parse sfdx-project.json content" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{
        \\  "packageDirectories": [
        \\    { "path": "force-app", "default": true },
        \\    { "path": "cc-base-app" },
        \\    { "path": "cc-employee-app" }
        \\  ],
        \\  "namespace": "",
        \\  "sfdcLoginUrl": "https://login.salesforce.com",
        \\  "sourceApiVersion": "59.0"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    const pkg_dirs = root_obj.get("packageDirectories").?.array;

    try std.testing.expectEqual(@as(usize, 3), pkg_dirs.items.len);

    const expected = [_][]const u8{ "force-app", "cc-base-app", "cc-employee-app" };
    for (pkg_dirs.items, 0..) |item, i| {
        const path_str = item.object.get("path").?.string;
        try std.testing.expectEqualStrings(expected[i], path_str);
    }
}

test "fallback when packageDirectories is empty" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{ "packageDirectories": [] }
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    const pkg_dirs = root_obj.get("packageDirectories").?.array;
    try std.testing.expectEqual(@as(usize, 0), pkg_dirs.items.len);
}

test "fallback when packageDirectories missing" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{ "namespace": "" }
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    try std.testing.expect(root_obj.get("packageDirectories") == null);
}
