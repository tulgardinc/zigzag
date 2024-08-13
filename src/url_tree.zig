const std = @import("std");
const Handler = @import("handler.zig").Handler;

/// Datastructure to build a URL tree for routing
pub const UrlNode = struct {
    // the url segment of the node
    segment: []const u8,
    // child segments
    children: std.StringHashMap(UrlNode),
    // the handler for the endpoint if any exists
    handler: ?Handler,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, segment: []const u8, handler: ?Handler) !Self {
        const temp = try allocator.alloc(u8, segment.len);
        @memcpy(temp, segment);
        return Self{
            .segment = temp,
            .children = std.StringHashMap(UrlNode).init(allocator),
            .allocator = allocator,
            .handler = handler,
        };
    }

    pub fn deinit(self: *Self) void {
        var key_iter = self.children.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.children.deinit();
        self.allocator.free(self.segment);
    }
};

/// A datastructure that makes it easier to interact with URL segments
pub const UrlSegments = struct {
    segments: std.ArrayList(std.ArrayList(u8)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .segments = std.ArrayList(std.ArrayList(u8)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.segments.items) |segment| {
            segment.deinit();
        }
        self.segments.deinit();
    }
};
