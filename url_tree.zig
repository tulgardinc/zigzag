const std = @import("std");
const Handler = @import("handler.zig").Handler;

pub const UrlNode = struct {
    segment: []const u8,
    children: std.StringHashMap(UrlNode),
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
        std.debug.print("freeing {s}\n", .{self.segment});
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.children.deinit();
        self.allocator.free(self.segment);
    }
};

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
