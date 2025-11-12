// Copyright (c) 2011 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Package dominantcolor provides a function for finding
// a color that represents the calculated dominant color in the
// image. This uses a KMean clustering algorithm to find clusters of pixel
// colors in RGB space.
//
// The algorithm is ported from Chromium source code:
//
//  https://github.com/chromium/chromium/blob/main/ui/gfx/color_analysis.h
//  https://github.com/chromium/chromium/blob/main/ui/gfx/color_analysis.cc
//  https://github.com/cenkalti/dominantcolor/blob/master/dominantcolor.go
//
// RGB KMean Algorithm (N clusters, M iterations):
//
// 1. Pick N starting colors by randomly sampling the pixels. If you see a
// color you already saw keep sampling. After a certain number of tries
// just remove the cluster and continue with N = N-1 clusters (for an image
// with just one color this should devolve to N=1). These colors are the
// centers of your N clusters.
//
// 2. For each pixel in the image find the cluster that it is closest to in RGB
// space. Add that pixel's color to that cluster (we keep a sum and a count
// of all of the pixels added to the space, so just add it to the sum and
// increment count).
//
// 3. Calculate the new cluster centroids by getting the average color of all of
// the pixels in each cluster (dividing the sum by the count).
//
// 4. See if the new centroids are the same as the old centroids.
//
// a) If this is the case for all N clusters than we have converged and can move on.
//
// b) If any centroid moved, repeat step 2 with the new centroids for up to M iterations.
//
// 5. Once the clusters have converged or M iterations have been tried, sort
// the clusters by weight (where weight is the number of pixels that make up
// this cluster).
//
// 6. Going through the sorted list of clusters, pick the first cluster with the
// largest weight that's centroid falls between |lower_bound| and
// |upper_bound|. Return that color.
// If no color fulfills that requirement return the color with the largest
// weight regardless of whether or not it fulfills the equation above.

const std = @import("std");
const zigimg = @import("zigimg");
const zstbi = @import("zstbi");

const resize_to: u32 = 256;
const max_sample: u32 = 10;
const n_iterations: u32 = 50;
const max_brightness: u16 = 665;
const min_darkness: u16 = 100;
const n_clusters_default: u32 = 4;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    weight: f64,

    pub fn toRGBA(self: Color) RGBA {
        return RGBA{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = self.a,
        };
    }
};

pub const RGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

const KMeanCluster = struct {
    centroid_r: u8,
    centroid_g: u8,
    centroid_b: u8,
    sum_r: u64,
    sum_g: u64,
    sum_b: u64,
    weight: u64,

    pub fn init() KMeanCluster {
        return KMeanCluster{
            .centroid_r = 0,
            .centroid_g = 0,
            .centroid_b = 0,
            .sum_r = 0,
            .sum_g = 0,
            .sum_b = 0,
            .weight = 0,
        };
    }

    pub fn setCentroid(self: *KMeanCluster, r: u8, g: u8, b: u8) void {
        self.centroid_r = r;
        self.centroid_g = g;
        self.centroid_b = b;
    }

    pub fn centroid(self: KMeanCluster) [3]u8 {
        return [3]u8{ self.centroid_r, self.centroid_g, self.centroid_b };
    }

    pub fn addPoint(self: *KMeanCluster, r: u8, g: u8, b: u8) void {
        self.sum_r += r;
        self.sum_g += g;
        self.sum_b += b;
        self.weight += 1;
    }

    pub fn recomputeCentroid(self: *KMeanCluster) void {
        if (self.weight > 0) {
            self.centroid_r = @as(u8, @intCast(self.sum_r / self.weight));
            self.centroid_g = @as(u8, @intCast(self.sum_g / self.weight));
            self.centroid_b = @as(u8, @intCast(self.sum_b / self.weight));
        }
    }

    pub fn compareCentroidWithAggregate(self: *KMeanCluster) bool {
        if (self.weight == 0) return true;
        const new_r = @as(u8, @intCast(self.sum_r / self.weight));
        const new_g = @as(u8, @intCast(self.sum_g / self.weight));
        const new_b = @as(u8, @intCast(self.sum_b / self.weight));
        return (self.centroid_r == new_r and self.centroid_g == new_g and self.centroid_b == new_b);
    }

    pub fn reset(self: *KMeanCluster) void {
        self.sum_r = 0;
        self.sum_g = 0;
        self.sum_b = 0;
        self.weight = 0;
    }
};

const KMeanClusterGroup = std.ArrayList(KMeanCluster);

fn containsCentroid(clusters: KMeanClusterGroup, r: u8, g: u8, b: u8) bool {
    for (clusters.items) |cluster| {
        if (cluster.centroid_r == r and cluster.centroid_g == g and cluster.centroid_b == b) {
            return true;
        }
    }
    return false;
}

