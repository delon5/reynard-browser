//
//  HomepageThumbnailRenderer.swift
//  Reynard
//
//  Created by Minh Ton on 21/6/26.
//

import UIKit

final class HomepageThumbnailRenderer {
    private weak var homepageViewController: HomepageViewController?
    
    init(homepageViewController: HomepageViewController) {
        self.homepageViewController = homepageViewController
    }
    
    func prepareForCapture(contentMode: HomepageContentMode, isPrivateBrowsing: Bool) {
        guard let homepageViewController else {
            return
        }
        
        homepageViewController.loadViewIfNeeded()
        homepageViewController.setPrivateBrowsing(isPrivateBrowsing)
        homepageViewController.setContentMode(contentMode)
        homepageViewController.setShowsBackground(true)
        homepageViewController.view.setNeedsLayout()
        homepageViewController.view.layoutIfNeeded()
    }
    
    func capture(
        size: CGSize,
        visibleRect: CGRect,
        contentMode: HomepageContentMode,
        isPrivateBrowsing: Bool,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard size.width > 1,
              size.height > 1,
              visibleRect.width > 1,
              visibleRect.height > 1 else {
            completion(nil)
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            completion(self?.snapshot(
                size: size,
                visibleRect: visibleRect,
                contentMode: contentMode,
                isPrivateBrowsing: isPrivateBrowsing
            ))
        }
    }
    
    func snapshot(
        size: CGSize,
        visibleRect: CGRect,
        contentMode: HomepageContentMode,
        isPrivateBrowsing: Bool
    ) -> UIImage? {
        guard size.width > 1,
              size.height > 1,
              visibleRect.width > 1,
              visibleRect.height > 1,
              let homepageViewController else {
            return nil
        }
        
        homepageViewController.loadViewIfNeeded()
        homepageViewController.setPrivateBrowsing(isPrivateBrowsing)
        homepageViewController.setContentMode(contentMode)
        homepageViewController.setShowsBackground(true)
        
        let view = homepageViewController.view!
        let originalFrame = view.frame
        let originalBounds = view.bounds
        let temporarilyAttachedView = view.superview == nil
        var captureContainer: UIView?
        if temporarilyAttachedView {
            captureContainer = UIView(frame: CGRect(origin: .zero, size: size))
            captureContainer?.addSubview(view)
            view.frame = visibleRect
        }
        
        captureContainer?.layoutIfNeeded()
        view.layoutIfNeeded()
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: visibleRect.minX, y: visibleRect.minY)
            guard view.bounds.width > 1, view.bounds.height > 1 else {
                context.cgContext.restoreGState()
                return
            }
            context.cgContext.scaleBy(
                x: visibleRect.width / view.bounds.width,
                y: visibleRect.height / view.bounds.height
            )
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
            context.cgContext.restoreGState()
        }
        
        if temporarilyAttachedView {
            view.removeFromSuperview()
        }
        view.frame = originalFrame
        view.bounds = originalBounds
        return image
    }
}
