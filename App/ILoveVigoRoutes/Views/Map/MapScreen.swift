import SwiftUI
import MapKit
import UIKit
import CoreLocation
import VigoCore

/// The map tab.
///
/// Replaces `StopsMapView` with the same behaviour plus the one thing the owner asked for
/// first: **the stops are a layer, and the layer is off by default**. A map that opens
/// speckled with 1149 pins is noise; what it should open as is a clean map of Vigo.
///
/// Anything on the map can be selected and becomes a place: one of our stops, one of Apple's
/// points of interest, or any point at all with a long press. All three land in the same
/// card, which is what makes "cualquier lugar disponible" one code path rather than three
/// special cases. Apple's own selection card is switched off (`mapFeatureSelectionAccessory(nil)`)
/// now that there is one of ours to put in its place.
struct MapScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: MapScreenModel?
    /// This screen's lease on the app's single `CLLocationManager` (H-50). `@State` so SwiftUI
    /// keeps the first `UUID` it is given for this view's identity — the initialiser still runs
    /// on every body re-evaluation, but a `UUID()` costs nanoseconds where a
    /// `LocationProvider()` cost a trip to `locationd`.
    @State private var locationHolder = LocationDemand.Holder()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))
    @State private var selection: MapSelection<StopID>?
    @State private var live: FirstBoardingLive?
    /// Measured walking times for the alternatives on screen (B3). Held here beside `live`
    /// because it has the same lifecycle: it belongs to what is being looked at, and stops
    /// the moment the screen goes away.
    @State private var walks: WalkRefinementLive?
    /// Which detent the sheet is showing.
    ///
    /// Bound rather than left to the system: `presentationDetents` on its own opens at the
    /// smallest, and the smallest here is the peek that shows only a title — so every place
    /// card arrived with its buttons hidden behind a drag the user should not have to do.
    @State private var detent: PresentationDetent = .fraction(0.45)
    /// Camera moves are animated by MapKit unless told otherwise. Someone who has asked the
    /// system for less motion has asked for exactly this kind of less.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the finger is, updated by a simultaneous drag that never consumes the gesture.
    /// `LongPressGesture` cannot report a location on its own; this is the recipe the Fase 5
    /// spike confirmed on device, panning and zooming intact.
    @State private var lastTouch: CGPoint = .zero
    /// Whether the "¿en qué autobús vas?" sheet is up.
    @State private var declaringRide = false
    @State private var choosingNearbyStop = false

    /// `CLLocationCoordinate2D` is not `Equatable`, so `onChange` cannot watch it directly.
    /// `Coordinate` is, and it is the type the rest of the flow speaks anyway.
    private var currentCoordinate: Coordinate? {
        environment.location.coordinate.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    map(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if model == nil {
                model = MapScreenModel(repository: environment.repository,
                                       planner: environment.planner)
            }
            if live == nil {
                live = FirstBoardingLive(arrivals: environment.arrivals)
            }
            if walks == nil {
                walks = WalkRefinementLive(router: environment.walkRouter)
            }
            await model?.loadStops()
            // The request may have arrived before this screen existed — Favourites can be the
            // first tab touched on a cold start.
            if let requested = environment.consumePendingSavedJourney() {
                await model?.route(savedJourney: requested)
            }
            environment.location.requestPermissionIfNeeded()
            environment.location.acquire(locationHolder)
            if let coordinate = environment.location.coordinate {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
                model?.updateCurrentLocation(
                    Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
        .onChange(of: currentCoordinate) { _, new in
            if let new { model?.updateCurrentLocation(new) }
        }
        .onDisappear {
            environment.location.release(locationHolder)
            live?.cancel()
            walks?.cancel()
            // Leaving the tab must not leave the screen pinned awake.
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: environment.feedStatus.importedAt) {
            Task { await model?.loadStops() }
        }
    }

    @ViewBuilder
    private func map(_ model: MapScreenModel) -> some View {
        MapReader { proxy in
            Map(position: $camera, selection: $selection) {
                UserAnnotation()
                ForEach(model.layer.stops) { stop in
                    Marker(stop.name, systemImage: "bus.fill",
                           coordinate: CLLocationCoordinate2D(latitude: stop.latitude,
                                                              longitude: stop.longitude))
                        .tint(.indigo)
                        .tag(MapSelection(stop.id))
                }
                // The selected place gets its own pin unless it already is one of the stop
                // markers above, which would otherwise draw two pins on one spot.
                if let place = model.state.selectedPlace, place.stop == nil {
                    Marker(place.label, systemImage: place.symbolName,
                           coordinate: place.coordinate.clLocation)
                        .tint(.red)
                }
                // Drawn from the model's own pair and not from `state.route`, so a re-plan
                // does not blank the route for the length of the query. Gated on the mode
                // instead: the route is on the map because the route flow is open, and
                // closing the sheet takes it away.
                if isRouting(model), !model.drawn.isEmpty {
                    JourneyOverviewMapContent(journeys: model.drawn.journeys,
                                              traces: model.drawn.traces,
                                              selected: model.state.selectedAlternative)
                }
            }
            // Apple draws its own card for a selected point of interest. Ours replaces it.
            .mapFeatureSelectionAccessory(nil)
            // Only the scale, which lives bottom-left and collides with nothing. The user
            // location button used to come from here, and MapKit decides where its controls
            // go — which put it under the layers button below, where it was not just ugly but
            // unreachable: the overlay swallowed every tap. Both buttons are ours now, in one
            // stack, so their positions cannot disagree. The compass goes with it: it returns
            // to this same corner the moment the map is rotated.
            .mapControls { MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { context in
                model.viewportChanged(to: MapStopsLayer.Viewport(
                    centreLatitude: context.region.center.latitude,
                    centreLongitude: context.region.center.longitude,
                    latitudeSpan: context.region.span.latitudeDelta,
                    longitudeSpan: context.region.span.longitudeDelta))
            }
            // Two simultaneous gestures, neither of which consumes the map's own: the drag
            // only records where the finger is, and the long press is what decides. Verified
            // on device in the spike — panning and zooming are untouched.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { lastTouch = $0.location })
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    guard let coordinate = proxy.convert(lastTouch, from: .local) else { return }
                    // Clearing the map's own selection first: a pressed point is a different
                    // kind of selection, and leaving a stop marker highlighted under a
                    // dropped pin's card is a lie about what the card is showing.
                    selection = nil
                    Task {
                        await model.dropPin(at: Coordinate(latitude: coordinate.latitude,
                                                           longitude: coordinate.longitude))
                    }
                })
            // A selection that resolves to neither one of our stops nor a map feature is what
            // *deselecting* looks like — MapKit writes an empty `MapSelection` rather than
            // `nil`, as the Fase 5 spike showed on device.
            .onChange(of: selection) { _, new in
                if let stopID = new?.value {
                    model.selectStop(id: stopID)
                } else if let feature = new?.feature {
                    model.selectPointOfInterest(
                        title: feature.title,
                        rawCategory: feature.pointOfInterestCategory?.rawValue,
                        coordinate: Coordinate(latitude: feature.coordinate.latitude,
                                               longitude: feature.coordinate.longitude))
                } else {
                    model.clearSelection()
                }
            }
            .onChange(of: model.state.selectedPlace) { _, place in
                if let place { focus(on: place) }
            }
            // The sheet's height is part of what each mode means: a card is useless with its
            // actions hidden, a search wants the whole screen, and following wants the map.
            //
            // Only for the modes that present a sheet, and only when the height really differs
            // (H-49). This used to run for *every* mode change, including the presenting ones,
            // and `.onChange` fires after the update in which the value changed — one update
            // too late, with the presentation already committed. The sheet was therefore
            // presented at whatever height the previous mode left behind and then animated to
            // the right one: two transitions where one was wanted, with the `.searchable` field
            // and the toolbar installed into a container that was momentarily zero-wide. That
            // is the `UIView-Encapsulated-Layout-Width == 0` constraint conflict, and the stall
            // behind `Gesture: System gesture gate timed out`, on a real iPhone.
            //
            // The presenting transitions set their own height before they present now. What is
            // left here is the mode changes that happen *underneath* a sheet that is already up
            // — `.searching → .place` when a result is picked, `.place → .routing` — where a
            // single animated resize is exactly what is wanted.
            .onChange(of: model.state.mode) { _, mode in
                guard let wanted = defaultDetent(for: mode), wanted != detent else { return }
                detent = wanted
            }
            .onChange(of: model.state.isFollowing) { _, following in
                applyFollowing(following)
            }
            .onChange(of: environment.pendingSavedJourney) { _, journey in
                guard journey != nil, let requested = environment.consumePendingSavedJourney()
                else { return }
                Task { await model.route(savedJourney: requested) }
            }
            // Realtime is asked for once per result, and only for what is on screen. Never in
            // the background: these endpoints are unofficial, and §8 of the handoff makes not
            // polling them an obligation rather than a nicety.
            //
            // Hangs off the answer and not off what is drawn, so the annotations are asked for
            // as soon as the planner replies, without waiting on the shape reads.
            .onChange(of: model.state.route.journeys) { _, _ in
                // For the visible ones, not the whole pool: the planner now hands back more
                // candidates than fit on screen so the ordering can choose among them, and
                // asking the realtime source about journeys nobody is looking at would be
                // exactly the polling §8 of the handoff rules out.
                live?.refresh(for: model.state.visibleJourneys)
                walks?.refresh(for: model.state.visibleJourneys)
            }
            // Framing follows the answer, not the question: as soon as there are routes, the
            // camera opens on all of them rather than staying on the destination pin.
            //
            // Driven by what is actually drawn, so the journeys and the traces it frames are
            // the same pair. Hanging it off `state.route.journeys` would fire while `drawn`
            // still held the previous result and frame one route with another's geometry.
            .onChange(of: model.drawn.journeys) { _, journeys in
                guard !journeys.isEmpty else { return }
                frame(journeys: journeys, traces: model.drawn.traces)
            }
            .onChange(of: model.state.selectedAlternative) { _, _ in
                frame(journeys: model.drawn.journeys, traces: model.drawn.traces)
            }
            .sheet(isPresented: $declaringRide) { OnboardDeclareSheet() }
            // Picking a stop hands it to the map's own card, which is the stop screen: this
            // sheet closes itself and the flow's single sheet opens on that stop.
            .sheet(isPresented: $choosingNearbyStop) {
                NearbyStopsSheet { stop in
                    if let wanted = defaultDetent(for: .place(.stop(stop))) { detent = wanted }
                    model.select(.stop(stop))
                }
            }
            .overlay(alignment: .top) { hint(model) }
            .overlay(alignment: .topTrailing) { controls(model) }
            .overlay(alignment: .bottom) { followingBanner(model) }
            // Only while browsing: once a card or a route is up, the sheet is the way in and
            // a second search affordance underneath it would be a second front door.
            //
            // Hidden rather than removed (H-51). Adding and removing a `safeAreaInset` is a
            // full `MKMapView` layout pass plus a change to the visible region, so the instant
            // the sheet was presented was also a camera-change instant: `onMapCameraChange`
            // below fired `viewportChanged` → `recomputeLayer()` on the main actor while UIKit
            // was installing a `NavigationStack`, a search bar and a toolbar into a brand new
            // presentation container. Keeping the inset constant costs ~50 pt of bottom inset
            // while a sheet is up — inside the margin `focus(on:)` and `frame(journeys:traces:)`
            // already compensate for, and constant, so it is no longer something their lift has
            // to be right about *while it changes*.
            //
            // `accessibilityHidden` is not optional here: a button at zero opacity is still
            // focusable by VoiceOver, and a hidden "Buscar en el mapa" that swipes into focus
            // over a route card would be trading a stutter for a regression.
            .safeAreaInset(edge: .bottom) {
                MapBrowseBar {
                    // H-49: the height first, the mode second, both in one transaction.
                    //
                    // `beginSearch()` is what presents the sheet, and the presentation reads
                    // `detent` at that instant. Leaving the height to the `.onChange` above
                    // meant the sheet opened at the card height and was then animated to
                    // `.large`. Written here, both land in the same SwiftUI update, so the
                    // sheet is built already knowing it wants the whole screen.
                    if let wanted = defaultDetent(for: .searching) { detent = wanted }
                    model.beginSearch()
                }
                .opacity(model.state.mode == .browsing ? 1 : 0)
                .allowsHitTesting(model.state.mode == .browsing)
                .accessibilityHidden(model.state.mode != .browsing)
            }
            // One sheet for the whole flow, switched by mode. Presenting a second sheet
            // over the first would stack two cards for what is one continuous journey from
            // "this place" to "how do I get there".
            .sheet(isPresented: Binding(
                get: { model.state.mode != .browsing },
                set: { if !$0 { dismissSheet(model) } }
            ), onDismiss: {
                // Back to the height every card presentation wants, once the sheet is gone.
                //
                // The next presentation reads `detent` at the instant it is made, so leaving
                // `.large` behind after a search would open the *next* place card full screen
                // and then shrink it — H-49 again, by way of a tap on a marker instead of the
                // search bar. `onDismiss` and not `dismissSheet` deliberately: this runs after
                // the dismissal animation, so it cannot resize a sheet still on its way out.
                detent = .fraction(sheetFraction)
            }) {
                sheetContent(model)
                    .presentationDetents([.height(sheetPeek), .fraction(sheetFraction), .large],
                                         selection: $detent)
                    .presentationBackgroundInteraction(backgroundInteraction(model))
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ model: MapScreenModel) -> some View {
        switch model.state.mode {
        case .place(let place):
            MapPlaceSheet(place: place,
                          distanceText: model.distanceText(to: place),
                          routeBlockedReason: model.routeBlockedReason,
                          onRoute: { Task { await model.routeToSelectedPlace() } },
                          onRouteFrom: { model.routeFromSelectedPlace() },
                          onClose: { dismissSheet(model) })

        case .routing, .journeyDetail:
            MapRouteSheet(
                state: model.state,
                failure: model.planningFailure,
                plannedAt: model.plannedAt,
                live: { live?.match(for: $0) },
                liveAdjustment: { journey, now in live?.adjustment(for: journey, now: now) },
                walkRefinement: { journey, now in walks?.outcome(for: journey, now: now) },
                onPick: { role, place in
                    Task {
                        switch role {
                        case .origin: await model.setOrigin(place)
                        case .destination: await model.setDestination(place)
                        }
                    }
                },
                onSwap: { Task { await model.swapEnds() } },
                onDeparture: { departure in Task { await model.setDeparture(departure) } },
                onOrdering: { model.ordering = $0 },
                onAccessibility: { model.accessibility = $0 },
                onRefresh: { await model.refresh() },
                onSelect: { model.selectAlternative(at: $0) },
                onOpen: { model.openSelectedAlternative() },
                onCloseDetail: { model.dismiss() },
                onFollow: { model.startFollowing() },
                onStopFollowing: { model.stopFollowing() },
                onStartActiveJourney: {
                    if let snapshot = model.startActiveJourney() {
                        environment.activeJourney.start(snapshot)
                    }
                },
                onClose: { dismissSheet(model) })

        case .searching:
            MapSearchSheet(
                purpose: .explore,
                // No dismissal here: picking switches the same sheet over to the place card,
                // which is the whole point of one sheet for the flow.
                onPick: { model.select($0) },
                onPickJourney: { journey in Task { await model.route(savedJourney: journey) } },
                onCancel: { dismissSheet(model) })

        case .browsing:
            // Unreachable: the sheet is not presented in this mode. Drawing nothing beats a
            // placeholder that could flash during the dismiss animation.
            EmptyView()
        }
    }

    /// Whether the route flow is the thing on screen, and so whether the map should be
    /// drawing a route at all.
    private func isRouting(_ model: MapScreenModel) -> Bool {
        model.state.mode == .routing || model.state.mode == .journeyDetail
    }

    /// Opens the camera on every alternative at once, lifted clear of the sheet.
    private func frame(journeys: [Journey], traces: [[JourneyTrace]]) {
        guard !journeys.isEmpty else { return }
        let region = JourneyTraceBuilder.region(for: journeys, traces: traces)
        let lift = region.span.latitudeDelta * sheetFraction / 2
        move(to: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.center.latitude - lift,
                                           longitude: region.center.longitude),
            span: region.span))
    }

    /// The height a mode wants, or `nil` for a mode that shows no sheet at all.
    ///
    /// `.browsing` used to answer `.height(sheetPeek)`, which was never a height anything was
    /// ever drawn at — the sheet is not presented in that mode — and only served to resize the
    /// sheet on its way out (H-49).
    private func defaultDetent(for mode: MapNavigationState.Mode) -> PresentationDetent? {
        switch mode {
        case .searching: .large
        case .place, .routing, .journeyDetail: .fraction(sheetFraction)
        case .browsing: nil
        }
    }

    /// The map stays live and touchable behind a *card* — that is the Apple Maps shape, and
    /// half the reason the card is a sheet at all. Behind a full-screen search it is neither:
    /// there is nothing visible to touch, and keeping the map hosted underneath is what leaves
    /// MapKit rendering into a zero-sized drawable while the sheet grows over it — the
    /// `CAMetalLayer ignoring invalid setDrawableSize width=0.000000` in the device log (H-52).
    private func backgroundInteraction(_ model: MapScreenModel) -> PresentationBackgroundInteraction {
        model.state.mode == .searching ? .disabled
                                       : .enabled(upThrough: .fraction(sheetFraction))
    }

    /// Everything follow mode actually costs, switched on and off in one place.
    ///
    /// This is what `JourneyMapView` used to own. The full-screen map it also provided is no
    /// longer worth a screen of its own — this map is already full screen — but these three
    /// are: a camera that tracks heading, a screen that does not sleep while walking, and a
    /// finer fix than the hundred metres that answers "which stops are near me".
    private func applyFollowing(_ following: Bool) {
        UIApplication.shared.isIdleTimerDisabled = following
        if following {
            environment.location.acquire(locationHolder, precision: .fine)
            camera = .userLocation(followsHeading: true,
                                   fallback: .region(MKCoordinateRegion(
                                       center: LocationProvider.vigoCentre,
                                       span: MKCoordinateSpan(latitudeDelta: 0.01,
                                                              longitudeDelta: 0.01))))
            detent = .height(sheetPeek)
        } else {
            // Back to coarse, not off: this screen still wants a position. The old
            // `stop(); start()` here was a downgrade dressed as a reset — `start()`'s default
            // accuracy silently replaced the fine one — and it stopped a manager the search
            // sheet over this map might still have been using (H-50).
            environment.location.acquire(locationHolder, precision: .coarse)
        }
    }

    /// Height of the smallest detent, and the share of the screen the medium one covers.
    /// The second is what the camera has to compensate for.
    private let sheetPeek: CGFloat = 180
    private let sheetFraction: CGFloat = 0.45

    /// Closing the sheet, from any mode it can be showing.
    ///
    /// `clearSelection()` is not enough: it only acts on `.place` by design, so dragging the
    /// sheet down while searching — or while looking at a route — would leave `mode` where it
    /// was, the binding still true, and the sheet stuck open.
    private func dismissSheet(_ model: MapScreenModel) {
        selection = nil
        model.closeSheet()
    }

    /// Centres on a place, lifted clear of the sheet.
    ///
    /// MapKit does not reframe for a sheet, so centring on the coordinate puts the pin behind
    /// the card. Moving the camera's centre *south* — to a lower latitude — slides the fixed
    /// pin towards the top of the screen, by the share of it the sheet covers.
    private func focus(on place: MapPlace) {
        let span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        let lift = span.latitudeDelta * sheetFraction / 2
        move(to: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.coordinate.latitude - lift,
                                           longitude: place.coordinate.longitude),
            span: span))
    }

    /// Every camera move goes through here so the reduce-motion rule is applied once instead
    /// of being remembered at each call site.
    private func move(to region: MKCoordinateRegion) {
        guard reduceMotion else {
            camera = .region(region)
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { camera = .region(region) }
    }

    /// Only ever shown for "too many to draw". An empty patch of map gets no hint, because
    /// zooming in would not reveal anything.
    @ViewBuilder
    private func hint(_ model: MapScreenModel) -> some View {
        if let count = model.tooManyCount {
            Text("\(count) paradas aquí. Acerca el mapa para verlas.")
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    /// The map's own controls, in one stack so their positions cannot disagree.
    private func controls(_ model: MapScreenModel) -> some View {
        VStack(spacing: 10) {
            Button {
                recentreOnUser()
            } label: {
                Image(systemName: environment.location.isAuthorized ? "location.fill"
                                                                    : "location.slash")
                    .font(.title3)
                    .frame(width: 24, height: 24)
                    .padding(9)
                    .background(.regularMaterial, in: Circle())
            }
            .disabled(!environment.location.isAuthorized)
            .accessibilityLabel("Centrar en mi ubicación")

            Menu {
                Toggle(isOn: Binding(get: { model.stopsVisible },
                                     set: { model.stopsVisible = $0 })) {
                    Label("Mostrar paradas", systemImage: "bus.fill")
                }
            } label: {
                Image(systemName: model.stopsVisible
                      ? "square.3.layers.3d" : "square.3.layers.3d.slash")
                    .font(.title3)
                    .frame(width: 24, height: 24)
                    .padding(9)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Capas del mapa")

            // «Estoy en esta parada» starts here: the stops around you, pick yours.
            Button {
                choosingNearbyStop = true
            } label: {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3)
                    .frame(width: 24, height: 24)
                    .padding(9)
                    .background(.regularMaterial, in: Circle())
            }
            .disabled(!environment.location.isAuthorized)
            .accessibilityLabel("Paradas cercanas")

            // Declaring a bus lives here rather than in a sheet somebody has to find: the
            // moment it is useful is the moment somebody is sitting on a bus with the map
            // open. It disappears while a ride is declared — the capsule at the bottom is
            // then the way in.
            if environment.onboardRide.ride == nil {
                Button {
                    declaringRide = true
                } label: {
                    Image(systemName: "bus.fill")
                        .font(.title3)
                        .frame(width: 24, height: 24)
                        .padding(9)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Voy en un autobús")
            }
        }
        .padding(.trailing, 10)
        .padding(.top, 10)
    }

    /// Follow mode is easy to start and must be just as easy to leave, without hunting for the
    /// sheet that started it — which by then is sitting at its smallest detent.
    @ViewBuilder
    private func followingBanner(_ model: MapScreenModel) -> some View {
        if model.state.isFollowing {
            Button {
                model.stopFollowing()
            } label: {
                Label("Dejar de seguir", systemImage: "location.slash.fill")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
    }

    /// Centres on the device. Never silently: with no fix yet there is nothing to centre on,
    /// and the button is already disabled when there is no permission.
    private func recentreOnUser() {
        camera = .userLocation(followsHeading: false,
                               fallback: .region(MKCoordinateRegion(
                                   center: LocationProvider.vigoCentre,
                                   span: MKCoordinateSpan(latitudeDelta: 0.04,
                                                          longitudeDelta: 0.04))))
    }
}
