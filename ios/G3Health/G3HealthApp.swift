import SwiftUI
import UIKit

@main
@MainActor
struct G3HealthApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Palette.mint)
                .task { await model.foregroundRefresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.foregroundRefresh() } }
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.setupBackgroundAtLaunch()
        return true
    }
}
