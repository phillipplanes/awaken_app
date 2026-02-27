import Foundation
import Combine
import CoreLocation

@MainActor
final class AlarmWeatherViewModel: NSObject, ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isAvailable = false
    @Published private(set) var forecastText = "Forecast unavailable"
    @Published private(set) var detailText = "Allow location to see weather at alarm time."
    @Published private(set) var symbolName = "cloud.sun"

    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var pendingAlarmTime: Date?
    private var refreshTask: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func scheduleRefresh(for alarmTime: Date) {
        pendingAlarmTime = alarmTime
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.refreshNow(for: alarmTime)
        }
    }

    func refreshNow(for alarmTime: Date) async {
        pendingAlarmTime = alarmTime

        switch locationManager.authorizationStatus {
        case .notDetermined:
            isLoading = true
            locationManager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            setUnavailable(
                forecast: "Forecast unavailable",
                detail: "Allow location access in Settings to show alarm weather.",
                symbol: "location.slash"
            )
        case .authorizedAlways, .authorizedWhenInUse:
            if let location = currentLocation ?? locationManager.location {
                await fetchForecast(for: alarmTime, location: location)
            } else {
                isLoading = true
                locationManager.requestLocation()
            }
        @unknown default:
            setUnavailable(
                forecast: "Forecast unavailable",
                detail: "Location permission state is unknown.",
                symbol: "questionmark.circle"
            )
        }
    }

    private func fetchForecast(for alarmTime: Date, location: CLLocation) async {
        isLoading = true

        let targetDate = nextAlarmDate(matching: alarmTime)
        let targetUnix = Int(targetDate.timeIntervalSince1970)

        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            setUnavailable(
                forecast: "Forecast unavailable",
                detail: "Could not build weather request.",
                symbol: "exclamationmark.triangle"
            )
            return
        }

        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]

        guard let url = components.url else {
            setUnavailable(
                forecast: "Forecast unavailable",
                detail: "Could not build weather request URL.",
                symbol: "exclamationmark.triangle"
            )
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                setUnavailable(
                    forecast: "Forecast unavailable",
                    detail: "Weather service returned an unexpected response.",
                    symbol: "exclamationmark.triangle"
                )
                return
            }

            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            guard let hourly = closestHour(to: targetUnix, in: decoded.hourly) else {
                setUnavailable(
                    forecast: "Forecast unavailable",
                    detail: "Hourly forecast data is unavailable.",
                    symbol: "cloud"
                )
                return
            }

            let tempF = Int(hourly.temperatureF.rounded())
            let precipPercent = Int(hourly.precipitationProbability.rounded())
            let condition = conditionText(for: hourly.weatherCode)
            let icon = symbolName(for: hourly.weatherCode)
            let timeString = alarmTimeString(for: targetDate)

            forecastText = "\(timeString): \(tempF)°F, \(condition)"
            detailText = "Precipitation chance: \(precipPercent)%"
            symbolName = icon
            isAvailable = true
            isLoading = false
        } catch {
            setUnavailable(
                forecast: "Forecast unavailable",
                detail: "Could not load weather data right now.",
                symbol: "exclamationmark.triangle"
            )
        }
    }

    private func closestHour(to targetUnix: Int, in hourly: OpenMeteoHourly) -> OpenMeteoHour? {
        guard !hourly.time.isEmpty else { return nil }

        var bestIndex: Int?
        var bestDistance = Int.max

        for (index, timeUnix) in hourly.time.enumerated() {
            let distance = abs(timeUnix - targetUnix)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        guard
            let index = bestIndex,
            index < hourly.temperature2m.count,
            index < hourly.precipitationProbability.count,
            index < hourly.weatherCode.count
        else {
            return nil
        }

        return OpenMeteoHour(
            temperatureF: hourly.temperature2m[index],
            precipitationProbability: hourly.precipitationProbability[index],
            weatherCode: hourly.weatherCode[index]
        )
    }

    private func setUnavailable(forecast: String, detail: String, symbol: String) {
        forecastText = forecast
        detailText = detail
        symbolName = symbol
        isAvailable = false
        isLoading = false
    }

    private func nextAlarmDate(matching timeOnlyDate: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.hour, .minute], from: timeOnlyDate)
        let now = Date()

        components.year = calendar.component(.year, from: now)
        components.month = calendar.component(.month, from: now)
        components.day = calendar.component(.day, from: now)

        let todayAlarm = calendar.date(from: components) ?? now
        if todayAlarm > now {
            return todayAlarm
        }

        return calendar.date(byAdding: .day, value: 1, to: todayAlarm) ?? todayAlarm
    }

    private func alarmTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }

    private func conditionText(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 95, 96, 99: return "Thunderstorms"
        default: return "Unsettled"
        }
    }

    private func symbolName(for code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55, 56, 57: return "cloud.drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}

extension AlarmWeatherViewModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard let pendingAlarmTime else { return }
            await refreshNow(for: pendingAlarmTime)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else {
                setUnavailable(
                    forecast: "Forecast unavailable",
                    detail: "Could not get your location.",
                    symbol: "location.slash"
                )
                return
            }

            currentLocation = location

            guard let pendingAlarmTime else { return }
            await fetchForecast(for: pendingAlarmTime, location: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            setUnavailable(
                forecast: "Forecast unavailable",
                detail: "Location request failed.",
                symbol: "location.slash"
            )
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    let hourly: OpenMeteoHourly
}

private struct OpenMeteoHourly: Decodable {
    let time: [Int]
    let temperature2m: [Double]
    let precipitationProbability: [Double]
    let weatherCode: [Int]

    enum CodingKeys: String, CodingKey {
        case time
        case temperature2m = "temperature_2m"
        case precipitationProbability = "precipitation_probability"
        case weatherCode = "weather_code"
    }
}

private struct OpenMeteoHour {
    let temperatureF: Double
    let precipitationProbability: Double
    let weatherCode: Int
}
