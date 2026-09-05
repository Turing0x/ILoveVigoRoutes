import Foundation
import Testing
@testable import VigoCore

/// La consulta de un día entero de una línea en una parada.
///
/// El fixture está hecho a medida para esto: `T_NIGHT_1` sale a las **25:10** del día de
/// servicio 20260904, o sea a la 01:10 del 5 de septiembre.
@Suite("Horarios de una línea en una parada")
struct LineTimetableQueryTests {

    private func repository() throws -> TransitRepository {
        TransitRepository(database: try Fixture.importedDatabase())
    }

    private let praza = StopID("3493")
    private let nocturna = RouteID("30")     // N4, la que sale a las 25:10
    private let circular = RouteID("1")      // C1, la de las 08:00

    /// **El test de esta fase.** Una salida a las 25:10 del día 4 *ocurre* el día 5, y quien
    /// lee la tabla del día 5 espera encontrarla ahí. Preguntar solo por el día que se nombra
    /// pierde todas las salidas de madrugada de las líneas nocturnas — y todo lo demás
    /// seguiría pareciendo correcto.
    @Test("Una salida de madrugada aparece en el día en que de verdad ocurre")
    func pastMidnightBelongsToTheNextDay() throws {
        let repository = try repository()

        let fifth = try repository.scheduledDepartures(
            stopID: praza, routeID: nocturna, on: ServiceDate(yyyymmdd: 20_260_905))
        try #require(fifth.count == 1)
        #expect(fifth[0].absoluteDate == Fixture.date(2026, 9, 5, 1, 10))
        #expect(fifth[0].serviceDate == ServiceDate(yyyymmdd: 20_260_904),
                "el día de servicio del que salió sigue siendo el 4")
        #expect(fifth[0].routeShortName == "N4")

        // Y no aparece en el día 4, que es cuando *no* pasa por la parada.
        let fourth = try repository.scheduledDepartures(
            stopID: praza, routeID: nocturna, on: ServiceDate(yyyymmdd: 20_260_904))
        #expect(fourth.isEmpty, "la del día 4 se marcha a la 01:10 del 5")
    }

    @Test("Solo salen los horarios de la línea pedida, no los de otra que para en el mismo poste")
    func otherRoutesAreNotIncluded() throws {
        let repository = try repository()
        // La parada 3493 la sirven la C1 (08:00) y la N4 (25:10) el mismo día de servicio.
        let departures = try repository.scheduledDepartures(
            stopID: praza, routeID: circular, on: ServiceDate(yyyymmdd: 20_260_905))

        try #require(departures.count == 1)
        #expect(departures[0].routeShortName == "C1")
        #expect(departures[0].absoluteDate == Fixture.date(2026, 9, 5, 8, 0))
    }

    /// El día 6 es domingo y ese servicio no corre: un día sin servicio no es un error, es una
    /// respuesta.
    @Test("Un día en el que la línea no circula devuelve una tabla vacía")
    func daysWithoutServiceAreEmpty() throws {
        let repository = try repository()
        #expect(try repository.scheduledDepartures(
            stopID: praza, routeID: circular, on: ServiceDate(yyyymmdd: 20_260_906)).isEmpty)
    }

    @Test("Las salidas vienen ordenadas por el instante en que ocurren")
    func resultsAreChronological() throws {
        let repository = try repository()
        let departures = try repository.scheduledDepartures(
            stopID: praza, routeID: nocturna, on: ServiceDate(yyyymmdd: 20_260_906))
        // La del día de servicio 5, que ocurre a la 01:10 del 6.
        try #require(departures.count == 1)
        #expect(departures[0].absoluteDate == Fixture.date(2026, 9, 6, 1, 10))
    }

    // MARK: - El día que dura 25 horas

    /// Un feed mínimo alrededor del cambio de hora de octubre.
    ///
    /// Existe porque una mutación —calcular los bordes del día sumando 86400 fijo en vez de
    /// restar medianoches reales— **pasó desapercibida** con el fixture normal, que vive
    /// entero en septiembre. Es el mismo aviso que la Fase 5 dejó escrito tres veces: un test
    /// con datos cómodos no ve la mitad de los fallos.
    ///
    /// El **domingo 25 de octubre de 2026** los relojes se atrasan a las 03:00 en Europe/Madrid,
    /// así que ese día dura 25 horas. Una salida a las `24:30` del día de servicio 25 ocurre
    /// **antes** de la medianoche del 26 —quedan 30 minutos— y pertenece por tanto a la tabla
    /// del 25. Con 86400 fijo se cae de esa tabla y aparece un día tarde.
    private func dstDatabase() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let provider = GTFSInMemory(texts: [
            "agency.txt": Fixture.agency,
            "stops.txt": """
            stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding
            3493,P006930,Praza de América  1,42.2209973130163,-8.73283517659561,1
            """,
            "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            30,1,N4,SAMIL  – BUENOS AIRES,3,993300,000000
            """,
            "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            30,SUN,T_LATE,BUENOS AIRES,0,B1,
            """,
            "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
            T_LATE,24:30:00,24:30:00,3493,1,0,0
            """,
            "calendar.txt": Fixture.calendar,
            "calendar_dates.txt": """
            service_id,date,exception_type
            SUN,20261025,1
            """,
            "shapes.txt": """
            shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled
            """,
        ])
        let result = try GTFSParser().parse(from: provider)
        _ = try GTFSImporter(database: db).import(feed: result.feed, parseWarnings: result.warnings,
                                                  importedAt: Fixture.date(2026, 10, 24, 8, 0))
        return db
    }

    @Test("El día del cambio de hora dura 25 horas, y los bordes lo respetan")
    func daylightSavingDayIsTwentyFiveHours() throws {
        let repository = TransitRepository(database: try dstDatabase())

        let table = try repository.scheduledDepartures(
            stopID: praza, routeID: nocturna, on: ServiceDate(yyyymmdd: 20_261_025))

        try #require(table.count == 1, "la salida de las 24:30 cae dentro del propio día 25")
        let midnightOn26 = try #require(
            ServiceDate(yyyymmdd: 20_261_026).startOfDay(in: Fixture.madrid))
        #expect(table[0].absoluteDate < midnightOn26,
                "ocurre antes de que acabe el 25, que ese día tiene una hora de más")

        // Y no se cuela en la tabla del día siguiente.
        #expect(try repository.scheduledDepartures(
            stopID: praza, routeID: nocturna, on: ServiceDate(yyyymmdd: 20_261_026)).isEmpty)
    }

    // MARK: - Días que el feed puede contestar

    /// El feed real descargado el 2026-09-04 reportaba ventana 20260905–20260911: **empieza
    /// mañana**. Un selector construido con el reloj ofrecería días que no contestan nada.
    @Test("Los días ofrecidos salen de la ventana del feed, no del reloj")
    func serviceDaysComeFromTheWindow() throws {
        let status = try repository().feedStatus()
        let days = status.serviceDays(calendar: Fixture.madrid)

        #expect(days == [ServiceDate(yyyymmdd: 20_260_904),
                         ServiceDate(yyyymmdd: 20_260_905),
                         ServiceDate(yyyymmdd: 20_260_906)])
    }

    @Test("Sin feed importado no se ofrece ningún día")
    func noFeedNoDays() {
        #expect(FeedStatus.empty.serviceDays(calendar: Fixture.madrid).isEmpty)
    }
}
