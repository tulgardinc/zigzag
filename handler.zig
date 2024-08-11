const std = @import("std");
const HTTPRequest = @import("http_request.zig").HTTPRequest;
const HTTPResponse = @import("http_response.zig").HTTPResponse;

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

fn GenStaticRunFn(comptime path: []const u8) type {
    return struct {
        fn run(allocator: std.mem.Allocator) HTTPResponse {
            var file = std.fs.cwd().openFile(
                path,
                .{ .mode = .read_write },
            ) catch unreachable;
            defer file.close();

            const file_size = file.getEndPos() catch unreachable;

            const buffer = allocator.alloc(u8, file_size) catch unreachable;

            _ = file.readAll(buffer) catch unreachable;

            var resp = HTTPResponse.init(allocator, .OK, buffer);
            resp.headers.put("Content-Type", "text/html; charset=UTF-8") catch unreachable;
            return resp;
        }
    };
}

pub fn staticHandler(allocator: std.mem.Allocator, comptime path: []const u8) Handler {
    return Handler.init(allocator, GenStaticRunFn(path).run);
}
