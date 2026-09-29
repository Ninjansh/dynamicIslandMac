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
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 210, height: 35),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        if let mainScreen = NSScreen.main {
            let screenFrame = mainScreen.frame
            let xPos = (screenFrame.width - panel.frame.width) / 2
            let yPos = screenFrame.height - panel.frame.height
            panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }

        panel.contentView = NSHostingView(rootView: ContentView())
        panel.orderFrontRegardless()
    }
}
