const std = @import("std");
const Handler = @import("handler.zig").Handler;

const UrlNode = struct {
    segment: []const u8,
    children: std.StringHashMap(UrlNode),
    handler: ?Handler,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, segment: []const u8, handler: ?Handler) Self {
        return Self{
            .segment = segment,
            .children = std.StringHashMap(UrlNode).init(allocator),
            .allocator = allocator,
            .handler = handler,
        };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
        self.allocator.free(self.segment);
    }
};
