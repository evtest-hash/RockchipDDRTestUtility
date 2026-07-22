import CLibusb
import DDRCore
import Foundation

/// The one libusb context for the whole process.
///
/// libusb contexts are meant to be long-lived; on macOS each `libusb_init`
/// spins up a darwin hotplug event thread and each `libusb_exit` tears it down.
/// Calling `libusb_exit` while that event thread is mid-callback servicing a
/// device *detach* (`darwin_devices_detached`) deadlocks: `darwin_exit` takes
/// the global `active_contexts_lock` and waits for the event thread to stop,
/// while the event thread is blocked trying to take that same lock. Because the
/// old design created and destroyed a context per `RkUsbTransportLibusb` — and
/// tore one down exactly on unplug (`MainViewModel.tearDownActiveTransport`) —
/// that race was reachable and froze the main thread for ~22s.
///
/// A single context created once and *never* exited removes the teardown path
/// entirely, so the deadlock can't occur. It also drops the redundant
/// init/exit churn on every enumerate/poll/CLI command. The context is a
/// deliberate process-lifetime "leak" — the OS reclaims it at exit; not exiting
/// it is the whole point. libusb contexts are thread-safe, so sharing one
/// across transports (and across the enumerate + I/O paths) is supported.
enum LibusbSharedContext {
    /// `static let` is initialized exactly once, lazily and thread-safely.
    private static let initialized: (context: OpaquePointer?, rc: Int32) = {
        var ctx: OpaquePointer?
        let rc = libusb_init(&ctx)
        return (ctx, rc)
    }()

    /// The shared context, initializing it on first use. Throws if the one-time
    /// `libusb_init` failed.
    static func acquire() throws -> OpaquePointer {
        let result = initialized
        guard result.rc == 0, let ctx = result.context else {
            throw DDRToolError.transportError("libusb_init failed (code \(result.rc))")
        }
        return ctx
    }
}

public final class RkUsbTransportLibusb: UsbTransport {
    private static let rockchipVendorID: UInt16 = 0x2207
    private static let bootControlRequestType: UInt8 = 0x40
    private static let bootControlRequest: UInt8 = 0x0C
    private static let bootControlIndex: UInt16 = 0x0471
    private static let bootControlChunkSize = 4096

    private static let downloadChunkSize = 0x4000
    private static let pollReadLength: UInt32 = 0x200   // 512B (1 max-packet). Was 0x2000 for the eyescan
    // DTT ring, but that broke the SOLDER test: a 0x2000 printf-poll command the solder DTT can't
    // service leaves it unresponsive → the next testDeviceReady times out (bulk IN timeout) at the
    // "connect" item. The eyescan's putc watermark backpressure keeps unread ≤256, so 512 drains it.
    private static let pollOpcode: UInt32 = 0x80
    private static let writeOpcode: UInt32 = 0x02
    private static let runOpcode: UInt32 = 0x03
    private static let handshakeOpcode: UInt32 = 0x00

    private static let timeoutMs: UInt32 = 5000
    private static let gb18030Encoding: UInt32 = 0x0632
    private static let fallbackParameterAddress: UInt32 = 0xFF0F_FF00

    /// PIDs whose boot transfer must NOT be RC4-encrypted. Values mirror Windows'
    /// config.ini `CLOSE_RC4_LIST = 350A|350B|350C|350D|350E|110F`
    /// (RK3568/RK3566, RK3588, RK3562, RK3576, RV1126B). Every other (older) SoC
    /// gets the boot blob RC4-encrypted before chunking. Mirrors DDR_UserTool
    /// `sub_40A3C0` flag `a4`.
    ///
    /// Mac is open-box and does not read config.ini for this, so this constant is
    /// the single source of truth (the parsed `ConfigSettings.closeRC4List` is
    /// unused on Mac). MAINTENANCE: when adding a new SoC, update BOTH this set
    /// (if its boot must skip RC4) AND `RockchipPidMap.pidToSoc` in DDRCore.
    private static let closeRC4PIDs: Set<UInt16> = [
        0x350A, 0x350B, 0x350C, 0x350D, 0x350E, 0x110F,
    ]

    private var handle: OpaquePointer?
    private var claimedInterface: Int32 = -1
    private var claimedAltSetting: Int32 = 0
    private var interfaceClaimed = false
    private var bulkOutEndpoint: UInt8 = 0x02
    private var bulkInEndpoint: UInt8 = 0x81
    private var openedDevice: UsbDevice?
    public var isOpen: Bool { handle != nil }
    private var tokenSeed: UInt32 = 0x13572468
    private let debugEnabled = false

