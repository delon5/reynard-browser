//
//  BrowserViewController+Translations.swift
//  Reynard
//
//  The translate bar, over the GeckoSessionTranslations API.
//
//  The engine drives this entirely: it decides a page is worth
//  offering ("GeckoView:Translations:Offer") and reports every state
//  change afterwards, including which languages it detected, whether a
//  pair was requested, and whether the engine hit an error. This file
//  is the surface for that - it invents no policy of its own beyond
//  when to hide.
//
//  Translation itself is fully local; the only network use is the
//  first download of a language pair's model through Remote Settings,
//  which is why translatePage carries a long timeout.
//

import UIKit
import GeckoView

final class TranslateBar: UIView {
    private let label = UILabel()
    private let actionButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let optionsButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// Translate, or restore the original once a page has been
    /// translated. One button, because the two are never both offered.
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Built lazily by the browser each time the menu opens. Async,
    /// because the current always/never state has to be read back from
    /// the engine - it is engine-owned and can change from elsewhere.
    var makeOptionsMenu: ((@escaping ([UIMenuElement]) -> Void) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1 / UITraitCollection.current.displayScale
        layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 2
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        dismissButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)

        optionsButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        optionsButton.setContentHuggingPriority(.required, for: .horizontal)
        // The deployment target is iOS 13, and this whole mechanism is
        // newer: UIButton.menu and UIDeferredMenuElement are 14+,
        // .uncached is 15+. Below 15 the button is simply hidden - the
        // bar still translates and restores, it just cannot offer the
        // always/never toggles, and a stale cached menu (the 14-only
        // UIDeferredMenuElement.init) would be worse than none, since
        // these toggles must reflect live engine state.
        if #available(iOS 15.0, *) {
            optionsButton.showsMenuAsPrimaryAction = true
            optionsButton.menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let build = self?.makeOptionsMenu else {
                        completion([])
                        return
                    }
                    build(completion)
                }
            ])
        } else {
            optionsButton.isHidden = true
        }

        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [label, spinner, actionButton, optionsButton, dismissButton])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showOffer(from source: String, to target: String) {
        spinner.stopAnimating()
        label.text = String(
            format: NSLocalizedString("Translate this page from %@ to %@?", comment: ""),
            Self.displayName(for: source), Self.displayName(for: target)
        )
        actionButton.setTitle(NSLocalizedString("Translate", comment: ""), for: .normal)
        actionButton.isHidden = false
    }

    func showInProgress() {
        spinner.startAnimating()
        label.text = NSLocalizedString("Translating…", comment: "")
        // Hidden rather than disabled: a second tap mid-translation
        // would start a duplicate ceremony, and the engine is already
        // the thing reporting progress.
        actionButton.isHidden = true
    }

    func showTranslated() {
        spinner.stopAnimating()
        label.text = NSLocalizedString("This page has been translated.", comment: "")
        actionButton.setTitle(NSLocalizedString("Show Original", comment: ""), for: .normal)
        actionButton.isHidden = false
    }

    func showError() {
        spinner.stopAnimating()
        label.text = NSLocalizedString("This page could not be translated.", comment: "")
        actionButton.isHidden = true
    }

    /// BCP 47 tag to something a person reads. Falls back to the raw
    /// tag rather than hiding an unknown language behind a blank.
    private static func displayName(for tag: String) -> String {
        Locale.current.localizedString(forLanguageCode: tag) ?? tag
    }

    @objc private func actionTapped() { onAction?() }
    @objc private func dismissTapped() { onDismiss?() }
}

extension BrowserViewController: TranslationsDelegate {
    // Associated-object storage, because a Swift extension cannot add a
    // stored property. The key is a heap pointer allocated once rather
    // than the address of a static var - taking `&someStaticVar` is the
    // common idiom but Swift does not guarantee that address is stable,
    // and newer compilers warn about it.
    private enum TranslationsAssociation {
        static let barKey = UnsafeRawPointer(
            UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        )
        static let stateKey = UnsafeRawPointer(
            UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        )
        static let langKey = UnsafeRawPointer(
            UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        )
    }

