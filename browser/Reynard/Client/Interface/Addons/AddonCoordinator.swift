//
//  AddonCoordinator.swift
//  Reynard
//
//  Created by Minh Ton on 28/4/26.
//

import GeckoView
import Security
import UIKit

protocol AddonCoordinatorDataSource: AnyObject {
    var selectedAddonSession: GeckoSession? { get }
    var isSelectedAddonTabPrivate: Bool { get }
    var addonTabs: [Tab] { get }
    var selectedAddonTabMode: TabMode { get }
    
    func indexOfAddonTab(for session: GeckoSession) -> Int?
}

protocol AddonCoordinatorDelegate: AnyObject {
    func refreshAddonChrome(_ coordinator: AddonCoordinator)
    func performAfterAddonMenuDismissal(_ coordinator: AddonCoordinator, work: @escaping () -> Void)
    func setAddonPopupLoading(_ coordinator: AddonCoordinator, isLoading: Bool)
    func presentAddonViewController(_ coordinator: AddonCoordinator, _ viewController: UIViewController)
    func presentAddonAlert(_ coordinator: AddonCoordinator, title: String?, message: String)
    func dismissAddonModal(_ coordinator: AddonCoordinator, completion: (() -> Void)?) -> Bool
    func createAddonTab(
        _ coordinator: AddonCoordinator,
        selecting: Bool,
        url: String?,
        windowId: String?,
        at index: Int?,
        loadImmediately: Bool
    ) -> Tab?
    func selectAddonTab(_ coordinator: AddonCoordinator, at index: Int, mode: TabMode?)
    func closeAddonTab(_ coordinator: AddonCoordinator, at index: Int, mode: TabMode?)
    func restoreAddonTabInteraction(_ coordinator: AddonCoordinator)
}

final class AddonCoordinator: NSObject, AddonEmbedderDelegate {
    private enum UX {
        static let menuIconSize: CGFloat = 18
    }
    
    private weak var dataSource: AddonCoordinatorDataSource?
    private weak var delegate: AddonCoordinatorDelegate?
    private let sessionManager: SessionManager
    private var browserActionsBySession: [ObjectIdentifier: [String: AddonAction]] = [:]
    private var pageActionsBySession: [ObjectIdentifier: [String: AddonAction]] = [:]
    private let iconCache = NSCache<NSString, UIImage>()
    private let iconLoadingQueue = DispatchQueue(label: "com.minh-ton.Reynard.AddonCoordinator.IconLoadingQueue", qos: .utility)
    private var loadingIconIDs = Set<String>()
    private var pendingAddonDownloadPaths = Set<String>()
    private var failedIconIDs = Set<String>()
    private var pendingIconRefreshWorkItem: DispatchWorkItem?
    private var nextDownloadID = 0
    let updateCoordinator: AddonUpdateCoordinator
    
    init(
        dataSource: AddonCoordinatorDataSource,
        delegate: AddonCoordinatorDelegate,
        sessionManager: SessionManager
    ) {
        self.dataSource = dataSource
        self.delegate = delegate
        self.sessionManager = sessionManager
        updateCoordinator = AddonUpdateCoordinator()
        super.init()
        iconCache.countLimit = 64
    }
    
    // MARK: - Runtime Lifecycle
    
    func start() async {
        AddonRuntime.shared.delegate = self
        await installSafeAreaDetectorIfNeeded()
        _ = try? await AddonRuntime.shared.list()
        updateCoordinator.start()
        delegate?.refreshAddonChrome(self)
    }
    
