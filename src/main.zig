const std = @import("std");
const assert = std.debug.assert;

const zlib = @cImport(@cInclude("zlib.h"));

const Header = packed struct
{
    headerString: [28]u8,
    blockOffset: u32,
    sizeCompressed: u32,
    version: u32,
    sizeDecompressed: u32,
    compressedBlocks: u32,
    // subHeader: SubHeader, // https://github.com/ziglang/zig/issues/2627
};

const SubHeader = packed struct
{
    versionString: [4]u8,
    versionNumber: u32,
    buildNumber: u16,
    flags: u16,
    replayLengthMs: u32,
    checksum: u32,
};

const DataBlockHeader = packed struct
{
    sizeCompressed: u16,
    sizeDecompressed: u16,
    unknown: u32, // checksum?
};

const SlotRecord = packed struct
{
    playerId: u8,
    mapDownloadPercent: u8,
    status: u8,
    flag: u8,
    teamNumber: u8,
    color: u8,
    raceFlags: u8,
    computerAiStrength: u8,
    handicapPercent: u8,
};

const Block = struct
{
};

const IdCountMapType = std.AutoHashMap(u32, u32);
var idCountMap_: IdCountMapType = undefined;

fn verifyHeaderString(string: [28]u8) bool
{
    if (!std.mem.eql(u8, string[0..26], "Warcraft III recorded game")) {
        return false;
    }
    if (string[26] != 0x1A or string[27] != 0) {
        return false;
    }
    return true;
}

fn verifySubHeaderString(string: [4]u8) bool
{
    return std.mem.eql(u8, &string, "PX3W") or std.mem.eql(u8, &string, "3RAW");
}

fn peekPtr(comptime theType: type, buf: []const u8, i: u32) !*const theType
{
    comptime {
        assert(@alignOf(theType) == 1);
    }
    if (i + @sizeOf(theType) > buf.len) {
        return error.OutOfBounds;
    }
    return @ptrCast(*const theType, &buf[i]);
}

fn peek(comptime theType: type, buf: []const u8, i: u32) !theType
{
    const size = comptime @sizeOf(theType);
    if (i + size > buf.len) {
        return error.OutOfBounds;
    }
    const a = comptime @alignOf(theType);
    if (a == 1) {
        return (try peekPtr(theType, buf, i)).*;
    }
    else {
        comptime {
            assert(size <= 8);
        }
        var slice: [8]u8 align(8) = undefined;
        std.mem.copy(u8, &slice, buf[i..i+size]);
        const ptr = @ptrCast(*const theType, &slice);
        return ptr.*;
    }
}

fn readPtr(comptime theType: type, buf: []const u8, iPtr: *u32) !*const theType
{
    const ptr = try peekPtr(theType, buf, iPtr.*);
    iPtr.* += @sizeOf(theType);
    return ptr;
}

fn read(comptime theType: type, buf: []const u8, iPtr: *u32) !theType
{
    const value = try peek(theType, buf, iPtr.*);
    iPtr.* += @sizeOf(theType);
    return value;
}

fn readStringZ(buf: []const u8, iPtr: *u32) !?[]const u8
{
    var i: u32 = iPtr.*;
    while (i < buf.len and buf[i] != 0) : (i += 1) {}
    if (i >= buf.len) {
        return null;
    }
    assert(buf[i] == 0);
    const iPrev = iPtr.*;
    iPtr.* = i + 1;
    return buf[iPrev..i];
}

fn idToString(id: u32) [4]u8
{
    const bytes = @ptrCast(*align(4) const [4]u8, &id);
    return [4]u8 {
        bytes[3], bytes[2], bytes[1], bytes[0]
    };
}

