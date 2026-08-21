import AppKit
import SwiftUI
import XCTest
@testable import CommonClipboard

/// 把真实的 `ClipboardPanelView` 装进真实窗口，向按钮**边缘**（而不是图标/文字正中）投递合成
/// `NSEvent`，验证按钮的命中区域覆盖了整个视觉外形。
///
/// 背景：`.buttonStyle(.plain)` 的按钮，label 上的 `.frame(...)` 只撑开布局占位，命中测试只认
/// 实际绘制的像素。外层加在 `Button` 之外的 `Capsule` / `Circle` 背景不属于按钮的可点区域，
/// 于是圆形关闭按钮只有中间的 ✕ 笔画能点、标签胶囊只有图标和文字能点。修复方式是在 label 内部
/// 补 `.contentShape(...)`。这些用例点的就是修复前的死区。
final class PanelHitAreaTests: XCTestCase {
    private var window: NSWindow!
    private var recorder: DragRecorder!
    private var viewModel: ClipboardViewModel!
    private var panelHeight: CGFloat = 0
    private var eventNumber = 0

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        recorder = nil
        viewModel = nil
        super.tearDown()
    }

    // MARK: - 右上角关闭按钮

    /// 关闭按钮是 32×32、右边缘贴着 18pt 内边距，所以圆心在 (466, 25)、半径 16。
    /// (456, 16) 距圆心 13.5pt，稳稳在圆里，但离中间那个 11pt 的 ✕ 笔画很远。
    func testCloseButtonAcceptsClicksAwayFromTheGlyph() {
        var closeCount = 0
        showPanel(itemCount: 5, onClose: { closeCount += 1 })

        press(at: CGPoint(x: 456, y: 16))

        XCTAssertEqual(closeCount, 1, "关闭按钮圆形范围内的空白也要能点")
        XCTAssertEqual(recorder.count, 0, "关闭按钮不能被窗口拖动抢占")
    }

    /// 反向对照：命中区不能反过来溢出到按钮外面，否则标题栏就没法拖动窗口了。
    func testAreaLeftOfTheCloseButtonStillDragsTheWindow() {
        var closeCount = 0
        showPanel(itemCount: 5, onClose: { closeCount += 1 })

        // 关闭按钮左侧的标题栏空白。
        press(at: CGPoint(x: 443, y: 25))

        XCTAssertEqual(closeCount, 0, "按钮外面的空隙不该触发关闭")
        XCTAssertGreaterThan(recorder.count, 0, "按钮外面的空隙应该还能拖动窗口")
    }

    // MARK: - 标签胶囊

    /// 标签栏接在标题栏下面，内部上下各留 `verticalPadding`，胶囊高 `chipHeight`。
    /// 这些坐标一律从 `TagBarMetrics` 推出来，标签栏高度一变就跟着走，
    /// 不会像写死数字那样悄悄滑出「文字之外」的死区、让用例变成恒真。
    private var tagChipTop: CGFloat {
        ClipboardPanelView.listHeaderHeight + TagBarMetrics.verticalPadding
    }

    private var tagChipBottom: CGFloat {
        tagChipTop + TagBarMetrics.chipHeight
    }

    /// 12pt 文字的行框只占胶囊中间约 14pt，上下各剩约 8pt 空白——修复前那里是死区。
    /// 取距胶囊上缘 2pt，既在胶囊里，又在文字行框之外。
    func testTagChipAcceptsClicksAboveTheLabelText() {
        showPanel(itemCount: 5, extraTagNames: ["工作"])
        let workTagID = viewModel.tags.last?.id

        click(at: CGPoint(x: 120, y: tagChipTop + 2))

        XCTAssertEqual(viewModel.selectedTagID, workTagID, "标签胶囊上缘的空白也要能点")
        XCTAssertEqual(recorder.count, 0, "标签栏要保留长按拖动排序")
    }

    /// 同一颗胶囊的下缘。
    func testTagChipAcceptsClicksBelowTheLabelText() {
        showPanel(itemCount: 5, extraTagNames: ["工作"])
        let workTagID = viewModel.tags.last?.id

        click(at: CGPoint(x: 120, y: tagChipBottom - 2))

        XCTAssertEqual(viewModel.selectedTagID, workTagID, "标签胶囊下缘的空白也要能点")
        XCTAssertEqual(recorder.count, 0, "标签栏要保留长按拖动排序")
    }

    /// 反向对照：胶囊上方的标签栏空白不该被算成标签点击。
    func testAreaAboveTheTagChipDoesNotSelectTheTag() {
        showPanel(itemCount: 5, extraTagNames: ["工作"])
        let defaultTagID = viewModel.tags.first?.id

        click(at: CGPoint(x: 120, y: tagChipTop - 2))

        XCTAssertEqual(viewModel.selectedTagID, defaultTagID, "胶囊外面的空白不该切换标签")
    }

    // MARK: - Harness

    private func showPanel(
        itemCount: Int,
        extraTagNames: [String] = [],
        onClose: @escaping () -> Void = {}
    ) {
        let store = PasteItemStore(fileURL: temporaryFileURL())
        for index in 1...itemCount {
            _ = store.add(text: "常用文本 \(index)")
        }
        for name in extraTagNames {
            _ = store.addTag(name: name)
        }

        viewModel = ClipboardViewModel(store: store, pasteService: StubPasteService())

        let recorder = DragRecorder()
        self.recorder = recorder

        panelHeight = ClipboardPanelView.panelHeight(
            for: viewModel.items.count,
            tags: viewModel.tags,
            mode: viewModel.mode
        )

        window = TestPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ClipboardPanelView.panelWidth,
                height: panelHeight
            ),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.contentView = PanelHostingView(
            rootView: ClipboardPanelView(
                viewModel: viewModel,
                onClose: onClose,
                onWindowDragChanged: { recorder.count += 1 },
                onWindowDragEnded: {}
            )
        )
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // 见 PanelDragExclusionTests：这里使用与生产环境相同的 `PanelHostingView`，
        // 按钮命中测试本身则需要窗口处于 key 状态。
        window.becomeKey()

        pumpEvents(for: 0.8)
    }

    private func press(at panelPoint: CGPoint) {
        let moved = CGPoint(x: panelPoint.x + 2, y: panelPoint.y + 2)

        post(.leftMouseDown, at: panelPoint)
        post(.leftMouseDragged, at: moved)
        post(.leftMouseUp, at: moved)

        pumpEvents(for: 1.0)
    }

    /// 标签按钮带有拖拽排序手势，命中区域测试只投递一次完整单击。
    private func click(at panelPoint: CGPoint) {
        post(.leftMouseDown, at: panelPoint)
        post(.leftMouseUp, at: panelPoint)

        pumpEvents(for: 1.0)
    }

    private func post(_ type: NSEvent.EventType, at panelPoint: CGPoint) {
        eventNumber += 1

        // 面板坐标系原点在左上，窗口坐标系原点在左下。
        let locationInWindow = NSPoint(x: panelPoint.x, y: panelHeight - panelPoint.y)

        guard let event = NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            XCTFail("无法构造 \(type) 事件")
            return
        }

        NSApp.postEvent(event, atStart: false)
    }

    private func pumpEvents(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            guard let event = NSApp.nextEvent(
                matching: .any,
                until: deadline,
                inMode: .default,
                dequeue: true
            ) else {
                break
            }

            NSApp.sendEvent(event)
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CommonClipboardTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }
}

private final class TestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DragRecorder {
    var count = 0
}

private final class StubPasteService: PasteService {
    func isAccessibilityTrusted() -> Bool { true }
    func requestAccessibilityPermission() {}
    func openAccessibilitySettings() {}
    func copy(text: String) -> Bool { true }
    func paste(text: String, into application: NSRunningApplication) {}
}
