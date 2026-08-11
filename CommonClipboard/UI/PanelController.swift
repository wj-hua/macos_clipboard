import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 菜单栏 App 的面板可能在第一次点击时还不是 key window。普通的 `NSHostingView`
/// 会让空白背景遵循 AppKit 的 first-mouse 规则，导致这次按压没有进入 SwiftUI 手势。
/// 明确接受 first mouse 后，空白区域和按钮一样会拦住点击，不会落到下面的 App。
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// 把面板空白区域里的鼠标拖动转换成窗口移动。
///
/// 位移一律按**屏幕坐标**计算，不能用 SwiftUI 手势的 `translation`：后者是窗口
/// 坐标系里的量，窗口一旦被移动，同一个鼠标位置算出来的 translation 就会缩回去，
/// 于是每个事件都在 `W0` 和 `W0 + 位移` 之间来回跳。屏幕坐标不受窗口移动影响。
struct WindowDragRecognizer {
    private struct Anchor {
        let windowOrigin: CGPoint
        let pointerLocation: CGPoint
    }

    private var anchor: Anchor?

    var isDragging: Bool {
        anchor != nil
    }

    /// 返回窗口应该被放到的新原点；返回 `nil` 表示这次事件不移动窗口。
    ///
    /// - Parameters:
    ///   - pointerLocation: 鼠标的屏幕坐标（y 轴向上，与窗口原点同向）。
    ///   - windowFrame: 当前窗口位置，只有按下的第一个事件会用到。
    mutating func update(
        pointerLocation: CGPoint,
        windowFrame: CGRect
    ) -> CGPoint? {
        guard let anchor else {
            // 第一个事件发生在按下的瞬间，此时只记录起点；后续任意位移都会直接移动窗口。
            self.anchor = Anchor(
                windowOrigin: windowFrame.origin,
                pointerLocation: pointerLocation
            )
            return nil
        }

        return origin(from: anchor, pointerLocation: pointerLocation)
    }

    mutating func end() {
        anchor = nil
    }

