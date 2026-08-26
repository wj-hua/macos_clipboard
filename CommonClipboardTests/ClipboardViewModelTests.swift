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

    func testCopyWorksWithoutAccessibilityPermissionOrTargetApplication() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let item = try XCTUnwrap(store.add(text: "无需权限的复制文本"))
        let service = MockPasteService()
        service.isTrusted = false
        let viewModel = ClipboardViewModel(store: store, pasteService: service)
        viewModel.selectedItemID = item.id

        XCTAssertTrue(viewModel.copySelectedItem())
        XCTAssertEqual(service.copiedTexts, [item.text])
        XCTAssertEqual(service.pasteCallCount, 0)
        XCTAssertFalse(viewModel.isShowingPermission)
    }

    func testCopyingItemByIDSelectsAndCopiesThatItem() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        _ = try XCTUnwrap(store.add(text: "第一条"))
        let second = try XCTUnwrap(store.add(text: "第二条"))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        XCTAssertTrue(viewModel.copyItem(withID: second.id))
        XCTAssertEqual(viewModel.selectedItemID, second.id)
        XCTAssertEqual(service.copiedTexts, [second.text])
    }

    func testDoubleClickCopyPreferencePersistsAndCopies() throws {
        let suiteName = "ClipboardViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PasteItemStore(fileURL: temporaryFileURL())
        let item = try XCTUnwrap(store.add(text: "双击复制"))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(
            store: store,
            pasteService: service,
            userDefaults: defaults
        )
        viewModel.doubleClickAction = .copy

        XCTAssertTrue(viewModel.performDoubleClickAction(on: item.id))
        XCTAssertEqual(service.copiedTexts, [item.text])
        XCTAssertEqual(service.pasteCallCount, 0)

        let reloadedViewModel = ClipboardViewModel(
            store: store,
            pasteService: service,
            userDefaults: defaults
        )
        XCTAssertEqual(reloadedViewModel.doubleClickAction, .copy)
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

    func testRenamingTagKeepsSelectionAndUpdatesTagNames() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let workItem = try XCTUnwrap(store.add(text: "工作文本", to: workTag.id))
        let service = MockPasteService()
        let viewModel = ClipboardViewModel(store: store, pasteService: service)

        viewModel.selectTag(withID: workTag.id)
        XCTAssertTrue(viewModel.renameTag(id: workTag.id, name: "公司"))

        XCTAssertEqual(viewModel.tags.map(\.name), ["默认", "公司"])
        XCTAssertEqual(viewModel.selectedTagID, workTag.id)
        XCTAssertEqual(viewModel.items.map(\.id), [workItem.id])
        XCTAssertEqual(viewModel.tagName(for: workItem), "公司")

        XCTAssertFalse(viewModel.renameTag(id: workTag.id, name: "默认"))
        XCTAssertEqual(viewModel.tags.map(\.name), ["默认", "公司"])
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

    func testSearchFiltersCurrentTagUsingEveryTermAndIgnoresCase() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let matchingItem = try XCTUnwrap(store.add(text: "GitHub Student Account"))
        _ = try XCTUnwrap(store.add(text: "GitHub personal account"))
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        _ = try XCTUnwrap(store.add(text: "GitHub Student Account", to: workTag.id))
        let viewModel = ClipboardViewModel(store: store, pasteService: MockPasteService())

        viewModel.searchText = "student github"

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [matchingItem.id])
        XCTAssertEqual(viewModel.selectedItemID, matchingItem.id)
    }

    func testAllTagsSearchIncludesMatchingItemsAndExposesTheirTagNames() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let defaultItem = try XCTUnwrap(store.add(text: "学校邮箱"))
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let workItem = try XCTUnwrap(store.add(text: "工作邮箱", to: workTag.id))
        let viewModel = ClipboardViewModel(store: store, pasteService: MockPasteService())

        viewModel.searchScope = .allTags
        viewModel.searchText = "邮箱"

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [defaultItem.id, workItem.id])
        XCTAssertEqual(viewModel.tagName(for: defaultItem), "默认")
        XCTAssertEqual(viewModel.tagName(for: workItem), "工作")
    }

    func testChangingSearchKeepsSelectionInsideVisibleResults() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let first = try XCTUnwrap(store.add(text: "Apple ID"))
        let second = try XCTUnwrap(store.add(text: "学校邮箱"))
        let viewModel = ClipboardViewModel(store: store, pasteService: MockPasteService())

        viewModel.selectedItemID = first.id
        viewModel.searchText = "邮箱"

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [second.id])
        XCTAssertEqual(viewModel.selectedItemID, second.id)

        viewModel.searchText = "不存在"
        XCTAssertTrue(viewModel.visibleItems.isEmpty)
        XCTAssertNil(viewModel.selectedItemID)
    }

    func testKeyboardSelectionAndNumberPasteUseFilteredResults() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        _ = try XCTUnwrap(store.add(text: "忽略"))
        let firstMatch = try XCTUnwrap(store.add(text: "邮箱一"))
        let secondMatch = try XCTUnwrap(store.add(text: "邮箱二"))
        let service = MockPasteService()
        service.isTrusted = true
        let viewModel = ClipboardViewModel(store: store, pasteService: service)
        viewModel.prepareForPresentation(targetApplication: NSRunningApplication.current)
        viewModel.searchText = "邮箱"

        XCTAssertEqual(viewModel.selectedItemID, firstMatch.id)
        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemID, secondMatch.id)

        XCTAssertTrue(viewModel.pasteItem(at: 0))
        XCTAssertEqual(viewModel.selectedItemID, firstMatch.id)
        XCTAssertEqual(service.pastedTexts, [firstMatch.text])
    }

    func testClearSearchReportsWhetherAQueryWasCleared() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let item = try XCTUnwrap(store.add(text: "常用文本"))
        let viewModel = ClipboardViewModel(store: store, pasteService: MockPasteService())

        XCTAssertFalse(viewModel.clearSearch())

        viewModel.searchText = "没有结果"
        XCTAssertNil(viewModel.selectedItemID)
        XCTAssertTrue(viewModel.clearSearch())
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.selectedItemID, item.id)
        XCTAssertFalse(viewModel.clearSearch())
    }

    func testMoveItemUpdatesItemsAndSelection() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let defaultItem1 = try XCTUnwrap(store.add(text: "默认第一条"))
        let defaultItem2 = try XCTUnwrap(store.add(text: "默认第二条"))
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let viewModel = ClipboardViewModel(store: store, pasteService: MockPasteService())

        viewModel.refreshFromStore()
        viewModel.selectedItemID = defaultItem1.id

        XCTAssertTrue(viewModel.moveItem(withID: defaultItem1.id, toTagID: workTag.id))

        // In current tag (默认), defaultItem1 is gone, so items should only contain defaultItem2,
        // and selectedItemID should switch to defaultItem2.
        XCTAssertEqual(viewModel.items.map(\.id), [defaultItem2.id])
        XCTAssertEqual(viewModel.selectedItemID, defaultItem2.id)

        // Switching to workTag shows defaultItem1
        viewModel.selectTag(withID: workTag.id)
        XCTAssertEqual(viewModel.items.map(\.id), [defaultItem1.id])
        XCTAssertEqual(viewModel.selectedItemID, defaultItem1.id)
    }

    func testDraftTagSelectionWhenAddingAndEditing() throws {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        let defaultItem = try XCTUnwrap(store.add(text: "默认文本"))
        let workTag = try XCTUnwrap(store.addTag(name: "工作"))
        let workItem = try XCTUnwrap(store.add(text: "工作文本", to: workTag.id))
        let viewModel = ClipboardViewModel(store: store, pasteService: MockPasteService())

        // 1. When adding in current tag (defaultTag), draftTagID defaults to defaultTag.
        viewModel.selectTag(withID: PasteTag.defaultID)
        viewModel.beginAdding()
        XCTAssertEqual(viewModel.draftTagID, PasteTag.defaultID)

        // User can change draftTagID to workTag and save.
        viewModel.draftText = "新建并选择工作标签"
        viewModel.draftTagID = workTag.id
        viewModel.saveDraft()

        XCTAssertEqual(store.items(for: workTag.id).map(\.text), ["工作文本", "新建并选择工作标签"])
        XCTAssertEqual(store.items(for: PasteTag.defaultID).map(\.text), ["默认文本"])

        // 2. When editing an item, draftTagID starts as that item's tagID.
        viewModel.beginEditing(item: workItem)
        XCTAssertEqual(viewModel.draftTagID, workTag.id)

        // User switches tag to default tag and saves.
        viewModel.draftTagID = PasteTag.defaultID
        viewModel.saveDraft()

        XCTAssertEqual(store.items(for: workTag.id).map(\.text), ["新建并选择工作标签"])
        XCTAssertEqual(store.items(for: PasteTag.defaultID).map(\.text), ["默认文本", "工作文本"])
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
    var copiedTexts: [String] = []

    func isAccessibilityTrusted() -> Bool {
        isTrusted
    }

    func requestAccessibilityPermission() {
        permissionRequestCount += 1
    }

    func openAccessibilitySettings() {}

    func copy(text: String) -> Bool {
        copiedTexts.append(text)
        return true
    }

    func paste(text: String, into application: NSRunningApplication) {
        pasteCallCount += 1
        pastedTexts.append(text)
    }
}
