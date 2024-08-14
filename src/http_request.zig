const std = @import("std");

/// Request methods
pub const Methods = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,
};

/// Represents an HTTP request from the client
pub const HTTPRequest = struct {
    allocator: std.mem.Allocator,
    method: Methods,
    url: []const u8,
    headers: std.StringHashMap([]const u8),
    query_params: ?std.StringHashMap([]const u8),

    const Self = @This();

    fn getQueryParams(allocator: std.mem.Allocator, query: []const u8) !std.StringHashMap([]const u8) {
        var query_map = std.StringHashMap([]const u8).init(allocator);
        var key_start: usize = 0;
        var key_end: usize = 0;
        for (query, 0..query.len) |c, i| {
            if (c == '=') {
                key_end = i;
            } else if (c == '&' or c == '\n') {
                std.debug.print("key: {s} value {s}\n", .{ query[key_start..key_end], query[key_end + 1 .. i] });
                try query_map.put(query[key_start..key_end], query[key_end + 1 .. i]);
                key_start = i + 1;
            }
        }
        return query_map;
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        if (self.query_params != null) {
            self.query_params.?.deinit();
        }
    }

    /// parse an HTTP request into an HTTPRequest instance
    pub fn parse(allocator: std.mem.Allocator, message: []const u8) !Self {
        var line_start: usize = 0;
        var curr_line: usize = 1;
        var message_type: Methods = undefined;
        var url: ?[]const u8 = null;
        var headers = std.StringHashMap([]const u8).init(allocator);
        var query_params: std.StringHashMap([]const u8) = undefined;
        char_loop: for (message, 0..) |char, line_end| {
            if (char == '\n') {
                if (curr_line == 1) {
                    var space_index: usize = 0;
                    const line = message[line_start .. line_end + 1];
                    // Get the method and the url (slug)
                    for (line, 0..) |c, index| {
                        if (c == '?') {
                            url = line[space_index + 1 .. index];
                            line_start = line_end + 1;
                            curr_line += 1;
                            query_params = try getQueryParams(allocator, line[index + 1 ..]);
                            continue :char_loop;
                        }
                        if (c == ' ') {
                            if (space_index == 0) {
                                message_type = std.meta.stringToEnum(Methods, line[0..index]).?;
                                space_index = index;
                                continue;
                            } else {
                                url = line[space_index + 1 .. index];
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
            .query_params = query_params,
            .url = url.?,
        };
    }
};

test "url parse" {
    const allocator = std.testing.allocator;
    const arena_alloc = std.heap.ArenaAllocator.init(allocator);
    defer arena_alloc.deinit();

    const message = "GET /search?item1=test1&item2=test2\n";

    var req = try HTTPRequest.parse(allocator, @constCast(message[0..]));
    defer req.deinit();

    const item1 = req.query_params.?.get("item1").?;
    const item2 = req.query_params.?.get("item2").?;

    try std.testing.expect(std.mem.eql(u8, item1, "test1"));
    try std.testing.expect(std.mem.eql(u8, item2, "test2"));
}
