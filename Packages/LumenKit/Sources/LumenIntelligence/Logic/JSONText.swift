import Foundation
import LumenFoundation

extension JSONValue {
    /// Deterministic compact JSON text.
    ///
    /// Encoding only fails for non-finite numbers, which parsed JSON and tool schemas never
    /// contain; the `{}` fallback keeps the property total.
    var compactText: String {
        (try? compactString()) ?? "{}"
    }
}
