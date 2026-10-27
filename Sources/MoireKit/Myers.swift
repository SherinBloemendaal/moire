/// One step of an edit script that turns sequence `a` into sequence `b`.
public enum EditOperation: Sendable, Hashable {
    case equal
    case delete
    case insert
}

/// Myers' O(ND) difference algorithm in its linear-space form: the middle snake splits the
/// problem in two, so memory stays proportional to the input even when the inputs differ a lot.
///
/// The result walks `a` and `b` together: `.equal` consumes one element of each, `.delete` one
/// of `a`, `.insert` one of `b`. Deletions come before insertions inside every changed run.
public enum Myers {
    public static func diff<Element: Hashable>(_ a: [Element], _ b: [Element]) -> [EditOperation] {
        // An element that the other side does not have at all can never be part of a match, so
        // it is a plain delete or insert. Leaving those out first keeps two files that share
        // little (a rewrite, the wrong file) fast, and the result is still minimal.
        let inB = Set(b)
        let inA = Set(a)
        let aKept = a.indices.filter { inB.contains(a[$0]) }
        let bKept = b.indices.filter { inA.contains(b[$0]) }
        let reducedA = aKept.map { a[$0] }
        let reducedB = bKept.map { b[$0] }

        var reduced: [EditOperation] = []
        reduced.reserveCapacity(max(reducedA.count, reducedB.count))
        var solver = Solver(a: reducedA, b: reducedB)
        solver.solve(aLow: 0, aHigh: reducedA.count, bLow: 0, bHigh: reducedB.count, into: &reduced)

        var operations: [EditOperation] = []
        operations.reserveCapacity(a.count + b.count)
        var i = 0, j = 0, ai = 0, bi = 0
        func skipA(to end: Int) {
            operations.append(contentsOf: repeatElement(.delete, count: end - i))
            i = end
        }
        func skipB(to end: Int) {
            operations.append(contentsOf: repeatElement(.insert, count: end - j))
            j = end
        }
        for operation in reduced {
            switch operation {
            case .equal:
                skipA(to: aKept[ai])
                skipB(to: bKept[bi])
                operations.append(.equal)
                i += 1; j += 1; ai += 1; bi += 1
            case .delete:
                skipA(to: aKept[ai])
                operations.append(.delete)
                i += 1; ai += 1
            case .insert:
                skipB(to: bKept[bi])
                operations.append(.insert)
                j += 1; bi += 1
            }
        }
        skipA(to: a.count)
        skipB(to: b.count)
        return normalized(operations)
    }

    /// Bisection can emit a changed run as insert, delete, insert. Reorder every run so its
    /// deletions come first; the run still consumes the same elements of `a` and `b`.
    private static func normalized(_ operations: [EditOperation]) -> [EditOperation] {
        var result: [EditOperation] = []
        result.reserveCapacity(operations.count)
        var deletes = 0
        var inserts = 0
        func flush() {
            result.append(contentsOf: repeatElement(.delete, count: deletes))
            result.append(contentsOf: repeatElement(.insert, count: inserts))
            deletes = 0
            inserts = 0
        }
        for operation in operations {
            switch operation {
            case .equal:
                flush()
                result.append(.equal)
            case .delete: deletes += 1
            case .insert: inserts += 1
            }
        }
        flush()
        return result
    }

    private struct Solver<Element: Equatable> {
        let a: [Element]
        let b: [Element]

