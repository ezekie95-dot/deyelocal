import SwiftUI
import Charts
import UIKit

/// Modo tablet: panel de solo lectura a pantalla completa, pensado para un iPad fijo.
struct TabletDashboardView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model: DashboardModel

    init(devices: [MicroDevice]) {
        _model = State(initialValue: DashboardModel(devices: devices))
    }

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 20)]

    var body: some View {
        ZStack {
            Dash.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    HStack(alignment: .top, spacing: 20) {
                        totalCard
                        chartCard
                    }
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(model.devices) { device in
                            MicroTile(device: device, entry: model.entries[device.id])
                        }
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await model.poll() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: store.dashboardIDs) { _, _ in
            model.devices = store.dashboardDevices
            Task { await model.refreshAll() }
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(alignment: .center) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 54, weight: .thin, design: .rounded))
                        .monospacedDigit()
                    Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.onlineCount == model.devices.count && model.lastUpdate != nil ? Dash.green : Dash.amber)
                        .frame(width: 10, height: 10)
                    Text("\(model.onlineCount)/\(model.devices.count) micros en línea")
                        .font(.headline)
                }
                if let last = model.lastUpdate {
                    Text("Actualizado \(last, format: .dateTime.hour().minute().second())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .accessibilityLabel("Salir del modo tablet")
        }
    }

    // MARK: - Total

    private var totalCard: some View {
        VStack(spacing: 18) {
            Text("PRODUCCIÓN AHORA")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(.secondary)
            PowerRing(value: model.totalPower, max: max(model.totalRated, 1), lineWidth: 22) {
                VStack(spacing: 0) {
                    Text(Dash.powerValue(model.totalPower))
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .monospacedDigit()
                    Text(Dash.powerUnit(model.totalPower))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Dash.sun)
                    if model.totalRated > 0 {
                        Text("de \(Fmt.power(model.totalRated))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
            .frame(width: 280, height: 280)
            HStack(spacing: 0) {
                BigStat(title: "Hoy", value: Fmt.energy(model.todayEnergy), icon: "sun.max.fill", tint: Dash.sun)
                BigStat(title: "Pico", value: Fmt.power(model.peakToday), icon: "bolt.fill", tint: Dash.amber)
                BigStat(title: "Total", value: Fmt.energy(model.totalEnergy), icon: "sum", tint: Dash.blue)
            }
        }
        .padding(24)
        .frame(width: 380)
        .dashCard()
    }

    // MARK: - Gráfica

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CURVA DE HOY")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.energy(model.todayEnergy))
                    .font(.headline)
                    .foregroundStyle(Dash.sun)
            }
            if model.history.count < 2 {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("La gráfica se irá dibujando mientras el modo tablet esté abierto.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(model.history) { s in
                    AreaMark(x: .value("Hora", s.date), y: .value("Potencia", s.watts))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Dash.sun.opacity(0.55), Dash.sun.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Hora", s.date), y: .value("Potencia", s.watts))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .foregroundStyle(Dash.sun)
                }
                .chartXScale(domain: Dash.dayWindow())
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel {
                            if let w = value.as(Double.self) { Text(Fmt.power(w)) }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 440, maxHeight: 440)
        .dashCard()
    }
}

// MARK: - Tarjeta de cada micro

private struct MicroTile: View {
    let device: MicroDevice
    let entry: DashboardModel.Entry?

    private var snap: MicroSnapshot? { entry?.snapshot }
    private var stale: Bool { entry?.isStale ?? false }

    private var statusColor: Color {
        guard let s = snap, !stale else { return stale ? Dash.red : .gray }
        if !s.isOn { return .gray }
        switch s.state {
        case .normal: return Dash.green
        case .alarm: return Dash.amber
        case .fault: return Dash.red
        default: return Dash.blue
        }
    }

    private var statusText: String {
        if stale { return "Sin respuesta" }
        guard let s = snap else { return "Conectando…" }
        return s.isOn ? s.state.label : "Apagado"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(device.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.caption.weight(.semibold))
                }
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(statusColor.opacity(0.15), in: Capsule())
            }

            HStack(alignment: .center, spacing: 20) {
                PowerRing(value: snap?.acPower ?? 0, max: max(snap?.ratedPower ?? 0, 1), lineWidth: 12) {
                    VStack(spacing: 0) {
                        Text(Dash.powerValue(snap?.acPower ?? 0))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(Dash.powerUnit(snap?.acPower ?? 0))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Dash.sun)
                    }
                }
                .frame(width: 120, height: 120)

                PanelBars(channels: snap?.pv ?? [], perPanelMax: perPanelMax)
                    .frame(maxWidth: .infinity)
                    .frame(height: 130)
            }

            HStack {
                Label(Fmt.energy(snap?.todayEnergy ?? 0), systemImage: "sun.max.fill")
                Spacer()
                Label("\(Fmt.num(snap?.temperature ?? 0, 0)) °C", systemImage: "thermometer.medium")
                Spacer()
                Label("\(Fmt.num(snap?.gridVoltage ?? 0, 0)) V", systemImage: "bolt.horizontal")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let s = snap, !stale, !(s.activeFaults.isEmpty && s.activeAlarms.isEmpty) {
                Label((s.activeFaults + s.activeAlarms).joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Dash.amber)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .opacity(stale ? 0.55 : 1)
        .dashCard()
        .animation(.easeInOut(duration: 0.6), value: snap?.acPower)
    }

    private var perPanelMax: Double {
        guard let s = snap, s.ratedPower > 0 else { return 500 }
        return s.ratedPower / Double(max(s.mpptCount, 1))
    }
}

