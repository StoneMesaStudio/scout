import AppKit
import SwiftUI

/// Makes the area behind it draggable, moving the whole panel.
///
/// `isMovableByWindowBackground` looks like it should be enough and is not: SwiftUI's material
/// background is a real view that swallows the mouse events, so the window never learns a drag
/// began. This sits behind the panel's top bar and hands the event to the window itself.
struct WindowDragHandle: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        // The cursor stays an arrow; a resize or text cursor here would promise the wrong thing.
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}


/// Hands a SwiftUI view the window it is living in.
///
/// Needed because answering a permission prompt gives the front back to whatever app was there
/// before — not to a menu-bar app with no Dock icon. Without putting the window back afterwards,
/// clicking Allow looks exactly like Settings closing itself.
struct WindowAccessor: NSViewRepresentable {

    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // A view has no window until it is in the hierarchy, which is a turn later than this.
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window == nil, let found = view.window {
            DispatchQueue.main.async { window = found }
        }
    }
}