    /// Serializes every device-command I/O on the handle. Required because the
    /// idle keep-alive reader (MainViewModel.startKeepAlive) and the test engine
    /// both drive this same libusb handle from different execution contexts. The
    /// Rockchip protocol pairs each 32-byte command with a token-echoed ack, so
    /// interleaving two operations would desync the response stream. Mirrors
    /// DDR_UserTool's CRKUsbComm critical section (sub_403050), which serializes
    /// its permanent printf-reader thread against the per-click test orchestrator
    /// thread. Recursive because `open` calls `close` internally.
    private let ioLock = NSRecursiveLock()
    private let bootChunkDelayUs: useconds_t = 60_000
    private let transferTimeoutMs: UInt32 = RkUsbTransportLibusb.timeoutMs

    public init() throws {
        // Force the one-time shared-context init so construction fails fast if
        // libusb_init failed. The context is a process global (see
        // `LibusbSharedContext`); this instance holds no context state.
        _ = try LibusbSharedContext.acquire()
    }

    deinit {
        // Only release this transport's device handle. The libusb context is
        // process-shared and intentionally never `libusb_exit`'d — see
        // `LibusbSharedContext`. Calling `libusb_exit` here (on the main actor,
        // on the unplug path) is what deadlocked against libusb's device-detach
        // handler and hung the UI.
        try? close()
    }

    public func discoverDevices() throws -> [UsbDevice] {
        let list = try enumerateDevices()
        defer {
            for dev in list {
                libusb_unref_device(dev)
            }
        }
        var devices: [UsbDevice] = []

        for dev in list {
            var descriptor = libusb_device_descriptor()
            let rc = libusb_get_device_descriptor(dev, &descriptor)
            guard rc == 0 else {
                continue
            }
            guard descriptor.idVendor == Self.rockchipVendorID else {
                continue
            }

            let bus = libusb_get_bus_number(dev)
            let addr = libusb_get_device_address(dev)
            let socName = RockchipPidMap.pidToSoc[descriptor.idProduct]
            let productName: String
            if let soc = socName {
                productName = "Rockchip \(soc) (0x\(String(format: "%04X", descriptor.idProduct)))"
            } else {
                productName = String(format: "Rockchip USB (0x%04X)", descriptor.idProduct)
            }

            var serialNumber: String?
            if descriptor.iSerialNumber != 0 {
                var handleForSerial: OpaquePointer?
                if libusb_open(dev, &handleForSerial) == 0, let handleForSerial {
                    serialNumber = readSerialNumber(handle: handleForSerial, index: descriptor.iSerialNumber)
                    libusb_close(handleForSerial)
                }
            }

            let deviceID = String(
                format: "%03u-%03u-%04X-%04X-%@",
                bus,
                addr,
                descriptor.idVendor,
                descriptor.idProduct,
                serialNumber ?? "NA"
            )
            devices.append(
                UsbDevice(
                    deviceID: deviceID,
                    vendorID: descriptor.idVendor,
                    productID: descriptor.idProduct,
                    productName: productName,
                    serialNumber: serialNumber,
                    socName: socName
                )
            )
        }

        return devices
    }

    public func open(device: UsbDevice) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        try close()

        let list = try enumerateDevices()
        defer {
            for dev in list {
                libusb_unref_device(dev)
            }
        }
        var selected: OpaquePointer?

        for dev in list {
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &descriptor) == 0 else {
                continue
            }
            guard descriptor.idVendor == device.vendorID, descriptor.idProduct == device.productID else {
                continue
            }

