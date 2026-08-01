//
//  CarPlaySendActivity.swift
//  Reynard
//
//  Added by fix_send_to_carplay.py.
//

import CarPlay
import GeckoView
import UIKit

/// Loads a URL onto the CarPlay display from the phone's share sheet.
///
/// The car display cannot be touched - Apple's CarPlay Developer Guide
/// states the base view "won't receive direct tap or drag events", and
/// a tap probe on device logged nothing, confirming it. So navigation
/// has to come from the phone, where there is a keyboard and the
/// existing tabs.
///
/// canPerform returns false when CarPlay is not connected, so the row
/// does not appear at all rather than showing a dead option.
@available(iOS 14.0, *)
final class CarPlaySendActivity: UIActivity {
    private var url: URL?

    override var activityTitle: String? {
        NSLocalizedString("Send to CarPlay", comment: "")
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "car")
    }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.minh-ton.Reynard.sendToCarPlay")
    }

    override class var activityCategory: UIActivity.Category {
        .action
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        guard CarPlaySceneDelegate.currentSession != nil else {
            return false
        }
        return activityItems.contains { $0 is URL }
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        url = activityItems.compactMap { $0 as? URL }.first
    }

    override func perform() {
        guard let url, let session = CarPlaySceneDelegate.currentSession else {
            activityDidFinish(false)
            return
        }

        session.load(url.absoluteString)
        logger(String(format: "CarPlay: sent %@ to the car display", url.absoluteString))
        activityDidFinish(true)
    }
}
