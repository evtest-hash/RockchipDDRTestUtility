import DDRCore
import XCTest

/// Variant (grade / package) decoding from the OTP dump.
///
/// Every rule here is transcribed from the vendor kernel, not inferred:
///   spec  0xd/0xa/0x13 = M/J/S            drivers/soc/rockchip/rockchip_opp_select.c:1341
///   RK3588 package 0x2 = RK3588S2         drivers/media/platform/rockchip/cif/hw.c:1712
///   RK3576 test_version gates the OPP bin drivers/cpufreq/rockchip-cpufreq.c:220
///   RK356x spec 0x1b = RK3566PRO          drivers/soc/rockchip/rockchip-cpuinfo.c:30
///   cpu_code = (byte2 << 8) | byte3       drivers/soc/rockchip/rockchip-cpuinfo.c:137
final class ChipVariantTests: XCTestCase {

    /// A dump starting at OTP byte 0, with the named bytes patched in.
    private func dump(_ patch: [Int: UInt8], baseByte: Int = 0, count: Int = 24) -> OtpDump {
        var bytes = [UInt8](repeating: 0, count: count)
        for (offset, value) in patch { bytes[offset - baseByte] = value }
        return OtpDump(baseByte: baseByte, bytes: bytes)
    }

    // MARK: - RK3588 family

    func testRK3588S2() {
        // spec 0x13 in byte6 bits[0:5], package 2 in byte6 bits[5:3] + byte5 bit0.
        let v = ChipVariant.resolve(family: .rk3588, dump: dump([0x05: 0x00, 0x06: 0x53]))
        XCTAssertEqual(v?.name, "RK3588S2")
        XCTAssertEqual(v?.spec, 0x13)
        XCTAssertEqual(v?.package, 0x2)
    }

    func testRK3588SWhenPackageIsNotTwo() {
        let v = ChipVariant.resolve(family: .rk3588, dump: dump([0x05: 0x00, 0x06: 0x13]))
        XCTAssertEqual(v?.name, "RK3588S")
        XCTAssertEqual(v?.package, 0x0)
    }

    func testRK3588PackageHighBitCounts() {
        // byte5 bit0 is package bit3: high=1, low=2 -> package 0xa, not 0x2.
        let v = ChipVariant.resolve(family: .rk3588, dump: dump([0x05: 0x01, 0x06: 0x53]))
        XCTAssertEqual(v?.package, 0xA)
        XCTAssertEqual(v?.name, "RK3588S")
    }

    func testRK3588GradedParts() {
        XCTAssertEqual(ChipVariant.resolve(family: .rk3588, dump: dump([0x06: 0x0D]))?.name, "RK3588M")
        XCTAssertEqual(ChipVariant.resolve(family: .rk3588, dump: dump([0x06: 0x0A]))?.name, "RK3588J")
        XCTAssertEqual(ChipVariant.resolve(family: .rk3588, dump: dump([0x06: 0x00]))?.name, "RK3588")
    }

    func testRK3588IgnoresPackageOutsideTheSSeries() {
        // package bits are only meaningful for spec 0x13 (cif/hw.c returns -EINVAL
        // otherwise), so a package of 2 must not turn an M part into an S2.
        let v = ChipVariant.resolve(family: .rk3588, dump: dump([0x06: 0x4D]))
        XCTAssertEqual(v?.name, "RK3588M")
        XCTAssertNil(v?.package)
    }

    func testRK3588ReadsCpuCodeWhenTheDumpReachesIt() {
        let v = ChipVariant.resolve(family: .rk3588, dump: dump([0x02: 0x35, 0x03: 0x88, 0x06: 0x13]))
        XCTAssertEqual(v?.cpuCode, 0x3588)
    }

