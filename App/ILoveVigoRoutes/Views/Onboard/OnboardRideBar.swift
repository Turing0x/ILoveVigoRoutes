import SwiftUI
import VigoCore

/// The capsule for "voy en el 9B.", sibling of `ActiveJourneyBar` and never on screen at the
/// same time as it: the two states are mutually exclusive, enforced in the repository.
///
/// It says how old the position is rather than implying a live one. The app only tracks
/// location in the foreground — when-in-use, no background modes — so "hace 6 min" is the
/// honest thing to show, and the same discipline `MapScreenModel.plannedAt` already applies to
/// a route on screen.
struct OnboardRideBar: View {
    let ride: OnboardRide
    let staleness: OnboardRideStaleness
    let looksOffRide: Bool
    let onEnd: () -> Void

    @State private var showingDestination = false

    var body: some View {
        Button {
            showingDestination = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: needsAsking ? "questionmark.circle.fill" : "bus.fill")
                    .foregroundStyle(needsAsking ? .orange : .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(needsAsking ? "¿Sigues en este autobús?" : "Vas en el \(ride.routeShortName)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(headline).font(.subheadline).lineLimit(1)
                }
                Spacer(minLength: 0)
                if needsAsking {
                    Button("Ya me bajé", action: onEnd)
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("¿Adónde llego?", systemImage: "mappin.and.ellipse") {
                showingDestination = true
            }
            Button("Ya me he bajado", systemImage: "figure.walk", role: .destructive, action: onEnd)
        }
        .sheet(isPresented: $showingDestination) {
            OnboardDestinationSheet(ride: ride)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Vas en el \(ride.routeShortName). \(headline)"))
    }

    private var needsAsking: Bool {
        if case .stale = staleness { return true }
        return looksOffRide
    }

    private var headline: String {
        var parts = [ride.currentStop.name]
        if abs(ride.observedDelaySeconds) >= 120 {
            let minutes = Int((Double(ride.observedDelaySeconds) / 60).rounded())
            parts.append(minutes > 0 ? "+\(minutes) min" : "\(minutes) min")
        }
        parts.append(age)
        return parts.joined(separator: " · ")
    }

    /// The age of the last confirmed position, never "en directo".
    private var age: String {
        let seconds = Date().timeIntervalSince(ride.updatedAt)
        if seconds < 90 { return "ahora mismo" }
        return "hace \(Int((seconds / 60).rounded())) min"
    }
}
