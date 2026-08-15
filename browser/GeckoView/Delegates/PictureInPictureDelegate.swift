//
//  PictureInPictureDelegate.swift
//  Reynard
//
//  Created by Minh Ton on 17/7/26.
//

import AVFoundation
import os

private let pipLog = OSLog(subsystem: "com.minh-ton.Reynard", category: "PiPDebug")

public protocol PictureInPictureDelegate: AnyObject {
    func onSourceChanged(session: GeckoSession)
}

public extension PictureInPictureDelegate {
    func onSourceChanged(session: GeckoSession) {}
}

final class PictureInPictureHandler: GeckoSessionHandlerCommon {
    let moduleName: String? = nil
    let events = ["GeckoView:PictureInPicture:SourceChanged"]
    let enabled = true
    
    private weak var session: GeckoSession?
    weak var delegate: PictureInPictureDelegate?
    
    var displayLayer: CALayer? {
        return autoreleasepool {
            session?.window?.pictureInPictureDisplayLayer()
        }
    }
    
    init(session: GeckoSession) {
        self.session = session
    }
    
    @MainActor
    func handleMessage(type: String, message: [String: Any?]?) async throws -> Any? {
        os_log("handleMessage fired: type=%{public}@", log: pipLog, type: .debug, type as String)
        guard events.contains(type) else {
            throw GeckoHandlerError("unknown message \(type)")
        }
        guard let session else {
            os_log("handleMessage: session was nil/destroyed", log: pipLog, type: .debug)
            throw GeckoHandlerError("session has been destroyed")
        }
        let layer = session.window?.pictureInPictureDisplayLayer()
        os_log("handleMessage: displayLayer is %{public}@", log: pipLog, type: .debug, layer == nil ? "nil" : "present")
        delegate?.onSourceChanged(session: session)
        return nil
    }
}

func newPictureInPictureHandler(_ session: GeckoSession) -> PictureInPictureHandler {
    return PictureInPictureHandler(session: session)
}
