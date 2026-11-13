import XCTest
@testable import CloudHubCore

final class BrowserRulesTests: XCTestCase {
    func testFailureOutranksEverything() {
        XCTAssertEqual(browserState(load: .failed, hasEntries: true, hasVisible: true, filtering: false), .error)
    }

    func testRefreshKeepsContent() {
        XCTAssertEqual(browserState(load: .loading, hasEntries: true, hasVisible: true, filtering: false), .content)
        XCTAssertEqual(browserState(load: .loading, hasEntries: false, hasVisible: false, filtering: false), .skeleton)
    }

    func testEmptyIsNotNoMatches() {
        XCTAssertEqual(browserState(load: .ready, hasEntries: false, hasVisible: false, filtering: false), .empty)
        XCTAssertEqual(browserState(load: .ready, hasEntries: true, hasVisible: false, filtering: true), .noMatches)
    }

    func testSkeletonLinger() {
        XCTAssertEqual(SkeletonTiming.lingerMs(shownForMs: 100), 300)
        XCTAssertEqual(SkeletonTiming.lingerMs(shownForMs: 900), 0)
    }
}

final class SearchRulesTests: XCTestCase {
    func testMinimumLength() {
        XCTAssertFalse(SearchRules.canSearch(" a "))
        XCTAssertTrue(SearchRules.canSearch("ab"))
    }

    func testContinuesOnlyWhileGettingFurther() {
        let more = SearchResult(incomplete: true, scanned: 50)
        XCTAssertTrue(SearchRules.shouldContinue(more, scannedBefore: 10, slicesSoFar: 1))
        XCTAssertFalse(SearchRules.shouldContinue(more, scannedBefore: 50, slicesSoFar: 1))
        XCTAssertFalse(SearchRules.shouldContinue(more, scannedBefore: 10, slicesSoFar: SearchRules.maxSlices))
        XCTAssertFalse(SearchRules.shouldContinue(SearchResult(incomplete: false, scanned: 50), scannedBefore: 10, slicesSoFar: 1))
    }

    func testNoMatchesOnlyOnceFinished() {
        XCTAssertTrue(SearchRules.summary(query: "x", count: 0, truncated: false, scanned: 0, searching: true, error: nil).hasPrefix("Searching"))
        XCTAssertEqual(SearchRules.summary(query: "x", count: 1, truncated: false, scanned: 0, searching: false, error: nil), "1 match in all folders")
        XCTAssertTrue(SearchRules.summary(query: "x", count: 0, truncated: true, scanned: 900, searching: false, error: nil).contains("first 900 files"))
        XCTAssertEqual(SearchRules.summary(query: "x", count: 0, truncated: false, scanned: 0, searching: false, error: "down"), "Search failed: down")
    }
}

final class ViewerRulesTests: XCTestCase {
    let photos = [entry("a.jpg"), entry("b.jpg"), entry("c.jpg")]

    func testCounter() {
        XCTAssertNil(ViewerRules.counter(index: 0, count: 1))
        XCTAssertEqual(ViewerRules.counter(index: 2, count: 12), "3 of 12")
        XCTAssertEqual(ViewerRules.counter(index: 40, count: 12), "12 of 12")
    }

    func testPageAfterRemoval() {
        XCTAssertEqual(ViewerRules.pageAfterRemoval(index: 1, remaining: 2), 1)
        XCTAssertEqual(ViewerRules.pageAfterRemoval(index: 2, remaining: 2), 1)
        XCTAssertEqual(ViewerRules.pageAfterRemoval(index: 0, remaining: 0), 0)
    }

    func testRestoredGoesBackWhereItWas() {
        let without = ViewerRules.without(photos, path: "/b.jpg")
        XCTAssertEqual(ViewerRules.restored(without, photos[1], at: 1).map(\.name), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(ViewerRules.restored(photos, photos[1], at: 0).count, 3)
    }

    func testRenamedOutOfBeingAPhotoLeaves() {
        XCTAssertEqual(ViewerRules.renamed(photos, old: photos[0], newPath: "/a.txt", newName: "a.txt").map(\.name), ["b.jpg", "c.jpg"])
        XCTAssertEqual(ViewerRules.renamed(photos, old: photos[0], newPath: "/z.png", newName: "z.png").map(\.name), ["z.png", "b.jpg", "c.jpg"])
    }
}

final class FavoriteRulesTests: XCTestCase {
    func testFilters() {
        let items = [entry("a.jpg"), entry("b.mp4"), entry("c.pdf"), entry("d.heic")]
        let counts = FavoriteRules.counts(items)
        XCTAssertEqual(counts[.all], 4)
        XCTAssertEqual(counts[.photos], 2)
        XCTAssertEqual(counts[.videos], 1)
        XCTAssertEqual(counts[.other], 1)
        XCTAssertEqual(FavoriteRules.effective(.videos, [entry("a.jpg")]), .all)
    }

