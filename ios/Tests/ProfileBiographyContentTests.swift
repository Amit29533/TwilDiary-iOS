import XCTest
@testable import TwilDiary

final class ProfileBiographyContentTests: XCTestCase {
    func testWebsiteOnlyLinesBecomeDeduplicatedIconsWithoutLosingBiography() {
        let value = ProfileBiographyContent(description: "**Agency:** Studio\n\n[Website](https://example.org) | [X](https://x.com/actor)\n[Again](https://x.com/actor)\n\nMember of [Blue Drops](https://example.org/duet).", hideSpoilers: true)
        XCTAssertEqual(value.links.count, 2)
        XCTAssertEqual(value.links.last?.asset, "site-x")
        XCTAssertTrue(value.markdown.contains("**Agency:** Studio"))
        XCTAssertTrue(value.markdown.contains("[Blue Drops](https://example.org/duet)"))
        XCTAssertFalse(value.markdown.contains("[Website]"))
        XCTAssertFalse(value.markdown.contains("[Again]"))
    }
    func testMultilineSpoilersCannotCreateVisibleWebsiteButtonsOrText() {
        let value = ProfileBiographyContent(description: "Public.\n\n~!Hidden\n[Secret](https://example.org/secret)\nspoiler.!~\n\nVisible.", hideSpoilers: true)
        XCTAssertTrue(value.links.isEmpty)
        XCTAssertEqual(value.markdown, "Public.\n\nVisible.")
        let revealed = ProfileBiographyContent(description: "~![Website](https://example.org)!~", hideSpoilers: false)
        XCTAssertEqual(revealed.links.count, 1)
    }
    func testInlineLinksStayInProseInsteadOfBeingRemovedAsWebsites() {
        let value = ProfileBiographyContent(description: "Read her [profile](https://example.org) for details.", hideSpoilers: true)
        XCTAssertTrue(value.links.isEmpty)
        XCTAssertEqual(value.markdown, "Read her [profile](https://example.org) for details.")
    }
    func testWebsiteIconsCheckWholeHostsAndRejectNonWebSchemes() {
        XCTAssertNil(ProfileWebsiteLink(url: URL(string: "javascript:alert(1)")!, title: "Bad"))
        XCTAssertNil(ProfileWebsiteLink(url: URL(string: "file:///secret")!, title: "Bad"))
        XCTAssertNil(ProfileWebsiteLink(url: URL(string: "/relative")!, title: "Bad"))
        XCTAssertNil(ProfileWebsiteLink(url: URL(string: "https://notyoutube.com")!, title: "Other")?.asset)
        XCTAssertEqual(ProfileWebsiteLink(url: URL(string: "https://www.youtube.com/@actor")!, title: "Video")?.asset, "site-youtube")
        XCTAssertEqual(ProfileWebsiteLink(url: URL(string: "https://instagram.com/actor")!, title: "Photo")?.label, "Instagram")
        XCTAssertEqual(ProfileWebsiteLink(url: URL(string: "https://anilist.co/staff/11")!, title: "Source")?.asset, "site-anilist")
    }
    func testEmptyAndLinkOnlyProfilesRemainUsable() {
        XCTAssertTrue(ProfileBiographyContent(description: "", hideSpoilers: true).markdown.isEmpty)
        let value = ProfileBiographyContent(description: "[Profile](https://example.org/profile)", hideSpoilers: true)
        XCTAssertTrue(value.markdown.isEmpty)
        XCTAssertEqual(value.links.first?.symbol, "person.crop.rectangle")
    }
    func testBirthdaysPreservePartialDatesAndLeapDaysWithoutInventingYears() {
        XCTAssertEqual(ProfileDate.short("29 May 1991"), "29 May 1991")
        XCTAssertEqual(ProfileDate.short("27 September"), "27 Sep")
        XCTAssertEqual(ProfileDate.short("29 February"), "29 Feb")
        XCTAssertEqual(ProfileDate.short("1991-05-29"), "29 May 1991")
        XCTAssertEqual(ProfileDate.short("Unknown"), "Unknown")
    }
}
