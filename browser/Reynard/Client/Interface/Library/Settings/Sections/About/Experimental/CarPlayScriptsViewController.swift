//
//  CarPlayScriptsViewController.swift
//  Reynard
//
//  Added by fix_carplay_scripts_ui.py.
//

import UIKit

/// Manages the scripts run against pages on the CarPlay display.
///
/// Mirrors PerSiteUserAgentOverridesViewController: a list with an add
/// row at the bottom and swipe to delete. The difference is that
/// editing pushes a screen rather than presenting an alert, because a
/// UIAlertController text field cannot hold multi-line JavaScript.
final class CarPlayScriptsViewController: SettingsTableViewController {
    private enum Section: CaseIterable {
        case scripts

        var text: SettingsSectionText {
            return SettingsSectionText(
                footerTitle: NSLocalizedString(
                    "Enabled scripts run on every page shown on the CarPlay display, once it has finished loading. They do not run in ordinary tabs.",
                    comment: ""
                )
            )
        }
    }

    private enum Row {
        case script(index: Int)
        case addScript
    }

    private var scripts: [CarPlayScript] = []

    private var displayedRows: [Row] {
        return scripts.indices.map { .script(index: $0) } + [.addScript]
    }

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("CarPlay Scripts", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scripts = Prefs.ExperimentalSettings.carPlayScripts
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // The editor writes straight to prefs, so re-read rather than
        // relying on a delegate callback.
        scripts = Prefs.ExperimentalSettings.carPlayScripts
        tableView.reloadData()
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
        case .script(let index):
            guard scripts.indices.contains(index) else {
                return cell
            }
            let script = scripts[index]
            cell.textLabel?.text = script.name
            cell.detailTextLabel?.text = script.isEnabled
                ? NSLocalizedString("On", comment: "")
                : NSLocalizedString("Off", comment: "")
            cell.detailTextLabel?.textColor = script.isEnabled ? .systemGreen : .secondaryLabel
            cell.accessoryType = .disclosureIndicator
        case .addScript:
            cell.textLabel?.text = NSLocalizedString("Add Script…", comment: "")
            cell.textLabel?.textColor = tableView.tintColor
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard displayedRows.indices.contains(indexPath.row) else {
            return false
        }
        if case .script = displayedRows[indexPath.row] {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete,
              displayedRows.indices.contains(indexPath.row),
              case .script(let index) = displayedRows[indexPath.row],
              scripts.indices.contains(index) else {
            return
        }
        scripts.remove(at: index)
        Prefs.ExperimentalSettings.carPlayScripts = scripts
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard displayedRows.indices.contains(indexPath.row) else {
            return
        }

        switch displayedRows[indexPath.row] {
        case .script(let index):
            guard scripts.indices.contains(index) else {
                return
            }
            let editor = CarPlayScriptEditorViewController(existingIndex: index)
            navigationController?.pushViewController(editor, animated: true)
        case .addScript:
            let editor = CarPlayScriptEditorViewController(existingIndex: nil)
            navigationController?.pushViewController(editor, animated: true)
        }
    }

    override func sectionText(for section: Int) -> SettingsSectionText {
        guard Section.allCases.indices.contains(section) else {
            return SettingsSectionText()
        }
        return Section.allCases[section].text
    }
}
