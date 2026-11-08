import SwiftUI

@main
struct DeyeLocalApp: App {
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .environment(store)
                .tint(.orange)
        }
    }
}
