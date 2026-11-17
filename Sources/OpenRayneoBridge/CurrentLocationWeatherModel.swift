// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import CoreLocation
import Foundation

@MainActor
final class CurrentLocationWeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot: HomeWeatherSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var notice = "按需获取 Mac 当前位置，更新眼镜的当前位置天气。"
    @Published var automatic = false {
        didSet {
            defaults.set(automatic, forKey: "currentLocationWeatherAutomatic")
            if automatic { requestAutomaticUpdate(force: true) }
            else {
                pendingAutomaticUpdate = false
                if operationIsAutomatic { cancel() }
            }
        }
    }

    private weak var bridge: DesktopBridge?
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let service = HomeWeatherService()
    private let defaults = UserDefaults.standard
    private var subscriptions = Set<AnyCancellable>()
    private var operation: Task<Void, Never>?
    private var operationIsAutomatic = false
    private var pendingManualAuthorization = false
    private var pendingAutomaticUpdate = false
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var locationTimeout: Task<Void, Never>?
    private var lastAttempt: Date?
    private let cacheURL: URL

    init(bridge: DesktopBridge) {
        self.bridge = bridge
        cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/CurrentLocationWeather/current.json")
        super.init()
        if let data = try? Data(contentsOf: cacheURL) {
            snapshot = try? JSONDecoder().decode(HomeWeatherSnapshot.self, from: data)
        }
        automatic = defaults.bool(forKey: "currentLocationWeatherAutomatic")
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorization = manager.authorizationStatus
        bridge.$connected.removeDuplicates().dropFirst().sink { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                if connected { self?.requestAutomaticUpdate(force: true) }
                else { self?.cancel() }
            }
        }.store(in: &subscriptions)
        bridge.$selectedAddress.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel()
                self?.requestAutomaticUpdate(force: true)
            }
        }.store(in: &subscriptions)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestAutomaticUpdate() }
        }.store(in: &subscriptions)
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.requestAutomaticUpdate() }
            }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestAutomaticUpdate() }
        }.store(in: &subscriptions)
        requestAutomaticUpdate()
    }

    var connected: Bool { bridge?.connected == true }
    var authorized: Bool { authorization == .authorizedAlways }
    var authorizationDescription: String {
        switch authorization {
        case .notDetermined: return "尚未授权定位；点击定位按钮后才会请求权限。"
        case .restricted: return "定位受系统限制。"
        case .denied: return "定位未获允许，请在系统设置的定位服务中允许 OpenRayneo。"
        case .authorizedAlways: return "已允许定位，仅在更新天气时获取一次位置。"
        @unknown default: return "定位权限状态未知。"
        }
    }

    // This button action is the only path that can request location authorization.
    func updateNow() {
        guard !busy else { return }
        authorization = manager.authorizationStatus
        if authorization == .notDetermined {
            pendingManualAuthorization = true
            notice = "请在系统提示中允许定位。"
            manager.requestWhenInUseAuthorization()
            return
        }
        guard authorized else { notice = authorizationDescription; return }
        startUpdate(automatically: false)
    }

    func cancel() {
        pendingManualAuthorization = false
        operation?.cancel()
        geocoder.cancelGeocode()
        finishLocation(.failure(CancellationError()))
    }

    private func requestAutomaticUpdate(force: Bool = false) {
        authorization = manager.authorizationStatus
        guard automatic, authorized, connected else { return }
        guard force || lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) >= 30 * 60 else { return }
        if busy {
            if force { pendingAutomaticUpdate = true }
            return
        }
        startUpdate(automatically: true)
    }

    private func startUpdate(automatically: Bool) {
        guard !busy else { return }
        busy = true
        operationIsAutomatic = automatically
        lastAttempt = Date()
        let expectedAddress = connected ? bridge?.selectedAddress : nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                busy = false
                operation = nil
                operationIsAutomatic = false
                if pendingAutomaticUpdate {
                    pendingAutomaticUpdate = false
                    requestAutomaticUpdate(force: true)
                }
            }
            do {
                notice = "正在获取当前位置…"
                let location = try await locateOnce()
                try Task.checkCancellation()
                let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")).first
                try Task.checkCancellation()
                let city = HomeCity(id: 0, name: placemark?.locality ?? placemark?.subAdministrativeArea ?? "当前位置",
                    latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                    timezone: placemark?.timeZone?.identifier ?? TimeZone.current.identifier,
                    country: placemark?.country, admin1: placemark?.administrativeArea)
                notice = "正在获取\(city.name)天气…"
                let forecast = try await service.forecast(city)
                try Task.checkCancellation()
                snapshot = forecast
                var cacheNotice = ""
                do {
                    try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(forecast).write(to: cacheURL, options: .atomic)
                } catch { cacheNotice = "；本地缓存保存失败：\(error.localizedDescription)" }
                guard let expectedAddress, let bridge, bridge.connected, bridge.selectedAddress == expectedAddress else {
                    notice = "天气已更新到 Mac；连接眼镜后可再次更新。" + cacheNotice
                    return
                }
                notice = "正在发送当前位置天气…"
                let response = try await bridge.request("/v1/weather/current", body: [
                    "location": forecast.city.name, "temp": Int(forecast.temperature.rounded()),
                    "icon": HomeWeatherCodes.glassesIcon(forecast.code, isDay: forecast.isDay)
                ])
                try Task.checkCancellation()
                notice = (response["acknowledged"] as? Bool == true
                    ? "眼镜已确认收到当前位置天气；请在眼镜端查看显示。"
                    : "当前位置天气已发送，尚未收到眼镜确认。") + cacheNotice
            } catch is CancellationError {
                notice = "已取消天气更新。"
            } catch {
                notice = "当前位置天气更新失败：\(error.localizedDescription)"
            }
        }
    }

    private func locateOnce() async throws -> CLLocation {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                locationContinuation = continuation
                locationTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    self?.finishLocation(.failure(HomeContentFailure("定位超时，请确认 Mac 定位服务可用后重试。")))
                }
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishLocation(.failure(CancellationError())) }
        }
    }

    private func finishLocation(_ result: Result<CLLocation, Error>) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        locationTimeout?.cancel()
        locationTimeout = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 120 }) else { return }
            self?.finishLocation(.success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.finishLocation(.failure(error)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            authorization = status
            if pendingManualAuthorization, status != .notDetermined {
                pendingManualAuthorization = false
                if authorized { startUpdate(automatically: false) }
                else { notice = authorizationDescription }
            } else if authorized { requestAutomaticUpdate() }
            else if status != .notDetermined { cancel() }
        }
    }
}
