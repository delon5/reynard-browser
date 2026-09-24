//
//  ContextMenuTabActions.swift
//  Reynard
//
//  Created by Minh Ton on 16/6/26.
//

import GeckoView

enum TabOpenDisposition: Equatable {
    case currentTab
    case newTab
    case newPrivateTab
    case backgroundTab
}

struct ContextMenuTabActions {
    private let tabManager: TabManager
    private let sessionManager: SessionManager
    
    init(tabManager: TabManager, sessionManager: SessionManager) {
        self.tabManager = tabManager
        self.sessionManager = sessionManager
    }
    
    func openPreviewSession(
        _ session: GeckoSession,
        url: String,
        title: String?,
        disposition: TabOpenDisposition
    ) {
        switch disposition {
        case .currentTab:
            tabManager.replaceSelectedSession(with: session, url: url, title: title)
            
        case .newTab, .backgroundTab:
            tabManager.addTransferredSession(
                session,
                url: url,
                title: title,
                selecting: disposition != .backgroundTab,
                at: tabManager.index(for: .afterSelected, mode: tabManager.selectedTabMode),
                isPrivate: tabManager.selectedTabMode == .private
            )
            
        case .newPrivateTab:
            // The preview session takes the privacy of the tab it was
            // opened from. From a private tab it is already private and is
            // handed over as before, keeping the loaded page. From a
            // regular tab it is NOT, and wrapping it in a private Tab would
            // run a private tab on a non-private session - its cookies,
            // storage and cache shared with regular browsing. That preview
            // is closed and the URL loaded fresh in a genuinely private
            // session instead (upstream a11d8c1f, #326).
            if session.isPrivateMode {
                tabManager.addTransferredSession(
                    session,
                    url: url,
                    title: title,
                    selecting: true,
                    at: tabManager.index(for: tabManager.selectedTabMode == .private ? .afterSelected : .end, mode: .private),
                    isPrivate: true
                )
                return
            }
            sessionManager.close(session)
            let tabIndex = tabManager.createTab(
                selecting: true,
                target: tabManager.selectedTabMode == .private ? .afterSelected : .end,
                mode: .private
            )
            guard let tab = tabManager.privateTabs[safe: tabIndex] else {
                return
            }
            tabManager.browse(to: url, in: tab)
        }
    }
}
