/// Stack with most recently element on top
final class MruStack<T: Equatable>: Sequence {
    typealias Element = T

    private var mruNode: Node<T>? = nil

    func makeIterator() -> MruStackIterator<T> {
        MruStackIterator(mruNode)
    }

    var mostRecent: T? { mruNode?.value }

    /// Returns the current ordering as an array (most recent first)
    func snapshot() -> [T] {
        Array(self)
    }

    /// Restores the MRU ordering from a snapshot (most recent first).
    /// Elements in the snapshot that are not currently in the stack are skipped.
    /// Elements currently in the stack but not in the snapshot retain their relative order at the bottom.
    func restoreOrder(from snapshot: [T]) {
        // Replay in reverse so the most-recent element ends up on top
        for value in snapshot.reversed() {
            // Only raise if still present
            if contains(where: { $0 == value }) {
                pushOrRaise(value)
            }
        }
    }

    func pushOrRaise(_ value: T) {
        remove(value)
        mruNode = Node(value, mruNode)
    }

    /// Add value to the bottom of the stack if not already present (does not change ordering if present)
    func pushIfAbsent(_ value: T) {
        var current = mruNode
        while let cur = current {
            if cur.value == value { return }
            current = cur.next
        }
        // Append at the bottom (least recent)
        if mruNode == nil {
            mruNode = Node(value)
        } else {
            var tail = mruNode!
            while let next = tail.next { tail = next }
            tail.next = Node(value)
        }
    }

    @discardableResult
    func remove(_ value: T) -> Bool {
        var prev: Node<T>? = nil
        var current = mruNode
        while let cur = current {
            if cur.value == value {
                if let prev {
                    prev.next = cur.next
                } else {
                    mruNode = current?.next
                }
                cur.next = nil
                return true
            }
            prev = cur
            current = cur.next
        }
        return false
    }
}

struct MruStackIterator<T: Equatable>: IteratorProtocol {
    typealias Element = T
    private var current: Node<T>?

    fileprivate init(_ current: Node<T>?) {
        self.current = current
    }

    mutating func next() -> T? {
        let result = current?.value
        current = current?.next
        return result
    }
}

private final class Node<T: Equatable> {
    var next: Node<T>? = nil
    let value: T

    init(_ value: T, _ next: Node<T>?) {
        self.value = value
        self.next = next
    }

    init(_ value: T) {
        self.value = value
    }
}
