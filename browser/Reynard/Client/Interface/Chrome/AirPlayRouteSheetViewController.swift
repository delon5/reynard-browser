//
//  AirPlayRouteSheetViewController.swift
//  Reynard
//
//  The API-guaranteed way to the system route picker: a sheet holding a
//  real AVRoutePickerView. AirPlayController first sends a synthetic tap
//  to a hidden picker, which goes straight to the system sheet; this is
//  what it falls back to when that does not present within its deadline,
//  and what Prefs.AirPlaySettings.pickerAlwaysUsesSheet forces.
//

import AVKit
import UIKit

final class AirPlayRouteSheetViewController: UIViewController {
    private enum UX {
        static let pickerSize: CGFloat = 64
        static let spacing: CGFloat = 12
        static let margin: CGFloat = 24
    }
    
    /// Fired once, on the Cancel button or an interactive dismissal.
    /// Not fired when AirPlayController dismisses the sheet itself after
    /// the picker's routes went away.
    var onCancel: (() -> Void)?
    
    private let prioritizesVideo: Bool
    private weak var pickerDelegate: AVRoutePickerViewDelegate?
    private var didCancel = false
    
    init(prioritizesVideo: Bool, pickerDelegate: AVRoutePickerViewDelegate) {
        self.prioritizesVideo = prioritizesVideo
        self.pickerDelegate = pickerDelegate
        super.init(nibName: nil, bundle: nil)
        // Half a screen is plenty for one button; the medium detent
        // exists from iOS 15. Before that a form sheet is the closest
        // thing on iPad and a page sheet on iPhone.
        if #available(iOS 15.0, *) {
            modalPresentationStyle = .pageSheet
            sheetPresentationController?.detents = [.medium()]
            sheetPresentationController?.prefersGrabberVisible = true
        } else {
            modalPresentationStyle = .formSheet
        }
        presentationController?.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        
        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = NSLocalizedString("Choose an AirPlay Device", comment: "")
        
        let subtitleLabel = UILabel()
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = NSLocalizedString("Tap the AirPlay button to pick a device.", comment: "")
        
        // The same delegate as the hidden picker, so
        // routePickerViewWillBegin/DidEndPresentingRoutes report this
        // one's sheet through the same path.
        let picker = AVRoutePickerView()
        picker.delegate = pickerDelegate
        picker.prioritizesVideoDevices = prioritizesVideo
        picker.tintColor = .label
        picker.activeTintColor = .systemBlue
        
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, picker, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = UX.spacing
        stack.setCustomSpacing(UX.spacing * 2, after: subtitleLabel)
        stack.setCustomSpacing(UX.spacing * 2, after: picker)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            picker.widthAnchor.constraint(equalToConstant: UX.pickerSize),
            picker.heightAnchor.constraint(equalToConstant: UX.pickerSize),
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: UX.margin),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -UX.margin),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: UX.margin),
        ])
    }
    
    @objc private func cancelTapped() {
        cancel()
        dismiss(animated: true)
    }
    
    private func cancel() {
        guard !didCancel else {
            return
        }
        didCancel = true
        onCancel?()
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension AirPlayRouteSheetViewController: UIAdaptivePresentationControllerDelegate {
    /// A swipe down is a cancel too. Programmatic dismissal does not
    /// come through here, which is what keeps a pick from reading as one.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cancel()
    }
}
