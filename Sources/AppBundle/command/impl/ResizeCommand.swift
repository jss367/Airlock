import AppKit
import Common

struct ResizeCommand: Command { // todo cover with tests
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else { return false }

        if window.isFloating {
            return try await resizeFloatingWindow(window, args)
        }

        let candidates = window.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else { return false }
        guard let orientation else { return false }
        guard let node else { return false }
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return false }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return true
    }
}

@MainActor
private func resizeFloatingWindow(_ window: Window, _ args: ResizeCmdArgs) async throws -> Bool {
    guard let size = try await window.getAxSize() else { return false }

    let widthDiff: CGFloat
    let heightDiff: CGFloat
    switch args.dimension.val {
        case .width:
            widthDiff = pixelDiff(args.units.val, current: size.width)
            heightDiff = 0
        case .height:
            widthDiff = 0
            heightDiff = pixelDiff(args.units.val, current: size.height)
        case .smart:
            widthDiff = pixelDiff(args.units.val, current: size.width)
            heightDiff = 0
        case .smartOpposite:
            widthDiff = 0
            heightDiff = pixelDiff(args.units.val, current: size.height)
    }

    let newWidth = max(1, size.width + widthDiff)
    let newHeight = max(1, size.height + heightDiff)
    window.setAxFrame(nil, CGSize(width: newWidth, height: newHeight))
    window.lastFloatingSize = CGSize(width: newWidth, height: newHeight)
    return true
}

private func pixelDiff(_ units: ResizeCmdArgs.Units, current: CGFloat) -> CGFloat {
    switch units {
        case .set(let unit): CGFloat(unit) - current
        case .add(let unit): CGFloat(unit)
        case .subtract(let unit): -CGFloat(unit)
    }
}
