import Foundation

public enum DDRToolError: Error, LocalizedError, Sendable {
    case fileNotFound(String)
    case invalidFormat(String)
    case parseFailure(String)
    case noDevice
    case multipleDevices(Int)
    case transportError(String)
    case runtimeError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let message):
            return message
        case .invalidFormat(let message):
            return message
        case .parseFailure(let message):
            return message
        case .noDevice:
            return "No device found"
        case .multipleDevices(let count):
            return "Found \(count) devices"
        case .transportError(let message):
            return message
        case .runtimeError(let message):
            return message
        }
    }
}



public struct TestFileEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let absolutePath: String
    public let relativePath: String
    public let socName: String
    public let displayName: String

    public init(absolutePath: String, relativePath: String, socName: String, displayName: String) {
        self.id = absolutePath
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.socName = socName
        self.displayName = displayName
    }
}

public enum CfgParamInputType: String, Sendable {
    case combo = "COMBO"
    case edit = "EDIT"
    case unknown
}

public struct CfgParameter: Hashable, Sendable {
    public let index: Int
    public let section: String
    public let name: String
    public let inputType: CfgParamInputType
    public let value: String
    public let unit: String
    public let inputRange: String?
    public let inputRangeName: String?
    public let inputRangeValue: String?

    public init(
        index: Int,
        section: String,
        name: String,
        inputType: CfgParamInputType,
        value: String,
        unit: String,
        inputRange: String?,
        inputRangeName: String?,
        inputRangeValue: String?
    ) {
        self.index = index
        self.section = section
        self.name = name
        self.inputType = inputType
        self.value = value
        self.unit = unit
        self.inputRange = inputRange
        self.inputRangeName = inputRangeName
        self.inputRangeValue = inputRangeValue
    }
}

public struct CfgItem: Hashable, Sendable {
    public let name: String
    public let pathHint: String?
    public let nameOffset: Int
    public let payloadOffset: Int
    public let payloadLength: Int
    /// Per-item `[ADDRESS]` value from the item's embedded INI section.
    /// `nil` when this item has no parameter block.
    public let paramAddress: UInt32?
    /// Parameters belonging to this item; empty when the item has none.
    public let params: [CfgParameter]

    public init(name: String, pathHint: String? = nil, nameOffset: Int = 0,
                payloadOffset: Int, payloadLength: Int,
                paramAddress: UInt32? = nil, params: [CfgParameter] = []) {
        self.name = name
        self.pathHint = pathHint
        self.nameOffset = nameOffset
        self.payloadOffset = payloadOffset
        self.payloadLength = payloadLength
        self.paramAddress = paramAddress
        self.params = params
    }
}

public struct CfgTestPlan: Sendable {
    public let sourcePath: String
    /// First `[ADDRESS]` value from the cfg. Used as the fallback parameter-write
    /// address when an item has no per-item `paramAddress` of its own.
    public let address: UInt32?
    public let downloadBaseAddress: UInt32
    public let items: [CfgItem]
    public let embeddedBins: [String: Data]

    public init(sourcePath: String, address: UInt32?, downloadBaseAddress: UInt32 = 0xFF00_4000,
                items: [CfgItem], embeddedBins: [String: Data]) {
        self.sourcePath = sourcePath
        self.address = address
        self.downloadBaseAddress = downloadBaseAddress
        self.items = items
        self.embeddedBins = embeddedBins
    }

