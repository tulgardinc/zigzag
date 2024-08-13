const std = @import("std");

/// Request methods
pub const Methods = enum {
    GET,
};

/// Represents an HTTP request from the client
pub const HTTPRequest = struct {
    allocator: std.mem.Allocator,
    method: Methods,
    url: []const u8,
    headers: std.StringHashMap([]u8),

    const Self = @This();

    /// parse an HTTP request into an HTTPRequest instance
    pub fn parse(allocator: std.mem.Allocator, message: []u8) !Self {
        var line_start: usize = 0;
        var curr_line: usize = 1;
        var message_type: Methods = undefined;
        var url: []u8 = undefined;
        var headers = std.StringHashMap([]u8).init(allocator);
        char_loop: for (message, 0..) |char, line_end| {
            if (char == '\n') {
                if (curr_line == 1) {
                    var space_index: usize = 0;
                    const line = message[line_start..line_end];
                    // Get the method and the url (slug)
                    for (line, 0..) |c, index| {
                        if (c == ' ') {
                            if (space_index == 0) {
                                message_type = std.meta.stringToEnum(Methods, line[0..index]).?;
                                space_index = index;
                                continue;
                            } else {
                                const url_slice = line[space_index + 1 .. index];
                                url = try allocator.alloc(u8, url_slice.len);
                                @memcpy(url, url_slice);
                                line_start = line_end + 1;
                                curr_line += 1;
                                continue :char_loop;
                            }
                        }
                    }
                }
                // Get headers
                const line = message[line_start..line_end];
                for (line, 0..) |c, i| {
                    if (c == ':') {
                        try headers.put(line[0..i], line[i + 2 ..]);
                        break;
                    }
                }
                line_start = line_end + 1;
                curr_line += 1;
            }
        }
        return Self{
            .method = message_type,
            .allocator = allocator,
            .headers = headers,
            .url = url,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.url);
    }
};
