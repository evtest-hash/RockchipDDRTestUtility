import XCTest
@testable import DDRCore

final class DdrGeometryTests: XCTestCase {

    // Hand-encoded per the SYS_REG **V3** macros for: LPDDR4X (type 8, which
    // exercises the 5-bit split — low 3 bits in reg2[15:13]=0, high 2 bits in
    // reg3[13:12]=1), 1 channel, 1 rank, col=10, 8 banks, cs0_row=16, 16-bit bus,
    // 16-bit die. Decodes to a 1024 MB part.
    //   reg2 = (1<<9)|(3<<6)|(1<<2)|(1<<0) = 0x2C5   (type-low bits = 0)
    //   reg3 = (3<<28) | (1<<12) = 0x30001000        (version 3, type-high = 1)
    func testDecodeV3TypeSplitLPDDR4X() {
        let words: [UInt32] = [0, 0, 0x0000_02C5, 0x3000_1000]
        let g = OsRegDecoder.decode(words)
        XCTAssertEqual(g.dramType, .lpddr4x)   // 0 | (1<<3) = 8
        XCTAssertEqual(g.sysRegVersion, 3)
        XCTAssertEqual(g.numChannels, 1)
        XCTAssertEqual(g.channels.count, 1)
        let c = g.channels[0]
        XCTAssertEqual(c.rank, 1)
        XCTAssertEqual(c.col, 10)
        XCTAssertEqual(c.bank, 3)
        XCTAssertEqual(c.cs0Row, 16)
        XCTAssertEqual(c.busWidthBits, 16)
        XCTAssertEqual(c.dieWidthBits, 16)
        XCTAssertEqual(g.totalSizeMB, 1024)
    }

    // DDR4 must decode to the authoritative code 0 (NOT 4).
    func testDDR4TypeCodeIsZero() {
        XCTAssertEqual(DramType(rawValue: 0), .ddr4)
        // reg2/reg3 type bits all zero → type 0 → DDR4.
        let g = OsRegDecoder.decode([0, 0, 0x0000_02C5, 0x3000_0000])
        XCTAssertEqual(g.dramType, .ddr4)
    }

    func testParseProbeOutput() {
        let text = """
        [INFO] INFO_PRINTF banner junk
        OSREG_BEGIN
        00000000
        00000001
        000082C5
        deadbeef
        OSREG_END
        trailing noise
        """
        let words = OsRegDecoder.parseProbeOutput(text)
        XCTAssertEqual(words, [0x0, 0x1, 0x82C5, 0xDEADBEEF])
    }

    func testParseProbeOutputMissingMarkers() {
        XCTAssertNil(OsRegDecoder.parseProbeOutput("no markers here 12345"))
    }

    func testFilenameParsing() {
        XCTAssertEqual(CfgAutoSelect.dramType(fromFilename: "8GB LPDDR4X(...)焊接检测.cfg"), .lpddr4x)
        XCTAssertEqual(CfgAutoSelect.dramType(fromFilename: "2GB DDR4(...).cfg"), .ddr4)
        XCTAssertEqual(CfgAutoSelect.dramType(fromFilename: "1GB LPDDR4(...).cfg"), .lpddr4)
        XCTAssertEqual(CfgAutoSelect.sizeMB(fromFilename: "8GB LPDDR4X(...).cfg"), 8192)
        XCTAssertEqual(CfgAutoSelect.sizeMB(fromFilename: "1.5GB LPDDR3(...).cfg"), 1536)
        XCTAssertEqual(CfgAutoSelect.sizeMB(fromFilename: "512MB DDR3(...).cfg"), 512)
    }

    // The self-contained detect cfg must parse cleanly with the shipping parser:
    // it packages ALL four payloads (Boot + ddrbin + osregdump + reboot), which
    // DdrDetector pulls from embeddedBins and drives itself. Download base
    // 0xFDCC4000; the osregdump payload RC4-round-trips to the ARM64 entry
    // (STP X29,X30 = 0xa9be7bfd little-endian: fd 7b .. a9).
    func testDetectCfgParses() throws {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/RK3568&RK3566/DDR自动探测.cfg"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("detect cfg not present at \(path)")
        }
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0xFDCC_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertTrue(names.contains("boot"))
        XCTAssertTrue(names.contains("ddrbin"))
        XCTAssertTrue(names.contains("osregdump"))
        XCTAssertTrue(names.contains("reboot"))
        // ddrbin (the auto-probing rkbin DDR bin) round-trips to real bytes.
        let ddrbin = try XCTUnwrap(plan.embeddedBins["ddrbin"])
        XCTAssertGreaterThan(ddrbin.count, 10_000)
        // reboot payload is present and non-empty.
        XCTAssertGreaterThan(try XCTUnwrap(plan.embeddedBins["reboot"]).count, 0)
        let probe = try XCTUnwrap(plan.embeddedBins["osregdump"])
        XCTAssertGreaterThan(probe.count, 0)
        // Entry is an AArch64 STP X29,X30,[SP,#-N]! prologue: bytes fd 7b .. a9
        // (frame size N varies as probe.S evolves, so match the stable opcode).
        XCTAssertEqual(probe[0], 0xfd)
        XCTAssertEqual(probe[1], 0x7b)
        XCTAssertEqual(probe[3], 0xa9)
    }
}

