import Foundation
import LumenFoundation

/// The state of an asynchronously loaded value. Views switch over it; a reload keeps showing the
/// previous value (`isRefreshing`) instead of flashing a spinner.
public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(ErrorPresentation)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var error: ErrorPresentation? {
        if case .failed(let error) = self { return error }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

extension LoadState: Equatable where Value: Equatable {}
