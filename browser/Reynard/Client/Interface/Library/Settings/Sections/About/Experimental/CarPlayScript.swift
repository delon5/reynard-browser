//
//  CarPlayScript.swift
//  Reynard
//
//  Added by fix_carplay_scripts_ui.py.
//

import Foundation

/// A user script run against pages shown on the CarPlay display.
///
/// CarPlay only ever shows what is deliberately sent to it, and its
/// base view receives no touch events - Apple's CarPlay Developer
/// Guide states this, and a tap probe on device confirmed it - so
/// scripts are the only way to influence what happens there once a
/// page has loaded.
///
/// Scripts are global rather than per-site: every enabled one runs on
/// every CarPlay page. That is deliberate for now, since the blast
/// radius is a single window and toggling one off takes a moment. The
/// main-app script loader, where a bad script would affect every tab,
/// is where URL matching earns its complexity.
struct CarPlayScript: Codable, Equatable {
    var name: String
    var body: String
    var isEnabled: Bool

    init(name: String, body: String, isEnabled: Bool) {
        self.name = name
        self.body = body
        self.isEnabled = isEnabled
    }
}
