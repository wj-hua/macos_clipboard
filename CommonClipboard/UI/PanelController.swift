import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 只有「按住不动足够久」的按压才会升级成窗口移动。
///
/// 位移一律按**屏幕坐标**计算，不能用 SwiftUI 手势的 `translation`：后者是窗口
/// 坐标系里的量，窗口一旦被移动，同一个鼠标位置算出来的 translation 就会缩回去，
/// 于是每个事件都在 `W0` 和 `W0 + 位移` 之间来回跳。屏幕坐标不受窗口移动影响。
///
/// 手势事件仅在鼠标移动时到达，所以长按判定完全由事件自带的时间戳驱动，不依赖定时器；
/// 抽成独立类型是为了让阈值和位移换算可以脱离窗口单独测试。
struct WindowDragRecognizer {
    private enum Phase {
        /// 已按下但还没满足长按时长，此时还不确定是不是要移动窗口。
        case pending(anchor: Anchor, startTimestamp: TimeInterval)
        case dragging(anchor: Anchor)
        /// 长按未满就明显移动，本次按压不再有机会变成窗口拖动。
        case cancelled
    }

    private struct Anchor {
        let windowOrigin: CGPoint
        let pointerLocation: CGPoint
    }

    let minimumPressDuration: TimeInterval
    let movementTolerance: CGFloat

    private var phase: Phase?

    init(minimumPressDuration: TimeInterval = 0.4, movementTolerance: CGFloat = 5) {
        self.minimumPressDuration = minimumPressDuration
        self.movementTolerance = movementTolerance
    }

    var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    /// 返回窗口应该被放到的新原点；返回 `nil` 表示这次事件不移动窗口。
    ///
    /// - Parameters:
    ///   - pointerLocation: 鼠标的屏幕坐标（y 轴向上，与窗口原点同向）。
    ///   - windowFrame: 当前窗口位置，只有按下的第一个事件会用到。
    mutating func update(
        pointerLocation: CGPoint,
        timestamp: TimeInterval,
        windowFrame: CGRect
    ) -> CGPoint? {
        switch phase {
        case .cancelled:
            return nil

        case nil:
            // 第一个事件发生在按下的瞬间，此时只记录起点。
            phase = .pending(
                anchor: Anchor(windowOrigin: windowFrame.origin, pointerLocation: pointerLocation),
                startTimestamp: timestamp
            )
            return nil

        case let .dragging(anchor):
            return origin(from: anchor, pointerLocation: pointerLocation)

        case let .pending(anchor, startTimestamp):
            // A quick drag is not a window move. The user must hold still long
            // enough first, which also keeps ordinary clicks from feeling sticky.
            guard timestamp - startTimestamp >= minimumPressDuration else {
                let offset = self.offset(from: anchor, pointerLocation: pointerLocation)
                if hypot(offset.x, offset.y) > movementTolerance {
                    phase = .cancelled
                }
                return nil
            }

            phase = .dragging(anchor: anchor)
            return origin(from: anchor, pointerLocation: pointerLocation)
        }
    }

    mutating func end() {
        phase = nil
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
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Window movement is implemented below with an explicit long-press
        // gesture. The AppKit default would move the panel on any drag.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: ClipboardPanelView(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.hide()
                },
                onWindowDragChanged: { [weak self] time in
                    self?.handleWindowDragChanged(time: time)
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

    private func handleWindowDragChanged(time: Date) {
        guard panel.isVisible,
              let origin = windowDragRecognizer.update(
                  pointerLocation: NSEvent.mouseLocation,
                  timestamp: time.timeIntervalSinceReferenceDate,
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
