const std = @import("std");
const linux = std.os.linux;
const errno = std.posix.errno;
const HTTPRequest = @import("http_request.zig").HTTPRequest;
const Methods = @import("http_request.zig").Methods;
const HTTPResponse = @import("http_response.zig").HTTPResponse;
const ResponseCode = @import("http_response.zig").ResponseCode;
const Handler = @import("handler.zig").Handler;
const h = @import("handler.zig");
const UrlNode = @import("url_tree.zig").UrlNode;
const UrlSegments = @import("url_tree.zig").UrlSegments;

pub const Zigzag = struct {
    allocator: std.mem.Allocator,
    handlers: std.AutoHashMap(Methods, UrlNode),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .handlers = std.AutoHashMap(Methods, UrlNode).init(allocator),
        };
    }

    fn deinitNodeTree(node: *UrlNode) void {
        if (node.children.count() == 0) {
            node.deinit();
        } else {
            var iter = node.children.valueIterator();
            while (iter.next()) |child| {
                std.debug.print("called on: {s}\n", .{child.segment});
                deinitNodeTree(child);
            }
            node.deinit();
        }
    }

    pub fn deinit(self: *Self) void {
        var iter = self.handlers.valueIterator();
        while (iter.next()) |root| {
            deinitNodeTree(root);
        }
        self.handlers.deinit();
    }

    pub fn start(self: *Self, ip_address: [4]u8, port: u16) !void {
        try self.openSocket(ip_address, port);
    }

    pub fn serveFile(self: *Self, comptime url: []const u8, comptime path: []const u8) !void {
        const handler = h.fileHandler(self.allocator, path);
        try self.assignHandler(.GET, url, handler);
    }

    pub fn serveDir(self: *Self, comptime url: []const u8, comptime path: []const u8) !void {
        const handler = try h.dirHandler(self.allocator, path);
        const new_url = url ++ "/*";
        try self.assignHandler(.GET, new_url, handler);
    }

    fn parseUrl(allocator: std.mem.Allocator, url: []const u8) !UrlSegments {
        if (url[0] != '/') return error.WrongUrlStructure;
        var segments = UrlSegments.init(allocator);
        var first_segment = std.ArrayList(u8).init(allocator);
        try first_segment.append('/');
        try segments.segments.append(first_segment);
        var i: usize = 1;
        outer: while (i < url.len) {
            var segment = std.ArrayList(u8).init(allocator);
            for (i..url.len) |j| {
                if (url[j] == '/') {
                    i = j + 1;
                    try segments.segments.append(segment);
                    continue :outer;
                }
                try segment.append(url[j]);
                if (j == url.len - 1) {
                    try segments.segments.append(segment);
                }
            }
            break;
        }
        return segments;
    }

    pub fn GET(self: *Self, url: []const u8, comptime func: anytype) !void {
        try self.assignHandler(.GET, url, Handler.init(self.allocator, func));
    }

    pub fn assignHandler(self: *Self, method: Methods, url: []const u8, handler: Handler) !void {
        const result = try self.handlers.getOrPut(method);
        var segments = try parseUrl(self.allocator, url);
        defer segments.deinit();

        if (!result.found_existing) {
            const new_node = try UrlNode.init(self.allocator, "/", null);
            std.debug.print("creating root\n", .{});
            result.value_ptr.* = new_node;
        }
        var prev_node_ptr = result.value_ptr;
        if (segments.segments.items.len == 1) {
            std.debug.print("assigning handler to root: {s}\n", .{prev_node_ptr.segment});
            prev_node_ptr.handler = handler;
            return;
        }
        for (1..segments.segments.items.len) |i| {
            const segment = segments.segments.items[i];
            var child_ptr = prev_node_ptr.children.getPtr(segment.items);
            if (child_ptr == null) {
                std.debug.print("creating node with segment: {s}\n", .{segment.items});
                const new_node = try UrlNode.init(self.allocator, segment.items, null);
                const key = try self.allocator.alloc(u8, segment.items.len);
                @memcpy(key, segment.items);
                const put_result = try prev_node_ptr.children.getOrPutValue(key, new_node);
                child_ptr = put_result.value_ptr;
            }
            if (i == segments.segments.items.len - 1) {
                std.debug.print("assigning segment handler: {s}\n", .{child_ptr.?.*.segment});
                child_ptr.?.handler = handler;
            }
        }
    }

    pub fn Response404(self: *Self) HTTPResponse {
        return HTTPResponse.init(self.allocator, .NOT_FOUND, "");
    }

    fn recurseUrlTree(
        self: *Self,
        request: HTTPRequest,
        segments: *const UrlSegments,
        index: usize,
        cur_node_ptr: *const UrlNode,
    ) ?HTTPResponse {
        std.debug.print("recursing node segment {s}\n", .{segments.segments.items[index].items});
        if (index == segments.segments.items.len - 1) {
            std.debug.print("last node is {s} with handler {any}\n", .{ cur_node_ptr.segment, cur_node_ptr.handler });
            if (cur_node_ptr.handler) |handler| {
                std.debug.print("returning handler\n", .{});
                return handler.run(request);
            }
            return self.Response404();
        }
        const next_segment = segments.segments.items[index + 1];
        std.debug.print("next segment {s}\n", .{next_segment.items});
        if (cur_node_ptr.children.getPtr(next_segment.items)) |next_node_ptr| {
            var resp = self.recurseUrlTree(
                request,
                segments,
                index + 1,
                next_node_ptr,
            );
            if (resp != null and resp.?.response_code == .NOT_FOUND) {
                if (cur_node_ptr.children.getPtr("*")) |wild_ptr| {
                    resp = wild_ptr.handler.?.run(request);
                }
            }
            return resp;
        } else if (cur_node_ptr.children.getPtr("*")) |wild_ptr| {
            return wild_ptr.handler.?.run(request);
        } else {
            std.debug.print("found 404\n", .{});
            return self.Response404();
        }
    }

    fn runHandler(self: *Self, request: HTTPRequest) !?HTTPResponse {
        var segments = try parseUrl(self.allocator, request.url);
        defer segments.deinit();
        const root_node = self.handlers.get(request.method);
        if (root_node) |n| {
            std.debug.print("entry node segment: {s}\n", .{n.segment});
            return self.recurseUrlTree(
                request,
                &segments,
                0,
                &n,
            );
        }
        // METHOD NOT SUPPORTED IMPLEMENT
        return self.Response404();
    }

    fn openSocket(self: *Self, ip_address: [4]u8, port: u16) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        //ipv4 domain
        const domain = linux.AF.INET;
        // Error checked, ordered two way communication
        const socket_type = linux.SOCK.STREAM;
        // the default protocol
        const socket_protocol = 0;

        // get file descriptor pointing to a socket
        const file_descriptor: linux.fd_t = @intCast(linux.socket(domain, socket_type, socket_protocol));
        if (file_descriptor == -1) return error.FailedToGetDescriptor;

        const enable: u8 = 1;
        _ = linux.setsockopt(
            file_descriptor,
            linux.SOL.SOCKET,
            linux.SO.REUSEADDR,
            @ptrCast(&enable),
            @sizeOf(@TypeOf(enable)),
        );

        // bind socket to an adderss
        const addr = std.net.Ip4Address.init(ip_address, port);
        const bind_errno = linux.bind(file_descriptor, @ptrCast(&addr.sa), addr.getOsSockLen());
        if (bind_errno != 0) {
            _ = linux.close(file_descriptor);
            return error.FailedToBind;
        }

        // start listeninng to the socket
        const max_queue = 10;
        const listen_errno = linux.listen(file_descriptor, max_queue);
        if (listen_errno != 0) return error.FailedToListen;

        // Start loop
        while (true) {
            // accpet pending connection by creating a new socket that is only
            // to communicate with that new connection
            const con_addr_ptr = try allocator.create(std.net.Ip4Address);
            defer allocator.destroy(con_addr_ptr);
            var sock_len = con_addr_ptr.getOsSockLen();
            const con_fd: linux.fd_t = @intCast(linux.accept(
                file_descriptor,
                @ptrCast(&con_addr_ptr.*.sa),
                &sock_len,
            ));
            if (con_fd == -1) return error.FailedToAccept;

            // connect to the accpeted connection
            const connect_errno = linux.connect(
                con_fd,
                @ptrCast(&con_addr_ptr.*.sa),
                con_addr_ptr.getOsSockLen(),
            );
            if (connect_errno == -1) return error.FailedToConnect;

            // Receive request
            const buf = try allocator.alloc(u8, 1000);
            defer allocator.free(buf);
            const req_len = linux.read(con_fd, @ptrCast(buf), buf.len);
            if (req_len == 0) {
                _ = linux.shutdown(con_fd, linux.SHUT.RDWR);
                continue;
            }
            if (req_len == -1) return error.FailedToRead;

            const request = try HTTPRequest.parse(allocator, buf[0..req_len]);

            const resp = try self.runHandler(request);

            if (resp) |r| {
                const resp_buf = try r.toString();
                std.debug.print("body: {s}\n", .{resp_buf.items});

                // send response
                _ = linux.sendto(
                    con_fd,
                    @ptrCast(resp_buf.items),
                    resp_buf.items.len,
                    0,
                    @ptrCast(&con_addr_ptr.*.sa),
                    sock_len,
                );
            }
        }

        _ = linux.close(file_descriptor);
    }
};

