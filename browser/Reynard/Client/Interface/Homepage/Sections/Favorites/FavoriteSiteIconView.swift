//
//  FavoriteSiteIconView.swift
//  Reynard
//
//  Created by Minh Ton on 22/6/26.
//

import UIKit

final class FavoriteSiteIconView: UIView {
    private enum UX {
        static let transparentIconInset: CGFloat = 6
    }
    
    private let imageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.tintColor = .secondaryLabel
        return view
    }()
    
    private var representedBookmarkGUID: String?
    private var iconTask: Task<Void, Never>?
    private var imageConstraints: [NSLayoutConstraint] = []
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(bookmark: BookmarkSnapshot) {
        representedBookmarkGUID = bookmark.guid
        iconTask?.cancel()
        let cachedIcon = BookmarkIconProvider.shared.cachedIcon(for: bookmark)
        applyIcon(cachedIcon.image, tintColor: cachedIcon.tintColor, shouldInset: cachedIcon.tintColor != nil)
        iconTask = Task { [weak self] in
            let icon = await BookmarkIconProvider.shared.icon(for: bookmark)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard self?.representedBookmarkGUID == bookmark.guid else {
                    return
                }
                self?.applyIcon(icon.image, tintColor: icon.tintColor, shouldInset: icon.tintColor != nil)
            }
        }
    }
    
    func reset() {
        representedBookmarkGUID = nil
        iconTask?.cancel()
        iconTask = nil
        applyIcon(UIImage(named: "reynard.globe"), tintColor: .secondaryLabel, shouldInset: true)
    }
    
    private func configureView() {
        backgroundColor = .clear
        addSubview(imageView)
        
        imageConstraints = [
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(imageConstraints)
        
        reset()
    }
    
    private func applyIcon(_ image: UIImage?, tintColor: UIColor?, shouldInset: Bool) {
        imageView.image = image
        imageView.tintColor = tintColor
        let inset = shouldInset ? UX.transparentIconInset : 0
        imageConstraints[0].constant = inset
        imageConstraints[1].constant = -inset
        imageConstraints[2].constant = inset
        imageConstraints[3].constant = -inset
    }
}
