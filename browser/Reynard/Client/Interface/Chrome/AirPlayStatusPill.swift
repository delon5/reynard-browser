//
//  AirPlayStatusPill.swift
//  Reynard
//

import UIKit

/// The small capsule under the status bar that says where the media
/// went: "Playing on Living Room" while an AVPlayer's video is on the
/// receiver, "AirPlay · Living Room" while the route is AirPlay and the
/// selected tab is playing something Gecko decodes. Safari draws this
/// as a placard inside the element; the app has no on-page rect for a
/// Gecko-rendered video, so the chrome carries it instead.
///
/// Owned by BrowserViewController, which pins it under the safe area
/// and tells it about fullscreen. Tapping it opens the picker, the
/// quickest way to bring the video back.
final class AirPlayStatusPill: UIControl {
    static let height: CGFloat = 32
    
    private enum UX {
        static let horizontalPadding: CGFloat = 14
        static let iconSpacing: CGFloat = 6
        static let iconPointSize: CGFloat = 13
        static let fadeDuration: TimeInterval = 0.2
        /// In fullscreen the page's controls own the surface, so the
        /// pill only announces a change and gets out of the way.
        static let fullscreenLinger: TimeInterval = 4.0
        static let highlightedAlpha: CGFloat = 0.6
        static let shadowOpacity: Float = 0.15
        static let shadowRadius: CGFloat = 8
        static let shadowOffset = CGSize(width: 0, height: 2)
    }
    
    /// Set from BrowserViewController.applyFullscreenState. Entering
    /// fullscreen hides the pill; each state change while there shows it
    /// for a few seconds.
    var isShowingFullscreenMedia = false {
        didSet {
            guard isShowingFullscreenMedia != oldValue else {
                return
            }
            lingerTimer?.invalidate()
            lingerTimer = nil
            if isShowingFullscreenMedia {
                setVisible(false)
            } else {
                refresh()
            }
        }
    }
    
    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous
        view.layer.cornerRadius = AirPlayStatusPill.height / 2
        view.isUserInteractionEnabled = false
        return view
    }()
    
    private let glassBackground = ToolbarGlassBackgroundView()
    
    private let iconView: UIImageView = {
        let configuration = UIImage.SymbolConfiguration(pointSize: UX.iconPointSize, weight: .semibold)
        let imageView = UIImageView(image: UIImage(systemName: "airplayvideo", withConfiguration: configuration))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .label
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        return imageView
    }()
    
    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        return label
    }()
    
    private var stateObserver: NSObjectProtocol?
    private var lingerTimer: Timer?
    /// The target, not isHidden: a show that lands during a fade-out
    /// must win over that fade's completion.
    private var isVisible = false
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        clipsToBounds = false
        alpha = 0
        isHidden = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        configureShadow()
        configureHierarchy()
        configureConstraints()
        addTarget(self, action: #selector(pillTapped), for: .touchUpInside)
        // The first refresh may be what builds AirPlayController.shared;
        // observing only afterwards means nothing posted while it is
        // still constructing can re-enter it through this pill.
        refresh()
        stateObserver = NotificationCenter.default.addObserver(
            forName: AirPlayController.stateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stateDidChange() }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        lingerTimer?.invalidate()
    }
    
    override var isHighlighted: Bool {
        didSet {
            contentView.alpha = isHighlighted ? UX.highlightedAlpha : 1
        }
    }
    
    /// Pins the pill under the host's safe area, centred. Convenience
    /// for the owner; the pill itself carries only its height.
    func install(in host: UIView) {
        guard superview !== host else {
            return
        }
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
            centerXAnchor.constraint(equalTo: host.safeAreaLayoutGuide.centerXAnchor),
            leadingAnchor.constraint(greaterThanOrEqualTo: host.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            trailingAnchor.constraint(lessThanOrEqualTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
    }
    
    /// Re-reads AirPlayController.state and the selected tab's playback
    /// state. The "AirPlay · X" line depends on the latter, which has no
    /// broadcast of its own, so the owner calls this when it changes.
    func refresh() {
        apply(text: currentText(), announcing: false)
    }
    
    private func stateDidChange() {
        apply(text: currentText(), announcing: true)
    }
    
    private func currentText() -> String? {
        guard Prefs.AirPlaySettings.isEnabled else {
            return nil
        }
        let state = AirPlayController.shared.state
        if state.videoActive {
            // "Apple TV" is the placard's own fallback when the route has
            // no name (placard-support.js:72-92).
            return String(format: NSLocalizedString("Playing on %@", comment: ""), state.routeName ?? "Apple TV")
        }
        if state.routeIsAirPlay,
           let routeName = state.routeName,
           SystemMediaSession.shared.selectedSnapshot?.playbackState == .playing {
            return String(format: NSLocalizedString("AirPlay · %@", comment: ""), routeName)
        }
        return nil
    }
    
    private func apply(text: String?, announcing: Bool) {
        lingerTimer?.invalidate()
        lingerTimer = nil
        guard let text else {
            setVisible(false)
            return
        }
        label.text = text
        accessibilityLabel = text
        guard isShowingFullscreenMedia else {
            setVisible(true)
            return
        }
        guard announcing else {
            setVisible(false)
            return
        }
        setVisible(true)
        lingerTimer = Timer.scheduledTimer(withTimeInterval: UX.fullscreenLinger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setVisible(false) }
        }
    }
    
    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else {
            return
        }
        isVisible = visible
        if visible {
            isHidden = false
        }
        UIView.animate(withDuration: UX.fadeDuration, animations: {
            self.alpha = visible ? 1 : 0
        }, completion: { [weak self] _ in
            guard let self, !self.isVisible else {
                return
            }
            self.isHidden = true
        })
    }
    
    @objc private func pillTapped() {
        // The iPad popover anchors on the pill rather than on nothing.
        let anchor = convert(bounds, to: nil)
        Task {
            _ = await AirPlayController.shared.presentPicker(prioritizesVideo: true, anchor: anchor)
        }
    }
    
    private func configureShadow() {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = UX.shadowOpacity
        layer.shadowRadius = UX.shadowRadius
        layer.shadowOffset = UX.shadowOffset
        layer.masksToBounds = false
    }
    
    private func configureHierarchy() {
        addSubview(contentView)
        glassBackground.install(in: contentView)
        contentView.addSubview(iconView)
        contentView.addSubview(label)
    }
    
    private func configureConstraints() {
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: AirPlayStatusPill.height),
            
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: UX.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: UX.iconSpacing),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -UX.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
}
