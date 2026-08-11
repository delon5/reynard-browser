//
//  BrowserViewController+FindInPage.swift
//  Reynard
//
//  Self-contained find-in-page UI over GeckoSessionFinder. The bar is
//  created on demand, floats under the top safe area, and drives the
//  selected tab's session. Entry points: presentFindInPage() (public,
//  callable from any future menu/toolbar item) and Cmd+F, installed
//  once from applyGeckoPreferences().
//

import UIKit
import GeckoView

final class FindInPageBar: UIView, UITextFieldDelegate {
    let textField = UITextField()
    private let countLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    var onSearch: ((String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .systemBackground
        layer.cornerRadius = 12
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        textField.placeholder = "Find in page"
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.clearButtonMode = .whileEditing
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.textColor = .secondaryLabel
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previousButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        previousButton.addTarget(self, action: #selector(findPrevious), for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        nextButton.addTarget(self, action: #selector(findNext), for: .touchUpInside)
        doneButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            textField, countLabel, previousButton, nextButton, doneButton,
        ])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        updateCount(current: 0, total: -1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateCount(current: Int, total: Int) {
        // total is -1 until the engine has counted; show nothing rather
        // than a misleading 0/0 while the count is still pending.
        countLabel.text = total >= 0 ? "\(current)/\(total)" : ""
        let hasMatches = total > 0
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
    }

    @objc private func textChanged() {
        onSearch?(textField.text ?? "", false)
    }

    @objc private func findNext() {
        onSearch?(textField.text ?? "", false)
    }

    @objc private func findPrevious() {
        onSearch?(textField.text ?? "", true)
    }

    @objc private func close() {
        onClose?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSearch?(textField.text ?? "", false)
        return true
    }
}

extension BrowserViewController {
    private enum FindInPageAssociation {
        static var barKey: UInt8 = 0
    }

    private enum FindUX {
        /// Where a match should sit below the top of the content view,
        /// in POINTS - clear of the find bar, which is point-sized
        /// (safe area top + 8pt offset + ~46pt of bar). Converted to
        /// CSS pixels per page in scrollToFindMatch: as plain CSS px
        /// this held only at zoom 1, and on a ~980px desktop-viewport
        /// page (~0.4pt per CSS px) 140 CSS px was ~56pt - at or
        /// behind the bar's bottom edge, on exactly the pages that
        /// need find-in-page most.
        static let matchTargetOffsetPoints: CGFloat = 140
        /// Below this the match is close enough to where it should be;
        /// moving anyway would jerk the page while stepping between two
        /// matches that are both already on screen. Points, converted
        /// alongside the target.
        static let matchDeadBandPoints: CGFloat = 60
    }

    private var findInPageBar: FindInPageBar? {
        get { objc_getAssociatedObject(self, &FindInPageAssociation.barKey) as? FindInPageBar }
        set {
            objc_setAssociatedObject(
                self, &FindInPageAssociation.barKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Installed once at startup. Guarded by input rather than a stored
    /// flag so re-running the bootstrap can never stack duplicates.
    func setUpFindInPageKeyCommand() {
        let alreadyInstalled = (keyCommands ?? []).contains {
            $0.input == "f" && $0.modifierFlags == .command
        }
        guard !alreadyInstalled else {
            return
        }
        let command = UIKeyCommand(
            title: "Find in Page",
            action: #selector(handleFindInPageKeyCommand),
            input: "f",
            modifierFlags: .command
        )
        // Let the command fire even while web content has first-responder
        // status inside the same responder chain. iOS 15+; below that the
        // command still works, it just loses to any system binding on the
        // same key.
        if #available(iOS 15.0, *) {
            command.wantsPriorityOverSystemBehavior = true
        }
        addKeyCommand(command)
    }

    @objc private func handleFindInPageKeyCommand() {
        presentFindInPage()
    }

    public func presentFindInPage(prefill: String? = nil) {
        if let bar = findInPageBar {
            if let prefill, !prefill.isEmpty {
                bar.textField.text = prefill
                performFindInPage(prefill, backwards: false)
            }
            bar.textField.becomeFirstResponder()
            return
        }

        let bar = FindInPageBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])

        bar.onSearch = { [weak self] query, backwards in
            self?.performFindInPage(query, backwards: backwards)
        }
        bar.onClose = { [weak self] in
            self?.dismissFindInPage()
        }

        findInPageBar = bar
        // Seeded from a selection: search immediately so the match count
        // is right there, rather than making the user re-trigger it.
        if let prefill, !prefill.isEmpty {
            bar.textField.text = prefill
            performFindInPage(prefill, backwards: false)
        }
        bar.textField.becomeFirstResponder()
    }

    public func dismissFindInPage() {
        guard let bar = findInPageBar else {
            return
        }
        tabManager.selectedTab?.session.clearMatches()
        bar.textField.resignFirstResponder()
        bar.removeFromSuperview()
        findInPageBar = nil
    }

    /// Brings the current match into view.
    ///
    /// The engine's own scroll-into-view moves the LAYOUT viewport, and
    /// APZ holds the VISUAL viewport separately - so on this port the
    /// selection steps from match to match while the page stays exactly
    /// where it was. GeckoView:ScrollBy is the path that moves what is
    /// composited: it reads the visual offset and re-issues it through
    /// scrollToVisual with UPDATE_TYPE_MAIN_THREAD.
    ///
    /// clientRect is relative to the visual viewport, so the delta is
    /// "where the match is" minus "where we want it", in CSS pixels.
    /// The target, though, is dictated by the find BAR, which is
    /// point-sized - so it is converted per page through the visual
    /// viewport's CSS width (see visualViewportCSSWidth). The dead band
    /// keeps stepping between two matches that are already both on
    /// screen from jerking the page for a few pixels.
    private func scrollToFindMatch(_ result: FindInPageResult, in session: GeckoSession) async {
        guard result.found, let rect = result.clientRect else {
            return
        }
        // Points per CSS pixel: the content view's point width against
        // the visual viewport's CSS width. Falls back to 1 - the
        // previous behaviour - when the engine cannot answer, and is
        // clamped so a degenerate answer can never fling the page.
        var pointsPerCSSPixel: CGFloat = 1
        let viewWidth = contentView.bounds.width
        if viewWidth > 0, let cssWidth = await session.visualViewportCSSWidth() {
            pointsPerCSSPixel = min(max(viewWidth / cssWidth, 0.1), 4)
        }
        let delta = rect.minY - FindUX.matchTargetOffsetPoints / pointsPerCSSPixel
        guard abs(delta) > FindUX.matchDeadBandPoints / pointsPerCSSPixel else {
            return
        }
        session.scrollBy(CGPoint(x: 0, y: delta))
    }

    private func performFindInPage(_ query: String, backwards: Bool) {
        guard let session = tabManager.selectedTab?.session else {
            return
        }
        guard !query.isEmpty else {
            session.clearMatches()
            findInPageBar?.updateCount(current: 0, total: -1)
            return
        }
        Task { @MainActor [weak self] in
            guard let result = try? await session.findInPage(query, backwards: backwards) else {
                return
            }
            // The engine answers per-search; a stale response for text
            // the user already replaced is dropped by comparing against
            // the field's current contents.
            guard self?.findInPageBar?.textField.text == query else {
                return
            }
            self?.findInPageBar?.updateCount(current: result.current, total: result.total)
            await self?.scrollToFindMatch(result, in: session)
        }
    }
}
