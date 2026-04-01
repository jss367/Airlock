/// Stack with most recently element on top
final class MruStack<T: Equatable>: Sequence {
    typealias Element = T

    private var mruNode: Node<T>? = nil

    func makeIterator() -> MruStackIterator<T> {
        MruStackIterator(mruNode)
    }

    var mostRecent: T? { mruNode?.value }

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
