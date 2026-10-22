import AppKit
import Combine
import SwiftUI

@MainActor
protocol PanelSessionHandling: AnyObject {
    func panelDidOpen()
    func panelDidClose()
}

/// Converts AppKit's delegate callbacks into balanced panel sessions. AppKit
/// may deliver duplicate close/show callbacks while a transient popover is
/// changing state, so this adapter deliberately owns the session truth.
@MainActor
final class StatusItemLifecycle<Host> {
    let host: Host

    private let session: any PanelSessionHandling
    private var isOpen = false
    private var isInvalidated = false

    init(session: any PanelSessionHandling, hostFactory: () -> Host) {
        self.session = session
        self.host = hostFactory()
    }

    func popoverWillShow() {
        guard !isInvalidated, !isOpen else { return }
        isOpen = true
        session.panelDidOpen()
    }

    func popoverDidClose() {
        guard !isInvalidated, isOpen else { return }
        isOpen = false
        session.panelDidClose()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if isOpen {
            isOpen = false
            session.panelDidClose()
        }
    }
}

extension SystemMonitor: PanelSessionHandling {
    func panelDidOpen() {
        setPanelVisible(true)
    }

    func panelDidClose() {
        setPanelVisible(false)
    }
}

enum PopoverSizePolicy {
    static let contentWidth: CGFloat = 380
    /// The height of the loaded layout (status line, hero, Top CPU and the
    /// collapsed sections). The popover is sized once, when it opens, often
    /// before processes arrive; measuring that half-loaded state made it open
    /// short and then cut its own content.
    static let minimumContentHeight: CGFloat = 640
    static let maximumComfortableContentHeight: CGFloat = 720
    static let maximumVisibleFrameFraction: CGFloat = 0.8
    static let screenEdgeClearance: CGFloat = 24

    /// The popover owns the viewport size while it is visible. Allowing the
    /// hosting controller to keep publishing its ideal content size would let
    /// live monitoring rows grow the window beyond the current screen.
    static let hostingSizingOptions: NSHostingSizingOptions = []

    static func contentSize(
        idealHeight: CGFloat,
        visibleFrameHeight: CGFloat
    ) -> NSSize {
        let screenBoundedHeight = max(1, visibleFrameHeight - screenEdgeClearance)
        let proportionalHeight = max(1, visibleFrameHeight * maximumVisibleFrameFraction)
        let maximumHeight = min(
            maximumComfortableContentHeight,
            min(screenBoundedHeight, proportionalHeight)
        )
        let desiredHeight = idealHeight.isFinite && idealHeight > 0
            ? max(minimumContentHeight, idealHeight)
            : minimumContentHeight

        return NSSize(
            width: contentWidth,
            height: min(maximumHeight, desiredHeight)
        )
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    let statusItem: NSStatusItem
    let popover: NSPopover

    private let statusBar: NSStatusBar
    private let monitor: SystemMonitor
    private let lifecycle: StatusItemLifecycle<NSHostingController<AnyView>>
    private var summarySubscription: AnyCancellable?
    private var isInvalidated = false

    init(
        monitor: SystemMonitor,
        statusBar: NSStatusBar = .system
    ) {
        self.statusBar = statusBar
        self.monitor = monitor
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.lifecycle = StatusItemLifecycle(session: monitor) {
            NSHostingController(
                rootView: AnyView(
                    MenuContentView()
                        .environmentObject(monitor)
                        .environmentObject(monitor.appServices)
                        .environmentObject(monitor.attention)
                )
            )
        }
        super.init()

        configurePopover()
        configureStatusButton()
        subscribe(to: monitor.statusModel)
        monitor.attention.refreshProviders(force: true)
        monitor.attention.closePopover = { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        monitor.attention.revealRequest = { [weak self] key in
            self?.monitor.attention.reveal(key)
            self?.showPopover()
        }
    }

    /// A tap on one of SysBar's notifications: the notification opens the
    /// popover on its item; a button runs that item's action.
    func handle(_ response: NotificationResponder.Response) {
        switch response {
        case let .open(notification):
            if let key = AttentionNotification.key(from: notification) {
                monitor.attention.reveal(key)
            }
            showPopover()
        case let .action(notification, action):
            guard let key = AttentionNotification.key(from: notification) else { return }
            monitor.attention.performNotificationAction(action, for: key)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        lifecycle.popoverWillShow()
        monitor.attention.refreshProviders()
        Task { [weak self] in await self?.monitor.refreshAppServices() }
    }

    func popoverDidClose(_ notification: Notification) {
        lifecycle.popoverDidClose()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true

        summarySubscription?.cancel()
        summarySubscription = nil
        lifecycle.invalidate()
        if popover.isShown {
            popover.performClose(nil)
        }

        statusItem.button?.target = nil
        statusItem.button?.action = nil
        popover.delegate = nil
        popover.contentViewController = nil
        statusBar.removeStatusItem(statusItem)
    }

    private func configurePopover() {
        let hostingController = lifecycle.host
        hostingController.sizingOptions = PopoverSizePolicy.hostingSizingOptions
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = hostingController
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }

        button.image = StatusGlyphRenderer.image(for: .loading)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.setAccessibilityLabel(AppResources.localized("SysBar"))
        button.setAccessibilityHelp(
            AppResources.localized("Shows system activity and opens SysBar")
        )
    }

    private func subscribe(to model: StatusSummaryModel) {
        summarySubscription = model.$summary
            .removeDuplicates()
            .sink { [weak self] summary in
                self?.updateStatusButton(with: summary)
            }
    }

    private func updateStatusButton(with summary: StatusSummary) {
        guard let button = statusItem.button else { return }
        if button.title != summary.title { button.title = summary.title }
        let glyph = StatusGlyphRenderer.image(for: summary)
        if button.image !== glyph { button.image = glyph }
        button.setAccessibilityValue(summary.accessibilityValue)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard !isInvalidated, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(button)
            return
        }
        showPopover()
    }

    /// Explicit opening is shared by the status item and Settings. Repeated
    /// requests focus the existing panel without toggling or starting a session.
    @discardableResult
    func showPopover() -> Bool {
        guard !isInvalidated, let button = statusItem.button else { return false }
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKey()
            return true
        }
        guard let screen = button.window?.screen else { return false }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hostingController = lifecycle.host

        // Temporarily ask SwiftUI for its ideal height, then lock the hosting
        // controller before the popover is shown. This preserves compact sizing
        // for short states without allowing later telemetry updates to resize it.
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingHeight = hostingController.view.fittingSize.height
        hostingController.sizingOptions = PopoverSizePolicy.hostingSizingOptions

        let contentSize = PopoverSizePolicy.contentSize(
            idealHeight: fittingHeight,
            visibleFrameHeight: screen.visibleFrame.height
        )
        hostingController.preferredContentSize = contentSize
        hostingController.view.setFrameSize(contentSize)
        popover.contentSize = contentSize

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        return popover.isShown
    }
}
