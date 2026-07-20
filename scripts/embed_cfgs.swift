#!/usr/bin/env swift
// Build-time encoder for the single-file CLI's embedded cfg library.
//
// Packs the entire DDRTestFiles/ tree into ONE blob that the CLI embeds via
// `.incbin` (Sources/CDDRBlob/blob.S) and decompresses IN-PROCESS at runtime
// using Apple's Compression framework (libcompression — a core OS library,
// always present, no external `tar`/`zstd`/`unzip` and no child process).
//
// Blob layout:  [u64 LE uncompressedSize] [ LZMA stream ]
// The LZMA stream decodes to a manifest archive:
//   "RKDR" (4) | u32 fileCount | fileCount × ( u16 pathLen | path utf8 | u32 dataLen | data )
// paths are relative to DDRTestFiles/ (e.g. "RK3588/4GB LPDDR4.cfg").
//
// Run whenever DDRTestFiles/ changes:  bash scripts/embed_cfgs.sh
// (86MB library → ~2.3MB blob; the cfgs share large payloads that LZMA folds.)

import Foundation
import Compression

let fm = FileManager.default
let repoRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
let base = repoRoot.appendingPathComponent("DDRTestFiles")
let outURL = repoRoot.appendingPathComponent("Sources/CDDRBlob/ddr_cfgs.blob")

guard fm.fileExists(atPath: base.path) else {
    FileHandle.standardError.write(Data("[embed_cfgs] DDRTestFiles/ not found under \(repoRoot.path)\n".utf8))
    exit(1)
}

// Collect files (sorted for a reproducible blob).
var files: [(rel: String, data: Data)] = []
if let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
    for case let u as URL in en {
        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let rel = String(u.path.dropFirst(base.path.count + 1))
        guard let d = try? Data(contentsOf: u) else { continue }
        files.append((rel, d))
    }
}
files.sort { $0.rel < $1.rel }

// Build the manifest archive.
var man = Data()
func putU32(_ v: UInt32) { var x = v.littleEndian; man.append(Data(bytes: &x, count: 4)) }
func putU16(_ v: UInt16) { var x = v.littleEndian; man.append(Data(bytes: &x, count: 2)) }
man.append(contentsOf: Array("RKDR".utf8))
putU32(UInt32(files.count))
for f in files {
    let pb = Array(f.rel.utf8)
    putU16(UInt16(pb.count)); man.append(contentsOf: pb)
    putU32(UInt32(f.data.count)); man.append(f.data)
}

// LZMA-compress with Apple's Compression framework (round-trips with the runtime decoder).
let src = [UInt8](man)
var dst = [UInt8](repeating: 0, count: src.count + 65_536)
let encoded = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_LZMA)
guard encoded > 0 else {
    FileHandle.standardError.write(Data("[embed_cfgs] LZMA encode failed\n".utf8))
    exit(1)
}

// Prepend the uncompressed size so the runtime can size its decode buffer.
var out = Data()
var sz = UInt64(src.count).littleEndian
out.append(Data(bytes: &sz, count: 8))
out.append(contentsOf: dst[0..<encoded])
do {
    try out.write(to: outURL)
} catch {
    FileHandle.standardError.write(Data("[embed_cfgs] write failed: \(error)\n".utf8))
    exit(1)
}

let mb = { (n: Int) in String(format: "%.2f MB", Double(n) / 1_000_000) }
print("[embed_cfgs] \(files.count) files, manifest \(mb(src.count)) → blob \(mb(out.count)) (\(String(format: "%.1f", Double(src.count) / Double(out.count)))x)")
print("[embed_cfgs] wrote \(outURL.path)")