fn parseBlock(block: *Block, buf: []const u8, iPtr: *u32) !void
{
    const id = try read(u8, buf, iPtr);
    switch (id) {
        0x17 => {
            // leave game
            iPtr.* += 13;
        },
        0x1A, 0x1B, 0x1C => {
            // unknown
            iPtr.* += 4;
        },
        0x1E, 0x1F => {
            // TimeSlot
            const nBytes = try read(u16, buf, iPtr);
            if (nBytes < 2) {
                return error.TimeSlotBytes;
            }
            const time = try peek(u16, buf, iPtr.*);
            const data = buf[(iPtr.*)+2..(iPtr.*)+nBytes];
            var i: u32 = 0;
            while (i < data.len) {
                const playerId = try read(u8, data, &i);
                const actionBytes = try read(u16, data, &i);
                const actionData = data[i..i+actionBytes];
                var j: u32 = 0;
                while (j < actionData.len) {
                    const actionId = try read(u8, actionData, &j);
                    switch (actionId) {
                        0x01 => {
                            // pause game
                        },
                        0x02 => {
                            // resume game
                        },
                        0x03 => {
                            // single-player set game speed (menu)
                            const gameSpeed = try read(u8, actionData, &j);
                        },
                        0x04 => {
                            // single-player set game speed (num+)
                        },
                        0x05 => {
                            // single-player set game speed (num-)
                        },
                        0x06 => {
                            // save game
                            const saveName = try readStringZ(actionData, &j);
                        },
                        0x07 => {
                            // save game finished
                            _ = try read(u32, actionData, &j); // unknown
                        },
                        0x10 => {
                            // unit/building ability (no params)
                            const abilityFlags = try read(u16, actionData, &j);
                            const itemId = try read(u32, actionData, &j);
                            _ = try read(u32, actionData, &j); // unknown
                            _ = try read(u32, actionData, &j); // unknown
                        },
                        0x11 => {
                            // unit/building ability (pos)
                            const abilityFlags = try read(u16, actionData, &j);
                            const itemId = try read(u32, actionData, &j);
                            _ = try read(u32, actionData, &j); // unknown
                            _ = try read(u32, actionData, &j); // unknown
                            const targetX = try read(u32, actionData, &j);
                            const targetY = try read(u32, actionData, &j);
                        },
                        0x12 => {
                            // unit/building ability (pos and object ID)
                            const abilityFlags = try read(u16, actionData, &j);
                            const itemId = try read(u32, actionData, &j);
                            _ = try read(u32, actionData, &j); // unknown
                            _ = try read(u32, actionData, &j); // unknown
                            const targetX = try read(u32, actionData, &j);
                            const targetY = try read(u32, actionData, &j);
                            const objId1 = try read(u32, actionData, &j);
                            const objId2 = try read(u32, actionData, &j);
                        },
                        0x13 => {
                            // give item to unit / drop item on ground
                            // (pos, object ID A and B)
                            const abilityFlags = try read(u16, actionData, &j);
                            const itemId = try read(u32, actionData, &j);
                            _ = try read(u32, actionData, &j); // unknown
                            _ = try read(u32, actionData, &j); // unknown
                            const targetX = try read(u32, actionData, &j);
                            const targetY = try read(u32, actionData, &j);
                            const objId1 = try read(u32, actionData, &j);
                            const objId2 = try read(u32, actionData, &j);
                            const itemObjId1 = try read(u32, actionData, &j);
                            const itemObjId2 = try read(u32, actionData, &j);
                        },
                        0x14 => {
                            // unit/building ability
                            // (two target positions and two item IDs)
                            const abilityFlags = try read(u16, actionData, &j);
                            const itemId1 = try read(u32, actionData, &j);
                            _ = try read(u32, actionData, &j); // unknown
                            _ = try read(u32, actionData, &j); // unknown
                            const targetX1 = try read(u32, actionData, &j);
                            const targetY1 = try read(u32, actionData, &j);

                            const itemId2 = try read(u32, actionData, &j);
                            j += 9; // unknown
                            const targetX2 = try read(u32, actionData, &j);
                            const targetY2 = try read(u32, actionData, &j);
                        },
                        0x16 => {
                            // change selection (unit, building, area)
                            const mode = try read(u8, actionData, &j);
                            const n = try read(u16, actionData, &j);
                            j += n * 8;
                        },
                        0x17 => {
                            // assign group hotkey
                            const groupNumber = try read(u8, actionData, &j);
                            const n = try read(u16, actionData, &j);
                            j += n * 8;
                        },
                        0x18 => {
                            // select group hotkey
                            const groupNumber = try read(u8, actionData, &j);
                            _ = try read(u8, actionData, &j); // unknown
                        },
                        0x19 => {
                            // select subgroup
                            const itemId = try read(u32, actionData, &j);
                            if (idCountMap_.get(itemId)) |count| {
                                try idCountMap_.put(itemId, count + 1);
                            }
                            else {
                                try idCountMap_.put(itemId, 1);
                            }
                            const objectId1 = try read(u32, actionData, &j);
                            const objectId2 = try read(u32, actionData, &j);
                        },
                        0x1A => {
                            // pre subselection
                        },
                        0x1B => {
                            // unknown
                            j += 9;
                        },
                        0x1C => {
                            // select ground item
                            j += 9;
                        },
                        0x1D => {
                            // cancel hero revival
                            j += 8;
                        },
                        0x1E => {
                            // remove unit from building queue
                            j += 5;
                        },
                        0x21 => {
                            // unknown
                            j += 8;
                        },
                        0x20, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29,
                        0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32 => {
                            return error.NoSinglePlayerForNow;
                            // single-player cheats
                            // switch (actionId) {
                            //     0x20, 0x22, 0x23,  => {
                            //         j += 1,
                            //     }
                            // }
                        },
                        0x50 => {
                            j += 5;
                        },
                        0x51=> {
                            j += 9;
                        },
                        0x60 => {
                            _ = try read(u32, actionData, &j); // unknown
                            _ = try read(u32, actionData, &j); // unknown
                            const command = try readStringZ(actionData, &j);
                        },
                        0x61 => {
                            // ESC pressed
                        },
                        0x62 => {
                            j += 12;
                        },
                        0x66 => {
                            // enter choose hero skill submenu
                        },
                        0x67 => {
                            // enter choose building submenu
                        },
                        0x68 => {
                            // minimap ping
                            j += 12;
                        },
                        0x69 => {
                            // continue game (block A)
                            j += 16;
                        },
                        0x6A => {
                            // continue game (block B)
                            j += 16;
                        },
                        0x6B => {
                            // MMD
                            // TODO this is my best guess about the data format
                            const filename = (try readStringZ(actionData, &j)) orelse {
                                return error.MMDNoFilename;
                            };
                            if (!std.mem.eql(u8, filename, "MMD.Dat")) {
                                return error.MMDBadFilename;
                            }
                            const valKey = (try readStringZ(actionData, &j)) orelse {
                                return error.MMDNoValKey;
                            };
                            const message = (try readStringZ(actionData, &j)) orelse {
                                return error.MMDNoMessage;
                            };
                            const checksum = try read(u32, actionData, &j);
                        },
                        0x75 => {
                            _ = try read(u8, actionData, &j); // unknown
                        },
                        else => {
                            std.log.err("Unknown actionId={X} ind={} i={} j={}", .{actionId,  iPtr.*, i, j});
                            return error.UnknownActionId;
                        }
                    }
                    // TODO parse action IDs
                }
                i += actionBytes;
            }

            iPtr.* += nBytes;
        },
        0x20 => {
            // player chat message
            const playerId = try read(u8, buf, iPtr);
            const nBytes = try read(u16, buf, iPtr);
            iPtr.* += nBytes;
        },
        0x22 => {
            // unknown
            iPtr.* += 5;
        },
        0x23 => {
            // unknown
            iPtr.* += 10;
        },
        0x2F => {
            const mode = try read(u32, buf, iPtr);
            const seconds = try read(u32, buf, iPtr);
        },
        else => {
            std.log.err("Unknown block ID {X}", .{id});
            return error.UnknownBlockId;
        }
    }
}

