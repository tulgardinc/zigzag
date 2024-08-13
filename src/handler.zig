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

/// Wraps a function that handles an endpoint
pub const Handler = struct {
    fn_run_ptr: *const fn (std.mem.Allocator, HTTPRequest) anyerror!?HTTPResponse,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime func: anytype) Self {
        const run_fn = GenRunFn(func).run;
        return Self{
            .allocator = allocator,
            .fn_run_ptr = run_fn,
        };
    }

    pub fn run(self: Self, request: HTTPRequest) !?HTTPResponse {
        return try self.fn_run_ptr(self.allocator, request);
    }

    /// Generates a function that allows for the underlying endpoint function to be
    /// called without having to know it's type
    fn GenRunFn(comptime func: anytype) type {
        return struct {
            fn run(allocator: std.mem.Allocator, req: HTTPRequest) !?HTTPResponse {
                const args = std.meta.ArgsTuple(@TypeOf(func));
                const fields = std.meta.fields(args);

                comptime var arg_types: [fields.len]type = undefined;
                inline for (fields, 0..) |f, i| {
                    arg_types[i] = f.type;
                }

                const func_info = @typeInfo(@TypeOf(func));
                const ret_type = func_info.Fn.return_type;
                const ret_info = @typeInfo(ret_type.?);

                // the http response
                var resp: ?HTTPResponse = null;
                // whether the handler returns a response at all
                comptime var should_resp = true;
                if (ret_info == .ErrorUnion) {
                    should_resp = ret_info.ErrorUnion.payload != void;
                }

                if (fields.len == 0) {
                    // if the function takes no arguments, just call it.
                    const ret = func();
                    if (should_resp) resp = ret;
                } else {
                    // otherwise fill the arguments/injections
                    var args_tuple: std.meta.Tuple(&arg_types) = undefined;
                    inline for (&args_tuple) |*el| {
                        switch (@TypeOf(el.*)) {
                            HTTPRequest => el.* = req,
                            std.mem.Allocator => el.* = allocator,
                            else => unreachable,
                        }
                    }
                    // call the function
                    const ret = @call(.auto, func, args_tuple);
                    if (should_resp) {
                        // handle it if there is an error
                        if (ret_info == .ErrorUnion) {
                            resp = try ret;
                        } else {
                            resp = ret;
                        }
                    }
                }

                return resp;
            }
        };
    }
};

/// Generates a function that returns a file for an endpoint
fn GenServeFile(comptime path: []const u8) type {
    const extension = comptime getExtention(path);
    return struct {
        fn run(allocator: std.mem.Allocator) !HTTPResponse {
            std.debug.print("serving file {s}\n", .{path});
            var file = try std.fs.cwd().openFile(
                path,
                .{ .mode = .read_write },
            );
            defer file.close();

            const file_size = try file.getEndPos();

            const buffer = try allocator.alloc(u8, file_size);

            _ = try file.readAll(buffer);

            std.debug.print("file ext: {s}\n", .{extension});

            var resp = HTTPResponse.init(allocator, .OK, buffer);
            // Get the content type from the file extension
            const content_type = std.meta.stringToEnum(ContentType, extension) orelse .plain;
            try resp.headers.put("Content-Type", content_type.getString());
            return resp;
        }
    };
}

/// Returns a handler that serves a file
pub fn fileHandler(allocator: std.mem.Allocator, comptime path: []const u8) Handler {
    return Handler.init(allocator, GenServeFile(path).run);
}

/// Gets the extension from a file name during comptime
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

/// Gets the extension from a file during runtime
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

/// Generates a function that serves the contents of a directory for
/// an endpoint
fn GenServeDir(comptime path: []const u8) !type {
    return struct {
        fn run(allocator: std.mem.Allocator, request: HTTPRequest) !HTTPResponse {
            const extension = try getExtentionRuntime(allocator, request.url);
            defer extension.deinit();

            // Make sure file is within the specified directory to avoid attacks with ../ etc.
            const normalized_path = try std.fs.realpathAlloc(allocator, path);
            defer allocator.free(normalized_path);

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, request.url });
            defer allocator.free(full_path);

            const normalized_request_path = std.fs.realpathAlloc(allocator, full_path) catch return HTTPResponse.init(allocator, .NOT_FOUND, "");
            defer allocator.free(normalized_request_path);

            if (!std.mem.startsWith(u8, normalized_request_path, normalized_path)) return error.WrongPath;

            var file = try std.fs.openFileAbsolute(
                normalized_request_path,
                .{ .mode = .read_write },
            );
            defer file.close();

            const file_size = try file.getEndPos();

            const buffer = try allocator.alloc(u8, file_size);

            _ = try file.readAll(buffer);

            var resp = HTTPResponse.init(allocator, .OK, buffer);
            // Get the content type from the file extension
            const content_type = std.meta.stringToEnum(ContentType, extension.items) orelse .plain;
            try resp.headers.put("Content-Type", content_type.getString());
            return resp;
        }
    };
}

/// Returns a handler that serves a directory
pub fn dirHandler(allocator: std.mem.Allocator, comptime path: []const u8) !Handler {
    const fucntion = try GenServeDir(path);
    return Handler.init(allocator, fucntion.run);
}
