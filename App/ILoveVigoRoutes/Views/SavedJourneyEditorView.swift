import SwiftUI
import VigoCore

/// Creates a new saved journey, or edits an existing one's label and endpoints.
struct SavedJourneyEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case create
        case edit(SavedJourney)
    }

    let mode: Mode

    @State private var customLabel: String
    /// `nil` in edit mode means "keep the journey's current endpoint" — matches how
    /// `SavedJourneyEdit.origin`/`.destination` treat `nil`.
    @State private var originInput: SavedEndpointInput?
    @State private var originSummary: String
    @State private var destinationInput: SavedEndpointInput?
    @State private var destinationSummary: String
    @State private var pickingOrigin = false
    @State private var pickingDestination = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _customLabel = State(initialValue: "")
            _originInput = State(initialValue: nil)
            _originSummary = State(initialValue: "")
            _destinationInput = State(initialValue: nil)
            _destinationSummary = State(initialValue: "")
        case .edit(let journey):
            _customLabel = State(initialValue: journey.customLabel ?? "")
            _originInput = State(initialValue: nil)
            _originSummary = State(initialValue: journey.origin.name)
            _destinationInput = State(initialValue: nil)
            _destinationSummary = State(initialValue: journey.destination.name)
        }
    }

    private var isCreating: Bool { if case .create = mode { true } else { false } }

    private var canSave: Bool {
        !isCreating || (originInput != nil && destinationInput != nil)
    }

    private var derivedLabelPlaceholder: String {
        let origin = originSummary.isEmpty ? "Origen" : originSummary
        let destination = destinationSummary.isEmpty ? "Destino" : destinationSummary
        return "\(origin) → \(destination)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(derivedLabelPlaceholder, text: $customLabel)
                } header: {
                    Text("Etiqueta")
                } footer: {
                    Text("Déjala en blanco para que se derive del origen y el destino, y siga sus renombrados.")
                }

                Section("Origen") {
                    endpointRow(summary: originSummary) { pickingOrigin = true }
                }
                Section("Destino") {
                    endpointRow(summary: destinationSummary) { pickingDestination = true }
                }
            }
            .navigationTitle(isCreating ? "Nuevo trayecto" : "Editar trayecto")
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
            .sheet(isPresented: $pickingOrigin) {
                EndpointPickerSheet(title: "Origen") { input, summary in
                    originInput = input; originSummary = summary
                }
            }
            .sheet(isPresented: $pickingDestination) {
                EndpointPickerSheet(title: "Destino") { input, summary in
                    destinationInput = input; destinationSummary = summary
                }
            }
        }
    }

    private func endpointRow(summary: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(summary.isEmpty ? "Elegir" : summary)
                    .foregroundStyle(summary.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let trimmed = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .create:
            guard let originInput, let destinationInput else { return }
            environment.savedPlaces.createJourney(
                customLabel: trimmed.isEmpty ? nil : trimmed,
                origin: originInput, destination: destinationInput)
        case .edit(let journey):
            let labelEdit: SavedJourneyLabelEdit = trimmed.isEmpty ? .derived : .custom(trimmed)
            environment.savedPlaces.updateJourney(id: journey.id, SavedJourneyEdit(
                label: labelEdit, origin: originInput, destination: destinationInput))
        }
        dismiss()
    }
}

/// Picks one journey endpoint: a saved place (a live link, so a later rename propagates) or
/// anything `PlacePickerView` can find, taken as a detached, one-off snapshot.
private struct EndpointPickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (SavedEndpointInput, String) -> Void

    @State private var showingPlacePicker = false

    var body: some View {
        NavigationStack {
            List {
                if !environment.savedPlaces.places.isEmpty {
                    Section("Lugares guardados") {
                        ForEach(environment.savedPlaces.places) { place in
                            Button {
                                onPick(.savedPlace(place), place.name)
                                dismiss()
                            } label: {
                                Label(place.name, systemImage: place.symbolName)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        showingPlacePicker = true
                    } label: {
                        Label("Elegir otro lugar", systemImage: "mappin.and.ellipse")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingPlacePicker) {
            PlacePickerView(title: title) { picked in
                let anchor: SavedPlaceAnchorInput
                switch picked.place {
                case .stop(let stop): anchor = .stop(stop)
                case .coordinate(let coordinate, _): anchor = .coordinate(coordinate)
                }
                onPick(.adHoc(name: picked.place.label, anchor: anchor), picked.place.label)
                dismiss()
            }
        }
    }
}