    /// The cfg shipped before this change dumps from OTP byte 4, which already
    /// covers bytes 5 and 6 — so an un-rebuilt RK3588 cfg still names the variant,
    /// it just cannot report cpu_code.
    func testRK3588LegacyDumpStillNamesTheVariant() {
        let v = ChipVariant.resolve(family: .rk3588,
                                    dump: dump([0x05: 0x00, 0x06: 0x53], baseByte: 0x04, count: 20))
        XCTAssertEqual(v?.name, "RK3588S2")
        XCTAssertNil(v?.cpuCode)
    }

    func testRK3588WithoutTheSpecByteYieldsNothing() {
        XCTAssertNil(ChipVariant.resolve(family: .rk3588,
                                         dump: dump([:], baseByte: 0x0A, count: 16)))
    }

    // MARK: - RK3576

    func testRK3576SNeedsTestVersionZero() {
        let v = ChipVariant.resolve(family: .rk3576,
                                    dump: dump([0x07: 0x00, 0x08: 0x13], baseByte: 0x04, count: 24))
        XCTAssertEqual(v?.name, "RK3576S")
        XCTAssertEqual(v?.testVersion, 0)
    }

    func testRK3576SStillNamedOnATestVersionPart() {
        // spec 0x13 with test_version != 0 falls back to OPP bin 0 in the kernel, but
        // it is still an S part — see testRealRK3576SCapture, a board silkscreened
        // RK3576S that reads exactly this combination.
        let v = ChipVariant.resolve(family: .rk3576,
                                    dump: dump([0x07: 0x01, 0x08: 0x13], baseByte: 0x04, count: 24))
        XCTAssertEqual(v?.name, "RK3576S")
        XCTAssertEqual(v?.spec, 0x13)
        XCTAssertEqual(v?.testVersion, 1)
    }

    func testRK3576GradedParts() {
        let base = 0x04
        XCTAssertEqual(ChipVariant.resolve(family: .rk3576,
                                           dump: dump([0x08: 0x0D], baseByte: base))?.name, "RK3576M")
        XCTAssertEqual(ChipVariant.resolve(family: .rk3576,
                                           dump: dump([0x08: 0x0A], baseByte: base))?.name, "RK3576J")
        XCTAssertEqual(ChipVariant.resolve(family: .rk3576,
                                           dump: dump([0x08: 0x01], baseByte: base))?.name, "RK3576")
    }

    /// The RK3576 cfg shipped before this change dumps from byte 8: spec is there,
    /// test_version is not. The grade still resolves; only the revision marker is lost.
    func testRK3576LegacyDumpResolvesGradeWithoutTestVersion() {
        let v = ChipVariant.resolve(family: .rk3576, dump: dump([0x08: 0x13], baseByte: 0x08, count: 20))
        XCTAssertEqual(v?.name, "RK3576S")
        XCTAssertNil(v?.testVersion)
        XCTAssertEqual(ChipVariant.resolve(family: .rk3576,
                                           dump: dump([0x08: 0x0D], baseByte: 0x08, count: 20))?.name,
                       "RK3576M")
    }

    // MARK: - RK3566 / RK3567 / RK3568

    func testCpuCodeNamesTheRK356xPart() {
        XCTAssertEqual(ChipVariant.resolve(family: .rk356x,
                                           dump: dump([0x02: 0x35, 0x03: 0x66]))?.name, "RK3566")
        XCTAssertEqual(ChipVariant.resolve(family: .rk356x,
                                           dump: dump([0x02: 0x35, 0x03: 0x67]))?.name, "RK3567")
        XCTAssertEqual(ChipVariant.resolve(family: .rk356x,
                                           dump: dump([0x02: 0x35, 0x03: 0x68]))?.name, "RK3568")
    }

    func testRK3566Pro() {
        let v = ChipVariant.resolve(family: .rk356x,
                                    dump: dump([0x02: 0x35, 0x03: 0x66, 0x07: 0x1B]))
        XCTAssertEqual(v?.name, "RK3566PRO")
        XCTAssertEqual(v?.spec, 0x1B)
    }

