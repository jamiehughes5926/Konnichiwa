import SwiftUI

@main
struct KonnichiwaApp: App {
    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor.systemBackground // Set this to any color you need

        UITabBar.appearance().standardAppearance = tabBarAppearance
        if #available(iOS 16.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
