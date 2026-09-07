import Testing
import Foundation
@testable import VigoCore

@Suite("Calendario de festivos")
struct HolidayCalendarTests {

    private static var madrid: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }

    // MARK: - Pascua

    /// Domingos de Pascua conocidos. La fórmula es exacta, así que un fallo aquí es un fallo
    /// de transcripción del algoritmo y no una aproximación que se desvía.
    @Test("El domingo de Pascua sale bien en años conocidos")
    func easterIsExact() {
        let expected: [Int: Int] = [
            2024: 20_240_331, 2025: 20_250_420, 2026: 20_260_405,
            2027: 20_270_328, 2028: 20_280_416, 2030: 20_300_421,
            2000: 20_000_423, 1999: 19_990_404,
        ]
        for (year, yyyymmdd) in expected {
            #expect(HolidayCalendar.easterSunday(year: year).yyyymmdd == yyyymmdd,
                    "Pascua de \(year)")
        }
    }

    /// La Pascua sólo puede caer entre el 22 de marzo y el 25 de abril. Una comprobación
    /// barata sobre tres siglos que atrapa cualquier error de desbordamiento en la fórmula.
    @Test("La Pascua siempre cae en su ventana canónica, y en domingo")
    func easterStaysInItsWindow() {
        let calendar = Self.madrid
        for year in 1900...2200 {
            let easter = HolidayCalendar.easterSunday(year: year)
            #expect(easter.year == year)
            let asNumber = easter.month * 100 + easter.day
            #expect(asNumber >= 322 && asNumber <= 425,
                    "Pascua de \(year) fuera de ventana: \(easter)")
            #expect(easter.gtfsWeekdayIndex(calendar: calendar) == 6,
                    "Pascua de \(year) no cae en domingo")
        }
    }

    // MARK: - Carga

    @Test("Expande reglas fijas y desplazamientos de Pascua a fechas concretas")
    func expandsRules() throws {
        let json = """
        {"firstYear": 2026, "lastYear": 2027,
         "fixed": [{"month": 12, "day": 25, "name": "Nadal"}],
         "easterOffsets": [{"offset": -2, "name": "Venres Santo"}],
         "local": [{"date": 20260328, "name": "Reconquista"}]}
        """
        let calendar = try HolidayCalendar.load(json: Data(json.utf8), calendar: Self.madrid)

        #expect(calendar.isHoliday(ServiceDate(yyyymmdd: 20_261_225)))
        #expect(calendar.isHoliday(ServiceDate(yyyymmdd: 20_271_225)))
        // Pascua de 2026 es el 5 de abril, así que el Viernes Santo es el 3.
        #expect(calendar.isHoliday(ServiceDate(yyyymmdd: 20_260_403)))
        #expect(calendar.isHoliday(ServiceDate(yyyymmdd: 20_260_328)))
        #expect(!calendar.isHoliday(ServiceDate(yyyymmdd: 20_260_404)))
        #expect(calendar.years == 2026...2027)
    }

    @Test("Un rango de años al revés es un error, no un calendario vacío")
    func rejectsInvertedRange() {
        let json = """
        {"firstYear": 2027, "lastYear": 2026, "fixed": [], "easterOffsets": [], "local": []}
        """
        #expect(throws: HolidayCalendar.LoadError.self) {
            _ = try HolidayCalendar.load(json: Data(json.utf8), calendar: Self.madrid)
        }
    }

    @Test("Una regla fija imposible es un error")
    func rejectsImpossibleRule() {
        let json = """
        {"firstYear": 2026, "lastYear": 2026,
         "fixed": [{"month": 13, "day": 1, "name": "mes trece"}],
         "easterOffsets": [], "local": []}
        """
        #expect(throws: HolidayCalendar.LoadError.self) {
            _ = try HolidayCalendar.load(json: Data(json.utf8), calendar: Self.madrid)
        }
    }

    /// `covers` no es lo mismo que `isHoliday`. Fuera de los años expandidos el calendario no
    /// sabe nada, y "no sé" tiene que poder distinguirse de "no es festivo": es la diferencia
    /// entre proyectar a ciegas y negarse a proyectar.
    @Test("Saber que no se sabe")
    func knowsWhatItDoesNotKnow() throws {
        let json = """
        {"firstYear": 2026, "lastYear": 2026, "fixed": [], "easterOffsets": [], "local": []}
        """
        let calendar = try HolidayCalendar.load(json: Data(json.utf8), calendar: Self.madrid)
        #expect(calendar.covers(ServiceDate(yyyymmdd: 20_260_601)))
        #expect(!calendar.covers(ServiceDate(yyyymmdd: 20_300_601)))

        #expect(!HolidayCalendar.empty.covers(year: 2026))
        #expect(!HolidayCalendar.empty.isHoliday(ServiceDate(yyyymmdd: 20_261_225)))
    }

    // MARK: - El recurso empaquetado

    /// `bundled` degrada a `.empty` ante cualquier fallo, igual que `FootpathTable.bundled`.
    /// Sin esta prueba, borrar el recurso de `Package.swift` dejaría la proyección
    /// prometiendo horario de laborable el día de Navidad sin un solo error por ningún lado.
    @Test("El recurso empaquetado existe y contiene los festivos que debe")
    func bundledIsPresent() {
        let calendar = HolidayCalendar.bundled
        #expect(calendar.count > 40, "holidays-vigo.json no se cargó")
        #expect(calendar.covers(year: 2026))

        // Fijos nacionales y de Galicia.
        for yyyymmdd in [20_260_101, 20_260_106, 20_260_501, 20_260_517,
                         20_260_725, 20_260_815, 20_261_012, 20_261_101,
                         20_261_206, 20_261_208, 20_261_225] {
            #expect(calendar.isHoliday(ServiceDate(yyyymmdd: yyyymmdd)),
                    "falta el festivo \(yyyymmdd)")
        }
        // Derivados de la Pascua de 2026 (domingo 5 de abril): jueves 2, viernes 3.
        #expect(calendar.isHoliday(ServiceDate(yyyymmdd: 20_260_402)))
        #expect(calendar.isHoliday(ServiceDate(yyyymmdd: 20_260_403)))

        // Y un día laborable cualquiera no lo es.
        #expect(!calendar.isHoliday(ServiceDate(yyyymmdd: 20_260_908)))
    }

    /// El 12 de octubre de 2026 cae en lunes, y el planificador del Concello devuelve para
    /// ese día horario de domingo (`AUDITORIA-MOTOR-VS-CONCELLO.md` §2.8). Es la observación
    /// que motivó este fichero, y la que se rompería primero si alguien lo vaciara.
    @Test("El festivo que destapó la necesidad de este calendario")
    func theObservedCase() {
        let date = ServiceDate(yyyymmdd: 20_261_012)
        #expect(date.gtfsWeekdayIndex(calendar: Self.madrid) == 0, "es lunes")
        #expect(HolidayCalendar.bundled.isHoliday(date))
    }
}
