const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

const pb = @import("protobuf");
const types = pb.types;
const plugin = pb.plugin;
const descr = pb.descriptor;
const protobuf = pb.protobuf;
const CodeGeneratorRequest = plugin.CodeGeneratorRequest;
const FieldDescriptorProto = descr.FieldDescriptorProto;
const Tag = types.Tag;
const tcommon = pb.testing;
const encodeMessage = tcommon.encodeMessage;
const lengthEncode = tcommon.lengthEncode;
const encodeVarint = tcommon.encodeVarint;
const encodeFloat = tcommon.encodeFloat;
const expectEqual = tcommon.expectEqual;
const testInit = tcommon.testInit;
const String = pb.extern_types.String;

const talloc = testing.allocator;
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const tarena = arena.allocator();

test "basic ser" {
    var data = descr.FieldOptions.init();
    data.set(.ctype, .STRING);
    data.set(.lazy, true);
    var ui = descr.UninterpretedOption.init();
    ui.set(.identifier_value, String.init("ident"));
    ui.set(.positive_int_value, 42);
    ui.set(.negative_int_value, -42);
    ui.set(.double_value, 42);
    try data.uninterpreted_option.append(talloc, &ui);
    data.setPresent(.uninterpreted_option);
    defer data.uninterpreted_option.deinit(talloc);
    var buf = std.ArrayList(u8).init(talloc);
    defer buf.deinit();
    try protobuf.serialize(&data.base, buf.writer());

    const message = comptime encodeMessage(.{
        Tag.init(.VARINT, 1), // FieldOptions.ctype
        @intFromEnum(descr.FieldOptions.CType.STRING),
        Tag.init(.VARINT, 5), // FieldOptions.lazy
        true,
        Tag.init(.LEN, 999), // FieldOptions.uninterpreted_option
        lengthEncode(.{
            Tag.init(.LEN, 3), // UninterpretedOption.identifier_value
            lengthEncode(.{"ident"}),
            Tag.init(.VARINT, 4), // UninterpretedOption.positive_int_value
            encodeVarint(u8, 42),
            Tag.init(.VARINT, 5), // UninterpretedOption.negative_int_value
            encodeVarint(i64, -42),
            Tag.init(.I64, 6), // UninterpretedOption.double_value
            encodeFloat(f64, 42.0),
        }),
    });

    try testing.expectEqualSlices(u8, message, buf.items);
}

test "packed repeated ser 1" {
    // from https://developers.google.com/protocol-buffers/docs/encoding#packed
    const Test5 = extern struct {
        base: pb.types.Message,
        // repeated int32 f = 6 [packed=true];
        f: pb.extern_types.ArrayListMut(i32) = .{},

        pub const field_ids = [_]c_uint{6};
        pub const opt_field_ids = [_]c_uint{};
        pub usingnamespace pb.types.MessageMixins(@This());

        pub const field_descriptors = [_]pb.types.FieldDescriptor{
            pb.types.FieldDescriptor.init(
                "f",
                6,
                .LABEL_REPEATED,
                .TYPE_INT32,
                @offsetOf(@This(), "f"),
                null,
                null,
                @intFromEnum(pb.types.FieldDescriptor.FieldFlag.FLAG_PACKED),
            ),
        };
    };

    var data = Test5.init();
    defer data.f.deinit(talloc);
    try data.f.appendSlice(talloc, &.{ 3, 270, 86942 });
    data.setPresent(.f);

    var buf = std.ArrayList(u8).init(talloc);
    defer buf.deinit();
    try protobuf.serialize(&data.base, buf.writer());

    var buf2: [64]u8 = undefined;
    const actual = try std.fmt.bufPrint(&buf2, "{}", .{std.fmt.fmtSliceHexLower(buf.items)});
    try testing.expectEqualStrings("3206038e029ea705", actual);
}

test "packed repeated ser 2" {
    var data = descr.FileDescriptorProto.init();
    // defer data.base.deinit(talloc);
    // ^ don't do this as it tries to free list strings and the bytes of data
    // which are non-heap allocated memory here.
    var deps: pb.extern_types.ArrayListMut(String) = .{};
    try deps.append(talloc, String.init("dep1"));
    defer deps.deinit(talloc);
    data.set(.dependency, deps);
    var pubdeps: pb.extern_types.ArrayListMut(i32) = .{};
    defer pubdeps.deinit(talloc);
    try pubdeps.appendSlice(talloc, &.{ 0, 1, 2 });
    data.set(.public_dependency, pubdeps);

    var buf = std.ArrayList(u8).init(talloc);
    defer buf.deinit();
    try protobuf.serialize(&data.base, buf.writer());

    var ctx = pb.protobuf.context(buf.items, talloc);
    const m = try ctx.deserialize(&descr.FileDescriptorProto.descriptor);
    defer m.deinit(talloc);
    const T = descr.FileDescriptorProto;
    const data2 = try m.as(T);
    try expectEqual(T, data, data2.*);
}

