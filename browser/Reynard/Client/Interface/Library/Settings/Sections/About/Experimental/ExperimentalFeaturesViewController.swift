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
        case carPlayScripts
        case backgroundKeepAlive
        case diagnosticLogs
        case jitDiagnostics
        
        var text: SettingsSectionText {
            switch self {
            case .features:
                return SettingsSectionText()
            case .carPlayScripts:
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("CarPlay", comment: ""),
                    footerTitle: NSLocalizedString("Runs scripts on pages shown on the CarPlay display, once each page has loaded. The display cannot be touched, so scripts are the only way to change what happens there - hiding page chrome so video fills the screen, for instance. Ordinary tabs are unaffected.", comment: "")
                )
            case .backgroundKeepAlive:
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("Background", comment: ""),
                    footerTitle: NSLocalizedString("Plays inaudible audio so iOS keeps Reynard running in the background, which keeps JIT active for open tabs instead of losing it on every suspension. Uses noticeably more battery, and mixes with other audio rather than interrupting it.", comment: "")
                )
            case .diagnosticLogs:
                // Its own section rather than folded into
                // jitDiagnostics, whose footer describes DDI deletion
                // specifically and would read as applying to these
                // toggles too. Placed before it so the destructive
                // "Reset DDI Storage" action stays last.
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("Diagnostic Logs", comment: ""),
                    footerTitle: NSLocalizedString("Written to the app's Documents folder and retrievable over USB in Finder. Leave these enabled unless you need the disk space or want to reduce logging overhead.", comment: "")
                )
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
        case avPlayerHLS
        case hideUpdateNotification
        case hideUpdateAvailableBanner
        case carPlayScriptsEnabled
        case manageCarPlayScripts
        case backgroundAudioKeepAlive
        case debugLogFile
        case ideviceNativeLog
        case jitHangBacktrace
        case stdoutLog
        case resetDDIStorage
        
        var section: Section {
            switch self {
            case .videoPictureInPicture, .avPlayerHLS, .hideUpdateNotification, .hideUpdateAvailableBanner:
                return .features
            case .carPlayScriptsEnabled, .manageCarPlayScripts:
                return .carPlayScripts
            case .backgroundAudioKeepAlive:
                return .backgroundKeepAlive
            case .debugLogFile, .ideviceNativeLog, .jitHangBacktrace, .stdoutLog:
                return .diagnosticLogs
            case .resetDDIStorage:
                return .jitDiagnostics
            }
        }
    }
    
    private let videoPictureInPictureSwitch = UISwitch()
    private let avPlayerHLSSwitch = UISwitch()
    private let hideUpdateNotificationSwitch = UISwitch()
    private let hideUpdateAvailableBannerSwitch = UISwitch()
    private let carPlayScriptsSwitch = UISwitch()
    private let backgroundAudioKeepAliveSwitch = UISwitch()
    private let debugLogFileSwitch = UISwitch()
    private let ideviceNativeLogSwitch = UISwitch()
    private let jitHangBacktraceSwitch = UISwitch()
    private let stdoutLogSwitch = UISwitch()
    
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
        case .avPlayerHLS:
            return switchCell(
                title: NSLocalizedString("HLS Playback (AVPlayer)", comment: ""),
                subtitle: NSLocalizedString("Plays HLS streams, including FairPlay, through AVFoundation", comment: ""),
                accessoryView: avPlayerHLSSwitch
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
        case .carPlayScriptsEnabled:
            return switchCell(
                title: NSLocalizedString("Run Scripts on CarPlay", comment: ""),
                accessoryView: carPlayScriptsSwitch
            )
        case .manageCarPlayScripts:
            return SettingsViewUtils.disclosureCell(title: NSLocalizedString("Manage Scripts…", comment: ""))
        case .backgroundAudioKeepAlive:
            return switchCell(
                title: NSLocalizedString("Keep Running in Background", comment: ""),
                accessoryView: backgroundAudioKeepAliveSwitch
            )
        case .debugLogFile:
            // Gates everything written to
            // Documents/reynard_jit_log.txt - the JIT pipeline and the
            // tab lifecycle counts alike - hence the generic name.
            return switchCell(
                title: NSLocalizedString("Debug Log File", comment: ""),
                accessoryView: debugLogFileSwitch
            )
        case .ideviceNativeLog:
            return switchCell(
                title: NSLocalizedString("idevice Native Log", comment: ""),
                accessoryView: ideviceNativeLogSwitch
            )
        case .jitHangBacktrace:
            return switchCell(
                title: NSLocalizedString("JIT Hang Backtrace", comment: ""),
                accessoryView: jitHangBacktraceSwitch
            )
        case .stdoutLog:
            // Documents/reynard_stdout.txt - Gecko's stdout and stderr,
            // so JS dump(), printf_stderr and NSLog. Turning it off
            // sends them to /dev/null rather than leaving the streams
            // alone: the redirect itself is what stops a full, undrained
            // stdout pipe blocking the main thread into a watchdog kill.
            return switchCell(
                title: NSLocalizedString("Standard Output Log", comment: ""),
                accessoryView: stdoutLogSwitch
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
        case .videoPictureInPicture, .hideUpdateNotification, .hideUpdateAvailableBanner,
             .carPlayScriptsEnabled,
             .backgroundAudioKeepAlive,
             .debugLogFile, .ideviceNativeLog, .jitHangBacktrace, .stdoutLog:
            break
        case .manageCarPlayScripts:
            navigationController?.pushViewController(CarPlayScriptsViewController(), animated: true)
        case .resetDDIStorage:
            confirmResetDDIStorage()
        }
    }
    
    private func rows(in section: Section) -> [Row] {
        Row.allCases.filter { $0.section == section }
    }
    
    private func configureSwitch() {
        videoPictureInPictureSwitch.addTarget(self, action: #selector(videoPictureInPictureSwitchDidChange(_:)), for: .valueChanged)
        avPlayerHLSSwitch.addTarget(self, action: #selector(avPlayerHLSSwitchDidChange(_:)), for: .valueChanged)
        hideUpdateNotificationSwitch.addTarget(self, action: #selector(hideUpdateNotificationSwitchDidChange(_:)), for: .valueChanged)
        hideUpdateAvailableBannerSwitch.addTarget(self, action: #selector(hideUpdateAvailableBannerSwitchDidChange(_:)), for: .valueChanged)
        carPlayScriptsSwitch.addTarget(self, action: #selector(carPlayScriptsSwitchDidChange(_:)), for: .valueChanged)
        backgroundAudioKeepAliveSwitch.addTarget(self, action: #selector(backgroundAudioKeepAliveSwitchDidChange(_:)), for: .valueChanged)
        debugLogFileSwitch.addTarget(self, action: #selector(debugLogFileSwitchDidChange(_:)), for: .valueChanged)
        ideviceNativeLogSwitch.addTarget(self, action: #selector(ideviceNativeLogSwitchDidChange(_:)), for: .valueChanged)
        jitHangBacktraceSwitch.addTarget(self, action: #selector(jitHangBacktraceSwitchDidChange(_:)), for: .valueChanged)
        stdoutLogSwitch.addTarget(self, action: #selector(stdoutLogSwitchDidChange(_:)), for: .valueChanged)
    }
    
    private func refreshDisplayedState() {
        videoPictureInPictureSwitch.isOn = Prefs.ExperimentalSettings.isVideoPictureInPictureEnabled
        avPlayerHLSSwitch.isOn = Prefs.ExperimentalSettings.isAVPlayerHLSEnabled
        hideUpdateNotificationSwitch.isOn = !Prefs.HomepageSettings.showsNewUpdates
        hideUpdateAvailableBannerSwitch.isOn = Prefs.ExperimentalSettings.hidesUpdateAvailableBanner
        carPlayScriptsSwitch.isOn = Prefs.ExperimentalSettings.isCarPlayScriptsEnabled
        backgroundAudioKeepAliveSwitch.isOn = Prefs.ExperimentalSettings.isBackgroundAudioKeepAliveEnabled
        debugLogFileSwitch.isOn = Prefs.ExperimentalSettings.isJITDebugLogEnabled
        ideviceNativeLogSwitch.isOn = Prefs.ExperimentalSettings.isIdeviceNativeLogEnabled
        jitHangBacktraceSwitch.isOn = Prefs.ExperimentalSettings.isJITHangBacktraceEnabled
        stdoutLogSwitch.isOn = Prefs.ExperimentalSettings.isStdoutLogEnabled
    }
    
    // All three prompt for a restart, like the Picture-in-Picture
    // toggle above. The values are read once at startup and pushed
    // down into the Objective-C layer, and idevice_init_logger in
    // particular is initialised under dispatch_once, so none of them
    // can genuinely take effect mid-process.
    // No restart needed, unlike the logging toggles - the audio engine
    // starts and stops live.
    @objc private func carPlayScriptsSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isCarPlayScriptsEnabled = sender.isOn
    }
    
    @objc private func backgroundAudioKeepAliveSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isBackgroundAudioKeepAliveEnabled = sender.isOn
        BackgroundAudioKeepAlive.shared.applyPreference()
    }
    
    @objc private func debugLogFileSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isJITDebugLogEnabled = sender.isOn
        showRestartAlert()
    }
    
    @objc private func ideviceNativeLogSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isIdeviceNativeLogEnabled = sender.isOn
        showRestartAlert()
    }
    
    /// Takes effect on the next launch: the redirect it controls runs in
    /// main.swift before UIApplicationMain, so the streams for THIS
    /// process are already pointed wherever they were going. Same as the
    /// other logging toggles.
    @objc private func stdoutLogSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isStdoutLogEnabled = sender.isOn
    }

    @objc private func jitHangBacktraceSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isJITHangBacktraceEnabled = sender.isOn
        showRestartAlert()
    }
    
    @objc private func videoPictureInPictureSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isVideoPictureInPictureEnabled = sender.isOn
        showRestartAlert()
    }
    
    // Pushed to the engine immediately as well as at startup, so a
    // restart is only needed for pages already loaded under the old
    // setting - DecoderTraits asks IsSupportedType per media element.
    @objc private func avPlayerHLSSwitchDidChange(_ sender: UISwitch) {
        Prefs.ExperimentalSettings.isAVPlayerHLSEnabled = sender.isOn
        AVPlayerPolicyController.applyAVPlayerHLS()
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
    
    private func switchCell(
        title: String,
        subtitle: String? = nil,
        accessoryView: UISwitch
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: subtitle == nil ? .default : .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = title
        if let subtitle {
            cell.detailTextLabel?.text = subtitle
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.numberOfLines = 0
        }
        cell.accessoryView = accessoryView
        return cell
    }
}
