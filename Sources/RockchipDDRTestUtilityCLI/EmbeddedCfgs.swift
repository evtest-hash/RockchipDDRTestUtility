import CDDRBlob
import Compression
import Foundation

/// Materializes the compiled-in cfg library so the CLI can run as a single
/// self-contained file (no sibling DDRTestFiles/ needed). The blob is embedded
/// via `.incbin` (CDDRBlob) as `[u64 LE uncompressedSize][LZMA stream]`, decoded
/// IN-PROCESS with Apple's Compression framework (libcompression — a core OS
/// library, no external tar/zstd/unzip, no child process), and written to a
/// temp dir keyed by blob size so repeated runs reuse the extraction.
///
/// Wired via `CfgRepository.embeddedRootProvider`, which `makeDefaultRootURL`
/// consults only AFTER its on-disk probes — so a real DDRTestFiles/ next to the
/// binary (or in CWD) still wins, and this is purely the lone-binary fallback.
enum EmbeddedCfgs {
    /// Returns the extracted `…/DDRTestFiles` directory, or nil if the blob is
    /// absent/corrupt. Extraction happens once; later calls reuse the temp dir.
    static func rootURL() -> URL? {
        let len = ddr_cfgs_blob_len()
        guard len > 8, let raw = ddr_cfgs_blob_ptr() else { return nil }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rkddr-cfgs-\(len)", isDirectory: true)
        let root = dir.appendingPathComponent("DDRTestFiles", isDirectory: true)
        let sentinel = dir.appendingPathComponent(".extracted")
        let fm = FileManager.default
        if fm.fileExists(atPath: sentinel.path), fm.fileExists(atPath: root.path) {
            return canonical(root)   // already extracted
        }

        let blob = UnsafeBufferPointer(start: raw, count: len)
        // Header: uncompressed size (u64 LE).
        var uncompressed = 0
        for i in 0..<8 { uncompressed |= Int(blob[i]) << (8 * i) }
        guard uncompressed > 0 else { return nil }

        // Decode the LZMA stream in-process.
        var manifest = [UInt8](repeating: 0, count: uncompressed)
        let written = manifest.withUnsafeMutableBufferPointer { dst -> Int in
            compression_decode_buffer(dst.baseAddress!, dst.count,
                                      raw + 8, len - 8, nil, COMPRESSION_LZMA)
        }
        guard written == uncompressed else { return nil }

        guard let files = parseManifest(manifest) else { return nil }

        // Extract into a fresh temp dir, then drop the sentinel.
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for (rel, data) in files {
                let fileURL = root.appendingPathComponent(rel)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try data.write(to: fileURL)
            }
            fm.createFile(atPath: sentinel.path, contents: Data())
        } catch {
            return nil
        }
        return canonical(root)
    }

    /// Canonical (symlink-resolved) path. NSTemporaryDirectory() returns a path
    /// under `/var/...`, but FileManager's enumerator yields the resolved
    /// `/private/var/...`; CfgRepository.discoverTestFiles strips the root as a
    /// STRING prefix, so the two must agree or every cfg is skipped. realpath(3)
    /// gives the same canonical form the enumerator uses. (resolvingSymlinksInPath
    /// does NOT reliably resolve /var here.)
    private static func canonical(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p))
    }

    /// "RKDR" | u32 count | count × ( u16 pathLen | path | u32 dataLen | data ), LE.
    private static func parseManifest(_ bytes: [UInt8]) -> [(String, Data)]? {
        var p = 0
        func u16() -> Int? {
            guard p + 2 <= bytes.count else { return nil }
            let v = Int(bytes[p]) | (Int(bytes[p + 1]) << 8); p += 2; return v
        }
        func u32() -> Int? {
            guard p + 4 <= bytes.count else { return nil }
            let v = Int(bytes[p]) | (Int(bytes[p + 1]) << 8) | (Int(bytes[p + 2]) << 16) | (Int(bytes[p + 3]) << 24)
            p += 4; return v
        }
        guard bytes.count >= 8, Array(bytes[0..<4]) == Array("RKDR".utf8) else { return nil }
        p = 4
        guard let count = u32() else { return nil }
        var out: [(String, Data)] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let pl = u16(), p + pl <= bytes.count,
                  let rel = String(bytes: bytes[p..<p + pl], encoding: .utf8) else { return nil }
            p += pl
            guard let dl = u32(), p + dl <= bytes.count else { return nil }
            out.append((rel, Data(bytes[p..<p + dl])))
            p += dl
        }
        return out
    }
}
