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

    /// Posted when the panel should go back to the size and place it starts at.
    static let resetGeometryNotification = Notification.Name("ScoutResetPanelGeometry")

    private var panel: SearchPanel?
    private let model = SearchModel()
    private let settings = ScoutSettings.shared
    private var frameObservers: [NSObjectProtocol] = []
    /// True while a reset is moving the window, so the observers that remember the frame do not
    /// write back the one the reset just cleared.
    private var isResetting = false

    /// How much of the screen the panel takes when it has never been resized. Tall on purpose:
    /// the results are the point, and a panel that only shows the search field looks broken.
    private let defaultHeightFraction: CGFloat = 0.80
    private let defaultWidth: CGFloat = 900
    private let minimumSize = NSSize(width: 620, height: 300)

    /// Bring the panel up offscreen, run a query through it, and report what the layout did.
    /// Used by `Scout --selftest`, because "the results are drawn into a zero-height box" is a
    /// bug no unit test catches and no one can see without the app in front of them.
    func selfTest(query: String) -> String {
        let panel = existingOrNewPanel()
        panel.setFrame(NSRect(x: -6000, y: 0, width: 900, height: 800), display: false)
        panel.orderFront(nil)
        panel.layoutIfNeeded()

        model.reset()
        model.text = query
        return summary(of: panel)
    }

    /// Re-measure after the search has had time to come back.
    func selfTestSummary() -> String {
        guard let panel else { return "no panel" }
        panel.layoutIfNeeded()
        return summary(of: panel)
    }

    private func summary(of panel: NSPanel) -> String {
        let content = panel.contentView
        let tallest = content?.subviews.map(\.frame.height).max() ?? 0
        let sections = model.sections.map { "\($0.lane.title):\($0.rows.count)" }.joined(separator: ", ")
        return [
            "panel: \(Int(panel.frame.width))x\(Int(panel.frame.height))",
            "content view: \(Int(content?.frame.width ?? 0))x\(Int(content?.frame.height ?? 0))",
            "tallest child of content view: \(Int(tallest))",
            "rows in model: \(model.rowCount)",
            "sections: \(sections)",
            "drawn: " + model.displayItems.map(Self.label).joined(separator: " | "),
        ].joined(separator: "\n")
    }

    /// A compact description of what the panel is drawing, in order — the only way to see that a
    /// heading is sitting over the right rows without looking at the screen.
    private static func label(_ item: PanelItem) -> String {
        switch item {
        case .header(let lane, let count, let total): "[\(lane.title) \(count)/\(total)]"
        case .status(let lane, _): "(\(lane.title): notice)"
        case .row(let row, _):
            switch row {
            case .app: "app"
            case .file: "file"
            case .pane: "pane"
            case .mail: "mail"
            case .message: "msg"
            case .contact: "contact"
            }
        case .showMore(_, let remaining): "(+\(remaining) more)"
        case .indexing(_, let done, let total): "(indexing \(done)/\(total))"
        case .hiddenNotice: "(hidden)"
        }
    }

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
            contentRect: NSRect(origin: .zero, size: minimumSize),
            // `.resizable` on a borderless window still gives working edges to drag, without
            // adding a title bar this panel has no use for.
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.minSize = minimumSize
        // Follows the user between spaces and shows over full-screen apps, like Spotlight does.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // No `sizingOptions` here on purpose. Letting the hosting view drive the window size is
        // what made the results vanish: a ScrollView has no height of its own to report, so the
        // window sized itself to the search field and the results were drawn into nothing.
        // The window owns the size; the view fills it.
        panel.contentView = NSHostingView(rootView: SearchRootView(model: model))

        frameObservers.append(NotificationCenter.default.addObserver(
            forName: Self.resetGeometryNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetGeometry() }
        })

        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rememberFrame() }
            }
            frameObservers.append(token)
        }

        self.panel = panel
        return panel
    }

    /// Put the panel where it was left, or — the first time — centred and tall on whichever screen
    /// the pointer is on. That is the screen the user is looking at, which is not always the one
    /// holding the menu bar.
    private func position(_ panel: NSPanel, ignoringSaved: Bool = false) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        if !ignoringSaved, let saved = settings.panelFrame, visible.intersects(saved) {
            // Clamped to the screen it is opening on. A panel sized for an external display is
            // taller than a laptop screen, and restoring it unchanged put the search field itself
            // off the top edge.
            panel.setFrame(Self.clamp(saved, into: visible, minimum: minimumSize), display: false)
            return
        }

        let height = min(visible.height, visible.height * defaultHeightFraction)
        let width = min(visible.width - 80, defaultWidth)
        let x = visible.midX - width / 2
        // Sits slightly above centre, which reads as "in front of your work" rather than "on top
        // of it", and leaves the menu bar clear.
        let y = visible.maxY - (visible.height - height) / 2.5 - height

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    /// Forget the remembered frame and lay the panel out from scratch.
    private func resetGeometry() {
        isResetting = true
        defer { isResetting = false }

        settings.panelFrame = nil
        guard let panel else { return }
        // `position` computes the default size as well as the place, so nothing here needs to
        // guess at a height — setting the minimum first is how the reset used to collapse the
        // panel to a strip.
        position(panel, ignoringSaved: true)
    }

    /// Fit a remembered frame onto the screen it is opening on.
    static func clamp(_ frame: NSRect, into visible: NSRect, minimum: NSSize) -> NSRect {
        var result = frame
        result.size.width = min(max(minimum.width, result.width), visible.width)
        result.size.height = min(max(minimum.height, result.height), visible.height)
        result.origin.x = min(max(visible.minX, result.minX), visible.maxX - result.width)
        result.origin.y = min(max(visible.minY, result.minY), visible.maxY - result.height)
        return result
    }

    private func rememberFrame() {
        // A reset moves and resizes the window, which fires these same notifications — and
        // saving from inside one would write back the frame the reset just cleared.
        guard !isResetting, let panel, panel.isVisible else { return }
        settings.panelFrame = panel.frame
    }
}
