const std = @import("std");
const builtin = @import("builtin");
const dominant_color = @import("dominant_color");
const zigimg = @import("zigimg");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    if (builtin.mode != .Debug) {
        allocator = std.heap.c_allocator;
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} [-n=N|--number=N] <image_path>\n", .{args[0]});
        std.process.exit(1);
    }

    var n_colors: ?u32 = null;
    var image_path: []const u8 = undefined;
    var found_path = false;

    // Parse arguments
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-n=")) {
            const n_str = arg[3..];
            n_colors = std.fmt.parseInt(u32, n_str, 10) catch |err| {
                std.debug.print("Error: invalid number '{s}': {s}\n", .{ n_str, @errorName(err) });
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--number=")) {
            const n_str = arg[9..];
            n_colors = std.fmt.parseInt(u32, n_str, 10) catch |err| {
                std.debug.print("Error: invalid number '{s}': {s}\n", .{ n_str, @errorName(err) });
                std.process.exit(1);
            };
        } else if (!found_path) {
            image_path = arg;
            found_path = true;
        } else {
            std.debug.print("Error: unexpected argument '{s}'\n", .{arg});
            std.debug.print("Usage: {s} [-n=N|--number=N] <image_path>\n", .{args[0]});
            std.process.exit(1);
        }
    }

    if (!found_path) {
        std.debug.print("Error: image path is required\n", .{});
        std.debug.print("Usage: {s} [-n=N|--number=N] <image_path>\n", .{args[0]});
        std.process.exit(1);
    }

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var image = zigimg.Image.fromFilePath(allocator, image_path, read_buffer[0..]) catch |err| {
        std.debug.print("Error: failed to load image '{s}': {s}\n", .{ image_path, @errorName(err) });
        std.process.exit(1);
    };
    defer image.deinit(allocator);

    if (n_colors) |n| {
        const colors = try dominant_color.findN(allocator, &image, n);
        defer allocator.free(colors);

        for (colors) |color| {
            const hex_str = try dominant_color.hexString(allocator, color);
            defer allocator.free(hex_str);
            std.debug.print("{s}\n", .{hex_str});
        }
    } else {
        const color = try dominant_color.find(allocator, &image);
        const hex_str = try dominant_color.hexString(allocator, color);
        defer allocator.free(hex_str);
        std.debug.print("{s}\n", .{hex_str});
    }
}
