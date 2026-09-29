import SwiftUI
import AppKit

/// A zero-size `NSView` that fires `onVisible` every time its host window
/// transitions into a visible state.
///
/// Why: `MenuBarExtra(.window)`'s `onAppear` fires only on the first show on
/// some macOS point releases; the popover's view hierarchy stays alive
/// across hides, so subsequent opens never re-fire it. Observing the
/// containing `NSWindow` directly is the only reliable per-open signal
/// across macOS 14, 15, 26 and beyond.
///
/// The reliable signal is KVO on `NSWindow.isVisible` — a previous review
/// probe showed it toggling reliably on every open/close, whereas
/// `occlusionState` can stay `.visible` behind a locked screen. We also
/// subscribe to `didChangeOcclusionStateNotification` and
/// `didBecomeKeyNotification` as belt-and-braces, and invoke `onVisible`
/// once on install if the window is already visible. The store is
/// single-flight and calls to `refreshIfStale(olderThan: 60)` are guarded
/// by a staleness check, so duplicates from any of these paths are
/// harmless.
struct WindowVisibilityObserver: NSViewRepresentable {

    let onVisible: () -> Void

    func makeNSView(context: Context) -> NSView {
        WindowObservingView(onVisible: onVisible)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? WindowObservingView {
            view.onVisible = onVisible
        }
    }

    /// A thread-safe bag of `NotificationCenter` observer tokens.
    ///
    /// Used so the `WindowObservingView`'s deinit can drain the observers
    /// without touching main-actor state.
    private final class ObserverBag: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [NSObjectProtocol] = []

        func add(_ token: NSObjectProtocol) {
            lock.lock(); defer { lock.unlock() }
            tokens.append(token)
        }

        func drain() {
            let toRemove: [NSObjectProtocol] = {
                lock.lock(); defer { lock.unlock() }
                let copy = tokens
                tokens.removeAll()
                return copy
            }()
            for token in toRemove {
                NotificationCenter.default.removeObserver(token)
            }
        }

        deinit { drain() }
    }

    private final class WindowObservingView: NSView {

        var onVisible: () -> Void
        private let bag = ObserverBag()
        private var kvoToken: NSKeyValueObservation?
        private var wasVisible: Bool = false

        init(onVisible: @escaping () -> Void) {
            self.onVisible = onVisible
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not used — this view is only ever created programmatically")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bag.drain()
            kvoToken?.invalidate()
            kvoToken = nil
            wasVisible = false
            guard let window else { return }

            // Primary signal: KVO on `isVisible`. NSWindow flips this
            // reliably on every menu-bar-item open/close, including cases
            // where occlusionState stays `.visible` behind a locked
            // screen. Fires on false→true transitions only.
            kvoToken = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, change in
                guard let self else { return }
                let isVisible = change.newValue ?? false
                MainActor.assumeIsolated {
                    let wasVisible = self.wasVisible
                    self.wasVisible = isVisible
                    if isVisible && !wasVisible {
                        self.onVisible()
                    }
                }
            }

            // Belt-and-braces on macOS versions that quirk KVO for
            // menu-bar panels.
            let center = NotificationCenter.default
            bag.add(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fireIfVisible()
                }
            })
            bag.add(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fireIfVisible()
                }
            })
        }

        private func fireIfVisible() {
            guard let window else { return }
            if window.isVisible { onVisible() }
        }

        deinit {
            kvoToken?.invalidate()
        }
    }
}
