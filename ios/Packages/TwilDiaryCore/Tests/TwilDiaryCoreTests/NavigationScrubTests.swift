import Testing
@testable import TwilDiaryCore

@Test func navigationScrubFindsEveryTabAcrossPhoneWidthsAndClampsThePreview() {
    for width in [296.0, 351, 366, 378, 416] {
        let cell = (width - 8) / 5
        for index in 0..<5 {
            #expect(NavigationScrub.index(x: 4 + cell * (Double(index) + 0.5), width: width) == index)
        }
        #expect(NavigationScrub.index(x: -100, width: width) == 0)
        #expect(NavigationScrub.index(x: width + 100, width: width) == 4)
        #expect(NavigationScrub.index(x: width - 4, width: width) == 4)
    }
}
@Test func navigationScrubCancelsOutsideTheBarInsteadOfCommittingAnEdgeTab() {
    #expect(NavigationScrub.acceptsRelease(x: 170, y: 30, width: 378, height: 65))
    #expect(NavigationScrub.acceptsRelease(x: 0, y: -24, width: 378, height: 65))
    #expect(!NavigationScrub.acceptsRelease(x: -1, y: 30, width: 378, height: 65))
    #expect(!NavigationScrub.acceptsRelease(x: 379, y: 30, width: 378, height: 65))
    #expect(!NavigationScrub.acceptsRelease(x: 170, y: -25, width: 378, height: 65))
    #expect(!NavigationScrub.acceptsRelease(x: 170, y: 90, width: 378, height: 65))
}
@Test func navigationScrubRejectsInvalidGeometryAndCountsBeforeIntegerConversion() {
    #expect(NavigationScrub.index(x: .nan, width: 378) == nil)
    #expect(NavigationScrub.index(x: .infinity, width: 378) == nil)
    #expect(NavigationScrub.index(x: 10, width: 8) == nil)
    #expect(NavigationScrub.index(x: 10, width: .infinity) == nil)
    #expect(NavigationScrub.index(x: 10, width: 378, count: 0) == nil)
    #expect(NavigationScrub.index(x: 10, width: 378, count: .max) == nil)
    #expect(!NavigationScrub.acceptsRelease(x: .nan, y: 30, width: 378, height: 65))
}
