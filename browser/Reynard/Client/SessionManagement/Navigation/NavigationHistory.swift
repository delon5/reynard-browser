//
//  NavigationHistory.swift
//  Reynard
//
//  Created by Minh Ton on 18/6/26.
//

import Foundation

final class NavigationHistory {
    private let store: NavigationHistoryStore
    private let persistencePolicy: NavigationPersistencePolicy
    
    init(
        store: NavigationHistoryStore = .shared,
        persistencePolicy: NavigationPersistencePolicy = NavigationPersistencePolicy()
    ) {
        self.store = store
        self.persistencePolicy = persistencePolicy
    }
    
    func restoreState(
        for tabID: UUID,
        storageMode: NavigationHistoryStorageMode = .persistent
    ) -> NavigationAvailability {
        guard storageMode == .persistent else {
            return NavigationAvailability(canGoBack: false, canGoForward: false)
        }
        let snapshot = store.currentSnapshot(for: tabID)
        if snapshot.canGoBack || snapshot.canGoForward {
            _ = store.setUsesPersistedHistory(true, for: tabID)
        }
        return availability(for: tabID, sessionState: .unavailable)
    }
    
    func availability(
        for tabID: UUID,
        sessionState: SessionNavigationAvailability
    ) -> NavigationAvailability {
        let snapshot = store.currentSnapshot(for: tabID)
        // The engine's own answer is always OR-ed in, latched or not. The
        // latch says where this tab's history is KEPT, not whether the
        // engine has any; reporting canGoBack: false while the engine can
        // in fact go back disables the button and makes the engine path
        // unreachable, which is how a latched tab used to get stuck.
        return NavigationAvailability(
            canGoBack: snapshot.canGoBack || sessionState.canGoBack,
            canGoForward: snapshot.canGoForward || sessionState.canGoForward
        )
    }
    
    func record(
        to url: String,
        for tabID: UUID,
        sessionState: SessionNavigationAvailability,
        storageMode: NavigationHistoryStorageMode = .persistent
    ) -> NavigationAvailability {
        guard storageMode == .persistent,
              let persistableURL = persistencePolicy.persistableURL(from: url) else {
            return availability(for: tabID, sessionState: sessionState)
        }
        _ = store.recordNavigation(to: persistableURL, for: tabID)
        return availability(for: tabID, sessionState: sessionState)
    }
    
    func goBack(
        for tabID: UUID,
        sessionState: SessionNavigationAvailability
    ) -> NavigationTransition? {
        // Prefer the engine whenever it actually has history, latched or
        // not. usesStoredHistory is a one-way flag - restoreState() sets
        // it on any restored tab with stored entries, both fallback arms
        // re-assert it, and nothing anywhere clears it - so gating the
        // engine path on it means a tab that has been restored once never
        // uses engine traversal again, even after session state is
        // restored and the engine has a real history. The flag's job is to
        // pick the FALLBACK, which is the branch below.
        //
        // The snapshot read that used to sit here went with the term that
        // needed it: currentSnapshot is a pure read but a queue.sync one
        // that hits the filesystem, and neither arm below uses it.
        if sessionState.canGoBack {
            _ = store.goBack(for: tabID)
            return NavigationTransition(
                action: .session,
                availability: availability(for: tabID, sessionState: sessionState)
            )
        }
        
        guard let url = store.goBack(for: tabID) else {
            return nil
        }
        _ = store.setUsesPersistedHistory(true, for: tabID)
        return NavigationTransition(
            action: .load(url),
            availability: availability(for: tabID, sessionState: sessionState)
        )
    }
    
    func goForward(
        for tabID: UUID,
        sessionState: SessionNavigationAvailability
    ) -> NavigationTransition? {
        // See goBack: the latch selects the fallback, it does not veto the
        // engine, and the snapshot read went with the term that used it.
        if sessionState.canGoForward {
            _ = store.goForward(for: tabID)
            return NavigationTransition(
                action: .session,
                availability: availability(for: tabID, sessionState: sessionState)
            )
        }
        
        guard let url = store.goForward(for: tabID) else {
            return nil
        }
        _ = store.setUsesPersistedHistory(true, for: tabID)
        return NavigationTransition(
            action: .load(url),
            availability: availability(for: tabID, sessionState: sessionState)
        )
    }
    
    func useStoredHistory(for tabID: UUID) -> NavigationAvailability {
        _ = store.setUsesPersistedHistory(true, for: tabID)
        return availability(for: tabID, sessionState: .unavailable)
    }
    
    func updateCurrentHistoryThumbnail(_ image: NavigationPreviewImage?, for tabID: UUID, matching url: String) {
        store.updateCurrentHistoryThumbnail(image, for: tabID, matching: url)
    }
    
    func previewImages(for tabID: UUID) -> NavigationPreviewImages {
        let snapshot = store.currentSnapshot(for: tabID)
        return NavigationPreviewImages(backImage: snapshot.backPreviewImage, forwardImage: snapshot.forwardPreviewImage)
    }
    
    func invalidateThumbnails() {
        store.invalidateThumbnails()
    }
    
    func removeHistory(for tabID: UUID) {
        store.removeNavigationHistory(for: tabID)
    }
}
