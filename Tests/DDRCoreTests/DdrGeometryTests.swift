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

    // The built detect cfg must parse cleanly with the shipping parser: Boot +
    // one osregdump item, download base 0xFDCC4000, probe payload RC4-round-trips
    // to the ARM64 entry (STP X29,X30 = 0xa9be7bfd little-endian: fd 7b be a9).
    func testDetectCfgParses() throws {
        let path = FileManager.default.currentDirectoryPath + "/tools/ddr-autodetect/rk3568_osregdump.cfg"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("detect cfg not present at \(path)")
        }
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0xFDCC_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertTrue(names.contains("boot"))
        XCTAssertTrue(names.contains("osregdump"))
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
    // Locks the decode: SYS_REG v3, LPDDR4-family, 4 GB, dual-CS, 32-bit bus,
    // x16 die, col=10, 8 banks, 16 row bits. (LPDDR4X via the SYS_REG3 bit0
    // hypothesis — see decode().)
    func testDecodeRealCapture() {
        let words: [UInt32] = [0,0,0x1000EAF1,0x30000001,0,0,0,0,0x34B02204,0x8210A088,0x49068440,0x0040285A]
        let g = OsRegDecoder.decode(words)
        print(">>> REAL DECODE: version=\(g.sysRegVersion) \(g.summary())")
        XCTAssertEqual(g.sysRegVersion, 3)
        XCTAssertEqual(g.totalSizeMB, 4096)
        XCTAssertEqual(g.numChannels, 1)
        XCTAssertEqual(g.totalCS, 2)
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

    // End-to-end: the real decode must shortlist the 4GB / 2-CS / LPDDR4-family
    // soldering cfg at the top when run against the real RK3568 folder.
    func testRealCaptureRanksAgainstRK3568Folder() throws {
        let root = FileManager.default.currentDirectoryPath + "/DDRTestFiles"
        guard FileManager.default.fileExists(atPath: root) else { throw XCTSkip("no DDRTestFiles") }
        let files = try CfgRepository(rootURL: URL(fileURLWithPath: root)).discoverTestFiles()
        let soc = files.filter { $0.socName == "RK3568&RK3566" }
        try XCTSkipIf(soc.isEmpty, "no RK3568 cfgs")
        let g = OsRegDecoder.decode([0,0,0x1000EAF1,0x30000001,0,0,0,0,0,0,0,0])
        let cands = CfgAutoSelect.rank(geometry: g, socFiles: soc)
        print(">>> TOP CANDIDATES:")
        for c in cands.prefix(4) { print("   [\(c.score)] \(c.entry.displayName)") }
        let top = try XCTUnwrap(cands.first)
        XCTAssertTrue(top.entry.displayName.contains("4GB"))
        XCTAssertEqual(top.csCount, 2)
        XCTAssertTrue(top.dramType == .lpddr4 || top.dramType == .lpddr4x)
    }
}
