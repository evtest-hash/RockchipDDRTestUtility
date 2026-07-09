public enum EyescanFamily: Equatable { case d3lp3, d4lp4 }

/// RK3568 eyescan bins split by DDR protocol family only (not size/CS):
///   *_D3_LP3_eyescan_*  → DDR3 / LPDDR3
///   *_D4_LP4_4x_eyescan_* → DDR4 / LPDDR4 / LPDDR4X
public func eyescanFamily(for type: DramType) -> EyescanFamily? {
    switch type {
    case .ddr3, .lpddr3: return .d3lp3
    case .ddr4, .lpddr4, .lpddr4x: return .d4lp4
    default: return nil
    }
}
