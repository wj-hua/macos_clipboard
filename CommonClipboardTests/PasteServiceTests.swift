import AppKit
import Foundation
import XCTest
@testable import CommonClipboard

final class PasteboardSnapshotTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("CommonClipboardTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    func testRestoresPlainTextRichTextHTMLAndImageRepresentations() throws {
        let rtf = Data("{\\rtf1\\ansi 原始富文本}".utf8)
        let html = Data("<strong>原始富文本</strong>".utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let firstItem = NSPasteboardItem()
        _ = firstItem.setString("原始文本", forType: .string)
        _ = firstItem.setData(rtf, forType: .rtf)
        _ = firstItem.setData(html, forType: .html)
        _ = firstItem.setData(png, forType: .png)

        let secondItem = NSPasteboardItem()
        _ = secondItem.setString("第二个项目", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))

        let snapshot = ClipboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("常用文本", forType: .string))
        let injectedChangeCount = pasteboard.changeCount

        XCTAssertTrue(
            snapshot.restoreIfUnchanged(
                on: pasteboard,
                expectedChangeCount: injectedChangeCount
            )
        )

        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "原始文本")
        XCTAssertEqual(restoredItems[0].data(forType: .rtf), rtf)
        XCTAssertEqual(restoredItems[0].data(forType: .html), html)
        XCTAssertEqual(restoredItems[0].data(forType: .png), png)
        XCTAssertEqual(restoredItems[1].string(forType: .string), "第二个项目")
    }

    func testDoesNotRestoreAfterClipboardChanges() throws {
        let originalItem = NSPasteboardItem()
        _ = originalItem.setString("原始内容", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([originalItem]))

        let snapshot = ClipboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("常用文本", forType: .string))
        let injectedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("用户刚复制的内容", forType: .string))

        XCTAssertFalse(
            snapshot.restoreIfUnchanged(
                on: pasteboard,
                expectedChangeCount: injectedChangeCount
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "用户刚复制的内容")
    }
}

final class SystemPasteServiceIntegrationTests: XCTestCase {
    private var window: NSWindow?

    func testCommandVPastesCommonTextBeforeRestoringManualClipboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CommonClipboardIntegration-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let manualClipboardText = "选中后手动复制的内容"
        let commonText = "常用粘贴板中的内容"
        XCTAssertTrue(pasteboard.setString(manualClipboardText, forType: .string))

        let pasteExpectation = expectation(description: "目标文本框收到常用文本")
        let textView = PasteboardTestTextView(pasteboard: pasteboard) { pastedText in
            XCTAssertEqual(pastedText, commonText)
            pasteExpectation.fulfill()
        }
        textView.string = "选中的文本"
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(textView))

        let service = SystemPasteService(
            pasteboard: pasteboard,
            accessibilityTrustCheck: { true }
        )
        service.paste(text: commonText, into: NSRunningApplication.current)

        wait(for: [pasteExpectation], timeout: 2.0)

        let restoreExpectation = expectation(description: "剪贴板恢复手动复制内容")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            restoreExpectation.fulfill()
        }
        wait(for: [restoreExpectation], timeout: 1.5)

        XCTAssertEqual(textView.string, commonText)
        XCTAssertEqual(pasteboard.string(forType: .string), manualClipboardText)

        window.orderOut(nil)
        self.window = nil
    }
}

private final class PasteboardTestTextView: NSTextView {
    private let pasteboard: NSPasteboard
    private let onPaste: (String) -> Void

    init(pasteboard: NSPasteboard, onPaste: @escaping (String) -> Void) {
        self.pasteboard = pasteboard
        self.onPaste = onPaste

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 320, height: 120))
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 120), textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string) else { return }

        insertText(text, replacementRange: selectedRange())
        onPaste(text)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return super.performKeyEquivalent(with: event)
        }

        paste(nil)
        return true
    }
}
