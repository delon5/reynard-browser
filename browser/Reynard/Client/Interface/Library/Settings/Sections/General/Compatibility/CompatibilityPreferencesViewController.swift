//
//  CompatibilityPreferencesViewController.swift
//  Reynard
//
//  Created by Minh Ton on 18/6/26.
//

import UIKit

final class CompatibilityPreferencesViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case userAgent
        
        var text: SettingsSectionText {
            return SettingsSectionText()
        }
    }
    
    private enum Row: CaseIterable {
        case useAndroidUserAgent
        case userAgentOverrides
        case useCustomUserAgent
        case customUserAgent
        case perSiteOverrides
    }
    
    private let androidUserAgentSwitch = UISwitch()
    private let customUserAgentSwitch = UISwitch()
    
    private var displayedRows: [Row] {
        var rows: [Row] = [.useAndroidUserAgent, .useCustomUserAgent]
        if Prefs.CompatibilitySettings.useCustomUserAgent {
            rows.append(.customUserAgent)
        }
        rows.append(.perSiteOverrides)
        return rows
    }
    
    private var compatibilityUserAgentName: String {
        return Prefs.BrowsingSettings.requestDesktopWebsite ? NSLocalizedString("Desktop Firefox", comment: "") : NSLocalizedString("Firefox for Android", comment: "")
    }
    
    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Compatibility", comment: "")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configureSwitch()
        refreshDisplayedState()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshDisplayedState()
        tableView.reloadData()
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard Section.allCases.indices.contains(section) else {
            return 0
        }
        
        switch Section.allCases[section] {
        case .userAgent:
            return displayedRows.count
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard Section.allCases.indices.contains(indexPath.section),
              displayedRows.indices.contains(indexPath.row) else {
            return UITableViewCell()
        }
        
        let row = displayedRows[indexPath.row]
        switch row {
        case .useAndroidUserAgent:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Use Compatibility User Agent", comment: "")
            cell.selectionStyle = .none
            cell.accessoryView = androidUserAgentSwitch
            return cell
        case .userAgentOverrides:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("User Agent Overrides", comment: "")
            cell.accessoryType = .disclosureIndicator
            return cell
        case .useCustomUserAgent:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Use Custom User Agent", comment: "")
            cell.selectionStyle = .none
            cell.accessoryView = customUserAgentSwitch
            return cell
        case .customUserAgent:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Custom User Agent", comment: "")
            cell.detailTextLabel?.text = Prefs.CompatibilitySettings.customUserAgent.isEmpty
                ? NSLocalizedString("Not Set", comment: "")
                : Prefs.CompatibilitySettings.customUserAgent
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.lineBreakMode = .byTruncatingHead
            cell.accessoryType = .disclosureIndicator
            return cell
        case .perSiteOverrides:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("User Agent Overrides", comment: "")
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard Section.allCases.indices.contains(indexPath.section),
              displayedRows.indices.contains(indexPath.row) else {
            return
        }
        switch displayedRows[indexPath.row] {
        case .userAgentOverrides:
            navigationController?.pushViewController(UserAgentOverridesPreferencesViewController(), animated: true)
        case .customUserAgent:
            navigationController?.pushViewController(CustomUserAgentPreferencesViewController(), animated: true)
        case .perSiteOverrides:
            navigationController?.pushViewController(PerSiteUserAgentOverridesViewController(), animated: true)
        default:
            break
        }
    }
    
    override func sectionText(for section: Int) -> SettingsSectionText {
        guard Section.allCases.indices.contains(section) else {
            return SettingsSectionText()
        }
        
        let headerTitle = Section.allCases[section].text.headerTitle
        if Prefs.CompatibilitySettings.useAndroidUserAgent {
            let footerTitle = String(format: NSLocalizedString("Use the %@ user agent for all websites to improve compatibility.", comment: "User agent name placeholder"), compatibilityUserAgentName)
            return SettingsSectionText(headerTitle: headerTitle, footerTitle: footerTitle)
        }
        
        return SettingsSectionText(
            headerTitle: headerTitle,
            footerTitle: String(format: NSLocalizedString("Add websites with sign-in failures, human verification challenges, or other issues to use the %@ user agent.", comment: "User agent name placeholder"), compatibilityUserAgentName)
        )
    }
    
    private func refreshDisplayedState() {
        androidUserAgentSwitch.isOn = Prefs.CompatibilitySettings.useAndroidUserAgent
        customUserAgentSwitch.isOn = Prefs.CompatibilitySettings.useCustomUserAgent
    }
    
    private func configureSwitch() {
        androidUserAgentSwitch.addTarget(self, action: #selector(applyAndroidUserAgentPreference), for: .valueChanged)
        customUserAgentSwitch.addTarget(self, action: #selector(applyCustomUserAgentPreference), for: .valueChanged)
    }
    
    @objc private func applyCustomUserAgentPreference() {
        Prefs.CompatibilitySettings.useCustomUserAgent = customUserAgentSwitch.isOn
        tableView.reloadData()
    }
    
    @objc private func applyAndroidUserAgentPreference() {
        Prefs.CompatibilitySettings.useAndroidUserAgent = androidUserAgentSwitch.isOn
        
        guard let section = Section.allCases.firstIndex(of: .userAgent) else {
            return
        }
        if let footer = tableView.footerView(forSection: section) {
            footer.textLabel?.text = sectionText(for: section).footerTitle
            footer.sizeToFit()
        }
    }
}
