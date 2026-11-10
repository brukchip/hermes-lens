import SwiftUI

@main
struct HermesLensApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
    @State private var model = AppModel()
    @State private var intentRouter = AppIntentRouter.shared

    var body: some Scene {
        WindowGroup {
            AppShellView(intentRouter: intentRouter)
                .environment(model)
                .task { await model.bootstrap() }
                .task { await model.monitorGlassesState() }
                .onOpenURL { url in
                    Task { await model.handleOpenURL(url) }
                }
        }
    }
}