/// Barras verticales, una por panel (PV1-PV4).
private struct PanelBars: View {
    let channels: [PVChannel]
    let perPanelMax: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(0..<max(channels.count, 4), id: \.self) { i in
                let ch = i < channels.count ? channels[i] : nil
                let frac = min(max((ch?.power ?? 0) / perPanelMax, 0), 1)
                VStack(spacing: 6) {
                    Text(ch.map { "\(Int($0.power.rounded()))" } ?? "–")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(.white.opacity(0.07))
                            Capsule()
                                .fill(LinearGradient(colors: [Dash.amber, Dash.sun], startPoint: .bottom, endPoint: .top))
                                .frame(height: max(geo.size.height * CGFloat(frac), frac > 0 ? 6 : 0))
                        }
                    }
                    Text("PV\(i + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Componentes comunes

struct PowerRing<Content: View>: View {
    let value: Double
    let max: Double
    let lineWidth: CGFloat
    @ViewBuilder let content: () -> Content

    private var fraction: Double { Swift.min(Swift.max(value / max, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [Dash.amber, Dash.sun, Color.yellow, Dash.sun],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Dash.sun.opacity(0.5), radius: lineWidth * 0.6)
                .animation(.easeOut(duration: 1.0), value: fraction)
            content()
        }
        .padding(lineWidth / 2)
    }
}

private struct BigStat: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

enum Dash {
    static let sun = Color(red: 1.0, green: 0.66, blue: 0.16)
    static let amber = Color(red: 1.0, green: 0.48, blue: 0.12)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let red = Color(red: 1.0, green: 0.33, blue: 0.33)
    static let blue = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let background = LinearGradient(
        colors: [Color(red: 0.04, green: 0.06, blue: 0.12), Color(red: 0.07, green: 0.10, blue: 0.20)],
        startPoint: .top, endPoint: .bottom)

    static func powerValue(_ w: Double) -> String {
        w >= 1000 ? Fmt.num(w / 1000, 2) : Fmt.num(w, 0)
    }
    static func powerUnit(_ w: Double) -> String { w >= 1000 ? "kW" : "W" }

    /// Eje X de la gráfica: de 6:00 a 22:00 de hoy.
    static func dayWindow() -> ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date())
        return start.addingTimeInterval(6 * 3600)...start.addingTimeInterval(22 * 3600)
    }
}

private struct DashCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

extension View {
    fileprivate func dashCard() -> some View { modifier(DashCard()) }
}
