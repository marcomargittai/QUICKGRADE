import XCTest
@testable import QuickGradeCore

final class ShelfSelectionTests: XCTestCase {
    func testShelfNameKeepsJPEGAndPNG() {
        XCTAssertEqual(ImageKind.shelfSelectionName("photo.jpg"), "photo.jpg")
        XCTAssertEqual(ImageKind.shelfSelectionName("photo.JPEG"), "photo.JPEG")
        XCTAssertEqual(ImageKind.shelfSelectionName("photo.jfif"), "photo.jfif")
        XCTAssertEqual(ImageKind.shelfSelectionName("photo.png"), "photo.png")
    }

    func testBakSuffixMapsBackToShelfFile() {
        XCTAssertEqual(ImageKind.shelfSelectionName("photo.jpg.quickgrade-bak"), "photo.jpg")
        XCTAssertEqual(ImageKind.shelfSelectionName("photo.PNG.QUICKGRADE-BAK"), "photo.PNG")
        XCTAssertNil(ImageKind.shelfSelectionName("notes.pdf.quickgrade-bak"))
        XCTAssertNil(ImageKind.shelfSelectionName("notes.pdf"))
        XCTAssertNil(ImageKind.shelfSelectionName("photo"))
    }

    func testWriteExtensionDoesNotTurnJPEGIntoPNG() {
        XCTAssertEqual(ImageKind.shelfWriteExtension("jpeg"), "jpeg")
        XCTAssertEqual(ImageKind.shelfWriteExtension(".JPG"), "jpg")
        XCTAssertEqual(ImageKind.shelfWriteExtension("png"), "png")
        XCTAssertNil(ImageKind.shelfWriteExtension("heic"))
        XCTAssertNil(ImageKind.shelfWriteExtension(""))
    }

    func testShelfFileFindsPhotoWhenNameHasBakSuffix() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-shelf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.jpg")
        try Data("jpeg".utf8).write(to: photo)
        let found = ImageKind.shelfFile(matching: "photo.jpg.quickgrade-bak", in: folder)
        XCTAssertEqual(found?.lastPathComponent, "photo.jpg")
        XCTAssertTrue(ImageKind.opensInShelf(photo))
        XCTAssertNil(ImageKind.shelfFile(matching: "notes.pdf", in: folder))
    }
}