    private func offset(from anchor: Anchor, pointerLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: pointerLocation.x - anchor.pointerLocation.x,
            y: pointerLocation.y - anchor.pointerLocation.y
        )
    }

    private func origin(from anchor: Anchor, pointerLocation: CGPoint) -> CGPoint {
        let offset = self.offset(from: anchor, pointerLocation: pointerLocation)
        return CGPoint(
            x: anchor.windowOrigin.x + offset.x,
            y: anchor.windowOrigin.y + offset.y
        )
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let viewModel: ClipboardViewModel
    private let panel: FloatingPanel
    private var localEventMonitor: Any?
    private var sizeCancellables = Set<AnyCancellable>()
    private var windowDragRecognizer = WindowDragRecognizer()

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        self.panel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ClipboardPanelView.panelWidth,
                height: ClipboardPanelView.panelHeight(
                    for: viewModel.items.count,
                    tagCount: viewModel.tags.count,
                    mode: viewModel.mode
                )
            ),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Window movement is implemented below so interactive controls can be
        // excluded. The AppKit default would also move the panel from controls.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = PanelHostingView(
            rootView: ClipboardPanelView(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.hide()
                },
                onWindowDragChanged: { [weak self] in
                    self?.handleWindowDragChanged()
                },
                onWindowDragEnded: { [weak self] in
                    self?.endWindowDrag()
                }
            )
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        viewModel.$items
            .combineLatest(viewModel.$tags, viewModel.$mode)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updatePanelSize()
            }
            .store(in: &sizeCancellables)

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else {
                return event
            }

            return self.handleKeyDown(event) ? nil : event
        }
    }

    deinit {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        present(targetApplication: currentTargetApplication())
    }

    func showForAdding() {
        present(targetApplication: currentTargetApplication())
        viewModel.beginAdding()
    }

    func hide() {
        endWindowDrag()
        panel.orderOut(nil)
        viewModel.dismiss()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.sheets.isEmpty, panel.isVisible else { return }

        // AppKit may briefly report a resign-key event while the accessory app is
        // being activated. Wait one run-loop turn before treating it as an
        // intentional click outside the panel.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.panel.sheets.isEmpty,
                  self.panel.isVisible,
                  !self.panel.isKeyWindow,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else {
                return
            }

            // An alert that AppKit puts in its own window instead of a sheet also
            // takes key away from the panel. `keyWindow` is nil once the click
            // really went to another application, so this only skips our own
            // windows.
            guard NSApp.keyWindow == nil else { return }

            self.hide()
        }
    }

    private func present(targetApplication: NSRunningApplication?) {
        viewModel.prepareForPresentation(targetApplication: targetApplication)
        updatePanelSize(animated: false)
        positionPanel()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func updatePanelSize(animated: Bool = true) {
        let desiredHeight = ClipboardPanelView.panelHeight(
            for: viewModel.items.count,
            tagCount: viewModel.tags.count,
            mode: viewModel.mode
        )
        guard abs(panel.frame.height - desiredHeight) > 0.5 else { return }

        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: ClipboardPanelView.panelWidth, height: desiredHeight)
        frame.origin.y = topEdge - desiredHeight
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func currentTargetApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return application
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            if viewModel.mode == .editor {
                viewModel.cancelEditing()
            } else {
                hide()
            }
            return true
        }

        if viewModel.mode == .editor {
            if handleEditingShortcut(event) {
                return true
            }

            if handleEditorSubmit(event) {
                return true
            }
        }

        guard viewModel.mode == .list else { return false }

        if handleListShortcut(event) {
            return true
        }

        switch event.keyCode {
        case UInt16(kVK_UpArrow):
            viewModel.moveSelection(by: -1)
            return true
        case UInt16(kVK_DownArrow):
            viewModel.moveSelection(by: 1)
            return true
        case UInt16(kVK_LeftArrow):
            viewModel.moveTagSelection(by: -1)
            return true
        case UInt16(kVK_RightArrow):
            viewModel.moveTagSelection(by: 1)
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            if viewModel.pasteSelectedItem() {
                hide()
            }
            return true
        default:
            return false
        }
    }

    private func handleListShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.shift) else {
            return false
        }

        guard let index = listShortcutItemIndex(for: event.keyCode) else { return false }
        if viewModel.pasteItem(at: index) {
            hide()
        }
        return true
    }

    private func listShortcutItemIndex(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_Keypad1):
            return 0
        case UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_Keypad2):
            return 1
        case UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_Keypad3):
            return 2
        case UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_Keypad4):
            return 3
        case UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_Keypad5):
            return 4
        case UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_Keypad6):
            return 5
        case UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_Keypad7):
            return 6
        case UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_Keypad8):
            return 7
        case UInt16(kVK_ANSI_9), UInt16(kVK_ANSI_Keypad9):
            return 8
        default:
            return nil
        }
    }

    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        let selector: Selector?
        switch characters {
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "x":
            selector = #selector(NSText.cut(_:))
        case "a":
            selector = #selector(NSText.selectAll(_:))
        default:
            selector = nil
        }

        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func handleEditorSubmit(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Return)
                || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) else {
            return false
        }

        let textInputModifiers = event.modifierFlags.intersection([
            .shift,
            .control,
            .option,
            .command
        ])
        guard textInputModifiers.isEmpty else { return false }

        if let textInputClient = panel.firstResponder as? NSTextInputClient,
           textInputClient.hasMarkedText() {
            return false
        }

        viewModel.saveDraft()
        return true
    }

    private func handleWindowDragChanged() {
        guard panel.isVisible,
              let origin = windowDragRecognizer.update(
                  pointerLocation: NSEvent.mouseLocation,
                  windowFrame: panel.frame
              ) else {
            return
        }

        panel.setFrameOrigin(origin)
    }

    private func endWindowDrag() {
        windowDragRecognizer.end()
    }
}
