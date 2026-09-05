//
//  BrowserViewController+AddressBar.swift
//  Reynard
//
//  Created by Minh Ton on 16/6/26.
//

import AVFoundation
import UIKit
import GeckoView

extension BrowserViewController: AddressBarDelegate, AddressBarGestureDelegate {
    // MARK: - Address Bar State
    
    func refreshAddressBar() {
        let selectedTab = tabManager.selectedTab
        let displayText: String?
        if case let .pending(text) = selectedTab?.state.displayState {
            displayText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            displayText = nil
        }
        
        let selectedURL = selectedTab?.url
        browserChrome.setAddressBarText(
            displayText?.isEmpty == false ? displayText : selectedURL,
            locationText: selectedURL,
            locationTitle: selectedTab?.title,
            showsBarMenu: displayText?.isEmpty != false && selectedURL?.isEmpty == false
        )
        browserChrome.setAddressBarLoadingProgress(
            selectedTab?.state.loadingState.progress ?? 0,
            isLoading: selectedTab?.state.loadingState.isLoading ?? false
        )
        addonCoordinator.prepareMenuIcons()
        let usesDesktopWebsite = selectedTab.flatMap { tab in
            tab.url.flatMap { url in
                sessionManager.isDesktopMode(for: url, tabID: tab.id)
            }
        }
        browserChrome.updateAddressBarMenu(
            url: selectedURL,
            usesDesktopWebsite: usesDesktopWebsite,
            airPlayTitle: airPlayMenuTitle()
        )
    }
    
    /// The page menu's AirPlay row title, or nil to leave the row out.
    ///
    /// Gated the way Safari gates its button - airplay-support.js
    /// enables it only after hasPlayed: the page has to have registered
    /// media with SystemMediaSession, unless the system route already
    /// IS an AirPlay device, in which case the row is how the user gets
    /// the audio back on the phone. The row is left out only when the
    /// audio session's category has no AirPlay route to offer - .record,
    /// or .playAndRecord without .allowAirPlay, which cubeb's own
    /// capture and enumeration categories both carry - the same test
    /// AirPlayController.presentPicker refuses under, so no row rather
    /// than a row that does nothing.
    ///
    /// Re-evaluated from refreshAirPlayChrome as well as the usual
    /// refreshAddressBar callers, because media starting on a page
    /// that has finished loading changes nothing else in the bar.
    private func airPlayMenuTitle() -> String? {
        guard Prefs.AirPlaySettings.isEnabled,
              !AirPlayController.audioSessionBlocksAirPlay() else {
            return nil
        }
        // Not gated on "something has played": an inline HLS video
        // brokered to AVPlayer never registers with SystemMediaSession
        // (it has no audio track inside Gecko), so a hasPlayed test
        // built on selectedSnapshot would hide the item for exactly the
        // content AirPlay video exists for. The system picker is safe
        // to open at any time, as it is from Control Center.
        let airPlayState = AirPlayController.shared.state
        if airPlayState.routeIsAirPlay,
           let routeName = airPlayState.routeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !routeName.isEmpty {
            return String(
                format: NSLocalizedString("AirPlay: %@", comment: "AirPlay route name"),
                routeName
            )
        }
        return NSLocalizedString("AirPlay", comment: "")
    }
    
    // MARK: - AddressBarDelegate
    
    func addressBarDidRequestReloadOrStop(_ addressBar: AddressBar) {
        if tabManager.selectedTab?.session.isOpen() == false {
            reloadTerminatedTab()
            return
        }
        
        tabManager.reloadOrStopSelectedTab()
    }
    
    func addressBarAddonItems(_ addressBar: AddressBar) -> [AddressBarMenu.AddonItem] {
        addonCoordinator.currentSiteMenuItems().map { item in
            AddressBarMenu.AddonItem(
                menuItem: item,
                image: addonCoordinator.menuIcon(for: item.addon)
            )
        }
    }

