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

public struct AppLanguage: Hashable, Identifiable, Sendable {
    public var id: String { tag }
    public let tag: String
    public let titleChinese: String
    public let titleEnglish: String
    public let fileName: String

    public init(tag: String, titleChinese: String, titleEnglish: String, fileName: String) {
        self.tag = tag
        self.titleChinese = titleChinese
        self.titleEnglish = titleEnglish
        self.fileName = fileName
    }
}

public struct ConfigSettings: Sendable {
    public let defaultTestFile: String?
    public let autoTest: String?
    public let logFlag: Bool
    public let supportLowUSB: Bool
    public let mscWaitTime: Int
    public let rkusbWaitTime: Int
    public let printfInterval: Int
    public let supportDeviceSelect: Bool
    public let closeRC4List: [String]

    public init(
        defaultTestFile: String?,
        autoTest: String?,
        logFlag: Bool,
        supportLowUSB: Bool,
        mscWaitTime: Int,
        rkusbWaitTime: Int,
        printfInterval: Int,
        supportDeviceSelect: Bool,
        closeRC4List: [String]
    ) {
        self.defaultTestFile = defaultTestFile
        self.autoTest = autoTest
        self.logFlag = logFlag
        self.supportLowUSB = supportLowUSB
        self.mscWaitTime = mscWaitTime
        self.rkusbWaitTime = rkusbWaitTime
        self.printfInterval = printfInterval
        self.supportDeviceSelect = supportDeviceSelect
        self.closeRC4List = closeRC4List
    }

    public static let `default` = ConfigSettings(
        defaultTestFile: nil,
        autoTest: nil,
        logFlag: true,
        supportLowUSB: true,
        mscWaitTime: 30,
        rkusbWaitTime: 20,
        printfInterval: 100,
        supportDeviceSelect: false,
        closeRC4List: []
    )
}

public struct TestFileEntry: Identifiable, Hashable {
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

    public init(name: String, pathHint: String?, nameOffset: Int, payloadOffset: Int, payloadLength: Int) {
        self.name = name
        self.pathHint = pathHint
        self.nameOffset = nameOffset
        self.payloadOffset = payloadOffset
        self.payloadLength = payloadLength
    }
}

public struct CfgTestPlan: Sendable {
    public let sourcePath: String
    public let address: UInt32?
    public let downloadBaseAddress: UInt32
    public let items: [CfgItem]
    public let params: [CfgParameter]
    public let embeddedBins: [String: Data]

    public init(sourcePath: String, address: UInt32?, downloadBaseAddress: UInt32 = 0xFF00_4000, items: [CfgItem], params: [CfgParameter], embeddedBins: [String: Data]) {
        self.sourcePath = sourcePath
        self.address = address
        self.downloadBaseAddress = downloadBaseAddress
        self.items = items
        self.params = params
        self.embeddedBins = embeddedBins
    }
}

/// Maps Rockchip USB PID (VID 0x2207) to TestFiles directory name.
/// Source: rockchip-flash-tool chip_db.py + TestFiles/ directory names.
public enum RockchipPidMap {
    public static let pidToSoc: [UInt16: String] = [
        // From rockchip-flash-tool chip_db.py
        0x300A: "RK3066_RK3066A",
        0x301A: "RK3036",
        0x310B: "RK3188",
        0x310C: "RK3128",
        0x310D: "RK3126&RK3126C",
        0x320A: "RK3288",
        0x320B: "RK322X",
        0x320C: "rk322xh&RK3328",
        0x330A: "RK3368",
        0x330C: "RK3399",
        0x330D: "RK3326 & PX30 & RK3326S & PX30S",
        0x350A: "RK3568&RK3566",
        0x350B: "RK3588",
        0x350C: "RK3562",
        0x350E: "RK3576",
        0x350F: "RK3506",
        0x110C: "RV1126",
        // From rkdeveloptool RKScan.cpp (older SoCs, no exact TestFiles match)
        0x300B: "RK3026&3028A",
        0x300C: "RK3028",
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

    public init(deviceID: String, vendorID: UInt16, productID: UInt16, productName: String, serialNumber: String?, socName: String? = nil) {
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.serialNumber = serialNumber
        self.socName = socName
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

public enum StepState: Sendable {
    case pending
    case downloading
    case running
    case passed
    case failed
}

public struct TestStep: Identifiable {
    public let id: String
    public let name: String
    public var state: StepState
    public var messages: [String]

    public init(name: String, state: StepState = .pending) {
        self.id = name
        self.name = name
        self.state = state
        self.messages = []
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

    public init(
        outcome: TestOutcome,
        state: ExecutionState,
        selectedDevice: UsbDevice?,
        logs: [ExecutionLogEntry],
        startedAt: Date,
        finishedAt: Date,
        bootSucceeded: Bool = false
    ) {
        self.outcome = outcome
        self.state = state
        self.selectedDevice = selectedDevice
        self.logs = logs
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.bootSucceeded = bootSucceeded
    }
}

public struct LocalizedStrings: Sendable {
    public let map: [String: String]

    public init(map: [String: String]) {
        self.map = map
    }

    public subscript(_ key: String, fallback fallbackValue: String) -> String {
        map[key] ?? fallbackValue
    }
}