fn parseDecompressed(decompressed: []const u8, allocator: *std.mem.Allocator) !void
{
    // player record
    var ind: u32 = 0;
    _ = try read(u32, decompressed, &ind); // unknown
    const recordId = try read(u8, decompressed, &ind);
    if (recordId != 0) {
        return error.NonHostPlayerRecord;
    }
    const playerId = try read(u8, decompressed, &ind);
    const playerName = (try readStringZ(decompressed, &ind)) orelse {
        return error.PlayerName;
    };
    const extraBytes = try read(u8, decompressed, &ind);
    ind += extraBytes; // nothing important here
    std.log.info("{}: {s}", .{playerId, playerName});

    // game name
    const gameName = (try readStringZ(decompressed, &ind)) orelse {
        return error.GameName;
    };
    std.log.info("game name: {s}", .{gameName});

    ind += 1; // null byte

    // encoded string
    const encoded = (try readStringZ(decompressed, &ind)) orelse {
        return error.EncodedString;
    };
    var decoded = std.ArrayList(u8).init(allocator);
    defer decoded.deinit();
    var mask: u8 = undefined;
    for (encoded) |char, i| {
        const imod8 = @intCast(u3, i % 8);
        if (imod8 == 0) {
            mask = char;
        }
        else {
            if ((mask & (@intCast(u8, 1) << imod8)) == 0) {
                try decoded.append(char - 1);
            }
            else {
                try decoded.append(char);
            }
        }
    }

    // TODO flags from decoded
    std.log.info("{s}", .{decoded.items});

    const playerCount = try read(u32, decompressed, &ind);
    const gameType = try read(u32, decompressed, &ind);
    const languageId = try read(u32, decompressed, &ind);

    const recordId2 = try peek(u8, decompressed, ind);
    if (recordId2 == 0x16) {
        while (true) {
            const rid = try peek(u8, decompressed, ind);
            if (rid != 0x16) {
                break;
            }
            ind += 1;
            const pId = try read(u8, decompressed, &ind);
            const pName = try readStringZ(decompressed, &ind);
            const eb = try read(u8, decompressed, &ind);
            ind += eb;
            _ = try read(u32, decompressed, &ind); // unknown

            std.log.info("{}: {s}", .{pId, pName});
        }
    }

    const slotRecordId = try read(u8, decompressed, &ind);
    if (slotRecordId != 0x19) {
        return error.BadSlotRecordId;
    }
    const nBytes = try read(u16, decompressed, &ind);
    const nSlotRecords = try read(u8, decompressed, &ind);
    var slot: u8 = 0;
    while (slot < nSlotRecords) : (slot += 1) {
        const slotRecordPtr = try readPtr(SlotRecord, decompressed, &ind);
        std.log.info("{}", .{slotRecordPtr.*});
    }
    const seed = try read(u32, decompressed, &ind);
    const selectMode = try read(u8, decompressed, &ind);
    const startSpotCount = try read(u8, decompressed, &ind);

    // replay data blocks
    var numBlocks: u32 = 0;
    defer std.log.info("ind={} numBlocks={}", .{ind, numBlocks});
    while (ind < decompressed.len) {
        const blockId = try peek(u8, decompressed, ind);
        if (blockId == 0) {
            // expected trailing zeroes in decompressed data
            break;
        }
        var block: Block = undefined;
        parseBlock(&block, decompressed, &ind) catch |err| {
            std.log.err("Error when parsing block {}, id {X}, ind {}", .{numBlocks, blockId, ind});
            return err;
        };
        numBlocks += 1;
    }
}

