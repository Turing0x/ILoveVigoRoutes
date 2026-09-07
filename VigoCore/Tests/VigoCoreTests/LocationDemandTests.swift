import Foundation
import Testing
@testable import VigoCore

/// The location lease, exercised without CoreLocation.
///
/// Every rule here was a bug the app could have had — and two of them it did have (H-50):
/// a screen turning the manager off under another screen that still wanted it, and follow
/// mode's fine precision being downgraded to coarse by a `stop()`/`start()` pair meant as a
/// reset. Both are arithmetic, so both are checked here rather than by hand on a phone.
@Suite("Demanda de ubicación")
struct LocationDemandTests {

    private let map = LocationDemand.Holder()
    private let sheet = LocationDemand.Holder()

    @Test("Nadie la pide: en reposo")
    func idleAtRest() {
        let demand = LocationDemand()
        #expect(demand.isIdle)
        #expect(demand.precision == nil)
    }

    @Test("Un solo arrendatario arranca y para")
    func singleHolder() {
        var demand = LocationDemand()
        #expect(demand.acquire(map) == .start(.coarse))
        #expect(demand.precision == .coarse)
        #expect(demand.release(map) == .stop)
        #expect(demand.isIdle)
    }

    /// The first half of H-50: the search sheet disappearing must not turn off the location
    /// the map underneath is still using.
    @Test("Soltar uno de dos no para nada")
    func releasingOneOfTwoKeepsItRunning() {
        var demand = LocationDemand()
        demand.acquire(map)
        #expect(demand.acquire(sheet) == .unchanged)
        #expect(demand.release(sheet) == .unchanged)
        #expect(demand.precision == .coarse)
        #expect(demand.release(map) == .stop)
    }

    /// The second half of H-50, and the reason `Precision` is `Comparable`: the finer request
    /// wins while it is held, and releasing it gives the coarse holder its own precision back
    /// rather than stopping the manager or leaving it running fine.
    @Test("La precisión fina gana, y soltarla devuelve la gruesa")
    func finestWins() {
        var demand = LocationDemand()
        #expect(demand.acquire(map, precision: .coarse) == .start(.coarse))
        #expect(demand.acquire(sheet, precision: .fine) == .start(.fine))
        #expect(demand.precision == .fine)
        #expect(demand.release(sheet) == .start(.coarse))
        #expect(demand.precision == .coarse)
    }

    /// The same holder raising its own precision and lowering it again — this is follow mode
    /// on `MapScreen`, which acquires `.fine` on entry and `.coarse` on exit rather than
    /// stopping and restarting.
    @Test("Un arrendatario que sube y baja su propia precisión")
    func sameHolderChangesPrecision() {
        var demand = LocationDemand()
        demand.acquire(map, precision: .coarse)
        #expect(demand.acquire(map, precision: .fine) == .start(.fine))
        #expect(demand.acquire(map, precision: .coarse) == .start(.coarse))
        #expect(demand.release(map) == .stop)
    }

    @Test("Pedir dos veces lo mismo no cambia nada")
    func repeatedAcquireIsIdempotent() {
        var demand = LocationDemand()
        demand.acquire(map, precision: .coarse)
        #expect(demand.acquire(map, precision: .coarse) == .unchanged)
    }

    /// `.onDisappear` can outlive the `.task` that would have acquired, so this has to be a
    /// no-op rather than a trap.
    @Test("Soltar un arrendatario desconocido no hace nada")
    func releasingUnknownHolder() {
        var demand = LocationDemand()
        #expect(demand.release(sheet) == .unchanged)
        demand.acquire(map)
        #expect(demand.release(sheet) == .unchanged)
        #expect(demand.precision == .coarse)
    }
}
