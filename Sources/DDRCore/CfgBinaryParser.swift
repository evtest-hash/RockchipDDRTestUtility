import Foundation

public final class CfgBinaryParser {
    private static let recordSpacing = 0x2C3
    private static let firstRecordOffset = 0x41
    private static let defaultDownloadBaseAddress: UInt32 = 0xFF00_4000

    public init() {}

    public func parse(url: URL) throws -> CfgTestPlan {
        let data = try Data(contentsOf: url)
        return try parse(data: data, sourcePath: url.path)
    }

    public func parse(data: Data, sourcePath: String) throws -> CfgTestPlan {
        let tokens = extractUTF16ASCIITokens(from: data)
        guard !tokens.isEmpty else {
            throw DDRToolError.parseFailure("No UTF-16 tokens found in cfg")
        }

        let sectionStartIndex = tokens.firstIndex { $0.value.hasPrefix("[") && $0.value.hasSuffix("]") }
        let configTokens = sectionStartIndex.map { Array(tokens[$0...]) } ?? []

        // Family B cfgs carry several [ADDRESS]+[PARAM_xx] blocks at the file
        // tail — one per test item that takes parameters. Every block reuses the
        // same [PARAM_01..NN] section names, so parsing them as a single INI
        // would let later blocks overwrite earlier ones (IniParser keys on
        // section name) and the init item would receive the wrong (last) block.
        // Segmenting at each [ADDRESS] keeps the blocks distinct.
        let paramBlocks = parseParamBlocks(tokens: configTokens)
        let address = paramBlocks.first?.address

        let records = parseRecords(from: data)
        let items = buildItems(from: records, paramBlocks: paramBlocks)
        let bins = extractPayloads(data: data, records: records)
        let downloadBaseAddress = parseDownloadBaseAddress(from: data)

        return CfgTestPlan(
            sourcePath: sourcePath,
            address: address,
            downloadBaseAddress: downloadBaseAddress,
            items: items,
            embeddedBins: bins
        )
    }

    // MARK: - Record Parsing

    private struct CfgRecord {
        let name: String
        let span: Int
        let dataOffset: Int
    }

    private func parseRecords(from data: Data) -> [CfgRecord] {
        var records: [CfgRecord] = []
        var offset = Self.firstRecordOffset

        while offset + 10 < data.count {
            let marker = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            guard marker == 0x02C3 else { break }

            let span = Int(UInt32(data[offset + 2])
                | (UInt32(data[offset + 3]) << 8)
                | (UInt32(data[offset + 4]) << 16)
                | (UInt32(data[offset + 5]) << 24))
            let dataOffset = Int(UInt32(data[offset + 6])
                | (UInt32(data[offset + 7]) << 8)
                | (UInt32(data[offset + 8]) << 16)
                | (UInt32(data[offset + 9]) << 24))

            let nameStart = offset + 10
            var nameChars: [UInt8] = []
            var j = nameStart
            while j + 1 < data.count && j < nameStart + 80 {
                let b = data[j]
                let z = data[j + 1]
                if b >= 0x20, b <= 0x7E, z == 0x00 {
                    nameChars.append(b)
                    j += 2
                } else {
                    break
                }
            }

            let name = String(bytes: nameChars, encoding: .ascii) ?? ""
            guard !name.isEmpty else { break }

            records.append(CfgRecord(name: name, span: span, dataOffset: dataOffset))
            offset += Self.recordSpacing
        }

        return records
    }

    /// A single `[ADDRESS]` + `[PARAM_xx]` block from the embedded INI.
    private struct ParamBlock {
        let address: UInt32?
        let params: [CfgParameter]
    }

    /// Splits the embedded-INI tokens into `[ADDRESS]`-delimited blocks and parses
    /// each as an independent INI. This prevents the duplicate `[PARAM_01..NN]`
    /// section names that recur in every Family B block from colliding inside a
    /// single IniDocument.
    private func parseParamBlocks(tokens: [Token]) -> [ParamBlock] {
        let blockStarts = tokens.indices.filter { tokens[$0].value == "[ADDRESS]" }
        guard !blockStarts.isEmpty else { return [] }

        var blocks: [ParamBlock] = []
        for (i, start) in blockStarts.enumerated() {
            let end = (i + 1 < blockStarts.count) ? blockStarts[i + 1] : tokens.count
            let iniText = tokens[start..<end].map(\.value).joined(separator: "\r\n")
            let ini = IniParser.parse(text: iniText)
            let address = parseAddress(from: ini.section("ADDRESS")["VALUE"])
            blocks.append(ParamBlock(address: address, params: parseParams(from: ini)))
        }
        return blocks
    }

