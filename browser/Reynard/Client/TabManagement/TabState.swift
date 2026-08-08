//
//  TabState.swift
//  Reynard
//
//  Created by Minh Ton on 16/6/26.
//

import GeckoView

enum TabLoadingState: Equatable {
    case idle
    case loading(progress: Float)
    
    var isLoading: Bool {
        switch self {
        case .idle:
            return false
        case .loading:
            return true
        }
    }
    
    var progress: Float {
        switch self {
        case .idle:
            return 0
        case let .loading(progress):
            return progress
        }
    }
}

enum TabRestoreState: Equatable {
    case none
    case pending(String)
}

enum TabDisplayState: Equatable {
    case committed
    case pending(String)
}

enum TabInsertionTarget: Equatable {
    case end
    case afterSelected
    case index(Int)
}

final class TabSessionState {
    var restoreState: TabRestoreState = .none
    var displayState: TabDisplayState = .committed
    var selectionOrder = 0
    var suppressInitialNavigation = true
    var isSuppressingInitialBlankPageLoad = false
    var showsStartupHomepage = false
    var hasFirstComposite = false
    var sessionNavigationAvailability = SessionNavigationAvailability.unavailable
    var navigationState = NavigationAvailability(canGoBack: false, canGoForward: false)
    var loadingState = TabLoadingState.idle
    
    /// How the current page reserves space at its bottom edge, asked of
    /// the content process at PageStop and on location change. Decides
    /// which mechanism can move the page's content: an env() reader
    /// responds to the reported inset, a page with a bar that does not
    /// read env() only responds to the layout viewport being shortened.
    ///
    /// nil means no answer yet for this tab's current page - a fresh
    /// tab, a page still loading, or an engine without the detector -
    /// and callers must treat it as the pill's established default
    /// (float over the page) rather than guessing.
    var bottomReservation: GeckoSession.BottomReservation?

    /// Whether the page reads env(safe-area-inset-bottom), which is the
    /// condition the condensed pill's content anchor keys off.
    var usesSafeAreaInsetCSS: Bool? {
        guard let bottomReservation else {
            return nil
        }
        return bottomReservation == .readsSafeAreaInset
    }
}
