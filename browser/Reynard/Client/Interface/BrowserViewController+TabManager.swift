//
//  BrowserViewController+TabManager.swift
//  Reynard
//
//  Created by Minh Ton on 15/5/26.
//

import GeckoView
import UIKit

extension BrowserViewController: TabManagerDelegate {
    func tabManager(_ tabManager: TabManager, didRequestFindInPage text: String) {
        presentFindInPage(prefill: text)
    }

    func tabManagerDidChangeTabs(_ tabManager: TabManager) {
        if let selectedTab = tabManager.selectedTab {
            if !contentView.isDisplaying(session: selectedTab.session) {
                contentView.setTab(
                    selectedTab,
                    pageBackgroundColor: sessionManager.pageBackgroundColor(for: selectedTab.session)
                )
            }
        } else {
            contentView.setTab(nil)
        }
        refreshAddressBar()
        
        if !tabOverview.isPresented {
            tabOverview.setMode(TabOverview.Mode(tabMode: tabManager.selectedTabMode), animated: false)
        }
        tabOverview.applyPendingTabChanges()
        tabBar.reloadTabs()
        updateBrowserLayout(animated: false)
        homepageOverlayCoordinator.updatePresentation(animated: false)
        tabBar.updateLayout()
    }
    
    func tabManagerDidTerminateSelectedTab(_ tabManager: TabManager) {
        guard let tab = tabManager.selectedTab else {
            return
        }
        
        contentView.showPageError(for: tab.url)
        captureThumbnail(
            forTabAt: tabManager.selectedTabIndex,
            mode: tabManager.selectedTabMode
        )
    }
    
    func tabManager(_ tabManager: TabManager, didFinishLoading session: GeckoSession) {
        contentView.didFinishLoading(session: session)
        
        // Safe-area detection runs at PageStop and can flip after a
        // page settles - the device log shows one tab reporting NO and
        // then YES as its content loaded. Re-applying the layout here
        // picks up the new verdict through
        // condensedContentBottomAnchor; applying only on selection
        // would leave it stale until the next tab switch. See
        // fix_per_tab_artificial_safe_area_inset.py.
        applyBrowserLayout(animated: false)
    }
    
    func tabManager(_ tabManager: TabManager, didSelectTabAt index: Int, previousIndex: Int?) {
        toolbarController.reset()
        tabBar.setPendingExpansion(at: nil)

        // Condensed chrome is a property of how far the user scrolled the
        // page they were on, so it must not follow them to a different
        // one: without this the incoming tab shows the pill at the top of
        // its own document, and only a downward drag there restores the
        // toolbar. Not animated - the tab switch is its own transition.
        scrollChromeCoordinator.resetVisible()

        guard let selectedTab = tabManager.activeTabs[safe: index] else {
            return
        }
        
        // The content anchor follows the SELECTED tab's own flag, so
        // switching tabs re-evaluates it - updateBrowserLayout below
        // reads condensedContentBottomAnchor. See
        // fix_per_tab_artificial_safe_area_inset.py.
        browserChrome.setAddressBarLoadingProgress(
            selectedTab.state.loadingState.progress,
            isLoading: selectedTab.state.loadingState.isLoading
        )
        refreshAddressBar()
        syncSelectedPageZoomControls()
        updateNavigationButtons()
        
        contentView.setTab(
            selectedTab,
            pageBackgroundColor: sessionManager.pageBackgroundColor(for: selectedTab.session)
        )
        addonCoordinator.handleTabSelectionChange(selectedIndex: index, previousIndex: previousIndex)
        
        if !tabOverview.isPresented && !tabOverview.isTransitionRunning {
            tabOverview.setMode(TabOverview.Mode(tabMode: tabManager.selectedTabMode), animated: false)
            tabOverview.reloadTabs()
        }
        tabBar.reloadTabs()
        homepageOverlayCoordinator.updatePresentation(animated: false)
        updateBrowserLayout(animated: false)
        
        if isShowingFullscreenMedia,
           fullscreenSession !== selectedTab.session {
            applyFullscreenState(false, for: fullscreenSession)
        }
    }
    
