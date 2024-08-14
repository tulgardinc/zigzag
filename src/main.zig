const std = @import("std");
const Zigzag = @import("zigzag.zig").Zigzag;
const HTTPResponse = @import("http_response.zig").HTTPResponse;
const PathParameters = @import("handler.zig").PathParameters;
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("stdio.h");
});

var db: ?*c.sqlite3 = undefined;

fn handleGet(allocator: std.mem.Allocator, path_params: PathParameters) !HTTPResponse {
    std.debug.print("{s}\n", .{path_params.get("test").?});
    var resp = HTTPResponse.init(allocator, .OK, "");
    try resp.headers.put("Content-Type", "text/plain");
    return resp;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var zag = Zigzag.init(allocator);
    defer zag.deinit();

    try zag.serveFile("/", "../public/index.html");
    try zag.serveDir("/", "../public");
    try zag.addEndpoint(.POST, "/api/<test>", handleGet);

    try zag.start(.{ 127, 0, 0, 1 }, 8080);
}

test "sql" {
    const open_rc = c.sqlite3_open("./test.db", &db);
    defer _ = c.sqlite3_close(db);
    if (open_rc == -1) std.debug.print("failed to open\n", .{});

    const create_table_sql = "CREATE TABLE IF NOT EXISTS todos(id INTEGER PRIMARY KEY, name TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)";
    const create_rc = c.sqlite3_exec(db, create_table_sql, null, null, null);
    if (create_rc != c.SQLITE_OK) std.debug.print("failed to exec\n", .{});

    const add_todo_sql = "INSERT INTO todos (name) VALUES ('new test');";
    const add_todo_rc = c.sqlite3_exec(db, add_todo_sql, null, null, null);
    if (add_todo_rc != c.SQLITE_OK) std.debug.print("failed to exec\n", .{});

    const get_todos_sql = "SELECT id, name, done FROM todos;";
    var stmt: ?*c.sqlite3_stmt = undefined;
    _ = c.sqlite3_prepare_v2(db, get_todos_sql, -1, &stmt, null);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int(stmt, 0);
        const name = c.sqlite3_column_text(stmt, 1);
        const done = c.sqlite3_column_int(stmt, 2);
        std.debug.print("{d}|{s}|{d}\n", .{ id, name, done });
    }
    _ = c.sqlite3_finalize(stmt);
}
