import Foundation
import XCTest
@testable import CommonClipboard

final class PasteItemStoreTests: XCTestCase {
    func testStorePersistsItemsAndOrder() throws {
        let fileURL = temporaryFileURL()
        let store = PasteItemStore(fileURL: fileURL)

        let first = try XCTUnwrap(store.add(text: "第一条"))
        let second = try XCTUnwrap(store.add(text: "第二条"))
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let reloadedStore = PasteItemStore(fileURL: fileURL)

        XCTAssertEqual(reloadedStore.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloadedStore.items.map(\.order), [0, 1])
        XCTAssertEqual(reloadedStore.items.map(\.text), ["第二条", "第一条"])
    }

    func testEmptyTextCannotBeSaved() {
        let store = PasteItemStore(fileURL: temporaryFileURL())

        XCTAssertNil(store.add(text: " \n\t "))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testUpdateAndDelete() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let item = try XCTUnwrap(store.add(text: "原始文本"))

        XCTAssertTrue(store.update(id: item.id, text: "更新后的文本"))
        XCTAssertEqual(store.items.first?.text, "更新后的文本")

        XCTAssertTrue(store.delete(id: item.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLegacyItemsAreMigratedToTheDefaultTag() throws {
        let fileURL = temporaryFileURL()
        let legacyItem = LegacyPasteItem(id: UUID(), text: "旧格式文本", order: 0)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode([legacyItem]).write(to: fileURL)

        let store = PasteItemStore(fileURL: fileURL)

        XCTAssertEqual(store.tags.count, 1)
        XCTAssertEqual(store.tags.first?.id, PasteTag.defaultID)
        XCTAssertEqual(store.items(for: PasteTag.defaultID).map(\.text), ["旧格式文本"])
        XCTAssertEqual(store.items.first?.tagID, PasteTag.defaultID)

        let reloadedStore = PasteItemStore(fileURL: fileURL)
        XCTAssertEqual(reloadedStore.items(for: PasteTag.defaultID).map(\.text), ["旧格式文本"])
    }

    func testTagOperationsPersistOrderAndMoveDeletedItemsToDefault() throws {
        let fileURL = temporaryFileURL()
        let store = PasteItemStore(fileURL: fileURL)
        let defaultItem = try XCTUnwrap(store.add(text: "默认文本"))
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        _ = try XCTUnwrap(store.addTag(name: "个人"))
        _ = try XCTUnwrap(store.add(text: "工作第一条", to: workTag.id))
        let workSecondItem = try XCTUnwrap(store.add(text: "工作第二条", to: workTag.id))

        store.moveTags(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, in: workTag.id)

        let reloadedStore = PasteItemStore(fileURL: fileURL)
        XCTAssertEqual(reloadedStore.tags.map(\.name), ["默认", "个人", "工作"])
        XCTAssertEqual(
            reloadedStore.items(for: workTag.id).map(\.text),
            ["工作第二条", "工作第一条"]
        )

        XCTAssertFalse(reloadedStore.deleteTag(id: PasteTag.defaultID))
        XCTAssertTrue(reloadedStore.deleteTag(id: workTag.id))
        XCTAssertEqual(
            reloadedStore.items(for: PasteTag.defaultID).map(\.id),
            [defaultItem.id, workSecondItem.id, reloadedStore.items.first(where: { $0.text == "工作第一条" })?.id].compactMap { $0 }
        )
    }

    func testDuplicateOrEmptyTagNamesCannotBeSaved() {
        let store = PasteItemStore(fileURL: temporaryFileURL())

        XCTAssertNil(store.addTag(name: "  "))
        XCTAssertNil(store.addTag(name: "默认"))
        XCTAssertNotNil(store.addTag(name: "工作"))
        XCTAssertNil(store.addTag(name: " 工作 "))
    }

    func testRenamingTagKeepsItemsAndRejectsInvalidNames() throws {
        let fileURL = temporaryFileURL()
        let store = PasteItemStore(fileURL: fileURL)

        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let workItem = try XCTUnwrap(store.add(text: "工作文本", to: workTag.id))

        XCTAssertFalse(store.renameTag(id: workTag.id, name: "   "))
        XCTAssertFalse(store.renameTag(id: workTag.id, name: " 默认 "))
        XCTAssertFalse(store.renameTag(id: UUID(), name: "不存在"))

        // Renaming to its own name (or a different letter case) stays allowed.
        XCTAssertTrue(store.renameTag(id: workTag.id, name: "工作"))
        XCTAssertTrue(store.renameTag(id: workTag.id, name: " 公司 "))
        XCTAssertTrue(store.renameTag(id: PasteTag.defaultID, name: "收件箱"))

        let reloadedStore = PasteItemStore(fileURL: fileURL)
        XCTAssertEqual(reloadedStore.tags.map(\.name), ["收件箱", "公司"])
        XCTAssertEqual(reloadedStore.items(for: workTag.id).map(\.id), [workItem.id])
    }

    func testMoveItemToAnotherTag() throws {
        let fileURL = temporaryFileURL()
        let store = PasteItemStore(fileURL: fileURL)

        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let personalTag = try XCTUnwrap(store.addTag(name: "个人"))
        let item1 = try XCTUnwrap(store.add(text: "工作第一条", to: workTag.id))
        let item2 = try XCTUnwrap(store.add(text: "工作第二条", to: workTag.id))
        let personalItem = try XCTUnwrap(store.add(text: "个人第一条", to: personalTag.id))

        XCTAssertTrue(store.moveItem(withID: item1.id, toTagID: personalTag.id))

        // After moving item1 to personalTag, workTag should only have item2 (order 0),
        // and personalTag should have personalItem (order 0) and item1 (order 1).
        XCTAssertEqual(store.items(for: workTag.id).map(\.id), [item2.id])
        XCTAssertEqual(store.items(for: workTag.id).map(\.order), [0])
        XCTAssertEqual(store.items(for: personalTag.id).map(\.id), [personalItem.id, item1.id])
        XCTAssertEqual(store.items(for: personalTag.id).map(\.order), [0, 1])

        let reloadedStore = PasteItemStore(fileURL: fileURL)
        XCTAssertEqual(reloadedStore.items(for: workTag.id).map(\.id), [item2.id])
        XCTAssertEqual(reloadedStore.items(for: personalTag.id).map(\.id), [personalItem.id, item1.id])
    }

    func testUpdateItemTextAndTag() throws {
        let fileURL = temporaryFileURL()
        let store = PasteItemStore(fileURL: fileURL)

        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let personalTag = try XCTUnwrap(store.addTag(name: "个人"))
        let item = try XCTUnwrap(store.add(text: "原始工作文本", to: workTag.id))

        XCTAssertTrue(store.update(id: item.id, text: "修改后的个人文本", tagID: personalTag.id))

        XCTAssertEqual(store.items(for: workTag.id), [])
        XCTAssertEqual(store.items(for: personalTag.id).map(\.text), ["修改后的个人文本"])
        XCTAssertEqual(store.items(for: personalTag.id).map(\.tagID), [personalTag.id])

        let reloadedStore = PasteItemStore(fileURL: fileURL)
        XCTAssertEqual(reloadedStore.items(for: personalTag.id).map(\.text), ["修改后的个人文本"])
    }

    func testMoveItemToNonExistentTagFails() throws {
        let fileURL = temporaryFileURL()
        let store = PasteItemStore(fileURL: fileURL)
        let item = try XCTUnwrap(store.add(text: "默认文本"))

        XCTAssertFalse(store.moveItem(withID: item.id, toTagID: UUID()))
        XCTAssertFalse(store.moveItem(withID: UUID(), toTagID: PasteTag.defaultID))
        XCTAssertEqual(store.items(for: PasteTag.defaultID).map(\.id), [item.id])
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CommonClipboardTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }
}

private struct LegacyPasteItem: Codable {
    let id: UUID
    let text: String
    let order: Int
}
