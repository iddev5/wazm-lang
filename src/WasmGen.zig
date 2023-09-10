const WasmGen = @This();

const std = @import("std");
const leb = std.leb;
const Air = @import("Air.zig");

pub const Module = struct {
    code: []const u8,
};

pub const Opcode = enum(u8) {
    block = 0x02,
    loop = 0x03,
    if_op = 0x04,
    else_op = 0x05,
    br = 0x0c,
    br_if = 0x0d,
    ret = 0x0f,
    local_get = 0x20,
    local_set = 0x21,
    global_get = 0x23,
    global_set = 0x24,
    i32_const = 0x41,
    f64_const = 0x44,
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    f64_eq = 0x61,
    f64_ne = 0x62,
    f64_lt = 0x63,
    f64_gt = 0x64,
    f64_le = 0x65,
    f64_ge = 0x66,
    f64_neg = 0x9a,
    f64_add = 0xa0,
    f64_sub = 0xa1,
    f64_mul = 0xa2,
    f64_div = 0xa3,
    end = 0x0b,
};

pub const Section = struct {
    ty: Type,
    code: std.ArrayList(u8),
    count: u32 = 0,

    pub fn init(ty: Type, allocator: std.mem.Allocator) Section {
        return .{ .ty = ty, .code = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(sec: *Section) void {
        sec.code.deinit();
    }

    pub fn emit(sec: *const Section, w: anytype) !void {
        // Section code
        try leb.writeULEB128(w, @intFromEnum(sec.ty));

        // Start section only has one element
        if (sec.ty == .start) {
            try leb.writeULEB128(w, @as(u32, @intCast(sec.code.items.len)));
        } else {
            // Size of the section
            try leb.writeULEB128(w, @as(u32, @intCast(sec.code.items.len + 1)));
            // Num/count of elements
            try leb.writeULEB128(w, @as(u32, sec.count));
        }

        try w.writeAll(sec.code.items);
    }

    pub const Type = enum(u8) {
        custom = 0,
        type = 1,
        import = 2,
        func = 3,
        table = 4,
        mem = 5,
        global = 6,
        exp = 7,
        start = 8,
        elem = 9,
        code = 10,
        data = 11,
        datacount = 12,
    };
};

pub const WasmType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    vec = 0x7b,
    funcref = 0x70,
    externref = 0x6f,
    func = 0x60,
    void = 0x40,
    _,
};

pub const Mutability = enum(u8) {
    immut = 0x00,
    mut = 0x01,
};

pub const Export = enum(u8) {
    func = 0x00,
};

allocator: std.mem.Allocator,
ir: *Air,
sections: [12]Section = undefined,
num_sections: usize = 0,

const module_header = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
const module_version = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

fn section(gen: *WasmGen, ty: Section.Type) *Section {
    for (&gen.sections) |*sec|
        if (sec.ty == ty)
            return sec;

    gen.sections[gen.num_sections] = Section.init(ty, gen.allocator);
    gen.num_sections += 1;
    return &gen.sections[gen.num_sections - 1];
}

fn resolveValueType(gen: *WasmGen, ty: Air.ValueType) WasmType {
    _ = gen;
    return switch (ty) {
        .void => unreachable,
        .bool => .i32,
        .float => .f64,
    };
}

pub fn emit(gen: *WasmGen, w: anytype) !Module {
    try w.writeAll(module_header[0..]);
    try w.writeAll(module_version[0..]);

    const global_section = gen.section(.global);
    global_section.count = @intCast(gen.ir.globals.len);

    const global_writer = global_section.code.writer();
    for (gen.ir.globals) |global| {
        const resolved_type = gen.resolveValueType(global);
        try gen.emitEnum(global_writer, resolved_type);
        try gen.emitEnum(global_writer, Mutability.mut); // TODO: mutability setting

        switch (resolved_type) {
            .i32 => try gen.emitBool(global_writer, false),
            .f64 => try gen.emitFloat(global_writer, 0.0),
            else => {},
        }
        try gen.emitOpcode(global_writer, .end);
    }

    // Entry point: implicit main function
    try gen.emitFunc(.{
        .start_inst = gen.ir.start_inst,
        .inst_len = @intCast(gen.ir.instructions.len - gen.ir.start_inst),
        .locals = gen.ir.locals,
        .params = &.{},
        .result = &.{},
    });

    const func_section = gen.section(.func);
    const main_index = func_section.count - 1;

    // Export the main function under the __start symbol
    var export_section = gen.section(.exp);
    export_section.count += 1;

    const export_writer = export_section.code.writer();
    const main_name = "__start";
    try gen.emitUnsigned(export_writer, @as(u32, @intCast(main_name.len)));
    try export_writer.writeAll(main_name);
    try gen.emitEnum(export_writer, Export.func);
    try gen.emitUnsigned(export_writer, main_index);

    std.sort.insertion(Section, gen.sections[0..gen.num_sections], {}, sortSections);

    for (gen.sections[0..gen.num_sections]) |sec|
        try sec.emit(w);

    return .{
        .code = "",
    };
}

fn sortSections(ctx: void, lhs: Section, rhs: Section) bool {
    _ = ctx;
    return @intFromEnum(lhs.ty) < @intFromEnum(rhs.ty);
}

fn emitFunc(gen: *WasmGen, func: Air.Inst.Function) !void {
    // TODO: approximate initial size
    var func_code = std.ArrayList(u8).init(gen.allocator);
    defer func_code.deinit();

    var func_code_writer = func_code.writer();

    try gen.emitUnsigned(func_code_writer, @as(u32, @intCast(func.locals.len)));
    for (func.locals) |local| {
        try gen.emitUnsigned(func_code_writer, @as(u8, 1));
        try gen.emitEnum(func_code_writer, gen.resolveValueType(local));
    }

    try gen.emitBlock(func_code_writer, .{
        .start_inst = func.start_inst,
        .inst_len = func.inst_len,
    });

    // Function type
    var type_section = gen.section(.type);
    type_section.count += 1;

    const type_writer = type_section.code.writer();
    try gen.emitEnum(type_writer, WasmType.func);

    try gen.emitUnsigned(type_writer, @as(u32, @intCast(func.params.len)));
    for (func.params) |param|
        try type_writer.writeByte(@intFromEnum(gen.resolveValueType(param)));

    try gen.emitUnsigned(type_writer, @as(u32, @intCast(func.result.len)));
    for (func.result) |result|
        try type_writer.writeByte(@intFromEnum(gen.resolveValueType(result)));

    // Function entry
    var func_section = gen.section(.func);
    func_section.count += 1;

    const func_writer = func_section.code.writer();
    try gen.emitUnsigned(func_writer, func_section.count - 1);

    // Function code
    var code_section = gen.section(.code);
    code_section.count += 1;

    const code_writer = code_section.code.writer();
    // Emit function size the end opcode
    try gen.emitUnsigned(code_writer, @as(u32, @intCast(func_code.items.len + 1)));

    try code_writer.writeAll(func_code.items);
    try gen.emitOpcode(code_writer, .end);
}

fn emitBlock(gen: *WasmGen, writer: anytype, block: Air.Inst.Block) !void {
    var inst_index: usize = block.start_inst;
    while (inst_index < block.start_inst + block.inst_len) : (inst_index += 1) {
        switch (gen.ir.instructions[inst_index]) {
            .block => |blk| {
                inst_index += blk.inst_len;
                continue;
            },
            .func => |fun| {
                inst_index += fun.inst_len;
                continue;
            },
            else => {},
        }

        const iindex: isize = @intCast(inst_index);
        if (iindex - 1 >= 0 and gen.ir.instructions[inst_index - 1] == .stmt)
            continue;

        try gen.emitTopLevel(
            writer,
            inst_index,
        );
    }
}

fn emitTopLevel(gen: *WasmGen, writer: anytype, inst: usize) anyerror!void {
    switch (gen.ir.instructions[inst]) {
        .local_set => try gen.emitLocal(writer, inst),
        .global_set => try gen.emitGlobal(writer, inst),
        .ret => try gen.emitRet(writer, inst),
        .cond => try gen.emitCond(writer, inst),
        .loop => try gen.emitLoop(writer, inst),
        .br => {
            try gen.emitOpcode(writer, .br);
            try gen.emitUnsigned(writer, @as(u32, 1));
        },
        .block_do => |block| try gen.emitBlock(writer, gen.ir.instructions[block].block),

        else => {},
    }
}

fn emitLocal(gen: *WasmGen, writer: anytype, inst: usize) !void {
    const inst_obj = gen.ir.instructions[inst];
    try gen.emitExpr(writer, inst_obj.local_set.value);
    try gen.emitOpcode(writer, .local_set);
    try gen.emitUnsigned(writer, inst_obj.local_set.index);
}

fn emitGlobal(gen: *WasmGen, writer: anytype, inst: usize) !void {
    const inst_obj = gen.ir.instructions[inst];
    try gen.emitExpr(writer, inst_obj.global_set.value);
    try gen.emitOpcode(writer, .global_set);
    try gen.emitUnsigned(writer, inst_obj.global_set.index);
}

fn emitRet(gen: *WasmGen, writer: anytype, inst: usize) !void {
    try gen.emitExpr(writer, gen.ir.instructions[inst].ret.value);
    try gen.emitOpcode(writer, .ret);
}

fn emitCond(gen: *WasmGen, writer: anytype, inst: usize) !void {
    const inst_obj = gen.ir.instructions[inst];

    // Emit the condition with the if opcode followed by void type
    // to state that the block does not return any value
    try gen.emitExpr(writer, inst_obj.cond.cond);
    try gen.emitOpcode(writer, .if_op);
    try gen.emitEnum(writer, WasmType.void);

    // Emit the chunk
    try gen.emitBlock(writer, gen.ir.instructions[inst_obj.cond.result].block);

    // Check for presence of else block
    switch (gen.ir.instructions[inst_obj.cond.else_blk]) {
        .nop => {},
        else => |tag| {
            try gen.emitOpcode(writer, .else_op);
            if (tag == .block) {
                try gen.emitBlock(writer, tag.block);
            } else {
                try gen.emitTopLevel(writer, inst_obj.cond.else_blk + 1);
            }
        },
    }

    try gen.emitOpcode(writer, .end);
}

fn emitLoop(gen: *WasmGen, writer: anytype, inst: usize) !void {
    const inst_obj = gen.ir.instructions[inst].loop;

    // Create a block and a loop each of result type void
    // A block and a loop are opposite to each other in that
    // breaking from a loop jumps to the start of loop while
    // breaking from a block jumps to the end of it.
    try gen.emitOpcode(writer, .block);
    try gen.emitEnum(writer, WasmType.void);
    try gen.emitOpcode(writer, .loop);
    try gen.emitEnum(writer, WasmType.void);

    // Emit the condition and check if cond == false
    // If so, jump to the end of the block. The value 1 (one)
    // after br_if specifies the no of outer scope to jump.
    // The innermost scope in this case is loop (index 0) while
    // the one above it is block (index 1)
    try gen.emitExpr(writer, inst_obj.cond);
    try gen.emitOpcode(writer, .i32_eqz);
    try gen.emitOpcode(writer, .br_if);
    try gen.emitUnsigned(writer, @as(u32, 1));

    // Loop normally
    try gen.emitOpcode(writer, .br);
    try gen.emitUnsigned(writer, @as(u32, 0));

    try gen.emitBlock(writer, gen.ir.instructions[inst_obj.block].block);

    for (0..2) |_|
        try gen.emitOpcode(writer, .end);
}

fn emitBinOp(gen: *WasmGen, writer: anytype, inst: usize, op: Air.Inst.BinaryOp) !void {
    const inst_obj = gen.ir.instructions[inst];
    try gen.emitExpr(writer, op.lhs);
    try gen.emitExpr(writer, op.rhs);

    try gen.emitOpcode(writer, buildOpcode(
        std.meta.activeTag(inst_obj),
        gen.resolveValueType(op.result_ty),
    ));
}

fn emitUnOp(gen: *WasmGen, writer: anytype, inst: usize, op: Air.Inst.UnaryOp) !void {
    const inst_obj = gen.ir.instructions[inst];
    try gen.emitExpr(writer, op.inst);

    try gen.emitOpcode(writer, buildOpcode(
        std.meta.activeTag(inst_obj),
        gen.resolveValueType(op.result_ty),
    ));
}

fn emitExpr(gen: *WasmGen, writer: anytype, inst: usize) anyerror!void {
    switch (gen.ir.instructions[inst]) {
        .bool => |info| try gen.emitBool(writer, info),
        .float => |info| try gen.emitFloat(writer, info),
        .ident => try gen.emitIdent(writer, inst),
        .add,
        .sub,
        .mul,
        .div,
        .equal,
        .not_equal,
        .less_than,
        .greater_than,
        .less_equal,
        .greater_equal,
        => |info| try gen.emitBinOp(writer, inst, info),
        .negate => |info| try gen.emitUnOp(writer, inst, info),
        else => unreachable,
    }
}

fn emitBool(gen: *WasmGen, writer: anytype, val: bool) !void {
    try gen.emitOpcode(writer, .i32_const);
    try writer.writeByte(@intFromBool(val));
}

fn emitFloat(gen: *WasmGen, writer: anytype, val: f64) !void {
    try gen.emitOpcode(writer, .f64_const);

    const float = @as(u64, @bitCast(val));
    try writer.writeIntLittle(u32, @as(u32, @truncate(float)));
    try writer.writeIntLittle(u32, @as(u32, @truncate(float >> 32)));
}

fn emitUnsigned(gen: *WasmGen, writer: anytype, val: anytype) !void {
    _ = gen;
    try leb.writeULEB128(writer, val);
}

fn emitSigned(gen: *WasmGen, writer: anytype, val: anytype) !void {
    _ = gen;
    try leb.writeILEB128(writer, val);
}

fn emitEnum(gen: *WasmGen, writer: anytype, val: anytype) !void {
    _ = gen;
    try leb.writeULEB128(writer, @intFromEnum(val));
}

fn emitIdent(gen: *WasmGen, writer: anytype, inst: usize) !void {
    const ident = gen.ir.instructions[inst].ident;
    try gen.emitOpcode(writer, if (ident.global) .global_get else .local_get);
    try gen.emitUnsigned(writer, ident.index);
}

fn emitOpcode(gen: *WasmGen, writer: anytype, op: Opcode) !void {
    _ = gen;
    try writer.writeByte(@intFromEnum(op));
}

fn buildOpcode(op: Air.InstType, ty: WasmType) Opcode {
    return switch (op) {
        .add => switch (ty) {
            .f64 => .f64_add,
            else => unreachable, // do when needed
        },
        .sub => switch (ty) {
            .f64 => .f64_sub,
            else => unreachable, // do when needed
        },
        .mul => switch (ty) {
            .f64 => .f64_mul,
            else => unreachable, // do when needed
        },
        .div => switch (ty) {
            .f64 => .f64_div,
            else => unreachable, // do when needed
        },
        .negate => switch (ty) {
            .f64 => .f64_neg,
            else => unreachable,
        },
        .equal => switch (ty) {
            .i32 => .i32_eq,
            .f64 => .f64_eq,
            else => unreachable,
        },
        .not_equal => switch (ty) {
            .i32 => .i32_ne,
            .f64 => .f64_ne,
            else => unreachable,
        },
        .less_than => switch (ty) {
            .f64 => .f64_lt,
            else => unreachable,
        },
        .greater_than => switch (ty) {
            .f64 => .f64_gt,
            else => unreachable,
        },
        .less_equal => switch (ty) {
            .f64 => .f64_le,
            else => unreachable,
        },
        .greater_equal => switch (ty) {
            .f64 => .f64_ge,
            else => unreachable,
        },
        else => unreachable,
    };
}
