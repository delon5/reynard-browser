//
//  CarPlayScriptsViewController.swift
//  Reynard
//
//  Added by fix_carplay_scripts_ui.py.
//

import UIKit
import UniformTypeIdentifiers

/// Manages the scripts run against pages on the CarPlay display.
///
/// Mirrors PerSiteUserAgentOverridesViewController: a list with an add
/// row at the bottom and swipe to delete. The difference is that
/// editing pushes a screen rather than presenting an alert, because a
/// UIAlertController text field cannot hold multi-line JavaScript.
final class CarPlayScriptsViewController: SettingsTableViewController, UIDocumentPickerDelegate {
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
        case importScript
    }

    private var scripts: [CarPlayScript] = []

    private var displayedRows: [Row] {
        return scripts.indices.map { .script(index: $0) } + [.addScript, .importScript]
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
        case .importScript:
            cell.textLabel?.text = NSLocalizedString("Import from Files…", comment: "")
            cell.textLabel?.textColor = tableView.tintColor
            cell.detailTextLabel?.text = NSLocalizedString("Reynard's Documents folder appears in Files", comment: "")
            cell.detailTextLabel?.textColor = .secondaryLabel
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
        case .importScript:
            presentScriptImporter()
        }
    }

    override func sectionText(for section: Int) -> SettingsSectionText {
        guard Section.allCases.indices.contains(section) else {
            return SettingsSectionText()
        }
        return Section.allCases[section].text
    }

    // MARK: - Importing

    /// See fix_carplay_script_import.py. Mirrors how the pairing file
    /// is imported, so it behaves like the rest of the app.
    private func presentScriptImporter() {
        let picker: UIDocumentPickerViewController

        if #available(iOS 14.0, *) {
            // .plainText as well as .javaScript: a .js file written on a
            // desktop and synced through iCloud is often typed as plain
            // text, and would otherwise be unselectable.
            var types: [UTType] = [.plainText, .text]
            if let javaScript = UTType(filenameExtension: "js") {
                types.insert(javaScript, at: 0)
            }
            picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.text"], in: .import)
        }

        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var imported = 0

        for url in urls {
            // Needed for anything outside the sandbox - iCloud, another
            // app's folder. Harmless for files already in Reynard's own
            // Documents folder, so the same path handles both.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer {
                if needsScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let body = try? String(contentsOf: url, encoding: .utf8),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let name = url.deletingPathExtension().lastPathComponent

            // Matched on origin first, so re-importing an edited file
            // updates the right entry even if it has since been renamed.
            // See fix_carplay_script_origin.py.
            //
            // The name fallback catches entries created before origin
            // existed. Scripts written in the editor have no origin and
            // so are only ever matched by name - never silently replaced
            // by an unrelated import.
            let existing = scripts.firstIndex(where: { $0.origin == name })
                ?? scripts.firstIndex(where: { $0.origin == nil && $0.name == name })

            if let existing {
                // The displayed name is left alone - renaming an
                // imported script should survive re-importing it.
                scripts[existing].body = body
                scripts[existing].origin = name
            } else {
                scripts.append(CarPlayScript(name: name, body: body, isEnabled: true, origin: name))
            }
            imported += 1
        }

        guard imported > 0 else {
            presentImportFailure()
            return
        }

        Prefs.ExperimentalSettings.carPlayScripts = scripts
        tableView.reloadData()
    }

    private func presentImportFailure() {
        let alert = UIAlertController(
            title: NSLocalizedString("Nothing Imported", comment: ""),
            message: NSLocalizedString("The file could not be read, or was empty.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }
}
