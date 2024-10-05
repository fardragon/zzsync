const std = @import("std");

const yazap = @import("yazap");
const http = @import("http.zig");
const ranges = @import("ranges.zig");
const common = @import("common.zig");

const App = yazap.App;
const Arg = yazap.Arg;

// zs = read_zsync_control_file(location_str, filename)
// Reads a zsync control file from either a URL or filename specified in
// location_str. This is treated as a URL if no local file exists of that name
// and it starts with a URL scheme ; only http URLs are supported.
// Second parameter is a filename in which to locally save the content of the
// .zsync _if it is retrieved from a URL_; can be NULL in which case no local
// copy is made.

fn read_zsync_control_file(allocator: std.mem.Allocator, path: [:0]const u8, filename: ?[:0]const u8) !struct { *common.c.zsync_state, ?[]u8 } {
    if (std.fs.cwd().accessZ(path, .{ .mode = .read_only })) |_| {
        unreachable;
    } else |err| {
        std.log.err("{}", .{err});
        return zsyncReadControlFileHTTP(allocator, path, filename) catch unreachable;
    }
}

fn zsyncReadControlFileHTTP(allocator: std.mem.Allocator, path: [:0]const u8, filename: ?[:0]const u8) !struct { *common.c.zsync_state, []u8 } {
    const file, const referer = try http.http_get(allocator, path, filename);

    errdefer allocator.free(referer);
    errdefer _ = common.c.fclose(file);

    const zs = common.c.zsync_begin(file);

    // Read the .zsync
    if (zs == null) {
        return error.ZSYNC_PARSE_ERROR;
    }

    return .{ zs.?, referer };
}

fn getFilenamePrefix(filename: []const u8) ![]const u8 {
    const base = std.fs.path.basename(filename);
    for (base, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c)) {
            return base[0..i];
        }
    }
    return error.Unreachable;
}

fn getFilename(allocator: std.mem.Allocator, zstate: *const common.c.zsync_state, source_name: []const u8) ![:0]u8 {
    const zstate_filename_c = common.c.zsync_filename(zstate);
    defer common.c.free(zstate_filename_c);

    const prefix = try getFilenamePrefix(source_name);

    if (zstate_filename_c != null) {
        const zstate_filename = std.mem.span(zstate_filename_c.?);

        if (std.mem.containsAtLeast(u8, zstate_filename, 1, "/")) {
            std.log.err("Rejected filename specfied in {s}, contained path component.", .{source_name});
        } else {
            if (std.mem.eql(u8, zstate_filename[0..prefix.len], prefix)) {
                return try allocator.dupeZ(u8, zstate_filename);
            } else {
                std.log.err("Rejected filanme specified in {s} - prefix {s} differed from filename {s}.", .{ source_name, prefix, zstate_filename });
            }
        }
    }

    return try allocator.dupeZ(u8, prefix);
}

fn readSeedFile(allocator: std.mem.Allocator, state: *common.c.struct_zsync_state, filename: [:0]const u8) !void {
    if (common.c.zsync_hint_decompress(state) == 1 and filename.len > 3) {
        const file = std.fs.cwd().openFileZ(filename, .{ .mode = .read_only }) catch {
            std.log.err("Unable to open seed file: {s}", .{filename});
            return;
        };

        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) {
            std.log.warn("Skipping empty seed file: {s}", .{filename});
            return;
        }

        var decompressor = std.compress.gzip.decompressor(file.reader());

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        while (try decompressor.next()) |buf| {
            try buffer.appendSlice(buf);
        }

        const file_buffer = common.c.fmemopen(buffer.items.ptr, buffer.items.len, "r") orelse {
            std.log.err("Unable to process seed file: {s}", .{filename});
            return;
        };
        defer _ = common.c.fclose(file_buffer);

        _ = common.c.zsync_submit_source_file(state, file_buffer, 1);
    } else {
        const file = common.c.fopen(filename.ptr, "r") orelse {
            std.log.err("Unable to open seed file: {s}", .{filename});
            return;
        };

        defer _ = common.c.fclose(file);

        //     if (!no_progress)
        std.log.debug("Reading seedd file: {s}\r\n", .{filename});
        _ = common.c.zsync_submit_source_file(state, file, 1);
    }

    var done: c_longlong = undefined;
    var total: c_longlong = undefined;

    common.c.zsync_progress(state, &done, &total);
    //     if (!no_progress)
    const percentage = @as(f64, @floatFromInt(done)) * 100.0 / @as(f64, @floatFromInt(total));
    std.log.debug("Done reading {s}. {d:.2}% of target obtained.", .{ filename, percentage });
}

