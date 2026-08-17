import SwiftUI

@main
@MainActor
struct PiccoloApp: App {
    @StateObject private var store: ReviewStore

    init() {
        _store = StateObject(wrappedValue: ReviewStore())
    }

    var body: some Scene {
        WindowGroup {
            PhotoReviewView(store: store)
        }
        .defaultSize(width: 1_100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            ReviewCommands(store: store)
        }
    }
}

@MainActor
private struct ReviewCommands: Commands {
    @ObservedObject var store: ReviewStore

    var body: some Commands {
        CommandMenu("Review") {
            Button("Keep Photo") {
                perform(.keep)
            }
            .keyboardShortcut("k", modifiers: [])
            .disabled(!canPerform)

            Button("Move Photo to Trash") {
                perform(.trash)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!canPerform)

            Button("Move Photo to Trash with Forward Delete") {
                perform(.trash)
            }
            .keyboardShortcut(.deleteForward, modifiers: [])
            .disabled(!canPerform)

            Divider()

            Button("Pass Photo") {
                perform(.pass)
            }
            .keyboardShortcut(" ", modifiers: [])
            .disabled(!canPerform)

            Button("Pass Photo with Right Arrow") {
                perform(.pass)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!canPerform)
        }
    }

    private var canPerform: Bool {
        store.isActiveReviewVisible && !store.isBusy
    }

    private func perform(_ action: ReviewAction) {
        Task {
            await store.perform(action)
        }
    }
}
