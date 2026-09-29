// The specimen page: the Metal stage, a masthead, the control panel and live readouts.
// Regular width (iPad, large iPhone landscape): side panel on the right.
// Compact width (iPhone portrait): a bottom sheet with the essentials, settings on demand.

import SwiftUI
import UIKit

enum Ink {
    static let bg = Color(red: 0xE2 / 255, green: 0xDF / 255, blue: 0xDA / 255)
    static let ink = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x19 / 255)
    static let muted = Color(red: 0x6D / 255, green: 0x69 / 255, blue: 0x62 / 255)
    static let faint = Color(red: 0x9A / 255, green: 0x95 / 255, blue: 0x8C / 255)
    static let line = Color(red: 28 / 255, green: 27 / 255, blue: 25 / 255).opacity(0.16)
    static let lineStrong = Color(red: 28 / 255, green: 27 / 255, blue: 25 / 255).opacity(0.42)
    static let live = Color(red: 0x2F / 255, green: 0x6F / 255, blue: 0x47 / 255)
    static let panel = Color(red: 0xF1 / 255, green: 0xEF / 255, blue: 0xEB / 255).opacity(0.86)
}

private struct FrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private extension View {
    func reportFrame(_ key: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: FrameKey.self, value: [key: g.frame(in: .named("stage"))]) })
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @State private var showInfo = false
    @State private var showSettings = false

    private var regular: Bool { hSize == .regular || vSize == .compact }

    var body: some View {
        GeometryReader { outer in
            let safe = outer.safeAreaInsets
            let W = outer.size.width + safe.leading + safe.trailing
            let H = outer.size.height + safe.top + safe.bottom
            ZStack(alignment: .topLeading) {
                Ink.bg
                JellyMetalView(model: model)
                StrokeOverlay(model: model)
                chrome
                    .padding(EdgeInsets(top: safe.top, leading: safe.leading, bottom: safe.bottom, trailing: safe.trailing))
                if let t = model.toast {
                    Text(t)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Ink.bg)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(Ink.ink.opacity(0.88)))
                        .frame(width: W, height: H * 0.6, alignment: .bottom)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let err = model.fatalError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RENDU HORS LIGNE").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(Ink.muted)
                        Text("Ce spécimen a besoin de Metal.").font(.system(size: 26, design: .serif))
                        Text(err).font(.footnote).foregroundColor(Ink.muted)
                    }
                    .padding(32).frame(width: W, height: H)
                    .background(Ink.bg)
                }
            }
            .frame(width: W, height: H)
            .coordinateSpace(name: "stage")
            .onPreferenceChange(FrameKey.self) { frames in updateObstruction(frames, W: W, H: H) }
            .ignoresSafeArea()
        }
        .foregroundColor(Ink.ink)
        .tint(model.accent)
        .statusBarHidden(false)
        .sheet(isPresented: $showInfo) { InfoSheet(readouts: model.readouts) }
    }

    // the slice is framed in what the UI chrome leaves free
    private func updateObstruction(_ f: [String: CGRect], W: CGFloat, H: CGFloat) {
        var ins = UIEdgeInsets.zero
        if regular {
            if let head = f["masthead"] {
                ins.left = min(head.maxX, W * 0.24) * 0.55
                ins.top = min(head.maxY, H * 0.34) * 0.5
            }
            if let panel = f["panel"] { ins.right = max(0, W - panel.minX + 12) }
            if let read = f["readouts"] { ins.bottom = max(0, H - read.minY - 24) }
        } else {
            if let head = f["masthead"] { ins.top = head.maxY * 0.7 }
            if let panel = f["panel"] { ins.bottom = max(0, H - panel.minY) }
        }
        model.setObstruction(ins)
    }

    @ViewBuilder private var chrome: some View {
        if regular { regularChrome } else { compactChrome }
    }

    // ── iPad / landscape ──
    private var regularChrome: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Masthead(large: vSize != .compact).reportFrame("masthead")
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    HintText(tool: model.tool)
                    StatsRow(readouts: model.readouts)
                    Text("Échelle illustrative : 1 unité ≈ 3,5 cm, gomme à 1,3 g/cm³. Volume et énergie sont sommés en direct sur chaque tétraèdre et chaque particule.")
                        .font(.system(size: 11)).foregroundColor(Ink.faint)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                .reportFrame("readouts")
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 12) {
                    StatusPill(paused: model.paused)
                    Group {
                        if vSize == .compact {
                            // landscape phone: not enough height for the whole panel
                            ScrollView(showsIndicators: false) { ControlPanel(model: model, compact: false, showInfo: $showInfo) }
                        } else {
                            ControlPanel(model: model, compact: false, showInfo: $showInfo)
                        }
                    }
                    .frame(width: 300)
                    .reportFrame("panel")
                }
            }
            .padding(24)
        }
    }

    // ── iPhone portrait ──
    private var compactChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Masthead(large: false).reportFrame("masthead")
                Spacer()
                StatusPill(paused: model.paused)
            }
            .padding(.horizontal, 18).padding(.top, 8)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                StatsRow(readouts: model.readouts, compact: true)
                ControlPanel(model: model, compact: true, showInfo: $showInfo, showSettings: $showSettings)
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            .reportFrame("panel")
        }
    }
}

