import AppKit
import Foundation
import XCTest
@testable import CommonClipboard

final class ClipboardViewModelTests: XCTestCase {
    func testArrowSelectionWrapsAtListBoundaries() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let first = try XCTUnwrap(store.add(text: "第一条"))
        let second = try XCTUnwrap(store.add(text: "第二条"))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.refreshFromStore()
        viewModel.selectedItemID = first.id
        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedItemID, second.id)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemID, first.id)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemID, second.id)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemID, first.id)
    }

    func testArrowSelectionSwitchesTagsAndWrapsAtTagBoundaries() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let defaultItem = try XCTUnwrap(store.add(text: "默认文本"))
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let workItem = try XCTUnwrap(store.add(text: "工作文本", to: workTag.id))
        let personalTag = try XCTUnwrap(store.addTag(name: "个人"))
        let personalItem = try XCTUnwrap(store.add(text: "个人文本", to: personalTag.id))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.moveTagSelection(by: -1)
        XCTAssertEqual(viewModel.selectedTagID, personalTag.id)
        XCTAssertEqual(viewModel.selectedItemID, personalItem.id)

        viewModel.moveTagSelection(by: 1)
        XCTAssertEqual(viewModel.selectedTagID, PasteTag.defaultID)
        XCTAssertEqual(viewModel.selectedItemID, defaultItem.id)

        viewModel.moveTagSelection(by: 1)
        XCTAssertEqual(viewModel.selectedTagID, workTag.id)
        XCTAssertEqual(viewModel.selectedItemID, workItem.id)

        viewModel.moveTagSelection(by: 1)
        XCTAssertEqual(viewModel.selectedTagID, personalTag.id)
        XCTAssertEqual(viewModel.selectedItemID, personalItem.id)

        viewModel.moveTagSelection(by: 1)
        XCTAssertEqual(viewModel.selectedTagID, PasteTag.defaultID)
        XCTAssertEqual(viewModel.selectedItemID, defaultItem.id)

        viewModel.moveTagSelection(by: -1)
        XCTAssertEqual(viewModel.selectedTagID, personalTag.id)
        XCTAssertEqual(viewModel.selectedItemID, personalItem.id)
    }

    func testSelectItemByIndexSelectsTheCorrespondingItem() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let first = try XCTUnwrap(store.add(text: "第一条"))
        let second = try XCTUnwrap(store.add(text: "第二条"))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.selectItem(at: 1)
        XCTAssertEqual(viewModel.selectedItemID, second.id)

        viewModel.selectItem(at: 0)
        XCTAssertEqual(viewModel.selectedItemID, first.id)
    }

    func testSelectItemByIndexIgnoresOutOfRangeIndex() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let first = try XCTUnwrap(store.add(text: "第一条"))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.selectItem(at: 3)

        XCTAssertEqual(viewModel.selectedItemID, first.id)
    }

    func testPastingItemByIndexSelectsAndPastesTheNinthItem() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let items = try (1...9).map { index in
            try XCTUnwrap(store.add(text: "第\(index)条"))
        }
        let service = MockPasteService()
        service.isTrusted = true
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.prepareForPresentation(targetApplication: NSRunningApplication.current)

        XCTAssertTrue(viewModel.pasteItem(at: 8))
        XCTAssertEqual(viewModel.selectedItemID, items[8].id)
        XCTAssertEqual(service.pastedTexts, [items[8].text])
    }

    func testReturnDoesNotPasteWithoutAccessibilityPermission() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let item = try XCTUnwrap(store.add(text: "需要权限的文本"))
        let service = MockPasteService()
        service.isTrusted = false
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.refreshFromStore()
        viewModel.selectedItemID = item.id

        XCTAssertFalse(viewModel.pasteSelectedItem())
        XCTAssertTrue(viewModel.isShowingPermission)
        XCTAssertEqual(service.pasteCallCount, 0)
        XCTAssertEqual(service.permissionRequestCount, 0)
    }

    func testReturnPastesWhenPermissionIsGranted() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let item = try XCTUnwrap(store.add(text: "可以粘贴的文本"))
        let service = MockPasteService()
        service.isTrusted = true
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.prepareForPresentation(targetApplication: NSRunningApplication.current)
        viewModel.selectedItemID = item.id

        XCTAssertTrue(viewModel.pasteSelectedItem())
        XCTAssertEqual(service.pasteCallCount, 1)
    }

    func testPastingItemByIDSelectsAndPastesThatItem() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let first = try XCTUnwrap(store.add(text: "第一条"))
        let second = try XCTUnwrap(store.add(text: "第二条"))
        let service = MockPasteService()
        service.isTrusted = true
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.prepareForPresentation(targetApplication: NSRunningApplication.current)
        viewModel.selectedItemID = first.id

        XCTAssertTrue(viewModel.pasteItem(withID: second.id))
        XCTAssertEqual(viewModel.selectedItemID, second.id)
        XCTAssertEqual(service.pasteCallCount, 1)
        XCTAssertEqual(service.pastedTexts, [second.text])
    }

    func testRefreshPermissionClosesNoticeAfterPermissionIsGranted() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.isShowingPermission = true
        service.isTrusted = true

        XCTAssertTrue(viewModel.refreshAccessibilityPermission())
        XCTAssertFalse(viewModel.isShowingPermission)
    }

    func testSelectingTagShowsOnlyItsItemsAndNewDraftUsesSelectedTag() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        _ = try XCTUnwrap(store.add(text: "默认文本"))
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let workItem = try XCTUnwrap(store.add(text: "工作文本", to: workTag.id))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.selectTag(withID: workTag.id)

        XCTAssertEqual(viewModel.items.map(\.id), [workItem.id])
        XCTAssertEqual(viewModel.selectedTagID, workTag.id)

        viewModel.beginAdding()
        viewModel.draftText = "新工作文本"
        viewModel.saveDraft()

        XCTAssertEqual(viewModel.items.map(\.text), ["工作文本", "新工作文本"])
        XCTAssertEqual(store.items(for: workTag.id).map(\.text), ["工作文本", "新工作文本"])
        XCTAssertEqual(store.items(for: PasteTag.defaultID).map(\.text), ["默认文本"])
    }

    func testDeletingSelectedTagFallsBackToDefaultTag() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        _ = try XCTUnwrap(store.add(text: "工作文本", to: workTag.id))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.selectTag(withID: workTag.id)
        XCTAssertTrue(viewModel.deleteTag(id: workTag.id))

        XCTAssertEqual(viewModel.selectedTagID, PasteTag.defaultID)
        XCTAssertEqual(viewModel.items.map(\.text), ["工作文本"])
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CommonClipboardTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }
}

private final class MockPasteService: PasteService {
    var isTrusted = false
    var permissionRequestCount = 0
    var pasteCallCount = 0
    var pastedTexts: [String] = []

    func isAccessibilityTrusted() -> Bool {
        isTrusted
    }

    func requestAccessibilityPermission() {
        permissionRequestCount += 1
    }

    func openAccessibilitySettings() {}

    func paste(text: String, into application: NSRunningApplication) {
        pasteCallCount += 1
        pastedTexts.append(text)
    }
}
