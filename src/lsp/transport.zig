//! transport — JSON-RPC over stdio トランスポート。
//!
//! LSP 仕様に従い、Content-Length ヘッダ付きの JSON メッセージを
//! stdin から読み取り、stdout へ書き出す。

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

pub const Transport = struct {
    in_file: Io.File,
    out_file: Io.File,
    io: Io,
    allocator: std.mem.Allocator,
    read_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: Io, in_file: Io.File, out_file: Io.File) Transport {
        return .{
            .in_file = in_file,
            .out_file = out_file,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.read_buf.deinit(self.allocator);
    }

    /// 1 つの JSON-RPC メッセージを読み取る。
    /// 接続終了時は null を返す。
    pub fn readMessage(self: *Transport) !?[]const u8 {
        const content_length = self.readHeaders() catch |err| {
            if (err == error.EndOfStream) return null;
            return err;
        } orelse return null;

        self.read_buf.clearRetainingCapacity();
        try self.read_buf.resize(self.allocator, content_length);
        const buf = self.read_buf.items;

        var total_read: usize = 0;
        while (total_read < content_length) {
            const slices: [1][]u8 = .{buf[total_read..content_length]};
            const n = self.in_file.readStreaming(self.io, &slices) catch return null;
            if (n == 0) return null;
            total_read += n;
        }

        return buf[0..content_length];
    }

    /// JSON-RPC メッセージを書き出す。
    pub fn writeMessage(self: *Transport, body: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
        try self.out_file.writeStreamingAll(self.io, header);
        try self.out_file.writeStreamingAll(self.io, body);
    }

    /// JSON-RPC レスポンスを送信する。
    pub fn sendResponse(self: *Transport, allocator: std.mem.Allocator, id: types.RequestId, result: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try id.jsonStringify(&jw);
        try jw.objectField("result");
        try jw.write(result);
        try jw.endObject();

        try self.writeMessage(aw.written());
    }

    /// JSON-RPC エラーレスポンスを送信する。
    pub fn sendErrorResponse(self: *Transport, allocator: std.mem.Allocator, id: types.RequestId, code: i32, message: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try id.jsonStringify(&jw);
        try jw.objectField("error");
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(code);
        try jw.objectField("message");
        try jw.write(message);
        try jw.endObject();
        try jw.endObject();

        try self.writeMessage(aw.written());
    }

    /// JSON-RPC 通知を送信する。
    pub fn sendNotification(self: *Transport, allocator: std.mem.Allocator, method: []const u8, params: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write(method);
        try jw.objectField("params");
        try jw.write(params);
        try jw.endObject();

        try self.writeMessage(aw.written());
    }

    // -- internal --

    const ReadError = Io.File.ReadStreamingError || error{EndOfStream};

    fn readHeaders(self: *Transport) ReadError!?usize {
        var content_length: ?usize = null;
        var line_buf: [1024]u8 = undefined;

        while (true) {
            const line = try self.readLine(&line_buf) orelse return error.EndOfStream;

            if (line.len == 0) break;

            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value = std.mem.trimStart(u8, line["content-length:".len..], " \t");
                content_length = std.fmt.parseInt(usize, value, 10) catch continue;
            }
        }

        return content_length;
    }

    fn readLine(self: *Transport, buf: []u8) ReadError!?[]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            var byte_buf: [1]u8 = undefined;
            const slices: [1][]u8 = .{&byte_buf};
            const n = self.in_file.readStreaming(self.io, &slices) catch return error.EndOfStream;
            if (n == 0) {
                if (i == 0) return null;
                return buf[0..i];
            }
            const byte = byte_buf[0];
            if (byte == '\n') {
                const end = if (i > 0 and buf[i - 1] == '\r') i - 1 else i;
                return buf[0..end];
            }
            buf[i] = byte;
            i += 1;
        }
        return buf[0..i];
    }
};
