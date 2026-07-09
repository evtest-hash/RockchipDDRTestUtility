// Sources/DDRUSB/EyescanRunner.swift
import DDRCore
import Foundation

/// Downloads a long-running "eye-scan" blob and continuously drains the
/// device's USB printf channel (opcode 0x80) into a growing transcript.
///
/// Eye-scan output can't be buffered on-device — the blob streams its results
/// to the host for the duration of the run — so this actor keeps polling
/// `readPrintf()` until either an end-marker substring shows up in the
/// transcript or the timeout elapses, then returns whatever was captured.
/// Mirrors `DdrDetector`'s style: transport/device are method params, driven
/// with the same raw transport primitives (`downloadBoot`, `readPrintf`).
public actor EyescanRunner {
    public init() {}

    public func run(transport: UsbTransport, device: UsbDevice, blob: Data,
                     endMarkers: [String], timeout: TimeInterval) async throws -> String {
        if !transport.isOpen { try transport.open(device: device) }

        // The eye blob takes over the CPU on its final chunk, so that
        // chunk's ACK is lost — that's expected success, hence lenient.
        let item = CfgItem(name: "eyescan", pathHint: nil, nameOffset: 0,
                            payloadOffset: 0, payloadLength: blob.count)
        try transport.downloadBoot(item: item, payload: blob, lenientFinalChunk: true)

        var transcript = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? transport.readPrintf(), !s.isEmpty {
                transcript += s
                if endMarkers.contains(where: transcript.contains) { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return transcript
    }
}
