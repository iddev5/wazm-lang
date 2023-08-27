const Air = @This();

const std = @import("std");

allocator: std.mem.Allocator,
functions: []const FuncBlock,

pub const FuncBlock = struct {
    instructions: []const Inst,
    start_inst: usize,
    params: []const ValueType,
    result: []const ValueType,
};

pub const ValueType = enum {
    int,
    float,
};

pub fn deinit(air: *Air) void {
    for (air.functions) |func|
        air.allocator.free(func.instructions);

    air.allocator.free(air.functions);
}

pub const InstType = enum {
    float,
    add,
    sub,
    mul,
    div,
    negate,
};

pub const Inst = union(InstType) {
    float: f64,
    add: BinaryOp,
    sub: BinaryOp,
    mul: BinaryOp,
    div: BinaryOp,
    negate: UnaryOp,

    pub const Index = u32;

    pub const BinaryOp = struct {
        lhs: Inst.Index,
        rhs: Inst.Index,
    };

    pub const UnaryOp = struct {
        inst: Inst.Index,
    };
};
