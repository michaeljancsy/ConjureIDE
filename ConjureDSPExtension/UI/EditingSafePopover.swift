//
//  EditingSafePopover.swift
//  ConjureDSPExtension
//

import AppKit
import SwiftUI

extension View {
    /// `.popover(isPresented:)` that ends text editing before the popover
    /// closes. When `isPresented` turns false, editing ends first and the
    /// popover closes on the next main-loop turn.
    ///
    /// Closing a popover while one of its text fields is editing makes AppKit
    /// remove the text cursor's caps lock / keyboard layout indicator window
    /// in the middle of the popover's own window reorder. Inside the AU view
    /// service, ViewBridge asserts on that nested reorder and the plugin
    /// process aborts (Sentry CONJUREDSP-6E). Ending the edit first removes
    /// the indicator while the popover is still on screen.
    func editingSafePopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        modifier(EditingSafePopover(isPresented: isPresented, arrowEdge: arrowEdge, popoverContent: content))
    }
}

private struct EditingSafePopover<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge?
    let popoverContent: () -> PopoverContent

    /// Drives the real popover. Follows `isPresented`, except that closing
    /// waits a turn so editing can end while the popover is still up.
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $shown, arrowEdge: arrowEdge, content: popoverContent)
            .onAppear { shown = isPresented }
            .onChange(of: isPresented) { _, presented in
                if presented {
                    shown = true
                } else if shown {
                    endEditingInPopovers()
                    DispatchQueue.main.async {
                        if !isPresented { shown = false }
                    }
                }
            }
            // The popover closed itself (a click outside it).
            .onChange(of: shown) { _, nowShown in
                if !nowShown && isPresented { isPresented = false }
            }
    }
}

/// Ends editing wherever a text field inside a popover (a child window) holds
/// the field editor. The editor can be the first responder of the popover
/// window or of its parent, which a popover shares its first responder with.
@MainActor
private func endEditingInPopovers() {
    for window in NSApp.windows {
        guard let editor = window.firstResponder as? NSText, editor.window?.parent != nil else { continue }
        window.makeFirstResponder(nil)
    }
}
