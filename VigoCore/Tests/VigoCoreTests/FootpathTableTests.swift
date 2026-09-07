import Testing
import Foundation
@testable import VigoCore

@Suite("Tabla de caminatas medidas")
struct FootpathTableTests {

    // MARK: - Parsing

    @Test("Lee el CSV que genera la herramienta")
    func parsesGeneratorOutput() throws {
        let csv = """
        from_stop_id,to_stop_id,metres
        2997,2999,231
        3000,3001,88
        """
        let table = try FootpathTable.load(csv: Data(csv.utf8))
        #expect(table.pairCount == 2)
        #expect(table.metres(from: StopID("2997"), to: StopID("2999")) == 231)
        #expect(table.coveredStops == [StopID("2997"), StopID("2999"),
                                       StopID("3000"), StopID("3001")])
    }

    /// The generator writes one row per pair. Reading it back in either direction has to
    /// give the same answer, or a transfer would cost different amounts depending on which
    /// way RAPTOR happened to relax it.
    @Test("Una fila sirve para las dos direcciones")
    func undirected() throws {
        let table = try FootpathTable.load(csv: Data("from_stop_id,to_stop_id,metres\nA,B,150\n".utf8))
        #expect(table.metres(from: StopID("A"), to: StopID("B")) == 150)
        #expect(table.metres(from: StopID("B"), to: StopID("A")) == 150)
    }

    @Test("Tolera el fin de línea de Windows, líneas en blanco y comentarios")
    func tolerantFormat() throws {
        let csv = "# generado por Tools/build_footpaths.py\r\nfrom_stop_id,to_stop_id,metres\r\nA,B,10\r\n\r\n"
        let table = try FootpathTable.load(csv: Data(csv.utf8))
        #expect(table.pairCount == 1)
        #expect(table.metres(from: StopID("A"), to: StopID("B")) == 10)
    }

    @Test("Una fila rota se denuncia con su número de línea")
    func malformedRowIsNamed() {
        #expect(throws: FootpathTable.LoadError.self) {
            _ = try FootpathTable.load(csv: Data("from_stop_id,to_stop_id,metres\nA,B\n".utf8))
        }
        #expect(throws: FootpathTable.LoadError.self) {
            _ = try FootpathTable.load(csv: Data("from_stop_id,to_stop_id,metres\nA,B,lejos\n".utf8))
        }
    }

    @Test("Ante filas repetidas gana la más corta")
    func duplicatesTakeTheShorter() throws {
        let table = try FootpathTable.load(
            csv: Data("from_stop_id,to_stop_id,metres\nA,B,300\nB,A,120\n".utf8))
        #expect(table.pairCount == 1)
        #expect(table.metres(from: StopID("A"), to: StopID("B")) == 120)
    }

    @Test("Una parada consigo misma no es una caminata")
    func noSelfPair() throws {
        let table = try FootpathTable.load(csv: Data("from_stop_id,to_stop_id,metres\nA,A,0\n".utf8))
        #expect(table.pairCount == 0)
        #expect(table.covers(StopID("A")), "la parada sigue estando medida")
    }

    @Test("La tabla vacía no cubre nada, así que todo cae al estimador")
    func emptyCoversNothing() {
        #expect(FootpathTable.empty.pairCount == 0)
        #expect(!FootpathTable.empty.covers(StopID("2997")))
        #expect(FootpathTable.empty.metres(from: StopID("A"), to: StopID("B")) == nil)
    }

    // MARK: - The shipped resource

    /// `FootpathTable.bundled` swallows every failure and degrades to `.empty` on purpose —
    /// a packaging mistake must not crash the app. The cost of that is that a resource
    /// dropped from `Package.swift`, renamed, or corrupted would be **completely silent**,
    /// and the planner would quietly go back to guessing. This test is the alarm that
    /// silence needs.
    @Test("El recurso empaquetado existe, se lee y tiene la forma esperada")
    func bundledResourceIsPresentAndSane() {
        let table = FootpathTable.bundled
        #expect(table.pairCount > 2_000,
                "footpaths.csv no se cargó, o se cargó truncado — el planificador estaría estimando en línea recta")
        #expect(table.coveredStops.count > 900)

        // Vigo's stop ids are numeric strings in the 2000–6000 band. If they ever stop
        // being the GTFS `stop_id` — `stop_code` is the other candidate and looks like
        // "P006930" — every lookup in this table would miss and the whole thing would
        // degrade to the estimate without a single error. DATA-SOURCES.md §2.8.
        let sample = table.coveredStops.prefix(50)
        #expect(sample.allSatisfy { Int($0.rawValue) != nil },
                "las claves dejaron de ser stop_id del GTFS")
    }

    /// The measured distances have to be plausible walks, not artefacts. Anything at zero
    /// would make a transfer instantaneous; anything far beyond the policy radius means the
    /// table was generated with settings the app no longer agrees with.
    @Test("Las distancias empaquetadas caen dentro del radio de política")
    func bundledDistancesAreInRange() {
        let table = FootpathTable.bundled
        guard table.pairCount > 0 else { return }
        let radius = PlannerOptions().maxTransferWalkMetres
        var checked = 0
        for a in table.coveredStops {
            for b in table.coveredStops where a != b {
                guard let metres = table.metres(from: a, to: b) else { continue }
                #expect(metres > 0, "una caminata de cero metros haría el transbordo instantáneo")
                #expect(metres <= radius,
                        "generada con un radio distinto del que usa PlannerOptions")
                checked += 1
                if checked > 400 { return }
            }
        }
    }
}