fn closestCluster(clusters: KMeanClusterGroup, r: u8, g: u8, b: u8) *KMeanCluster {
    var min_dist: f64 = std.math.inf(f64);
    var closest: *KMeanCluster = undefined;
    var found = false;

    for (clusters.items) |*cluster| {
        const dr = @as(f64, @floatFromInt(cluster.centroid_r)) - @as(f64, @floatFromInt(r));
        const dg = @as(f64, @floatFromInt(cluster.centroid_g)) - @as(f64, @floatFromInt(g));
        const db = @as(f64, @floatFromInt(cluster.centroid_b)) - @as(f64, @floatFromInt(b));
        const dist = std.math.sqrt(dr * dr + dg * dg + db * db);

        if (!found or dist < min_dist) {
            min_dist = dist;
            closest = cluster;
            found = true;
        }
    }

    return closest;
}

fn sortByWeight(clusters: *KMeanClusterGroup) void {
    const SortContext = struct {
        pub fn lessThan(_: @This(), a: KMeanCluster, b: KMeanCluster) bool {
            return a.weight > b.weight;
        }
    };
    const context = SortContext{};
    std.mem.sort(KMeanCluster, clusters.items, context, SortContext.lessThan);
}

fn pixelFromZigimg(pixel: zigimg.color.Colorf32) RGBA {
    const r = @as(u8, @intFromFloat(pixel.r * 255.0));
    const g = @as(u8, @intFromFloat(pixel.g * 255.0));
    const b = @as(u8, @intFromFloat(pixel.b * 255.0));
    const a = @as(u8, @intFromFloat(pixel.a * 255.0));
    return RGBA{ .r = r, .g = g, .b = b, .a = a };
}

fn extractPixels(allocator: std.mem.Allocator, image: *zigimg.Image) ![]RGBA {
    const pixel_count = image.width * image.height;
    const pixels = try allocator.alloc(RGBA, pixel_count);
    errdefer allocator.free(pixels);

    var it = image.iterator();
    var i: usize = 0;
    while (it.next()) |pixel| {
        pixels[i] = pixelFromZigimg(pixel);
        i += 1;
    }

    return pixels;
}

fn resizeIfLarge(allocator: std.mem.Allocator, image: *zigimg.Image) !zigimg.Image {
    const width = image.width;
    const height = image.height;

    if (width <= resize_to and height <= resize_to) {
        return image.*;
    }

    zstbi.init(allocator);
    defer zstbi.deinit();

    const aspect = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
    var new_w: u32 = undefined;
    var new_h: u32 = undefined;

    if (aspect > 1.0) {
        new_w = resize_to;
        new_h = @as(u32, @intFromFloat(@as(f64, @floatFromInt(new_w)) / aspect));
    } else {
        new_h = resize_to;
        new_w = @as(u32, @intFromFloat(@as(f64, @floatFromInt(new_h)) * aspect));
    }

    var rgba_image: zigimg.Image = undefined;
    var image_needs_deinit = false;
    var raw_bytes: []const u8 = undefined;

    if (image.pixelFormat() != .rgba32) {
        const pixels = try extractPixels(allocator, image);
        defer allocator.free(pixels);

        const pixel_count = width * height;
        const byte_size = pixel_count * 4;
        const rgba_bytes = try allocator.alloc(u8, byte_size);
        errdefer allocator.free(rgba_bytes);

        for (pixels, 0..) |pixel, i| {
            const offset = i * 4;
            rgba_bytes[offset + 0] = pixel.r;
            rgba_bytes[offset + 1] = pixel.g;
            rgba_bytes[offset + 2] = pixel.b;
            rgba_bytes[offset + 3] = pixel.a;
        }

        rgba_image = try zigimg.Image.fromRawPixelsOwned(width, height, rgba_bytes, .rgba32);
        image_needs_deinit = true;
        raw_bytes = rgba_image.rawBytes();
    } else {
        rgba_image = image.*;
        image_needs_deinit = false;
        raw_bytes = rgba_image.rawBytes();
    }
    const src_pixel_count = width * height;
    const src_byte_size = src_pixel_count * 4;

    var src_zstbi_img = try zstbi.Image.createEmpty(@as(u32, @intCast(width)), @as(u32, @intCast(height)), 4, .{
        .bytes_per_component = 1,
        .bytes_per_row = 0,
    });
    defer src_zstbi_img.deinit();

    @memcpy(src_zstbi_img.data[0..src_byte_size], raw_bytes[0..src_byte_size]);

    var resized_zstbi = src_zstbi_img.resize(new_w, new_h);
    defer resized_zstbi.deinit();

    const resized_pixel_count = new_w * new_h;
    const resized_byte_size = resized_pixel_count * 4;
    const resized_data = try allocator.alloc(u8, resized_byte_size);
    errdefer allocator.free(resized_data);
    @memcpy(resized_data, resized_zstbi.data[0..resized_byte_size]);

    const resized = try zigimg.Image.fromRawPixelsOwned(new_w, new_h, resized_data, .rgba32);

    if (image_needs_deinit) {
        rgba_image.deinit(allocator);
    }

    return resized;
}

