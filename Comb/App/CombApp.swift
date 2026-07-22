import SwiftUI

@main
struct CombApp: App {
    @State private var model = ConnectModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let session = model.session {
                    ChannelListView(session: session) {
                        Task { await model.disconnect() }
                    }
                } else {
                    ConnectView(model: model)
                }
            }
            .task {
                #if DEBUG
                // Lets automation drive the demo path with no taps:
                // simctl launch ... --demo [--open-first-channel]
                if ProcessInfo.processInfo.arguments.contains("--demo") {
                    await model.connectDemo()
                }
                #endif
            }
        }
    }
}

#if DEBUG
enum LaunchFlags {
    static var opensFirstChannel: Bool {
        ProcessInfo.processInfo.arguments.contains("--open-first-channel")
    }
}
#endif
