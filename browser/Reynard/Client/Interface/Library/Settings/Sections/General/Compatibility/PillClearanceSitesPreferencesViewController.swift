//
//  PillClearanceSitesPreferencesViewController.swift
//  Reynard
//
//  User-pinned pill-clearance sites.
//
//  The automatic detector classifies how each site's bottom UI should
//  clear the floating pill, and ships pinned verdicts for the sites it
//  provably cannot classify (tv.apple.com, m.twitch.tv). This screen is
//  the user-editable version of that list: sites entered here have the
//  page end at the pill's top edge while the chrome is condensed, so
//  nothing the site draws can sit behind the pill. Answering "which
//  OTHER sites need that" should not need a build.
//
//  Modelled on WebKitShimHostsPreferencesViewController.
//

import UIKit

final class PillClearanceSitesPreferencesViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case hosts

        var text: SettingsSectionText {
            return SettingsSectionText(
                footerTitle: NSLocalizedString(
                    "Comma separated, e.g. play.hbomax.com, hbomax.com. Each entry matches that host and its subdomains. Listed sites keep their content above the floating pill by ending the page at the pill's top edge. Reload the page after changing this.",
                    comment: ""
                )
            )
        }
    }

    private let textField = UITextField()

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Pill Clearance Sites", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        textField.text = Prefs.CompatibilitySettings.pillClearanceSites
        textField.placeholder = NSLocalizedString("play.hbomax.com, example.com", comment: "")
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
        Prefs.CompatibilitySettings.pillClearanceSites = textField.text ?? ""
    }
}