const SortedSlot = struct
{
    k: u32,
    v: u32,
};

fn lessThan(context: u32, lhs: SortedSlot, rhs: SortedSlot) bool
{
    return lhs.v < rhs.v;
}

pub fn main() void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = &gpa.allocator;

    const args = std.process.argsAlloc(allocator) catch |err| {
        std.log.err("Error getting arguments: {}", .{err});
        return;
    };
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.log.err("Expected 1 argument, got {}", .{args.len - 1});
        return;
    }

    const replayFilePath = args[1];
    const cwd = std.fs.cwd();
    const replayFile = cwd.readFileAlloc(allocator, replayFilePath, std.math.maxInt(usize)) catch |err| {
        std.log.err("Error reading file \"{s}\": {}", .{replayFilePath, err});
        return;
    };
    defer allocator.free(replayFile);

    std.log.info("Reading replay file \"{s}\", {} bytes", .{replayFilePath, replayFile.len});

    const header = @ptrCast(*Header, replayFile);
    if (!verifyHeaderString(header.headerString)) {
        std.log.err("Invalid replay header", .{});
        return;
    }
    const blockOffset = @sizeOf(Header) + @sizeOf(SubHeader);
    comptime {
        if (blockOffset != 0x44) {
            @compileLog(blockOffset);
            unreachable;
        }
    }
    if (header.version != 1 or header.blockOffset != blockOffset) {
        std.log.err("Unsupported wc3 version", .{});
        return;
    }

    const subHeader = @ptrCast(*SubHeader, &replayFile[@sizeOf(Header)]);
    if (!verifySubHeaderString(subHeader.versionString)) {
        std.log.err("Invalid replay subheader version string", .{});
        return;
    }

    std.log.info("{}", .{header});
    std.log.info("{}", .{subHeader});

    const blockSize = 8192;
    var decompressed = allocator.alloc(u8, header.compressedBlocks * blockSize) catch |err| {
        std.log.err("Failed to allocate decompressed data memory", .{});
        return;
    };
    defer allocator.free(decompressed);

    var block: u32 = 0;
    var i: u32 = blockOffset;
    while (block < header.compressedBlocks) : (block += 1) {
        // TODO bounds checks
        const blockHeader = @ptrCast(*DataBlockHeader, &replayFile[i]);
        if (blockHeader.sizeDecompressed != blockSize) {
            std.log.err("Unexpected block decompressed size {}, expected {}",
                .{blockHeader.sizeDecompressed, blockSize}
            );
            return;
        }
        i += @sizeOf(DataBlockHeader);

        var zStream: zlib.z_stream = undefined;
        zStream.zalloc = null;
        zStream.zfree = null;
        //zStream.opaque = zlib.Z_NULL;
        const inflateInitError = zlib.inflateInit(&zStream);
        if (inflateInitError != zlib.Z_OK) {
            std.log.err("zlib inflateInit error: {}", .{inflateInitError});
            return;
        }

        zStream.next_in = &replayFile[i];
        zStream.avail_in = blockHeader.sizeCompressed;
        zStream.next_out = &decompressed[block * blockSize];
        zStream.avail_out = blockSize;
        const inflateResult = zlib.inflate(&zStream, zlib.Z_SYNC_FLUSH);
        if (inflateResult != zlib.Z_OK or zStream.avail_out != 0) {
            std.log.err("zlib inflate error: {}", .{inflateResult});
            return;
        }

        i += blockHeader.sizeCompressed;
    }

    if (i != replayFile.len) {
        if (i > replayFile.len) {
            std.log.err("Out of bounds, and we didn't realize! Bad!", .{});
            return;
        }
        else {
            std.log.err("{} extra bytes after compressed data", .{replayFile.len - i});
        }
    }

    cwd.writeFile("out.bin", decompressed) catch |err| {
        std.log.err("Failed to write file: {}", .{err});
        return;
    };

    idCountMap_ = IdCountMapType.init(allocator);
    defer idCountMap_.deinit();
    parseDecompressed(decompressed, allocator) catch |err| {
        std.log.err("Failed to parse decompressed replay data: {}", .{err});
        return;
    };

    var sorted = std.ArrayList(SortedSlot).init(allocator);
    defer sorted.deinit();
    var it = idCountMap_.iterator();
    while (it.next()) |kv| {
        var ptr = sorted.addOne() catch |err| {
            std.log.err("addOne failed", .{});
            return;
        };
        ptr.k = kv.key_ptr.*;
        ptr.v = kv.value_ptr.*;
        //try sorted.append(SortedSlot {.k = kv.key_ptr.*, .v = kv.value_ptr.*});
        //std.log.info("{s}={}", .{idToString(kv.key_ptr.*), kv.value_ptr.*});
    }

    const context: u32 = 0;
    std.sort.sort(SortedSlot, sorted.items, context, lessThan);
    for (sorted.items) |kv| {
        std.log.info("{s}={}", .{idToString(kv.k), kv.v});
    }
}

test
{
    var i: u32 = undefined;
    const testBuffer = [_]u8 {
        0x10, 0x01, 0x00, 0x00, 0x00, 0x03
    };

    i = 0;
    assert((try read(u32, &testBuffer, &i)) == 272);
    assert(i == 4);
    assert((try read(u8, &testBuffer, &i)) == 0);
    assert(i == 5);
    assert((try read(u8, &testBuffer, &i)) == 3);
    assert(i == 6);

    i = 0;
    assert((try read(u16, &testBuffer, &i)) == 272);
    assert(i == 2);
    assert((try read(u32, &testBuffer, &i)) == 50331648);
    assert(i == 6);

    i = 0;
    assert((try read(u8, &testBuffer, &i)) == 16);
    assert(i == 1);
    assert((try read(u8, &testBuffer, &i)) == 1);
    assert(i == 2);
    assert((try read(u16, &testBuffer, &i)) == 0);
    assert(i == 4);
    assert((try read(u16, &testBuffer, &i)) == 768);
    assert(i == 6);
}