    func testNewStarGoesFirst() {
        let list = [entry("a.jpg"), entry("b.jpg")]
        XCTAssertEqual(FavoriteRules.afterToggle(list, entry("c.jpg"), starred: true).map(\.name), ["c.jpg", "a.jpg", "b.jpg"])
        XCTAssertEqual(FavoriteRules.afterToggle(list, entry("a.jpg"), starred: false).map(\.name), ["b.jpg"])
    }
}

final class SubtitleRulesTests: XCTestCase {
    func testNames() {
        XCTAssertTrue(SubtitleRules.isSubtitleFile("x.SRT"))
        XCTAssertFalse(SubtitleRules.isSubtitleFile("x.txt"))
        XCTAssertEqual(SubtitleRules.guessLanguage("The.Film.2024.1080p.WEB-DL.nl.srt"), "nl")
        XCTAssertEqual(SubtitleRules.guessLanguage("The.Film.WEB-DL.srt"), "")
        XCTAssertEqual(SubtitleRules.guessLanguage("film.srt"), "")
        XCTAssertEqual(SubtitleRules.fileName(forVideo: "Holiday.mp4", language: " NL ", extension: ".SRT"), "Holiday.nl.srt")
        XCTAssertEqual(SubtitleRules.fileName(forVideo: "Holiday.mp4", language: "", extension: "vtt"), "Holiday.vtt")
    }
}

final class DownloadRulesTests: XCTestCase {
    func testFreeName() {
        var taken: Set<String> = ["photo.jpg", "photo (1).jpg"]
        XCTAssertEqual(DownloadRules.freeName("photo.jpg") { taken.contains($0) }, "photo (2).jpg")
        XCTAssertEqual(DownloadRules.freeName("new.jpg") { taken.contains($0) }, "new.jpg")
        taken = [".profile"]
        XCTAssertEqual(DownloadRules.freeName(".profile") { taken.contains($0) }, ".profile (1)")
        XCTAssertEqual(DownloadRules.safeName("/a/b/"), "b")
        XCTAssertEqual(DownloadRules.safeName("  "), "download")
    }
}

final class ResumePolicyTests: XCTestCase {
    func testEnds() {
        XCTAssertFalse(ResumePolicy.shouldResume(positionMs: 5_000, durationMs: 600_000))
        XCTAssertTrue(ResumePolicy.shouldResume(positionMs: 60_000, durationMs: 600_000))
        XCTAssertFalse(ResumePolicy.shouldResume(positionMs: 590_000, durationMs: 600_000))
        XCTAssertTrue(ResumePolicy.shouldResume(positionMs: 60_000, durationMs: 0))
    }

    func testPrefsPruneAndForget() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        for i in 0..<(ResumePolicy.maxRemembered + 5) { prefs.rememberResumePosition("/v\(i).mp4", ms: 20_000) }
        XCTAssertEqual(prefs.rememberedPositionCount, ResumePolicy.maxRemembered)
        XCTAssertEqual(prefs.resumePosition(of: "/v0.mp4"), 0, "the oldest went first")
        XCTAssertEqual(prefs.resumePosition(of: "/v204.mp4"), 20_000)
        prefs.forgetResumePosition("/v204.mp4")
        XCTAssertEqual(prefs.resumePosition(of: "/v204.mp4"), 0)
    }

    func testTapZones() {
        XCTAssertEqual(zoneAt(x: 10, width: 100), .seekBack)
        XCTAssertEqual(zoneAt(x: 50, width: 100), .middle)
        XCTAssertEqual(zoneAt(x: 90, width: 100), .seekForward)
        XCTAssertEqual(zoneAt(x: 90, width: 0), .middle)
    }
}