    /// TEMPORARY DIAGNOSTIC — compares the actual, real BuildManifest.plist
    /// this app downloaded (via URLSession, in DDIManager) against a
    /// known-good, directly-verified size (805005 bytes, confirmed via
    /// curl on the same source URL) — checking whether the app's own
    /// download process might be producing something different/corrupted
    /// even though the source file itself is confirmed valid and
    /// genuinely supports this exact device model.
    private func checkDDIManifestFileSize() {
        guard let sharedDDI = ReynardDirectories.shared.sharedDDI else {
            presentDiagnosticAlert(title: "Manifest check", message: "Shared DDI location unavailable.")
            return
        }
        let manifestURL = sharedDDI.appendingPathComponent("BuildManifest.plist", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            presentDiagnosticAlert(title: "Manifest check", message: "No BuildManifest.plist found at:\n\(manifestURL.path)")
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path)
        let size = (attributes?[.size] as? Int) ?? -1
        let isValidPlist = (try? Data(contentsOf: manifestURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } != nil
        presentDiagnosticAlert(
            title: "Manifest check",
            message: "Size: \(size) bytes\n(known-good curl download was 805005 bytes)\n\nParses as valid plist: \(isValidPlist)"
        )
    }
    
    /// TEMPORARY, ONE-TIME UTILITY — deletes the DDI folder from the
    /// shared App Group container if present, forcing a completely
    /// fresh re-download on the next JIT attempt, rather than trusting
    /// whatever migrated over from the old, private location (this
    /// device's DDI was moved there for the very first time tonight,
    /// by code that had never been tested before). "Error -28:
    /// BadBuildManifest" (confirmed directly from this project's own
    /// vendored idevice source) points specifically at one of the
    /// three DDI files being malformed — a fresh download is the
    /// simplest way to rule this out. Safe to remove once confirmed
    /// either way.
    private func resetSharedDDIOnceIfNeeded() {
        guard let sharedDDI = ReynardDirectories.shared.sharedDDI,
              FileManager.default.fileExists(atPath: sharedDDI.path) else {
            presentDiagnosticAlert(title: "DDI reset", message: "No DDI folder found at the shared location — nothing to delete.")
            return
        }
        do {
            try FileManager.default.removeItem(at: sharedDDI)
            presentDiagnosticAlert(title: "DDI reset", message: "Deleted DDI folder at:\n\(sharedDDI.path)\n\nThe next JIT attempt should now trigger a completely fresh download.")
        } catch {
            presentDiagnosticAlert(title: "DDI reset failed", message: "\(error)")
        }
    }
    
    /// TEMPORARY DIAGNOSTIC — simplified after discovering
    /// SecTaskCreateFromSelf/SecTaskCopyValueForEntitlement are private
    /// APIs not actually exposed via a plain `import Security` in
    /// Swift, unlike a first attempt assumed. This version sticks to
    /// standard, already-proven Foundation APIs only: shows the real,
    /// live bundle ID, the exact group ID string this code is actually
    /// using, and whether containerURL genuinely resolves or not —
    /// directly answering the practical question that matters, without
    /// needing risky private-API declarations this late.
    private func checkLiveAppGroupEntitlement() {
        let bundleID = Bundle.main.bundleIdentifier ?? "(nil)"
        let groupID = ReynardDirectories.sharedAppGroupIdentifier()
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        presentDiagnosticAlert(
            title: "Live App Group check",
            message: "Bundle ID:\n\(bundleID)\n\nGroup ID used:\n\(groupID)\n\ncontainerURL result:\n\(String(describing: container))"
        )
        checkEmbeddedProvisioningProfile()
    }
    
    /// TEMPORARY DIAGNOSTIC — reads and displays the literal
    /// provisioning profile Apple's own servers embedded in this
    /// exact, currently-running install, via AltStore's own re-signing.
    /// The most direct possible evidence available: not a copy, not
    /// something re-extracted externally, the actual file the OS itself
    /// is using right now. embedded.mobileprovision is a CMS/PKCS7-
    /// signed envelope, not a plain plist — rather than fully decoding
    /// that signature (which needs more Security-framework APIs, one of
    /// which already turned out to be private/inaccessible tonight),
    /// this uses a simpler, well-known trick: the plist's own XML text
    /// remains directly readable within the raw file bytes regardless
    /// of the binary signature wrapped around it.
    private func checkEmbeddedProvisioningProfile() {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let rawData = try? Data(contentsOf: profileURL) else {
            presentDiagnosticAlert(title: "Provisioning profile", message: "No embedded.mobileprovision found in this app's bundle at all — AltStore's re-signing may not embed one the way Xcode normally would.")
            return
        }
        
        let rawString = String(decoding: rawData, as: UTF8.self)
        guard let xmlStart = rawString.range(of: "<?xml"),
              let plistEnd = rawString.range(of: "</plist>") else {
            presentDiagnosticAlert(title: "Provisioning profile", message: "Found the file (\(rawData.count) bytes) but couldn't locate readable plist markers inside it.")
            return
        }
        
        let plistText = String(rawString[xmlStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistText.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            presentDiagnosticAlert(title: "Provisioning profile", message: "Extracted plist text but couldn't parse it:\n\n\(plistText.prefix(2000))")
            return
        }
        
        let entitlements = plist["Entitlements"] as? [String: Any]
        let appGroupsValue = entitlements?["com.apple.security.application-groups"]
        let appIDName = plist["AppIDName"] as? String ?? "(missing)"
        let applicationIdentifierPrefix = plist["ApplicationIdentifierPrefix"] as? [String] ?? []
        
        presentDiagnosticAlert(
            title: "Provisioning profile (real, embedded)",
            message: "AppIDName:\n\(appIDName)\n\nApplicationIdentifierPrefix:\n\(applicationIdentifierPrefix)\n\nEntitlements' app-groups value:\n\(String(describing: appGroupsValue))\n\nAll entitlement keys present:\n\(entitlements?.keys.sorted().joined(separator: ", ") ?? "(none)")"
        )
    }
    
    /// Installs the signed SafeAreaDetector.xpi via the same, already-
    /// proven install(url:) path this app already uses for real,
    /// user-initiated .xpi installs — deliberately not installBuiltIn,
    /// which hit a genuine, unfixable wall tonight (this specific iOS
    /// port has no "android" resource-substitution registered at all,
    /// confirmed via two separate, real, on-device errors).
    ///
    /// Expects a file literally named "SafeAreaDetector-signed.xpi"
    /// bundled into the app's own resources (same drag-into-Xcode,
    /// folder-reference process as before, just a single file this
    /// time rather than a folder) — rename the actual file Mozilla's
    /// signing service returns to match this exact name, or update the
    /// string below to match whatever it's actually called.
    ///
    /// This install call, and everything downstream of it (the
    /// "GeckoView:WebExtension:Message" event handling, the payload
    /// extraction in AddonRuntimeEvents.swift and here in
    /// AddonCoordinator, and the pill's own two-rule layout logic) is
    /// all genuinely untested — prepared and ready, but not yet
    /// verified end to end on a real device with the real, signed file.
    private static let safeAreaDetectorAddonID = "safe-area-detector@reynard.internal"
    
    private func installSafeAreaDetectorIfNeeded() async {
        // Genuinely "if needed" now — this was previously unconditional
        // despite its own name, causing the install attempt (and its
        // diagnostic alert) to fire on every single launch rather than
        // just the first one.
        if let existing = try? await AddonRuntime.shared.addon(byID: Self.safeAreaDetectorAddonID), existing != nil {
            return
        }
        
        guard let xpiURL = Bundle.main.url(forResource: "SafeAreaDetector-signed", withExtension: "xpi") else {
            presentDiagnosticAlert(title: "SafeAreaDetector", message: "SafeAreaDetector-signed.xpi not found in app bundle — check it's added to Copy Bundle Resources under the Reynard target")
            return
        }
        do {
            let addon = try await AddonRuntime.shared.install(url: xpiURL.absoluteString)
            presentDiagnosticAlert(title: "SafeAreaDetector: Installed", message: "id: \(addon.id)\nisBuiltIn: \(addon.isBuiltIn)\n\nNow browse to any page and check for a second alert confirming the detection message was received.")
        } catch {
            presentDiagnosticAlert(title: "SafeAreaDetector: Install Failed", message: "URI tried:\n\(xpiURL.absoluteString)\n\nError:\n\(String(describing: error))")
        }
    }
    
    /// Same on-screen diagnostic pattern proven useful earlier tonight —
    /// bypasses logging entirely, which was genuinely unreliable to
    /// check. Delayed slightly to give the app time to fully launch
    /// before attempting to present anything.
    @MainActor
    private func presentDiagnosticAlert(title: String, message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                return
            }
            var topViewController = rootViewController
            while let presented = topViewController.presentedViewController {
                topViewController = presented
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            topViewController.present(alert, animated: true)
        }
    }
    
    /// New tonight, for the SafeAreaDetector addon specifically. No
    /// immediate UI refresh triggered here deliberately — the pill
    /// checks this stored value lazily, whenever it's actually about to
    /// condense, rather than needing to be proactively notified the
    /// moment a result arrives. Detection should complete well before a
    /// user starts scrolling in practice, so this simpler design avoids
    /// needing any additional notification chain at all.
    func addonController(_ controller: AddonRuntime, didReceiveNativeMessage message: [String: Any?]?, session: GeckoSession) {
        // TEMPORARY DIAGNOSTIC — on-screen, since Console.app/NSLog have
        // proven genuinely unreliable to check tonight. Fires
        // regardless of whether tab lookup or payload extraction
        // actually succeed, so a real answer either way, not just on
        // the success path.
        presentDiagnosticAlert(title: "Native message received", message: "Raw payload:\n\(String(describing: message))")
        
        guard let dataSource,
              let index = dataSource.indexOfAddonTab(for: session),
              dataSource.addonTabs.indices.contains(index) else {
            return
        }
        let tab = dataSource.addonTabs[index]
        
        // Same defensive, best-effort extraction as the GeckoView-layer
        // logging — genuinely needs verification against the real
        // payload once this actually runs.
        let payload = (message?["message"] as? [String: Any?]) ?? message
        guard let usesSafeAreaInset = payload?["usesSafeAreaInset"] as? Bool else {
            return
        }
        tab.state.usesSafeAreaInsetCSS = usesSafeAreaInset
    }
    
    func handleExternalResponse(_ response: ExternalResponseInfo) -> Bool {
        guard shouldInterceptAMOInstall(response) else {
            return false
        }
        
        pendingAddonDownloadPaths.insert(response.localFilePath)
        return true
    }
    
    func shouldContinueExternalResponse(localFilePath: String) -> Bool {
        return pendingAddonDownloadPaths.contains(localFilePath)
    }
    
    func completeExternalResponse(localFilePath: String, succeeded: Bool) -> Bool {
        guard pendingAddonDownloadPaths.remove(localFilePath) != nil else {
            return false
        }
        
        let packageFileURL = URL(fileURLWithPath: localFilePath)
        guard succeeded else {
            try? FileManager.default.removeItem(at: packageFileURL)
            return true
        }
        
        Task { @MainActor [weak self] in
            defer {
                try? FileManager.default.removeItem(at: packageFileURL)
            }
            
            do {
                _ = try await AddonRuntime.shared.install(
                    url: packageFileURL.absoluteString,
                    installMethod: .manager
                )
            } catch {
                guard let self else {
                    return
                }
                let presentation = AddonErrorPresenter.installErrorPresentation(
                    for: error,
                    addonName: nil
                )
                if !presentation.isUserCancelled {
                    self.delegate?.presentAddonAlert(self, title: nil, message: presentation.alertMessage)
                }
            }
        }
        return true
    }
    
    // MARK: - Tab State
    
    func handleTabSelectionChange(selectedIndex: Int, previousIndex: Int?) {
        let activeTabs = dataSource?.addonTabs ?? []
        if let previousIndex,
           activeTabs.indices.contains(previousIndex) {
            sessionManager.setAddonTabActive(false, for: activeTabs[previousIndex].session)
        }
        
        if activeTabs.indices.contains(selectedIndex) {
            sessionManager.setAddonTabActive(true, for: activeTabs[selectedIndex].session)
        }
    }
    
    func handleSelectedTabSessionReplacement(from previousSession: GeckoSession, to replacementSession: GeckoSession) {
        sessionManager.transferAddonTabActivation(from: previousSession, to: replacementSession)
    }
    
    private var menuAddons: [Addon] {
        guard dataSource?.isSelectedAddonTabPrivate == true else {
            return AddonRuntime.shared.installedAddons
        }
        
        return AddonRuntime.shared.installedAddons.filter { $0.metaData.allowedInPrivateBrowsing }
    }
    
    // MARK: - Menu Actions
    
    func currentSiteMenuItems() -> [AddonMenuItem] {
        guard let session = dataSource?.selectedAddonSession else {
            return []
        }

        let addons = menuAddons
        let items = addons.flatMap { addon in
            visibleActions(for: addon, session: session).map { action in
                AddonMenuItem(
                    addon: addon,
                    action: action,
                    title: action.title ?? addon.metaData.name ?? addon.id
                )
            }
        }
        return items
    }
    
    func visibleActions(for addon: Addon, session: GeckoSession) -> [AddonAction] {
        guard addon.metaData.enabled else {
            return []
        }
        
        var actions: [AddonAction] = []
        
        if let action = mergedBrowserAction(for: addon, session: session),
           action.enabled != false {
            actions.append(action)
        }
        
        if let action = mergedPageAction(for: addon, session: session),
           action.enabled == true {
            actions.append(action)
        }
        
        return actions
    }
    
    func activateMenuItem(_ item: AddonMenuItem) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.delegate?.setAddonPopupLoading(self, isLoading: true)
            
            do {
                if let url = try await AddonRuntime.shared.clickAction(kind: item.action.kind, addon: item.addon),
                   !url.isEmpty {
                    self.presentPopupAfterMenuDismissal(url: url)
                } else {
                    self.delegate?.setAddonPopupLoading(self, isLoading: false)
                }
            } catch {
                self.delegate?.setAddonPopupLoading(self, isLoading: false)
                self.delegate?.presentAddonAlert(self, title: nil, message: "\(error)")
            }
        }
    }
    
    // MARK: - AddonEmbedderDelegate
    
    func addonController(_ controller: AddonRuntime, didUpdate addon: Addon) {
        _ = addon
        if addon.metaData.enabled == false || AddonRuntime.shared.installedAddons.contains(where: { $0.id == addon.id }) == false {
            clearCachedActions(for: addon.id)
        }
        NotificationCenter.default.post(
            name: .addonRuntimeDidChange,
            object: controller,
            userInfo: ["addonID": addon.id]
        )
        delegate?.refreshAddonChrome(self)
    }
    
    func addonController(_ controller: AddonRuntime, didFailInstall failure: AddonInstallFailure) {
        _ = controller
        _ = failure
    }

    func addonController(_ controller: AddonRuntime, download request: AddonDownloadRequest) -> AddonDownloadResult? {
        guard let imported = DownloadStore.shared.importCompletedDownload(
            from: request.sourceURL,
            sourceURL: request.sourceURL,
            suggestedFileName: request.suggestedFileName,
            mimeType: request.mimeType
        ) else {
            return nil
        }
        nextDownloadID += 1
        return AddonDownloadResult(
            id: nextDownloadID,
            fileName: imported.fileURL.lastPathComponent,
            mimeType: imported.mimeType,
            fileSize: imported.fileSize
        )
    }
    
    @MainActor
    func addonController(_ controller: AddonRuntime, promptFor prompt: AddonPermissionPrompt) async -> AddonPermissionPromptResponse {
        let presentPrompt: @MainActor (AddonPermissionPrompt) async -> AddonPermissionPromptResponse = { prompt in
            await withCheckedContinuation { continuation in
                guard let delegate = self.delegate else {
                    continuation.resume(returning: .deny)
                    return
                }
                
                let promptViewController = AddonPermissionPromptViewController(prompt: prompt) { response in
                    continuation.resume(returning: response)
                }
                
                let navigationController = UINavigationController(rootViewController: promptViewController)
                navigationController.modalPresentationStyle = .pageSheet
                delegate.presentAddonViewController(self, navigationController)
            }
        }
        
        if prompt.kind == .update {
            return await updateCoordinator.responseForUpdatePrompt(prompt, presentPrompt: presentPrompt)
        }
        
        return await presentPrompt(prompt)
    }
    
    func addonController(_ controller: AddonRuntime, didUpdate action: AddonAction, for addon: Addon, session: GeckoSession?) {
        guard let session else {
            return
        }
        
        let key = ObjectIdentifier(session)
        switch action.kind {
        case .browser:
            var actions = browserActionsBySession[key] ?? [:]
            actions[addon.id] = action
            browserActionsBySession[key] = actions
        case .page:
            var actions = pageActionsBySession[key] ?? [:]
            actions[addon.id] = action
            pageActionsBySession[key] = actions
        }
        
        if session === dataSource?.selectedAddonSession {
            delegate?.refreshAddonChrome(self)
        }
    }
    
    func addonController(_ controller: AddonRuntime, didRequestOpenPopup url: String, for addon: Addon, action: AddonAction, session: GeckoSession?) {
        Task { @MainActor [weak self] in
            self?.presentPopupAfterMenuDismissal(
                url: url
            )
        }
    }
    
    func addonController(_ controller: AddonRuntime, didRequestOpenOptionsPageFor addon: Addon) {
        _ = controller
        guard let value = addon.metaData.optionsPageURL,
              URL(string: value) != nil else {
            return
        }
        
        let createTab: () -> Void = { [weak self] in
            self?.createAddonTab(
                selecting: true,
                url: value,
                loadImmediately: true
            )
        }
        
        if delegate?.dismissAddonModal(self, completion: createTab) == true {
            return
        }
        
        createTab()
    }
    
    func addonController(_ controller: AddonRuntime, createNewTabFor addon: Addon, details: AddonCreateTabDetails, newSessionID: String) -> Bool {
        _ = addon
        let createTab: () -> Void = { [weak self] in
            self?.createAddonTab(
                selecting: details.active ?? true,
                url: details.url,
                windowId: newSessionID,
                at: details.index
            )
        }
        
        if delegate?.dismissAddonModal(self, completion: createTab) != true {
            createTab()
        }
        return true
    }
    
    func addonController(_ controller: AddonRuntime, updateTab session: GeckoSession, for addon: Addon, details: AddonUpdateTabDetails) -> AllowOrDeny {
        _ = addon
        guard let dataSource,
              let index = dataSource.indexOfAddonTab(for: session) else {
            return .deny
        }
        
        if details.active == true {
            delegate?.selectAddonTab(self, at: index, mode: dataSource.selectedAddonTabMode)
        }
        
        return .allow
    }
    
    func addonController(_ controller: AddonRuntime, closeTab session: GeckoSession, for addon: Addon) -> AllowOrDeny {
        _ = addon
        guard let dataSource,
              let index = dataSource.indexOfAddonTab(for: session) else {
            return .deny
        }
        
        delegate?.closeAddonTab(self, at: index, mode: dataSource.selectedAddonTabMode)
        return .allow
    }
    
    // MARK: - Action State
    
    private func clearCachedActions(for addonID: String) {
        browserActionsBySession = browserActionsBySession.reduce(into: [:]) { result, entry in
            var actions = entry.value
            actions.removeValue(forKey: addonID)
            if !actions.isEmpty {
                result[entry.key] = actions
            }
        }
        
        pageActionsBySession = pageActionsBySession.reduce(into: [:]) { result, entry in
            var actions = entry.value
            actions.removeValue(forKey: addonID)
            if !actions.isEmpty {
                result[entry.key] = actions
            }
        }
    }
    
    private func mergedBrowserAction(for addon: Addon, session: GeckoSession) -> AddonAction? {
        let key = ObjectIdentifier(session)
        if let override = browserActionsBySession[key]?[addon.id],
           let defaultAction = addon.browserAction {
            return override.merged(with: defaultAction)
        }
        return browserActionsBySession[key]?[addon.id] ?? addon.browserAction
    }
    
    private func mergedPageAction(for addon: Addon, session: GeckoSession) -> AddonAction? {
        let key = ObjectIdentifier(session)
        if let override = pageActionsBySession[key]?[addon.id],
           let defaultAction = addon.pageAction {
            return override.merged(with: defaultAction)
        }
        return pageActionsBySession[key]?[addon.id] ?? addon.pageAction
    }
    
    private func shouldInterceptAMOInstall(_ response: ExternalResponseInfo) -> Bool {
        guard let url = URL(string: response.url),
              url.host?.lowercased() == "addons.mozilla.org" else {
            return false
        }
        
        let path = url.path.lowercased()
        return path.contains("/firefox/downloads/file/") && path.hasSuffix(".xpi")
    }
    
    // MARK: - Presentation
    
    @MainActor
    private func presentPopupAfterMenuDismissal(url: String) {
        delegate?.performAfterAddonMenuDismissal(self, work: { [weak self] in
            self?.presentPopup(url: url)
        })
    }
    
    private func presentPopup(url: String) {
        let popupViewController = AddonPopupViewController(
            url: url,
            sessionManager: sessionManager,
            openInNewTab: { [weak self] url in
                self?.openPopupURLInTab(url)
            },
            createSession: { [weak self] url, windowId in
                self?.createPopupTabSession(url: url, windowId: windowId)
            },
            didDismiss: { [weak self] in
                guard let self else {
                    return
                }
                self.delegate?.restoreAddonTabInteraction(self)
            }
        )
        
        // Hack: Use .overFullScreen so GeckoView can scroll
        popupViewController.modalPresentationStyle = .overFullScreen
        popupViewController.isModalInPresentation = true
        delegate?.presentAddonViewController(self, popupViewController)
    }
    
    // MARK: - Tab Actions
    
    @discardableResult
    private func createAddonTab(
        selecting: Bool,
        url: String?,
        windowId: String? = nil,
        at index: Int? = nil,
        loadImmediately: Bool = false
    ) -> Tab? {
        let tab = delegate?.createAddonTab(
            self,
            selecting: selecting,
            url: url,
            windowId: windowId,
            at: index,
            loadImmediately: loadImmediately
        )
        delegate?.refreshAddonChrome(self)
        return tab
    }
    
    private func openPopupURLInTab(_ url: String) {
        let createTab: () -> Void = { [weak self] in
            self?.createAddonTab(selecting: true, url: url, loadImmediately: true)
        }
        
        if delegate?.dismissAddonModal(self, completion: createTab) != true {
            createTab()
        }
    }
    
    private func createPopupTabSession(url: String, windowId: String) -> GeckoSession? {
        let session = createAddonTab(selecting: true, url: url, windowId: windowId)?.session
        _ = delegate?.dismissAddonModal(self, completion: nil)
        return session
    }
    
    // MARK: - Icons
    
    func menuIcon(for addon: Addon) -> UIImage? {
        let cacheKey = addon.id as NSString
        if let cached = iconCache.object(forKey: cacheKey) {
            return cached
        }
        return UIImage(named: "reynard.puzzlepiece.extension")
    }
    
    private func prefetchIconIfNeeded(for addon: Addon) {
        let cacheKey = addon.id as NSString
        if iconCache.object(forKey: cacheKey) != nil {
            return
        }
        if loadingIconIDs.contains(addon.id) {
            return
        }
        if failedIconIDs.contains(addon.id) {
            return
        }
        guard addon.metaData.iconURL != nil else {
            return
        }
        
        loadingIconIDs.insert(addon.id)
        let iconURL = addon.metaData.iconURL
        iconLoadingQueue.async { [weak self] in
            guard let self else {
                return
            }
            let image = AddonIconLoader.loadImage(
                from: iconURL,
                targetSize: CGSize(width: UX.menuIconSize, height: UX.menuIconSize)
            )
            DispatchQueue.main.async {
                self.loadingIconIDs.remove(addon.id)
                if let image {
                    self.iconCache.setObject(image, forKey: cacheKey)
                } else {
                    self.failedIconIDs.insert(addon.id)
                }
                if image != nil {
                    self.scheduleIconRefresh()
                }
            }
        }
    }

    private func scheduleIconRefresh() {
        pendingIconRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingIconRefreshWorkItem = nil
            self.delegate?.refreshAddonChrome(self)
        }
        pendingIconRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
    
    func prepareMenuIcons() {
        guard let session = dataSource?.selectedAddonSession else {
            return
        }

        let candidates = menuAddons.filter { addon in
                visibleActions(for: addon, session: session).isEmpty == false
            }
        candidates.forEach { prefetchIconIfNeeded(for: $0) }
    }
}