fn isURLAbsolute(url: []const u8) bool {
    // Find end of first no-special-URL-characters part of the string
    const maybe_pos = std.mem.indexOfAny(u8, url, ":/?");

    if (maybe_pos) |pos| {
        // If the first special character is a :, the start is a URL scheme
        return url[pos] == ':';
    } else {
        // otherwise, it's a full path or relative path URL, or just a local file
        // path (caller knows the context)
        return false;
    }
}

fn makeURLAbsolute(allocator: std.mem.Allocator, url: []const u8, base: ?[]const u8) ![]u8 {
    if (isURLAbsolute(url)) {
        return try allocator.dupe(u8, url);
    }

    if (base == null) {
        return error.MissingBaseURL;
    }

    var buffer: [256]u8 = undefined;
    var b: []u8 = buffer[0..];

    const base_parsed = try std.Uri.parse(base.?);
    const resolved = try base_parsed.resolve_inplace(url, &b);

    return std.fmt.allocPrint(allocator, "{}", .{resolved});
}

fn fetchRemainingBlocksHTTP(allocator: std.mem.Allocator, state: *common.c.struct_zsync_state, url: []const u8, utype: c_int) i8 {
    var range = ranges.RangeFetch.init(allocator, url) catch {
        return -1;
    };
    defer range.deinit();

    const receiver = common.c.zsync_begin_receive(state, utype);
    if (receiver == null) {
        return -1;
    }
    defer common.c.zsync_end_receive(receiver);

    // Get a set of byte ranges that we need to complete the target */
    var ranges_count: c_int = undefined;
    var ranges_list = common.c.zsync_needed_byte_ranges(state, &ranges_count, utype);

    if (ranges_list == null) {
        return 1;
    }
    defer common.c.free(ranges_list);

    if (ranges_count == 0) {
        return 0;
    }

    const input_ranges = ranges_list[0 .. 2 * @as(usize, @intCast(ranges_count))];
    range.addRanges(input_ranges) catch {
        return -1;
    };

    // Create a read buffer
    const receive_buffer = allocator.alloc(u8, 8192) catch |err| {
        std.log.err("Failed to create receive buffer: {}", .{err});
        return -1;
    };
    defer allocator.free(receive_buffer);

    var data_offset: usize = undefined;
    while (true) {
        data_offset, const data_length = range.getDataFromBuffer(receive_buffer) catch |err| {
            std.log.err("Failed to receive data: {}", .{err});
            return -1;
        };

        if (data_length == 0) break;

        if (common.c.zsync_receive_data(receiver, receive_buffer.ptr, @intCast(data_offset), data_length) != 0) {
            return 1;
        }

        // /* Maintain progress display */
        // if (!no_progress)
        // do_progress(p, calc_zsync_progress(z),
        // range_fetch_bytes_down(rf));

        data_offset += data_length;
    }

    if (common.c.zsync_receive_data(receiver, null, @intCast(data_offset), 0) != 0) {
        return 1;
    }

    return 0;
}

fn fetchRemainingBlocksFromURL(allocator: std.mem.Allocator, state: *common.c.struct_zsync_state, url: []const u8, referer: ?[]const u8, utype: c_int) i8 {

    // URL might be relative - we need an absolute URL to do a fetch
    const absolute_url = makeURLAbsolute(allocator, url, referer) catch {
        std.log.err(
            \\URL '{s}' from the .zsync file is relative, but I don't know the referer URL (you probably downloaded the .zsync separately and gave it to me as a file).
            \\I need to know the referring URL (the URL of the .zsync) in order to locate the download.
            \\ You can specify this with -u (or edit the URL line(s) in the .zsync file you have)
        , .{url});
        return -1;
    };

    defer allocator.free(absolute_url);

    // Try fetching data from this URL
    const rc = fetchRemainingBlocksHTTP(allocator, state, absolute_url, utype);
    if (rc != 0) {
        std.log.err("Failed to retrieve data from {s}", .{absolute_url});
    }
    return rc;
}

