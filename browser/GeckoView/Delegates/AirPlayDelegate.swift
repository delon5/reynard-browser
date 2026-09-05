//
//  AirPlayDelegate.swift
//  Reynard
//
//  The session-side half of AirPlay. A page that carries Safari's
//  prefixed API (or the Remote Playback API) asks two things of the
//  embedder through the GeckoViewContent actor: "is anyone listening
//  for targets" - which decides whether the app runs an AVRouteDetector
//  - and "show me the picker". Both arrive here as plain dispatcher
//  events with no JS module behind them, the same shape as
//  PictureInPictureDelegate: the actor sends straight to the
//  dispatcher, and the value handleMessage returns is what resolves
//  the actor's sendQuery.
//
//  No AVFoundation here on purpose. The route detector, the picker and
//  the preference that gates them are the app's, and the app is the
//  only reader of Prefs; this file only carries the question across.
//

import Foundation

public protocol AirPlayDelegate: AnyObject {
    /// The page asked for the route picker. Returns "selected",
    /// "dismissed" or "unavailable" - the string the shim's
    /// remote.prompt() maps to resolve / NotAllowedError /
    /// NotSupportedError. hasVideo says whether the element has a
    /// video track, so the picker can lead with video-capable devices.
    func onShowPicker(session: GeckoSession, hasVideo: Bool) async -> String
    /// The page started or stopped listening for target availability.
    /// Reference-counted by the app per session; a session that closes
    /// drops its count through onSessionClosed.
    func onWatchAvailability(session: GeckoSession, watching: Bool)
    func onSessionClosed(session: GeckoSession)
}

public extension AirPlayDelegate {
    func onShowPicker(session: GeckoSession, hasVideo: Bool) async -> String {
        return "unavailable"
    }
    func onWatchAvailability(session: GeckoSession, watching: Bool) {}
    func onSessionClosed(session: GeckoSession) {}
}

final class AirPlayHandler: GeckoSessionHandlerCommon {
    let moduleName: String? = nil
    let events = ["GeckoView:AirPlay:ShowPicker", "GeckoView:AirPlay:Watch"]
    let enabled = true

    private weak var session: GeckoSession?
    weak var delegate: AirPlayDelegate?

    init(session: GeckoSession) {
        self.session = session
    }

    @MainActor
    func handleMessage(type: String, message: [String: Any?]?) async throws -> Any? {
        guard let session else {
            throw GeckoHandlerError("session has been destroyed")
        }
        switch type {
        case "GeckoView:AirPlay:ShowPicker":
            // No delegate is the same answer as a delegate that has
            // nothing to show: the page's promise rejects with
            // NotSupportedError rather than hanging on a query nobody
            // will answer.
            guard let delegate else {
                return "unavailable"
            }
            return await delegate.onShowPicker(
                session: session,
                hasVideo: message?["hasVideo"] as? Bool ?? true
            )
        case "GeckoView:AirPlay:Watch":
            delegate?.onWatchAvailability(
                session: session,
                watching: message?["watching"] as? Bool ?? false
            )
            return nil
        default:
            throw GeckoHandlerError("unknown message \(type)")
        }
    }
}

func newAirPlayHandler(_ session: GeckoSession) -> AirPlayHandler {
    return AirPlayHandler(session: session)
}