extension DdrGeometryTests {
    // Real OS_REG captured from the board (RK3568, v1.25 DDR bin):
    //   OS_REG2=0x1000EAF1, OS_REG3=0x30000001.
    // Locks the authoritative SYS_REG V3 decode: LPDDR4 (type 7, reg3 high bits 0),
    // 4 GB, dual-CS, 32-bit bus, x16 die, col=10, 8 banks, 16 row bits.
    func testDecodeRealCapture() {
        let words: [UInt32] = [0,0,0x1000EAF1,0x30000001,0,0,0,0,0x34B02204,0x8210A088,0x49068440,0x0040285A]
        let g = OsRegDecoder.decode(words)
        print(">>> REAL DECODE: version=\(g.sysRegVersion) \(g.summary())")
        XCTAssertEqual(g.sysRegVersion, 3)
        XCTAssertEqual(g.totalSizeMB, 4096)
        XCTAssertEqual(g.numChannels, 1)
        XCTAssertEqual(g.csPerDie, 2)
        XCTAssertEqual(g.channels.first?.busWidthBits, 32)
        XCTAssertEqual(g.channels.first?.dieWidthBits, 16)
        XCTAssertEqual(g.channels.first?.col, 10)
        XCTAssertEqual(g.channels.first?.cs0Row, 16)
        // Authoritative SYS_REG V3 decode: DDRTYPE = reg2[15:13]=7 | reg3[13:12]=0
        // → LPDDR4 (7). (The DDR bin did not set the LP4X high type bits here; if
        // the physical part is LP4X, SYS_REG readback still reports LPDDR4 — the
        // two aren't separable from OS_REG, which is why CfgAutoSelect families them.)
        XCTAssertEqual(g.dramType, .lpddr4)
    }

    // End-to-end against the real RK3568 folder: the LPDDR4 4GB/2-CS decode must
    // return ONLY exact matches. Per sdram.h, LPDDR4 (7) and LPDDR4X (8) are
    // distinct types, so a type-7 detection matches the LPDDR4 cfg and NOT the
    // same-size/CS LPDDR4X cfg.
    func testRealCaptureRanksAgainstRK3568Folder() throws {
        let root = FileManager.default.currentDirectoryPath + "/DDRTestFiles"
        guard FileManager.default.fileExists(atPath: root) else { throw XCTSkip("no DDRTestFiles") }
        let files = try CfgRepository(rootURL: URL(fileURLWithPath: root)).discoverTestFiles()
        let soc = files.filter { $0.socName == "RK3568&RK3566" }
        try XCTSkipIf(soc.isEmpty, "no RK3568 cfgs")
        let g = OsRegDecoder.decode([0,0,0x1000EAF1,0x30000001,0,0,0,0,0,0,0,0])
        XCTAssertEqual(g.dramType, .lpddr4)
        let cands = CfgAutoSelect.rank(geometry: g, socFiles: soc)
        print(">>> EXACT MATCHES:")
        for c in cands { print("   \(c.entry.displayName)") }
        XCTAssertFalse(cands.isEmpty)
        // every returned candidate is an EXACT (type + capacity + CS) match —
        // LPDDR4 only, the same-size LPDDR4X cfg is excluded.
        for c in cands {
            XCTAssertEqual(c.sizeMB, 4096)
            XCTAssertEqual(c.csCount, 2)
            XCTAssertEqual(c.dramType, .lpddr4)
        }
        XCTAssertTrue(cands.first!.entry.displayName.contains("4GB"))
    }

