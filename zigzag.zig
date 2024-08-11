const std = @import("std");
const linux = std.os.linux;
const errno = std.posix.errno;
const HTTPRequest = @import("http_request.zig").HTTPRequest;
const Methods = @import("http_request.zig").Methods;
const HTTPResponse = @import("http_response.zig").HTTPResponse;
const ResponseCode = @import("http_response.zig").ResponseCode;
const Handler = @import("handler.zig").Handler;
const h = @import("handler.zig");

pub const Zigzag = struct {
    allocator: std.mem.Allocator,
    handlers: std.AutoHashMap(Methods, std.StringHashMap(Handler)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .handlers = std.AutoHashMap(Methods, std.StringHashMap(Handler)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.handlers.deinit();
    }

    pub fn start(self: *Self, ip_address: [4]u8, port: u16) !void {
        try self.openSocket(ip_address, port);
    }

    pub fn ServeFile(self: *Self, url: []const u8, comptime path: []const u8) !void {
        const result = try self.handlers.getOrPut(.GET);
        if (!result.found_existing) {
            result.value_ptr.* = std.StringHashMap(Handler).init(self.allocator);
        }
        const handler = h.fileHandler(self.allocator, path);
        try result.value_ptr.put(url, handler);
    }

    pub fn ServeDir(self: *Self, url: []const u8, comptime path: []const u8) !void {
        const result = try self.handlers.getOrPut(.GET);
        if (!result.found_existing) {
            result.value_ptr.* = std.StringHashMap(Handler).init(self.allocator);
        }
        const handler = h.fileHandler(self.allocator, path);
        try result.value_ptr.put(url, handler);
    }

    pub fn GET(self: *Self, url: []const u8, comptime func: anytype) !void {
        const result = try self.handlers.getOrPut(.GET);
        if (!result.found_existing) {
            result.value_ptr.* = std.StringHashMap(Handler).init(self.allocator);
        }
        const handler = Handler.init(self.allocator, func);
        try result.value_ptr.put(url, handler);
    }

    pub fn Response404(self: *Self) HTTPResponse {
        return HTTPResponse.init(self.allocator, .NOT_FOUND, "");
    }

    fn runHandler(self: *Self, request: HTTPRequest) ?HTTPResponse {
        if (self.handlers.get(request.method)) |inner| {
            if (inner.get(request.url)) |handler| {
                return handler.run(request);
            } else {
                // 404
                std.debug.print("404", .{});
                return self.Response404();
            }
        } else {
            // server doesn't handle this method
            std.debug.print("unsuported method", .{});
        }
        return null;
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
        if (bind_errno != 0) return error.FailedToBind;

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

            const resp = self.runHandler(request);

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