    /// The document language the engine detected, kept for as long as
    /// the bar is up. offeredLanguagePair is cleared once a translation
    /// starts, but the options menu still needs to name the language.
    private var detectedDocumentLanguage: String? {
        get { objc_getAssociatedObject(self, TranslationsAssociation.langKey) as? String }
        set {
            objc_setAssociatedObject(
                self, TranslationsAssociation.langKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private var translateBar: TranslateBar? {
        get { objc_getAssociatedObject(self, TranslationsAssociation.barKey) as? TranslateBar }
        set {
            objc_setAssociatedObject(
                self, TranslationsAssociation.barKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// The pair the offer was made for, so the Translate button knows
    /// what to ask for without re-reading engine state.
    private var offeredLanguagePair: (from: String, to: String)? {
        get {
            (objc_getAssociatedObject(self, TranslationsAssociation.stateKey)
                as? [String])
                .flatMap { $0.count == 2 ? (from: $0[0], to: $0[1]) : nil }
        }
        set {
            let boxed = newValue.map { [$0.from, $0.to] }
            objc_setAssociatedObject(
                self, TranslationsAssociation.stateKey, boxed,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    // MARK: - TranslationsDelegate

    func onTranslationOffer(session: GeckoSession) {
        // The offer carries no payload; the languages arrive on the
        // state change that accompanies it. Showing the bar here with
        // nothing to say would flash placeholder text, so the offer is
        // recorded by presenting only once a pair is known.
    }

    func onTranslationStateChange(session: GeckoSession, state: [String: Any?]?) {
        // The engine nests its payload under "data".
        guard let data = state?["data"] as? [String: Any] else {
            return
        }

        if data["error"] != nil, !(data["error"] is NSNull) {
            presentTranslateBarIfNeeded().showError()
            return
        }

        // A requested pair means a translation is under way or done.
        if let requested = data["requestedLanguagePair"] as? [String: Any],
           !requested.isEmpty {
            let ready = data["isEngineReady"] as? Bool ?? false
            let bar = presentTranslateBarIfNeeded()
            if ready {
                bar.showTranslated()
            } else {
                bar.showInProgress()
            }
            return
        }

        // No pair requested: this is an offer, if the engine detected a
        // supported document language that differs from the user's.
        guard let detected = data["detectedLanguages"] as? [String: Any],
              let docLang = detected["docLangTag"] as? String,
              let userLang = detected["userLangTag"] as? String,
              detected["isDocLangTagSupported"] as? Bool == true,
              docLang != userLang else {
            dismissTranslateBar()
            return
        }

        offeredLanguagePair = (from: docLang, to: userLang)
        detectedDocumentLanguage = docLang
        presentTranslateBarIfNeeded().showOffer(from: docLang, to: userLang)
    }

    // MARK: - Presentation

    @discardableResult
    private func presentTranslateBarIfNeeded() -> TranslateBar {
        if let bar = translateBar {
            return bar
        }
        let bar = TranslateBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        bar.onAction = { [weak self] in
            self?.performTranslateAction()
        }
        bar.onDismiss = { [weak self] in
            self?.dismissTranslateBar()
        }
        bar.makeOptionsMenu = { [weak self] completion in
            self?.buildTranslationOptions(completion) ?? completion([])
        }
        translateBar = bar
        return bar
    }

    public func dismissTranslateBar() {
        translateBar?.removeFromSuperview()
        translateBar = nil
        offeredLanguagePair = nil
        detectedDocumentLanguage = nil
    }

    /// Always / never for the detected language, and the site
    /// blacklist. Current state is read back from the engine each time
    /// the menu opens rather than cached, so it stays right if it was
    /// changed from somewhere else.
    ///
    /// Site level is never-only on purpose: Gecko models an
    /// always-translate list per LANGUAGE, not per site, so there is no
    /// "always translate this site" to offer.
    private func buildTranslationOptions(
        _ completion: @escaping ([UIMenuElement]) -> Void
    ) {
        guard let language = detectedDocumentLanguage,
              let session = tabManager.selectedTab?.session else {
            completion([])
            return
        }
        let name = Locale.current.localizedString(forLanguageCode: language) ?? language

        Task { @MainActor [weak self] in
            let setting = await GeckoRuntime.translationLanguageSetting(for: language)
            let neverSite = await session.neverTranslateSite()
            guard let self else {
                completion([])
                return
            }

            let always = UIAction(
                title: String(format: NSLocalizedString("Always Translate %@", comment: ""), name),
                state: setting == .always ? .on : .off
            ) { [weak self] _ in
                // Selecting an active option clears it back to "offer",
                // so the pair behaves like a three-way toggle rather
                // than a trap you cannot leave from the menu.
                self?.applyLanguageSetting(setting == .always ? .offer : .always, for: language)
            }

            let never = UIAction(
                title: String(format: NSLocalizedString("Never Translate %@", comment: ""), name),
                state: setting == .never ? .on : .off
            ) { [weak self] _ in
                self?.applyLanguageSetting(setting == .never ? .offer : .never, for: language)
            }

            let site = UIAction(
                title: NSLocalizedString("Never Translate This Site", comment: ""),
                state: neverSite ? .on : .off
            ) { [weak self] _ in
                self?.applySiteSetting(!neverSite)
            }

            completion([
                UIMenu(title: "", options: .displayInline, children: [always, never]),
                UIMenu(title: "", options: .displayInline, children: [site]),
            ])
        }
    }

    private func applyLanguageSetting(
        _ setting: TranslationLanguageSetting, for language: String
    ) {
        Task { @MainActor [weak self] in
            try? await GeckoRuntime.setTranslationLanguageSetting(setting, for: language)
            // "never" means this page should stop offering right now.
            if setting == .never {
                self?.dismissTranslateBar()
            }
        }
    }

    private func applySiteSetting(_ neverTranslate: Bool) {
        guard let session = tabManager.selectedTab?.session else {
            return
        }
        Task { @MainActor [weak self] in
            try? await session.setNeverTranslateSite(neverTranslate)
            if neverTranslate {
                self?.dismissTranslateBar()
            }
        }
    }

    private func performTranslateAction() {
        guard let session = tabManager.selectedTab?.session else {
            return
        }
        // A pair is only recorded while an offer is showing; its absence
        // means the button currently reads "Show Original".
        guard let pair = offeredLanguagePair else {
            Task { @MainActor [weak self] in
                try? await session.restoreOriginalPage()
                self?.dismissTranslateBar()
            }
            return
        }
        translateBar?.showInProgress()
        Task { @MainActor [weak self] in
            do {
                try await session.translatePage(
                    fromLanguage: pair.from, toLanguage: pair.to
                )
                // Completion is reported through the state change, which
                // is what flips the bar to "Show Original" - so only the
                // offer state is cleared here.
                self?.offeredLanguagePair = nil
            } catch {
                self?.translateBar?.showError()
            }
        }
    }
}
