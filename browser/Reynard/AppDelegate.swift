//
//  AppDelegate.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        guard !ReynardStartupMode.current.usesUIKitOnlyStartup else {
            return true
        }
        
        // ADDED - see fix_background_skip_predicates.py.
        //
        // applyPreference() had exactly one caller: the Experimental
        // toggle handler. So a preference left ON was applied only in the
        // process where it was switched on. isRunning starts false and
        // only start() sets it, so on every relaunch afterwards the
        // engine never started, iOS suspended the app normally, and both
        // keep-alive skips in SceneDelegate fired anyway - they tested
        // the preference, not the engine. They test isActive now, which
        // is only honest if something applies the preference at launch.
        //
        // Here rather than main.swift, where JITController.shared.start()
        // is kicked: main.swift runs before UIApplicationMain, and its
        // own comment says registerDefaults() has not happened there, so
        // the profile-scoped preference this reads may not exist yet.
        // That is exactly why stdoutLogBridgeKey is a flat key.
        //
        // Here rather than scene(_:willConnectTo:): that runs per scene
        // and can run again on reconnect, and CarPlay has its own
        // delegate. This runs once per launch, and the guard above
        // already keeps it out of the data-transfer and recovery startup
        // modes, which have no tabs and nothing to keep alive.
        //
        // Logged unconditionally: whether the engine came up is the
        // single fact the two SceneDelegate skips now turn on, and it is
        // otherwise invisible until a background happens.
        BackgroundAudioKeepAlive.shared.applyPreference()
        let keepAlivePreference = Prefs.ExperimentalSettings.isBackgroundAudioKeepAliveEnabled
        logger(String(format: "keepAlive: applied at launch - preference %@, engine %@", keepAlivePreference ? "ON" : "off", BackgroundAudioKeepAlive.shared.isActive ? "RUNNING" : "not running"))
        
        Task {
            do {
                try await AddonPackageStagingService.shared.removeStaleFiles()
            } catch {
                AddonPackageStagingLog.error("Unable to clean staged add-on packages", error: error)
            }
        }
        return true
    }
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
    
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}

    func applicationWillTerminate(_ application: UIApplication) {
        guard !ReynardStartupMode.current.usesUIKitOnlyStartup else {
            return
        }
        NavigationHistoryStore.shared.flushPendingWrites()
    }
}
