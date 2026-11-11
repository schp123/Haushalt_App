import SwiftUI
import SwiftData
import UserNotifications
import Observation

enum AppTab: Hashable { case vorrat, mahlzeiten, plan, einkauf, ausgaben }

@MainActor
@Observable
final class Router {
    static let shared = Router()
    var tab: AppTab = .vorrat
    var showCheck = false
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Auch bei geöffneter App als Banner zeigen.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Tipp auf eine Benachrichtigung öffnet den passenden Screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let route = response.notification.request.content.userInfo["route"] as? String
        await MainActor.run {
            switch route {
            case "check": Router.shared.showCheck = true
            case "einkauf": Router.shared.tab = .einkauf
            case "ausgaben": Router.shared.tab = .ausgaben
            default: break
            }
        }
    }
}

@main
struct WocheneinkaufApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .fontDesign(.rounded)
        }
        .modelContainer(for: [
            Product.self, PriceRecord.self, MealTemplate.self, Ingredient.self,
            PlanEntry.self, MealLog.self, Purchase.self, AppSettings.self, WishItem.self, SyncMeta.self
        ])
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var router = Router.shared

    var body: some View {
        TabView(selection: $router.tab) {
            VorratView()
                .tabItem { Label("Vorrat", systemImage: "square.grid.2x2") }
                .tag(AppTab.vorrat)
            MahlzeitenView()
                .tabItem { Label("Mahlzeiten", systemImage: "fork.knife") }
                .tag(AppTab.mahlzeiten)
            WochenplanView()
                .tabItem { Label("Wochenplan", systemImage: "calendar") }
                .tag(AppTab.plan)
            EinkaufView()
                .tabItem { Label("Einkauf", systemImage: "cart") }
                .tag(AppTab.einkauf)
            AusgabenView()
                .tabItem { Label("Ausgaben", systemImage: "eurosign") }
                .tag(AppTab.ausgaben)
        }
        .tint(Theme.accent)
        .sheet(isPresented: $router.showCheck) {
            CheckView()
        }
        .task {
            SyncEngine.shared.attach(context)
            _ = AppSettings.current(context)
            await Notifier.requestAuthorization()
            Notifier.evaluate(context)
        }
        .task(id: scenePhase) {
            // Solange die App offen ist: jede Minute Änderungen vom anderen iPhone holen.
            guard scenePhase == .active else { return }
            SyncEngine.shared.attach(context)
            Notifier.evaluate(context)
            while !Task.isCancelled {
                await SyncEngine.shared.sync()
                Notifier.evaluate(context)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}