// ── pieces of chrome ──

struct Masthead: View {
    let large: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 4) {
            Text("ÉTUDES DE MATIÈRE / N° 009")
                .font(.system(size: large ? 11 : 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.2).foregroundColor(Ink.muted)
            if large {
                VStack(alignment: .leading, spacing: -6) {
                    Text("Melon")
                    Text("Jelly.").italic()
                }
                .font(.system(size: 64, weight: .regular, design: .serif))
                Text("Une tranche d’été.\nUn peu de tremblote.\nTrop tendre pour la partager.")
                    .font(.system(size: 14, design: .serif)).foregroundColor(Ink.muted)
                    .lineSpacing(2)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Melon")
                    Text("Jelly.").italic()
                }
                .font(.system(size: 32, weight: .regular, design: .serif))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
    }
}

struct StatusPill: View {
    let paused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(paused ? Ink.faint : Ink.live).frame(width: 7, height: 7)
            Text(paused ? "METAL · EN PAUSE" : "METAL · EN DIRECT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                .foregroundColor(Ink.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().stroke(Ink.line, lineWidth: 1))
        .allowsHitTesting(false)
    }
}

struct HintText: View {
    let tool: Tool
    var body: some View {
        (Text(tool == .knife ? "Couteau  " : "Main  ").bold()
            + Text(tool == .knife
                   ? "Tracez une ligne en travers de la tranche — le couteau s’aligne dessus et coupe quand vous relâchez. Recoupez les morceaux aussi petits que vous voulez."
                   : "Attrapez n’importe quel morceau — pointe, coin, chair ou écorce — et tirez. Posez un second doigt pendant la prise pour le tordre."))
            .font(.system(size: 13)).foregroundColor(Ink.muted)
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatsRow: View {
    let readouts: Readouts
    var compact = false
    var body: some View {
        HStack(alignment: .bottom, spacing: compact ? 0 : 26) {
            stat("MASSE", "≈\(Int(readouts.massG.rounded()))", "g")
            if compact { Spacer() }
            stat("VOLUME", String(format: "%.1f", readouts.volumePct), "% repos")
            if compact { Spacer() }
            stat("CINÉTIQUE", ke, "µJ")
            if compact { Spacer() }
            stat("MORCEAUX", "\(readouts.pieces)", "")
        }
        .padding(.horizontal, compact ? 6 : 0)
        .allowsHitTesting(false)
    }
    private var ke: String {
        let uj = readouts.kineticMicroJ
        return uj < 0.05 ? "0.00" : uj < 100 ? String(format: "%.2f", uj) : String(format: "%.0f", uj)
    }
    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundColor(Ink.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: compact ? 17 : 22, design: .serif)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundColor(Ink.muted) }
            }
        }
    }
}

struct KnifeIcon: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        path.move(to: p(3, 17)); path.addLine(to: p(12.2, 7.8))
        path.move(to: p(12.2, 7.8)); path.addLine(to: p(15.8, 3.5))
        path.addCurve(to: p(14.4, 9.2), control1: p(16.6, 5.1), control2: p(16.1, 7.5))
        path.addLine(to: p(12.6, 11)); path.addLine(to: p(9, 7.4))
        path.move(to: p(3, 17)); path.addLine(to: p(5.6, 16.4))
        return path
    }
}

struct ToolPicker: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            toolButton(.hand, "Main") { Image(systemName: "hand.raised").font(.system(size: 14)) }
            toolButton(.knife, "Couteau") {
                KnifeIcon().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 17, height: 17)
            }
        }
    }
    private func toolButton<I: View>(_ t: Tool, _ label: String, @ViewBuilder icon: () -> I) -> some View {
        let on = model.tool == t
        return Button { model.tool = t } label: {
            HStack(spacing: 6) { icon(); Text(label).font(.system(size: 14, weight: .medium)) }
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundColor(on ? Ink.bg : Ink.ink)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? Ink.ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.clear : Ink.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct Swatches: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Palette.all) { p in
                let on = model.paletteID == p.id
                Button { model.paletteID = p.id } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 0) {
                            Color(linear: p.skin)
                            Color(linear: p.pale * 0.95)
                            Color(linear: p.uiFlesh)
                        }
                        .frame(height: 12).clipShape(Capsule())
                        Text(p.name).font(.system(size: 12, weight: on ? .semibold : .regular))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Ink.ink : Ink.line, lineWidth: on ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Variété \(p.name)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let lo: String, hi: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(title)
                Spacer()
                Text(String(format: "%.2f", value)).font(.system(size: 12, design: .monospaced)).foregroundColor(Ink.muted)
            }
            Slider(value: $value, in: 0...1, step: 0.01)
            HStack {
                Text(lo); Spacer(); Text(hi)
            }
            .font(.system(size: 11, design: .serif)).italic().foregroundColor(Ink.faint)
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.1).foregroundColor(Ink.muted)
    }
}