fn fetchRemainingBlocks(allocator: std.mem.Allocator, state: *common.c.struct_zsync_state, referer: ?[]const u8) bool {
    var n: c_int = undefined;
    var utype: c_int = undefined;

    const urls = common.c.zsync_get_urls(state, &n, &utype);

    if (urls == null) {
        // std.log.err("No download URLs known!", .{});
        return false;
    }
    var ok_urls = n;

    var statuses = std.ArrayList(bool).init(allocator);
    defer statuses.deinit();
    statuses.appendNTimes(true, @intCast(n)) catch {
        return false;
    };

    while (common.c.zsync_status(state) < 2 and ok_urls > 0) {
        // TODO: Pick URLs at random?
        for (0..@intCast(n)) |i| {
            if (!statuses.items[i]) continue;

            const url = std.mem.span(urls[i]);
            const rc = fetchRemainingBlocksFromURL(allocator, state, url, referer, utype);
            if (rc != 0) {
                statuses.items[i] = false;
                ok_urls -= 1;
            }
        }
    }

    return true;
}

fn set_mtime(file_path: []const u8, mtime: i128) !void {
    const stat = try std.fs.cwd().statFile(file_path);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    try file.updateTimes(stat.atime, mtime);
}

// static int set_mtime(char* filename, time_t mtime) {
//     struct stat s;
//     struct utimbuf u;

//     /* Get the access time, which I don't want to modify. */
//     if (stat(filename, &s) != 0) {
//         perror("stat");
//         return -1;
//     }

