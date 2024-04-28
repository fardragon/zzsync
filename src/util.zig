const std = @import("std");
const common = @import("common.zig");

pub usingnamespace @import("ranges.zig");
pub usingnamespace @import("http.zig");

// char* base64(const char*);
export fn base64(input: common.ConstCString) common.CString {
    const result = base_64_internal(std.mem.span(input)) catch return null;
    return return_c_string(result);
}

// int set_proxy_from_string(const char* s);
export fn set_proxy_from_string(s: common.ConstCString) c_int {
    _ = s;
    return 0;
}

// void add_auth(char* host, char* user, char* pass);
export fn add_auth(host: common.CString, user: common.CString, pass: common.CString) void {
    _ = host;
    _ = user;
    _ = pass;
    @panic("Not implemented");
}

// extern char *referer;
// extern var referer: CString;

// Internal implementations
fn return_c_string(slice_to_return: []const u8) common.CString {
    const return_buffer_raw = common.c.malloc(slice_to_return.len + 1) orelse return null;

    const return_buffer: []u8 = @as([*]u8, @ptrCast(return_buffer_raw))[0 .. slice_to_return.len + 1];
    @memcpy(return_buffer, slice_to_return);
    return_buffer[slice_to_return.len] = 0;
    return return_buffer.ptr;
}

fn base_64_internal(input: []const u8) ![]const u8 {
    var buffer: [8192]u8 = undefined;

    const encoder = std.base64.standard.Encoder;
    if (encoder.calcSize(input.len) > buffer.len) {
        return error.InputTooBig;
    }

    return encoder.encode(&buffer, input);
}
