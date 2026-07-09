import XCTest
@testable import DDRCore

final class EyescanBinSelectTests: XCTestCase {
    func testD3LP3Family() {
        XCTAssertEqual(eyescanFamily(for: .ddr3), .d3lp3)
        XCTAssertEqual(eyescanFamily(for: .lpddr3), .d3lp3)
    }
    func testD4LP4Family() {
        XCTAssertEqual(eyescanFamily(for: .ddr4), .d4lp4)
        XCTAssertEqual(eyescanFamily(for: .lpddr4), .d4lp4)
        XCTAssertEqual(eyescanFamily(for: .lpddr4x), .d4lp4)
    }
}
