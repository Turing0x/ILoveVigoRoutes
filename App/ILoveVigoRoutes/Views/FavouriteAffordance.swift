import SwiftUI
import VigoCore

/// A star toolbar button backed by `environment.favourites`, the single source of truth.
/// Reading `environment.favourites.contains(stop.id)` inside `body` registers the
/// `@Observable` dependency, so this button — wherever it appears — updates the instant
/// any other screen toggles the same stop.
struct FavouriteStarButton: View {
    @Environment(AppEnvironment.self) private var environment
    let stop: Stop

    private var isFavourite: Bool { environment.favourites.contains(stop.id) }

    var body: some View {
        Button {
            environment.favourites.toggle(stop)
        } label: {
            Image(systemName: isFavourite ? "star.fill" : "star")
        }
        .accessibilityLabel(isFavourite ? "Quitar de favoritos" : "Añadir a favoritos")
    }
}

/// Swipe and context-menu favourite actions for a stop in a list row. The same gesture
/// wherever a stop appears in a list, so the user only has to learn it once.
private struct FavouriteRowActions: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    let stop: Stop

    private var isFavourite: Bool { environment.favourites.contains(stop.id) }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    environment.favourites.toggle(stop)
                } label: {
                    Label(isFavourite ? "Quitar de favoritos" : "Añadir a favoritos",
                          systemImage: isFavourite ? "star.slash" : "star.fill")
                }
                .tint(.yellow)
            }
            .contextMenu {
                Button {
                    environment.favourites.toggle(stop)
                } label: {
                    Label(isFavourite ? "Quitar de favoritos" : "Añadir a favoritos",
                          systemImage: isFavourite ? "star.slash" : "star.fill")
                }
            }
    }
}

extension View {
    /// Applies the standard leading swipe action and context menu for favouriting a stop
    /// inside a list row.
    func favouriteActions(for stop: Stop) -> some View {
        modifier(FavouriteRowActions(stop: stop))
    }
}