    /// Look up an embedded payload by record name, case-insensitively. Shared by
    /// the container-cfg consumers (`DdrDetector`, the GUI eye-scan flow) which
    /// pull payloads out of a packaged cfg by name rather than running it.
    public func payload(named name: String) -> Data? {
        embeddedBins.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Extract the eye-scan payloads packaged in this cfg — Boot (=DTT), eyescan (=item),
    /// an optional `trainonly` stage① bin, and an optional `reboot` item; `itemBase` is the cfg's
    /// download-base. Returns nil if this isn't an eye-scan cfg (no Boot/eyescan record). SINGLE
    /// SOURCE shared by the GUI (`MainViewModel`) and the CLI `--eyescan` mode — both just parse the
    /// SoC's `DDR眼图.cfg` and call this, so neither hand-specifies per-bin paths.
    public func eyescanPayloads() -> EyescanPayloads? {
        guard let dtt = payload(named: "Boot"), let item = payload(named: "eyescan") else { return nil }
        return EyescanPayloads(trainOnly: payload(named: "trainonly") ?? Data(), dtt: dtt, item: item,
                               itemBase: downloadBaseAddress, reboot: payload(named: "reboot"))
    }
}

/// The four payloads that drive an eye-scan run, extracted from a packaged `DDR眼图.cfg`
/// (see `CfgTestPlan.eyescanPayloads`). `trainOnly` empty ⇒ no stage① (self-training eyescan-item,
/// e.g. RK3576/RK3588); non-empty ⇒ RK3568's small-core model that needs a train-only stage①.
public struct EyescanPayloads: Sendable {
    public let trainOnly: Data
    public let dtt: Data
    public let item: Data
    public let itemBase: UInt32
    public let reboot: Data?
    public init(trainOnly: Data, dtt: Data, item: Data, itemBase: UInt32, reboot: Data?) {
        self.trainOnly = trainOnly; self.dtt = dtt; self.item = item; self.itemBase = itemBase; self.reboot = reboot
    }
}

/// Maps Rockchip USB PID (VID 0x2207) to TestFiles directory name.
/// Source: linux-usb.org usb.ids (authoritative Rockchip maskrom PIDs, up to
/// RK3399) + rockchip-flash-tool chip_db.py (modern SoCs) + TestFiles/ dir names.
public enum RockchipPidMap {
    public static let pidToSoc: [UInt16: String] = [
        // From linux-usb.org usb.ids — authoritative maskrom PIDs.
        0x290A: "RK29",
        0x292A: "RK2926&RK2928",   // usb.ids: "RK2928"
        0x292C: "RK3026&3028A",    // usb.ids: "RK3026"
        0x300A: "RK3066_RK3066A",
        0x300B: "RK3168",          // usb.ids: "RK3168"
        0x301A: "RK3036",
        0x310B: "RK3188",
        0x310C: "RK3128",          // usb.ids: "RK3126/RK3128"
        0x310D: "RK3126&RK3126C",
        0x320A: "RK3288",
        0x320B: "RK322X",          // usb.ids: "RK3228/RK3229"
        0x320C: "rk322xh&RK3328",
        0x330A: "RK3368",
        0x330C: "RK3399",
        // Modern SoCs — not in usb.ids; from rockchip-flash-tool chip_db.py.
        0x330D: "RK3326 & PX30 & RK3326S & PX30S",
        0x350A: "RK3568&RK3566",
        0x350B: "RK3588",
        0x350C: "RK3562",
        0x350E: "RK3576",
        0x350F: "RK3506",
        0x110C: "RV1126",
        0x3308: "RK3308",
    ]
}

public struct UsbDevice: Identifiable, Hashable, Sendable {
    public var id: String { deviceID }
    public let deviceID: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let productName: String
    public let serialNumber: String?
    public let socName: String?
    /// The USB address the host assigned this device. Unlike `deviceID` — which is
    /// deliberately stable across re-enumeration so a board can be addressed by the
    /// socket it is plugged into — this CHANGES every time the device re-enumerates,
    /// which is what makes it the signal for "did the board actually reset".
    public let usbAddress: UInt8

    public init(deviceID: String, vendorID: UInt16, productID: UInt16, productName: String, serialNumber: String?, socName: String? = nil, usbAddress: UInt8 = 0) {
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.serialNumber = serialNumber
        self.socName = socName
        self.usbAddress = usbAddress
    }
}

public enum ExecutionState: String, Sendable {
    case idle = "Idle"
    case initializing = "Init"
    case downloading = "Download"
    case running = "Run"
    case collectingLog = "CollectLog"
    case completed = "Completed"
    case failed = "Failed"
}

public enum LogLevel: String, Sendable {
    case info = "INFO"
    case error = "ERROR"
}

public struct ExecutionLogEntry: Hashable, Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let code: String
    public let message: String
    /// Structured item identity for item-scoped entries (boot/forceinit/connect/…).
    /// Carries the item name directly so consumers don't have to re-parse it out of
    /// `message` prose. `nil` for non-item entries (init, device, printf, …).
    public let itemName: String?