//     /* Set the modification time. */
//     u.actime = s.st_atime;
//     u.modtime = mtime;
//     if (utime(filename, &u) != 0) {
//         perror("utime");
//         return -1;
//     }
//     return 0;
// }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App.init(allocator, "zsync", "Modern zsync implementation");
    defer app.deinit();

    var zsync_args = app.rootCommand();
    try zsync_args.addArg(Arg.positional("ZSYNC_FILE_URI", null, null));
    try zsync_args.addArg(Arg.multiValuesOption("input-files", 'i', "input files", 128));

    const matches = try app.parseProcess();

    if (!matches.containsArgs()) {
        try app.displayHelp();
        return;
    }

    // STEP 1: Read the zsync control file
    const uri = try allocator.dupeZ(u8, matches.getSingleValue("ZSYNC_FILE_URI").?);
    defer allocator.free(uri);
    const state, const maybe_referer = try read_zsync_control_file(allocator, uri, null);
    defer {
        if (maybe_referer) |referer| {
            allocator.free(referer);
        }
    }

    const filename = try getFilename(allocator, state, matches.getSingleValue("ZSYNC_FILE_URI").?);
    defer allocator.free(filename);

    const temp_filename = try std.fmt.allocPrintZ(allocator, "{s}.part", .{filename});
    defer allocator.free(temp_filename);

    // STEP 2: read available local data and fill in what we know in the target file
    var seed_files = std.ArrayList([:0]u8).init(allocator);
    defer {
        for (seed_files.items) |str| {
            seed_files.allocator.free(str);
        }
        seed_files.deinit();
    }

    if (matches.getMultiValues("input-files")) |input_files| {
        for (input_files) |input_file| {
            std.log.debug("Adding seed file from cmdline: {s}", .{input_file});
            try seed_files.append(try allocator.dupeZ(u8, input_file));
        }
    }

    // If the target file already exists, we're probably updating that file - so it's a seed file */
    if (std.fs.cwd().access(filename, .{ .mode = .read_only })) |_| {
        std.log.debug("Adding target file {s} to seed files.", .{filename});
        try seed_files.append(try allocator.dupeZ(u8, filename));
    } else |_| {}

    // If the .part file exists, it's probably an interrupted earlier
    // effort; a normal HTTP client would 'resume' from where it got to,
    // but zsync can't (because we don't know this data corresponds to the
    // current version on the remote) and doesn't need to, because we can
    // treat it like any other local source of data. Use it now. */
    if (std.fs.cwd().access(temp_filename, .{ .mode = .read_only })) |_| {
        std.log.debug("Adding temp file {s} to seed files.", .{temp_filename});
        try seed_files.append(try allocator.dupeZ(u8, temp_filename));
    } else |_| {}

    // TODO: Skip duplicates in seed_files
    for (seed_files.items) |seed_file| {
        std.log.debug("Processing seed file {s}", .{seed_file});

        // Check if target is complete
        if (common.c.zsync_status(state) >= 2) {
            break;
        }
        try readSeedFile(allocator, state, seed_file);
    }

    var local_used: c_longlong = 0;
    common.c.zsync_progress(state, &local_used, null);
    if (local_used == 0) {
        // if (!no_progress)
        std.log.info(
            \\ No relevent local data found - I will be downloading the whole file. If that's not what you want, CTRL-C out.
            \\ You should specify the local file is the old version of the file to download with -i (you might have to decompress it with gzip -d first).
            \\ Or perhaps you just have no data that helps download the file,
        , .{});
    }

    // libzsync has been writing to a randomly-named temp file so far -
    // because we didn't want to overwrite the .part from previous runs. Now
    // we've read any previous .part, we can replace it with our new
    // in-progress run (which should be a superset of the old .part - unless
    // the content changed, in which case it still contains anything relevant
    // from the old .part). */
    if (common.c.zsync_rename_file(state, temp_filename) != 0) {
        return error.FileRenameError;
    }

    // STEP 3: fetch remaining blocks via the URLs from the .zsync

    const fetch_status = fetchRemainingBlocks(allocator, state, maybe_referer);
    const target_status = common.c.zsync_status(state);
    if (target_status < 2) {
        if (!fetch_status) {
            std.log.err("No download URLs are known, so no data could be downloaded. The .zsync file is probably incomplete.", .{});
        } else {
            if (target_status == 0) {
                std.log.err("No data downloaded - none of the download URLs worked.", .{});
            } else {
                std.log.err("Not all of the required data could be downloaded, and the remaining data could not be retrieved from any of the download URLs.", .{});
            }
        }
        std.log.err(
            \\Incomplete transfer left in {s}.
            \\(If this is the download filename with .part appended, zsync will automatically pick this up and reuse the data it has already done if you retry in this dir.)"
        , .{temp_filename});
        return error.zsync_fetch_failed;
    }

    std.log.debug("Verifying download", .{});
    switch (common.c.zsync_complete(state)) {
        -1 => {
            std.log.err("Aborting, download available in {s}", .{temp_filename});
            return error.unknown_error;
        },
        0 => {
            std.log.debug("No recognised checksum found", .{});
        },
        1 => {
            std.log.debug("Checksum matches OK", .{});
        },
        else => unreachable,
    }

    // Get any mtime that we is suggested to set for the file, and then shut
    // down the zsync_state as we are done on the file transfer. Getting the
    // current name of the file at the same time.
    const mtime = common.c.zsync_mtime(state);
    const complete_file = common.c.zsync_end(state);
    defer common.c.free(complete_file);

    // STEP 5: Move completed .part file into place as the final target

    const old_backup_filename = try std.fmt.allocPrint(allocator, "{s}.zs-old", .{filename});
    defer allocator.free(old_backup_filename);
    if (std.fs.cwd().access(filename, .{ .mode = .read_only })) {
        // Backup the old file.
        // First, remove any previous backup. We don't care if this fail the link below will catch any failure
        std.fs.cwd().deleteFile(old_backup_filename) catch {
            // std.log.debug("{}", err);
        };

        // Try linking the filename to the backup file name, so we will
        // atomically replace the target file in the next step.
        // If that fails due to EPERM, it is probably a filesystem that
        // doesn't support hard-links - so try just renaming it to the
        // backup filename.

        // if (link(filename, oldfile_backup) != 0
        //     && (errno != EPERM || rename(filename, oldfile_backup) != 0)) {
        //     perror("linkname");
        //     fprintf(stderr,
        //             "Unable to back up old file %s - completed download left in %s\n",
        //             filename, temp_file);
        //     ok = 0;         /* Prevent overwrite of old file below */
        // }
        try std.fs.cwd().rename(filename, old_backup_filename);
    } else |_| {}

    try std.fs.cwd().rename(std.mem.span(complete_file), filename);
    if (mtime != -1) {
        try set_mtime(filename, mtime);
    }

    // if (ok) {
    //     /* Rename the file to the desired name */
    //     if (rename(temp_file, filename) == 0) {
    //         /* final, final thing - set the mtime on the file if we have one */
    //         if (mtime != -1) set_mtime(filename, mtime);
    //     }
    //     else {
    //         perror("rename");
    //         fprintf(stderr,
    //                 "Unable to back up old file %s - completed download left in %s\n",
    //                 filename, temp_file);
    //     }
    // }
    // free(oldfile_backup);
    // free(filename);

}
