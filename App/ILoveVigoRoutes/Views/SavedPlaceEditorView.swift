import SwiftUI
import VigoCore

/// A name-and-icon shortcut offered only at creation time. Selecting one just fills in
/// `name` and `symbolName` in the form below — there is no template column in the schema,
/// no uniqueness, and no singleton slot. Two places from the same template coexist exactly
/// like any other pair of saved places.
private struct PlaceTemplate: Identifiable {
    let name: String
    let symbolName: String
    var id: String { name }

    static let all: [PlaceTemplate] = [
        PlaceTemplate(name: "Casa", symbolName: "house.fill"),
        PlaceTemplate(name: "Trabajo", symbolName: "briefcase.fill"),
        PlaceTemplate(name: "Hospital", symbolName: "cross.case.fill"),
        PlaceTemplate(name: "Centro de salud", symbolName: "stethoscope"),
        PlaceTemplate(name: "Gimnasio", symbolName: "figure.run"),
        PlaceTemplate(name: "Otro", symbolName: "mappin.circle.fill"),
    ]
}

/// SF Symbols offered for a saved place's icon. A fixed, curated set rather than a search
/// field: there is no need to browse the whole SF Symbols catalogue for this.
private let availableSymbols = [
    "house.fill", "briefcase.fill", "cross.case.fill", "stethoscope", "figure.run",
    "mappin.circle.fill", "cart.fill", "building.2.fill", "graduationcap.fill",
    "star.fill", "heart.fill", "pawprint.fill", "fork.knife", "cup.and.saucer.fill",
    "airplane", "car.fill", "tree.fill", "figure.2.and.child.holdinghands",
]

/// Creates a new saved place, or edits an existing one — the same form either way, which is
/// what makes renaming, re-iconing and re-anchoring a single screen instead of three.
struct SavedPlaceEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case create
        /// Shortcut from "Guardar como lugar…" on a stop row or a resolved address in
        /// `MapSearchSheet`: the anchor is already known, only the name is missing.
        case createFrom(Place)
        case edit(SavedPlace)
    }

    let mode: Mode

    @State private var name: String
    @State private var symbolName: String
    /// Set only when the user actively picks or re-picks a point. `nil` in edit mode means
    /// "keep the place's current anchor" — `SavedPlaceEdit.anchor` treats `nil` exactly
    /// that way.
    @State private var anchorInput: SavedPlaceAnchorInput?
    @State private var anchorSummary: String
    @State private var pickingAnchor = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _symbolName = State(initialValue: "mappin.circle.fill")
            _anchorInput = State(initialValue: nil)
            _anchorSummary = State(initialValue: "")
        case .createFrom(let place):
            _name = State(initialValue: place.label)
            _symbolName = State(initialValue: "mappin.circle.fill")
            _anchorInput = State(initialValue: Self.input(for: place))
            _anchorSummary = State(initialValue: place.label)
        case .edit(let place):
            _name = State(initialValue: place.name)
            _symbolName = State(initialValue: place.symbolName)
            _anchorInput = State(initialValue: nil)
            _anchorSummary = State(initialValue: Self.summary(for: place.anchor))
        }
    }

    private var isCreating: Bool {
        switch mode {
        case .create, .createFrom: true
        case .edit: false
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isCreating || anchorInput != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreating {
                    Section("Plantillas") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(PlaceTemplate.all) { template in
                                    Button {
                                        name = template.name
                                        symbolName = template.symbolName
                                    } label: {
                                        Label(template.name, systemImage: template.symbolName)
                                            .font(.footnote)
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                }

                Section("Nombre") {
                    TextField("Nombre del lugar", text: $name)
                }

                Section("Icono") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(availableSymbols, id: \.self) { symbol in
                            Button {
                                symbolName = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 36, height: 36)
                                    .background(symbol == symbolName ? .indigo.opacity(0.2) : .clear,
                                               in: Circle())
                                    .foregroundStyle(symbol == symbolName ? .indigo : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Punto") {
                    Button {
                        pickingAnchor = true
                    } label: {
                        HStack {
                            Text(anchorSummary.isEmpty ? "Elegir punto" : anchorSummary)
                                .foregroundStyle(anchorSummary.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(isCreating ? "Nuevo lugar" : "Editar lugar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $pickingAnchor) {
                MapSearchSheet(purpose: .standalone(title: "Punto del lugar"),
                               onPick: { place in
                                   // `place.savedEndpointInput.anchor`, not `input(for:)`
                                   // (H-37): a `MapPlace` is available here, and its `origin`
                                   // is the same source of truth `MapPlace.savedEndpoint`
                                   // reads on the way back in — one rule instead of two that
                                   // have to be kept in step by hand.
                                   anchorInput = place.savedEndpointInput.anchor
                                   anchorSummary = place.label
                                   pickingAnchor = false
                               },
                               onPickJourney: { _ in },
                               onCancel: { pickingAnchor = false })
            }
        }
    }

    private func save() {
        switch mode {
        case .create, .createFrom:
            guard let anchorInput else { return }
            environment.savedPlaces.createPlace(name: name, symbolName: symbolName, anchor: anchorInput)
        case .edit(let place):
            environment.savedPlaces.updatePlace(
                id: place.id, SavedPlaceEdit(name: name, symbolName: symbolName, anchor: anchorInput))
        }
        dismiss()
    }

    /// Only for `.createFrom(Place)`, where there is no `MapPlace` to read an `origin` from
    /// — a bare `Place` has exactly these two cases, with nothing left to disambiguate the
    /// way `MapPlace.origin` sometimes has to (see `savedEndpointInput`), so this is not a
    /// second copy of that rule, just its narrower half.
    private static func input(for place: Place) -> SavedPlaceAnchorInput {
        switch place {
        case .stop(let stop): .stop(stop)
        case .coordinate(let coordinate, _): .coordinate(coordinate)
        }
    }

    private static func summary(for anchor: SavedPlaceAnchor) -> String {
        switch anchor {
        case .stop(let stop): stop.name
        case .orphanedStop: "Parada guardada ya no disponible en el horario vigente"
        case .coordinate: "Punto guardado en el mapa"
        }
    }
}
