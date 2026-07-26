//
//  ReynardDirectoriesBridge.swift
//  Reynard
//

import Foundation

@objc(ReynardDirectoriesBridge)
final class ReynardDirectoriesBridge: NSObject {
    @objc static var ddiPath: String {
        ReynardDirectories.shared.ddi.path
    }

    @objc static var pairingFilePath: String {
        ReynardDirectories.shared.pairingFile.path
    }

    @objc static var jitTemporaryPath: String {
        ReynardDirectories.shared.jitTemporary.path
    }
    
    // New — nil-coalesced to empty string rather than making these
    // optional, matching this bridge's own existing pattern above
    // (pairingFilePath already does the same for a different reason).
    // Callers already need to handle "file not found" regardless, so a
    // missing shared container surfaces the same way rather than
    // needing a second, separate failure mode.
    @objc static var sharedPairingFilePath: String {
        ReynardDirectories.shared.sharedPairingFile?.path ?? ""
    }
    
    @objc static var sharedDDIPath: String {
        ReynardDirectories.shared.sharedDDI?.path ?? ""
    }
}
