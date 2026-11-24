import Foundation

/// Myers' O(ND) difference algorithm in linear space (middle-snake bisection), over sequences of
/// integer symbols. Produces a minimal edit script.
struct MyersDiff {
    enum Operation: Equatable {
        case equal
        case delete
        case insert
    }

    private let old: [Int]
    private let new: [Int]
    private var operations: [Operation] = []

    /// Edit operations turning `old` into `new`, in order: each `.equal` consumes one symbol of
    /// both, `.delete` one of `old`, `.insert` one of `new`.
    static func operations(old: [Int], new: [Int]) -> [Operation] {
        var diff = MyersDiff(old: old, new: new)
        diff.operations.reserveCapacity(max(old.count, new.count))
        diff.diff(oldRange: 0..<old.count, newRange: 0..<new.count)
        return diff.operations
    }

    private init(old: [Int], new: [Int]) {
        self.old = old
        self.new = new
    }

    private mutating func diff(oldRange: Range<Int>, newRange: Range<Int>) {
        var oldLower = oldRange.lowerBound, oldUpper = oldRange.upperBound
        var newLower = newRange.lowerBound, newUpper = newRange.upperBound

        var prefix = 0
        while oldLower < oldUpper, newLower < newUpper, old[oldLower] == new[newLower] {
            oldLower += 1
            newLower += 1
            prefix += 1
        }
        var suffix = 0
        while oldLower < oldUpper, newLower < newUpper, old[oldUpper - 1] == new[newUpper - 1] {
            oldUpper -= 1
            newUpper -= 1
            suffix += 1
        }

        append(.equal, count: prefix)
        let oldCount = oldUpper - oldLower
        let newCount = newUpper - newLower
        if oldCount == 0 {
            append(.insert, count: newCount)
        } else if newCount == 0 {
            append(.delete, count: oldCount)
        } else if oldCount == 1 || newCount == 1 {
            singleElement(oldRange: oldLower..<oldUpper, newRange: newLower..<newUpper)
        } else {
            bisect(oldRange: oldLower..<oldUpper, newRange: newLower..<newUpper)
        }
        append(.equal, count: suffix)
    }

    /// One side has a single symbol (and the ranges share no prefix or suffix): it is either found
    /// once in the other side or replaced.
    private mutating func singleElement(oldRange: Range<Int>, newRange: Range<Int>) {
        if oldRange.count == 1 {
            let symbol = old[oldRange.lowerBound]
            if let match = newRange.first(where: { new[$0] == symbol }) {
                append(.insert, count: match - newRange.lowerBound)
                append(.equal, count: 1)
                append(.insert, count: newRange.upperBound - match - 1)
            } else {
                append(.delete, count: 1)
                append(.insert, count: newRange.count)
            }
        } else {
            let symbol = new[newRange.lowerBound]
            if let match = oldRange.first(where: { old[$0] == symbol }) {
                append(.delete, count: match - oldRange.lowerBound)
                append(.equal, count: 1)
                append(.delete, count: oldRange.upperBound - match - 1)
            } else {
                append(.delete, count: oldRange.count)
                append(.insert, count: 1)
            }
        }
    }

    /// Finds the middle snake of the shortest edit path and recurses on both halves.
    private mutating func bisect(oldRange: Range<Int>, newRange: Range<Int>) {
        let oldBase = oldRange.lowerBound, newBase = newRange.lowerBound
        let n = oldRange.count, m = newRange.count
        let maxD = (n + m + 1) / 2
        let offset = maxD
        let length = 2 * maxD + 2
        var forward = [Int](repeating: -1, count: length)
        var backward = [Int](repeating: -1, count: length)
        forward[offset + 1] = 0
        backward[offset + 1] = 0
        let delta = n - m
        // With an odd delta the paths meet while extending forward, otherwise backward.
        let checkWhileForward = delta % 2 != 0
        var forwardStart = 0, forwardEnd = 0, backwardStart = 0, backwardEnd = 0

        for d in 0..<maxD {
            var k = -d + forwardStart
            while k <= d - forwardEnd {
                let index = offset + k
                var x: Int
                if k == -d || (k != d && forward[index - 1] < forward[index + 1]) {
                    x = forward[index + 1]
                } else {
                    x = forward[index - 1] + 1
                }
                var y = x - k
                while x < n, y < m, old[oldBase + x] == new[newBase + y] {
                    x += 1
                    y += 1
                }
                forward[index] = x
                if x > n {
                    forwardEnd += 2
                } else if y > m {
                    forwardStart += 2
                } else if checkWhileForward {
                    let mirror = offset + delta - k
                    if mirror >= 0, mirror < length, backward[mirror] != -1, x >= n - backward[mirror] {
                        split(oldRange: oldRange, newRange: newRange, x: x, y: y)
                        return
                    }
                }
                k += 2
            }

            k = -d + backwardStart
            while k <= d - backwardEnd {
                let index = offset + k
                var x: Int
                if k == -d || (k != d && backward[index - 1] < backward[index + 1]) {
                    x = backward[index + 1]
                } else {
                    x = backward[index - 1] + 1
                }
                var y = x - k
                while x < n, y < m, old[oldBase + n - x - 1] == new[newBase + m - y - 1] {
                    x += 1
                    y += 1
                }
                backward[index] = x
                if x > n {
                    backwardEnd += 2
                } else if y > m {
                    backwardStart += 2
                } else if !checkWhileForward {
                    let mirror = offset + delta - k
                    if mirror >= 0, mirror < length, forward[mirror] != -1 {
                        let forwardX = forward[mirror]
                        let forwardY = offset + forwardX - mirror
                        if forwardX >= n - x {
                            split(oldRange: oldRange, newRange: newRange, x: forwardX, y: forwardY)
                            return
                        }
                    }
                }
                k += 2
            }
        }
        // Unreachable for non-empty inputs (the paths always meet); kept as a correct fallback.
        append(.delete, count: n)
        append(.insert, count: m)
    }

    private mutating func split(oldRange: Range<Int>, newRange: Range<Int>, x: Int, y: Int) {
        let oldMiddle = oldRange.lowerBound + x
        let newMiddle = newRange.lowerBound + y
        diff(oldRange: oldRange.lowerBound..<oldMiddle, newRange: newRange.lowerBound..<newMiddle)
        diff(oldRange: oldMiddle..<oldRange.upperBound, newRange: newMiddle..<newRange.upperBound)
    }

    private mutating func append(_ operation: Operation, count: Int) {
        guard count > 0 else { return }
        operations.append(contentsOf: repeatElement(operation, count: count))
    }
}
