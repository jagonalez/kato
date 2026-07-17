import Foundation

/// Seam for all event sources. See docs/ARCHITECTURE.md §"Module map".
public protocol Monitor: Sendable {
    func start(onEvent: @escaping @Sendable (KatoEvent) -> Void)
    func stop()
}
