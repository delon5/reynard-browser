//
//  ExperimentalFeaturesViewController.swift
//  Reynard
//
//  Created by Minh Ton on 19/7/26.
//

import UIKit

final class ExperimentalFeaturesViewController: SettingsTableViewController {
    private enum UX {
        static let restartDelay = 1
    }
    
    private enum Section: CaseIterable {
        case features
        case jitDiagnostics
        
        var text: SettingsSectionText {
            switch self {
            case .features:
                return SettingsSectionText()
            case .jitDiagnostics:
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("JIT Diagnostics", comment: ""),
                    footerTitle: NSLocalizedString("Deletes the downloaded Developer Disk Image from both the shared and private storage locations, forcing a completely fresh download and mount on the next JIT attempt.", comment: "")
                )
            }
        }
    }
    
    private enum Row: CaseIterable {
        case videoPictureInPicture
        case hideUpdateNotification
        case hideUpdateAvailableBanner
        case resetDDIStorage
        
        var section: Section {
            switch self {
            case .videoPictureInPicture, .hideUpdateNotification, .hideUpdateAvailableBanner:
                return .features
            case .resetDDIStorage:
                return .jitDiagnostics
            }
        }
    }
    
    private let videoPictureInPictureSwitch = UISwitch()
    private let hideUpdateNotificationSwitch = UISwitch()
    private let hideUpdateAvailableBannerSwitch = UISwitch()
    
    init() {
        super.init(style: .insetGrouped)
        title = "Experimental Features"
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
        return Section.allCases.count
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard Section.allCases.indices.contains(section) else {
            return 0
        }
        
        return rows(in: Section.allCases[section]).count
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
        
        let sectionRows = rows(in: Section.allCases[indexPath.section])
        guard sectionRows.indices.contains(indexPath.row) else {
            return UITableViewCell()
        }
        
        switch sectionRows[indexPath.row] {
        case .videoPictureInPicture:
            return switchCell(
                title: "Video Picture-in-Picture",
                accessoryView: videoPictureInPictureSwitch
            )
        case .hideUpdateNotification:
            // Same underlying preference as the "New updates" toggle
            // in Settings > General > Homepage
            // (Prefs.HomepageSettings.showsNewUpdates) — a second,
            // quicker entry point to it from this screen, inverted to
            // read as "hide" rather than "show".
            return switchCell(
                title: NSLocalizedString("Hide Reynard Update Notification", comment: ""),
                accessoryView: hideUpdateNotificationSwitch
            )
        case .hideUpdateAvailableBanner:
            // A completely separate mechanism from the row above -
            // this hides the "Update Available" section header,
            // release notes, and Update Now button shown at the top
            // of the main Settings screen itself
            // (SettingsViewController.Section.updates), not the
            // homepage card. Deliberately a separate toggle rather
            // than folded into the one above, since these two have
            // nothing to do with each other beyond both being update
            // notifications.
            return switchCell(
                title: NSLocalizedString("Hide Update Available Banner", comment: ""),
                accessoryView: hideUpdateAvailableBannerSwitch
            )
        case .resetDDIStorage:
            // Destructive-red — this deletes on-disk data, so it
            // should read as destructive like "Erase All Content"
            // style rows do elsewhere in Settings, not blend in with
            // the ordinary feature-toggle row above it.
            return SettingsViewUtils.actionCell(title: NSLocalizedString("Reset DDI Storage…", comment: ""), tintColor: .systemRed)
        }
    }
    
    // MARK: - Table Delegate
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard Section.allCases.indices.contains(indexPath.section) else {
            return
        }
        
        let sectionRows = rows(in: Section.allCases[indexPath.section])
        guard sectionRows.indices.contains(indexPath.row) else {
            return
        }
        
        switch sectionRows[indexPath.row] {
        case .videoPictureInPicture, .hideUpdateNotification, .hideUpdateAvailableBanner:
            break
        case .resetDDIStorage:
            confirmResetDDIStorage()
        }
    }
    
    private func rows(in section: Section) -> [Row] {
        Row.allCases.filter { $0.section == section }
    }
    
    private func configureSwitch() {
        videoPictureInPictureSwitch.addTarget(self, action: #selector(videoPictureInPictureSwitchDidChange(_:)), for: .valueChanged)
        hideUpdateNotificationSwitch.addTarget(self, action: #selector(hideUpdateNotificationSwitchDidChange(_:)), for: .valueChanged)
        hideUpdateAvailableBannerSwitch.addTarget(self, action: #selector(hideUpdateAvailableBannerSwitchDidChange(_:)), for: .valueChanged)
    }
    
    private func refreshDisplayedState() {
        videoPictureInPictureSwitch.isOn = Prefs.ExperimentalSettings.isVideoPictureInPictureEnabled
        hideUpdateNotificationSwitch.isOn = !Prefs.HomepageSettings.showsNewUpdates
        hideUpdateAvailableBannerSwitch.isOn = Prefs.ExperimentalSettings.hidesUpdateAvailableBanner
    }
    
    @objc private func videoPictureInPictureSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isVideoPictureInPictureEnabled = sender.isOn
        showRestartAlert()
    }
    
    // Inverted mirror of Settings > General > Homepage's own "New
    // updates" toggle — same preference, no restart needed since
    // UpdateAvailableViewController re-checks it live (via
    // .appUpdateAvailable / viewWillAppear) rather than caching a
    // value at launch.
    @objc private func hideUpdateNotificationSwitchDidChange(_ sender: UISwitch) {
        Prefs.HomepageSettings.showsNewUpdates = !sender.isOn
    }
    
    // No restart needed here either -
    // SettingsViewController.displayedSections is a plain computed
    // property with no caching, and that screen already calls
    // tableView.reloadData() in its own viewWillAppear, so navigating
    // back there from here picks up the new value naturally.
    @objc private func hideUpdateAvailableBannerSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.hidesUpdateAvailableBanner = sender.isOn
    }
    
    // MARK: - DDI Storage Reset
    
    // In-app alternative to deleting the DDI folders by hand via
    // Filza/SSH — clears both possible storage locations (the shared
    // App Group container and the private-container fallback) via
    // DDIManager.resetAllDDIStorage(), so a stale or mismatched
    // download (e.g. from before the group ID fix, or from a session
    // where the shared container silently fell back) can be fully
    // cleared without needing on-device file-manager access. Lives
    // here, behind the same 10-tap reveal as the rest of Experimental
    // Features, rather than on the main JIT settings screen — it's a
    // destructive, rarely-needed maintenance action, not a routine
    // setting someone should stumble into.
    private func confirmResetDDIStorage() {
        let alert = UIAlertController(
            title: NSLocalizedString("Reset DDI Storage?", comment: ""),
            message: NSLocalizedString("This deletes the downloaded Developer Disk Image from both the shared and private storage locations. JIT will be disabled until you download it again from the JIT settings screen.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Reset", comment: ""), style: .destructive) { [weak self] _ in
            self?.performResetDDIStorage()
        })
        present(alert, animated: true)
    }
    
    private func performResetDDIStorage() {
        // Cancel first — resetAllDDIStorage would otherwise be
        // deleting out from under an in-progress download's own
        // writes to the same directory.
        DDIManager.shared.cancelActiveDownload()
        
        DDIManager.shared.resetAllDDIStorage { [weak self] result in
            guard let self else {
                return
            }
            
            switch result {
            case .success:
                // The in-memory JITEnabler singleton (main app process)
                // may already have didEnsureDDIMounted latched true
                // from earlier this session — that flag isn't affected
                // by deleting files on disk, so without a restart nothing
                // downstream would actually notice the storage is now
                // empty, and this reset would silently accomplish
                // nothing until the app happens to relaunch on its own.
                Prefs.JITSettings.isJITEnabled = false
                self.showRestartAlert()
            case .failure(let error):
                let failureAlert = UIAlertController(
                    title: NSLocalizedString("Reset Failed", comment: ""),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                failureAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                self.present(failureAlert, animated: true)
            }
        }
    }
    
    private func showRestartAlert() {
        let alert = UIAlertController(
            title: "Restart Required",
            message: "The app will now close for the experimental setting to take effect.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .seconds(UX.restartDelay)
            ) {
                exit(EXIT_SUCCESS)
            }
        })
        present(alert, animated: true)
    }
    
    private func switchCell(title: String, accessoryView: UISwitch) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = title
        cell.accessoryView = accessoryView
        return cell
    }
}
