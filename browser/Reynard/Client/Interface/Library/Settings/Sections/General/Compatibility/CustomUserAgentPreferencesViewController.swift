//
//  CustomUserAgentPreferencesViewController.swift
//  Reynard
//

import UIKit

final class CustomUserAgentPreferencesViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case userAgent

        var text: SettingsSectionText {
            return SettingsSectionText(
                footerTitle: NSLocalizedString(
                    "This user agent is sent to every site that doesn't have its own override set under User Agent Overrides.",
                    comment: ""
                )
            )
        }
    }

    private let textField = UITextField()

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Custom User Agent", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        textField.text = Prefs.CompatibilitySettings.customUserAgent
        textField.placeholder = NSLocalizedString("Enter a user agent string", comment: "")
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
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
        Prefs.CompatibilitySettings.customUserAgent = textField.text ?? ""
    }
}
