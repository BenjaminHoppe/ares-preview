import SwiftUI

struct TelemetryPanel: View {
    @ObservedObject var timekeeper: MarsTimekeeper

    let coordinates: String
    let resolution: String
    let fieldOfView: String

    var body: some View {
        TelemetryView(
            timekeeper: timekeeper,
            coordinates: coordinates,
            resolution: resolution,
            fieldOfView: fieldOfView
        )
    }
}