    /// Classifies a param block by the parameter names it carries. The cfg
    /// embeds no per-block item-name header, so a block's role is inferred from
    /// its content — mirroring how the Windows host selects which block to
    /// download before each named item (confirmed via USB capture on RK3288:
    /// Init got the controller block, ChangeFreq the freq block, memTest the
    /// test-config block). Content classification also generalizes across the
    /// different per-SoC param schemas (RK3288 PHY vs RK3368 TEST_TYPE vs
    /// Family A DDR geometry).
    private enum ParamBlockKind {
        case ddrInit        // Family A: DDR geometry (DDR_Type / die_bit_width / die_cap)
        case controller     // Family B RK3288-style: PHY driver/ODT/RTT
        case scanLimit      // cross-talk / scan limits (max/min limit, loop)
        case memTestConfig  // memTest config (Test Size, Write/Read Freq, ...)
        case memTestLoop    // march-style loops (Mem Test Loop, Stuck Address, ...)
        case freq           // frequency-only (small block, ChangeFreq)
        case testConfig     // TEST_TYPE / SR_Time / CheckCap (init or suspend)
        case unknown
    }

    private func classify(block: ParamBlock) -> ParamBlockKind {
        let names = block.params.map { $0.name.lowercased() }
        func has(_ needle: String) -> Bool { names.contains { $0.contains(needle) } }
        if has("ddr_type") || has("die_bit") || has("die_cap")
            || has("cs0_bit") || has("cs0_cap") || has("cs0_die") {
            return .ddrInit
        }
        if has("driver") && (has("odt") || has("rtt") || has("pull_up")) {
            return .controller
        }
        if has("max limit") || has("min limit") {
            return .scanLimit
        }
        if has("test size") || (has("write freq") && has("read freq")) {
            return .memTestConfig
        }
        if has("mem test loop") || has("stuck address") || has("random value") || has("compare xor") {
            return .memTestLoop
        }
        if block.params.count <= 2 && has("freq") {
            return .freq
        }
        if has("test_type") || has("sr_time") || has("checkcap") {
            return .testConfig
        }
        return .unknown
    }

    /// Builds test items from records, attaching each `[ADDRESS]` param block to
    /// the item whose role matches the block's classified content. Verified
    /// against a captured Windows run (RK3288 board-stability 528 MHz):
    /// Init←controller(5p), ChangeFreq←freq(1p, value 528), memTest←test-config
    /// (21p); DiagonalScan/CrossTalk received none. For schemas without a PHY
    /// block (RK3368 TEST_TYPE-style) Init takes the test-config block; Family A
    /// cfgs assign their single DDR-geometry block to the lone init/forceinit.
    private func buildItems(from records: [CfgRecord], paramBlocks: [ParamBlock]) -> [CfgItem] {
        let kinds = paramBlocks.map { classify(block: $0) }
        var used = Array(repeating: false, count: paramBlocks.count)
        func take(_ kind: ParamBlockKind) -> ParamBlock? {
            for i in paramBlocks.indices where !used[i] && kinds[i] == kind {
                used[i] = true
                return paramBlocks[i]
            }
            return nil
        }
        func takeAny(_ ks: [ParamBlockKind]) -> ParamBlock? {
            for k in ks { if let b = take(k) { return b } }
            return nil
        }
        func takeFirstUnused() -> ParamBlock? {
            for i in paramBlocks.indices where !used[i] {
                used[i] = true
                return paramBlocks[i]
            }
            return nil
        }

        let lower = records.map { $0.name.lowercased() }
        var blockFor = [Int: ParamBlock]()
        for ri in records.indices.dropFirst() {  // skip Boot
            let n = lower[ri]
            var block: ParamBlock? = nil
            if n.contains("init") {
                // Init/ForceInit: PHY controller config, else DDR geometry,
                // else TEST_TYPE config, else (Family A fallback) any block.
                block = takeAny([.controller, .ddrInit, .testConfig]) ?? takeFirstUnused()
            } else if n.contains("changefreq") {
                block = take(.freq)
            } else if n.contains("memtest") {
                block = take(.memTestConfig) ?? take(.memTestLoop)
            } else if n.contains("march") {
                block = take(.memTestLoop) ?? take(.memTestConfig)
            } else if n.contains("crosstalk") || n.contains("scan") || n.contains("diagonal") {
                block = take(.scanLimit)
            } else if n.contains("suspend") || n.contains("sr_test") || n.contains("dietest") {
                block = take(.testConfig)
            }
            if let b = block { blockFor[ri] = b }
        }

        return records.enumerated().map { (idx, rec) in
            let block = blockFor[idx]
            return CfgItem(
                name: rec.name,
                pathHint: nil,
                nameOffset: 0,
                payloadOffset: rec.dataOffset,
                payloadLength: rec.span,
                paramAddress: block?.address,
                params: block?.params ?? []
            )
        }
    }