    // Real OS_REG captured from an RK3588 board (rk3588 v1.21 DDR bin):
    //   OS_REG2=0x3AF51AF5 OS_REG3=0x30001005  (group 0: ch0/1)
    //   OS_REG4=0x3AF51AF5 OS_REG5=0x30001005  (group 1: ch2/3, identical)
    // RK3588's 64-bit bus = 4×16-bit channels across TWO SYS_REG groups, so the
    // capacity is the SUM of both: 4 channels, dual-CS, 16-bit each → 8192 MB.
    // Type high bit reg3[13:12]=1 → LPDDR4X (the RK3588 bin does set it).
    func testDecodeRK3588FourChannelCapture() {
        let words: [UInt32] = [0, 0, 0x3AF51AF5, 0x30001005, 0x3AF51AF5, 0x30001005, 0, 0, 0, 0, 0, 0]
        let g = OsRegDecoder.decode(words)
        print(">>> RK3588 DECODE: version=\(g.sysRegVersion) \(g.summary())")
        XCTAssertEqual(g.sysRegVersion, 3)
        XCTAssertEqual(g.dramType, .lpddr4x)
        XCTAssertEqual(g.numChannels, 4)      // 2 groups × 2 channels
        XCTAssertEqual(g.csPerDie, 2)         // per-die/per-channel rank (NOT the 8 total)
        XCTAssertEqual(g.totalSizeMB, 8192)   // 2 × the single-group 4096 MB
        XCTAssertEqual(g.channels.first?.busWidthBits, 16)
    }

