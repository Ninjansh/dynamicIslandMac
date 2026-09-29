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
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 100

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // Prevents macOS from drawing standard window shadows/tints
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        
        if let screen = NSScreen.main {
            let screenWidth = screen.frame.width
            let screenHeight = screen.frame.height
            
            let xPos = (screenWidth - panelWidth) / 2.0
            let yPos = screenHeight - panelHeight
            
            panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }

        panel.contentView = NSHostingView(rootView: ContentView())
        panel.orderFrontRegardless()
    }
}
