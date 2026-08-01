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

    /// The filename an imported script came from, without its
    /// extension. Never shown or edited - it exists so that
    /// re-importing an edited file updates the right entry even after
    /// the script has been renamed. See
    /// fix_carplay_script_origin.py.
    ///
    /// nil for scripts written in the editor, which is deliberate: they
    /// are then never silently overwritten by an import that happens to
    /// share their name.
    var origin: String?

    init(name: String, body: String, isEnabled: Bool, origin: String? = nil) {
        self.name = name
        self.body = body
        self.isEnabled = isEnabled
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case body
        case isEnabled
        case origin
    }

    /// Explicit rather than synthesised, because Swift treats a missing
    /// key as a decoding ERROR even for an optional. Without
    /// decodeIfPresent here, every script saved before `origin` existed
    /// would fail to decode and silently disappear on next launch.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        body = try container.decode(String.self, forKey: .body)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
    }
}
