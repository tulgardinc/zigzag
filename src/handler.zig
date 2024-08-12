const std = @import("std");
const HTTPRequest = @import("http_request.zig").HTTPRequest;
const HTTPResponse = @import("http_response.zig").HTTPResponse;

pub const ContentType = enum {
    css,
    html,
    js,
    plain,

    pub fn getString(self: ContentType) []const u8 {
        return switch (self) {
            .css => "text/css; charset=UTF-8",
            .html => "text/html; charset=UTF-8",
            .js => "text/js; charset=UTF-8",
            .plain => "text/plain; charset=UTF-8",
        };
    }
};

pub const Handler = struct {
    fn_run_ptr: *const fn (std.mem.Allocator, HTTPRequest) ?HTTPResponse,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime func: anytype) Self {
        const run_fn = GenRunFn(func).run;
        return Self{
            .allocator = allocator,
            .fn_run_ptr = run_fn,
        };
    }

    pub fn run(self: Self, request: HTTPRequest) ?HTTPResponse {
        return self.fn_run_ptr(self.allocator, request);
    }

    fn GenRunFn(comptime func: anytype) type {
        return struct {
            fn run(allocator: std.mem.Allocator, req: HTTPRequest) ?HTTPResponse {
                const args = std.meta.ArgsTuple(@TypeOf(func));
                const fields = std.meta.fields(args);

                comptime var arg_types: [fields.len]type = undefined;
                inline for (fields, 0..) |f, i| {
                    arg_types[i] = f.type;
                }

                const func_info = @typeInfo(@TypeOf(func));
                const ret_type = func_info.Fn.return_type;
                const ret_info = @typeInfo(ret_type.?);

                var resp: ?HTTPResponse = null;
                comptime var should_resp = true;
                if (ret_info == .ErrorUnion) {
                    should_resp = ret_info.ErrorUnion.payload != void;
                }

                if (fields.len == 0) {
                    const ret = func();
                    if (should_resp) resp = ret;
                } else {
                    var args_tuple: std.meta.Tuple(&arg_types) = undefined;
                    inline for (&args_tuple) |*el| {
                        switch (@TypeOf(el.*)) {
                            HTTPRequest => el.* = req,
                            std.mem.Allocator => el.* = allocator,
                            else => unreachable,
                        }
                    }
                    const ret = @call(.auto, func, args_tuple);
                    if (should_resp) resp = ret;
                }

                return resp;
            }
        };
    }
};

fn GenServeFile(comptime path: []const u8) type {
    const extension = comptime getExtention(path);
    return struct {
        fn run(allocator: std.mem.Allocator) HTTPResponse {
            std.debug.print("serving file\n", .{});
            var file = std.fs.cwd().openFile(
                path,
                .{ .mode = .read_write },
            ) catch unreachable;
            defer file.close();

            const file_size = file.getEndPos() catch unreachable;

            const buffer = allocator.alloc(u8, file_size) catch unreachable;

            _ = file.readAll(buffer) catch unreachable;

            std.debug.print("file ext: {s}\n", .{extension});

            var resp = HTTPResponse.init(allocator, .OK, buffer);
            const content_type = std.meta.stringToEnum(ContentType, extension) orelse .plain;
            resp.headers.put("Content-Type", content_type.getString()) catch unreachable;
            return resp;
        }
    };
}

pub fn fileHandler(allocator: std.mem.Allocator, comptime path: []const u8) Handler {
    return Handler.init(allocator, GenServeFile(path).run);
}

fn getExtention(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        const c = path[i];
        if (c == '.') {
            break;
        }
    }
    const extension = blk: {
        var temp: [path.len - i - 1]u8 = undefined;
        for (0..temp.len) |j| {
            temp[j] = path[i + j + 1];
        }
        break :blk temp;
    };
    return &extension;
}

fn getExtentionRuntime(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(u8) {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        const c = path[i];
        if (c == '.') {
            break;
        }
    }
    var extension = std.ArrayList(u8).init(allocator);
    for (0..path.len - i - 1) |j| {
        try extension.append(path[i + j + 1]);
    }
    return extension;
}

fn GenServeDir(comptime path: []const u8) !type {
    return struct {
        fn run(allocator: std.mem.Allocator, request: HTTPRequest) HTTPResponse {
            const extension = getExtentionRuntime(allocator, request.url) catch unreachable;
            defer extension.deinit();

            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, request.url }) catch unreachable;
            std.debug.print("opening file at {s}\n", .{full_path});
            defer allocator.free(full_path);
            var file = std.fs.cwd().openFile(
                full_path,
                .{ .mode = .read_write },
            ) catch unreachable;
            defer file.close();

            const file_size = file.getEndPos() catch unreachable;

            const buffer = allocator.alloc(u8, file_size) catch unreachable;

            _ = file.readAll(buffer) catch unreachable;

            var resp = HTTPResponse.init(allocator, .OK, buffer);
            const content_type = std.meta.stringToEnum(ContentType, extension.items) orelse .plain;
            resp.headers.put("Content-Type", content_type.getString()) catch unreachable;
            return resp;
        }
    };
}

pub fn dirHandler(allocator: std.mem.Allocator, comptime path: []const u8) !Handler {
    const fucntion = try GenServeDir(path);
    return Handler.init(allocator, fucntion.run);
}
