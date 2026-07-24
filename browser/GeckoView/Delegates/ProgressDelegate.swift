//
//  ProgressDelegate.swift
//  Reynard
//
//  Created by Minh Ton on 22/2/26.
//

import Foundation

// MARK: - Progress Delegate

public protocol ProgressDelegate {
    func onPageStart(session: GeckoSession, url: String)
    func onPageStop(session: GeckoSession, success: Bool)
    func onProgressChange(session: GeckoSession, progress: Int)
    /// Called whenever the engine reports an updated session state
    /// (navigation history, scroll position, or form data changed).
    /// Fires automatically on ordinary state changes, and can be
    /// requested on demand via GeckoSession.flushSessionState() — for
    /// example, right before persisting a tab's state to disk.
    func onSessionStateChange(session: GeckoSession, state: GeckoSessionState)
}

extension ProgressDelegate {
    public func onPageStart(session: GeckoSession, url: String) {}
    public func onPageStop(session: GeckoSession, success: Bool) {}
    public func onProgressChange(session: GeckoSession, progress: Int) {}
    public func onSessionStateChange(session: GeckoSession, state: GeckoSessionState) {}
}

// MARK: - Progress Events

enum ProgressEvents: String, CaseIterable {
    case pageStart = "GeckoView:PageStart"
    case pageStop = "GeckoView:PageStop"
    case progressChanged = "GeckoView:ProgressChanged"
    case securityChanged = "GeckoView:SecurityChanged"
    case stateUpdated = "GeckoView:StateUpdated"
}

// MARK: - Progress Handler

func newProgressHandler(_ session: GeckoSession) -> GeckoSessionHandler {
    GeckoSessionHandler(
        moduleName: "GeckoViewProgress",
        events: ProgressEvents.allCases.map(\.rawValue),
        session: session
    ) { @MainActor session, delegate, type, message in
        guard let event = ProgressEvents(rawValue: type) else {
            throw GeckoHandlerError("unknown message \(type)")
        }
        
        let delegate = delegate as? ProgressDelegate
        switch event {
        case .pageStart:
            guard let url = message?["uri"] as? String else {
                return nil
            }
            delegate?.onPageStart(session: session, url: url)
            return nil
        case .pageStop:
            delegate?.onPageStop(session: session, success: message?["success"] as? Bool ?? false)
            return nil
        case .progressChanged:
            delegate?.onProgressChange(session: session, progress: message?["progress"] as? Int ?? 0)
            return nil
        case .securityChanged:
            return nil
        case .stateUpdated:
            guard let update = message?["data"] as? [String: Any?] else {
                return nil
            }
            let state = session.mergeSessionStateUpdate(update)
            guard !state.isEmpty else {
                return nil
            }
            delegate?.onSessionStateChange(session: session, state: state)
            return nil
        }
    }
}
