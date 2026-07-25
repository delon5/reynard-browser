//
//  PrivateBrowsingLockPreferencesViewController.swift
//  Reynard
//

import LocalAuthentication
import UIKit

final class PrivateBrowsingLockPreferencesViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case lock

        var text: SettingsSectionText {
            return SettingsSectionText()
        }
    }

    private enum Row: CaseIterable {
        case requiresAuthentication
    }

    private let requiresAuthenticationSwitch = UISwitch()

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Private Browsing Lock", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSwitch()
        refreshDisplayedState()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard PrivateBrowsingAuthenticator.shared.isAvailable else {
            return NSLocalizedString(
                "Set a device passcode to use this feature.",
                comment: ""
            )
        }
        return NSLocalizedString(
            "When enabled, your private tabs are hidden and require Face ID, Touch ID, or your device passcode to view whenever you return to the app.",
            comment: ""
        )
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Row.allCases[indexPath.row] {
        case .requiresAuthentication:
            return switchCell(
                title: NSLocalizedString("Require Authentication", comment: ""),
                accessoryView: requiresAuthenticationSwitch
            )
        }
    }

    private func configureSwitch() {
        requiresAuthenticationSwitch.addTarget(
            self,
            action: #selector(requiresAuthenticationSwitchDidChange(_:)),
            for: .valueChanged
        )
        requiresAuthenticationSwitch.isEnabled = PrivateBrowsingAuthenticator.shared.isAvailable
    }

    private func refreshDisplayedState() {
        requiresAuthenticationSwitch.isOn = Prefs.PrivacySettings.requiresAuthenticationForPrivateTabs
    }

    @objc private func requiresAuthenticationSwitchDidChange(_ sender: UISwitch) {
        guard !sender.isOn else {
            // Turning protection ON is always safe to apply immediately.
            Prefs.PrivacySettings.requiresAuthenticationForPrivateTabs = true
            return
        }
        
        // Turning protection OFF must itself be authenticated —
        // otherwise anyone holding an unlocked phone could simply
        // disable the lock here and freely browse private tabs from
        // then on, defeating the whole point of the feature.
        PrivateBrowsingAuthenticator.shared.authenticate(
            reason: NSLocalizedString("Authenticate to turn off private browsing lock", comment: "")
        ) { result in
            switch result {
            case .success, .unavailable:
                Prefs.PrivacySettings.requiresAuthenticationForPrivateTabs = false
            case .cancelled, .failed:
                // Authentication didn't succeed — leave protection on
                // and revert the switch back to reflect that.
                sender.setOn(true, animated: true)
            }
        }
    }
    
    private func switchCell(title: String, accessoryView: UISwitch) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = title
        cell.accessoryView = accessoryView
        return cell
    }
}
