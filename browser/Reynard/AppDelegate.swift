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
        // One-shot, and only when asked for. AVStreamDataParser is the
        // only thing that could originate a FairPlay key request for MSE
        // content - public AVFoundation cannot, because AVURLAsset is
        // the sole AVContentKeyRecipient - so whether it instantiates
        // and accepts addContentKeyRecipient: decides whether Apple TV+,
        // Netflix and HBO Max are reachable at all. It writes to stderr,
        // so the answer arrives in the ordinary device capture.
        //
        // Unconditional, deliberately. An environment variable would
        // never fire here - SpringBoard launches this app, and only
        // Xcode or a shell sets one - so gating on that would have
        // produced a probe that silently never ran and a capture that
        // looked like a negative answer.
        //
        // The cost is about a hundred lines once per process, in a log
        // where 90% of every capture is already one repeated extension
        // error. Remove this call once the question is answered.
        ReynardRunAVStreamDataParserProbe()
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
