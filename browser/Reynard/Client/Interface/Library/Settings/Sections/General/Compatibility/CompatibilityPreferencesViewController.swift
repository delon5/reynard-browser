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
        case perSiteOverrides
        case media
        
        var text: SettingsSectionText {
            switch self {
            case .userAgent:
                return SettingsSectionText()
            case .perSiteOverrides:
                return SettingsSectionText(
                    footerTitle: NSLocalizedString(
                        "Set a specific user agent for individual websites. A site's own override, when enabled, takes priority over the settings above.",
                        comment: ""
                    )
                )
            case .media:
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("Media", comment: ""),
                    footerTitle: NSLocalizedString(
                        "Hide Media Source Extensions on sites using an iPhone Safari user agent, so video players pick the native HLS path - the only one that can carry FairPlay in this browser. Real iPhone Safari does not expose MSE either.",
                        comment: ""
                    )
                )
            }
        }
    }
    
    private enum UserAgentRow: CaseIterable {
        case useAndroidUserAgent
        case useCustomUserAgent
        case customUserAgent
    }
    
    private enum PerSiteOverridesRow: CaseIterable {
        case enableOverrides
        case manageOverrides
    }
    
    private enum MediaRow: CaseIterable {
        case hideMediaSource
    }
    
    private let androidUserAgentSwitch = UISwitch()
    private let customUserAgentSwitch = UISwitch()
    private let enablePerSiteOverridesSwitch = UISwitch()
    private let hideMediaSourceSwitch = UISwitch()
    
    private var displayedUserAgentRows: [UserAgentRow] {
        var rows: [UserAgentRow] = [.useAndroidUserAgent, .useCustomUserAgent]
        if Prefs.CompatibilitySettings.useCustomUserAgent {
            rows.append(.customUserAgent)
        }
        return rows
    }
    
    private var displayedPerSiteOverridesRows: [PerSiteOverridesRow] {
        var rows: [PerSiteOverridesRow] = [.enableOverrides]
        if Prefs.CompatibilitySettings.enablePerSiteUserAgentOverrides {
            rows.append(.manageOverrides)
        }
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
        configureSwitches()
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
            return displayedUserAgentRows.count
        case .perSiteOverrides:
            return displayedPerSiteOverridesRows.count
        case .media:
            return MediaRow.allCases.count
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard Section.allCases.indices.contains(indexPath.section) else {
            return UITableViewCell()
        }
        
        switch Section.allCases[indexPath.section] {
        case .userAgent:
            return userAgentCell(at: indexPath.row, in: tableView)
        case .perSiteOverrides:
            return perSiteOverridesCell(at: indexPath.row, in: tableView)
        case .media:
            return mediaCell(at: indexPath.row, in: tableView)
        }
    }
    
    private func userAgentCell(at row: Int, in tableView: UITableView) -> UITableViewCell {
        guard displayedUserAgentRows.indices.contains(row) else {
            return UITableViewCell()
        }
        
        switch displayedUserAgentRows[row] {
        case .useAndroidUserAgent:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Use Compatibility User Agent", comment: "")
            cell.selectionStyle = .none
            cell.accessoryView = androidUserAgentSwitch
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
        }
    }
    
    private func perSiteOverridesCell(at row: Int, in tableView: UITableView) -> UITableViewCell {
        guard displayedPerSiteOverridesRows.indices.contains(row) else {
            return UITableViewCell()
        }
        
        switch displayedPerSiteOverridesRows[row] {
        case .enableOverrides:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("User Agent Overrides", comment: "")
            cell.selectionStyle = .none
            cell.accessoryView = enablePerSiteOverridesSwitch
            return cell
        case .manageOverrides:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Manage Websites", comment: "")
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }
    
    private func mediaCell(at row: Int, in tableView: UITableView) -> UITableViewCell {
        guard MediaRow.allCases.indices.contains(row) else {
            return UITableViewCell()
        }
        
        switch MediaRow.allCases[row] {
        case .hideMediaSource:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Hide Media Source (MSE)", comment: "")
            cell.selectionStyle = .none
            cell.accessoryView = hideMediaSourceSwitch
            return cell
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard Section.allCases.indices.contains(indexPath.section) else {
            return
        }
        
        switch Section.allCases[indexPath.section] {
        case .userAgent:
            guard displayedUserAgentRows.indices.contains(indexPath.row),
                  displayedUserAgentRows[indexPath.row] == .customUserAgent else {
                return
            }
            navigationController?.pushViewController(CustomUserAgentPreferencesViewController(), animated: true)
        case .perSiteOverrides:
            guard displayedPerSiteOverridesRows.indices.contains(indexPath.row),
                  displayedPerSiteOverridesRows[indexPath.row] == .manageOverrides else {
                return
            }
            navigationController?.pushViewController(PerSiteUserAgentOverridesViewController(), animated: true)
        case .media:
            break
        }
    }
    
    override func sectionText(for section: Int) -> SettingsSectionText {
        guard Section.allCases.indices.contains(section) else {
            return SettingsSectionText()
        }
        
        switch Section.allCases[section] {
        case .userAgent:
            let headerTitle = Section.userAgent.text.headerTitle
            if Prefs.CompatibilitySettings.useAndroidUserAgent {
                let footerTitle = String(format: NSLocalizedString("Use the %@ user agent for all websites to improve compatibility.", comment: "User agent name placeholder"), compatibilityUserAgentName)
                return SettingsSectionText(headerTitle: headerTitle, footerTitle: footerTitle)
            }
            return SettingsSectionText(
                headerTitle: headerTitle,
                footerTitle: String(format: NSLocalizedString("Add websites with sign-in failures, human verification challenges, or other issues to use the %@ user agent.", comment: "User agent name placeholder"), compatibilityUserAgentName)
            )
        case .perSiteOverrides:
            return Section.perSiteOverrides.text
        case .media:
            return Section.media.text
        }
    }
    
    private func refreshDisplayedState() {
        androidUserAgentSwitch.isOn = Prefs.CompatibilitySettings.useAndroidUserAgent
        customUserAgentSwitch.isOn = Prefs.CompatibilitySettings.useCustomUserAgent
        enablePerSiteOverridesSwitch.isOn = Prefs.CompatibilitySettings.enablePerSiteUserAgentOverrides
        hideMediaSourceSwitch.isOn = Prefs.CompatibilitySettings.hideMediaSourceForSafariUA
    }
    
    private func configureSwitches() {
        androidUserAgentSwitch.addTarget(self, action: #selector(applyAndroidUserAgentPreference), for: .valueChanged)
        customUserAgentSwitch.addTarget(self, action: #selector(applyCustomUserAgentPreference), for: .valueChanged)
        enablePerSiteOverridesSwitch.addTarget(self, action: #selector(applyPerSiteOverridesPreference), for: .valueChanged)
        hideMediaSourceSwitch.addTarget(self, action: #selector(applyHideMediaSourcePreference), for: .valueChanged)
    }
    
    @objc private func applyPerSiteOverridesPreference() {
        Prefs.CompatibilitySettings.enablePerSiteUserAgentOverrides = enablePerSiteOverridesSwitch.isOn
        tableView.reloadData()
    }
    
    @objc private func applyHideMediaSourcePreference() {
        Prefs.CompatibilitySettings.hideMediaSourceForSafariUA = hideMediaSourceSwitch.isOn
        MediaCompatibilityPolicyController.applyMediaSourceVisibility()
    }
    
    @objc private func applyCustomUserAgentPreference() {
        Prefs.CompatibilitySettings.useCustomUserAgent = customUserAgentSwitch.isOn
        
        if customUserAgentSwitch.isOn, Prefs.CompatibilitySettings.useAndroidUserAgent {
            Prefs.CompatibilitySettings.useAndroidUserAgent = false
            androidUserAgentSwitch.setOn(false, animated: true)
        }
        
        tableView.reloadData()
    }
    
    @objc private func applyAndroidUserAgentPreference() {
        Prefs.CompatibilitySettings.useAndroidUserAgent = androidUserAgentSwitch.isOn
        
        // These two global user agent modes can never both meaningfully
        // apply at once — only one is ever actually used, so leaving
        // both switches "on" would be misleading about which one is
        // really in effect.
        if androidUserAgentSwitch.isOn, Prefs.CompatibilitySettings.useCustomUserAgent {
            Prefs.CompatibilitySettings.useCustomUserAgent = false
            customUserAgentSwitch.setOn(false, animated: true)
            tableView.reloadData()
            return
        }
        
        guard let section = Section.allCases.firstIndex(of: .userAgent) else {
            return
        }
        if let footer = tableView.footerView(forSection: section) {
            footer.textLabel?.text = sectionText(for: section).footerTitle
            footer.sizeToFit()
        }
    }
}