test "ser all_types.proto" {
    const all_types = @import("generated").all_types;
    const T = all_types.All;

    // init the all_types object
    var data = try testInit(T, null, tarena);
    try testing.expectEqual(@as(usize, 1), data.oneof_fields.len);
    try testing.expect(data.oneof_fields.items[0].base.hasFieldId(111));

    // serialize the object to buf
    var buf = std.ArrayList(u8).init(talloc);
    defer buf.deinit();
    try protobuf.serialize(&data.base, buf.writer());

    // deserialize from buf and check equality
    var ctx = protobuf.context(buf.items, talloc);
    const m = try ctx.deserialize(&T.descriptor);
    defer m.deinit(talloc);
    const data2 = try m.as(T);
    try expectEqual(T, data, data2.*);

    // serialize m to buf2 and verify buf and buf2 are equal
    var buf2 = std.ArrayList(u8).init(talloc);
    defer buf2.deinit();
    try protobuf.serialize(m, buf2.writer());
    try testing.expectEqualStrings(buf.items, buf2.items);
}

test "ser oneof-2.proto" {
    const oneof_2 = @import("generated").oneof_2;
    const T = oneof_2.TestAllTypesProto3;

    // init the all_types object
    var data = try testInit(T, null, tarena);
    try testing.expect(data.base.hasFieldId(111));
    try testing.expect(!data.has(.oneof_field__oneof_nested_message));

    // // serialize the object to buf
    var buf = std.ArrayList(u8).init(talloc);
    defer buf.deinit();
    try protobuf.serialize(&data.base, buf.writer());

    // deserialize from buf and check equality
    var ctx = protobuf.context(buf.items, talloc);
    const m = try ctx.deserialize(&T.descriptor);
    defer m.deinit(talloc);
    const data2 = try m.as(T);
    try expectEqual(T, data, data2.*);

    // serialize m to buf2 and verify buf and buf2 are equal
    var buf2 = std.ArrayList(u8).init(talloc);
    defer buf2.deinit();
    try protobuf.serialize(m, buf2.writer());
    try testing.expectEqualStrings(buf.items, buf2.items);
}

test "ser group round trip" {
    const group = @import("generated").group;
    const T = group.Grouped;

    var g = T.init();

    // .data field
    var data = T.Data.init();
    g.set(.data, &data);
    data.set(.group_int32, 202);
    data.set(.group_uint32, 203);

    // .data2 field
    var item = T.Data2.init();
    item.set(.group2_int32, 212);
    item.set(.group2_uint32, 213);
    var data2list = pb.extern_types.ArrayListMut(*T.Data2){};
    defer data2list.deinit(talloc);
    try data2list.append(talloc, &item);
    g.set(.data2, data2list);

    // ser g
    var buf = std.ArrayList(u8).init(talloc);
    defer buf.deinit();
    try pb.protobuf.serialize(&g.base, buf.writer());

    // deser ser g
    var ctx = protobuf.context(buf.items, talloc);
    const m = try ctx.deserialize(&T.descriptor);
    defer m.deinit(talloc);
    const g2 = try m.as(T);
    try testing.expect(g2.has(.data));
    try testing.expect(g2.has(.data2));
    try testing.expect(g2.data2.len == 1);

    // ser deser ser g
    var buf2 = std.ArrayList(u8).init(talloc);
    defer buf2.deinit();
    try pb.protobuf.serialize(m, buf2.writer());

    try testing.expectEqualStrings(buf.items, buf2.items);
}

test "http example" {
    // this test is only verifies that serialize()'s error set supports
    // more than just std.fs.File errors

    const oneof_2 = @import("generated").oneof_2;
    var data = oneof_2.TestAllTypesProto3.init();
    var http_req: std.http.Client.Request = undefined;
    var bufw = std.io.bufferedWriter(http_req.writer());
    try pb.protobuf.serialize(&data.base, bufw.writer());
}