    func tabManagerDidUpdateSafeAreaUsage(_ tabManager: TabManager) {
        // The selected tab's verdict changed after the page was already
        // showing - a page settling, or an SPA route swapping the bottom
        // of the document. Re-run the layout so
        // condensedContentBottomAnchor is re-evaluated, and re-report the
        // reservation so the right mechanism is engaged: which of the two
        // is used depends on this verdict, and the chrome height alone may
        // not have changed. Only fires when the value actually changed, so
        // this is not a per-navigation relayout.
        applyBrowserLayout(animated: false)
    }

    func tabManager(_ tabManager: TabManager, didReplaceSelectedSession previousSession: GeckoSession, with replacementSession: GeckoSession) {
        if contentView.isDisplaying(session: previousSession) {
            contentView.setTab(
                tabManager.selectedTab,
                pageBackgroundColor: tabManager.selectedTab.map {
                    sessionManager.pageBackgroundColor(for: $0.session)
                }
            )
        }
        addonCoordinator.handleSelectedTabSessionReplacement(from: previousSession, to: replacementSession)
    }

    func tabManager(_ tabManager: TabManager, didFirstCompositeFor tabID: UUID) {
        guard pendingNewTabKeyboardFocusTabID == tabID else {
            return
        }
        isPendingNewTabContentReady = true
        fulfillPendingAutomaticKeyboardFocusIfPossible()
    }
    
    func tabManager(_ tabManager: TabManager, didRequestContentKeyboardFocusFor session: GeckoSession) {
        requestContentKeyboardFocus(for: session)
    }
    
    func tabManager(_ tabManager: TabManager, captureHistoryThumbnailForTabAt index: Int, mode: TabMode, url: String) {
        captureHistoryThumbnail(forTabAt: index, mode: mode, url: url)
    }
    
    func tabManager(_ tabManager: TabManager, didRequestContextMenuAt point: CGPoint, for element: ContextElement, in session: GeckoSession) {
        guard contentView.isDisplaying(session: session) else {
            return
        }
        
        if element.type == .image,
           let source = element.srcUri?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: source) {
            let linkURL = element.linkUri
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { URL(string: $0) }
            contextMenuCoordinator.present(
                at: point,
                target: .image(url, linkURL: linkURL),
                allowsPreview: !element.isMouseInput
            )
            return
        }
        
