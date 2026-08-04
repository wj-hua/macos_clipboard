import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let viewModel: ClipboardViewModel
    private let panel: FloatingPanel
    private var localEventMonitor: Any?
    private var sizeCancellables = Set<AnyCancellable>()

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
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: ClipboardPanelView(viewModel: viewModel, onClose: { [weak self] in
                self?.hide()
            })
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
                  !self.panel.isKeyWindow else {
                return
            }
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

        if viewModel.mode == .editor, handleEditingShortcut(event) {
            return true
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
}
