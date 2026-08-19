import AppKit
import SwiftUI

/// A borderless panel that floats over whatever app is in front — the same behaviour as
/// Spotlight's own window, and the reason Scout never needs to be "opened".
final class SearchPanel: NSPanel {
    // Borderless windows refuse key status unless asked to accept it, and a search box that
    // cannot receive typing is not much of a search box.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {

    private var panel: SearchPanel?
    private let model = SearchModel()
    private var resizeObserver: NSObjectProtocol?

    /// Where the panel's top-left corner belongs. The panel grows and shrinks as results come and
    /// go, and macOS measures windows from the bottom-left — so without pinning the top edge, the
    /// search field would jump up the screen every time a result arrived.
    private var anchor: NSPoint?

    /// The proportion of the screen height the panel's top edge sits at. Slightly above centre
    /// reads as "in front of your work" rather than "in the middle of it".
    private let verticalPlacement: CGFloat = 0.26
    private let panelWidth: CGFloat = 820

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = existingOrNewPanel()
        model.reset()
        model.onDismiss = { [weak self] in self?.hide() }

        panel.layoutIfNeeded()
        position(panel)
        // Bringing the app forward is what lets the text field take key focus. Dismissing hides
        // Scout again, which hands focus straight back to the app underneath.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        model.stop()
        NSApp.hide(nil)
    }

    private func existingOrNewPanel() -> SearchPanel {
        if let panel { return panel }

        let panel = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        // Follows the user between spaces and shows over full-screen apps, like Spotlight does.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let host = NSHostingView(rootView: SearchRootView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchor() }
        }

        self.panel = panel
        return panel
    }

    /// Put the top-left corner back where it was after the panel changed height.
    private func reanchor() {
        guard let panel, let anchor else { return }
        panel.setFrameTopLeftPoint(anchor)
    }

    /// Put the panel on whichever screen the pointer is on — that is the screen the user is
    /// looking at, which is not always the one holding the menu bar.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let x = frame.midX - panelWidth / 2
        let top = frame.maxY - (frame.height * verticalPlacement)
        anchor = NSPoint(x: x, y: top)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }
}