    func addressBarDidRequestAddonList(_ addressBar: AddressBar) {
        browserChrome.performAfterAddressBarMenuDismissal { [weak self] in
            guard let self else { return }
            let controller = AddonQuickListViewController(
                itemProvider: { [weak self] in
                    guard let self else { return [] }
                    return self.addressBarAddonItems(addressBar)
                },
                onSelect: { [weak self] item, listController in
                    listController.dismiss(animated: true) {
                        self?.addonCoordinator.activateMenuItem(item)
                    }
                },
                onUninstall: { [weak self] addon in
                    self?.confirmAddonUninstall(addon)
                },
                onDiscover: { [weak self] listController in
                    LibrarySharedUtils.openLinkInBrowser(
                        "https://addons.mozilla.org/android/",
                        from: listController
                    )
                    self?.refreshAddressBar()
                },
                onInstallFromFile: { [weak self] packageURL in
                    guard let self else {
                        throw CancellationError()
                    }
                    let stagedURL = try await self.addonPackageStagingService.stage(
                        packageURL: packageURL
                    )
                    do {
                        _ = try await AddonRuntime.shared.install(url: stagedURL.absoluteString)
                        _ = try await AddonRuntime.shared.list()
                    } catch {
                        let installationError = error
                        do {
                            try await self.addonPackageStagingService.remove(stagedURL)
                        } catch {
                            AddonPackageStagingLog.error("Unable to remove a failed staged package", error: error)
                        }
                        throw installationError
                    }
                    do {
                        try await self.addonPackageStagingService.remove(stagedURL)
                    } catch {
                        AddonPackageStagingLog.error("Unable to remove a staged add-on package", error: error)
                    }
                },
                onUpdateAll: { [weak self] in
                    guard let self else {
                        return AddonUpdateBatchResult(updatedCount: 0, noUpdateCount: 0, pendingApprovalCount: 0, failedCount: 0)
                    }
                    let coordinator = self.addonCoordinator.updateCoordinator
                    if coordinator.hasPendingApprovals {
                        return await coordinator.completePendingUpdates { _, _ in }
                    }
                    return await coordinator.updateAllAddons { _, _ in }
                }
            )
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.modalPresentationStyle = .pageSheet
            if #available(iOS 15.0, *) {
                navigationController.sheetPresentationController?.detents = [.medium(), .large()]
                navigationController.sheetPresentationController?.prefersGrabberVisible = true
            }
            self.present(navigationController, animated: true)
        }
    }

    func addressBarCurrentPageZoomLevel(_ addressBar: AddressBar) -> Int? {
        return tabManager.selectedTab?.session.settings.pageZoom.level
    }

    func addressBarMaximumPageZoomLevel(_ addressBar: AddressBar) -> Int {
        return maximumSafePageZoomLevel()
    }

    func addressBar(_ addressBar: AddressBar, didRequestPageZoomLevel level: Int) {
        setSelectedPageZoomLevel(level)
    }
    
    func addressBarDidRequestWebsiteModeChange(_ addressBar: AddressBar) {
        guard tabManager.changeWebsiteModeForSelectedTab() else {
            return
        }
        
        refreshAddressBar()
    }
    
    func addressBarDidRequestAirPlay(_ addressBar: AddressBar) {
        // Deferred like Find in Page below: the picker is a system sheet
        // (or the app's own fallback sheet) presented from the top view
        // controller, and presenting it while the menu overlay is still
        // animating out stacks the two.
        browserChrome.performAfterAddressBarMenuDismissal {
            Task { @MainActor in
                _ = await AirPlayController.shared.presentPicker(prioritizesVideo: true)
            }
        }
    }
    
    func addressBarDidRequestFindInPage(_ addressBar: AddressBar) {
        // Deferred until the menu has gone, like the Settings entry
        // below: presenting the find bar and making its field first
        // responder while the menu is still dismissing loses the
        // keyboard.
        browserChrome.performAfterAddressBarMenuDismissal { [weak self] in
            self?.presentFindInPage()
        }
    }

    func addressBarDidRequestWebsiteSettings(_ addressBar: AddressBar) {
        presentWebsiteSettings()
    }

    func addressBarDidRequestSettings(_ addressBar: AddressBar) {
        browserChrome.performAfterAddressBarMenuDismissal { [weak self] in
            self?.presentLibrary(initialSection: .settings)
        }
    }
    
    func addressBar(_ addressBar: AddressBar, didRequestBookmarkInFavorites favorites: Bool) {
        presentBookmarkEditor(addToFavorites: favorites)
    }
    
    func addressBarShareableURL(_ addressBar: AddressBar) -> URL? {
        guard let selectedTab = tabManager.selectedTab else {
            return nil
        }
        
        return tabManager.shareableURL(for: selectedTab)
    }
    
    // MARK: - AddressBarGestureDelegate
    
    var transitionContainerView: UIView {
        return view
    }
    
    var transitionContentView: ContentView {
        return contentView
    }
    
    var chromeMode: BrowserChromeMode {
        return browserLayout.chromeMode
    }
    
    var isSearchFocused: Bool {
        return searchOverlayCoordinator.isFocused
    }
    
    var isTabOverviewPresented: Bool {
        return tabOverview.isPresented
    }
    
    var isTabOverviewTransitionRunning: Bool {
        return tabOverview.isTransitionRunning
    }
    
    var selectedTabIndex: Int {
        return tabManager.selectedTabIndex
    }
    
    var selectedTabMode: TabMode {
        return tabManager.selectedTabMode
    }
    
    var activeTabs: [Tab] {
        return tabManager.activeTabs
    }
    
    func pageBackgroundColor(for tab: Tab) -> UIColor {
        return sessionManager.pageBackgroundColor(for: tab.session)
    }
    
    func selectTabFromGesture(at index: Int, mode: TabMode) {
        tabManager.selectTab(at: index, mode: mode)
    }
    
    func createTabForSwipe() -> Int {
        let mode = tabManager.selectedTabMode
        captureTabThumbnailIfNeeded()
        homepageOverlayCoordinator.prepareHomepageForNewTab(mode: mode)
        let index = tabManager.createTab(selecting: false)
        
        if Prefs.NewTabSettings.newTabDisplayOption == .customURL {
            applyNewTabDisplayOption(toTabAt: index)
            return index
        }
        
        if let tab = tabManager.activeTabs[safe: index],
           let previewImage = homepageOverlayCoordinator.previewImage(for: tab) {
            tabManager.updateThumbnail(previewImage, forTabAt: index, mode: mode)
        }
        return index
    }
    
    func setPendingTabExpansion(at index: Int?) {
        tabBar.setPendingExpansion(at: index)
    }
    
    func presentTabOverviewFromGesture(animated: Bool) {
        setTabOverviewVisible(true, animated: animated)
    }
    
    func addressBarTransitionWillBegin(prepareForGesture: Bool) {
        toolbarController.lock(for: .addressBarTransition)
        guard prepareForGesture else {
            return
        }
        browserChrome.dismissActionBar(animated: false)
        captureTabThumbnailIfNeeded()
    }
    
    func addressBarTransitionDidEnd() {
        toolbarController.unlock(for: .addressBarTransition)
    }
    
    private func captureTabThumbnailIfNeeded() {
        if let tab = tabManager.activeTabs[safe: tabManager.selectedTabIndex],
           homepageOverlayCoordinator.needsHomepageThumbnail(for: tab) {
            if let thumbnail = homepageOverlayCoordinator.previewImage(for: tab) {
                tabManager.updateThumbnail(thumbnail, forTabAt: tabManager.selectedTabIndex, mode: tabManager.selectedTabMode)
            }
            return
        }
        
        captureThumbnail(forTabAt: tabManager.selectedTabIndex, mode: tabManager.selectedTabMode)
    }
    
    func storedContentPreview(from tab: Tab) -> UIImage? {
        guard homepageOverlayCoordinator.needsHomepageThumbnail(for: tab) else {
            return nil
        }
        
        return tab.thumbnail
    }
    
    // MARK: - Page Zoom
    
    func setSelectedPageZoomToPreviousLevel() {
        setSelectedPageZoomLevel(browserChrome.previousPageZoomLevel())
    }
    
    func setSelectedPageZoomToNextLevel() {
        setSelectedPageZoomLevel(browserChrome.nextPageZoomLevel())
    }

    func maximumSafePageZoomLevel() -> Int {
        return PageZoomViewportPolicy.maximumLevel(
            viewportWidth: Double(contentView.bounds.width),
            minimumLayoutWidth: tabManager.selectedTab?
                .session.settings.pageZoom.minimumLayoutWidth
        )
    }

    func syncSelectedPageZoomControls() {
        guard let selectedTab = tabManager.selectedTab else {
            return
        }

        browserChrome.syncPageZoomControls(
            level: selectedTab.session.settings.pageZoom.level,
            maximumLevel: maximumSafePageZoomLevel()
        )
    }
    
    func setSelectedPageZoomLevel(_ level: Int) {
        guard let selectedTab = tabManager.selectedTab,
              let url = selectedTab.url else {
            return
        }
        let effectiveLevel = PageZoomViewportPolicy.effectiveLevel(
            requestedLevel: level,
            viewportWidth: Double(contentView.bounds.width),
            minimumLayoutWidth: selectedTab.session.settings.pageZoom.minimumLayoutWidth
        )

        browserChrome.setPageZoomLevel(effectiveLevel)
        sessionManager.setPageZoom(
            effectiveLevel,
            of: selectedTab.session,
            for: url,
            tabID: selectedTab.id
        )
    }
    
    // MARK: - Website Actions

    private func confirmAddonUninstall(_ addon: Addon) {
        let addonName = addon.metaData.name ?? addon.id
        AlertPresenter.show(
            title: String(
                format: NSLocalizedString("Uninstall %@?", comment: "Add-on name"),
                addonName
            ),
            message: nil,
            buttons: [
                AlertPresenter.Button(
                    title: NSLocalizedString("Cancel", comment: ""),
                    style: .cancel
                ),
                AlertPresenter.Button(
                    title: NSLocalizedString("Uninstall", comment: ""),
                    style: .destructive
                ) { [weak self] in
                    Task { [weak self] in
                        do {
                            try await AddonRuntime.shared.uninstall(addon)
                            let installedAddons = try await AddonRuntime.shared.list()
                            guard !installedAddons.contains(where: { $0.id == addon.id }) else {
                                throw NSError(
                                    domain: "com.minh-ton.Reynard.AddonUninstall",
                                    code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Gecko still reports this add-on as installed."]
                                )
                            }
                            await MainActor.run {
                                self?.refreshAddressBar()
                                self?.browserChrome.invalidateAddressBarMenuPresentation()
                            }
                        } catch {
                            await MainActor.run {
                                AlertPresenter.show(
                                    title: NSLocalizedString(
                                        "Failed to uninstall add-on",
                                        comment: ""
                                    ),
                                    message: "\(error)"
                                )
                            }
                        }
                    }
                },
            ]
        )
    }
    
    private func presentWebsiteSettings() {
        guard let selectedTab = tabManager.selectedTab,
              let urlString = selectedTab.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: urlString),
              let settingsController = SiteSettingsViewController(
                url: url,
                session: selectedTab.session,
                trackingProtection: sessionManager.trackingProtection,
                onWebsiteModeChanged: { [weak self] mode in
                    guard let self else { return }
                    if self.tabManager.setPersistentWebsiteMode(mode, forSelectedTabWithID: selectedTab.id) {
                        self.refreshAddressBar()
                    }
                },
                onWebsiteSettingsReset: { [weak self] in
                    guard let self else { return }
                    if self.tabManager.resetWebsiteSettings(
                        forSelectedTabWithID: selectedTab.id
                    ) {
                        self.refreshAddressBar()
                    }
                }
              ) else {
            return
        }
        
        presentContentModal(settingsController)
    }
    
    private func presentBookmarkEditor(addToFavorites: Bool) {
        guard let selectedTab = tabManager.selectedTab,
              let urlString = selectedTab.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: urlString) else {
            return
        }
        
        let title = selectedTab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmarkController: EditBookmarkViewController
        if addToFavorites {
            bookmarkController = EditBookmarkViewController(
                title: title,
                url: url,
                limitsToFavorites: true
            )
        } else if let bookmark = BookmarkStore.shared.bookmark(savedFor: url) {
            bookmarkController = EditBookmarkViewController(bookmark: bookmark)
        } else {
            bookmarkController = EditBookmarkViewController(title: title, url: url)
        }
        
        presentContentModal(bookmarkController)
    }
}
