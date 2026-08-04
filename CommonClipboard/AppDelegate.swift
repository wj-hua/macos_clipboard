import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: PasteItemStore
    private let viewModel: ClipboardViewModel

    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var hotKeyController: GlobalHotKeyController!
    private var shortcutStatusItem: NSMenuItem!

    override init() {
        let store = PasteItemStore()
        self.store = store
        self.viewModel = ClipboardViewModel(store: store, pasteService: SystemPasteService())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[CommonClipboard] applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        panelController = PanelController(viewModel: viewModel)
        configureStatusItem()
        configureGlobalHotKey()
        NSLog("[CommonClipboard] status item and global hot key configured")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showPanel() {
        panelController.show()
    }

    @objc private func addPasteItem() {
        panelController.showForAdding()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = makeMenuBarIcon()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = "常用粘贴板"
            button.setAccessibilityLabel("常用粘贴板")
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "显示面板", action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let addItem = NSMenuItem(title: "添加常用文本", action: #selector(addPasteItem), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        menu.addItem(.separator())

        shortcutStatusItem = NSMenuItem(title: "快捷键：Option + 空格", action: nil, keyEquivalent: "")
        shortcutStatusItem.isEnabled = false
        menu.addItem(shortcutStatusItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出常用粘贴板", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func makeMenuBarIcon() -> NSImage {
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let body = NSBezierPath(
                roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 14.1),
                xRadius: 2.1,
                yRadius: 2.1
            )
            body.lineWidth = 1.35
            body.lineCapStyle = .round
            body.lineJoinStyle = .round
            body.stroke()

            let clip = NSBezierPath(
                roundedRect: NSRect(x: 5.1, y: 13.7, width: 7.8, height: 2.8),
                xRadius: 1.1,
                yRadius: 1.1
            )
            clip.lineWidth = 1.25
            clip.lineCapStyle = .round
            clip.lineJoinStyle = .round
            clip.stroke()

            let clipSlot = NSBezierPath(
                roundedRect: NSRect(x: 7.1, y: 14.25, width: 3.8, height: 1.45),
                xRadius: 0.7,
                yRadius: 0.7
            )
            clipSlot.lineWidth = 1.05
            clipSlot.stroke()

            let firstLine = NSBezierPath()
            firstLine.lineWidth = 1.25
            firstLine.lineCapStyle = .round
            firstLine.move(to: NSPoint(x: 4.7, y: 11.15))
            firstLine.curve(
                to: NSPoint(x: 12.8, y: 11.25),
                controlPoint1: NSPoint(x: 7.0, y: 10.95),
                controlPoint2: NSPoint(x: 10.5, y: 11.5)
            )
            firstLine.stroke()

            let secondLine = NSBezierPath()
            secondLine.lineWidth = 1.25
            secondLine.lineCapStyle = .round
            secondLine.move(to: NSPoint(x: 4.7, y: 8.45))
            secondLine.curve(
                to: NSPoint(x: 11.2, y: 8.55),
                controlPoint1: NSPoint(x: 6.4, y: 8.25),
                controlPoint2: NSPoint(x: 9.0, y: 8.75)
            )
            secondLine.stroke()

            let thirdLine = NSBezierPath()
            thirdLine.lineWidth = 1.25
            thirdLine.lineCapStyle = .round
            thirdLine.move(to: NSPoint(x: 4.7, y: 5.75))
            thirdLine.curve(
                to: NSPoint(x: 12.2, y: 5.9),
                controlPoint1: NSPoint(x: 7.2, y: 5.55),
                controlPoint2: NSPoint(x: 10.1, y: 6.1)
            )
            thirdLine.stroke()

            return true
        }

        // 菜单栏会根据浅色/深色外观自动着色，保持与系统菜单栏一致。
        icon.isTemplate = true
        return icon
    }

    private func configureGlobalHotKey() {
        hotKeyController = GlobalHotKeyController()
        hotKeyController.onHotKey = { [weak self] in
            self?.panelController.toggle()
        }

        if hotKeyController.register() {
            shortcutStatusItem.title = "快捷键：Option + 空格"
            NSLog("[CommonClipboard] global hot key registration succeeded")
        } else {
            shortcutStatusItem.title = "快捷键注册失败，请检查是否被其他应用占用"
            NSLog("[CommonClipboard] global hot key registration failed")
        }
    }
}