        mutating func solve(aLow: Int, aHigh: Int, bLow: Int, bHigh: Int, into operations: inout [EditOperation]) {
            var aLow = aLow, aHigh = aHigh, bLow = bLow, bHigh = bHigh

            while aLow < aHigh, bLow < bHigh, a[aLow] == b[bLow] {
                operations.append(.equal)
                aLow += 1
                bLow += 1
            }
            var commonSuffix = 0
            while aLow < aHigh, bLow < bHigh, a[aHigh - 1] == b[bHigh - 1] {
                aHigh -= 1
                bHigh -= 1
                commonSuffix += 1
            }

            if aLow == aHigh {
                operations.append(contentsOf: repeatElement(.insert, count: bHigh - bLow))
            } else if bLow == bHigh {
                operations.append(contentsOf: repeatElement(.delete, count: aHigh - aLow))
            } else if let (x, y) = middleSnake(aLow: aLow, aHigh: aHigh, bLow: bLow, bHigh: bHigh) {
                solve(aLow: aLow, aHigh: x, bLow: bLow, bHigh: y, into: &operations)
                solve(aLow: x, aHigh: aHigh, bLow: y, bHigh: bHigh, into: &operations)
            } else {
                // Nothing in common at all.
                operations.append(contentsOf: repeatElement(.delete, count: aHigh - aLow))
                operations.append(contentsOf: repeatElement(.insert, count: bHigh - bLow))
            }

            operations.append(contentsOf: repeatElement(.equal, count: commonSuffix))
        }

        /// Runs the forward and the reverse search at the same time until they overlap, and
        /// returns the absolute point where they meet. `nil` means the ranges share nothing.
        private func middleSnake(aLow: Int, aHigh: Int, bLow: Int, bHigh: Int) -> (Int, Int)? {
            let n = aHigh - aLow
            let m = bHigh - bLow
            let maxD = (n + m + 1) / 2
            let offset = maxD
            let length = 2 * maxD + 2
            var forward = [Int](repeating: -1, count: length)
            var reverse = [Int](repeating: -1, count: length)
            forward[offset + 1] = 0
            reverse[offset + 1] = 0
            let delta = n - m
            // With an odd delta the paths overlap during a forward step, with an even one during a reverse step.
            let checkOnForward = delta % 2 != 0
            var k1Start = 0, k1End = 0, k2Start = 0, k2End = 0

            for d in 0..<maxD {
                var k1 = -d + k1Start
                while k1 <= d - k1End {
                    let index = offset + k1
                    var x1 = (k1 == -d || (k1 != d && forward[index - 1] < forward[index + 1]))
                        ? forward[index + 1]
                        : forward[index - 1] + 1
                    var y1 = x1 - k1
                    while x1 < n, y1 < m, a[aLow + x1] == b[bLow + y1] {
                        x1 += 1
                        y1 += 1
                    }
                    forward[index] = x1
                    if x1 > n {
                        k1End += 2
                    } else if y1 > m {
                        k1Start += 2
                    } else if checkOnForward {
                        let reverseIndex = offset + delta - k1
                        if reverseIndex >= 0, reverseIndex < length, reverse[reverseIndex] != -1, x1 >= n - reverse[reverseIndex] {
                            return (aLow + x1, bLow + y1)
                        }
                    }
                    k1 += 2
                }

                var k2 = -d + k2Start
                while k2 <= d - k2End {
                    let index = offset + k2
                    var x2 = (k2 == -d || (k2 != d && reverse[index - 1] < reverse[index + 1]))
                        ? reverse[index + 1]
                        : reverse[index - 1] + 1
                    var y2 = x2 - k2
                    while x2 < n, y2 < m, a[aLow + n - x2 - 1] == b[bLow + m - y2 - 1] {
                        x2 += 1
                        y2 += 1
                    }
                    reverse[index] = x2
                    if x2 > n {
                        k2End += 2
                    } else if y2 > m {
                        k2Start += 2
                    } else if !checkOnForward {
                        let forwardIndex = offset + delta - k2
                        if forwardIndex >= 0, forwardIndex < length, forward[forwardIndex] != -1 {
                            let x1 = forward[forwardIndex]
                            let y1 = offset + x1 - forwardIndex
                            if x1 >= n - x2 {
                                return (aLow + x1, bLow + y1)
                            }
                        }
                    }
                    k2 += 2
                }
            }
            return nil
        }
    }
}
