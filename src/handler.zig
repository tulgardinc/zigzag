const std = @import("std");
const HTTPRequest = @import("http_request.zig").HTTPRequest;
const HTTPResponse = @import("http_response.zig").HTTPResponse;

pub const PathParameters = std.StringHashMap([]const u8);

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

const PathParameter = struct {
    index: usize,
    name: []const u8,
};

fn getParameters(comptime path: []const u8) []const PathParameter {
    comptime var parameters: []const PathParameter = &.{};
    var start_i: i32 = 0;
    var segment_index: usize = 0;
    inline for (path[1..], 1..) |c, i| {
        if (c == '<' and (path[i - 1] == '/')) {
            start_i = i + 1;
        }
        if (c == '/') {
            start_i = -1;
            segment_index += 1;
        }
        if (c == '>' and start_i != -1 and (i == path.len - 1 or path[i + 1] == '/')) {
            const param = PathParameter{
                .index = segment_index,
                .name = path[@intCast(start_i)..i],
            };
            parameters = parameters ++ .{param};
        }
    }
    return parameters;
}

fn getPathParamValues(param_info: []const PathParameter, url: []const u8, result_array: [][]const u8) void {
    var par_start: usize = 0;
    var segment_index: usize = 0;
    var param_index: usize = 0;
    for (url[1..], 1..) |c, i| {
        if (c == '/' or i == url.len - 1) {
            if (segment_index == param_info[param_index].index) {
                const fin_index = if (c == '/') i else i + 1;
                result_array[param_index] = url[par_start..fin_index];
                param_index += 1;
                if (i == url.len - 1) return;
            }
            segment_index += 1;
            if (segment_index == param_info[param_index].index) {
                par_start = i + 1;
            }
        }
    }
}

/// Wraps a function that handles an endpoint
pub const Handler = struct {
    fn_run_ptr: *const fn (std.mem.Allocator, HTTPRequest) anyerror!HTTPResponse,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime path: []const u8, comptime func: anytype) Self {
        const run_fn = GenRunFn(path, func).run;
        return Self{
            .allocator = allocator,
            .fn_run_ptr = run_fn,
        };
    }

    pub fn run(self: Self, request: HTTPRequest) !HTTPResponse {
        return try self.fn_run_ptr(self.allocator, request);
    }

    /// Generates a function that allows for the underlying endpoint function to be
    /// called without having to know it's type
    fn GenRunFn(comptime path: []const u8, comptime func: anytype) type {
        return struct {
            fn run(allocator: std.mem.Allocator, req: HTTPRequest) !HTTPResponse {
                const args = std.meta.ArgsTuple(@TypeOf(func));
                const fields = std.meta.fields(args);
                const path_param_info = comptime getParameters(path);

                var path_params = std.StringHashMap([]const u8).init(allocator);
                defer path_params.deinit();

                if (path_param_info.len > 0) {
                    const path_param_values = try allocator.alloc([]const u8, path_param_info.len);
                    defer allocator.free(path_param_values);
                    getPathParamValues(path_param_info, req.url, path_param_values);

                    for (0..path_param_values.len) |i| {
                        try path_params.put(path_param_info[i].name, path_param_values[i]);
                    }
                }

                comptime var arg_types: [fields.len]type = undefined;
                inline for (fields, 0..) |f, i| {
                    arg_types[i] = f.type;
                }

                const func_info = @typeInfo(@TypeOf(func));
                const ret_type = func_info.Fn.return_type;
                const ret_info = @typeInfo(ret_type.?);

                // the http response
                var resp: HTTPResponse = undefined;
                if (fields.len == 0) {
                    // if the function takes no arguments, just call it.
                    const ret = func();
                    resp = ret;
                } else {
                    // otherwise fill the arguments/injections
                    var args_tuple: std.meta.Tuple(&arg_types) = undefined;
                    inline for (&args_tuple) |*el| {
                        switch (@TypeOf(el.*)) {
                            HTTPRequest => el.* = req,
                            std.mem.Allocator => el.* = allocator,
                            PathParameters => el.* = path_params,
                            else => unreachable,
                        }
                    }
                    // call the function
                    const ret = @call(.auto, func, args_tuple);
                    // handle it if there is an error
                    if (ret_info == .ErrorUnion) {
                        resp = try ret;
                    } else {
                        resp = ret;
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
            var file = try std.fs.cwd().openFile(
                path,
                .{ .mode = .read_write },
            );
            defer file.close();

            const file_size = try file.getEndPos();

            const buffer = try allocator.alloc(u8, file_size);

            _ = try file.readAll(buffer);

            var resp = HTTPResponse.init(allocator, 200, buffer);
            // Get the content type from the file extension
            const content_type = std.meta.stringToEnum(ContentType, extension) orelse .plain;
            try resp.headers.put("Content-Type", content_type.getString());
            return resp;
        }
    };
}

/// Returns a handler that serves a file
pub fn fileHandler(allocator: std.mem.Allocator, comptime path: []const u8) Handler {
    return Handler.init(allocator, path, GenServeFile(path).run);
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

            const normalized_request_path = std.fs.realpathAlloc(allocator, full_path) catch return HTTPResponse.init(allocator, 404, "");
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

            var resp = HTTPResponse.init(allocator, 200, buffer);
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
    return Handler.init(allocator, path, fucntion.run);
}

test "get parameters" {
    const params = comptime getParameters("/url/<test1>/path/<test2>/no<parm>/<no/param>");

    try std.testing.expect(std.mem.eql(u8, params[0].name, "test1"));
    try std.testing.expect(params[0].index == 1);
    try std.testing.expect(std.mem.eql(u8, params[1].name, "test2"));
    try std.testing.expect(params[1].index == 3);
    try std.testing.expect(params.len == 2);
}

test "get param values" {
    const input = "/segment/value1/second_segment/value2";

    const param_info = [_]PathParameter{
        PathParameter{ .name = "test1", .index = 1 },
        PathParameter{ .name = "test2", .index = 3 },
    };

    const allocator = std.testing.allocator;
    const results = try allocator.alloc([]const u8, 2);
    defer allocator.free(results);

    getPathParamValues(&param_info, input, results);

    try std.testing.expect(std.mem.eql(u8, results[0], "value1"));
    try std.testing.expect(std.mem.eql(u8, results[1], "value2"));
}