final class StorageMeterTests: XCTestCase {
    func testQuotaOutranksStoreOutranksDisk() {
        XCTAssertEqual(StorageMeter.of(usedBytes: 5, quotaBytes: 10, storeUsedBytes: 50, storeLimitBytes: 100, diskFreeBytes: 0, diskTotalBytes: 1000).against, .quota)
        XCTAssertEqual(StorageMeter.of(usedBytes: 5, quotaBytes: 0, storeUsedBytes: 50, storeLimitBytes: 100, diskFreeBytes: 0, diskTotalBytes: 1000).against, .store)
        let disk = StorageMeter.of(usedBytes: 5, quotaBytes: 0, storeUsedBytes: 50, storeLimitBytes: 0, diskFreeBytes: 50, diskTotalBytes: 1000)
        XCTAssertEqual(disk.against, .disk)
        XCTAssertEqual(disk.usedBytes, 950)
        XCTAssertTrue(disk.nearlyFull)
    }

    func testNoNegativesNoNaN() {
        let over = StorageMeter.of(usedBytes: 20, quotaBytes: 10, storeUsedBytes: 0, storeLimitBytes: 0, diskFreeBytes: 0, diskTotalBytes: 0)
        XCTAssertEqual(over.remainingBytes, 0)
        XCTAssertEqual(over.fraction, 1)
        let nothing = StorageMeter.of(usedBytes: 0, quotaBytes: 0, storeUsedBytes: 0, storeLimitBytes: 0, diskFreeBytes: 0, diskTotalBytes: 0)
        XCTAssertEqual(nothing.fraction, 0)
    }
}

final class PhotoFactsTests: XCTestCase {
    func testWording() {
        XCTAssertEqual(PhotoFacts.dimensions(width: 4032, height: 3024), "4032 × 3024 · 12.2 MP")
        XCTAssertNil(PhotoFacts.dimensions(width: 0, height: 3))
        XCTAssertEqual(PhotoFacts.taken("2024:05:17 14:03:22"), "2024-05-17 14:03")
        XCTAssertNil(PhotoFacts.taken("0000:00:00 00:00:00"))
        XCTAssertNil(PhotoFacts.taken("   "))
        XCTAssertEqual(PhotoFacts.camera(make: "Canon", model: "Canon EOS R6"), "Canon EOS R6")
        XCTAssertEqual(PhotoFacts.camera(make: "Google", model: "Pixel 8"), "Google Pixel 8")
        XCTAssertEqual(PhotoFacts.camera(make: "Apple", model: nil), "Apple")
        XCTAssertEqual(PhotoFacts.exposure(fNumber: 1.8, seconds: 1.0 / 120, iso: 50, focalMm: 6.9), "f/1.8 · 1/120 s · ISO 50 · 6.9 mm")
        XCTAssertEqual(PhotoFacts.exposure(fNumber: 2.0, seconds: 1.5, iso: nil, focalMm: 50), "f/2 · 1.5 s · 50 mm")
        XCTAssertNil(PhotoFacts.exposure(fNumber: nil, seconds: nil, iso: nil, focalMm: nil))
    }

    func testBytes() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(1536), "1.5 KB")
        XCTAssertEqual(Format.bytes(150 * 1024 * 1024), "150 MB")
        XCTAssertEqual(Format.time(milliseconds: 3_723_000), "1:02:03")
        XCTAssertEqual(Format.time(milliseconds: 65_000), "1:05")
    }
}

final class WebVTTTests: XCTestCase {
    func testParseAndLookup() {
        let source = """
        WEBVTT

        NOTE a comment

        1
        00:00:01.000 --> 00:00:02.500 align:start
        <i>Hello</i> &amp; welcome

        00:03.000 --> 00:04.000
        Second
        line
        """
        let cues = WebVTT.parse(source)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello & welcome")
        XCTAssertEqual(cues[1].text, "Second\nline")
        XCTAssertEqual(WebVTT.cue(at: 1.5, in: cues)?.text, "Hello & welcome")
        XCTAssertNil(WebVTT.cue(at: 2.7, in: cues))
        XCTAssertEqual(WebVTT.cue(at: 3.2, in: cues)?.text, "Second\nline")
        XCTAssertEqual(WebVTT.seconds("01:02:03,500"), 3723.5)
    }
}

final class DuplicateRulesTests: XCTestCase {
    let group = DuplicateGroup(bytes: 100, count: 3, reclaimable: 200, files: [
        DuplicateFile(path: "/b/x.jpg", bytes: 100, mtime: 20),
        DuplicateFile(path: "/a/x.jpg", bytes: 100, mtime: 10),
        DuplicateFile(path: "/c/x.jpg", bytes: 100, mtime: 10),
    ], kind: nil)

