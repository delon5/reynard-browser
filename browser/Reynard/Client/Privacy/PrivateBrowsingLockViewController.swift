//
//  PrivateBrowsingLockViewController.swift
//  Reynard
//

import UIKit

/// A full-screen cover shown over private tabs when
/// `Prefs.PrivacySettings.requiresAuthenticationForPrivateTabs` is enabled
/// and the app returns to the foreground (or launches) with private
/// browsing active. Nothing behind this view is interactive or visible
/// until the user authenticates or explicitly switches back to their
/// regular tabs.
final class PrivateBrowsingLockViewController: UIViewController {
    private enum UX {
        static let iconPointSize: CGFloat = 56
        static let contentSpacing: CGFloat = 16
        static let buttonSpacing: CGFloat = 12
        static let contentHorizontalInset: CGFloat = 32
        static let unlockButtonCornerRadius: CGFloat = 14
        static let unlockButtonHeight: CGFloat = 50
    }

    /// Called when the user taps "Unlock" (and once automatically on first
    /// appearance). The coordinator owns the actual `LAContext` call.
    var onUnlockRequested: (() -> Void)?
    /// Called when the user chooses to bail out to their regular tabs
    /// instead of authenticating.
    var onSwitchToRegularTabsRequested: (() -> Void)?

    private var hasRequestedAutomaticUnlock = false

    private let iconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "private.mode.icon"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = NSLocalizedString("Private Tabs Locked", comment: "")
        label.font = UIFont.preferredFont(forTextStyle: .title2).withWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = NSLocalizedString("Authenticate to view your private tabs.", comment: "")
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let unlockButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(NSLocalizedString("Unlock", comment: ""), for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = UX.unlockButtonCornerRadius
        return button
    }()

    private let switchToRegularTabsButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(NSLocalizedString("Switch to Regular Tabs", comment: ""), for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .appBackground
        configureHierarchy()
        configureActions()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasRequestedAutomaticUnlock else {
            logger("privateLock: lock screen appeared but automatic unlock already used - NOT re-requesting")
            return
        }

        hasRequestedAutomaticUnlock = true
        logger("privateLock: lock screen appeared, requesting automatic unlock")
        onUnlockRequested?()
    }

    private func configureHierarchy() {
        let stackView = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = UX.contentSpacing
        stackView.setCustomSpacing(UX.contentSpacing * 1.5, after: iconView)

        view.addSubview(stackView)
        view.addSubview(unlockButton)
        view.addSubview(switchToRegularTabsButton)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: UX.iconPointSize),
            iconView.heightAnchor.constraint(equalToConstant: UX.iconPointSize),

            stackView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -UX.unlockButtonHeight),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: UX.contentHorizontalInset),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -UX.contentHorizontalInset),
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            unlockButton.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: UX.contentSpacing * 2),
            unlockButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: UX.contentHorizontalInset),
            unlockButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -UX.contentHorizontalInset),
            unlockButton.heightAnchor.constraint(equalToConstant: UX.unlockButtonHeight),

            switchToRegularTabsButton.topAnchor.constraint(equalTo: unlockButton.bottomAnchor, constant: UX.buttonSpacing),
            switchToRegularTabsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func configureActions() {
        unlockButton.addTarget(self, action: #selector(unlockButtonTapped), for: .touchUpInside)
        switchToRegularTabsButton.addTarget(self, action: #selector(switchToRegularTabsButtonTapped), for: .touchUpInside)
    }

    @objc private func unlockButtonTapped() {
        onUnlockRequested?()
    }

    @objc private func switchToRegularTabsButtonTapped() {
        onSwitchToRegularTabsRequested?()
    }

}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
