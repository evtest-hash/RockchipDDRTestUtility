import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public final class CfgBinaryParser {
    private static let cfgRC4Key = Data([
        0x7C, 0x4E, 0x03, 0x04, 0x55, 0x05, 0x09, 0x07,
        0x2D, 0x2C, 0x7B, 0x38, 0x17, 0x0D, 0x17, 0x11
    ])

    private static let recordSpacing = 0x2C3
    private static let firstRecordOffset = 0x41

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

        let iniText = configTokens.map(\.value).joined(separator: "\r\n")
        let ini = IniParser.parse(text: iniText)
        let address = parseAddress(from: ini.section("ADDRESS")["VALUE"])
        let params = parseParams(from: ini)

        let records = parseRecords(from: data)
        let items = buildItems(from: records)
        let bins = extractPayloads(data: data, records: records)
        let downloadBaseAddress = parseDownloadBaseAddress(from: data)

        return CfgTestPlan(
            sourcePath: sourcePath,
            address: address,
            downloadBaseAddress: downloadBaseAddress,
            items: items,
            params: params,
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

    private func buildItems(from records: [CfgRecord]) -> [CfgItem] {
        records.map { rec in
            CfgItem(
                name: rec.name,
                pathHint: nil,
                nameOffset: 0,
                payloadOffset: rec.dataOffset,
                payloadLength: rec.span
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

            // For boot, read beyond the recorded span.  The MASKROM expects
            // a payload that extends into the next item's encrypted data area.
            let length: Int
            if isBoot {
                // Use the gap to the second item's dataOffset, or a generous
                // minimum — whichever is larger.
                let gap: Int
                if records.count > 1 {
                    gap = records[1].dataOffset - start
                } else {
                    gap = record.span
                }
                length = max(record.span, gap, 10242)
            } else {
                length = record.span
            }

            let end = min(start + length, data.count)
            guard start < end else { continue }

            let rawPayload = data[start..<end]
            let payload: Data

            if isBoot {
                payload = Data(rawPayload)
            } else {
                payload = rc4Decrypt(key: Self.cfgRC4Key, data: Data(rawPayload))
            }

            if !payload.isEmpty {
                bins[record.name] = payload
            }
        }

        return bins
    }

    // MARK: - RC4

    private func rc4Decrypt(key: Data, data: Data) -> Data {
        var S = [UInt8](0...255)
        var j: UInt8 = 0
        for i in 0..<256 {
            j = j &+ S[i] &+ key[i % key.count]
            S.swapAt(i, Int(j))
        }

        var result = [UInt8](repeating: 0, count: data.count)
        var ii: UInt8 = 0
        var jj: UInt8 = 0
        for k in 0..<data.count {
            ii = ii &+ 1
            jj = jj &+ S[Int(ii)]
            S.swapAt(Int(ii), Int(jj))
            result[k] = data[k] ^ S[Int(S[Int(ii)] &+ S[Int(jj)])]
        }
        return Data(result)
    }

    // MARK: - Address Parsing

    private func parseDownloadBaseAddress(from data: Data) -> UInt32 {
        let offset = 0x5B6
        guard data.count >= offset + 4 else { return 0xFF00_4000 }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return value != 0 ? value : 0xFF00_4000
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
