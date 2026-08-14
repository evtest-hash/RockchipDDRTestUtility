// Sources/DDRCore/ChipVariant.swift
import Foundation

/// Which set of variant rules a SoC follows. Not the same thing as the marketing
/// name: RK3566/RK3567/RK3568 share one rule set (and one USB PID), and the name
/// is an OUTPUT of applying it.
public enum ChipFamily: String, Sendable, CaseIterable {
    case rk3588
    case rk3576
    case rk356x
}

/// A chip's variant within its model family, decoded from OTP.
///
/// `specification_serial_number` is a GRADE marker (M/J/S/PRO), not the model
/// class — the model class comes from `cpu_code`, and packaging differences
/// (RK3588S vs RK3588S2) need `package_serial_number` on top. `name` is nil when
/// the captured fields don't justify a conclusion; the raw fields are still
/// reported so an operator can see what was read.
///
/// Rules transcribed from the vendor kernel (linux-6.1 rkr7):
///   drivers/soc/rockchip/rockchip_opp_select.c:1341   spec 0xd/0xa/0x13 = M/J/S
///   drivers/media/platform/rockchip/cif/hw.c:1712     RK3588 package 0x2 = S2
///   drivers/cpufreq/rockchip-cpufreq.c:220            RK3576 test_version gates the OPP bin
///   drivers/soc/rockchip/rockchip-cpuinfo.c:30        RK356x spec 0x1b = RK3566PRO
///   drivers/soc/rockchip/rockchip-cpuinfo.c:137       cpu_code = (b2 << 8) | b3
public struct ChipVariant: Sendable, Equatable {
    /// Resolved marketing name, e.g. "RK3588S2". Nil when the evidence is
    /// insufficient — never a guess.
    public let name: String?
    /// OTP 0x02, 2 bytes, big-endian: the model class (0x3588, 0x3566, …).
    public let cpuCode: UInt16?
    /// specification_serial_number: the grade marker.
    public let spec: UInt8?
    /// package_serial_number, only meaningful for RK3588 S-series parts.
    public let package: UInt8?
    /// RK3576 only: non-zero marks a test/pilot revision. It does NOT change the
    /// model name — it means the S-grade OPP table must not be applied.
    public let testVersion: UInt8?

    public init(name: String?, cpuCode: UInt16? = nil, spec: UInt8? = nil,
                package: UInt8? = nil, testVersion: UInt8? = nil) {
        self.name = name
        self.cpuCode = cpuCode
        self.spec = spec
        self.package = package
        self.testVersion = testVersion
    }

    // MARK: - OTP offsets (absolute, as the vendor dtsi defines them)

    private enum Offset {
        static let cpuCode = 0x02          // 2 bytes, both families that expose it
        static let rk3588PackageHigh = 0x05
        static let rk3588Spec = 0x06       // package low lives in bits[5:3] of the same byte
        static let rk3576TestVersion = 0x07
        static let rk3576Spec = 0x08
        static let rk356xSpec = 0x07
    }

    private enum Grade {
        static let m: UInt8 = 0x0D
        static let j: UInt8 = 0x0A
        static let s: UInt8 = 0x13
        static let pro: UInt8 = 0x1B       // RK3566 only
    }

    /// Decode from an OTP dump. Returns nil when the dump doesn't reach any
    /// field this family needs.
    public static func resolve(family: ChipFamily, dump: OtpDump) -> ChipVariant? {
        switch family {
        case .rk3588: return resolveRK3588(dump)
        case .rk3576: return resolveRK3576(dump)
        case .rk356x: return resolveRK356x(dump)
        }
    }

    // MARK: - per-family rules

    private static func resolveRK3588(_ dump: OtpDump) -> ChipVariant? {
        guard let specByte = dump.byte(at: Offset.rk3588Spec) else { return nil }
        let spec = specByte & 0x1F
        let cpuCode = cpuCode(from: dump)

        switch spec {
        case Grade.s:
            // S-series only: cif/hw.c refuses to read a package number for anything else.
            guard let high = dump.byte(at: Offset.rk3588PackageHigh) else {
                return ChipVariant(name: nil, cpuCode: cpuCode, spec: spec)
            }
            let package = ((high & 0x1) << 3) | ((specByte >> 5) & 0x7)
            return ChipVariant(name: package == 0x2 ? "RK3588S2" : "RK3588S",
                               cpuCode: cpuCode, spec: spec, package: package)
        case Grade.m:
            return ChipVariant(name: "RK3588M", cpuCode: cpuCode, spec: spec)
        case Grade.j:
            return ChipVariant(name: "RK3588J", cpuCode: cpuCode, spec: spec)
        default:
            return ChipVariant(name: "RK3588", cpuCode: cpuCode, spec: spec)
        }
    }

    private static func resolveRK3576(_ dump: OtpDump) -> ChipVariant? {
        guard let specByte = dump.byte(at: Offset.rk3576Spec) else { return nil }
        let spec = specByte & 0x1F
        let testVersion = dump.byte(at: Offset.rk3576TestVersion).map { $0 & 0x0F }
        let cpuCode = cpuCode(from: dump)

        let name: String?
        switch spec {
        case Grade.m: name = "RK3576M"
        case Grade.j: name = "RK3576J"
        case Grade.s:
            // The kernel's test_version gate (rk3576_cpu_get_soc_info / its GPU twin)
            // is an OPP-BIN rule, not a naming one: a test_version != 0 part must not
            // use the S frequency table. It is still an S part — hardware settles it,
            // a board silkscreened RK3576S reads spec 0x13 with test_version 1.
            name = "RK3576S"
        default: name = "RK3576"
        }
        return ChipVariant(name: name, cpuCode: cpuCode, spec: spec, testVersion: testVersion)
    }

    private static func resolveRK356x(_ dump: OtpDump) -> ChipVariant? {
        guard let cpuCode = cpuCode(from: dump) else {
            // cpu_code is what separates RK3566/3567/3568; the PID cannot.
            return dump.byte(at: Offset.rk356xSpec) == nil
                ? nil
                : ChipVariant(name: nil, spec: dump.byte(at: Offset.rk356xSpec)! & 0x1F)
        }
        let spec = dump.byte(at: Offset.rk356xSpec).map { $0 & 0x1F }

        let name: String?
        switch cpuCode {
        case 0x3566: name = spec == Grade.pro ? "RK3566PRO" : "RK3566"
        case 0x3567: name = "RK3567"
        case 0x3568: name = "RK3568"
        default: name = nil
        }
        return ChipVariant(name: name, cpuCode: cpuCode, spec: spec)
    }

    /// OTP 0x02..0x03, big-endian (`rockchip_set_cpu`). Zero means unprogrammed,
    /// which is not a model class.
    private static func cpuCode(from dump: OtpDump) -> UInt16? {
        guard let bytes = dump.slice(at: Offset.cpuCode, count: 2) else { return nil }
        let code = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return code == 0 ? nil : code
    }
}
