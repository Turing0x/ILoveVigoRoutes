import Foundation
import Observation
import VigoCore

/// Carga y refresca las llegadas de una única parada mientras algo la mantiene viva.
///
/// Deliberadamente sin `Task` propio ni bucle que se auto-programe: `run(stop:)` es un
/// `while` que el llamante conduce con `.task(id:)`, así que cancelar es responsabilidad de
/// quien la usa, no de esta clase. Es el mismo contrato que `StopDetailModel`, aplicado
/// donde antes no lo había — el tiempo real del mapa (`FirstBoardingLive`) no lo sigue y por
/// eso se queda congelado tras la primera respuesta; esta clase existe para no repetir ese
/// error en la ficha de lugar.
@MainActor
@Observable
final class StopArrivalsFeed {
    private let arrivals: ArrivalsService
    private(set) var result: StopArrivals?

    private let refreshInterval: Duration = .seconds(30)

    init(arrivals: ArrivalsService) {
        self.arrivals = arrivals
    }

    func load(stop: Stop, forceNetwork: Bool = false) async {
        result = await arrivals.arrivals(for: stop)
    }

    /// Carga y sigue recargando cada 30 s hasta que la tarea que la invoca se cancele.
    func run(stop: Stop) async {
        await load(stop: stop)
        while !Task.isCancelled {
            try? await Task.sleep(for: refreshInterval)
            guard !Task.isCancelled else { break }
            await load(stop: stop)
        }
    }
}
