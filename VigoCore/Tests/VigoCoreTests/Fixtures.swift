import Foundation
@testable import VigoCore

/// A tiny but structurally complete feed, shaped like the real one: no calendar.txt rows,
/// service defined purely by calendar_dates, one trip running past midnight, one ghost
/// route with no trips, and a stop whose stop_code carries a letter prefix.
enum Fixture {

    static let stops = """
    stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding
    3493,P006930,Praza de América  1,42.2209973130163,-8.73283517659561,1
    3885,P0014264,Rúa de Urzáiz - Príncipe,42.2358735452815,-8.72008331665535,1
    4856,PA20113,Praza de América  3 (Dirección Hospital),42.2208765659118,-8.73336764352841,0
    9999,,Parada sen código,42.2300000000000,-8.72000000000000,0
    """

    static let routes = """
    route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
    1,1,C1,CIRCULAR CENTRO,3,ED4713,000000
    30,1,N4,SAMIL  – BUENOS AIRES,3,993300,000000
    18,1,18A,\tAREAL/COLÓN - SÁRDOMA/POULEIRA,3,D450A8,000000
    9003,1,9B.,BOUZAS,3,818E7E,000000
    """

    static let trips = """
    route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
    1,A  01LP001_008001,T_DAY_1,PRAZA AMÉRICA,0,B1,S1
    30,A  01LP001_008001,T_NIGHT_1,BUENOS AIRES,0,B2,S1
    18,A  01FP001_008001,T_SUN_1,POULEIRA,1,B3,S1
    """

    /// T_NIGHT_1 departs at 25:10:00 — 01:10 on the following calendar day.
    static let stopTimes = """
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
    T_DAY_1,08:00:00,08:00:00,3493,1,0,0
    T_DAY_1,08:12:00,08:12:00,3885,2,0,0
    T_NIGHT_1,25:10:00,25:10:00,3493,1,0,0
    T_NIGHT_1,25:22:00,25:22:00,3885,2,0,0
    T_SUN_1,10:00:00,10:00:00,4856,1,0,0
    T_SUN_1,10:20:00,10:20:00,3885,2,0,0
    """

    static let calendar = """
    service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date
    """

    /// 2026-09-04 is a Friday, 2026-09-06 a Sunday.
    static let calendarDates = """
    service_id,date,exception_type
    A  01LP001_008001,20260904,1
    A  01LP001_008001,20260905,1
    A  01FP001_008001,20260906,1
    """

    static let shapes = """
    shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled
    S1,42.2209973130163,-8.73283517659561,1,0
    S1,42.2358735452815,-8.72008331665535,2,1200
    """

    static let agency = """
    agency_id,agency_name,agency_url,agency_timezone,agency_lang
    1,Viguesa de Transportes S.L.,http://www.vitrasa.es/,Europe/Madrid,es
    """

    static var provider: GTFSInMemory {
        GTFSInMemory(texts: [
            "agency.txt": agency,
            "stops.txt": stops,
            "routes.txt": routes,
            "trips.txt": trips,
            "stop_times.txt": stopTimes,
            "calendar.txt": calendar,
            "calendar_dates.txt": calendarDates,
            "shapes.txt": shapes,
        ])
    }

    static func parsedFeed() throws -> GTFSFeed {
        try GTFSParser().parse(from: provider).feed
    }

    static func importedDatabase() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let result = try GTFSParser().parse(from: provider)
        _ = try GTFSImporter(database: db).import(feed: result.feed, parseWarnings: result.warnings)
        return db
    }

    static var madrid: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }

    static func date(_ yyyy: Int, _ mm: Int, _ dd: Int, _ hh: Int, _ mi: Int) -> Date {
        madrid.date(from: DateComponents(year: yyyy, month: mm, day: dd, hour: hh, minute: mi))!
    }

    /// Captured verbatim from the live API on 2026-09-04, stop 6930.
    static let liveArrivalsJSON = """
    {"parada":[{"latitud":42.220997313,"longitud":-8.732835177,"stop_vitrasa":6930,"nombre":"Praza de América  1"}],\
    "estimaciones":[{"minutos":29,"ruta":"P. AMERICA - URZAIZ - G.ESPINO*","linea":"N4","metros":-1},\
    {"minutos":141,"ruta":"PRAZA AMÉRICA*","linea":"C1","metros":-1},\
    {"minutos":158,"ruta":"PRAZA AMÉRICA*","linea":"C1","metros":-1}]}
    """

    /// Captured verbatim from the live API for an unknown stop id.
    static let unknownStopJSON = #"{"parada":[],"estimaciones":[]}"#

    /// Captured verbatim for an unrecognised `tipo`.
    static let invalidTipoJSON = #"{"t": "TIPO_INVALIDO TRANSPORTE_NAVIERAS"}"#
}
