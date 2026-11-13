import Foundation
import NetworkExtension
import CryptoKit
import Darwin

private let apiBase = URL(string: "https://vpnmirapis.com")!
private let locationsURL = URL(string: "https://vpnmirapis.com/api/v1/locations.json?tier=patron")!
private let providerBundle = "com.vpnmir.app.mac-standalone.tunnel-system"
private let profileName = "VPN MIR"
private let profileKey = Data("QAM1Ta94n2WSgZAN9KoW67objsv19lzs".utf8)
private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser
private let cacheDir = home.appendingPathComponent("Library/Caches/vpnmir-cli", isDirectory: true)
private let dataDir = home.appendingPathComponent("Library/Application Support/vpnmir-cli", isDirectory: true)
private let cacheFile = cacheDir.appendingPathComponent("locations.json")
private let stateFile = dataDir.appendingPathComponent("state.json")
private let sessionFile = dataDir.appendingPathComponent("session.json")
private let settingsFile = dataDir.appendingPathComponent("settings.json")
private let watchdogFile = dataDir.appendingPathComponent("watchdog.json")
private let watchdogLog = dataDir.appendingPathComponent("autorenew.log")
private let appPreferences = home.appendingPathComponent("Library/Preferences/com.vpnmir.app.mac-standalone.plist")
private let defaultRenewSeconds: TimeInterval = 59 * 60

struct Server: Codable {
    let id: Int
    let hash: String?
    let iv: String?
    let tag: String?
    let ip: String?
    let load: Int?
    let isOnline: Bool?
    let isPatronOnly: Bool?
    enum CodingKeys: String, CodingKey {
        case id, hash, iv, tag, ip, load
        case isOnline = "is_online"
        case isPatronOnly = "is_patron_only"
    }
}

struct Location: Codable {
    let id: Int
    let code: String
    let name: String
    let cityName: String
    let servers: [Server]
    enum CodingKeys: String, CodingKey {
        case id, code, name, servers
        case cityName = "city_name"
    }
}

struct SavedState: Codable {
    let locationID: Int
    let code: String
    let name: String
    let city: String
    let serverID: Int
    let connectedAt: Date
}

struct Session: Codable { let token: String }
struct RenewSettings: Codable { var enabled: Bool; var intervalSeconds: Double }
struct WatchdogInfo: Codable { let pid: Int32; let startedAt: Date }

struct AccountInfo: Decodable {
    let accountNumber: String
    let hasActiveAccess: Bool
    let hasUnlimitedTimeAccess: Bool
    let hasSecretServersAccess: Bool
    let hasExtraLocationsAccess: Bool
    let paidUntil: Double?
    enum CodingKeys: String, CodingKey {
        case accountNumber = "account_number"
        case hasActiveAccess = "has_active_access"
        case hasUnlimitedTimeAccess = "has_unlimited_time_access"
        case hasSecretServersAccess = "has_secret_servers_access"
        case hasExtraLocationsAccess = "has_extra_locations_access"
        case paidUntil = "paid_until"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountNumber = try values.decode(String.self, forKey: .accountNumber)
        hasActiveAccess = try values.decode(Bool.self, forKey: .hasActiveAccess)
        hasUnlimitedTimeAccess = try values.decode(Bool.self, forKey: .hasUnlimitedTimeAccess)
        hasSecretServersAccess = try values.decode(Bool.self, forKey: .hasSecretServersAccess)
        hasExtraLocationsAccess = try values.decode(Bool.self, forKey: .hasExtraLocationsAccess)
        if let number = try? values.decode(Double.self, forKey: .paidUntil) { paidUntil = number }
        else if let text = try? values.decode(String.self, forKey: .paidUntil) {
            if let number = Double(text) { paidUntil = number }
            else if let date = ISO8601DateFormatter().date(from: text) { paidUntil = date.timeIntervalSinceReferenceDate }
            else { paidUntil = nil }
        } else { paidUntil = nil }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "Ошибка" }
}

func secureWrite(_ data: Data, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
    let temp = url.deletingLastPathComponent().appendingPathComponent(".vpnmir-\(UUID().uuidString)")
    try data.write(to: temp, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    try fm.moveItem(at: temp, to: url)
}

func requestData(_ request: URLRequest) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { result = .failure(error) }
        else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            result = .failure(CLIError.message("API VPN MIR вернул HTTP \(http.statusCode)."))
        } else if let data { result = .success(data) }
        else { result = .failure(CLIError.message("API VPN MIR вернул пустой ответ.")) }
        semaphore.signal()
    }.resume()
    if semaphore.wait(timeout: .now() + 25) == .timedOut { throw CLIError.message("API VPN MIR не ответил вовремя.") }
    return try result!.get()
}

