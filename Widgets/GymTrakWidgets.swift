import SwiftUI
import WidgetKit

/// The extension only hosts the rest-timer Live Activity; there are no home-screen widgets.
@main
struct GymTrakWidgets: WidgetBundle {
    var body: some Widget {
        RestLiveActivity()
    }
}