    // MARK: - Payload Extraction with RC4

    private func extractPayloads(data: Data, records: [CfgRecord]) -> [String: Data] {
        var bins: [String: Data] = [:]

        for record in records {
            let lower = record.name.lowercased()
            let start = record.dataOffset
            let isBoot = lower == "boot"

            // Boot payload is exactly the recorded span. Verified against a
            // captured Windows run: the bootrom receives the loader zero-padded
            // to a 2048-byte multiple by the transport, not an oversized read.
            // (The previous "read into the next item's area" heuristic sent
            // thousands of garbage bytes and broke RC4 SoCs like RK3288.)
            let length = record.span

            let end = min(start + length, data.count)
            guard start < end else { continue }

            let rawPayload = data[start..<end]
            let payload: Data

            if isBoot {
                payload = Data(rawPayload)
            } else {
                payload = RC4.cipher(key: RC4.rockchipKey, data: Data(rawPayload))
            }

            if !payload.isEmpty {
                bins[record.name] = payload
            }
        }

        return bins
    }

    // MARK: - Address Parsing

    private func parseDownloadBaseAddress(from data: Data) -> UInt32 {
        let offset = 0x5B6
        guard data.count >= offset + 4 else { return Self.defaultDownloadBaseAddress }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return value != 0 ? value : Self.defaultDownloadBaseAddress
    }

    private func parseAddress(from value: String?) -> UInt32? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        return UInt32(trimmed)
    }

    // MARK: - Parameter Parsing

    private func parseParams(from ini: IniDocument) -> [CfgParameter] {
        var result: [CfgParameter] = []

        for (sectionName, values) in ini.sections {
            guard sectionName.uppercased().hasPrefix("PARAM_") else {
                continue
            }
            let idxString = sectionName.split(separator: "_").last.map(String.init) ?? "0"
            let index = Int(idxString) ?? 0
            let inputType = CfgParamInputType(rawValue: (values["INPUTTYPE"] ?? "").uppercased()) ?? .unknown
            let parameter = CfgParameter(
                index: index,
                section: sectionName,
                name: values["NAME"] ?? sectionName,
                inputType: inputType,
                value: values["VALUE"] ?? "",
                unit: values["UNIT"] ?? "",
                inputRange: values["INPUTRANGE"],
                inputRangeName: values["INPUTRANGENAME"],
                inputRangeValue: values["INPUTRANGEVALUE"]
            )
            result.append(parameter)
        }

        return result.sorted { lhs, rhs in
            if lhs.index == rhs.index {
                return lhs.section < rhs.section
            }
            return lhs.index < rhs.index
        }
    }

    // MARK: - UTF-16 Token Extraction

    private struct Token {
        let value: String
        let start: Int
        let end: Int
    }

    private func extractUTF16ASCIITokens(from data: Data) -> [Token] {
        let bytes = [UInt8](data)
        var tokens: [Token] = []
        var index = 0

        while index + 1 < bytes.count {
            let byte = bytes[index]
            let zero = bytes[index + 1]
            if byte >= 0x20 && byte <= 0x7E && zero == 0x00 {
                let start = index
                var cursor = index
                var stringBytes: [UInt8] = []

                while cursor + 1 < bytes.count {
                    let c = bytes[cursor]
                    let z = bytes[cursor + 1]
                    if c >= 0x20 && c <= 0x7E && z == 0x00 {
                        stringBytes.append(c)
                        cursor += 2
                    } else {
                        break
                    }
                }

                if stringBytes.count >= 4 {
                    let value = String(bytes: stringBytes, encoding: .ascii) ?? ""
                    tokens.append(Token(value: value, start: start, end: cursor))
                    index = cursor
                    continue
                }
            }
            index += 1
        }

        return tokens
    }
}
