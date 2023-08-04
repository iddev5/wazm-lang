const std = @import("std");
const Ast = @import("Ast.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    var tree = try Ast.parse(allocator, "hello = -12 - #12 * -12");
    defer tree.deinit();

    try tree.printTree(stdout);
}

comptime {
    _ = @import("Tokenizer.zig");
    _ = @import("Ast.zig");
}
