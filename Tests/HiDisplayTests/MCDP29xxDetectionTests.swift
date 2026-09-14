import XCTest
@testable import HiDisplayKit

/// Covers the MCDP29xx bridge chip-address decision as a pure function, with no IORegistry lookup and
/// no hardware. Real detection reads `EPICProviderClass` off the parent of the bound
/// `DCPAVServiceProxy` (see `IORegistryAccess.parentStringProperty`), but that string is all the
/// decision actually depends on — so that is all this tests.
final class MCDP29xxDetectionTests: XCTestCase {

    func testProviderClassMatchingMCDP29xxUsesBridgeChipAddress() {
        let chip = AppleSiliconAVServiceTransport.chipAddress(forProviderClass: "AppleDCPMCDP29XX")
        XCTAssertEqual(chip, DDC.mcdp29xxChipAddress)
        XCTAssertEqual(chip, 0xB7)
    }

    func testUnrelatedProviderClassUsesDefaultChipAddress() {
        let chip = AppleSiliconAVServiceTransport.chipAddress(forProviderClass: "AppleCLCD2")
        XCTAssertEqual(chip, DDC.chipAddress)
        XCTAssertEqual(chip, 0x37)
    }

    func testAbsentProviderClassUsesDefaultChipAddress() {
        let chip = AppleSiliconAVServiceTransport.chipAddress(forProviderClass: nil)
        XCTAssertEqual(chip, DDC.chipAddress)
    }
}