    func testOldestIsKeptAndTiesBreakOnPath() {
        XCTAssertEqual(DuplicateRules.keeper(for: group, chosen: nil), "/a/x.jpg")
        XCTAssertEqual(DuplicateRules.keeper(for: group, chosen: "/c/x.jpg"), "/c/x.jpg")
        XCTAssertEqual(DuplicateRules.keeper(for: group, chosen: "/nope"), "/a/x.jpg")
        XCTAssertEqual(DuplicateRules.removable(group, chosen: nil), ["/b/x.jpg", "/c/x.jpg"])
    }

    func testNeverEmptiesAGroup() {
        XCTAssertTrue(DuplicateRules.wouldEmptyAGroup([group], Set(group.files.map(\.path))))
        XCTAssertFalse(DuplicateRules.wouldEmptyAGroup([group], ["/b/x.jpg", "/c/x.jpg"]))
    }

    func testWithoutDropsSingletons() {
        let scan = DuplicateScan(done: true, groups: [group])
        let after = DuplicateRules.without(scan, removed: ["/b/x.jpg"])
        XCTAssertEqual(after.groups.first?.count, 2)
        XCTAssertEqual(after.reclaimable, 100)
        XCTAssertTrue(DuplicateRules.without(scan, removed: ["/b/x.jpg", "/c/x.jpg"]).groups.isEmpty)
    }

    func testKindsAndProgress() {
        XCTAssertEqual(DuplicateRules.kindOf(group), .photos)
        XCTAssertEqual(DuplicateRules.kindOf(DuplicateGroup(files: [DuplicateFile(path: "/a.mov")])), .videos)
        XCTAssertEqual(DuplicateRules.kindOf(DuplicateGroup(files: [DuplicateFile(path: "/a.heic")], kind: "document")), .other)
        XCTAssertNil(DuplicateRules.progress(DuplicateScan(toHash: 0)))
        XCTAssertEqual(DuplicateRules.progress(DuplicateScan(hashed: 5, toHash: 10)), 0.5)
        XCTAssertEqual(DuplicateRules.freed(by: [group], selected: ["/b/x.jpg"]), 100)
    }
}

final class UploadMathTests: XCTestCase {
    func testPacing() {
        XCTAssertEqual(UploadPacing.chunkBytes(serverChunkBytes: 8 << 20, mediaOnScreen: false), 2 << 20)
        XCTAssertEqual(UploadPacing.chunkBytes(serverChunkBytes: 8 << 20, mediaOnScreen: true), 256 << 10)
        XCTAssertEqual(UploadPacing.chunkBytes(serverChunkBytes: 100, mediaOnScreen: false), 100)
        XCTAssertEqual(UploadPacing.chunkBytes(serverChunkBytes: 0, mediaOnScreen: false), 1 << 20)
        // While watching, well under an 8 Mbit link (1 MB/s).
        XCTAssertLessThan(UploadPacing.approximateRate(serverChunkBytes: 8 << 20, mediaOnScreen: true), 1_000_000 / 4)
    }

    func testProgressNeverGoesBackwards() {
        let a = QueuedUpload(id: "a", name: "a", stagedName: "a", targetPath: "/", size: 100)
        let b = QueuedUpload(id: "b", name: "b", stagedName: "b", targetPath: "/", size: 300)
        var total = UploadProgress.batchTotal(previous: 0, remainingBytes: 400)
        let first = UploadProgress.summarise(remaining: [a, b], currentId: "a", currentSent: 50, batchTotal: total)
        XCTAssertEqual(first.fraction, 50.0 / 400, accuracy: 0.0001)
        total = UploadProgress.batchTotal(previous: total, remainingBytes: 300)
        let second = UploadProgress.summarise(remaining: [b], currentId: "b", currentSent: 0, batchTotal: total)
        XCTAssertEqual(second.fraction, 100.0 / 400, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(second.fraction, first.fraction)
        XCTAssertEqual(UploadProgress.summarise(remaining: [], currentId: nil, currentSent: 0, batchTotal: 400).finished, true)
    }

    func testStagingSpace() {
        XCTAssertTrue(StagingSpace.hasRoom(freeBytes: 1 << 30, neededBytes: 100 << 20))
        XCTAssertFalse(StagingSpace.hasRoom(freeBytes: 100 << 20, neededBytes: 90 << 20))
        XCTAssertTrue(StagingSpace.hasRoom(freeBytes: 100 << 20, neededBytes: -1))
    }
}
