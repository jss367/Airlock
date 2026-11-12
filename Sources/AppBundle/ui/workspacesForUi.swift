/// The workspaces the menu bar, Mission Control, and Quick Switcher list, in `persistent-workspaces` order with the
/// rest sorted after them. While window management is off, only workspaces shown on a monitor can be focused (see
/// windowManagementRequired.swift), so the others are left out rather than listed as dead entries.
@MainActor
func workspacesForUi() -> [Workspace] {
    let persistentOrder = config.persistentWorkspaces
    return Workspace.all
        .filter { config.enableWindowManagement || $0.isVisible }
        .sorted { a, b in
            let ai = persistentOrder.firstIndex(of: a.name)
            let bi = persistentOrder.firstIndex(of: b.name)
            switch (ai, bi) {
                case (.some(let ai), .some(let bi)): return ai < bi
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return a < b
            }
        }
}
