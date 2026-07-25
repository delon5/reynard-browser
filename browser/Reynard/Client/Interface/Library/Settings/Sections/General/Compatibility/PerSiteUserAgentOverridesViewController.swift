//
//  PerSiteUserAgentOverridesViewController.swift
//  Reynard
//

import UIKit

final class PerSiteUserAgentOverridesViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case overrides

        var text: SettingsSectionText {
            return SettingsSectionText(
                footerTitle: NSLocalizedString(
                    "A user agent set here for a specific site takes priority over the global custom user agent and the Android compatibility list, for that site only.",
                    comment: ""
                )
            )
        }
    }

    private enum Row {
        case override(domain: String, userAgent: String)
        case addWebsite
    }

    private var overrides: [String: String] = [:]

    private var sortedDomains: [String] {
        return overrides.keys.sorted()
    }

    private var displayedRows: [Row] {
        return sortedDomains.map { domain in
            .override(domain: domain, userAgent: overrides[domain] ?? "")
        } + [.addWebsite]
    }

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("User Agent Overrides", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrides = Prefs.CompatibilitySettings.perSiteUserAgentOverrides
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard Section.allCases.indices.contains(section) else {
            return 0
        }
        return displayedRows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard displayedRows.indices.contains(indexPath.row) else {
            return UITableViewCell()
        }

        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        switch displayedRows[indexPath.row] {
        case .override(let domain, let userAgent):
            cell.textLabel?.text = domain
            cell.detailTextLabel?.text = userAgent
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.lineBreakMode = .byTruncatingTail
            cell.accessoryType = .disclosureIndicator
        case .addWebsite:
            cell.textLabel?.text = NSLocalizedString("Add Website…", comment: "")
            cell.textLabel?.textColor = tableView.tintColor
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard displayedRows.indices.contains(indexPath.row) else {
            return false
        }
        if case .override = displayedRows[indexPath.row] {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete,
              displayedRows.indices.contains(indexPath.row),
              case .override(let domain, _) = displayedRows[indexPath.row] else {
            return
        }
        overrides.removeValue(forKey: domain)
        Prefs.CompatibilitySettings.perSiteUserAgentOverrides = overrides
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard displayedRows.indices.contains(indexPath.row) else {
            return
        }
        switch displayedRows[indexPath.row] {
        case .override(let domain, let userAgent):
            promptForOverride(existingDomain: domain, existingUserAgent: userAgent)
        case .addWebsite:
            promptForOverride(existingDomain: nil, existingUserAgent: nil)
        }
    }

    override func sectionText(for section: Int) -> SettingsSectionText {
        guard Section.allCases.indices.contains(section) else {
            return SettingsSectionText()
        }
        return Section.allCases[section].text
    }

    private func promptForOverride(existingDomain: String?, existingUserAgent: String?) {
        let isEditing = existingDomain != nil
        let alert = UIAlertController(
            title: isEditing
                ? NSLocalizedString("Edit Website", comment: "")
                : NSLocalizedString("Add Website", comment: ""),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = NSLocalizedString("e.g. youtube.com", comment: "")
            field.text = existingDomain
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.keyboardType = .URL
            field.clearButtonMode = .whileEditing
            // Editing an existing entry's domain isn't supported here —
            // delete and re-add instead, so we don't have to reconcile
            // a rename with the dictionary's own key.
            field.isEnabled = !isEditing
        }
        alert.addTextField { field in
            field.placeholder = NSLocalizedString("User agent string", comment: "")
            field.text = existingUserAgent
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }

        let saveAction = UIAlertAction(
            title: isEditing ? NSLocalizedString("Save", comment: "") : NSLocalizedString("Add", comment: ""),
            style: .default
        ) { [weak self, weak alert] _ in
            guard let domainText = alert?.textFields?.first?.text,
                  let userAgentText = alert?.textFields?.last?.text else {
                return
            }
            self?.saveOverride(
                domain: existingDomain ?? domainText,
                userAgent: userAgentText
            )
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(saveAction)
        present(alert, animated: true)
    }

    private func saveOverride(domain: String, userAgent: String) {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedUserAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDomain.isEmpty, !trimmedUserAgent.isEmpty else {
            return
        }
        overrides[normalizedDomain] = trimmedUserAgent
        Prefs.CompatibilitySettings.perSiteUserAgentOverrides = overrides
        tableView.reloadData()
    }
}
