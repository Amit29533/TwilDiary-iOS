import XCTest
@testable import TwilDiary

/// Settings → Customise: orders and hidden sections as they're saved and read back.
final class CustomiseTests: XCTestCase {
    func testAnEmptySettingIsTheOriginalLayout() {
        let home = HomeSection.layout("")
        XCTAssertEqual(home.order, HomeSection.allCases.map(\.rawValue))
        XCTAssertTrue(home.hidden.isEmpty)
    }
    func testYourOrderAndHiddenSectionsComeBack() {
        var home = HomeSection.layout("")
        home.order.move(fromOffsets: IndexSet(integer: 7), toOffset: 0)   // Recently watched to the top
        home.hidden = ["favourites"]
        let read = HomeSection.layout(home.text)
        XCTAssertEqual(read.order.first, "recent")
        XCTAssertEqual(read.visible.contains("favourites"), false)
    }
    func testASectionAnUpdateAddsJoinsAtTheEndAndUnknownOnesAreDropped() {
        let read = SectionOrder("b,ghost,a|ghost", all: ["a", "b", "c"])
        XCTAssertEqual(read.order, ["b", "a", "c"])
        XCTAssertTrue(read.hidden.isEmpty)
    }
    func testTheShortcutsAndTheMainTabsAlwaysShow() {
        XCTAssertTrue(HomeSection.layout("|shortcuts,week").visible.contains("shortcuts"), "Explore & Canvas can't be hidden")
        XCTAssertFalse(HomeSection.layout("|shortcuts,week").visible.contains("week"))
        let tabs = TabLayout.layout("more,home,library,search,glance|glance,library")
        XCTAssertEqual(tabs.visible, ["more", "home", "library", "search"], "only Glance can be hidden; your order is kept")
    }
    func testPosterSizesAcross() {
        XCTAssertEqual(PosterSize.compact.columns, 4)
        XCTAssertEqual(PosterSize.regular.columns, 3)
        XCTAssertEqual(PosterSize.large.columns, 2)
    }
}
