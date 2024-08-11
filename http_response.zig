const std = @import("std");

pub const ResponseCode = enum(usize) {
    OK = 200,

    pub fn getString(self: ResponseCode) []const u8 {
        return switch (self) {
            .OK => "OK",
        };
    }
};

pub const HTTPResponse = struct {
    response_code: ResponseCode,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, code: ResponseCode, body: []const u8) Self {
        return Self{
            .response_code = code,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .body = body,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    pub fn toString(self: Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.print(
            "HTTP/1.1 {d} {s}\n",
            .{
                @intFromEnum(self.response_code), self.response_code.getString(),
            },
        );

        try writer.print(
            "Content-Length: {d}\n",
            .{self.body.len},
        );

        var iter = self.headers.iterator();
        while (iter.next()) |e| {
            try writer.print(
                "{s}: {s}\n",
                .{ e.key_ptr.*, e.value_ptr.* },
            );
        }

        _ = try writer.write("\r\n\r\n");
        _ = try writer.write(self.body);

        return buffer;
    }
};
