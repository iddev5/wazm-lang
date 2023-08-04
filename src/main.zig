const std = @import("std");
const Ast = @import("Ast.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    var tree = try Ast.parse(allocator, "-12 * 15 + 2");
    try tree.printAst(stdout);
}

comptime {
    _ = @import("Tokenizer.zig");
}