        guard let link = element.linkUri?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: link) else {
            return
        }
        
        contextMenuCoordinator.present(at: point, target: .link(url), allowsPreview: !element.isMouseInput)
    }
    
    func tabManager(_ tabManager: TabManager, didChangeFullscreen fullScreen: Bool, for session: GeckoSession) {
        guard tabManager.selectedTab?.session === session else {
            return
        }
        applyFullscreenState(fullScreen, for: session)
    }
    
    func tabManagerDidStartDocumentLoad(_ tabManager: TabManager) {
        // A new document starts at the top, so the chrome expands to
        // match rather than staying condensed from the previous page's
        // scroll position. Fired from pageStart, which same-document
        // navigations never produce - expanding from the .location
        // update instead had the chrome popping open on every
        // pushState/fragment change.
        scrollChromeCoordinator.resetVisible(animated: true)
    }
    
    func tabManager(_ tabManager: TabManager, didUpdateTabAt index: Int, reason: TabManagerUpdateReason) {
        guard tabManager.activeTabs.indices.contains(index) else {
            return
        }
        
        switch reason {
        case .title:
            if index == tabManager.selectedTabIndex {
                refreshAddressBar()
            }
            tabBar.reloadTab(at: index)
            tabOverview.isPresented
            ? tabOverview.refreshTab(at: index, mode: tabManager.selectedTabMode)
            : tabOverview.reloadTabs()
            
        case .location:
            if index == tabManager.selectedTabIndex {
                // Chrome expansion moved to tabManagerDidStartDocumentLoad:
                // .location also fires for same-document navigations
                // (pushState/fragment), which must not pop the chrome
                // open mid-scroll.
                contentView.noteHistoryLocationChange()
                refreshAddressBar()
                syncSelectedPageZoomControls()
                updateNavigationButtons()
                homepageOverlayCoordinator.updatePresentation(animated: true)
            }
            
        case .favicon:
            tabBar.reloadTab(at: index)
            tabOverview.isPresented
            ? tabOverview.refreshTab(at: index, mode: tabManager.selectedTabMode)
            : tabOverview.reloadTabs()
            
        case .navigationState:
            if index == tabManager.selectedTabIndex {
                updateNavigationButtons()
            }
            
        case .loading:
            if index == tabManager.selectedTabIndex {
                let tab = tabManager.activeTabs[index]
                
                // A recovered tab holds a new session, and nothing on
                // this path was rebinding the view to it - so the page
                // loaded correctly into something the view was not
                // showing. Three completed refreshes of ign.com, blank
                // every time. See fix_rebind_view_after_recovery.py.
                //
                // The same test tabManagerDidChangeTabs uses, and a
                // pointer comparison on a path that already runs.
                if !contentView.isDisplaying(session: tab.session) {
                    logger("tabRecovery: rebinding the view to the tab's new session")
                    contentView.setTab(tab)
                }
                
                browserChrome.setAddressBarLoadingProgress(
                    tab.state.loadingState.progress,
                    isLoading: tab.state.loadingState.isLoading
                )
                
                if !tab.state.loadingState.isLoading {
                    contentView.finishHistoryLoad()
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              index == self.tabManager.selectedTabIndex else {
                            return
                        }
                        
                        self.captureThumbnail(forTabAt: index, mode: self.tabManager.selectedTabMode)
                    }
                }
            }
            
        case .thumbnail:
            tabOverview.isPresented
            ? tabOverview.refreshTab(at: index, mode: tabManager.selectedTabMode)
            : tabOverview.reloadTabs()
            
        case .pageBackgroundColor:
            guard index == tabManager.selectedTabIndex else {
                return
            }
            let tab = tabManager.activeTabs[index]
            contentView.setPageBackgroundColor(sessionManager.pageBackgroundColor(for: tab.session))
        }
    }
    
    func tabManager(_ tabManager: TabManager, animateNewTabSelectionAt index: Int, completion: @escaping () -> Void) {
        guard tabManager.activeTabs.indices.contains(index) else {
            completion()
            return
        }
        
        let selectedIndex = tabManager.selectedTabIndex
        let selectedMode = tabManager.selectedTabMode
        captureThumbnail(forTabAt: selectedIndex, mode: selectedMode) { [weak self] _ in
            guard let self,
                  tabManager.activeTabs.indices.contains(index) else {
                completion()
                return
            }
            
            self.tabBar.setPendingExpansion(at: index)
            self.browserChrome.animateAutomaticNewTabTransition(to: tabManager.activeTabs[index], completion: completion)
        }
    }
    
    func tabManager(_ tabManager: TabManager, didRequestDownload download: DownloadStore.PendingDownload) {
        DispatchQueue.main.async { [weak self] in
            self?.downloadsCoordinator.enqueueConfirmation(download)
        }
    }
    
    func tabManager(_ tabManager: TabManager, shouldStartExternalResponse response: ExternalResponseInfo, for session: GeckoSession) async -> Bool {
        if addonCoordinator.handleExternalResponse(response) {
            return true
        }
        guard let download = DownloadStore.shared.pendingDownload(from: response) else {
            return false
        }
        return await downloadsCoordinator.confirm(download)
    }
    
    func tabManager(_ tabManager: TabManager, shouldContinueExternalResponseAt localFilePath: String, bytesReceived: Int64) -> Bool {
        if addonCoordinator.shouldContinueExternalResponse(localFilePath: localFilePath) {
            return true
        }
        return DownloadStore.shared.updateCapturedDownload(
            localFilePath: localFilePath,
            bytesReceived: bytesReceived
        )
    }
    
    func tabManager(_ tabManager: TabManager, didCompleteExternalResponseAt localFilePath: String, succeeded: Bool) {
        if addonCoordinator.completeExternalResponse(
            localFilePath: localFilePath,
            succeeded: succeeded
        ) {
            return
        }
        DownloadStore.shared.completeCapturedDownload(
            localFilePath: localFilePath,
            succeeded: succeeded
        )
    }
    
    func reloadTerminatedTab() {
        guard tabManager.selectedTab?.session.isOpen() == false else {
            return
        }
        
        let index = tabManager.selectedTabIndex
        let mode = tabManager.selectedTabMode
        tabManager.selectTab(at: index, mode: mode)
    }
}

