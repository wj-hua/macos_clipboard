import AppKit
import SwiftUI
import XCTest
@testable import CommonClipboard

/// 把真实的 `ClipboardPanelView` 装进真实窗口，向窗口投递合成 `NSEvent`，
/// 验证「哪些区域会把按压交给窗口拖动」。
///
/// 事件走完整的 AppKit 事件队列 + 命中测试 + SwiftUI 手势链路，所以校验的是实际布局算出来的
/// 按钮 / 列表 / 编辑器位置，而不是测试里写死的坐标假设。每条「不该拖动」的用例同时断言对应
/// 控件真的收到了这次点击，避免变成「事件压根没送到」的空跑。
final class PanelDragExclusionTests: XCTestCase {
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

    /// 正向对照：没有它的话，下面所有「不该拖动」的用例都可能因为事件根本没送达而假通过。
    func testPressingBlankChromeHandsTheGestureToTheWindowDrag() {
        showPanel(itemCount: 5)

        // 标题栏里的空白，既不是按钮也不是列表。
        press(at: CGPoint(x: 210, y: 34))

        XCTAssertGreaterThan(recorder.count, 0, "空白区域应该可以长按拖动窗口")
    }

    func testPressingTheAddButtonDoesNotStartAWindowDrag() {
        showPanel(itemCount: 5)

        // 底栏最左侧的「添加」按钮。
        press(at: CGPoint(x: 45, y: panelHeight - 30))

        XCTAssertEqual(viewModel.mode, .editor, "点击应该落在「添加」按钮上")
        XCTAssertEqual(recorder.count, 0, "底栏按钮不能被窗口拖动抢占")
    }

    func testPressingTheCloseButtonDoesNotStartAWindowDrag() {
        var closeCount = 0
        showPanel(itemCount: 5, onClose: { closeCount += 1 })

        press(at: CGPoint(x: 464, y: 37))

        XCTAssertEqual(closeCount, 1, "点击应该落在关闭按钮上")
        XCTAssertEqual(recorder.count, 0, "关闭按钮不能被窗口拖动抢占")
    }

    func testPressingTheItemListDoesNotStartAWindowDrag() {
        showPanel(itemCount: 5)
        let firstSelection = viewModel.selectedItemID

        // 列表里靠中间的一行。
        press(at: CGPoint(x: 250, y: 200))

        XCTAssertNotEqual(viewModel.selectedItemID, firstSelection, "点击应该选中了另一行")
        XCTAssertEqual(recorder.count, 0, "文本列表要保留自己的点击与拖拽排序")
    }

    func testPressingTheTagBarDoesNotStartAWindowDrag() {
        showPanel(itemCount: 5, extraTagNames: ["工作"])
        let workTagID = viewModel.tags.last?.id

        // 标签栏里第二个标签「工作」。
        press(at: CGPoint(x: 150, y: 102))

        XCTAssertEqual(viewModel.selectedTagID, workTagID, "点击应该落在「工作」标签上")
        XCTAssertEqual(recorder.count, 0, "标签栏要保留长按拖动排序")
    }

    func testPressingTheTextEditorDoesNotStartAWindowDrag() {
        showPanel(itemCount: 5, startsInEditor: true)

        press(at: CGPoint(x: 250, y: 220))

        XCTAssertTrue(window.firstResponder is NSTextView, "点击应该落在文本编辑器上")
        XCTAssertEqual(recorder.count, 0, "文本编辑器不能被窗口拖动抢占")
    }

    // MARK: - Harness

    private func showPanel(
        itemCount: Int,
        extraTagNames: [String] = [],
        startsInEditor: Bool = false,
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
        if startsInEditor {
            viewModel.beginAdding()
        }

        let recorder = DragRecorder()
        self.recorder = recorder

        panelHeight = ClipboardPanelView.panelHeight(
            for: viewModel.items.count,
            tagCount: viewModel.tags.count,
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
        window.contentViewController = NSHostingController(
            rootView: ClipboardPanelView(
                viewModel: viewModel,
                onClose: onClose,
                onWindowDragChanged: { _ in recorder.count += 1 },
                onWindowDragEnded: {}
            )
        )
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // `xcodebuild test` 下宿主 App 抢不到焦点，`makeKey` 不足以让窗口真正成为 key window。
        // 而 AppKit 的 first-mouse 规则会把非 key 窗口空白背景上的 mouseDown 直接吞掉
        //（只有 `acceptsFirstMouse` 为真的交互控件才收得到），空白区域用例会永远为 0。
        // `becomeKey()` 会把内部 key 状态置上，事件才会照常派发。
        window.becomeKey()

        // 等 SwiftUI 完成布局，并把各控件的排除矩形通过 preference 冒泡上来。
        pumpEvents(for: 0.8)
    }

    /// 按下、轻微拖动、松开。轻微拖动是为了确保手势一定被驱动一次。
    ///
    /// 三个事件必须先进事件队列再统一抽取，不能直接 `window.sendEvent`：像 `NSTextView`
    /// 这样的 AppKit 控件会在 `mouseDown` 里自己开一个嵌套事件跟踪循环等 mouseUp，
    /// 同步派发的话那个 mouseUp 永远进不了队列，测试会直接挂死。
    private func press(at panelPoint: CGPoint) {
        let moved = CGPoint(x: panelPoint.x + 2, y: panelPoint.y + 2)

        post(.leftMouseDown, at: panelPoint)
        post(.leftMouseDragged, at: moved)
        post(.leftMouseUp, at: moved)

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

    /// 测试方法本身跑在 run loop 里，此时 `NSApplication` 不会自己派发事件，需要手动抽干队列。
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

/// 和生产环境的 `FloatingPanel` 一样，是一只可以成为 key 的无边框面板。
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
    func paste(text: String, into application: NSRunningApplication) {}
}
