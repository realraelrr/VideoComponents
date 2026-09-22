import SwiftUI

public struct AdaptiveVideoCardLayout: Layout {
  var contentAspectRatio: CGFloat?
  var maximumSize = VideoPlayerLayout.defaultMaximumSize

  public init(contentAspectRatio: CGFloat?, maximumSize: CGSize = CGSize(width: 320, height: 450)) {
    self.contentAspectRatio = contentAspectRatio
    self.maximumSize = maximumSize
  }

  public func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let resolvedMaximumSize = if let contentAspectRatio,
                                 contentAspectRatio.isFinite,
                                 contentAspectRatio > 0 {
      maximumSize
    } else {
      VideoPlayerLayout.defaultMaximumSize
    }
    return VideoPlayerLayout.adaptiveCardSize(
      forAvailableSize: CGSize(
        width: proposal.width ?? resolvedMaximumSize.width,
        height: proposal.height ?? resolvedMaximumSize.height
      ),
      contentAspectRatio: contentAspectRatio,
      maximumSize: resolvedMaximumSize
    )
  }

  public func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let subview = subviews.first else { return }
    subview.place(
      at: bounds.origin,
      anchor: .topLeading,
      proposal: ProposedViewSize(bounds.size)
    )
  }
}
