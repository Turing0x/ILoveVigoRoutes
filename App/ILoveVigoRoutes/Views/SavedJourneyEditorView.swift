import SwiftUI
import VigoCore

/// Creates a new saved journey, or edits an existing one's label and endpoints.
struct SavedJourneyEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case create
        /// Creating with both ends already known — saving the route currently on the map.
        ///
        /// A separate case rather than a `create` with optional arguments so `canSave` can
        /// keep meaning "both ends are set" without a second way of being half-filled.
        case createFrom(origin: SavedEndpointInput, originName: String,
                        destination: SavedEndpointInput, destinationName: String)
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
        case .createFrom(let origin, let originName, let destination, let destinationName):
            _customLabel = State(initialValue: "")
            _originInput = State(initialValue: origin)
            _originSummary = State(initialValue: originName)
            _destinationInput = State(initialValue: destination)
            _destinationSummary = State(initialValue: destinationName)
        case .edit(let journey):
            _customLabel = State(initialValue: journey.customLabel ?? "")
            _originInput = State(initialValue: nil)
            _originSummary = State(initialValue: journey.origin.name)
            _destinationInput = State(initialValue: nil)
            _destinationSummary = State(initialValue: journey.destination.name)
        }
    }

    private var isCreating: Bool {
        switch mode {
        case .create, .createFrom: true
        case .edit: false
        }
    }

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
            // H-36: `MapSearchSheet` directly, not the `EndpointPickerSheet` this used to
            // open first — that extra sheet only re-listed "Lugares guardados" (already the
            // first thing `MapSearchSheet` itself offers here) behind one more tap, the exact
            // duplication Fase 7 existed to remove from the rest of the app.
            .sheet(isPresented: $pickingOrigin) {
                MapSearchSheet(purpose: .standalone(title: "Origen"),
                               onPick: { place in
                                   originInput = place.savedEndpointInput
                                   originSummary = place.label
                                   pickingOrigin = false
                               },
                               onPickJourney: { _ in },
                               onCancel: { pickingOrigin = false })
            }
            .sheet(isPresented: $pickingDestination) {
                MapSearchSheet(purpose: .standalone(title: "Destino"),
                               onPick: { place in
                                   destinationInput = place.savedEndpointInput
                                   destinationSummary = place.label
                                   pickingDestination = false
                               },
                               onPickJourney: { _ in },
                               onCancel: { pickingDestination = false })
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
        case .create, .createFrom:
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