fn findClusters(allocator: std.mem.Allocator, image: *zigimg.Image, n_cluster: u32) !struct { clusters: KMeanClusterGroup, total_weight: f64, allocator: std.mem.Allocator } {
    const width = image.width;
    const height = image.height;
    const needs_resize = width > resize_to or height > resize_to;

    var resized_image: zigimg.Image = undefined;
    var resized_owned = false;
    if (needs_resize) {
        resized_image = try resizeIfLarge(allocator, image);
        resized_owned = true;
        errdefer resized_image.deinit(allocator);
    } else {
        resized_image = image.*;
        resized_owned = false;
    }

    defer if (resized_owned) resized_image.deinit(allocator);

    const resized_width = resized_image.width;
    const resized_height = resized_image.height;

    const pixels = try extractPixels(allocator, &resized_image);
    defer allocator.free(pixels);

    var rng = std.Random.DefaultPrng.init(0);
    const random = rng.random();

    var clusters = KMeanClusterGroup{};
    clusters.ensureTotalCapacity(allocator, n_cluster) catch |err| {
        return err;
    };
    errdefer clusters.deinit(allocator);

    var i: u32 = 0;
    while (i < n_cluster) : (i += 1) {
        var color_unique = false;
        var j: u32 = 0;
        while (j < max_sample) : (j += 1) {
            const idx = random.uintLessThan(usize, pixels.len);
            const pixel = pixels[idx];

            if (pixel.a == 0) {
                continue;
            }

            color_unique = !containsCentroid(clusters, pixel.r, pixel.g, pixel.b);

            if (color_unique) {
                var cluster = KMeanCluster.init();
                cluster.setCentroid(pixel.r, pixel.g, pixel.b);
                try clusters.append(allocator, cluster);
                break;
            }
        }
        if (!color_unique) {
            break;
        }
    }

    var convergence = false;
    var iteration: u32 = 0;
    while (iteration < n_iterations and !convergence and clusters.items.len > 0) : (iteration += 1) {
        for (clusters.items) |*cluster| {
            cluster.reset();
        }

        for (pixels) |pixel| {
            if (pixel.a == 0) {
                continue;
            }

            const closest = closestCluster(clusters, pixel.r, pixel.g, pixel.b);
            closest.addPoint(pixel.r, pixel.g, pixel.b);
        }

        convergence = true;
        for (clusters.items) |*cluster| {
            const converged = cluster.compareCentroidWithAggregate();
            convergence = convergence and converged;
            cluster.recomputeCentroid();
        }
    }

    sortByWeight(&clusters);

    const total_weight = @as(f64, @floatFromInt(resized_width)) * @as(f64, @floatFromInt(resized_height));
    return .{ .clusters = clusters, .total_weight = total_weight, .allocator = allocator };
}

pub fn find(allocator: std.mem.Allocator, image: *zigimg.Image) !RGBA {
    const colors = try findN(allocator, image, n_clusters_default);
    defer allocator.free(colors);
    if (colors.len == 0) {
        return RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }

    for (colors) |c| {
        const summed_color = @as(u16, c.r) + @as(u16, c.g) + @as(u16, c.b);
        if (summed_color < max_brightness and summed_color > min_darkness) {
            return c;
        }
    }

    return colors[0];
}

pub fn findN(allocator: std.mem.Allocator, image: *zigimg.Image, n_clusters: u32) ![]RGBA {
    const colors = try findWeight(allocator, image, n_clusters);
    defer allocator.free(colors);

    const result = try allocator.alloc(RGBA, colors.len);
    for (colors, result) |c, *r| {
        r.* = c.toRGBA();
    }
    return result;
}

pub fn findWeight(allocator: std.mem.Allocator, image: *zigimg.Image, n_clusters: u32) ![]Color {
    const n = if (n_clusters == 0) n_clusters_default else n_clusters;
    var result = try findClusters(allocator, image, n);
    defer result.clusters.deinit(result.allocator);

    const colors = try allocator.alloc(Color, result.clusters.items.len);
    for (result.clusters.items, colors) |cluster, *color| {
        const centroid = cluster.centroid();
        color.* = Color{
            .r = centroid[0],
            .g = centroid[1],
            .b = centroid[2],
            .a = 255,
            .weight = @as(f64, @floatFromInt(cluster.weight)) / result.total_weight,
        };
    }

    return colors;
}

