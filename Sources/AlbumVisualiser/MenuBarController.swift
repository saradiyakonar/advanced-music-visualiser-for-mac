import AppKit

/// Status item and its menu. The owner rebuilds it whenever its contents change.
final class MenuBarController: NSObject, NSMenuDelegate {
    struct Model {
        var isOpen = false
        var screens: [(id: UInt32, name: String)] = []
        var selectedScreen: UInt32?
        var syncInfo = ""
        var launchAtLogin = false
    }

    var onToggle: () -> Void = {}
    var onSelectScreen: (UInt32) -> Void = { _ in }
    var onSync: (Double?) -> Void = { _ in } // nil = reset
    var onLaunchAtLogin: (Bool) -> Void = { _ in }
    var onQuit: () -> Void = {}
    var model: () -> Model = { Model() }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Album Visualiser")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild each time the menu opens so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = model()

        let start = item(m.isOpen ? "Close visualiser" : "Start visualiser", #selector(toggle))
        start.keyEquivalent = "v"
        start.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(start)

        if m.screens.count > 1 {
            let sub = NSMenu()
            for s in m.screens {
                let i = item(s.name, #selector(selectScreen(_:)))
                i.tag = Int(s.id)
                i.state = s.id == m.selectedScreen ? .on : .off
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: "Show on", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        let sync = NSMenu()
        let info = NSMenuItem(title: m.syncInfo, action: nil, keyEquivalent: "")
        info.isEnabled = false
        sync.addItem(info)
        sync.addItem(.separator())
        sync.addItem(item("Visuals earlier", #selector(earlier)))
        sync.addItem(item("Visuals later", #selector(later)))
        sync.addItem(item("Reset", #selector(resetSync)))
        let syncParent = NSMenuItem(title: "Sync", action: nil, keyEquivalent: "")
        syncParent.submenu = sync
        menu.addItem(syncParent)

        let login = item("Launch at login", #selector(toggleLogin))
        login.state = m.launchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggle() { onToggle() }
    @objc private func selectScreen(_ sender: NSMenuItem) { onSelectScreen(UInt32(sender.tag)) }
    @objc private func earlier() { onSync(-0.02) }
    @objc private func later() { onSync(0.02) }
    @objc private func resetSync() { onSync(nil) }
    @objc private func toggleLogin() { onLaunchAtLogin(!model().launchAtLogin) }
    @objc private func quit() { onQuit() }
}
