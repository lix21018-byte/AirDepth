import SwiftUI
import UIKit

@main
struct AirDepthMocapApp: App {
    init() {
        // Keep iPhone Air screen awake during TrueDepth motion capture recording
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