struct PillButton: View {
    let title: String
    var filled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundColor(filled ? Ink.bg : Ink.ink)
                .background(RoundedRectangle(cornerRadius: 10).fill(filled ? Ink.ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(filled ? Color.clear : Ink.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct CheckToggle: View {
    let title: String
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 15))
                Text(title).font(.system(size: 13))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ControlPanel: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    @Binding var showInfo: Bool
    var showSettings: Binding<Bool> = .constant(true)

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            if !compact {
                HStack {
                    SectionLabel("Le spécimen")
                    Spacer()
                    Text("fig. 9").font(.system(size: 12, design: .serif)).italic().foregroundColor(Ink.faint)
                }
                Divider().overlay(Ink.line)
                SectionLabel("Outil")
            }
            ToolPicker(model: model)
            if !compact { SectionLabel("Variété") }
            Swatches(model: model)
            if compact {
                HStack(spacing: 8) {
                    PillButton(title: "Pichenette") { model.nudge() }
                    PillButton(title: "Réinitialiser") { model.reset() }
                    PillButton(title: model.paused ? "Reprendre" : "Pause", filled: model.paused) { model.paused.toggle() }
                    Button { withAnimation(.easeInOut(duration: 0.25)) { showSettings.wrappedValue.toggle() } } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                            .frame(width: 40, height: 38)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Réglages")
                }
                if showSettings.wrappedValue {
                    settings.transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                settings
                HStack(spacing: 8) {
                    PillButton(title: "Pichenette") { model.nudge() }
                    PillButton(title: "Réinitialiser") { model.reset() }
                }
                PillButton(title: model.paused ? "Reprendre" : "Pause", filled: model.paused) { model.paused.toggle() }
            }
        }
        .padding(compact ? 14 : 20)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Ink.line, lineWidth: 1))
        .environment(\.colorScheme, .light)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledSlider(title: "Fermeté", value: $model.firmness, lo: "tremblante", hi: "prise")
            LabeledSlider(title: "Amortissement interne", value: $model.damping, lo: "vive", hi: "sirupeuse")
            HStack(spacing: 18) {
                CheckToggle(title: "Vitesse ¼", on: $model.slow)
                CheckToggle(title: "Maillage", on: $model.showMesh)
                Spacer()
                Button { showInfo = true } label: { Image(systemName: "info.circle").font(.system(size: 17)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("À l’intérieur de l’expérience")
            }
        }
    }
}

// the knife stroke, drawn over the stage while the finger moves
struct StrokeOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Canvas { ctx, _ in
            guard let s = model.stroke else { return }
            var p = Path()
            p.move(to: s.a); p.addLine(to: s.b)
            ctx.stroke(p, with: .color(Ink.ink.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 5]))
        }
        .opacity(model.strokeVisible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

struct InfoSheet: View {
    let readouts: Readouts
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Un corps fait de tétraèdres",
                            "La tranche est un maillage volumique de \(readouts.particles) particules et \(readouts.tets) tétraèdres, résolu en XPBD sur un pas fixe de 60 Hz découpé en 10 sous-pas. Chaque tétraèdre est tiré, avec une compliance finie, vers sa forme de repos tournée au mieux — une contrainte élastique co-rotationnelle qui retourne aussi les éléments inversés — et porte une contrainte de volume qui garde la gelée quasi incompressible : étirée, la tranche s’amincit comme la vraie.")
                    section("Écorce et amortissement",
                            "Les tétraèdres de l’écorce sont environ trois fois plus raides que la chair. L’amortissement n’agit que sur la vitesse relative le long des arêtes du maillage : la tranche tombe et culbute librement tandis que son tremblement s’éteint. Le contact au sol projette les particules hors du plan avec un frottement de Coulomb.")
                    section("La découpe",
                            "Chaque morceau est un contour convexe dans le plan de repos d’origine, aux coins arrondis. Votre trait, lu sur la surface où il a été tracé, fixe un plan de lame vertical. Pour chaque morceau traversé, la pose actuelle est ajustée par une meilleure rotation, le plan est ramené dans l’espace de repos où il devient une droite, et deux nouveaux maillages sont construits avant que la lame ne descende.")
                    section("Une surface qui suit",
                            "La surface lisse, les pépins et les bulles d’air sont des maillages séparés, chaque sommet épinglé à un tétraèdre par des poids barycentriques — les pépins s’étirent, tournent et voyagent avec la chair qui les entoure.")
                    section("La lumière à travers la gelée",
                            "Les shaders Metal rendent d’abord le sol, les pépins, les bulles et le couteau, puis les faces arrière de la tranche pour mesurer l’épaisseur traversée par chaque rayon. Les faces avant réfractent la scène selon cette épaisseur, l’absorbent avec une couleur de Beer–Lambert, ajoutent une diffusion laiteuse dans la couche pâle, une lueur en contre-jour sur les bords fins et des reflets de Fresnel d’un studio procédural. Ombres douces PCSS, occlusion de contact, MSAA 4× et tone mapping PBR Neutral.")
                }
                .padding(24)
            }
            .navigationTitle("À l’intérieur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, design: .serif))
            Text(body).font(.system(size: 15)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