    // The second SYS_REG group is counted ONLY when populated: RK356x zeros
    // os_reg4/5, so its single-group result is unchanged by the multi-group loop.
    func testSingleGroupUnaffectedWhenSecondGroupZero() {
        let g = OsRegDecoder.decode([0, 0, 0x1000EAF1, 0x30000001, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(g.numChannels, 1)
        XCTAssertEqual(g.totalSizeMB, 4096)   // matches testDecodeRealCapture (RK3568)
    }

    // Real OS_REG captured from an RK3576 board (rk3576 v1.12 LPDDR5 bin):
    //   OS_REG2=0x3BF53BF5 OS_REG3=0x30001005 (single group; os_reg4/5=0).
    // The DDR bin printed "Bk=16 … Size=4096MB/channel" (2 channels → 8 GB). The
    // SYS_REG BK field decodes to 2 (4 banks), but LPDDR5 has 16 banks, so the
    // decoder must correct bank→4 by type — else it under-counts 4× (2 GB).
    func testDecodeRK3576LPDDR5BankCorrection() {
        let words: [UInt32] = [0, 0, 0x3BF53BF5, 0x30001005, 0, 0, 1, 0, 0, 0, 0, 0]
        let g = OsRegDecoder.decode(words)
        print(">>> RK3576 DECODE: version=\(g.sysRegVersion) \(g.summary())")
        XCTAssertEqual(g.dramType, .lpddr5)
        XCTAssertEqual(g.numChannels, 2)
        XCTAssertEqual(g.csPerDie, 2)
        XCTAssertEqual(g.channels.first?.bank, 4)     // LPDDR5 16 banks (not the raw 2)
        XCTAssertEqual(g.totalSizeMB, 8192)           // 2ch × 2CS × 2GB — matches the bin's print
    }

    // Real OS_REG captured from an RK3288 board (rk3288 v1.12 DDR bin, arm32):
    //   OS_REG2 = 0x32817281, OS_REG3 = 0 (single-register SYS_REG **V1**).
    // Both 16-bit lanes decode identically: DDR3 (type 3), 32-bit bus, x16 die,
    // col=10, 8 banks, cs0_row=15, rank 1. NUM_CH=2 → 2 × 1024 MB = 2048 MB.
    // Matches the DDR bin's own UART print ("通道a: DDR3 400MHz Bus Width=32
    // Col=10 …"). os_reg3 is untouched so the version nibble reads 0 → V1 path,
    // NOT the V3 decoder (which would spuriously read reg3 high bits).
    func testDecodeRK3288V1Capture() {
        let words: [UInt32] = [0, 0, 0x3281_7281, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let g = OsRegDecoder.decode(words)
        print(">>> RK3288 V1 DECODE: version=\(g.sysRegVersion) \(g.summary())")
        XCTAssertEqual(g.sysRegVersion, 0)           // V1: no version nibble
        XCTAssertEqual(g.dramType, .ddr3)
        XCTAssertEqual(g.numChannels, 2)
        XCTAssertEqual(g.csPerDie, 1)
        XCTAssertEqual(g.totalSizeMB, 2048)          // 2ch × 1GB
        let c = g.channels[0]
        XCTAssertEqual(c.rank, 1)
        XCTAssertEqual(c.col, 10)
        XCTAssertEqual(c.bank, 3)                    // 8 banks
        XCTAssertEqual(c.cs0Row, 15)
        XCTAssertEqual(c.busWidthBits, 32)
        XCTAssertEqual(c.dieWidthBits, 16)
    }

    // A single-channel dual-rank V1 part, hand-encoded: DDR3, NUM_CH=1 (bit12=0),
    // rank=2 (bit11), col=10, 8 banks, cs0_row=15, cs1_row=14 (reg2[5:4]=1),
    // 32-bit bus, x16 die. CS1 reuses CS0's column count (V1 has no separate CS1
    // column field), so the channel is 1024 (CS0) + 512 (CS1) = 1536 MB.
    //   lane = (3<<13)|(1<<11)|(1<<9)|(2<<6)|(1<<4)|(1<<0) = 0x6A91
    func testDecodeV1DualRank() {
        let g = OsRegDecoder.decode([0, 0, 0x0000_6A91, 0])
        XCTAssertEqual(g.dramType, .ddr3)
        XCTAssertEqual(g.numChannels, 1)             // reg2[12]=0
        XCTAssertEqual(g.csPerDie, 2)
        let c = g.channels[0]
        XCTAssertEqual(c.rank, 2)
        XCTAssertEqual(c.cs0Row, 15)
        XCTAssertEqual(c.cs1Row, 14)
        XCTAssertEqual(g.totalSizeMB, 1536)          // 1024 (CS0) + 512 (CS1)
    }

    // End-to-end against the real RK3288 folder: the DDR3 2048MB 1-CS/channel
    // decode (os_reg2=0x32817281) must select the symmetric "2GB DDR3(通道a用1个CS
    // …通道b用1个CS…)" cfg. RK3288 cfgs name CS per channel ("通道a用N个CS"); the
    // csCount parser picks the first "N个CS" and csPerDie is the max channel rank,
    // which agree for this symmetric part (both channels rank 1).
    func testRK3288CaptureRanksAgainstFolder() throws {
        let root = FileManager.default.currentDirectoryPath + "/DDRTestFiles"
        guard FileManager.default.fileExists(atPath: root) else { throw XCTSkip("no DDRTestFiles") }
        let soc = try CfgRepository(rootURL: URL(fileURLWithPath: root)).discoverTestFiles()
            .filter { $0.socName == "RK3288" }
        try XCTSkipIf(soc.isEmpty, "no RK3288 cfgs")
        let g = OsRegDecoder.decode([0, 0, 0x3281_7281, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(g.dramType, .ddr3)
        XCTAssertEqual(g.totalSizeMB, 2048)
        XCTAssertEqual(g.csPerDie, 1)
        let cands = CfgAutoSelect.rank(geometry: g, socFiles: soc)
        print(">>> RK3288 EXACT MATCHES:")
        for c in cands { print("   \(c.entry.displayName)") }
        XCTAssertFalse(cands.isEmpty)
        for c in cands {
            XCTAssertEqual(c.sizeMB, 2048)
            XCTAssertEqual(c.csCount, 1)
            XCTAssertEqual(c.dramType, .ddr3)
        }
        // The symmetric 2GB/1-CS DDR3 cfg is among the matches.
        XCTAssertTrue(cands.contains { $0.entry.displayName.contains("2GB DDR3(通道a用1个CS") })
    }

    // A garbage geometry (all-zero SYS_REG, as a FAILED DDR init produces) must
    // match NOTHING: detection fails rather than offering a wrong cfg. The version
    // nibble is 0 → V1 path, which decodes all-zero to a bogus DDR4 128MB 1CS
    // (type 0, col 9, 8 banks, row 13, 32-bit; no DDR4 bank-group term in V1).
    func testGarbageGeometryMatchesNothing() throws {
        let root = FileManager.default.currentDirectoryPath + "/DDRTestFiles"
        guard FileManager.default.fileExists(atPath: root) else { throw XCTSkip("no DDRTestFiles") }
        let soc = try CfgRepository(rootURL: URL(fileURLWithPath: root)).discoverTestFiles()
            .filter { $0.socName == "RK3568&RK3566" }
        try XCTSkipIf(soc.isEmpty, "no RK3568 cfgs")
        let g = OsRegDecoder.decode([0, 0, 0, 0])   // all-zero → bogus DDR4 128MB 1CS
        XCTAssertEqual(g.totalSizeMB, 128)          // no RK3568 cfg is 128 MB
        XCTAssertTrue(CfgAutoSelect.rank(geometry: g, socFiles: soc).isEmpty)
    }
}
