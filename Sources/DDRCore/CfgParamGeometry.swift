import Foundation

/// 把 DDR 几何"位宽"从两个来源归一成同一个可比较的键：
/// - cfg 的 `forceinit` 参数（`cs0_bit_width` / `cs0_die_bit_width`，各为枚举，需换算成实际位数）；
/// - 探测解码出的 `ChannelGeometry`（已是实际位数）。
/// 仅用于 `CfgAutoSelect.tieBreak` 在同规格候选里做组内区分。
public enum CfgParamGeometry {

    public struct WidthKey: Equatable, Sendable {
        public let busWidthBits: Int
        public let dieWidthBits: Int
        public init(busWidthBits: Int, dieWidthBits: Int) {
            self.busWidthBits = busWidthBits
            self.dieWidthBits = dieWidthBits
        }
    }

    /// 从 cfg forceinit 参数取 CS0 的位宽键。位宽参数是 combo：value 是索引，
    /// 实际位数 = inputRangeValue 按 "|" 拆分后的第 index 项 —— 与引擎
    /// RkUsbTransportLibusb.resolveParamValue 写进硬件的口径完全一致（权威，非经验公式）。
    /// 缺参数、缺 inputRangeValue、索引越界、或值非整数 → 返回 nil（上层回退手动，绝不误判）。
    public static func widthKey(fromForceinit item: CfgItem) -> WidthKey? {
        guard let bus = resolvedComboInt(item, "cs0_bit_width"),
              let die = resolvedComboInt(item, "cs0_die_bit_width") else { return nil }
        return WidthKey(busWidthBits: bus, dieWidthBits: die)
    }

    /// Resolve a combo param to its actual integer value via inputRangeValue[index].
    /// Non-combo params resolve by parsing `value` directly.
    private static func resolvedComboInt(_ item: CfgItem, _ name: String) -> Int? {
        guard let p = item.params.first(where: { ($0.name.isEmpty ? $0.section : $0.name) == name }) else { return nil }
        switch p.inputType {
        case .combo:
            guard let rv = p.inputRangeValue else { return Int(p.value) }
            let opts = rv.split(separator: "|").map(String.init)
            guard let idx = Int(p.value), idx >= 0, idx < opts.count else { return nil }
            return Int(opts[idx])
        default:
            return Int(p.value)
        }
    }

    public static func widthKey(fromDecoded ch: ChannelGeometry) -> WidthKey {
        WidthKey(busWidthBits: ch.busWidthBits, dieWidthBits: ch.dieWidthBits)
    }
}
