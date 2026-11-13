import XCTest
@testable import CloudHubCore

/// The same cases as the Android client's NaturalOrderTest, so both apps sort a folder alike.
final class NaturalOrderTests: XCTestCase {
    private func sorted(_ names: [String]) -> [String] { names.sorted(by: NaturalOrder.less) }

    private func assertOrder(_ expected: String..., file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sorted(expected), expected, file: file, line: line)
        XCTAssertEqual(sorted(expected.reversed()), expected, "reversed input", file: file, line: line)
        XCTAssertEqual(sorted(expected.shuffled()), expected, "shuffled input", file: file, line: line)
    }

    func testPlainNumbersCountUp() { assertOrder("1", "2", "3", "4", "5", "10", "11", "12") }

    func testANumberAfterAWordCountsUp() {
        assertOrder("File 1", "File 2", "File 3", "File 10", "File 11")
        assertOrder("Folder 2", "Folder 10")
    }

    func testANumberBeforeAnExtension() { assertOrder("Image 1.jpg", "Image 2.jpg", "Image 10.jpg") }

    func testDottedNumbersSectionBySection() {
        assertOrder("1.2.3", "1.2.4", "1.2.10")
        assertOrder("1.2.3", "1.10")
        assertOrder("v1.2.3.zip", "v1.2.10.zip", "v1.10.0.zip")
    }

    func testEveryNumberCounts() {
        assertOrder("Season 1 Episode 2", "Season 1 Episode 10", "Season 2 Episode 1", "Season 10 Episode 1")
        assertOrder("IMG_2024_1_9.jpg", "IMG_2024_1_10.jpg", "IMG_2024_2_1.jpg", "IMG_2024_10_1.jpg")
    }

    func testCaseInsensitiveLetters() { assertOrder("apple 2", "APPLE 3", "Apple 10", "banana 1", "Banana 2") }

    func testNumbersSitWhereTheyDoUnderName() { assertOrder("Track", "Track 1", "Track 2", "Track 10", "Track A", "TrackB") }

    func testShorterFirst() { assertOrder("Folder", "Folder 2", "Folder 10", "Folder 10 old") }

    func testOriginalBeforeItsCopy() {
        for copy in ["photo 2.jpg", "photo-2.jpg", "photo_2.jpg", "photo (2).jpg"] {
            XCTAssertEqual(sorted([copy, "photo.jpg"]), ["photo.jpg", copy], copy)
        }
        assertOrder("New Text Document.txt", "New Text Document (2).txt", "New Text Document (10).txt")
    }

    func testNumberBeforeExtension() {
        assertOrder("Image 2.png", "Image 10.jpg")
        assertOrder("Clip 9.mp4", "Clip 10.MOV", "Clip 11.avi")
    }

    func testSameNameByExtension() {
        assertOrder("notes", "notes.md", "notes.txt")
        assertOrder("report.DOCX", "report.pdf")
    }

    func testOnlyRealExtensionsAreSetAside() {
        assertOrder("Backup", "Backup.2023", "Backup.2024", "Backup.10000")
        assertOrder("Mr. Smith 2", "Mr. Smith 10")
        assertOrder(".hidden 2", ".hidden 10", ".nomedia")
        assertOrder("file 2.", "file 10.")
    }

    func testFewerLeadingZerosFirst() {
        assertOrder("File 1", "File 01", "File 001", "File 2", "File 02")
        assertOrder("7", "007", "08", "10")
    }

    func testUpperBeforeLower() {
        assertOrder("File 1", "file 1")
        assertOrder("IMG 1.JPG", "IMG 1.jpg", "img 1.jpg")
    }

    func testLettersOutrankZeros() { assertOrder("File 01 a", "File 1 b") }

    func testLongNumbersDoNotOverflow() {
        assertOrder("Serial 99999999999999999999", "Serial 100000000000000000000", "Serial 123456789012345678901234567890")
    }

    func testOtherScriptsDigitsStayText() {
        XCTAssertEqual(sorted(["file ٣", "file 20", "file 3"]), ["file 3", "file 20", "file ٣"])
    }

    func testEmptyNames() { assertOrder("", "0", "a") }

    func testTotalOrder() {
        let names = ["a", "A", "a1", "a01", "a 1", "a.b", "a.1", "1", "01", "", "b", "B 2", "b 10", "x.txt", "x.TXT"]
        for a in names {
            for b in names {
                let ab = NaturalOrder.compare(a, b)
                let ba = NaturalOrder.compare(b, a)
                XCTAssertEqual(ab == .orderedAscending, ba == .orderedDescending, "\(a) vs \(b)")
                XCTAssertEqual(a == b, ab == .orderedSame, "\(a) vs \(b)")
            }
        }
    }

    func testFoldersFirstUnderEverySort() {
        let items = [entry("b.jpg", size: 5, modified: "2024-01-02"), entry("A", dir: true), entry("a.jpg", size: 9, modified: "2024-01-01")]
        for sort in FileSort.allCases {
            XCTAssertTrue(sort.sorted(items)[0].isDirectory, "\(sort)")
        }
        XCTAssertEqual(FileSort.largest.sorted(items).map(\.name), ["A", "a.jpg", "b.jpg"])
        XCTAssertEqual(FileSort.newest.sorted(items).map(\.name), ["A", "b.jpg", "a.jpg"])
        XCTAssertEqual(FileSort.natural.sorted([entry("File 10"), entry("File 2")]).map(\.name), ["File 2", "File 10"])
        XCTAssertEqual(FileSort.name.sorted([entry("File 10"), entry("File 2")]).map(\.name), ["File 10", "File 2"])
    }
}
