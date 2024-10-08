const std = @import("std");
const Zigzag = @import("zigzag.zig").Zigzag;
const HTTPResponse = @import("http_response.zig").HTTPResponse;
const PathParameters = @import("handler.zig").PathParameters;

fn handleGet(allocator: std.mem.Allocator, path_params: PathParameters) ![]const u8 {
    const str = path_params.get("test").?;
    const str2 = path_params.get("second").?;
    return try std.fmt.allocPrint(allocator, "<h1>{s}</h1><h2>{s}</h2>", .{ str, str2 });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var zag = Zigzag.init(allocator);
    defer zag.deinit();

    try zag.serveFile("/", "../public/index.html");
    try zag.serveDir("/", "../public");
    try zag.addEndpoint(.POST, "/api/<test>/<second>", handleGet);

    try zag.start(.{ 127, 0, 0, 1 }, 8080);
}
