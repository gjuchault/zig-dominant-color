# Dominant Color

A fast and efficient command-line tool written in Zig for extracting dominant colors from images using K-Means clustering.

## Features

- 🎨 Extract the dominant color from any image
- 🔢 Extract multiple dominant colors (N colors)
- ⚡ Fast performance with automatic image resizing for large images
- 🖼️ Supports common image formats (PNG, JPEG, etc.)
- 📦 Zero dependencies (uses Zig's package manager)

## Installation

### Prerequisites

- [Zig](https://ziglang.org/) 0.15.1 or later

### Building

```bash
zig build
```

This will create the executable at `zig-out/bin/dominant_color`.

### Running Tests

```bash
zig build test
```

## Usage

### Extract Single Dominant Color

```bash
dominant_color image.png
```

Output:

```
#D16C2A
```

### Extract Multiple Dominant Colors

Use the `-n=N` or `--number=N` flag to extract N dominant colors:

```bash
dominant_color -n=4 image.png
```

Output:

```
#D16C2A
#64ABD6
#293E79
#040104
```

The colors are returned in order of dominance (most dominant first).

## Algorithm

This implementation uses a K-Means clustering algorithm ported from Chromium's color analysis code. The algorithm:

1. **Samples** N starting colors by randomly sampling pixels from the image
2. **Clusters** pixels by finding the closest cluster in RGB space
3. **Iterates** up to 50 times, recalculating cluster centroids until convergence
4. **Selects** the dominant color(s) based on cluster weights and brightness constraints

For large images (>256x256), the image is automatically resized to improve performance while maintaining accuracy.

### Algorithm Parameters

- Default clusters: 4
- Max iterations: 50
- Resize threshold: 256x256 pixels
- Brightness bounds: 100-665 (RGB sum)

## Library Usage

This project can also be used as a library. Import it in your `build.zig.zon`:

```zig
const dominant_color = @import("dominant_color");

// Extract single dominant color
const color = try dominant_color.find(allocator, &image);

// Extract N dominant colors
const colors = try dominant_color.findN(allocator, &image, 4);

// Format as hex string
const hex_str = try dominant_color.hexString(allocator, color);
```

## Credits

- Algorithm ported from [Chromium's color analysis](https://github.com/chromium/chromium/blob/main/ui/gfx/color_analysis.cc) — BSD license
- Inspired by [cenkalti/dominantcolor](https://github.com/cenkalti/dominantcolor) — MIT license
