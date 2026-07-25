import sys

path = "browser/Reynard/SceneDelegate.swift"

with open(path, "r") as f:
    content = f.read()

old = '''    func sceneDidEnterBackground(_ scene: UIScene) {
        os_log("sceneDidEnterBackground", log: sceneLog, type: .debug)
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        browserViewController.sessionManager.setApplicationForeground(false)
        browserViewController.privateBrowsingLockCoordinator.lockIfNeeded()
        flushNavigationHistoryInBackground()
    }'''
new = '''    func sceneDidEnterBackground(_ scene: UIScene) {
        os_log("sceneDidEnterBackground", log: sceneLog, type: .debug)
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        browserViewController.sessionManager.setApplicationForeground(false)
        browserViewController.privateBrowsingLockCoordinator.lockIfNeeded()
        browserViewController.tabManager.sleepBackgroundedTabs()
        flushNavigationHistoryInBackground()
    }'''

count = content.count(old)
if count != 1:
    print(f"ERROR: expected 1 match, found {count}")
    sys.exit(1)
content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)

print("SceneDelegate.swift wired successfully - tabs now sleep when the app backgrounds.")
