//
//  AddonRuntimeEvents.swift
//  Reynard
//
//  Created by Minh Ton on 17/6/26.
//

import Foundation
import UIKit

extension AddonRuntime {
    @MainActor
    func handleSessionEvent(type: String, message: [String: Any?]?, session: GeckoSession) async throws -> Any? {
        switch type {
        case "GeckoView:BrowserAction:Update":
            try await handleActionUpdate(kind: .browser, message: message, session: session)
            return nil
        case "GeckoView:PageAction:Update":
            try await handleActionUpdate(kind: .page, message: message, session: session)
            return nil
        case "GeckoView:BrowserAction:OpenPopup":
            try await handleOpenPopup(kind: .browser, message: message, session: session)
            return nil
        case "GeckoView:PageAction:OpenPopup":
            try await handleOpenPopup(kind: .page, message: message, session: session)
            return nil
        case "GeckoView:WebExtension:OpenOptionsPage":
            try await handleOpenOptionsPage(message: message)
            return nil
        case "GeckoView:WebExtension:NewTab":
            return try await handleNewTab(message: message)
        case "GeckoView:WebExtension:UpdateTab":
            guard let extensionID = message?["extensionId"] as? String,
                  let addon = try await addon(byID: extensionID) else {
                throw GeckoHandlerError("tabs.update is not supported")
            }
            let details = AddonUpdateTabDetails(
                dictionary: message?["updateProperties"] as? [String: Any?] ?? [:]
            )
            if delegate?.addonController(self, updateTab: session, for: addon, details: details) == .allow {
                return nil
            }
            throw GeckoHandlerError("tabs.update is not supported")
        case "GeckoView:WebExtension:CloseTab":
            guard let extensionID = message?["extensionId"] as? String,
                  let addon = try await addon(byID: extensionID) else {
                throw GeckoHandlerError("tabs.remove is not supported")
            }
            if delegate?.addonController(self, closeTab: session, for: addon) == .allow {
                return nil
            }
            throw GeckoHandlerError("tabs.remove is not supported")
        case "GeckoView:WebExtension:CaptureVisibleTab":
            guard let view = session.window?.view(), !view.bounds.isEmpty else {
                throw GeckoHandlerError("The web content view is unavailable")
            }
            return try await AddonCaptureService.captureVisibleContent(
                view: view,
                requestedWidth: CGFloat(PayloadValue.double(message?["width"] ?? nil) ?? 0),
                requestedHeight: CGFloat(PayloadValue.double(message?["height"] ?? nil) ?? 0),
                requestedPixelScale: CGFloat(PayloadValue.double(message?["pixelScale"] ?? nil) ?? 1)
            )
        case "GeckoView:WebExtension:Message":
            // Deliberately just logging the complete, raw payload for
            // now, rather than guessing at specific key names — the
            // exact dictionary shape GeckoView actually sends for this
            // event isn't confirmed anywhere in this project or in
            // Mozilla's own public API docs (which describe the Java
            // method signature, not the underlying wire format). Once
            // this is seen for real, the actual fields can be extracted
            // properly instead of guessed at twice.
            NSLog("[SafeAreaDetector] GeckoView:WebExtension:Message received, raw payload: %@", String(describing: message))
            return nil
        default:
            throw GeckoHandlerError("Unhandled WebExtension session event \(type)")
        }
    }
}