    public init(timestamp: Date = Date(), level: LogLevel, code: String, message: String, itemName: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.code = code
        self.message = message
        self.itemName = itemName
    }
}

public enum TestOutcome: String, Sendable {
    case passed = "PASS"
    case failed = "FAIL"
}

/// WHY a run did not pass. The CLI's exit code hinges entirely on this
/// distinction: only `.deviceVerdict` means the device actually tested the DDR
/// and reported it bad (exit 2 — scrap the board). Every other kind means the
/// test never produced a verdict at all (exit 1 — fix the cable/fixture, leave
/// the board alone). Before this existed, `TestExecutionEngine` collapsed both
/// into `outcome: .failed`, so a single bulk timeout was indistinguishable from
/// a genuine soldering failure.
public enum FailureKind: String, Sendable {
    /// `RKU_TestDeviceReady` returned resultCode != 0 — a real DDR verdict.
    case deviceVerdict
    /// A control/bulk transfer failed, stalled, or timed out.
    case transport
    /// The cfg is missing, unparseable, or carries no test items.
    case cfg
    /// No Rockchip device to talk to.
    case noDevice
}

extension FailureKind {
    /// Classify a thrown error. Anything that isn't recognisably a cfg or
    /// device-presence problem is treated as transport — deliberately
    /// conservative: an unknown error must never be reported as a bad board.
    public static func classify(_ error: Error) -> FailureKind {
        guard let e = error as? DDRToolError else { return .transport }
        switch e {
        case .noDevice, .multipleDevices:
            return .noDevice
        case .fileNotFound, .invalidFormat, .parseFailure:
            return .cfg
        case .transportError, .runtimeError:
            return .transport
        }
    }
}

/// Outcome of a single `RKU_TestDeviceReady` (opcode 0) poll.
///
/// Mirrors DDR_UserTool's `sub_416B70`: the 16-byte response carries the echoed
/// token in word0, a status in word1, and a result code in word2. Pass/fail is
/// derived from these words — NOT from printf text (printf is display-only).
public struct DeviceReadyStatus: Sendable {
    public enum Phase: Sendable {
        /// word1 == 2 — the device is still executing the downloaded test code.
        case running
        /// word1 == 0 — the device finished; inspect `resultCode`.
        case finished
        /// word1 == 1 — the device reported an error.
        case error
    }

    /// word1 mapped to a phase.
    public let phase: Phase
    /// word2 — return code of the downloaded test code. Only meaningful once
    /// `phase == .finished`: 0 → pass, anything else → fail.
    public let resultCode: UInt32

    public init(phase: Phase, resultCode: UInt32) {
        self.phase = phase
        self.resultCode = resultCode
    }
}

public struct ExecutionResult: Sendable {
    public let outcome: TestOutcome
    public let state: ExecutionState
    public let selectedDevice: UsbDevice?
    public let logs: [ExecutionLogEntry]
    public let startedAt: Date
    public let finishedAt: Date
    /// True only when a boot download was actually performed AND succeeded this
    /// run. Lets the caller (MainViewModel) clear its "device needs boot" latch —
    /// mirroring DDR_UserTool's `this+0x4B8`, which is cleared solely after a
    /// successful boot. False when boot was skipped (already booted) or failed.
    public let bootSucceeded: Bool
    /// Why the run failed; `nil` when it passed. `.deviceVerdict` is the ONLY
    /// value that means "this board is bad" — see `FailureKind`.
    public let failure: FailureKind?

    public init(
        outcome: TestOutcome,
        state: ExecutionState,
        selectedDevice: UsbDevice?,
        logs: [ExecutionLogEntry],
        startedAt: Date,
        finishedAt: Date,
        bootSucceeded: Bool = false,
        failure: FailureKind? = nil
    ) {
        self.outcome = outcome
        self.state = state
        self.selectedDevice = selectedDevice
        self.logs = logs
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.bootSucceeded = bootSucceeded
        self.failure = failure
    }
}

