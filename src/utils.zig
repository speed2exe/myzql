const std = @import("std");

// This is a fixed-size byte array to avoid heap allocation.
pub fn FixedBytes(comptime max: usize) type {
    return struct {
        buf: [max]u8 = undefined,
        len: usize = 0,

        pub fn get(self: *const FixedBytes(max)) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *FixedBytes(max), src: []const u8) void {
            std.debug.assert(src.len <= max);
            const dest = self.buf[0..src.len];
            @memcpy(dest, src);
            self.len = src.len;
        }
    };
}

fn numSlice(comptime N: usize, shape: *const [N]usize) usize {
    return switch (N) {
        0 => return 0,
        1 => return shape[0],
        else => numSlice(N - 1, shape[1..]) * shape[0] + shape[0],
    };
}

// General purpose Multi-Dimensional Array allocating function
// T:     type of the element
// N:     number of dimensions
// shape: shape of the ndarray
// does not work on packed structs
pub fn ndArrayAlloc(comptime T: type, comptime N: usize, shape: *const [N]usize, allocator: std.mem.Allocator) !struct { NdSlice(T, N), []u8 } {
    std.debug.assert(N > 0);
    const num_elem = blk: {
        var res = shape[0];
        inline for (shape[1..]) |n| {
            res *= n;
        }
        break :blk res;
    };

    // Extra Allocation for Slices
    // *[N]T          => 0                                   + num_elem * sizeof(T)
    // *[M]*[N]T      => M * sizeof([]T)                     + num_elem * sizeof(T)
    // *[O]*[M]*[N]T  => O * sizeof([][]T) + M * sizeof([]T) + num_elem * sizeof(T)
    // ...
    const num_slice = numSlice(N - 1, shape[0 .. shape.len - 1]);

    const size_of_slices = num_slice * @sizeOf([]void);
    const size_of_elems = num_elem * @sizeOf(T);

    const raw = try allocator.alloc(u8, (size_of_elems + size_of_slices));

    const refs = raw[0..size_of_slices];
    const elems = std.mem.bytesAsSlice(T, raw[size_of_slices..]);

    return .{ setNdArraySlices(T, N, shape, @alignCast(elems), refs), raw };
}

fn NdSlice(comptime T: type, comptime N: usize) type {
    // N: 0, T
    // N: 1, []T
    // N: 2, [][]T
    // ...

    switch (N) {
        0 => return T,
        else => return []NdSlice(T, N - 1),
    }
}

fn setNdArraySlices(
    comptime T: type,
    comptime N: usize,
    shape: *const [N]usize, // {2,3,4}
    elems: []T, // .{ T ** 24 }
    refs: []u8,
) NdSlice(T, N) {
    std.debug.assert(N > 0);
    if (N == 1) {
        return elems;
    }

    const divider = shape[0] * @sizeOf([]void);
    const parent_refs = refs[0..divider];
    const children_refs = refs[divider..];

    const res = std.mem.bytesAsSlice(NdSlice(T, N - 1), parent_refs); // [][][]T
    for (res, 0..) |*elem, i| { // elem: [][]T
        const next_refs = blk: {
            if (N == 2) {
                break :blk &.{};
            }
            const ref_start = i * shape[1] * @sizeOf([]void);
            const ref_end = (i + 1) * shape[1] * @sizeOf([]void);
            break :blk children_refs[ref_start..ref_end];
        };

        const elem_start = i * elems.len / shape[0];
        const elem_end = (i + 1) * elems.len / shape[0];

        elem.* = setNdArraySlices(T, N - 1, shape[1..], elems[elem_start..elem_end], next_refs);
    }

    return @alignCast(res);
}

const MyStruct = struct { a: u8, b: u16, c: f32, d: f64, e: u64, f: u64 };

test "ndArrayAlloc - 1D" {
    const shape = &[_]usize{3};
    const nd, const raw = try ndArrayAlloc(MyStruct, shape.len, shape, std.testing.allocator);
    defer std.testing.allocator.free(raw);
    for (nd) |*elem| {
        elem.* = .{ .a = 1, .b = 2, .c = 3.0, .d = 4.0, .e = 5, .f = 6 };
    }
}

test "ndArrayAlloc - 2D" {
    const shape = &[_]usize{ 2, 3 };
    const nnd, const raw = try ndArrayAlloc(MyStruct, shape.len, shape, std.testing.allocator);
    defer std.testing.allocator.free(raw);
    for (nnd) |nd| {
        for (nd) |*elem| {
            elem.* = .{ .a = 1, .b = 2, .c = 3.0, .d = 4.0, .e = 5, .f = 6 };
        }
    }
}

test "ndArrayAlloc - 3D" {
    const shape = &[_]usize{ 2, 3, 4 };
    const nnnd, const raw = try ndArrayAlloc(MyStruct, shape.len, shape, std.testing.allocator);
    defer std.testing.allocator.free(raw);
    for (nnnd) |nnd| {
        for (nnd) |nd| {
            for (nd) |*elem| {
                elem.* = .{ .a = 1, .b = 2, .c = 3.0, .d = 4.0, .e = 5, .f = 6 };
            }
        }
    }
}

// broken, todo:use hashmap to check duplication pointer
// test "ndArrayAlloc - 4D" {
//     const shape = &[_]usize{ 2, 3, 4, 5 };
//     const nnnnd, const raw = try ndArrayAlloc(MyStruct, shape.len, shape, std.testing.allocator);
//     defer std.testing.allocator.free(raw);
//     for (nnnnd) |nnnd| {
//         for (nnnd) |nnd| {
//             for (nnd) |nd| {
//                 for (nd) |*elem| {
//                     elem.* = .{ .a = 1, .b = 2, .c = 3.0, .d = 4.0, .e = 5, .f = 6 };
//                 }
//             }
//         }
//     }
// }