test "parse url" {
    const allocator = std.testing.allocator;

    var segments = try Zigzag.parseUrl(allocator, "/test/inner");
    defer segments.deinit();

    try std.testing.expect(std.mem.eql(u8, segments.segments.items[0].items, "/"));
    try std.testing.expect(std.mem.eql(u8, segments.segments.items[1].items, "test"));
    try std.testing.expect(std.mem.eql(u8, segments.segments.items[2].items, "inner"));
}

test "url tree" {
    const allocator = std.testing.allocator;

    var zag = Zigzag.init(allocator);
    defer zag.deinit();

    //try zag.GET("/", handleGet);
    try zag.serveFile("/", "public/index.html");
    try zag.serveFile("/style.css", "public/style.css");

    const message = try std.fmt.allocPrint(allocator, "{s}", .{"GET / HTTP/1.1\n"});
    defer allocator.free(message);
    var request = try HTTPRequest.parse(allocator, message);
    defer request.deinit();

    var resp = (try zag.runHandler(request)).?;
    defer resp.deinit();
    std.debug.print("====================\n", .{});
    std.debug.print("body: {s}\n", .{resp.body});
    std.debug.print("code: {d}\n", .{@intFromEnum(resp.response_code)});
}

test "directory" {
    const allocator = std.testing.allocator;

    var zag = Zigzag.init(allocator);
    defer zag.deinit();

    //try zag.GET("/", handleGet);
    try zag.serveFile("/", "public/index.html");
    try zag.serveDir("/", "public");

    const message = try std.fmt.allocPrint(allocator, "{s}", .{"GET /style.css HTTP/1.1\n"});
    defer allocator.free(message);
    var request = try HTTPRequest.parse(allocator, message);
    defer request.deinit();

    var resp = (try zag.runHandler(request)).?;
    defer resp.deinit();
    std.debug.print("====================\n", .{});
    std.debug.print("body: {s}\n", .{resp.body});
    std.debug.print("code: {d}\n", .{@intFromEnum(resp.response_code)});
}
