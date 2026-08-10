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
    
    init(tabManager: TabManager) {
        self.tabManager = tabManager
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
            tabManager.addTransferredSession(
                session,
                url: url,
                title: title,
                selecting: true,
                at: tabManager.index(for: tabManager.selectedTabMode == .private ? .afterSelected : .end, mode: .private),
                isPrivate: true
            )
        }
    }
}
