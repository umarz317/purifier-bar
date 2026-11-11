import ServiceManagement
import SwiftUI

@main
struct PurifierBarApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            Panel(store: store)
        } label: {
            // Keep the same views at all times; MenuBarExtra labels don't pick up views added later.
            HStack(spacing: 4) {
                Image(systemName: store.offline ? "wifi.slash" : "aqi.medium")
                Text(store.offline ? "–" : store.state.map { "\($0.pm25)" } ?? "–")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

enum Login {
    case idle, loading, searching, manual
    case qr(NSImage)
    case pick([CloudDevice])
}

@MainActor @Observable
final class Store {
    var host = UserDefaults.standard.string(forKey: "host") ?? ""
    var token = UserDefaults.standard.string(forKey: "token") ?? ""
    var name = UserDefaults.standard.string(forKey: "name") ?? ""
    var state: PurifierState?
    var error: String?
    var offline = false
    var retrying = false
    var lastSeen: Date?
    var setup = false
    var login = Login.idle
    private var client: MiIO?
    private var loginTask: Task<Void, Never>?

    var connected: Bool { client != nil }

    init() {
        client = try? MiIO(host: host, token: token)
        setup = client == nil
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(offline ? 10 : 30))
            }
        }
    }

    func signIn() {
        loginTask?.cancel()
        error = nil
        loginTask = Task {
            do {
                login = .loading
                let cloud = XiaomiCloud()
                let qr = try await cloud.startLogin()
                login = .qr(qr.image)
                try await cloud.waitForScan(qr)
                login = .searching
                let devices = try await cloud.purifiers()
                switch devices.count {
                case 0: throw CloudError.failed("No 4 Compact or 4 Lite in this Mi Home account")
                case 1: use(devices[0])
                default: login = .pick(devices)
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                login = .idle
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        login = .idle
        error = nil
    }

    func use(_ device: CloudDevice) {
        guard !device.ip.isEmpty else {
            error = "\(device.name) is offline"
            login = .idle
            return
        }
        host = device.ip
        token = device.token
        name = device.name
        connect()
    }

    func connect() {
        do {
            client = try MiIO(host: host, token: token)
            for (key, value) in ["host": host, "token": token, "name": name] {
                UserDefaults.standard.set(value, forKey: key)
            }
            state = nil
            error = nil
            setup = false
            login = .idle
            Task { await refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            state = try await Task.detached { try client.readState() }.value
            error = nil
            offline = false
            lastSeen = Date()
            if UserDefaults.standard.object(forKey: "did") == nil, client.id != 0 {
                UserDefaults.standard.set(Int(client.id), forKey: "did")
            }
            // The custom Mi Home name only comes from cloud sign-in; otherwise name it by model.
            if name.isEmpty, let model = try? await Task.detached(operation: { try client.model() }).value {
                name = MiIO.productName(model)
                UserDefaults.standard.set(name, forKey: "name")
            }
        } catch MiIOError.timeout {
            offline = true
            error = nil
            await rediscover()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The router may hand the purifier a new IP after it reconnects. Find it again by device ID
    /// (or, before the ID is known, by which device accepts our token).
    private func rediscover() async {
        let token = token, did = UserDefaults.standard.object(forKey: "did") as? Int
        let match = await Task.detached { () -> (ip: String, client: MiIO, state: PurifierState)? in
            for device in MiIO.discover() where did == nil || Int(device.did) == did {
                guard let candidate = try? MiIO(host: device.ip, token: token),
                      let state = try? candidate.readState() else { continue }
                return (device.ip, candidate, state)
            }
            return nil
        }.value
        guard let match else { return }
        host = match.ip
        UserDefaults.standard.set(host, forKey: "host")
        client = match.client
        state = match.state
        offline = false
        lastSeen = Date()
    }

    func retry() async {
        retrying = true
        await refresh()
        retrying = false
    }

    func set(_ prop: Prop, _ value: some Sendable, apply: (inout PurifierState) -> Void) {
        guard let client, var next = state else { return }
        apply(&next)
        state = next  // optimistic; the refresh below corrects it if the purifier disagrees
        Task {
            do {
                try await Task.detached { try client.set(prop, value) }.value
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }
}

// MARK: - Panel

private let brand = Color(cgColor: Logo.bottom)

struct Panel: View {
    @Bindable var store: Store

    var body: some View {
        VStack(spacing: 16) {
            if store.setup {
                SetupView(store: store)
            } else if store.offline {
                OfflineView(store: store)
            } else if let state = store.state {
                Dashboard(store: store, state: state)
            } else if store.error == nil {
                ProgressView().padding(40)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(18)
        .frame(width: 300)
        .tint(brand)
        .task { await store.refresh() }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if store.setup {
                if store.connected {
                    Button("Back", systemImage: "chevron.left") { store.cancelLogin(); store.setup = false }
                }
            } else {
                Button("Settings", systemImage: "gearshape") { store.setup = true }
            }
            Spacer()
            Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        
    }
}

struct Dashboard: View {
    let store: Store
    let state: PurifierState
    @State private var fan = 0.0

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(store.name.isEmpty ? "Air Purifier" : store.name).font(.headline).lineLimit(1)
                Spacer()
                Button { store.set(.power, !state.power) { $0.power.toggle() } } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(state.power ? brand : Color.primary.opacity(0.1)))
                        .foregroundStyle(state.power ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .help(state.power ? "Turn off" : "Turn on")
            }

            AirRing(pm25: state.pm25, active: state.power)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    tile("Auto", "sparkles", on: state.mode == 0) { setMode(0) }
                    tile("Sleep", "moon.fill", on: state.mode == 1) { setMode(1) }
                    tile("Manual", "fan.fill", on: state.mode == 2) { setMode(2) }
                }

                if state.mode == 2 {
                    HStack {
                        Image(systemName: "fan").font(.caption)
                        Slider(value: $fan, in: 0...14, step: 1) { dragging in
                            guard !dragging else { return }
                            let level = Int(fan)
                            store.set(.favoriteLevel, level) { $0.favoriteLevel = level }
                        }
                        Image(systemName: "fan.fill")
                    }
                    .foregroundStyle(.secondary)
                    .onAppear { fan = Double(state.favoriteLevel) }
                    .onChange(of: state.favoriteLevel) { fan = Double($1) }
                }

                HStack(spacing: 8) {
                    tile("Display", ["eye.slash", "sun.min.fill", "sun.max.fill"][min(max(state.brightness, 0), 2)],
                         on: state.brightness > 0) {
                        let next = (state.brightness + 2) % 3  // On → Dim → Off → On
                        store.set(.brightness, next) { $0.brightness = next }
                    }
                    tile("Beep", state.buzzer ? "bell.fill" : "bell.slash", on: state.buzzer) {
                        store.set(.buzzer, !state.buzzer) { $0.buzzer.toggle() }
                    }
                    tile("Lock", state.childLock ? "lock.fill" : "lock.open", on: state.childLock) {
                        store.set(.childLock, !state.childLock) { $0.childLock.toggle() }
                    }
                    FilterTile(life: state.filterLife)
                }
            }
            .disabled(!state.power)
            .opacity(state.power ? 1 : 0.4)
        }
    }

    private func setMode(_ mode: Int) { store.set(.mode, mode) { $0.mode = mode } }

    private func tile(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).frame(height: 18)
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? brand : Color.primary.opacity(0.06)))
            .foregroundStyle(on ? .white : .primary)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct OfflineView: View {
    let store: Store

    var body: some View {
        VStack(spacing: 12) {
            Text(store.name.isEmpty ? "Air Purifier" : store.name).font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 12)
                Image(systemName: "wifi.slash").font(.system(size: 40, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: 148, height: 148)
            Text("Offline").font(.title3.weight(.semibold))
            if let lastSeen = store.lastSeen {
                Text("Last seen \(Text(lastSeen, style: .relative)) ago").font(.callout).foregroundStyle(.secondary)
            }
            Button { Task { await store.retry() } } label: {
                Group {
                    if store.retrying { ProgressView().controlSize(.small) } else { Text("Retry") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(store.retrying)
        }
    }
}

struct FilterTile: View {
    let life: Int

    var body: some View {
        VStack(spacing: 5) {
            Text("\(life)%").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(height: 18)
            Text("Filter").font(.caption2.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        .foregroundStyle(life < 10 ? .red : .primary)
        .accessibilityElement(children: .combine)
    }
}

struct AirRing: View {
    let pm25: Int
    let active: Bool

    private var color: Color {
        guard active else { return .secondary }
        return switch pm25 {
        // Mi Home / China PM2.5 bands
        case ..<35: .green
        case ..<75: .yellow
        case ..<115: .orange
        case ..<150: .red
        default: .purple
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: max(0.02, min(Double(pm25) / 150, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(pm25)")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("PM2.5 µg/m³").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 148, height: 148)
        .animation(.smooth, value: pm25)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Setup

struct SetupView: View {
    @Bindable var store: Store
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text("Purifier Bar").font(.title3.weight(.semibold))

            switch store.login {
            case .idle where store.connected:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(store.name.isEmpty ? "Air Purifier" : store.name)
                        Text(store.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        } catch {
                            store.error = error.localizedDescription
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Button(action: store.signIn) {
                    Label("Change purifier", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Button("Enter IP and token") { store.login = .manual }
                    .buttonStyle(.link).font(.caption)

            case .idle:
                Button(action: store.signIn) {
                    Label("Sign in with Mi Home", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Enter IP and token") { store.login = .manual }
                    .buttonStyle(.link).font(.caption)

            case .loading, .searching:
                ProgressView().frame(height: 80)

            case .qr(let image):
                Image(nsImage: image)
                    .resizable().interpolation(.none)
                    .frame(width: 200, height: 200)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                Text("Scan with Mi Home").font(.callout).foregroundStyle(.secondary)
                Button("Cancel", action: store.cancelLogin).buttonStyle(.link).font(.caption)

            case .pick(let devices):
                VStack(spacing: 6) {
                    ForEach(devices) { device in
                        Button { store.use(device) } label: {
                            HStack {
                                Image(systemName: "air.purifier.fill").foregroundStyle(brand)
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.ip.isEmpty ? "Offline" : device.ip)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

            case .manual:
                VStack(spacing: 8) {
                    TextField("IP address", text: $store.host)
                    SecureField("Token", text: $store.token)
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel", action: store.cancelLogin).buttonStyle(.link).font(.caption)
                    Spacer()
                    Button("Connect", action: store.connect).keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
