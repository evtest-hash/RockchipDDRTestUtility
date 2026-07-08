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

    private static func intValue(_ item: CfgItem, _ name: String) -> Int? {
        item.params.first { ($0.name.isEmpty ? $0.section : $0.name) == name }
            .flatMap { Int($0.value) }
    }

    /// 从 cfg `forceinit` 参数取 CS0 的位宽键。仅支持 `cs*_` 参数 schema
    /// (RK3568&RK3566 等)；缺 `cs0_bit_width`/`cs0_die_bit_width`（如 RK3288 的
    /// `cha/chb` schema）返回 nil —— 调用方据此回退手动，绝不误判。
    /// 映射（真实 cfg + 硬件实采验证）：die = 8<<(enum-1)；bus = 8<<enum。
    public static func widthKey(fromForceinit item: CfgItem) -> WidthKey? {
        guard let dieEnum = intValue(item, "cs0_die_bit_width"), dieEnum >= 1,
              let busEnum = intValue(item, "cs0_bit_width"), busEnum >= 1 else { return nil }
        return WidthKey(busWidthBits: 8 << busEnum,
                        dieWidthBits: 8 << (dieEnum - 1))
    }

    public static func widthKey(fromDecoded ch: ChannelGeometry) -> WidthKey {
        WidthKey(busWidthBits: ch.busWidthBits, dieWidthBits: ch.dieWidthBits)
    }
}