func cachedAccount() throws -> AccountInfo {
    let plistData = try Data(contentsOf: appPreferences)
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
          let raw = plist["CachedCurrentUser"] else {
        throw CLIError.message("Сохранённый аккаунт VPN MIR не найден. Один раз войдите через приложение VPN MIR.")
    }
    let data: Data
    if let value = raw as? Data { data = value }
    else if let value = raw as? String, let converted = value.data(using: .utf8) { data = converted }
    else { throw CLIError.message("Неизвестный формат данных аккаунта VPN MIR.") }
    return try JSONDecoder().decode(AccountInfo.self, from: data)
}

func savedSession() -> Session? {
    guard let data = try? Data(contentsOf: sessionFile) else { return nil }
    return try? JSONDecoder().decode(Session.self, from: data)
}

func loginToken(force: Bool = false) throws -> String {
    if !force, let session = savedSession(), !session.token.isEmpty { return session.token }
    let account = try cachedAccount()
    var request = URLRequest(url: apiBase.appendingPathComponent("api/v1/login"))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("vpnmir-cli/2.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["account_number": account.accountNumber])
    let data = try requestData(request)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = object["token"] as? String, !token.isEmpty else { throw CLIError.message("API не вернул токен активации.") }
    try secureWrite(try JSONEncoder().encode(Session(token: token)), to: sessionFile)
    return token
}

func refreshedAccount() throws -> AccountInfo {
    var request = URLRequest(url: apiBase.appendingPathComponent("api/v1/current_user.json"))
    request.timeoutInterval = 20
    request.setValue("Bearer \(try loginToken())", forHTTPHeaderField: "Authorization")
    request.setValue("vpnmir-cli/2.0", forHTTPHeaderField: "User-Agent")
    return try JSONDecoder().decode(AccountInfo.self, from: requestData(request))
}

func masked(_ value: String) -> String {
    guard value.count > 8 else { return String(repeating: "•", count: value.count) }
    return String(value.prefix(4)) + String(repeating: "•", count: max(4, value.count - 8)) + String(value.suffix(4))
}

func printAccount(_ account: AccountInfo, source: String) {
    print("Активация: \(account.hasActiveAccess ? "активна" : "неактивна")")
    print("Безлимитное время: \(account.hasUnlimitedTimeAccess ? "да" : "нет")")
    print("Секретные серверы ⚡: \(account.hasSecretServersAccess ? "доступны" : "недоступны")")
    print("Дополнительные локации: \(account.hasExtraLocationsAccess ? "доступны" : "недоступны")")
    if let paidUntil = account.paidUntil {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "dd.MM.yyyy HH:mm"
        print("Оплачено до: \(formatter.string(from: Date(timeIntervalSinceReferenceDate: paidUntil)))")
    }
    print("Аккаунт: \(masked(account.accountNumber))")
    print("Источник: \(source)")
}

func fetchLocations() throws -> [Location] {
    var request = URLRequest(url: locationsURL)
    request.timeoutInterval = 20
    request.setValue("vpnmir-cli/2.0", forHTTPHeaderField: "User-Agent")
    do {
        let data = try requestData(request)
        let rows = try JSONDecoder().decode([Location].self, from: data)
        try secureWrite(data, to: cacheFile)
        return rows
    } catch {
        if let cached = try? Data(contentsOf: cacheFile), let rows = try? JSONDecoder().decode([Location].self, from: cached) {
            fputs("Предупреждение: сеть недоступна, используется локальный кеш.\n", stderr)
            return rows
        }
        throw error
    }
}

func loadLocations() throws -> [Location] {
    if let data = try? Data(contentsOf: cacheFile),
       let attrs = try? fm.attributesOfItem(atPath: cacheFile.path),
       let changed = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(changed) < 6 * 3600,
       let rows = try? JSONDecoder().decode([Location].self, from: data) { return rows }
    return try fetchLocations()
}

func loadManager() throws -> NETunnelProviderManager {
    var managers: [NETunnelProviderManager]?; var loadError: Error?; var finished = false
    NETunnelProviderManager.loadAllFromPreferences { value, error in managers = value; loadError = error; finished = true }
    let deadline = Date().addingTimeInterval(10)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if !finished { throw CLIError.message("Не удалось прочитать системный профиль VPN MIR.") }
    if let loadError { throw loadError }
    guard let manager = managers?.first(where: {
        $0.localizedDescription == profileName || ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundle
    }) else { throw CLIError.message("Системный профиль VPN MIR не найден. Один раз запустите приложение и разрешите VPN-расширение.") }
    return manager
}

func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid: return "недоступен"; case .disconnected: return "отключён"; case .connecting: return "подключается"
    case .connected: return "подключён"; case .reasserting: return "переподключается"; case .disconnecting: return "отключается"
    @unknown default: return "неизвестно"
    }
}