extension BrowserViewController {
    func applyNewTabDisplayOption(toTabAt index: Int) {
        switch Prefs.NewTabSettings.newTabDisplayOption {
        case .homepage, .blankPage:
            captureThumbnail(forTabAt: index, mode: tabManager.selectedTabMode)
        case .customURL:
            guard let tab = tabManager.activeTabs[safe: index],
                  URLUtils.isWebURL(Prefs.NewTabSettings.customNewTabURL) else {
                return
            }
            
            tabManager.browse(to: Prefs.NewTabSettings.customNewTabURL, in: tab)
        }
    }
    
    func captureThumbnail(forTabAt index: Int, mode: TabMode, completion: ((UIImage?) -> Void)? = nil) {
        let targetTabs = mode == .private ? tabManager.privateTabs : tabManager.regularTabs
        guard let targetTab = targetTabs[safe: index] else {
            completion?(nil)
            return
        }
        
        let targetTabID = targetTab.id
        if homepageOverlayCoordinator.needsHomepageThumbnail(for: targetTab) {
            homepageOverlayCoordinator.captureHomepageThumbnail(targetTab) { [weak self] thumbnail in
                guard let self,
                      let thumbnail,
                      (mode == .private ? self.tabManager.privateTabs : self.tabManager.regularTabs)[safe: index]?.id == targetTabID else {
                    completion?(nil)
                    return
                }
                
                self.tabManager.updateThumbnail(thumbnail, forTabAt: index, mode: mode)
                completion?(thumbnail)
            }
            return
        }
        
        guard mode == tabManager.selectedTabMode,
              index == tabManager.selectedTabIndex,
              let tab = tabManager.activeTabs[safe: index],
              tab.id == targetTabID,
              !contentView.isHidden,
              contentView.isDisplaying(session: tab.session) else {
            completion?(nil)
            return
        }
        
        guard let thumbnail = contentView.makeWebThumbnail() else {
            completion?(nil)
            return
        }
        
        tabManager.updateThumbnail(thumbnail, forTabAt: index, mode: mode)
        completion?(thumbnail)
    }
    
    func captureOutgoingHistoryThumbnail() {
        guard let url = tabManager.selectedTab?.url else {
            return
        }
        
        captureHistoryThumbnail(
            forTabAt: tabManager.selectedTabIndex,
            mode: tabManager.selectedTabMode,
            url: url
        )
    }
    
    private func captureHistoryThumbnail(
        forTabAt index: Int,
        mode: TabMode,
        url: String
    ) {
        guard mode == tabManager.selectedTabMode,
              index == tabManager.selectedTabIndex,
              let tab = tabManager.activeTabs[safe: index],
              tab.url == url,
              !contentView.isHidden,
              contentView.isDisplaying(session: tab.session) else {
            return
        }
        
        guard let thumbnail = contentView.makeWebThumbnail() else {
            return
        }
        
        tabManager.updateThumbnail(thumbnail, forTabAt: index, mode: mode)
        tabManager.updateHistoryThumbnail(thumbnail, for: tab, url: url)
    }
}
