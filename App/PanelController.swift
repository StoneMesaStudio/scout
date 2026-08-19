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

    /// The proportion of the screen height the panel's top edge sits at. Slightly above centre
    /// reads as "in front of your work" rather than "in the middle of it".
    private let verticalPlacement: CGFloat = 0.26
    private let panelWidth: CGFloat = 680

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = existingOrNewPanel()
        model.reset()
        model.onDismiss = { [weak self] in self?.hide() }

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

        self.panel = panel
        return panel
    }

    /// Put the panel on whichever screen the pointer is on — that is the screen the user is
    /// looking at, which is not always the one holding the menu bar.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let x = frame.midX - panelWidth / 2
        let y = frame.maxY - (frame.height * verticalPlacement) - size.height
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: size.height), display: false)
    }
}