func waitForStatus(_ connection: NEVPNConnection, accepted: Set<NEVPNStatus>, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if accepted.contains(connection.status) { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return accepted.contains(connection.status)
}

func waitForConnected(_ connection: NEVPNConnection, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if connection.status == .connected { return true }
        if connection.status == .invalid { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return connection.status == .connected
}

func findLocation(_ rows: [Location], query: String) throws -> Location {
    let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let exact = rows.filter { String($0.id) == query || $0.code.caseInsensitiveCompare(query) == .orderedSame }
    let matches = exact.isEmpty ? rows.filter {
        "\($0.name) \($0.cityName)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(folded)
    } : exact
    guard matches.count == 1, let match = matches.first else {
        if matches.isEmpty { throw CLIError.message("Локация «\(query)» не найдена. Выполните: vpnmir l") }
        throw CLIError.message("Найдено несколько локаций. Укажите ID из списка.")
    }
    return match
}

func chooseServer(_ location: Location, requested: Int?, includeOffline: Bool) throws -> Server {
    var servers = location.servers.filter { $0.hash != nil && $0.iv != nil && $0.tag != nil }
    if let requested { servers = servers.filter { $0.id == requested } }
    if !includeOffline {
        let online = servers.filter { $0.isOnline != false }
        if !online.isEmpty { servers = online }
        else if !servers.isEmpty { fputs("Предупреждение: API помечает серверы как offline; пробую наименее загруженный.\n", stderr) }
    }
    guard let server = servers.sorted(by: {
        if ($0.isOnline != false) != ($1.isOnline != false) { return $0.isOnline != false }
        return ($0.load ?? Int.max) < ($1.load ?? Int.max)
    }).first else { throw CLIError.message("Подходящий сервер не найден. Добавьте --try-offline.") }
    return server
}

func decryptConfig(_ server: Server) throws -> String {
    guard let hash = server.hash.flatMap({ Data(base64Encoded: $0) }),
          let iv = server.iv.flatMap({ Data(base64Encoded: $0) }),
          let tag = server.tag.flatMap({ Data(base64Encoded: $0) }) else { throw CLIError.message("Профиль сервера повреждён.") }
    do {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: hash, tag: tag)
        let opened = try AES.GCM.open(box, using: SymmetricKey(data: profileKey))
        guard let object = try JSONSerialization.jsonObject(with: opened) as? [String: Any], object["outbounds"] != nil else {
            throw CLIError.message("В профиле отсутствует конфигурация VPN.")
        }
        return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    } catch let error as CLIError { throw error }
    catch { throw CLIError.message("Не удалось расшифровать профиль сервера: формат API изменился.") }
}

func savedState() -> SavedState? {
    guard let data = try? Data(contentsOf: stateFile) else { return nil }
    return try? JSONDecoder().decode(SavedState.self, from: data)
}

func saveState(location: Location, server: Server) throws {
    let value = SavedState(locationID: location.id, code: location.code, name: location.name,
                           city: location.cityName, serverID: server.id, connectedAt: Date())
    try secureWrite(try JSONEncoder().encode(value), to: stateFile)
}

func renewSettings() -> RenewSettings {
    guard let data = try? Data(contentsOf: settingsFile), let value = try? JSONDecoder().decode(RenewSettings.self, from: data) else {
        return RenewSettings(enabled: true, intervalSeconds: defaultRenewSeconds)
    }
    return RenewSettings(enabled: value.enabled, intervalSeconds: max(60, value.intervalSeconds))
}

func saveRenewSettings(_ value: RenewSettings) throws { try secureWrite(try JSONEncoder().encode(value), to: settingsFile) }
func watchdogInfo() -> WatchdogInfo? {
    guard let data = try? Data(contentsOf: watchdogFile) else { return nil }
    return try? JSONDecoder().decode(WatchdogInfo.self, from: data)
}
func processAlive(_ pid: Int32) -> Bool { pid > 1 && (Darwin.kill(pid, 0) == 0 || errno == EPERM) }

func stopWatchdog() {
    if let info = watchdogInfo(), processAlive(info.pid) {
        _ = Darwin.kill(info.pid, SIGTERM)
        for _ in 0..<20 where processAlive(info.pid) { usleep(50_000) }
    }
    try? fm.removeItem(at: watchdogFile)
}

func startWatchdog() throws {
    stopWatchdog()
    try fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if !fm.fileExists(atPath: watchdogLog.path) { fm.createFile(atPath: watchdogLog.path, contents: nil) }
    let log = try FileHandle(forWritingTo: watchdogLog); try log.seekToEnd()
    guard let executable = Bundle.main.executableURL else { throw CLIError.message("Не удалось определить путь к vpnmir.") }
    let process = Process(); process.executableURL = executable; process.arguments = ["__watchdog"]
    process.standardOutput = log; process.standardError = log
    try process.run()
    try secureWrite(try JSONEncoder().encode(WatchdogInfo(pid: process.processIdentifier, startedAt: Date())), to: watchdogFile)
}

func connect(location: Location, server: Server, manageWatchdog: Bool) throws {
    let manager = try loadManager()
    if ![NEVPNStatus.disconnected, .invalid].contains(manager.connection.status) {
        manager.connection.stopVPNTunnel()
        guard waitForStatus(manager.connection, accepted: [.disconnected, .invalid], timeout: 12) else {
            throw CLIError.message("Не удалось остановить предыдущее подключение.")
        }
    }
    try manager.connection.startVPNTunnel(options: ["config": try decryptConfig(server) as NSString])
    guard waitForConnected(manager.connection, timeout: 25) else {
        throw CLIError.message("Системное расширение не подключилось; состояние: \(statusName(manager.connection.status)).")
    }
    try saveState(location: location, server: server)
    if manageWatchdog {
        if renewSettings().enabled { try startWatchdog() } else { stopWatchdog() }
    }
    print("Подключено: \(location.name) / \(location.cityName), сервер \(server.id)\(server.isPatronOnly == true ? " ⚡" : "")")
}

func connectSaved(manageWatchdog: Bool) throws {
    guard let previous = savedState() else { throw CLIError.message("Последнее подключение не сохранено. Сначала выполните: vpnmir c <код>") }
    let location = try findLocation(loadLocations(), query: String(previous.locationID))
    let server = try chooseServer(location, requested: previous.serverID, includeOffline: true)
    try connect(location: location, server: server, manageWatchdog: manageWatchdog)
}

func runWatchdog() -> Never {
    while true {
        let settings = renewSettings()
        if !settings.enabled { exit(0) }
        guard let state = savedState() else { Thread.sleep(forTimeInterval: 10); continue }
        let remaining = state.connectedAt.addingTimeInterval(settings.intervalSeconds).timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: min(30, max(1, remaining))); continue }
        do { try connectSaved(manageWatchdog: false) }
        catch {
            fputs("[\(Date())] Ошибка autorenew: \(error)\n", stderr)
            Thread.sleep(forTimeInterval: 60)
        }
    }
}