            let bus = libusb_get_bus_number(dev)
            let addr = libusb_get_device_address(dev)
            let candidate = String(
                format: "%03u-%03u-%04X-%04X-",
                bus,
                addr,
                descriptor.idVendor,
                descriptor.idProduct
            )
            if device.deviceID.hasPrefix(candidate) {
                var handleCandidate: OpaquePointer?
                let rc = libusb_open(dev, &handleCandidate)
                guard rc == 0, let handleCandidate else {
                    throw makeUSBError("libusb_open failed for selected device", code: rc)
                }
                selected = handleCandidate
                break
            }
        }

        if selected == nil {
            selected = libusb_open_device_with_vid_pid(
                try LibusbSharedContext.acquire(), device.vendorID, device.productID)
        }

        guard let selected else {
            throw DDRToolError.transportError("Failed to open USB device \(device.deviceID)")
        }

        handle = selected
        openedDevice = device
        claimedInterface = -1
        claimedAltSetting = 0
        interfaceClaimed = false
        bulkOutEndpoint = 0x02
        bulkInEndpoint = 0x81

        // Set configuration to reset USB state
        let setConfigRC = libusb_set_configuration(selected, 1)
        debug("set configuration rc=\(setConfigRC)")

        _ = libusb_set_auto_detach_kernel_driver(selected, 1)
        let resolved = try resolveInterfaceAndEndpoints(handle: selected)
        claimedInterface = resolved.interfaceNumber
        claimedAltSetting = resolved.altSetting
        bulkOutEndpoint = resolved.bulkOut
        bulkInEndpoint = resolved.bulkIn
        debug("open selected iface=\(claimedInterface) alt=\(claimedAltSetting) out=0x\(String(format: "%02X", bulkOutEndpoint)) in=0x\(String(format: "%02X", bulkInEndpoint))")

        // Claim interface and set alt setting
        try ensureBulkInterfaceClaimed(handle: selected)
        _ = libusb_set_interface_alt_setting(selected, claimedInterface, claimedAltSetting)
        _ = libusb_clear_halt(selected, bulkOutEndpoint)
        _ = libusb_clear_halt(selected, bulkInEndpoint)
    }

    public func downloadBoot(item: CfgItem, payload: Data, lenientFinalChunk: Bool = false) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        try ensureOpened()
        guard payload.count > 0 else {
            throw DDRToolError.transportError("Boot payload is empty")
        }

        // Boot format, verified byte-for-byte against a captured Windows run on
        // RK3288 (RC4 SoC): the captured control transfer's 4096-byte body and
        // trailing 2-byte CRC both matched this exact construction.
        //   1. zero-pad the loader to a multiple of 2048 bytes
        //   2. RC4-encrypt the whole padded buffer (unless the SoC PID is in
        //      CLOSE_RC4_LIST)
        //   3. append a 2-byte big-endian CRC16-CCITT of the result
        //   4. send in 4096-byte vendor control chunks (request 0x0C, index
        //      0x0471); the CRC forms a trailing 2-byte chunk.
        // Mirrors Windows sub_40A3C0 (pad + RC4) then sub_40A910 (append CRC,
        // chunk into 4096-byte DeviceIoControl transfers).
        var bootPayload = payload
        let paddedLen = ((bootPayload.count + 0x7FF) / 0x800) * 0x800
        if paddedLen > bootPayload.count {
            bootPayload.append(Data(repeating: 0, count: paddedLen - bootPayload.count))
        }
        let useRC4 = shouldRC4BootForCurrentDevice
        if useRC4 {
            bootPayload = RC4.cipher(key: RC4.rockchipKey, data: bootPayload)
        }
        let crc = crcCCITT(bootPayload)
        bootPayload.append(UInt8((crc >> 8) & 0xFF))
        bootPayload.append(UInt8(crc & 0xFF))
        debug("downloadBoot bytes=\(bootPayload.count) rc4=\(useRC4)")

        var offset = 0
        while offset < bootPayload.count {
            let chunkLen = min(Self.bootControlChunkSize, bootPayload.count - offset)
            let chunk = bootPayload.subdata(in: offset..<(offset + chunkLen))
            let isFinal = (offset + chunkLen >= bootPayload.count)
            do {
                try sendBootControlChunk(chunk)
            } catch {
                if isFinal && lenientFinalChunk {
                    debug("final chunk not ACKed — treating blob as launched")
                } else {
                    throw error
                }
            }
            offset += chunkLen
            if bootChunkDelayUs > 0 {
                usleep(bootChunkDelayUs)
            }
        }
    }

    /// True when the opened device's PID is NOT in CLOSE_RC4_LIST — i.e. the
    /// boot transfer must be RC4-encrypted. Defaults to false when no device is
    /// open, which preserves the previously-verified (RC4-less) flow for modern
    /// SoCs and avoids encrypting the boot blob unexpectedly.
    private var shouldRC4BootForCurrentDevice: Bool {
        guard let pid = openedDevice?.productID else { return false }
        return !Self.closeRC4PIDs.contains(pid)
    }

    public func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        try ensureOpened()
        guard payload.count > 0 else {
            throw DDRToolError.transportError("Payload is empty for \(item.name)")
        }

        var offset = 0
        while offset < payload.count {
            let chunkLen = min(Self.downloadChunkSize, payload.count - offset)
            let chunkAddress = address &+ UInt32(offset)
            let token = nextToken()
            let command = makeCommand(
                opcode: Self.writeOpcode,
                address: chunkAddress,
                length: UInt32(chunkLen),
                token: token
            )

            try bulkWrite(command)
            try bulkWrite(payload.subdata(in: offset..<(offset + chunkLen)))
            guard let ack = try bulkRead(requiredBytes: 16, timeoutMs: transferTimeoutMs) else {
                throw DDRToolError.transportError("downloadItem ack timeout")
            }
            try validateAck(ack, expectedToken: token, stage: "downloadItem")

            offset += chunkLen
            usleep(10_000)
        }
    }

    public func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        try ensureOpened()
        let payload = makeParameterPayload(params: params)
        let targetAddress = address ?? Self.fallbackParameterAddress
        let token = nextToken()
        let command = makeCommand(
            opcode: Self.writeOpcode,
            address: targetAddress,
            length: UInt32(payload.count),
            token: token
        )

        try bulkWrite(command)
        try bulkWrite(payload)
        guard let ack = try bulkRead(requiredBytes: 16, timeoutMs: transferTimeoutMs) else {
            throw DDRToolError.transportError("downloadParam ack timeout")
        }
        try validateAck(ack, expectedToken: token, stage: "downloadParam")
        usleep(10_000)
    }

    public func runItem(item: CfgItem, address: UInt32) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        try ensureOpened()

        // RKU_RunMemory (opcode 3): hand control to the downloaded test code.
        // The device acks with the echoed token; we only validate that here.
        // Pass/fail is determined afterwards by polling testDeviceReady() —
        // mirroring Windows, which loops RKU_TestDeviceReady after RunMemory
        // (sub_406420) rather than trusting a single handshake response.
        let runToken = nextToken()
        let runCommand = makeCommand(
            opcode: Self.runOpcode,
            address: address,
            length: 0,
            token: runToken
        )
        try bulkWrite(runCommand)
        guard let runAck = try bulkRead(requiredBytes: 16, timeoutMs: transferTimeoutMs) else {
            throw DDRToolError.transportError("runItem ack timeout")
        }
        try validateAck(runAck, expectedToken: runToken, stage: "runItem")
    }

    public func testDeviceReady() throws -> DeviceReadyStatus {
        ioLock.lock(); defer { ioLock.unlock() }
        try ensureOpened()

        // RKU_TestDeviceReady (opcode 0). The 16-byte response:
        //   word0 = echoed token, word1 = status (0=done, 1=error, 2=running),
        //   word2 = result code of the test code (0 = pass).
        // Matches DDR_UserTool sub_416B70.
        let token = nextToken()
        let command = makeCommand(
            opcode: Self.handshakeOpcode,
            address: 0,
            length: 0,
            token: token
        )
        try bulkWrite(command)
        guard let ack = try bulkRead(requiredBytes: 16, timeoutMs: transferTimeoutMs) else {
            throw DDRToolError.transportError("testDeviceReady ack timeout")
        }
        try validateAck(ack, expectedToken: token, stage: "testDeviceReady")

        let statusWord = decodeUInt32LE(ack, at: 4)
        let resultCode = decodeUInt32LE(ack, at: 8)
        let phase: DeviceReadyStatus.Phase
        switch statusWord {
        case 1: phase = .error
        case 2: phase = .running
        default: phase = .finished
        }
        return DeviceReadyStatus(phase: phase, resultCode: resultCode)
    }

    public func readPrintf() throws -> String? {
        try readPrintf(acknowledge: true)
    }

    public func readPrintf(acknowledge: Bool) throws -> String? {
        ioLock.lock(); defer { ioLock.unlock() }
        try ensureOpened()

        guard let data = try sendPrintfPoll(timeoutMs: 100) else {
            return nil
        }
        guard !data.isEmpty else {
            return nil
        }

        if data.count == 16 {
            return nil
        }

        // The runtime-log handshake is what the firmware answers slowly during
        // streaming (~500ms/read). Skip it for high-rate drains — the DDR Test
        // Tool ring advances on the read itself, so it is not needed there.
        if acknowledge, data.count >= 128 {
            try acknowledgeRuntimeLog()
        }

        let trimmed = trimTrailingZeros(data)
        guard !trimmed.isEmpty else {
            return nil
        }

        // Device firmware outputs GBK-encoded Chinese mixed with ASCII.
        // Try GBK first; if that fails, try UTF-8, then ASCII.
        // As a fallback, if UTF-8 produced Latin-1-range garbage, fix double-encoding.
        var text: String?
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(Self.gb18030Encoding)) // GB18030
        if let s = String(data: trimmed, encoding: gbEncoding), !s.isEmpty {
            text = s
        } else if let s = String(data: trimmed, encoding: .utf8), !s.isEmpty {
            text = s
        } else if let s = String(data: trimmed, encoding: .ascii), !s.isEmpty {
            text = s
        }

        if let text {
            // Filter control characters but keep \n, \r, \t
            let filtered = text.unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar) ||
                CharacterSet.newlines.contains(scalar) || scalar == "\t"
            }.map(String.init).joined()
            return fixDoubleEncodedGBK(filtered)
        }

        // Binary data: hex dump
        return trimmed.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Lightweight liveness probe used by the idle keep-alive reader.
    ///
    /// Prefer the Windows-like printf poll first (opcode 0x80), because that is
    /// what naturally keeps the pipe active during idle. But some cfg flows leave
    /// the resident firmware in a state where printf polling can time out while
    /// the bulk command loop is still healthy; in that case, fall back to a
    /// status poll (opcode 0x00). A response on either path means the device is
    /// still alive and the current booted session must be preserved — otherwise
    /// the GUI wrongly re-arms `deviceNeedsBoot` and attempts to boot again on
    /// the next click, which fails on an already-booted device.
    public func probeAlive() -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        guard handle != nil else { return false }
        if let _ = try? sendPrintfPoll(timeoutMs: 400) {
            return true
        }
        let status = try? sendStatusPoll(timeoutMs: 400)
        return status != nil
    }

    /// Send the opcode-0x80 (RKU_ReadPrintf) poll and return the raw response
    /// (nil on timeout). Shared by `readPrintf` (decodes the bytes) and
    /// `probeAlive` (liveness). Caller must hold `ioLock`.
    private func sendPrintfPoll(timeoutMs: UInt32) throws -> Data? {
        let poll = makeCommand(
            opcode: Self.pollOpcode,
            address: 0,
            length: Self.pollReadLength,
            token: 0
        )
        try bulkWrite(poll)
        return try bulkRead(requiredBytes: nil, timeoutMs: timeoutMs)
    }

    /// Send opcode-0 status poll and return the decoded result, or nil on
    /// timeout. Shared by `probeAlive` as a fallback when printf polling is too
    /// strict for the current post-test firmware state. Caller must hold
    /// `ioLock`.
    private func sendStatusPoll(timeoutMs: UInt32) throws -> DeviceReadyStatus? {
        let token = nextToken()
        let command = makeCommand(
            opcode: Self.handshakeOpcode,
            address: 0,
            length: 0,
            token: token
        )
        try bulkWrite(command)
        guard let ack = try bulkRead(requiredBytes: 16, timeoutMs: timeoutMs, allowTimeout: true) else {
            return nil
        }
        try validateAck(ack, expectedToken: token, stage: "probeAlive")

        let statusWord = decodeUInt32LE(ack, at: 4)
        let resultCode = decodeUInt32LE(ack, at: 8)
        let phase: DeviceReadyStatus.Phase
        switch statusWord {
        case 1: phase = .error
        case 2: phase = .running
        default: phase = .finished
        }
        return DeviceReadyStatus(phase: phase, resultCode: resultCode)
    }

    public func close() throws {
        ioLock.lock(); defer { ioLock.unlock() }
        if let handle {
            if interfaceClaimed, claimedInterface >= 0 {
                _ = libusb_release_interface(handle, claimedInterface)
            }
            libusb_close(handle)
        }
        handle = nil
        openedDevice = nil
        claimedInterface = -1
        claimedAltSetting = 0
        interfaceClaimed = false
    }

    // MARK: - Core USB helpers

    private func readSerialNumber(handle: OpaquePointer, index: UInt8) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        let len = buf.withUnsafeMutableBufferPointer { ptr in
            libusb_get_string_descriptor_ascii(
                handle,
                index,
                ptr.baseAddress,
                Int32(ptr.count)
            )
        }
        guard len > 0 else { return nil }
        let safeLen = min(Int(len), buf.count - 1)
        return String(bytes: buf[..<safeLen], encoding: .ascii)
            ?? String(bytes: buf[..<safeLen], encoding: .utf8)
    }

    private func ensureOpened() throws {
        guard handle != nil else {
            throw DDRToolError.transportError("USB device is not opened")
        }
    }

    private func enumerateDevices() throws -> [OpaquePointer] {
        var listPtr: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(try LibusbSharedContext.acquire(), &listPtr)
        guard count >= 0 else {
            throw makeUSBError("libusb_get_device_list failed", code: Int32(count))
        }
        defer { libusb_free_device_list(listPtr, 1) }

        guard let listPtr else { return [] }
        var devices: [OpaquePointer] = []
        let intCount = Int(count)
        for idx in 0..<intCount {
            if let dev = listPtr[idx], let retained = libusb_ref_device(dev) {
                devices.append(retained)
            }
        }
        return devices
    }

    private func resolveInterfaceAndEndpoints(handle: OpaquePointer) throws -> (interfaceNumber: Int32, altSetting: Int32, bulkOut: UInt8, bulkIn: UInt8) {
        guard let dev = libusb_get_device(handle) else {
            throw DDRToolError.transportError("libusb_get_device returned nil")
        }

        var configPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        let rc = libusb_get_active_config_descriptor(dev, &configPtr)
        guard rc == 0, let configPtr else {
            throw makeUSBError("libusb_get_active_config_descriptor failed", code: rc)
        }
        defer { libusb_free_config_descriptor(configPtr) }

        struct Candidate {
            let interfaceNumber: Int32
            let altSetting: Int32
            let outEp: UInt8
            let inEp: UInt8
        }
        var candidates: [Candidate] = []

        let interfaceCount = Int(configPtr.pointee.bNumInterfaces)
        let ifaceArray = UnsafeBufferPointer(start: configPtr.pointee.interface, count: interfaceCount)
        for iface in ifaceArray {
            let altCount = Int(iface.num_altsetting)
            let altArray = UnsafeBufferPointer(start: iface.altsetting, count: altCount)
            for alt in altArray {
                let epCount = Int(alt.bNumEndpoints)
                let epArray = UnsafeBufferPointer(start: alt.endpoint, count: epCount)
                var outEp: UInt8?
                var inEp: UInt8?
                for ep in epArray {
                    let typeMask = UInt8(LIBUSB_TRANSFER_TYPE_MASK)
                    let type = ep.bmAttributes & typeMask
                    guard type == UInt8(LIBUSB_TRANSFER_TYPE_BULK.rawValue) else {
                        continue
                    }
                    let addr = ep.bEndpointAddress
                    let inMask = UInt8(LIBUSB_ENDPOINT_DIR_MASK)
                    let inValue = UInt8(LIBUSB_ENDPOINT_IN.rawValue)
                    if (addr & inMask) == inValue {
                        inEp = addr
                    } else {
                        outEp = addr
                    }
                }
                if let outEp, let inEp {
                    candidates.append(
                        Candidate(
                            interfaceNumber: Int32(alt.bInterfaceNumber),
                            altSetting: Int32(alt.bAlternateSetting),
                            outEp: outEp,
                            inEp: inEp
                        )
                    )
                }
            }
        }

        if debugEnabled {
            for c in candidates {
                debug("candidate iface=\(c.interfaceNumber) alt=\(c.altSetting) out=0x\(String(format: "%02X", c.outEp)) in=0x\(String(format: "%02X", c.inEp))")
            }
        }

        if let exact = candidates.first(where: { $0.outEp == 0x02 && $0.inEp == 0x81 }) {
            return (exact.interfaceNumber, exact.altSetting, exact.outEp, exact.inEp)
        }
        if let first = candidates.first {
            return (first.interfaceNumber, first.altSetting, first.outEp, first.inEp)
        }

        return (0, 0, 0x02, 0x81)
    }

    private func sendBootControlChunk(_ chunk: Data) throws {
        guard let handle else {
            throw DDRToolError.transportError("USB handle missing")
        }
        var buffer = [UInt8](chunk)
        let transferCount = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            libusb_control_transfer(
                handle,
                Self.bootControlRequestType,
                Self.bootControlRequest,
                0,
                Self.bootControlIndex,
                ptr.baseAddress,
                UInt16(ptr.count),
                transferTimeoutMs
            )
        }
        if transferCount == Int32(buffer.count) {
            return
        }

        if (transferCount == LIBUSB_ERROR_TIMEOUT.rawValue || transferCount == LIBUSB_ERROR_IO.rawValue),
           chunk.count > 512 {
            let split = chunk.count / 2
            let first = chunk.prefix(split)
            let second = chunk.dropFirst(split)
            debug("boot control retry split len=\(chunk.count) rc=\(transferCount)")
            try sendBootControlChunk(Data(first))
            try sendBootControlChunk(Data(second))
            return
        }

        guard transferCount == Int32(buffer.count) else {
            throw DDRToolError.transportError(
                "Boot control transfer failed, expected \(buffer.count) got \(transferCount)"
            )
        }
    }

    private func bulkWrite(_ data: Data) throws {
        guard let handle else {
            throw DDRToolError.transportError("USB handle missing")
        }
        try ensureBulkInterfaceClaimed(handle: handle)

        var bytes = [UInt8](data)
        let maxAttempts = bytes.count > 32 ? 3 : 1
        var transferred: Int32 = 0
        var rc: Int32 = 0
        for attempt in 1...maxAttempts {
            transferred = 0
            rc = bytes.withUnsafeMutableBufferPointer { ptr -> Int32 in
                libusb_bulk_transfer(
                    handle,
                    bulkOutEndpoint,
                    ptr.baseAddress,
                    Int32(ptr.count),
                    &transferred,
                    transferTimeoutMs
                )
            }

            if rc == 0, transferred == Int32(bytes.count) {
                break
            }

            let shouldRetry = (rc == LIBUSB_ERROR_TIMEOUT.rawValue || rc == LIBUSB_ERROR_IO.rawValue) && attempt < maxAttempts
            if shouldRetry {
                usleep(80_000)
                continue
            }
            break
        }

        if debugEnabled, bytes.count == 32 {
            debug("bulk OUT cmd \(hexBytes(bytes))")
        }
        guard rc == 0 else {
            throw makeUSBError("bulk OUT failed (ep=0x\(String(format: "%02X", bulkOutEndpoint)), len=\(bytes.count))", code: rc)
        }
        guard transferred == Int32(bytes.count) else {
            throw DDRToolError.transportError("bulk OUT short write: \(transferred)/\(bytes.count)")
        }
    }

    private func bulkRead(requiredBytes: Int?, timeoutMs: UInt32, allowTimeout: Bool = false) throws -> Data? {
        guard let handle else {
            throw DDRToolError.transportError("USB handle missing")
        }
        try ensureBulkInterfaceClaimed(handle: handle)

        let bufferSize = requiredBytes ?? Int(Self.pollReadLength)
        var bytes = [UInt8](repeating: 0, count: bufferSize)
        var transferred: Int32 = 0
        let rc = bytes.withUnsafeMutableBufferPointer { ptr -> Int32 in
            libusb_bulk_transfer(
                handle,
                bulkInEndpoint,
                ptr.baseAddress,
                Int32(ptr.count),
                &transferred,
                timeoutMs
            )
        }

        if rc == LIBUSB_ERROR_TIMEOUT.rawValue {
            if allowTimeout || requiredBytes == nil {
                return nil
            }
            throw makeUSBError("bulk IN timeout", code: rc)
        }
        guard rc == 0 else {
            throw makeUSBError("bulk IN failed", code: rc)
        }

        if let requiredBytes, transferred < Int32(requiredBytes) {
            throw DDRToolError.transportError("bulk IN short read: \(transferred)/\(requiredBytes)")
        }

        return Data(bytes.prefix(Int(transferred)))
    }

    private func validateAck(_ data: Data, expectedToken: UInt32, stage: String) throws {
        guard data.count >= 4 else {
            throw DDRToolError.transportError("\(stage) ack too short: \(data.count)")
        }
        let token = decodeUInt32LE(data, at: 0)
        guard token == expectedToken else {
            throw DDRToolError.transportError(
                "\(stage) ack token mismatch, expected 0x\(hex(expectedToken)), got 0x\(hex(token))"
            )
        }
    }

    private func makeCommand(opcode: UInt32, address: UInt32, length: UInt32, token: UInt32) -> Data {
        var command = Data()
        command.reserveCapacity(32)
        appendUInt32LE(opcode, to: &command)
        appendUInt32LE(address, to: &command)
        appendUInt32LE(length, to: &command)
        appendUInt32LE(token, to: &command)
        appendUInt32LE(1, to: &command)
        appendUInt32LE(0, to: &command)
        appendUInt32LE(0, to: &command)
        appendUInt32LE(0, to: &command)
        return command
    }

    private func acknowledgeRuntimeLog() throws {
        let token = nextToken()
        let command = makeCommand(
            opcode: Self.handshakeOpcode,
            address: 0,
            length: 0,
            token: token
        )
        try bulkWrite(command)
        guard let ack = try bulkRead(requiredBytes: 16, timeoutMs: 1000) else {
            throw DDRToolError.transportError("runtime log ack timeout")
        }
        try validateAck(ack, expectedToken: token, stage: "runtimeLogAck")
    }

    // MARK: - Dynamic Parameter Encoding

    private func makeParameterPayload(params: [CfgParameter]) -> Data {
        var values: [UInt32] = []
        for param in params {
            values.append(resolveParamValue(param))
        }
        var data = Data()
        data.reserveCapacity(values.count * 4)
        for v in values {
            appendUInt32LE(v, to: &data)
        }
        return data
    }

    private func resolveParamValue(_ param: CfgParameter) -> UInt32 {
        switch param.inputType {
        case .combo:
            guard let rangeValues = param.inputRangeValue else {
                return parseUInt32(param.value)
            }
            let options = rangeValues.split(separator: "|").map(String.init)
            let idx = Int(param.value) ?? 0
            guard idx < options.count else {
                return parseUInt32(param.value)
            }
            return parseUInt32(options[idx])
        case .edit:
            return parseUInt32(param.value)
        case .unknown:
            return parseUInt32(param.value)
        }
    }

    private func parseUInt32(_ s: String) -> UInt32 {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16) ?? 0
        }
        return UInt32(trimmed) ?? 0
    }

    // MARK: - Token Generation

    private func nextToken() -> UInt32 {
        tokenSeed = tokenSeed &* 1664525 &+ 1013904223
        if tokenSeed == 0 {
            tokenSeed = 1
        }
        return tokenSeed
    }

    // MARK: - Utilities

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    private func decodeUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data[offset..<(offset + 4)].withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }

    private func trimTrailingZeros(_ data: Data) -> Data {
        var end = data.count
        while end > 0, data[end - 1] == 0 {
            end -= 1
        }
        return data.prefix(end)
    }

    private func crcCCITT(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            var bit: UInt8 = 0x80
            while bit != 0 {
                if (crc & 0x8000) != 0 {
                    crc = (crc &<< 1) ^ 0x1021
                } else {
                    crc = crc &<< 1
                }
                if (byte & bit) != 0 {
                    crc ^= 0x1021
                }
                bit >>= 1
            }
        }
        return crc
    }

    private func makeUSBError(_ prefix: String, code: Int32) -> DDRToolError {
        DDRToolError.transportError("\(prefix): \(usbErrorMessage(code: code))")
    }

    private func ensureBulkInterfaceClaimed(handle: OpaquePointer) throws {
        if interfaceClaimed {
            return
        }

        let claimRC = libusb_claim_interface(handle, claimedInterface)
        guard claimRC == 0 else {
            throw DDRToolError.transportError(
                "libusb_claim_interface(\(claimedInterface)) failed: \(usbErrorMessage(code: claimRC))"
            )
        }
        debug("claim interface rc=0 (lazy)")
        interfaceClaimed = true
    }

    private func usbErrorMessage(code: Int32) -> String {
        guard let cString = libusb_error_name(code) else {
            return "LIBUSB_ERROR(\(code))"
        }
        return String(cString: cString)
    }

    private func hex(_ value: UInt32) -> String {
        String(format: "%08X", value)
    }

    private func hexBytes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Detect and fix double-encoded GBK text.
    /// When GBK bytes are misinterpreted as Latin-1 and re-encoded to UTF-8,
    /// each original byte > 0x7F becomes a 2-byte UTF-8 sequence (U+0080–U+00FF).
    /// We detect these Latin-1-range runs, re-encode as Latin-1 bytes, and decode as GBK.
    private func fixDoubleEncodedGBK(_ text: String) -> String {
        let latin1Range: ClosedRange<UnicodeScalar> = "\u{0080}"..."\u{00FF}"
        var result = ""
        var i = text.unicodeScalars.startIndex
        let scalars = text.unicodeScalars

        while i < scalars.endIndex {
            let scalar = scalars[i]
            if latin1Range.contains(scalar) {
                // Collect consecutive Latin-1 range characters
                var run = ""
                while i < scalars.endIndex {
                    let s = scalars[i]
                    if latin1Range.contains(s) || s == "\u{0020}" {
                        run.append(Character(s))
                        i = scalars.index(after: i)
                    } else {
                        break
                    }
                }
                // Try to re-decode as GBK
                if let latin1Data = run.data(using: .isoLatin1),
                   let fixed = String(data: latin1Data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632))) {
                    result.append(fixed)
                } else {
                    result.append(run)
                }
            } else {
                result.append(Character(scalar))
                i = scalars.index(after: i)
            }
        }
        return result
    }

    private func debug(_ message: String) {
        guard debugEnabled else { return }
        fputs("[RKUSB_DEBUG] \(message)\n", stderr)
    }
}
