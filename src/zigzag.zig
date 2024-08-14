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

/// Represents an open connection
const Connection = struct {
    timeout: u16,
    resp_count: u16,
    last_request: i64,
};

/// The http server
pub const Zigzag = struct {
    allocator: std.mem.Allocator,
    /// Url tree used to find handlers on request
    handlers: std.AutoHashMap(Methods, UrlNode),
    /// Map of active TCP connections
    connections: std.AutoHashMap(linux.fd_t, Connection),
    /// File descriptors to read from in the event loop
    read_fds: std.ArrayList(linux.fd_t),
    /// The file descriptor of the active socket
    main_fd: ?linux.fd_t = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const self = Self{
            .allocator = allocator,
            .handlers = std.AutoHashMap(Methods, UrlNode).init(allocator),
            .read_fds = std.ArrayList(linux.fd_t).init(allocator),
            .connections = std.AutoHashMap(linux.fd_t, Connection).init(allocator),
        };
        return self;
    }

    /// Recursively deinits the nodes in the node tree
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
        self.connections.deinit();
        self.handlers.deinit();
    }

    /// Starts the server at given address and port
    pub fn start(self: *Self, ip_address: [4]u8, port: u16) !void {
        try self.startEventLoop(ip_address, port);
    }

    /// Serves a file from the specified endpoint
    pub fn serveFile(self: *Self, comptime url: []const u8, comptime path: []const u8) !void {
        const handler = h.fileHandler(self.allocator, path);
        try self.assignHandler(.GET, url, handler);
    }

    /// Maps url requests to files in a directory
    pub fn serveDir(self: *Self, comptime url: []const u8, comptime path: []const u8) !void {
        const handler = try h.dirHandler(self.allocator, path);
        comptime var new_url: []const u8 = &.{};
        if (url.len == 1) {
            new_url = url ++ "*";
        } else {
            new_url = url ++ "/*";
        }
        try self.assignHandler(.GET, new_url, handler);
    }

    /// Helper function to divide url into segments
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

    /// Binds a given function to a given endpoint on provided request
    pub fn addEndpoint(self: *Self, method: Methods, comptime url: []const u8, comptime func: anytype) !void {
        try self.assignHandler(method, url, Handler.init(self.allocator, url, func));
    }

    /// Assigns a handler to an endpoint in the URL tree
    pub fn assignHandler(self: *Self, method: Methods, url: []const u8, handler: Handler) !void {
        const result = try self.handlers.getOrPut(method);
        var segments = try parseUrl(self.allocator, url);
        defer segments.deinit();

        if (!result.found_existing) {
            // Initiate root node
            const new_node = try UrlNode.init(self.allocator, "/", null);
            result.value_ptr.* = new_node;
        }
        var prev_node_ptr = result.value_ptr;
        if (segments.segments.items.len == 1) {
            // If the endpoint is the root segment then assign and exit early
            prev_node_ptr.handler = handler;
            return;
        }
        for (1..segments.segments.items.len) |i| {
            // Loop through the segments of the endpoint
            const segment = segments.segments.items[i];
            // Check if segment is a parameter
            const is_param = segment.items[0] == '<' and segment.items[segment.items.len - 1] == '>';
            // Assign correct segment
            const segment_str = if (is_param) "<param>" else segment.items;
            var child_ptr = prev_node_ptr.children.getPtr(segment_str);
            if (child_ptr == null) {
                // If node for the segment doesn't exist in the tree, create it
                const new_node = try UrlNode.init(self.allocator, segment_str, null);
                const key = try self.allocator.alloc(u8, segment_str.len);
                @memcpy(key, segment_str);
                const put_result = try prev_node_ptr.children.getOrPutValue(key, new_node);
                child_ptr = put_result.value_ptr;
            }
            if (i == segments.segments.items.len - 1) {
                // Assign the handler to the final segment of the url.
                child_ptr.?.handler = handler;
            }
            prev_node_ptr = child_ptr.?;
        }
    }

    /// Helper function to return error 404
    pub fn Response404(self: *Self) HTTPResponse {
        return HTTPResponse.init(self.allocator, 404, "");
    }

    /// Helper function to return error 500
    pub fn Response500(self: *Self) HTTPResponse {
        return HTTPResponse.init(self.allocator, 500, "");
    }

    /// Recursively go through the URL tree and call the specified handler in the request
    fn recurseUrlTree(
        self: *Self,
        request: HTTPRequest,
        segments: *const UrlSegments,
        index: usize,
        cur_node_ptr: *const UrlNode,
    ) !HTTPResponse {
        if (index == segments.segments.items.len - 1) {
            // If on the last segment
            if (cur_node_ptr.handler) |handler| {
                // If this segment is an endpoint run the handler
                return try handler.run(request);
            }
            // If the segment is not an endpoint then 404
            return self.Response404();
        }
        const next_segment = segments.segments.items[index + 1];
        if (cur_node_ptr.children.getPtr(next_segment.items)) |next_node_ptr| {
            // If the segment has children then move into them
            const resp = try self.recurseUrlTree(
                request,
                segments,
                index + 1,
                next_node_ptr,
            );
            if (resp.response_code != 404) {
                return resp;
            }
        }
        if (cur_node_ptr.children.getPtr("<param>")) |param_ptr| {
            const resp = try self.recurseUrlTree(
                request,
                segments,
                index + 1,
                param_ptr,
            );
            if (resp.response_code != 404) {
                return resp;
            }
        }
        if (cur_node_ptr.children.getPtr("*")) |wild_ptr| {
            // If the segment had no children but has a fallback
            return wild_ptr.handler.?.run(request);
        }
        std.debug.print("segment {s} found 404\n", .{cur_node_ptr.segment});
        return self.Response404();
    }

    fn debugUrlTreesRecurse(allocator: std.mem.Allocator, node: *const UrlNode, depth: usize) !void {
        const padding = try allocator.alloc(u8, depth * 4);
        defer allocator.free(padding);
        @memset(padding, ' ');
        var handler: []const u8 = undefined;
        if (node.handler != null) {
            handler = " (f)";
        } else {
            handler = &.{};
        }
        std.debug.print("{s}- {s}{s}\n", .{ padding, node.segment, handler });

        var child_iter = node.children.valueIterator();
        while (child_iter.next()) |child| {
            try debugUrlTreesRecurse(allocator, child, depth + 1);
        }
    }

    fn debugUrlTrees(self: Self) !void {
        std.debug.print("=========URL=TREE=========\n", .{});
        var handler_iter = self.handlers.iterator();
        while (handler_iter.next()) |entry| {
            std.debug.print("Starting Tree: {any}\n", .{entry.key_ptr.*});
            std.debug.print("--------------------------\n", .{});
            try debugUrlTreesRecurse(self.allocator, entry.value_ptr, 0);
        }
        std.debug.print("==========================\n", .{});
    }

    /// runs a handler based on a request
    fn runHandler(self: *Self, request: HTTPRequest) !HTTPResponse {
        var segments = try parseUrl(self.allocator, request.url);
        defer segments.deinit();
        const root_node = self.handlers.get(request.method);

        if (root_node) |n| {
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

    fn handleActiveConnections(self: *Self) void {
        var iter = self.connections.iterator();
        while (iter.next()) |e| {
            if (std.time.timestamp() - e.value_ptr.last_request >= e.value_ptr.timeout) {
                _ = linux.shutdown(e.key_ptr.*, linux.SHUT.RDWR);
                _ = self.connections.remove(e.key_ptr.*);
            }
        }
    }

    fn startEventLoop(self: *Self, ip_address: [4]u8, port: u16) !void {
        try self.debugUrlTrees();

        // ipv4 domain
        const domain = linux.AF.INET;
        // Error checked, ordered two way communication
        const socket_type = linux.SOCK.STREAM;
        // the default protocol
        const socket_protocol = 0;

        // get the main file descriptor, for the socket
        self.main_fd = @intCast(linux.socket(domain, socket_type, socket_protocol));
        if (self.main_fd.? == -1) return error.FailedToGetDescriptor;

        // set reusable so the so the socket is immidiately ready for reuse after
        // shutdown
        const enable: c_int = 1;
        _ = linux.setsockopt(
            self.main_fd.?,
            linux.SOL.SOCKET,
            linux.SO.REUSEADDR,
            @ptrCast(&enable),
            @as(std.c.socklen_t, @sizeOf(@TypeOf(enable))),
        );

        // bind socket to an adderss
        const addr = std.net.Ip4Address.init(ip_address, port);
        const bind_errno = linux.bind(self.main_fd.?, @ptrCast(&addr.sa), addr.getOsSockLen());
        if (bind_errno != 0) {
            _ = linux.close(self.main_fd.?);
            return error.FailedToBind;
        }

        // start listeninng to the socket
        const max_queue = 10;
        const listen_errno = linux.listen(self.main_fd.?, max_queue);
        if (listen_errno != 0) return error.FailedToListen;

        // add the socket fd to be listened to by epoll
        try self.read_fds.append(self.main_fd.?);
        const epoll_fd: linux.fd_t = @intCast(linux.epoll_create());
        var epoll_socket_ev = linux.epoll_event{
            .data = .{ .fd = self.main_fd.? },
            .events = linux.EPOLL.IN,
        };
        _ = linux.epoll_ctl(
            epoll_fd,
            @intCast(linux.EPOLL.CTL_ADD),
            self.main_fd.?,
            &epoll_socket_ev,
        );

        // setup array of triggered events for epoll
        const max_connections = 20;
        var triggered_events: [20]linux.epoll_event = undefined;

        // The event loop
        while (true) {
            self.handleActiveConnections();

            // see if any of the fds need reading
            const triggered_event_count = linux.epoll_wait(
                epoll_fd,
                &triggered_events,
                max_connections,
                -1,
            );

            for (0..triggered_event_count) |i| {
                if (triggered_events[i].data.fd == self.main_fd) {
                    // main socket fd triggered
                    // get the conn fd
                    const con_addr_ptr = try self.allocator.create(std.net.Ip4Address);
                    defer self.allocator.destroy(con_addr_ptr);
                    var sock_len = con_addr_ptr.getOsSockLen();
                    const con_fd: linux.fd_t = @intCast(linux.accept(
                        self.main_fd.?,
                        @ptrCast(&con_addr_ptr.*.sa),
                        &sock_len,
                    ));
                    if (con_fd == -1) return error.FailedToAccept;
                    // add conn fd to be listened for by epoll
                    try self.read_fds.append(con_fd);
                    var con_ev = linux.epoll_event{
                        .data = .{ .fd = con_fd },
                        .events = linux.EPOLL.IN,
                    };
                    _ = linux.epoll_ctl(
                        epoll_fd,
                        linux.EPOLL.CTL_ADD,
                        con_fd,
                        &con_ev,
                    );
                } else {
                    // receiving a request from a client
                    const con_fd = triggered_events[i].data.fd;
                    const buf = try self.allocator.alloc(u8, 1000);
                    defer self.allocator.free(buf);
                    const req_len = linux.read(con_fd, @ptrCast(buf), buf.len);
                    if (req_len == 0) {
                        // connection closed from the server
                        _ = linux.shutdown(con_fd, linux.SHUT.RDWR);
                        _ = self.connections.remove(con_fd);
                        continue;
                    }
                    if (req_len == -1) return error.FailedToRead;

                    const request = try HTTPRequest.parse(self.allocator, buf[0..req_len]);

                    // Get response
                    var resp = self.runHandler(request) catch self.Response500();

                    var should_close = true;

                    const max_responses = 100;
                    // const con_timeout = 5;

                    if (request.headers.get("Connection")) |req_con| {
                        if (std.mem.eql(u8, req_con, "close")) {
                            const remove_resp = self.connections.remove(con_fd);
                            if (!remove_resp) std.debug.panic("CLOSE WITHOUT CON: ", .{});
                        } else if (self.connections.getPtr(con_fd)) |active_con| {
                            active_con.resp_count -= 1;
                            if (active_con.resp_count == 0) {
                                try resp.headers.put("Connection", "close");
                            } else {
                                try resp.headers.put("Connection", "keep-alive");
                                should_close = false;
                            }
                        } else {
                            try self.connections.put(con_fd, Connection{
                                .resp_count = max_responses,
                                .timeout = 5,
                                .last_request = std.time.timestamp(),
                            });
                            try resp.headers.put("Connection", "keep-alive");
                            try resp.headers.put("Keep-Alive", "timeout=5; max=100");
                            should_close = false;
                        }
                    }

                    // If a response exists return it
                    const resp_buf = try resp.toString();

                    // send response
                    _ = linux.write(
                        con_fd,
                        @ptrCast(resp_buf.items),
                        resp_buf.items.len,
                    );

                    if (should_close) {
                        _ = linux.shutdown(con_fd, linux.SHUT.RDWR);
                    }
                }
            }
        }
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

    try zag.serveFile("/", "../public/index.html");
    try zag.serveFile("/style.css", "../public/style.css");

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
    try zag.serveFile("/", "../public/index.html");
    try zag.serveDir("/", "../public");

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
