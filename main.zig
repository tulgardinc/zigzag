const std = @import("std");
const Zigzag = @import("zigzag.zig").Zigzag;
const HTTPResponse = @import("http_response.zig").HTTPResponse;

fn handleGet(allcator: std.mem.Allocator) HTTPResponse {
    var resp = HTTPResponse.init(allcator, .OK, "<h1>YOOOOO</h1>");
    resp.headers.put("Content-Type", "text/html") catch unreachable;
    return resp;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var zag = Zigzag.init(allocator);

    //try zag.GET("/", handleGet);
    // try zag.GETStatic("/", "public/index.html");
    // try zag.GETStatic("/style.css", "public/style.css");

    try zag.start(.{ 127, 0, 0, 1 }, 8080);
}