    func testProSpecOnlyAppliesToRK3566() {
        let v = ChipVariant.resolve(family: .rk356x,
                                    dump: dump([0x02: 0x35, 0x03: 0x68, 0x07: 0x1B]))
        XCTAssertEqual(v?.name, "RK3568")
    }

    func testUnknownCpuCodeIsNotNamed() {
        let v = ChipVariant.resolve(family: .rk356x, dump: dump([0x02: 0x00, 0x03: 0x00]))
        XCTAssertNil(v?.name)
    }

    /// The RK356x cfg shipped before this change dumps from byte 0x0a — past both
    /// cpu_code and spec, so it can say nothing about the variant.
    func testRK356xLegacyDumpYieldsNothing() {
        XCTAssertNil(ChipVariant.resolve(family: .rk356x, dump: dump([:], baseByte: 0x0A, count: 16)))
    }

    // MARK: - real silicon

    /// Captured from a real RK3588S2 in maskrom (24 bytes from OTP byte 0):
    ///   52 4b 35 88 12 fe 53 4e 58 57 36 46 00 … 14 19 15 08
    /// The decisive byte is 5 = 0xfe: only bit0 belongs to package_serial_number.
    /// Masking it wrong (or reading the whole byte) turns this part into something
    /// else entirely, so this capture is the guard on the bit layout.
    func testRealRK3588S2Capture() throws {
        let bytes: [UInt8] = [0x52, 0x4b, 0x35, 0x88, 0x12, 0xfe, 0x53, 0x4e,
                              0x58, 0x57, 0x36, 0x46, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x14, 0x19, 0x15, 0x08]
        let dump = OtpDump(baseByte: 0, bytes: bytes)
        let v = try XCTUnwrap(ChipVariant.resolve(family: .rk3588, dump: dump))
        XCTAssertEqual(v.name, "RK3588S2")
        XCTAssertEqual(v.spec, 0x13)
        XCTAssertEqual(v.package, 0x2)
        XCTAssertEqual(v.cpuCode, 0x3588)
        // The same dump still yields the CPUID the board reports as its serial.
        let cpuid = try XCTUnwrap(dump.slice(at: 0x07, count: ChipIdentity.cpuidLength))
        XCTAssertEqual(ChipIdentity.hex(cpuid), "4e585736460000000000000000141915")
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "fa0a42f30e034ba5")
    }

    /// A plain RK3588 from the same batch reports spec 0x01 — a value the vendor
    /// kernel does not special-case, so it stays the base model rather than being
    /// forced into one of M/J/S.
    func testRealPlainRK3588Spec() {
        let v = ChipVariant.resolve(family: .rk3588,
                                    dump: OtpDump(baseByte: 0,
                                                  bytes: [0, 0, 0x35, 0x88, 0, 0, 0x01, 0]))
        XCTAssertEqual(v?.name, "RK3588")
        XCTAssertEqual(v?.spec, 0x01)
        XCTAssertNil(v?.package)
    }

    /// Captured from a real RK3568 in maskrom (28 bytes from OTP byte 0, SBPI
    /// controller). cpu_code is the point: this SoC's USB PID (0x350A) is shared by
    /// RK3566/RK3567/RK3568, so before the probe reached OTP byte 2 the tool could
    /// only ever say "RK3568&RK3566".
    func testRealRK3568Capture() throws {
        let bytes: [UInt8] = [0x52, 0x4b, 0x35, 0x68, 0x02, 0x00, 0xfe, 0x21,
                              0x10, 0x01, 0x54, 0x46, 0x37, 0x56, 0x30, 0x31,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04,
                              0x16, 0x1c, 0x18, 0x32]
        let dump = OtpDump(baseByte: 0, bytes: bytes)
        let v = try XCTUnwrap(ChipVariant.resolve(family: .rk356x, dump: dump))
        XCTAssertEqual(v.name, "RK3568")
        XCTAssertEqual(v.cpuCode, 0x3568)
        XCTAssertEqual(v.spec, 0x01)          // byte7 = 0x21, masked to 5 bits
        let cpuid = try XCTUnwrap(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
        XCTAssertEqual(ChipIdentity.hex(cpuid), "5446375630310000000000000004161c")
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "e84ccf1f10bc5aa4")
    }

    /// The other half of the pair: a real RK3566 captured on the same host, same
    /// USB PID (0x350A), same shipped cfg. Only cpu_code separates it from the
    /// RK3568 above — which is exactly the discrimination the PID cannot make.
    func testRealRK3566Capture() throws {
        let bytes: [UInt8] = [0x52, 0x4b, 0x35, 0x66, 0x02, 0x00, 0xfe, 0x21,
                              0x18, 0x01, 0x4d, 0x41, 0x54, 0x36, 0x35, 0x31,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14,
                              0x11, 0x0c, 0x2b, 0x48]
        let dump = OtpDump(baseByte: 0, bytes: bytes)
        let v = try XCTUnwrap(ChipVariant.resolve(family: .rk356x, dump: dump))
        XCTAssertEqual(v.name, "RK3566")      // NOT RK3566PRO: spec is 0x01, not 0x1b
        XCTAssertEqual(v.cpuCode, 0x3566)
        XCTAssertEqual(v.spec, 0x01)
        let cpuid = try XCTUnwrap(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
        XCTAssertEqual(ChipIdentity.hex(cpuid), "4d41543635310000000000000014110c")
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "cbe6c978c6ba1d6d")
    }

    /// Captured from a real RK3576S in maskrom (28 bytes from OTP byte 0). The board
    /// is silkscreened RK3576S and reads spec 0x13 with test_version 1 — which is why
    /// the kernel's test_version gate is treated as an OPP-bin rule here, not as
    /// grounds to withhold the S name.
    func testRealRK3576SCapture() throws {
        let bytes: [UInt8] = [0x52, 0x4b, 0x35, 0x76, 0x22, 0x00, 0xff, 0x01,
                              0x13, 0x01, 0x4e, 0x59, 0x35, 0x54, 0x43, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x15,
                              0x21, 0x20, 0x00, 0x00]
        let dump = OtpDump(baseByte: 0, bytes: bytes)
        let v = try XCTUnwrap(ChipVariant.resolve(family: .rk3576, dump: dump))
        XCTAssertEqual(v.name, "RK3576S")
        XCTAssertEqual(v.cpuCode, 0x3576)
        XCTAssertEqual(v.spec, 0x13)
        XCTAssertEqual(v.testVersion, 1)
        let cpuid = try XCTUnwrap(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
        XCTAssertEqual(ChipIdentity.hex(cpuid), "4e593554430000000000000000152120")
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "5158bd529128e395")
    }

    /// The control for the RK3576S case: a plain RK3576 read on the same host with
    /// the same cfg. spec 0x01 / test_version 0 against the S board's 0x13 / 1 — the
    /// pair is what establishes that spec, not test_version, carries the S marking.
    /// (This board is the one whose flashed serial 2aacddcd9cd362b3 is pinned in
    /// ChipIdentityTests, so the capture is independently anchored.)
    func testRealPlainRK3576Capture() throws {
        let bytes: [UInt8] = [0x52, 0x4b, 0x35, 0x76, 0x22, 0x00, 0xff, 0x00,
                              0x01, 0x01, 0x4e, 0x59, 0x36, 0x4b, 0x48, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c,
                              0x1e, 0x24, 0x00, 0x00]
        let dump = OtpDump(baseByte: 0, bytes: bytes)
        let v = try XCTUnwrap(ChipVariant.resolve(family: .rk3576, dump: dump))
        XCTAssertEqual(v.name, "RK3576")
        XCTAssertEqual(v.cpuCode, 0x3576)
        XCTAssertEqual(v.spec, 0x01)
        XCTAssertEqual(v.testVersion, 0)
        let cpuid = try XCTUnwrap(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "2aacddcd9cd362b3")
    }

}
