import XCTest
@testable import DDRCore

final class DetectCfgTests: XCTestCase {

    /// Every payload the detect flow needs. The detect cfg is a self-contained
    /// PACKAGING container: DdrDetector pulls each one out of `embeddedBins` and
    /// drives the sequence itself (it never runs the cfg through
    /// TestExecutionEngine), so embedding reboot here is safe — the detector runs
    /// it explicitly, after the OS_REG capture.
    private static let payloadNames = ["Boot", "ddrbin", "osregdump", "otpdump", "reboot"]

    /// Every shipped detect cfg, with the item download base build.sh packed into
    /// it. RK3288's "otpdump" reads the eFuse rather than an OTP controller (that
    /// SoC has no OTP block), but it is packaged and named exactly like the others
    /// so the host side needs no special case — which is what lets it sit in this
    /// table instead of in a test of its own.
    private static let detectCfgs: [(soc: String, downloadBase: UInt32)] = [
        ("RK3568&RK3566", 0xFDCC_4000),
        ("RK3588", 0xFF00_4000),
        ("RK3576", 0x3FF8_4000),
        ("RK3288", 0xFFFF_1500),
    ]

    private func parseDetectCfg(_ soc: String) throws -> CfgTestPlan {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/\(soc)/DDR自动探测.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        return try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
    }

    private func payload(_ name: String, in plan: CfgTestPlan) -> Data? {
        plan.embeddedBins.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Each SoC's cfg must carry exactly the five payloads, under those names, at
    /// that SoC's download base — and each must round-trip out non-empty (Boot raw,
    /// the rest RC4-decrypted by the parser).
    func testEveryDetectCfgPackagesAllPayloads() throws {
        for (soc, downloadBase) in Self.detectCfgs {
            let plan = try parseDetectCfg(soc)
            XCTAssertEqual(plan.downloadBaseAddress, downloadBase, "\(soc): download base")
            let names = plan.items.map { $0.name.lowercased() }
            XCTAssertEqual(names.count, Self.payloadNames.count, "\(soc): item count")
            for name in Self.payloadNames {
                XCTAssertTrue(names.contains(name.lowercased()), "\(soc): no item named \(name)")
                let bin = payload(name, in: plan)
                XCTAssertNotNil(bin, "\(soc): missing payload \(name)")
                XCTAssertGreaterThan(bin?.count ?? 0, 0, "\(soc): empty payload \(name)")
            }
        }
    }

    /// The rkbin DDR bin is the bulk of every detect cfg. A truncated one would
    /// still satisfy the non-empty check above while failing to init DDR at all.
    func testDetectCfgCarriesAFullSizeDdrBin() throws {
        for (soc, _) in Self.detectCfgs {
            let plan = try parseDetectCfg(soc)
            XCTAssertGreaterThan(payload("ddrbin", in: plan)?.count ?? 0, 10_000, "\(soc): ddrbin too small")
        }
    }

    /// The shipped otpdump payloads must speak the SELF-DESCRIBING framing: the
    /// probe prints OTP_DUMP + the OTP byte offset its dump starts at, and the app
    /// reads the dump at THAT offset. A cfg rebuilt without the marker would fall
    /// back to `IdProbe.legacyBaseByte`, silently misplacing every OTP field —
    /// including the CPUID, which would still look like a valid serial. RK3288 is
    /// the case where that fallback does not exist at all (`legacyBaseByte` nil),
    /// so losing the marker there means no identity rather than a wrong one.
    func testShippedOtpProbesAnnounceTheirDumpBase() throws {
        for (soc, _) in Self.detectCfgs {
            let plan = try parseDetectCfg(soc)
            let bin = try XCTUnwrap(payload("otpdump", in: plan), "\(soc): no otpdump payload")
            // The marker is a literal in the payload's string table.
            XCTAssertNotNil(bin.range(of: Data("OTP_DUMP".utf8)),
                            "\(soc): otpdump payload predates the self-describing framing")
        }
    }

    /// Each SoC's probe must dump far enough to cover the CPUID its profile reads.
    /// This is the arithmetic that a moved read-window gets wrong.
    func testProfileCpuidOffsetsMatchTheDocumentedOtpLayout() {
        XCTAssertEqual(DetectProfiles.all[0x350B]?.idProbe?.cpuidOffset, 0x07)   // RK3588: rockchip-common.h default
        XCTAssertEqual(DetectProfiles.all[0x350E]?.idProbe?.cpuidOffset, 0x0A)   // RK3576: rk3576_common.h
        XCTAssertEqual(DetectProfiles.all[0x350A]?.idProbe?.cpuidOffset, 0x0A)   // RK356x
        XCTAssertEqual(DetectProfiles.all[0x320A]?.idProbe?.cpuidOffset, 0x07)   // RK3288: eFuse cpu_id@0x07
        XCTAssertEqual(DetectProfiles.all[0x350B]?.family, .rk3588)
        XCTAssertEqual(DetectProfiles.all[0x350E]?.family, .rk3576)
        XCTAssertEqual(DetectProfiles.all[0x350A]?.family, .rk356x)
        XCTAssertNil(DetectProfiles.all[0x320A]?.family)                         // RK3288W not decoded
    }

}
