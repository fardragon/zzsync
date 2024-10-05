const std = @import("std");
const common = @import("common.zig");

// FILE* http_get(const char* orig_url, char** track_referer, const char* tfname);
pub fn http_get(allocator: std.mem.Allocator, orig_url: [:0]const u8, tfname: ?[]const u8) !struct { [*c]common.c.FILE, []u8 } {
    // TODO: Allow using local .zsync file
    // TODO: Add proxy handling
    // TODO: Add auth handling
    _ = tfname;

    const raw_url: []const u8 = orig_url[0..orig_url.len];

    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    var result_buffer = std.ArrayList(u8).init(allocator);
    defer result_buffer.deinit();

    const result = try client.fetch(
        .{
            .location = .{ .url = raw_url },
            .method = .GET,
            .response_storage = .{ .dynamic = &result_buffer },
            // TODO: Allow redirects, remember to set track_referer to new host
            .redirect_behavior = .not_allowed,
        },
    );

    _ = result;

    const output_file = common.c.tmpfile();
    _ = common.c.fwrite(result_buffer.items.ptr, 1, result_buffer.items.len, output_file);
    _ = common.c.rewind(output_file);

    return .{ output_file, allocator.dupe(u8, raw_url) catch unreachable };
}
