#!/usr/bin/env python3
"""
fix_carplay_browser_view.py

Step two of CarPlay: renders an actual browser session in the car
window, replacing the geometry probe.

-------------------------------------------------------------------
WHAT STEP ONE ESTABLISHED
-------------------------------------------------------------------

    CarPlay: connected - screen 425x255 @2.0x, window 425x255,
             safeArea t0 l0 b0 r0

The entitlement provisions, the scene connects, the CPWindow is real
and renders, and an empty CPMapTemplate is accepted as root. Those were
the parts that could have failed for reasons outside our control.

Those dimensions are the simulator's. A real head unit is typically
800x480 or larger, so nothing here assumes a size - layout is driven
entirely by the window's safeAreaLayoutGuide, which is also how head
units communicate their own chrome.

-------------------------------------------------------------------
THE REMAINING QUESTION
-------------------------------------------------------------------

Whether GeckoView renders into a second UIWindow on a different
UIScreen. Gecko on mobile assumes one window per process, and CarPlay
is genuinely a separate screen with its own scale.

This is the cheapest thing that answers it. If the page appears, a
native browser on CarPlay is viable. If it comes back blank, the
fallback is the approach TDS-CarPlay uses - mirroring the phone screen
via a ReplayKit broadcast extension - which is a much larger piece of
work and worth knowing about before starting.

-------------------------------------------------------------------
WHY IT CREATES ITS OWN SESSION
-------------------------------------------------------------------

GeckoSession has a public init, open() and load(), so the car window
gets its own session directly rather than going through
SessionManager and the tab manager.

That matters for more than tidiness: CarPlay can connect BEFORE the
phone's window scene exists, and reaching through
BrowserViewController for a SessionManager would then be nil. An
independent session has no such ordering dependency.

It also means the car browser is genuinely independent - its own page,
its own history, unaffected by what the phone is doing. That was the
option chosen over mirroring.

The cost is that it has no delegates, so there is no title reporting,
no history recording, no download handling and no error pages. Step
three would wire those up through SessionManager once the rendering
question is settled. Loading a page and displaying it needs none of
them.

-------------------------------------------------------------------
LAYOUT
-------------------------------------------------------------------

Pinned to safeAreaLayoutGuide rather than bounds. The simulator
reports zero insets, but real head units do not always, and a page
drawn under CarPlay's own chrome would be partly unreadable.

GeckoView.layoutSubviews already calls session.updateViewportWidth,
so the page adapts to the car display's width without anything extra.

-------------------------------------------------------------------

Run from the repo root:
    python3 fix_carplay_browser_view.py

Safe to re-run: skipped if already applied.

App code only - build-app.sh alone. No Gecko rebuild, no new files, so
nothing to add to the Xcode target.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent


class EditError(Exception):
    pass


def apply_edit(relative_path, old, new, already_applied_marker):
    path = REPO_ROOT / relative_path
    if not path.exists():
        raise EditError(f"{relative_path}: file not found at {path}")

    content = path.read_text(encoding="utf-8")

    if already_applied_marker in content:
        print(f"  SKIP  {relative_path} (already applied)")
        return

    count = content.count(old)
    if count == 0:
        raise EditError(
            f"{relative_path}: expected text not found \u2014 paste the "
            f"current file and it can be rebuilt against it."
        )
    if count > 1:
        raise EditError(
            f"{relative_path}: expected text appears {count} times, "
            f"expected exactly 1 \u2014 refusing to guess which one."
        )

    path.write_text(content.replace(old, new, 1), encoding="utf-8")
    print(f"  OK    {relative_path}")


CARPLAY_DELEGATE = "browser/Reynard/CarPlaySceneDelegate.swift"

# --- 1: show the browser instead of the probe ---

OLD_PRESENT = '''        let probe = CarPlayProbeViewController()
        probe.templateApplicationScene = templateApplicationScene
        window.rootViewController = probe
        window.makeKeyAndVisible()'''

NEW_PRESENT = '''        // CHANGED - the browser replaces the geometry probe. See
        // fix_carplay_browser_view.py.
        let browser = CarPlayBrowserViewController()
        window.rootViewController = browser
        window.makeKeyAndVisible()'''

MARKER_PRESENT = "let browser = CarPlayBrowserViewController()"

# --- 2: the browser view controller ---

OLD_PROBE = '''/// Shows the car display's geometry on the car screen itself, so it can
/// be read without a log capture.
private final class CarPlayProbeViewController: UIViewController {
    weak var templateApplicationScene: CPTemplateApplicationScene?
    
    private let label = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        // Against the safe area rather than bounds: CarPlay chrome
        // differs by head unit and the insets are how that is
        // communicated.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshText()
    }
    
    private func refreshText() {
        let insets = view.safeAreaInsets
        var lines = ["Reynard CarPlay probe", ""]
        
        if let screen = templateApplicationScene?.carWindow.screen {
            lines.append(String(format: "screen  %.0f x %.0f @%.1fx",
                                screen.bounds.width, screen.bounds.height, screen.scale))
        }
        
        lines.append(String(format: "view    %.0f x %.0f", view.bounds.width, view.bounds.height))
        lines.append(String(format: "insets  t%.0f l%.0f b%.0f r%.0f",
                            insets.top, insets.left, insets.bottom, insets.right))
        lines.append(String(format: "idiom   %d", traitCollection.userInterfaceIdiom.rawValue))
        
        label.text = lines.joined(separator: "\\n")
    }
}'''

NEW_PROBE = '''/// An independent browser on the car display.
///
/// Creates its OWN GeckoSession rather than going through
/// SessionManager and the tab manager. That is deliberate: CarPlay can
/// connect before the phone's window scene exists, and reaching through
/// BrowserViewController for a SessionManager would be nil in that
/// case. It also makes the car browser genuinely independent of the
/// phone, which was the option chosen over mirroring.
///
/// The cost is no delegates - no title reporting, history, downloads or
/// error pages. Loading and displaying a page needs none of them, and
/// wiring them up is step three, once rendering is confirmed.
@available(iOS 14.0, *)
private final class CarPlayBrowserViewController: UIViewController {
    private let geckoView = GeckoView(frame: .zero)
    private var session: GeckoSession?
    
    /// Where the car browser starts. Deliberately something simple and
    /// obviously rendered, so a blank screen means a rendering problem
    /// rather than a slow page.
    private static let homepage = "https://example.com"
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        geckoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(geckoView)
        
        // Against the safe area rather than bounds. The simulator
        // reports zero insets, but real head units do not always, and a
        // page drawn under CarPlay's own chrome would be partly
        // unreadable.
        NSLayoutConstraint.activate([
            geckoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            geckoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            geckoView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            geckoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
        
        startSession()
    }
    
    private func startSession() {
        let session = GeckoSession()
        session.open()
        
        // Assigning the session is what embeds its window view.
        // GeckoView.layoutSubviews then calls updateViewportWidth, so
        // the page adapts to the car display without anything extra.
        geckoView.session = session
        self.session = session
        
        session.load(Self.homepage)
        
        logger(String(format: "CarPlay: browser session opened, loading %@", Self.homepage))
    }
}'''

MARKER_PROBE = "final class CarPlayBrowserViewController"

EDITS = [
    (CARPLAY_DELEGATE, OLD_PRESENT, NEW_PRESENT, MARKER_PRESENT),
    (CARPLAY_DELEGATE, OLD_PROBE, NEW_PROBE, MARKER_PROBE),
]


def main():
    print(f"Putting a browser in the car window in {REPO_ROOT}\n")
    errors = []
    for relative_path, old, new, marker in EDITS:
        try:
            apply_edit(relative_path, old, new, marker)
        except EditError as e:
            print(f"  FAIL  {relative_path}: {e}")
            errors.append(relative_path)

    if errors:
        print()
        print(f"{len(errors)} edit(s) failed \u2014 paste the file and it can")
        print("be rebuilt against the real text.")
        sys.exit(1)

    source = (REPO_ROOT / CARPLAY_DELEGATE).read_text(encoding="utf-8")

    if source.count("{") != source.count("}") or source.count("(") != source.count(")"):
        print()
        print("BALANCE CHECK FAILED \u2014 review CarPlaySceneDelegate.swift.")
        sys.exit(1)

    # The probe must be fully gone, or the file references a type that
    # no longer exists.
    if "CarPlayProbeViewController" in source:
        print()
        print("CarPlayProbeViewController is still referenced - the")
        print("replacement was incomplete.")
        sys.exit(1)

    # The map template root is required for a navigation app.
    if "CPMapTemplate()" not in source:
        print()
        print("The CPMapTemplate root is gone - a navigation app must")
        print("set one, or CarPlay rejects the interface.")
        sys.exit(1)

    for needed in ("GeckoView(frame: .zero)", "session.open()", "session.load("):
        if needed not in source:
            print()
            print(f"MISSING {needed}")
            sys.exit(1)

    print()
    print("Balance, template and session checks passed.")
    print()
    print("Plug in. example.com should render on the car display, and")
    print("the log should show")
    print("    CarPlay: browser session opened, loading https://example.com")
    print()
    print("If the screen is BLANK, that is the answer on the second-")
    print("window question - GeckoView will not render on a separate")
    print("UIScreen, and the fallback is mirroring the phone via a")
    print("ReplayKit broadcast extension, as TDS-CarPlay does.")
    print()
    print("If it RENDERS, step three is wiring delegates through")
    print("SessionManager for titles, history and navigation, plus")
    print("deciding what chrome suits the display.")


if __name__ == "__main__":
    main()
