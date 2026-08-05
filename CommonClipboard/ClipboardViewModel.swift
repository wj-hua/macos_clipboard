import AppKit
import Combine
import Foundation

final class ClipboardViewModel: ObservableObject {
    enum Mode: Equatable {
        case list
        case editor
    }

    @Published private(set) var tags: [PasteTag]
    @Published private(set) var items: [PasteItem]
    @Published var selectedTagID: UUID?
    @Published var selectedItemID: UUID?
    @Published private(set) var mode: Mode = .list
    @Published var draftText = ""
    @Published private(set) var editingItemID: UUID?
    @Published var isShowingPermission = false
    @Published var alertMessage: String?

    private let store: PasteItemStore
    private let pasteService: PasteService
    private var targetApplication: NSRunningApplication?

    init(store: PasteItemStore, pasteService: PasteService) {
        self.store = store
        self.pasteService = pasteService
        self.tags = store.tags
        let initialTagID = store.tags.first?.id ?? PasteTag.defaultID
        self.selectedTagID = initialTagID
        self.items = store.items(for: initialTagID)
        self.selectedItemID = self.items.first?.id
    }

    var isEditingExistingItem: Bool {
        editingItemID != nil
    }

    var canSaveDraft: Bool {
        PasteItemStore.isValidText(draftText)
    }

    func prepareForPresentation(targetApplication: NSRunningApplication?) {
        self.targetApplication = targetApplication
        mode = .list
        editingItemID = nil
        draftText = ""
        isShowingPermission = false
        alertMessage = nil
        refreshFromStore()
        selectedItemID = items.first?.id
    }

    func refreshFromStore() {
        store.reload()
        tags = store.tags

        if let selectedTagID, tags.contains(where: { $0.id == selectedTagID }) {
            self.selectedTagID = selectedTagID
        } else {
            self.selectedTagID = tags.first?.id
        }

        items = selectedTagID.map(store.items(for:)) ?? []

        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) {
            return
        }
        self.selectedItemID = items.first?.id
    }

    func dismiss() {
        mode = .list
        editingItemID = nil
        draftText = ""
        isShowingPermission = false
        alertMessage = nil
        targetApplication = nil
    }

    func beginAdding() {
        mode = .editor
        editingItemID = nil
        draftText = ""
        alertMessage = nil
    }

    func beginEditingSelectedItem() {
        guard let selectedItem = selectedItem else { return }

        mode = .editor
        editingItemID = selectedItem.id
        draftText = selectedItem.text
        alertMessage = nil
    }

    func cancelEditing() {
        mode = .list
        editingItemID = nil
        draftText = ""
        alertMessage = nil
    }

    func selectTag(withID tagID: UUID) {
        guard tags.contains(where: { $0.id == tagID }) else { return }

        selectedTagID = tagID
        items = store.items(for: tagID)
        selectedItemID = items.first?.id
    }

    func moveTagSelection(by offset: Int) {
        guard let selectedTagID,
              let currentIndex = tags.firstIndex(where: { $0.id == selectedTagID }) else {
            guard let firstTag = tags.first else { return }
            selectTag(withID: firstTag.id)
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), tags.count - 1)
        guard nextIndex != currentIndex else { return }

        selectTag(withID: tags[nextIndex].id)
    }

    @discardableResult
    func addTag(name: String) -> Bool {
        guard let tag = store.addTag(name: name) else { return false }

        tags = store.tags
        selectedTagID = tag.id
        items = store.items(for: tag.id)
        selectedItemID = nil
        return true
    }

    @discardableResult
    func deleteTag(id: UUID) -> Bool {
        guard store.deleteTag(id: id) else { return false }

        tags = store.tags
        if selectedTagID == id {
            selectedTagID = PasteTag.defaultID
        } else if !tags.contains(where: { $0.id == selectedTagID }) {
            selectedTagID = tags.first?.id
        }
        items = selectedTagID.map(store.items(for:)) ?? []
        selectedItemID = items.first?.id
        return true
    }

    func moveTags(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        store.moveTags(fromOffsets: offsets, toOffset: destination)
        tags = store.tags
    }

    func saveDraft() {
        guard canSaveDraft else { return }

        if let editingItemID {
            guard store.update(id: editingItemID, text: draftText) else { return }
            selectedItemID = editingItemID
        } else if let newItem = store.add(text: draftText, to: selectedTagID ?? PasteTag.defaultID) {
            selectedItemID = newItem.id
        } else {
            return
        }

        refreshFromStore()
        mode = .list
        self.editingItemID = nil
        draftText = ""
    }

    @discardableResult
    func deleteSelectedItem() -> Bool {
        guard let selectedItemID else { return false }

        let deleted = store.delete(id: selectedItemID)
        guard deleted else { return false }

        refreshFromStore()
        return true
    }

    func moveItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        store.move(
            fromOffsets: offsets,
            toOffset: destination,
            in: selectedTagID ?? PasteTag.defaultID
        )
        items = selectedTagID.map(store.items(for:)) ?? []
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }

        selectedItemID = items[index].id
    }

    @discardableResult
    func pasteItem(at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }

        selectedItemID = items[index].id
        return pasteSelectedItem()
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }

        guard let selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = items.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        self.selectedItemID = items[nextIndex].id
    }

    @discardableResult
    func pasteSelectedItem() -> Bool {
        guard let selectedItem else { return false }

        guard pasteService.isAccessibilityTrusted() else {
            isShowingPermission = true
            return false
        }

        guard let targetApplication else {
            alertMessage = "没有找到需要粘贴的目标应用。请从其他应用中按 Option + 空格 打开。"
            return false
        }

        pasteService.paste(text: selectedItem.text, into: targetApplication)
        return true
    }

    /// Selects the tapped item and sends it through the same paste path as Return.
    /// Keeping selection and paste together prevents a double-click from pasting
    /// the item that was selected before the click.
    @discardableResult
    func pasteItem(withID itemID: UUID) -> Bool {
        guard items.contains(where: { $0.id == itemID }) else { return false }

        selectedItemID = itemID
        return pasteSelectedItem()
    }

    func requestAccessibilityPermission() {
        pasteService.requestAccessibilityPermission()
    }

    func openAccessibilitySettings() {
        pasteService.openAccessibilitySettings()
    }

    func dismissPermissionNotice() {
        isShowingPermission = false
    }

    @discardableResult
    func refreshAccessibilityPermission() -> Bool {
        let isTrusted = pasteService.isAccessibilityTrusted()
        if isTrusted {
            isShowingPermission = false
        }
        return isTrusted
    }

    private var selectedItem: PasteItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }
}
