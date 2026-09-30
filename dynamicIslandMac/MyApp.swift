import SwiftUI
import AppKit

@main
struct dynamicIslandMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = 200

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Float above the menu bar and full-screen auxiliary layers
        panel.level = .statusBar + 2
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true

        // Fallback to screens.first if NSScreen.main is nil on launch
        let targetScreen = NSScreen.main ?? NSScreen.screens.first

        if let screen = targetScreen {
            let screenWidth = screen.frame.width
            let screenHeight = screen.frame.height
            let screenOriginX = screen.frame.origin.x
            let screenOriginY = screen.frame.origin.y

            let xPos = screenOriginX + (screenWidth - panelWidth) / 2.0
            let yPos = screenOriginY + screenHeight - panelHeight

            panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }

        panel.contentView = NSHostingView(rootView: ContentView())
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }
}