pub fn hex(color: RGBA) [7]u8 {
    const hex_chars = "0123456789ABCDEF";
    var result: [7]u8 = undefined;
    result[0] = '#';
    result[1] = hex_chars[color.r >> 4];
    result[2] = hex_chars[color.r & 0x0F];
    result[3] = hex_chars[color.g >> 4];
    result[4] = hex_chars[color.g & 0x0F];
    result[5] = hex_chars[color.b >> 4];
    result[6] = hex_chars[color.b & 0x0F];
    return result;
}

pub fn hexString(allocator: std.mem.Allocator, color: RGBA) ![]const u8 {
    const hex_bytes = hex(color);
    return try allocator.dupe(u8, &hex_bytes);
}

const firefox_orange = RGBA{ .r = 230, .g = 96, .b = 0, .a = 255 };
const firefox_large_dominant = RGBA{ .r = 243, .g = 53, .b = 75, .a = 255 };

fn distance(a: RGBA, b: RGBA) f64 {
    const dr = @as(f64, @floatFromInt(a.r)) - @as(f64, @floatFromInt(b.r));
    const dg = @as(f64, @floatFromInt(a.g)) - @as(f64, @floatFromInt(b.g));
    const db = @as(f64, @floatFromInt(a.b)) - @as(f64, @floatFromInt(b.b));
    return std.math.sqrt(dr * dr + dg * dg + db * db);
}

fn loadTestImage(allocator: std.mem.Allocator, path: []const u8) !zigimg.Image {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    const image = try zigimg.Image.fromFilePath(allocator, path, read_buffer[0..]);
    return image;
}

test "find dominant color" {
    const path = "src/tests-assets/firefox.png";
    const allocator = std.testing.allocator;
    var image = try loadTestImage(allocator, path);
    defer image.deinit(allocator);

    const c = try find(allocator, &image);
    const d = distance(c, firefox_orange);
    const hex_str = try hexString(allocator, c);
    defer allocator.free(hex_str);

    std.debug.print("Found dominant color: {s}\n", .{hex_str});
    std.debug.print("Firefox orange:       #{X:0>2}{X:0>2}{X:0>2}\n", .{ firefox_orange.r, firefox_orange.g, firefox_orange.b });
    std.debug.print("Distance:             {d:.2}\n", .{d});

    try std.testing.expect(d < 50.0);
}

test "find dominant color large" {
    const allocator = std.testing.allocator;
    var image = try loadTestImage(allocator, "src/tests-assets/firefox-large.png");
    defer image.deinit(allocator);

    const c = try find(allocator, &image);
    const d = distance(c, firefox_large_dominant);
    const hex_str = try hexString(allocator, c);
    defer allocator.free(hex_str);

    std.debug.print("Found dominant color: {s}\n", .{hex_str});
    std.debug.print("Firefox large orange: #{X:0>2}{X:0>2}{X:0>2}\n", .{ firefox_large_dominant.r, firefox_large_dominant.g, firefox_large_dominant.b });
    std.debug.print("Distance:             {d:.2}\n", .{d});

    try std.testing.expect(d < 50.0);
}

test "single-color image" {
    const allocator = std.testing.allocator;
    var image = try loadTestImage(allocator, "src/tests-assets/orange.png");
    defer image.deinit(allocator);

    const c = try find(allocator, &image);
    const hex_str = try hexString(allocator, c);
    defer allocator.free(hex_str);
    try std.testing.expectEqualStrings("#FFA500", hex_str);
}

test "find weight" {
    const allocator = std.testing.allocator;
    var image = try loadTestImage(allocator, "src/tests-assets/firefox.png");
    defer image.deinit(allocator);

    const colors = try findWeight(allocator, &image, 4);
    defer allocator.free(colors);

    try std.testing.expect(colors.len == 4);

    for (colors, 0..) |col, i| {
        const hex_str = try hexString(allocator, col.toRGBA());
        defer allocator.free(hex_str);
        std.debug.print("{d}/{d} Found dominant color: {s}, weight: {d:.2}\n", .{ i + 1, colors.len, hex_str, col.weight });
    }
}

test "hex format" {
    const color = RGBA{ .r = 0xCB, .g = 0x5A, .b = 0x27, .a = 255 };
    const hex_bytes = hex(color);
    const expected = "#CB5A27";
    try std.testing.expectEqualStrings(expected, &hex_bytes);
}

test "findN returns correct number of colors" {
    const allocator = std.testing.allocator;
    var image = try loadTestImage(allocator, "src/tests-assets/firefox.png");
    defer image.deinit(allocator);

    const colors = try findN(allocator, &image, 4);
    defer allocator.free(colors);

    try std.testing.expect(colors.len == 4);
}
