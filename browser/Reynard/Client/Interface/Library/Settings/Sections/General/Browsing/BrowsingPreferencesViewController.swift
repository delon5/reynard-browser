//
//  BrowsingPreferencesViewController.swift
//  Reynard
//
//  Created by Minh Ton on 15/5/26.
//

import UIKit

final class BrowsingPreferencesViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case links
        case media
        case gestures
        case desktopWebsite
        
        var text: SettingsSectionText {
            switch self {
            case .links:
                return SettingsSectionText(headerTitle: NSLocalizedString("Links", comment: ""))
            case .media:
                return SettingsSectionText(headerTitle: NSLocalizedString("Media", comment: ""))
            case .gestures:
                return SettingsSectionText(headerTitle: NSLocalizedString("Gestures", comment: ""))
            case .desktopWebsite:
                return SettingsSectionText(headerTitle: NSLocalizedString("Content", comment: "Browsing settings section title"))
            }
        }
    }
    
    private enum LinksRow: CaseIterable {
        case openLinksInApps
        case showLinkPreviews
    }
    
    private enum MediaRow: CaseIterable {
        case autoplay
        case showImagePreviews
    }
    
    private enum DesktopWebsiteRow: CaseIterable {
        case allWebsites
    }
    
    private enum GesturesRow: CaseIterable {
        case swipeUpForTabSwitcher
    }
    
    private let showLinkPreviewsSwitch = UISwitch()
    private let openLinksInAppsSwitch = UISwitch()
    private let showImagePreviewsSwitch = UISwitch()
    private let swipeUpForTabSwitcherSwitch = UISwitch()
    
    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Browsing", comment: "")
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
        case .links:
            return LinksRow.allCases.count
        case .media:
            return MediaRow.allCases.count
        case .gestures:
            return GesturesRow.allCases.count
        case .desktopWebsite:
            return DesktopWebsiteRow.allCases.count
        }
    }
    
    override func sectionText(for section: Int) -> SettingsSectionText {
        guard Section.allCases.indices.contains(section) else {
            return SettingsSectionText()
        }
        return Section.allCases[section].text
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard Section.allCases.indices.contains(indexPath.section) else {
            return UITableViewCell()
        }
        
        switch Section.allCases[indexPath.section] {
        case .links:
            guard LinksRow.allCases.indices.contains(indexPath.row) else {
                return UITableViewCell()
            }
            switch LinksRow.allCases[indexPath.row] {
            case .openLinksInApps:
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.textLabel?.text = NSLocalizedString("Open Links in Apps", comment: "")
                cell.detailTextLabel?.text = NSLocalizedString("When an installed app supports the link", comment: "")
                cell.detailTextLabel?.textColor = .secondaryLabel
                cell.accessoryView = openLinksInAppsSwitch
                return cell
            case .showLinkPreviews:
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.textLabel?.text = NSLocalizedString("Show Link Previews", comment: "")
                cell.detailTextLabel?.text = NSLocalizedString("When long-pressing links", comment: "")
                cell.detailTextLabel?.textColor = .secondaryLabel
                cell.accessoryView = showLinkPreviewsSwitch
                return cell
            }
        case .media:
            guard MediaRow.allCases.indices.contains(indexPath.row) else {
                return UITableViewCell()
            }
            switch MediaRow.allCases[indexPath.row] {
            case .autoplay:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = NSLocalizedString("Autoplay", comment: "")
                cell.detailTextLabel?.text = SiteSettingsUtils.actionTitle(
                    for: SiteSettingsUtils.defaultAction(for: .autoplay),
                    permission: .autoplay
                )
                cell.accessoryType = .disclosureIndicator
                return cell
            case .showImagePreviews:
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.textLabel?.text = NSLocalizedString("Show Image Previews", comment: "")
                cell.detailTextLabel?.textColor = .secondaryLabel
                cell.accessoryView = showImagePreviewsSwitch
                return cell
            }
        case .gestures:
            guard GesturesRow.allCases.indices.contains(indexPath.row) else {
                return UITableViewCell()
            }
            switch GesturesRow.allCases[indexPath.row] {
            case .swipeUpForTabSwitcher:
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.textLabel?.text = NSLocalizedString("Swipe Up for Tab Switcher", comment: "")
                cell.detailTextLabel?.text = NSLocalizedString("Swiping up from the toolbar opens the tab switcher", comment: "")
                cell.detailTextLabel?.textColor = .secondaryLabel
                cell.accessoryView = swipeUpForTabSwitcherSwitch
                return cell
            }
        case .desktopWebsite:
            guard DesktopWebsiteRow.allCases.indices.contains(indexPath.row) else {
                return UITableViewCell()
            }
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = NSLocalizedString("Request Desktop Website", comment: "")
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard Section.allCases.indices.contains(indexPath.section) else {
            return
        }
        
        switch Section.allCases[indexPath.section] {
        case .links:
            return
        case .media:
            guard MediaRow.allCases.indices.contains(indexPath.row) else {
                return
            }
            switch MediaRow.allCases[indexPath.row] {
            case .autoplay:
                navigationController?.pushViewController(
                    SitePermissionDetailsViewController(permission: .autoplay, title: NSLocalizedString("Autoplay", comment: "")),
                    animated: true
                )
            case .showImagePreviews:
                return
            }
        case .gestures:
            return
        case .desktopWebsite:
            navigationController?.pushViewController(RequestDesktopWebsitePreferencesViewController(), animated: true)
        }
    }
    
    private func configureSwitch() {
        openLinksInAppsSwitch.addTarget(self, action: #selector(openLinksInAppsSwitchDidChange(_:)), for: .valueChanged)
        showLinkPreviewsSwitch.addTarget(self, action: #selector(showLinkPreviewsSwitchDidChange(_:)), for: .valueChanged)
        showImagePreviewsSwitch.addTarget(self, action: #selector(showImagePreviewsSwitchDidChange(_:)), for: .valueChanged)
        swipeUpForTabSwitcherSwitch.addTarget(self, action: #selector(swipeUpForTabSwitcherSwitchDidChange(_:)), for: .valueChanged)
    }
    
    private func refreshDisplayedState() {
        openLinksInAppsSwitch.isOn = Prefs.BrowsingSettings.openLinksInApps
        showLinkPreviewsSwitch.isOn = Prefs.BrowsingSettings.showLinkPreviews
        showImagePreviewsSwitch.isOn = Prefs.BrowsingSettings.showImagePreviews
        swipeUpForTabSwitcherSwitch.isOn = Prefs.BrowsingSettings.swipeUpForTabSwitcher
    }
    
    @objc private func showLinkPreviewsSwitchDidChange(_ sender: UISwitch) {
        Prefs.BrowsingSettings.showLinkPreviews = sender.isOn
    }

    @objc private func openLinksInAppsSwitchDidChange(_ sender: UISwitch) {
        Prefs.BrowsingSettings.openLinksInApps = sender.isOn
    }
    
    @objc private func showImagePreviewsSwitchDidChange(_ sender: UISwitch) {
        Prefs.BrowsingSettings.showImagePreviews = sender.isOn
    }
    
    @objc private func swipeUpForTabSwitcherSwitchDidChange(_ sender: UISwitch) {
        Prefs.BrowsingSettings.swipeUpForTabSwitcher = sender.isOn
    }
}
