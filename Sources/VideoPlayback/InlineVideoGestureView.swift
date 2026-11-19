import UIKit

final class InlineVideoGestureView: UIView {
  private lazy var boundary = TouchBoundary(surface: self)

  var touchStartedOutside: Bool { boundary.startedOutside }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    detachFromScrollView()
    guard window != nil else { return }
    var ancestor = superview
    while let view = ancestor {
      if let scroll = view as? UIScrollView {
        scroll.addGestureRecognizer(boundary)
        return
      }
      ancestor = view.superview
    }
  }

  func detachFromScrollView() {
    boundary.view?.removeGestureRecognizer(boundary)
  }

  // Observe at the common ancestor so a later finger cannot start a second
  // interaction on the opposite side of the video boundary.
  private final class TouchBoundary: UIGestureRecognizer {
    weak var surface: UIView?
    private(set) var startedOutside = false
    private var contacts: Set<UITouch> = []

    init(surface: UIView) {
      self.surface = surface
      super.init(target: nil, action: nil)
      cancelsTouchesInView = false
      delaysTouchesBegan = false
      delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      if contacts.isEmpty, let firstTime = touches.map(\.timestamp).min(), let surface {
        // Simultaneous first contacts straddling the edge belong to the page.
        startedOutside = touches.contains {
          $0.timestamp == firstTime && !surface.bounds.contains($0.location(in: surface))
        }
        if !startedOutside { state = .began }
      }
      contacts.formUnion(touches)
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool {
      !startedOutside && other === (view as? UIScrollView)?.panGestureRecognizer
    }

    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      finish(touches, with: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      finish(touches, with: .cancelled)
    }

    private func finish(_ touches: Set<UITouch>, with terminalState: State) {
      contacts.subtract(touches)
      if contacts.isEmpty { state = startedOutside ? .failed : terminalState }
    }

    override func reset() {
      super.reset()
      contacts.removeAll()
      startedOutside = false
    }
  }
}
