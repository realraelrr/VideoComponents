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
    return VideoPlayerLayout.adaptiveCardSize(
      forAvailableSize: CGSize(
        width: proposal.width ?? maximumSize.width,
        height: proposal.height ?? maximumSize.height
      ),
      contentAspectRatio: contentAspectRatio,
      maximumSize: maximumSize
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