func renewStatus() {
    let settings = renewSettings(); let info = watchdogInfo(); let running = info.map { processAlive($0.pid) } ?? false
    print("Autorenew: \(settings.enabled ? "включён" : "выключен")")
    print("Интервал: \(Int(settings.intervalSeconds / 60)) мин.")
    print("Watchdog: \(running ? "работает" : "не запущен")")
    if settings.enabled, running, let state = savedState() {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        print("Следующее обновление: \(formatter.string(from: state.connectedAt.addingTimeInterval(settings.intervalSeconds)))")
    }
}

func usage() {
    print("""
    VPN MIR CLI 2.0 для macOS

      vpnmir c|connect [локация] [--server ID] [--try-offline]
      vpnmir d|disconnect
      vpnmir s|status
      vpnmir l|locations [--refresh]
      vpnmir v|servers <локация>
      vpnmir a|activation [--refresh]
      vpnmir t|token [--refresh]
      vpnmir r|autorenew [MINUTES]|on|off|status
      vpnmir h|help

    Autorenew включён по умолчанию и обновляет соединение каждые 59 минут.
    """)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { usage(); exit(0) }
    switch command {
    case "help", "--help", "-h", "h": usage()
    case "locations", "list", "l":
        let rows = args.contains("--refresh") ? try fetchLocations() : try loadLocations()
        for row in rows.sorted(by: { $0.id < $1.id }) {
            let online = row.servers.filter { $0.isOnline != false }.count
            let secret = row.servers.contains { $0.isPatronOnly == true } ? "⚡" : " "
            print(String(format: "%3d  %-3@ %@ %@ / %@  %d/%d online", row.id, row.code as NSString, secret,
                         row.name, row.cityName, online, row.servers.count))
        }
        print("⚡ — секретные серверы, доступные по подписке")
    case "servers", "v":
        guard args.count >= 2 else { throw CLIError.message("Укажите код, ID или название локации.") }
        let location = try findLocation(loadLocations(), query: args[1]); print("\(location.name) / \(location.cityName):")
        for server in location.servers.sorted(by: { $0.id < $1.id }) {
            print(String(format: "  %5d  %@ %-8@  load=%d", server.id,
                         server.isPatronOnly == true ? "⚡" : " ",
                         (server.isOnline == false ? "offline*" : "online") as NSString, server.load ?? -1))
        }
    case "status", "s":
        let manager = try loadManager(); print("VPN MIR: \(statusName(manager.connection.status))")
        if let state = savedState() { print("Выбрано: \(state.name) / \(state.city), сервер \(state.serverID)") }
        renewStatus()
    case "activation", "account", "a":
        let refresh = args.contains("--refresh")
        printAccount(refresh ? try refreshedAccount() : try cachedAccount(), source: refresh ? "API VPN MIR" : "локальный кеш приложения")
    case "token", "t": print(try loginToken(force: args.contains("--refresh")))
    case "autorenew", "renew", "r":
        let action = args.count > 1 ? args[1] : "status"
        if let minutes = Int(action) {
            guard (1...10_080).contains(minutes) else { throw CLIError.message("Интервал должен быть от 1 до 10080 минут.") }
            var settings = renewSettings(); settings.enabled = true; settings.intervalSeconds = Double(minutes * 60)
            try saveRenewSettings(settings)
            if (try? loadManager().connection.status) == .connected { try startWatchdog() }
            print("Autorenew включён: переподключение каждые \(minutes) мин.")
            break
        }
        switch action {
        case "on", "enable":
            var settings = renewSettings(); settings.enabled = true
            try saveRenewSettings(settings)
            if (try? loadManager().connection.status) == .connected { try startWatchdog() }
            print("Autorenew включён: переподключение каждые \(Int(settings.intervalSeconds / 60)) мин.")
        case "off", "disable":
            var settings = renewSettings(); settings.enabled = false; try saveRenewSettings(settings); stopWatchdog()
            print("Autorenew выключен.")
        case "status", "s": renewStatus()
        default: throw CLIError.message("Использование: vpnmir r [MINUTES]|on|off|status")
        }
    case "disconnect", "stop", "d":
        stopWatchdog(); let manager = try loadManager(); manager.connection.stopVPNTunnel()
        guard waitForStatus(manager.connection, accepted: [.disconnected, .invalid], timeout: 12) else {
            throw CLIError.message("VPN не успел отключиться: \(statusName(manager.connection.status)).")
        }
        print("VPN MIR отключён.")
    case "connect", "start", "c":
        let positional = args.dropFirst().first { !$0.hasPrefix("--") }
        if positional == nil { try connectSaved(manageWatchdog: true); break }
        var serverID: Int?
        if let index = args.firstIndex(of: "--server") {
            guard index + 1 < args.count, let value = Int(args[index + 1]) else { throw CLIError.message("После --server нужен числовой ID.") }
            serverID = value
        }
        let location = try findLocation(loadLocations(), query: positional!)
        let server = try chooseServer(location, requested: serverID, includeOffline: args.contains("--try-offline"))
        try connect(location: location, server: server, manageWatchdog: true)
    case "__watchdog": runWatchdog()
    default: throw CLIError.message("Неизвестная команда «\(command)». Выполните: vpnmir h")
    }
} catch {
    fputs("Ошибка: \(error)\n", stderr)
    exit(1)
}
