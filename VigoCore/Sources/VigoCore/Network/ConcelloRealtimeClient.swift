import Foundation

/// Talks to the Concello de Vigo application API that backs InfoBus.
///
/// Endpoint and field names were reverse-engineered from `David-Lor/VigoBusAPI` and
/// `arielcostas/infobus-bot`, then re-verified live against three stops on 2026-09-04.
/// Where the reference projects disagreed with the live response, the live response wins.
/// See `DATA-SOURCES.md` §3.
public struct ConcelloRealtimeClient: RealtimeArrivalsProviding {

    public static let defaultBaseURL = URL(string: "https://datos.vigo.org/vci_api_app/api2.jsp")!

    /// Identifies this app to the source. These are unofficial public endpoints kept
    /// running by a municipality, so being recognisable is the polite minimum.
    public static let userAgent = "ILoveVigoRoutes/1.0 (personal use; iOS; +https://github.com/local/ILoveVigoRoutes)"

    let baseURL: URL
    let session: URLSession
    let timeout: TimeInterval

    public init(baseURL: URL = ConcelloRealtimeClient.defaultBaseURL,
                session: URLSession? = nil,
                timeout: TimeInterval = 12) {
        self.baseURL = baseURL
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.waitsForConnectivity = false
            // Arrivals go stale in seconds; a URL cache would only ever serve wrong data.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func arrivals(for stopCode: VitrasaStopCode) async throws -> ArrivalsSnapshot {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "tipo", value: "TRANSPORTE-ESTIMACION-PARADA"),
            URLQueryItem(name: "id", value: String(stopCode.value)),
            URLQueryItem(name: "ttl", value: "5"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let declaredCharset: String?
        do {
            let (payload, response) = try await session.data(for: request)
            // The status code is checked, but it proves nothing here: this API answers
            // unknown stops and invalid requests alike with 200. The body is the truth.
            let http = response as? HTTPURLResponse
            if let http, !(200...299).contains(http.statusCode) {
                throw RealtimeError.transport("HTTP \(http.statusCode)")
            }
            declaredCharset = http?.value(forHTTPHeaderField: "Content-Type")
            data = payload
        } catch let error as RealtimeError {
            throw error
        } catch {
            throw RealtimeError.transport(error.localizedDescription)
        }

        return try Self.decode(data, stopCode: stopCode, fetchedAt: Date(),
                               contentType: declaredCharset)
    }

    /// Picks the text encoding for a response body.
    ///
    /// The API currently answers `application/json;charset=ISO-8859-1`, so the declared
    /// charset is honoured when present. Falling back to Latin-1 unconditionally would be
    /// wrong the day the source starts serving UTF-8: every byte sequence is *valid*
    /// Latin-1, so the mistake would never raise an error, it would just quietly turn
    /// "América" into "AmÃ©rica". Sniffing UTF-8 first avoids that, because Latin-1
    /// accented text is almost never valid UTF-8.
    static func text(from data: Data, contentType: String?) -> String? {
        let declared = contentType?.lowercased()
        if let declared {
            if declared.contains("iso-8859-1") || declared.contains("latin1") || declared.contains("windows-1252") {
                return String(data: data, encoding: .isoLatin1)
            }
            if declared.contains("utf-8") {
                return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Separated from the transport so it can be tested against captured payloads.
    static func decode(_ data: Data, stopCode: VitrasaStopCode, fetchedAt: Date,
                       contentType: String? = nil) throws -> ArrivalsSnapshot {
        guard let text = text(from: data, contentType: contentType) else {
            throw RealtimeError.decoding("response was neither ISO-8859-1 nor UTF-8")
        }
        let utf8 = Data(text.utf8)

        // An unknown `tipo` comes back as {"t":"TIPO_INVALIDO ..."} — again with HTTP 200.
        if let rejection = try? JSONDecoder().decode(UpstreamRejection.self, from: utf8) {
            throw RealtimeError.upstreamRejectedRequest(rejection.t)
        }

        let payload: EstimationPayload
        do {
            payload = try JSONDecoder().decode(EstimationPayload.self, from: utf8)
        } catch {
            let preview = String(text.prefix(200))
            throw RealtimeError.decoding("\(error.localizedDescription) — body began: \(preview)")
        }

        // An empty `parada` means the source has never heard of this stop. An empty
        // `estimaciones` with a populated `parada` means a real stop with nothing due.
        // Collapsing the two would turn a bad identifier into a silent "no buses".
        guard let stop = payload.parada.first else {
            throw RealtimeError.stopNotFound(stopCode)
        }

        let arrivals = payload.estimaciones
            .map { Arrival(rawLine: $0.linea, destination: $0.ruta,
                           minutes: $0.minutos, metres: $0.metros) }
            .sorted { $0.minutes < $1.minutes }

        return ArrivalsSnapshot(
            stopCode: VitrasaStopCode(stop.stop_vitrasa),
            stopName: stop.nombre,
            latitude: stop.latitud,
            longitude: stop.longitud,
            arrivals: arrivals,
            fetchedAt: fetchedAt)
    }

    // Wire types. Field names are those observed live, not those in the reference
    // projects — infobus-bot expects `subtipo_gl` and `Tipo` where the API sends
    // `subtipo_ga` and `tipo_dia`, so its naming is not reliable.
    private struct EstimationPayload: Decodable {
        struct StopInfo: Decodable {
            let nombre: String?
            let stop_vitrasa: Int
            let latitud: Double?
            let longitud: Double?
        }
        struct Estimate: Decodable {
            let linea: String
            let ruta: String
            let minutos: Int
            let metros: Int?
        }
        let parada: [StopInfo]
        let estimaciones: [Estimate]
    }

    private struct UpstreamRejection: Decodable { let t: String }
}
