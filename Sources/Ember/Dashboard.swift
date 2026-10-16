import SwiftUI
import Charts

// Qualify the property wrapper: newer SDKs also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>
import HeatCore
import ServiceManagement

extension HeatLevel {
    var color: Color {
        switch self { case .unknown: .gray; case .cool: Color(red: 0.43, green: 0.84, blue: 0.73); case .warm: Palette.amber; case .hot: Color(red: 1, green: 0.36, blue: 0.29) }
    }
}
enum Palette {
    static let background = Color(red: 0.075, green: 0.082, blue: 0.09)
    static let card = Color.white.opacity(0.045)
    static let line = Color.white.opacity(0.085)
    static let muted = Color(red: 0.55, green: 0.58, blue: 0.61)
    static let amber = Color(red: 1, green: 0.66, blue: 0.32)
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @ViewState<Set<String>> private var expanded: Set<String> = []
    @ViewState<Bool> private var showAll = false
    @ViewState<Bool> private var showExplanation = false
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if monitor.showSettings { settings }
                    hero
                    sensorGrid
                    fanControls
                    trend
                    if !monitor.anomalies.isEmpty { anomalies }
                    contributors
                    if monitor.showSensors { sensorDetails }
                    sourceNote
                }.padding(22)
            }
            footer
        }
        .frame(width: 460, height: 740)
        .background(Palette.background)
        .foregroundStyle(Color.white.opacity(0.91))
        .preferredColorScheme(.dark)
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "flame.fill").font(.system(size: 18)).foregroundStyle(Palette.amber)
            Text("ember").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(-0.7)
            Text("A LITTLE THERMAL AWARENESS").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(Palette.muted).padding(.leading, 4)
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.2)) { monitor.showSettings.toggle() } } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(monitor.showSettings ? Palette.amber : Palette.muted)
            }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
        }.padding(.horizontal, 22).padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(monitor.level.color).frame(width: 5, height: 5)
                    Text(monitor.sampling ? "\((monitor.level == .unknown && monitor.lastUpdate != nil ? "UNKNOWN" : monitor.level.title.uppercased())) & \(monitor.level == .cool ? "COMFORTABLE" : monitor.level == .unknown ? "SAMPLING" : "ACTIVE")" : "MONITORING PAUSED")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(monitor.level.color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(monitor.displayTemperature.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: 62, weight: .light, design: .rounded)).tracking(-3).contentTransition(.numericText())
                    Text("°C").font(.system(size: 23, weight: .light)).foregroundStyle(Palette.muted).padding(.leading, 2)
                }
                Text(monitor.level == .unknown && monitor.lastUpdate != nil ? "Die temperature is unavailable on this Mac." : monitor.level.message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text(monitor.temperatureLabel).font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.75))
            }
            Spacer(minLength: 0)
            ThermalOrb(level: monitor.level, animate: monitor.animate && monitor.sampling && monitor.panelVisible)
                .frame(width: 113, height: 113)
        }.padding(.vertical, 2)
    }
    private var sensorGrid: some View {
        HStack(spacing: 8) {
            sensorCard("CPU", icon: "cpu", value: temperature(monitor.sensors.cpuAverage))
            sensorCard("GPU", icon: "square.stack.3d.up", value: temperature(monitor.sensors.gpuTemperature))
            sensorCard("BATTERY", icon: "battery.75percent", value: temperature(monitor.sensors.batteryTemperature))
            sensorCard("FANS", icon: "fan", value: fanText, suffix: monitor.sensors.fans.isEmpty ? nil : "RPM")
        }
    }
    private func sensorCard(_ title: String, icon: String, value: String, suffix: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).font(.system(size: 8, weight: .medium)).tracking(0.5)
            }.foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(suffix ?? (title == "FANS" ? (monitor.sensors.fanCount == 0 ? "Fanless Mac" : "Unavailable") : "Temperature"))
                .font(.system(size: 8)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private var fanText: String {
        if let max = monitor.sensors.fans.map(\.value).max() { return String(format: "%.0f", max) }
        return monitor.sensors.fanCount == 0 ? "Passive" : "—"
    }
    private var fanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { monitor.fans.cycle() } label: {
                    Color.clear.frame(width: 24, height: 24).padding(9)
                        .background(Palette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
                    // Keep the native animation outside the AppKit button's label host.
                    .overlay {
                        FanGlyph(spinning: monitor.sensors.fansSpinning, animated: monitor.animate && monitor.panelVisible)
                            .frame(width: 24, height: 24).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .disabled(monitor.fans.busy || monitor.sensors.fanCount == 0)
                    .help("Cycle fan mode: Auto → Max → Temperature")
                    .accessibilityLabel("Cycle fan control mode")
                VStack(alignment: .leading, spacing: 4) {
                    Text("FAN CONTROL").font(.system(size: 9, weight: .semibold)).tracking(1)
                    Text(monitor.fans.message).font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(monitor.fans.busy ? "Applying…" : monitor.fans.mode.title)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.amber)
            }
            if monitor.sensors.fanCount == 0 {
                Text("This Mac has no hardware fans.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            } else if !monitor.fans.connected {
                HStack {
                    Text("Fan control needs a macOS-approved helper.").font(.system(size: 9)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button(monitor.fans.installed ? "Connect" : "Enable…") { monitor.fans.installed ? monitor.fans.connect() : monitor.fans.enable() }
                        .font(.system(size: 10)).controlSize(.small)
                }
            } else {
                Picker("Fan mode", selection: Binding(get: { monitor.fans.mode }, set: { monitor.fans.setMode($0) })) {
                    ForEach(FanMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).tint(Palette.amber).disabled(monitor.fans.busy)
                if monitor.fans.mode == .threshold {
                    HStack {
                        Text("Max at peak temperature").font(.system(size: 10))
                        Spacer()
                        Stepper("\(Int(monitor.fans.threshold))°C", value: Binding(get: { monitor.fans.threshold }, set: { monitor.fans.threshold = $0 }), in: 45...100, step: 1)
                            .font(.system(size: 11, design: .monospaced)).fixedSize()
                    }
                    Text("Returns to Auto 5°C below the threshold. Checked on the selected polling cycle.").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
            }
            if monitor.showSettings {
                Text("Auto keeps macOS in charge. Max uses the firmware-reported maximum; Ember never sets a lower custom RPM. Quit Macs Fan Control before enabling Ember control. The helper restores Auto after a disconnect or 45s without a heartbeat.")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if !monitor.fans.connected { Button("Repair helper…") { monitor.fans.repair() }.font(.system(size: 10)).controlSize(.small) }
                if monitor.fans.installed { Button("Remove fan helper") { monitor.fans.remove() }.font(.system(size: 10)).controlSize(.small) }
            }
        }.padding(13).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private var trend: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("THERMAL PULSE · PEAK")
                Spacer()
                Text("LAST 5 MIN").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(Palette.muted)
            }
            if monitor.history.compactMap(\.temperature).count >= 2 {
                Chart(monitor.history) { point in
                    if let t = point.temperature {
                        AreaMark(x: .value("Time", point.date), yStart: .value("Base", chartFloor), yEnd: .value("Temperature", t))
                            .foregroundStyle(LinearGradient(colors: [monitor.level.color.opacity(0.22), monitor.level.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.date), y: .value("Temperature", t))
                            .interpolationMethod(.monotone).foregroundStyle(monitor.level.color).lineStyle(.init(lineWidth: 1.7))
                    }
                }
                .chartXScale(domain: Date().addingTimeInterval(-300)...Date())
                .chartYScale(domain: chartFloor...chartCeiling)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 58)
                .accessibilityLabel("Five minute temperature history")
            } else {
                HStack {
                    Spacer()
                    Text(monitor.sensors.hottest == nil ? "Temperature history unavailable" : "Collecting the first few readings…")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                }.frame(height: 58)
            }
            HStack {
                Text("5m ago"); Spacer()
                Text("Thermal pressure: \(monitor.pressureLabel)")
                Spacer(); Text("now")
            }.font(.system(size: 8)).foregroundStyle(Palette.muted)
        }.padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private var chartFloor: Double { max(0, (monitor.history.compactMap(\.temperature).min() ?? 30) - 5) }
    private var chartCeiling: Double { max(chartFloor + 15, (monitor.history.compactMap(\.temperature).max() ?? 65) + 5) }
    private var anomalies: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(Palette.amber)
                Text("WORTH A LOOK").font(.system(size: 9, weight: .semibold)).tracking(1)
                Spacer(); Text("\(monitor.anomalies.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.amber)
            }
            ForEach(monitor.anomalies.prefix(3)) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 11, weight: .medium))
                    Text(item.anomaly ?? "").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            Text("Background means not the frontmost app. This can be expected work.")
                .font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.padding(13).background(Palette.amber.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.amber.opacity(0.17)))
    }
    private var contributors: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("LIKELY HEAT CONTRIBUTORS")
                Spacer()
                Button { showExplanation.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Explain heat estimates")
                    .popover(isPresented: $showExplanation) {
                        Text("Estimated heat share is an app’s CPU time divided by CPU time across readable processes in the latest interval. It is a relative CPU activity estimate, not a measured fraction of heat or power. GPU work, charging, display and cooling are not attributed. CPU uses Activity Monitor’s convention: 100% equals one fully busy core. Some protected processes cannot be sampled.")
                            .font(.system(size: 12)).padding(18).frame(width: 330)
                    }
            }
            Picker("Activity filter", selection: $monitor.filter) {
                ForEach(ActivityFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().tint(Palette.amber).controlSize(.small)
            if showAll {
                TextField("Find app, process, or PID", text: $monitor.search).textFieldStyle(.roundedBorder).font(.system(size: 11))
            }
            HStack {
                Text("APP / PROCESS"); Spacer()
                Text("CPU").frame(width: 48, alignment: .trailing)
                Text("HEAT EST.").frame(width: 65, alignment: .trailing)
            }.font(.system(size: 8, weight: .medium)).tracking(0.6).foregroundStyle(Palette.muted)
            VStack(spacing: 0) {
                if monitor.filtered.isEmpty {
                    Text(monitor.lastUpdate == nil || monitor.history.count < 2 ? "Taking the first activity sample…" : "No matching activity")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                ForEach(Array(monitor.filtered.prefix(showAll ? 100 : 5))) { item in
                    activityRow(item)
                }
            }
            Button { withAnimation { showAll.toggle(); if !showAll { monitor.search = "" } } } label: {
                HStack {
                    Text(showAll ? "Show top contributors" : "Explore all activity")
                    Spacer()
                    Text("\(monitor.activities.count) groups").foregroundStyle(Palette.muted)
                    Image(systemName: showAll ? "chevron.up" : "arrow.right")
                }.font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(Palette.amber)
        }
    }
    private func activityRow(_ item: ProcessActivity) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                }
            } label: {
                HStack(spacing: 9) {
                    AppIcon(path: item.appPath).frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        HStack(spacing: 4) {
                            if item.anomaly != nil { Circle().fill(Palette.amber).frame(width: 4, height: 4) }
                            Text(item.background ? (item.appPath == nil ? "Background process" : "In background") : "Active app")
                            if item.members.count > 1 { Text("· \(item.members.count) processes") }
                        }.font(.system(size: 8)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 1)
                    Text(String(format: "%.1f%%", item.cpu)).font(.system(size: 11, design: .monospaced)).frame(width: 48, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(String(format: "%.0f%%", item.share)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(item.share > 20 ? Palette.amber : .white.opacity(0.75))
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(Palette.amber.opacity(0.8)).frame(width: geometry.size.width * min(1, item.share / 100))
                            }
                        }.frame(width: 48, height: 2)
                    }.frame(width: 56, alignment: .trailing)
                }.padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded.contains(item.id) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(ByteCountFormatter.string(fromByteCount: Int64(item.memory), countStyle: .memory), systemImage: "memorychip")
                        Spacer()
                        Text("\(item.members.count) sampled processes")
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Text("PIDs: " + item.members.map { String($0.identity.pid) }.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    if let path = item.appPath { Text(path).font(.system(size: 9)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                    HStack {
                        if let path = item.appPath {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                        Spacer()
                        Button("Force quit…") { monitor.terminate(item, force: true) }
                            .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.4)).disabled(!monitor.canTerminate(item))
                    }.font(.system(size: 10)).buttonStyle(.borderless)
                }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 8)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }
    private var sourceNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("A useful estimate, not a heat meter.").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
            Text("Heat share reflects CPU activity across readable processes. GPU work and charging can also warm your Mac.").font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(monitor.readable) of \(monitor.total) processes readable")
                Spacer()
                Button(monitor.showSensors ? "Hide sensors" : "Sensor details") { monitor.showSensors.toggle() }.buttonStyle(.plain).foregroundStyle(Palette.amber)
            }.font(.system(size: 9)).padding(.top, 3)
            if !monitor.sensors.connected || monitor.sensors.hottest == nil {
                Text("Temperature sensors are unavailable. Thermal pressure remains available from macOS.")
                    .font(.system(size: 9)).foregroundStyle(Palette.amber)
            }
        }
    }
    private var sensorDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("READ-ONLY HARDWARE SENSORS")
            ForEach(monitor.sensors.cpu + monitor.sensors.gpu + monitor.sensors.soc + monitor.sensors.battery) { sensor in
                HStack {
                    Text(sensor.key).font(.system(size: 10, design: .monospaced))
                    Spacer(); Text(String(format: "%.1f °C", sensor.value)).font(.system(size: 10, design: .monospaced))
                }.foregroundStyle(Palette.muted)
            }
            ForEach(monitor.sensors.fans) { sensor in
                HStack { Text(sensor.key); Spacer(); Text("\(Int(sensor.value)) RPM") }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("MAKE YOURSELF COMFORTABLE")
            HStack {
                Text("Refresh every").font(.system(size: 11)); Spacer()
                Picker("Refresh interval", selection: $monitor.interval) {
                    Text("5 seconds").tag(5.0); Text("15 seconds").tag(15.0); Text("30 seconds").tag(30.0)
                }.labelsHidden().frame(width: 120).controlSize(.small)
            }
            Picker("Displayed temperature", selection: $monitor.temperatureSource) {
                ForEach(TemperatureSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.controlSize(.small)
            if monitor.temperatureSource == .individual {
                Picker("Sensor", selection: $monitor.sensorKey) {
                    Text("Choose a sensor").tag("")
                    ForEach(monitor.sensors.cpu + monitor.sensors.gpu + monitor.sensors.soc + monitor.sensors.battery) { sensor in
                        Text("\(sensor.key) · \(Int(sensor.value))°C").tag(sensor.key)
                    }
                }.controlSize(.small)
            }
            Text("CPU average uses the same core sensor selection as Stats on supported chips. Polling times can still differ. The thermal state and fan threshold use the hottest CPU/GPU/SoC sensor.")
                .font(.system(size: 9)).foregroundStyle(Palette.muted)
            Toggle("Show top contributor in menu bar", isOn: $monitor.showCulprit)
            Toggle("Animate thermal indicator", isOn: $monitor.animate)
            LaunchAtLoginToggle()
            Text("Cool below 65°C · Warm 65–84°C · Hot 85°C+\nA 5°C recovery margin keeps the indicator steady. macOS thermal pressure can raise the state.")
                .font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
            .padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(monitor.sampling ? monitor.level.color : .gray).frame(width: 4, height: 4)
            Text(monitor.sampling ? "LIVE · EVERY \(Int(monitor.interval))S" : "PAUSED").font(.system(size: 8, weight: .medium)).tracking(0.5).foregroundStyle(Palette.muted)
            Spacer()
            Button { monitor.togglePause() } label: { Image(systemName: monitor.sampling ? "pause" : "play").font(.system(size: 10)) }
                .help(monitor.sampling ? "Pause monitoring" : "Resume monitoring").accessibilityLabel(monitor.sampling ? "Pause monitoring" : "Resume monitoring")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 11)) }.padding(.leading, 9).help("Quit Ember").accessibilityLabel("Quit Ember")
        }.buttonStyle(.plain).foregroundStyle(Palette.muted).padding(.horizontal, 22).padding(.vertical, 13)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
    private func temperature(_ value: Double?) -> String { value.map { String(format: "%.0f°", $0) } ?? "—" }
    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Color.white.opacity(0.62))
    }
}

struct AppIcon: View {
    let path: String?
    var body: some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.055))
                Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
    }
}

struct ThermalOrb: View {
    let level: HeatLevel
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        SmoothThermalOrb(level: level, animated: animate && !reduceMotion)
            .accessibilityLabel("Thermal state: \(level.title)")
    }
}

struct LaunchAtLoginToggle: View {
    @ViewState<Bool> private var enabled = SMAppService.mainApp.status == .enabled
    @ViewState<String?> private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(get: { enabled }, set: { value in
                do {
                    if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    enabled = SMAppService.mainApp.status == .enabled
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    error = nil
                } catch { self.error = error.localizedDescription; enabled = SMAppService.mainApp.status == .enabled }
            }))
            if let error { Text(error).font(.system(size: 9)).foregroundStyle(Palette.amber) }
        }
    }
}
