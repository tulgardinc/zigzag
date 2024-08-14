const std = @import("std");
const Zigzag = @import("zigzag.zig").Zigzag;
const HTTPResponse = @import("http_response.zig").HTTPResponse;

fn handleGet(allocator: std.mem.Allocator, str: []const u8) !HTTPResponse {
    const header = try std.fmt.allocPrint(allocator, "<h1>{s}</h1>", .{str});
    var resp = HTTPResponse.init(allocator, .OK, header);
    try resp.headers.put("Content-Type", "text/html");
    return resp;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var zag = Zigzag.init(allocator);
    defer zag.deinit();

    try zag.serveFile("/", "../public/index.html");
    try zag.serveDir("/", "../public");
    try zag.GET("/api/<test>", handleGet);

    try zag.start(.{ 127, 0, 0, 1 }, 8080);
}
