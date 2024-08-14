const std = @import("std");

/// Represents an HTTP response from the server
pub const HTTPResponse = struct {
    response_code: usize,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, code: usize, body: []const u8) Self {
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

    /// Converts the HTTPResponse instance into string
    pub fn toString(self: Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.print("HTTP/1.1 {d}\n", .{self.response_code});

        try writer.print(
            "Content-Length: {d}\n",
            .{self.body.len + 1},
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
