import SwiftUI
import MapKit
import VigoCore

/// Several alternatives at once: the highlighted one in full colour, the rest behind it in
/// grey.
///
/// Only the highlighted journey gets stop markers. With four alternatives sharing a corridor,
/// drawing every boarding and alighting pin turns the middle of Vigo into confetti, and the
/// pins that matter are the ones belonging to the route being read.
struct JourneyOverviewMapContent: MapContent {
    let journeys: [Journey]
    let traces: [[JourneyTrace]]
    let selected: Int

    var body: some MapContent {
        // Declaration order is draw order, so every unselected route goes down first and the
        // highlighted one is never buried under a grey line.
        ForEach(Array(journeys.enumerated()), id: \.offset) { index, _ in
            if index != selected, traces.indices.contains(index) {
                ForEach(traces[index]) { trace in
                    MapPolyline(coordinates: trace.coordinates)
                        .stroke(.secondary.opacity(0.45), lineWidth: 5)
                }
            }
        }

        if journeys.indices.contains(selected) {
            JourneyMapContent(journey: journeys[selected],
                              traces: traces.indices.contains(selected) ? traces[selected] : [])
        }
    }
}
