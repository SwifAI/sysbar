import AppKit
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SystemMonitor?
    private var statusItemController: StatusItemController?
    private var notificationResponder: NotificationResponder?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make()
        // Set before launch finishes so a tap that launched SysBar is delivered.
        // A bare executable has no bundle identity and no notifications.
        if Bundle.main.bundleIdentifier != nil {
            let responder = NotificationResponder()
            UNUserNotificationCenter.current().delegate = responder
            notificationResponder = responder
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard monitor == nil, statusItemController == nil else { return }
        let monitor = SystemMonitor()
        self.monitor = monitor
        let controller = StatusItemController(monitor: monitor)
        statusItemController = controller
        notificationResponder?.handler = { [weak controller] response in
            controller?.handle(response)
        }
    }

    /// Opening SysBar again (Finder, Spotlight, Launchpad, `open`) behaves like a
    /// native menu-bar extra: it opens the monitor and AppKit opens no window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.showPopover()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { [weak self] in await self?.monitor?.refreshAppServices() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.invalidate()
        monitor?.shutdown()
        statusItemController = nil
        monitor = nil
    }
}

/// The main menu is never shown (SysBar is an accessory app), but its key
/// equivalents still route Quit and the standard editing commands, so ⌘C, ⌘V,
/// ⌘A and ⌘Z keep working in the popover's search field.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: AppResources.localized("Quit SysBar"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editMenu = NSMenu(title: AppResources.localized("Edit"))
        editMenu.addItem(withTitle: AppResources.localized("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: AppResources.localized("Redo"),
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: AppResources.localized("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: AppResources.localized("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: AppResources.localized("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: AppResources.localized("Select All"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}

/// SysBar has no windows, only a status item and its popover, so it runs on the
/// AppKit lifecycle directly. A SwiftUI `App` must declare a scene, and macOS
/// presented that placeholder scene on every launch, including at login.
@main
enum SysBarMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
