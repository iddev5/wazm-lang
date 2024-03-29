const std = @import("std");
const Ast = @import("Ast.zig");
const analysis = @import("analysis.zig");
const WasmGen = @import("WasmGen.zig");
const Diagnostics = @import("Diagnostics.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const source =
        // \\hi, i := -1 + 2 * 3 / 4, true == true
        // \\if true == true then
        // \\    i, hi = true == false, 67 / 22 + hi
        // \\end
        // \\if false then
        // \\    return false
        // \\elseif true then
        // \\    return true
        // \\else
        // \\    m := 12
        // \\    if true then
        // \\        m = m * 2
        // \\        return true
        // \\    else
        // \\        return false
        // \\    end
        // \\    return 10
        // \\end
        // \\do
        // \\    m := true
        // \\end
        // \\return 12
        // \\while true do
        // \\    if i == false then
        // \\        break
        // \\    end
        // \\    m := true
        // \\    do
        // \\        m = false
        // \\    end
        // \\end
        \\m := 34
        // \\n := false
        \\function abc(m: float) float
        // \\    function def(n: float) float
        // \\        return n
        // \\    end
        \\    m = 10
        \\    k := false
        \\    return 0
        \\end
        \\function another(kj: float, ij: bool, lm: float) float, bool
        \\    return 10, true
        \\end
        \\m = abc(10 + 20 * 30)
        \\f := another
        \\x := f(10, false, 30)
    ;

    var diag: Diagnostics = .{ .allocator = allocator, .source = source };
    defer diag.deinit();

    var tree = Ast.parse(allocator, source, &diag) catch |err| switch (err) {
        error.ParsingFailed => return try diag.render(stderr),
        else => |e| return e,
    };
    defer tree.deinit();

    var air = analysis.gen(&tree, &diag) catch |err| switch (err) {
        error.AnalysisFailed => return try diag.render(stderr),
        else => |e| return e,
    };
    if (diag.errors.items.len > 0)
        return try diag.render(stderr);

    defer air.deinit();

    var gen = WasmGen{ .allocator = allocator, .ir = &air };
    defer gen.deinit();

    _ = try gen.emit(stdout);
}

comptime {
    _ = @import("Tokenizer.zig");
    _ = @import("Ast.zig");
    _ = @import("analysis.zig");
    _ = @import("WasmGen.zig");
}
