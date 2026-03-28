//
//  ResizeHandle.swift
//  ConjureDSPExtension
//

import SwiftUI

/// Draggable resize handle for the bottom-right corner of the plugin view.
/// Updates `preferredContentSize` on the view controller via the `onResize`
/// callback, which DAW hosts observe via KVO to resize the plugin window.
struct ResizeHandle: View {
    let minSize: NSSize
    let maxSize: NSSize
    let onResize: (CGSize) -> Void

    @State private var dragStartSize: CGSize = .zero
    @State private var currentParentSize: CGSize = .zero

    var body: some View {
        // Invisible reader to track parent size without blocking hit testing
        GeometryReader { geo in
            Color.clear
                .allowsHitTesting(false)
                .onAppear { currentParentSize = geo.size }
                .onChange(of: geo.size) { _, newSize in currentParentSize = newSize }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartSize == .zero {
                                dragStartSize = currentParentSize
                            }
                            let newWidth = max(minSize.width, min(maxSize.width, dragStartSize.width + value.translation.width))
                            let newHeight = max(minSize.height, min(maxSize.height, dragStartSize.height + value.translation.height))
                            onResize(CGSize(width: newWidth, height: newHeight))
                        }
                        .onEnded { _ in
                            dragStartSize = .zero
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .padding(4)
        }
    }
}
