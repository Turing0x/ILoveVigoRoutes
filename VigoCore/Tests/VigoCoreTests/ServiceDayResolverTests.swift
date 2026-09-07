import Testing
import Foundation
@testable import VigoCore

@Suite("Proyección de días de servicio")
struct ServiceDayResolverTests {

    private static var madrid: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }

    /// La ventana real del feed del 4 de septiembre de 2026: sábado 5 a viernes 11.
    private static let week: Set<ServiceDate> = Set(
        (20_260_905...20_260_911).map(ServiceDate.init(yyyymmdd:)))

    private func resolver(
        days: Set<ServiceDate> = ServiceDayResolverTests.week,
        holidays: HolidayCalendar = .bundled,
        maxProjectionDays: Int = 60
    ) -> ServiceDayResolver {
        ServiceDayResolver(observedDays: days, holidays: holidays,
                           calendar: Self.madrid, maxProjectionDays: maxProjectionDays)
    }

    // MARK: - Lo observado manda

    @Test("Un día que el feed contiene nunca se proyecta")
    func observedWins() {
        for yyyymmdd in 20_260_905...20_260_911 {
            let date = ServiceDate(yyyymmdd: yyyymmdd)
            let resolved = resolver().resolve(date)
            #expect(resolved?.source == .observed)
            #expect(resolved?.template == date)
            #expect(resolved?.isProjected == false)
        }
    }

    /// La garantía que hace tolerable un calendario de festivos imperfecto: aunque el 8 de
    /// septiembre estuviera marcado como festivo por error, sigue siendo un dato observado y
    /// se devuelve tal cual.
    @Test("Un error en el calendario de festivos no puede tocar un día observado")
    func holidayErrorCannotCorruptObserved() throws {
        let json = """
        {"firstYear": 2026, "lastYear": 2026,
         "fixed": [{"month": 9, "day": 8, "name": "festivo inventado"}],
         "easterOffsets": [], "local": []}
        """
        let wrong = try HolidayCalendar.load(json: Data(json.utf8), calendar: Self.madrid)
        let date = ServiceDate(yyyymmdd: 20_260_908)
        #expect(wrong.isHoliday(date))
        #expect(resolver(holidays: wrong).resolve(date)?.source == .observed)
    }

    // MARK: - Proyección hacia adelante

    @Test("Un martes futuro se proyecta desde el último martes observado")
    func projectsSameWeekday() {
        // 20/10/2026 es martes; el martes observado es el 8/9/2026.
        let resolved = resolver().resolve(ServiceDate(yyyymmdd: 20_261_020))
        #expect(resolved?.isProjected == true)
        #expect(resolved?.template == ServiceDate(yyyymmdd: 20_260_908))
    }

    @Test("Cada día de la semana se proyecta desde su propio día")
    func everyWeekdayFindsItsTemplate() {
        let calendar = Self.madrid
        for offset in 30...60 {
            guard let date = ServiceDate(yyyymmdd: 20_260_911).adding(days: offset, calendar: calendar),
                  let resolved = resolver().resolve(date)
            else { continue }
            guard !HolidayCalendar.bundled.isHoliday(date) else { continue }
            #expect(resolved.template.gtfsWeekdayIndex(calendar: calendar)
                    == date.gtfsWeekdayIndex(calendar: calendar),
                    "\(date) se proyectó desde \(resolved.template), otro día de la semana")
        }
    }

    /// El caso observado en el planificador del Concello: 12/10/2026 es lunes y circula
    /// horario de domingo.
    @Test("Un festivo se proyecta desde un domingo, no desde su día de la semana")
    func holidayProjectsFromSunday() {
        let hispanidad = ServiceDate(yyyymmdd: 20_261_012)
        #expect(hispanidad.gtfsWeekdayIndex(calendar: Self.madrid) == 0, "es lunes")

        let resolved = resolver().resolve(hispanidad)
        #expect(resolved?.isProjected == true)
        // El domingo observado es el 6 de septiembre.
        #expect(resolved?.template == ServiceDate(yyyymmdd: 20_260_906))
        #expect(resolved?.template.gtfsWeekdayIndex(calendar: Self.madrid) == 6)
    }

    /// La otra dirección, la que es fácil pasar por alto. Si la semana capturada contiene un
    /// festivo, ese día no puede ser plantilla de los lunes normales que vienen después.
    @Test("Un festivo dentro de la ventana no sirve de plantilla")
    func holidayIsNeverATemplate() throws {
        // Ventana con dos lunes: 7 y 14 de septiembre. Marcamos el 14 (el más reciente, el
        // que ganaría por defecto) como festivo.
        let days = Set((20_260_907...20_260_914).map(ServiceDate.init(yyyymmdd:)))
        let json = """
        {"firstYear": 2026, "lastYear": 2026,
         "fixed": [], "easterOffsets": [],
         "local": [{"date": 20260914, "name": "festivo local"}]}
        """
        let holidays = try HolidayCalendar.load(json: Data(json.utf8), calendar: Self.madrid)
        let sut = resolver(days: days, holidays: holidays)

        // 5/10/2026 es lunes y no es festivo.
        let resolved = sut.resolve(ServiceDate(yyyymmdd: 20_261_005))
        #expect(resolved?.template == ServiceDate(yyyymmdd: 20_260_907),
                "debe saltarse el lunes festivo y usar el anterior")
    }

    // MARK: - Cuándo se niega

    @Test("El pasado no se proyecta")
    func refusesThePast() {
        #expect(resolver().resolve(ServiceDate(yyyymmdd: 20_260_901)) == nil)
        #expect(resolver().resolve(ServiceDate(yyyymmdd: 20_250_101)) == nil)
    }

    @Test("Más allá del horizonte, se niega")
    func refusesBeyondHorizon() {
        let sut = resolver(maxProjectionDays: 30)
        // Último día observado: 11/09/2026. +30 días es el 11/10/2026.
        #expect(sut.resolve(ServiceDate(yyyymmdd: 20_261_011)) != nil)
        #expect(sut.resolve(ServiceDate(yyyymmdd: 20_261_012)) == nil)
    }

    /// Sin calendario de festivos no hay forma de distinguir un martes cualquiera del día de
    /// Navidad, así que proyectar sería adivinar.
    @Test("Un año que el calendario de festivos no cubre se niega")
    func refusesUncoveredYear() {
        #expect(resolver(holidays: .empty).resolve(ServiceDate(yyyymmdd: 20_261_020)) == nil)

        let farFuture = resolver(maxProjectionDays: 10_000)
        #expect(farFuture.resolve(ServiceDate(yyyymmdd: 20_400_101)) == nil,
                "2040 está fuera de los años expandidos")
    }

    @Test("Sin días observados no hay nada que proyectar")
    func refusesWithNoObservations() {
        #expect(resolver(days: []).resolve(ServiceDate(yyyymmdd: 20_261_020)) == nil)
    }

    /// Un día sin servicio dentro de la ventana no entra en `observedDays`, así que no puede
    /// convertirse en la plantilla de todos los martes futuros.
    @Test("Un día sin servicio no se usa como plantilla")
    func aDayWithoutServiceIsNoTemplate() {
        var days = Self.week
        days.remove(ServiceDate(yyyymmdd: 20_260_908))   // el martes se queda sin servicio
        // 20/10/2026, martes: no hay otro martes observado.
        #expect(resolver(days: days).resolve(ServiceDate(yyyymmdd: 20_261_020)) == nil)
    }

    // MARK: - Determinismo

    @Test("La misma pregunta da siempre la misma respuesta")
    func deterministic() {
        // `observedDays` es un Set, y su orden de iteración cambia entre ejecuciones. Un
        // resolver que dependiera de ese orden daría horarios distintos en dos arranques de
        // la misma app con los mismos datos.
        let date = ServiceDate(yyyymmdd: 20_261_020)
        let answers = Set((0..<50).map { _ in resolver().resolve(date)?.template })
        #expect(answers.count == 1)
    }
}
