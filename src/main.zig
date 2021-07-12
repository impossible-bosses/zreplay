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

    std.log.info("{} | {} | {} | {} | {}", .{
        header.blockOffset,
        header.sizeCompressed,
        header.version,
        header.sizeDecompressed,
        header.compressedBlocks
    });
    std.log.info("{s} | {} | {} | {} | {} | {}", .{
        subHeader.versionString,
        subHeader.versionNumber,
        subHeader.buildNumber,
        subHeader.flags,
        subHeader.replayLengthMs,
        subHeader.checksum,
    });

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
        if (inflateResult != zlib.Z_OK) {
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
}
