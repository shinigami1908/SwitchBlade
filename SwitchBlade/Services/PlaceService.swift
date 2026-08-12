import Foundation
import CoreLocation
import Observation

/// Current conditions for the home header.
struct WeatherSnapshot: Sendable, Equatable {
    var temperatureC: Double
    var code: Int
    var isDay: Bool

    var temperatureDisplay: String {
        let usesFahrenheit = Locale.current.measurementSystem == .us
        let value = usesFahrenheit ? temperatureC * 9 / 5 + 32 : temperatureC
        return "\(Int(value.rounded()))°"
    }

    /// WMO weather interpretation codes, as returned by Open-Meteo.
    var summary: String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Hailstorm"
        default: return "—"
        }
    }

    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "thermometer.medium"
        }
    }
}

/// Location plus weather for the home header.
///
/// Weather comes from Open-Meteo, which needs no key and no account. Location
/// is only requested when the user has left it enabled in Settings, and the
/// result is cached so a relaunch doesn't re-geocode.
@MainActor
@Observable
final class PlaceService: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceService()

    private(set) var placeName: String?
    private(set) var weather: WeatherSnapshot?
    private(set) var authorizationDenied = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastFetch: Date?
    private var isResolving = false

    /// Weather is refreshed at most every 15 minutes; conditions don't change
    /// faster than that in any way the header would show.
    private let refreshInterval: TimeInterval = 15 * 60

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        // City-level display doesn't need precision, and a coarse fix is faster
        // and cheaper on battery.
        manager.distanceFilter = 2000

        restoreCache()
    }

    // MARK: - Public entry point

    func refreshIfNeeded() {
        guard AppSettings.shared.useLocation else {
            placeName = nil
            weather = nil
            return
        }

        if let lastFetch, Date.now.timeIntervalSince(lastFetch) < refreshInterval, weather != nil {
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationDenied = false
            manager.requestLocation()
        case .denied, .restricted:
            authorizationDenied = true
        @unknown default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                self.authorizationDenied = false
                manager.requestLocation()
            case .denied, .restricted:
                self.authorizationDenied = true
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            await self.resolve(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isResolving = false
        }
    }

    // MARK: - Resolution

    private func resolve(_ location: CLLocation) async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }

        async let name = reverseGeocode(location)
        async let conditions = fetchWeather(for: location.coordinate)

        if let resolved = await name {
            placeName = resolved
        }
        if let conditions = await conditions {
            weather = conditions
            lastFetch = .now
        }

        persistCache()
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        return placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? placemark.country
    }

    private struct OpenMeteoResponse: Decodable {
        let current: Current

        struct Current: Decodable {
            let temperature2m: Double?
            let weatherCode: Int?
            let isDay: Int?

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case weatherCode = "weather_code"
                case isDay = "is_day"
            }
        }
    }

    private func fetchWeather(for coordinate: CLLocationCoordinate2D) async -> WeatherSnapshot? {
        guard let url = URL.build("https://api.open-meteo.com/v1/forecast", [
            "latitude": String(format: "%.3f", coordinate.latitude),
            "longitude": String(format: "%.3f", coordinate.longitude),
            "current": "temperature_2m,weather_code,is_day",
            "timezone": "auto"
        ]) else { return nil }

        guard let response = try? await HTTPClient.shared.get(url, as: OpenMeteoResponse.self),
              let temperature = response.current.temperature2m
        else { return nil }

        return WeatherSnapshot(
            temperatureC: temperature,
            code: response.current.weatherCode ?? -1,
            isDay: (response.current.isDay ?? 1) == 1
        )
    }

    // MARK: - Cache
    //
    // Showing a slightly stale place and temperature immediately beats an empty
    // header while CoreLocation warms up.

    private enum CacheKeys {
        static let place = "place.name"
        static let temperature = "place.temperature"
        static let code = "place.code"
        static let isDay = "place.is_day"
        static let timestamp = "place.timestamp"
    }

    private func restoreCache() {
        let defaults = UserDefaults.standard
        placeName = defaults.string(forKey: CacheKeys.place)

        guard defaults.object(forKey: CacheKeys.temperature) != nil else { return }
        weather = WeatherSnapshot(
            temperatureC: defaults.double(forKey: CacheKeys.temperature),
            code: defaults.integer(forKey: CacheKeys.code),
            isDay: defaults.bool(forKey: CacheKeys.isDay)
        )
        if let stored = defaults.object(forKey: CacheKeys.timestamp) as? Date {
            lastFetch = stored
        }
    }

    private func persistCache() {
        let defaults = UserDefaults.standard
        defaults.set(placeName, forKey: CacheKeys.place)
        if let weather {
            defaults.set(weather.temperatureC, forKey: CacheKeys.temperature)
            defaults.set(weather.code, forKey: CacheKeys.code)
            defaults.set(weather.isDay, forKey: CacheKeys.isDay)
        }
        defaults.set(lastFetch, forKey: CacheKeys.timestamp)
    }
}
