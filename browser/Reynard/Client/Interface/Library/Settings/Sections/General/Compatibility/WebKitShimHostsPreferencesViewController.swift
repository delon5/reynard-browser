//
//  WebKitShimHostsPreferencesViewController.swift
//  Reynard
//
//  Extra hosts for the WebKit media-keys shim.
//
//  The shim installs Apple's legacy prefixed EME and the prefixed
//  fullscreen API on a fixed list of four hosts - the ones this pipeline
//  has actually been exercised against. Safari-targeting players are
//  common enough that the interesting question is which OTHER sites it
//  already works for, and answering that should not need a build.
//
//  Modelled on CustomUserAgentPreferencesViewController.
//

import UIKit

final class WebKitShimHostsPreferencesViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case hosts

        var text: SettingsSectionText {
            return SettingsSectionText(
                footerTitle: NSLocalizedString(
                    "Comma separated, e.g. tv.apple.com, netflix.com. Each entry matches that host and its subdomains. Prime Video, Max, HBO Max and Disney+ are always included. Reload the page after changing this.",
                    comment: ""
                )
            )
        }
    }

    private let textField = UITextField()

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Extra Shim Hosts", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        textField.text = Prefs.CompatibilitySettings.webKitShimExtraHosts
        textField.placeholder = NSLocalizedString("tv.apple.com, example.com", comment: "")
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.keyboardType = .URL
        textField.clearButtonMode = .whileEditing
        textField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            textField.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            textField.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])
        return cell
    }

    override func sectionText(for section: Int) -> SettingsSectionText {
        guard Section.allCases.indices.contains(section) else {
            return SettingsSectionText()
        }
        return Section.allCases[section].text
    }

    @objc private func textFieldDidChange() {
        Prefs.CompatibilitySettings.webKitShimExtraHosts = textField.text ?? ""
    }
}
