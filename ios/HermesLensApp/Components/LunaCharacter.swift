import SwiftUI

/// Luna's moods. Each is a pose that reads without colour and without motion,
/// and each has one plain line that says what is happening.
enum LunaMood: String, CaseIterable, Sendable {
    case ready, connecting, listening, thinking, looking, speaking, needsOK, didntWork, offline

    /// Luna's own status line, shown under her.
    var line: String {
        switch self {
        case .ready: "Ready when you are"
        case .connecting: "Connecting…"
        case .listening: "I'm listening"
        case .thinking: "Let me think"
        case .looking: "Looking through your glasses"
        case .speaking: "Speaking"
        case .needsOK: "This needs your OK"
        case .didntWork: "That didn't work"
        case .offline: "I'm offline"
        }
    }
}

/// Luna: a soft lime pebble with a small face. Drawn in code (no image assets) so
/// she stays crisp from the 40 pt tab button to the 220 pt hero, and so every
/// mood is a pose, not a recolour. Motion pauses with Reduce Motion or when the
/// app is in the background; the still pose of every mood is complete on its own.
struct LunaCharacter: View {
    var mood: LunaMood
    /// Live microphone level, 0…1. Only listening reacts to it.
    var level: Double = 0
    var size: CGFloat = 220
    /// False draws the still pose (icons, small badges).
    var animated = true
    /// Fixed animation time for previews and renders.
    var previewTime: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let still = previewTime == nil && (!animated || reduceMotion || scenePhase == .background)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: still)) { context in
            Canvas { graphics, canvas in
                let time = previewTime ?? (still ? 0 : context.date.timeIntervalSinceReferenceDate)
                let pose = LunaPose(mood: mood, time: time, level: level, moving: !still || previewTime != nil)
                LunaPainter(pose: pose, scale: min(canvas.width, canvas.height) / 100,
                            dark: colorScheme == .dark)
                    .paint(&graphics)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Pose

/// Everything that changes between moods and frames, in Luna's 100 × 100 space.
struct LunaPose {
    enum Eyes { case open, happyClosed, sleepy }
    enum Mouth { case smile(CGFloat), open(CGFloat), flat, side, frown }
    enum Prop { case card(bob: CGFloat), sparkle(CGFloat), dots(Int), sweat(CGFloat), sleep(CGFloat), sound(CGFloat) }

    var squash: CGFloat = 0
    var tilt: Double = 0
    var lift: CGFloat = 0
    var height: CGFloat = 1
    var eyes: Eyes = .open
    var eyeOpen: CGFloat = 1
    var eyeScale: CGFloat = 1
    var gaze = CGVector.zero
    var mouth: Mouth = .smile(1)
    var cheeks: Double = 1
    var dim = false
    var props: [Prop] = []

    init(mood: LunaMood, time t: Double, level: Double, moving: Bool) {
        let level = CGFloat(min(max(level, 0), 1))
        func wave(_ period: Double, _ offset: Double = 0) -> CGFloat { moving ? CGFloat(sin((t / period + offset) * 2 * .pi)) : 0 }
        func blink() -> CGFloat {
            guard moving else { return 1 }
            // Two overlapping periods so the blinks never feel metronomic.
            for (period, shift) in [(5.3, 0.0), (8.9, 2.1)] {
                let p = (t + shift).truncatingRemainder(dividingBy: period)
                if p < 0.16 { return abs(p - 0.08) / 0.08 }
            }
            return 1
        }
        let breathe = wave(3.2) * 0.014

        switch mood {
        case .ready:
            squash = breathe
            eyeOpen = blink()
        case .connecting:
            squash = breathe
            tilt = -4 + Double(wave(1.8)) * 2.5
            eyeOpen = 0.42 + (moving ? (wave(2.2) + 1) * 0.14 : 0)
            mouth = .open(0.45)
            cheeks = 0.5
        case .listening:
            tilt = 7
            squash = -0.012 + level * 0.05 * (wave(0.16) + 1) / 2
            eyeScale = 1.1
            eyeOpen = blink()
            mouth = .smile(1.25)
            props = [.sound(moving ? max(0.35, level) : 0.6)]
        case .thinking:
            tilt = -6 + Double(wave(2.4)) * 3
            squash = breathe
            gaze = CGVector(dx: 2.6, dy: -3.2)
            mouth = .side
            cheeks = 0.6
            props = [.dots(moving ? Int(t / 0.45) % 4 : 3)]
        case .looking:
            squash = -0.01
            eyes = .happyClosed
            mouth = .flat
            props = [.sparkle(moving ? 0.85 + (wave(1.4) + 1) * 0.12 : 1)]
        case .speaking:
            lift = -abs(wave(0.96)) * 2.2
            squash = breathe
            eyeOpen = blink()
            let talk = moving ? (abs(sin(t * 8.7)) * 0.6 + abs(sin(t * 5.3 + 1)) * 0.4) : 0.75
            mouth = .open(0.45 + CGFloat(talk) * 0.8)
        case .needsOK:
            tilt = 4
            squash = breathe
            eyeScale = 1.08
            eyeOpen = blink()
            mouth = .smile(0.8)
            props = [.card(bob: wave(2.6) * 1.2)]
        case .didntWork:
            height = 0.92
            tilt = -3
            gaze = CGVector(dx: -0.6, dy: 2.4)
            eyeScale = 0.92
            mouth = .frown
            cheeks = 0.4
            props = [.sweat(moving ? (wave(3.0) + 1) * 0.5 : 0.3)]
        case .offline:
            height = 0.86
            squash = 0.02 + breathe * 0.5
            eyes = .sleepy
            mouth = .flat
            cheeks = 0
            dim = true
            props = [.sleep(moving ? CGFloat((t / 3.2).truncatingRemainder(dividingBy: 1)) : 0.35)]
        }
    }
}

// MARK: - Painter

private struct LunaPainter {
    let pose: LunaPose
    let scale: CGFloat
    let dark: Bool

    /// Body outline: a soft rounded dome, a little narrower at the crown.
    private static let outline: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 50, y: 15))
        p.addCurve(to: CGPoint(x: 87, y: 61), control1: CGPoint(x: 73, y: 15), control2: CGPoint(x: 85, y: 40))
        p.addCurve(to: CGPoint(x: 50, y: 88), control1: CGPoint(x: 89, y: 81), control2: CGPoint(x: 73, y: 88))
        p.addCurve(to: CGPoint(x: 13, y: 61), control1: CGPoint(x: 27, y: 88), control2: CGPoint(x: 11, y: 81))
        p.addCurve(to: CGPoint(x: 50, y: 15), control1: CGPoint(x: 15, y: 40), control2: CGPoint(x: 27, y: 15))
        p.closeSubpath()
        return p
    }()

    static let ink = Color(lunaHex: 0x181C17)

    /// Body space → canvas: squash and droop about the base, tilt, bounce, then scale.
    private var body: CGAffineTransform {
        let base = CGPoint(x: 50, y: 88)
        return CGAffineTransform(translationX: -base.x, y: -base.y)
            .concatenating(CGAffineTransform(scaleX: 1 + pose.squash, y: (1 - pose.squash) * pose.height))
            .concatenating(CGAffineTransform(rotationAngle: pose.tilt * .pi / 180))
            .concatenating(CGAffineTransform(translationX: base.x, y: base.y + pose.lift))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(body) }
    private func len(_ v: CGFloat) -> CGFloat { v * scale }

    func paint(_ g: inout GraphicsContext) {
        shadow(&g)
        let outline = Self.outline.applying(body)
        g.drawLayer { layer in
            layer.clip(to: outline)
            shade(&layer)
        }
        face(&g)
        for prop in pose.props { draw(prop, &g) }
    }

    private func shadow(_ g: inout GraphicsContext) {
        let width = 64 * (1 + pose.squash) * (pose.lift < 0 ? 1 + pose.lift / 40 : 1)
        let rect = CGRect(x: 50 - width / 2, y: 87.5, width: width, height: 7)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        g.drawLayer { layer in
            layer.addFilter(.blur(radius: len(2.4)))
            layer.fill(Path(ellipseIn: rect), with: .color(.black.opacity(dark ? 0.42 : 0.17)))
        }
    }

    private func shade(_ g: inout GraphicsContext) {
        let lit: [Color] = pose.dim
            ? [0xEEF1E2, 0xD3D9BC, 0xB7C09B, 0x96A07B].map { Color(lunaHex: $0) }
            : [0xF8FFD2, 0xE4FA6E, 0xD2F034, 0xA9C51D].map { Color(lunaHex: $0) }
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100).applying(body).insetBy(dx: -len(20), dy: -len(20))
        // Key light from the upper left.
        g.fill(Path(bounds), with: .radialGradient(
            Gradient(stops: [.init(color: lit[0], location: 0), .init(color: lit[1], location: 0.32),
                             .init(color: lit[2], location: 0.62), .init(color: lit[3], location: 1)]),
            center: pt(37, 30), startRadius: 0, endRadius: len(74)))
        // Ambient occlusion low on the body gives it weight.
        g.fill(Path(bounds), with: .linearGradient(
            Gradient(colors: [.clear, Color(lunaHex: pose.dim ? 0x5C6448 : 0x6E8A06).opacity(0.38)]),
            startPoint: pt(50, 62), endPoint: pt(50, 90)))
        // Light bouncing up from the ground: a faint lighter band along the base.
        g.drawLayer { layer in
            layer.addFilter(.blur(radius: len(5)))
            layer.fill(Path(ellipseIn: CGRect(center: pt(56, 90), width: len(58), height: len(9))),
                       with: .color(Color(lunaHex: pose.dim ? 0xE2E6D2 : 0xEFFF9A).opacity(0.55)))
        }
        // Specular: a soft sheen with a brighter core.
        g.drawLayer { layer in
            layer.addFilter(.blur(radius: len(2.2)))
            let sheen = Path(ellipseIn: CGRect(x: -9, y: -4.2, width: 18, height: 8.4))
                .applying(CGAffineTransform(rotationAngle: -0.5))
                .applying(CGAffineTransform(translationX: 35, y: 28))
                .applying(body)
            layer.fill(sheen, with: .color(.white.opacity(pose.dim ? 0.45 : 0.8)))
        }
        g.drawLayer { layer in
            layer.addFilter(.blur(radius: len(0.8)))
            let core = Path(ellipseIn: CGRect(x: -4, y: -1.6, width: 8, height: 3.2))
                .applying(CGAffineTransform(rotationAngle: -0.5))
                .applying(CGAffineTransform(translationX: 33, y: 28.5))
                .applying(body)
            layer.fill(core, with: .color(.white.opacity(pose.dim ? 0.5 : 0.9)))
        }
    }

    private func face(_ g: inout GraphicsContext) {
        let ink = Self.ink
        let stroke = StrokeStyle(lineWidth: len(2.3), lineCap: .round, lineJoin: .round)

        // Cheeks first, under the eyes.
        if pose.cheeks > 0 {
            g.drawLayer { layer in
                layer.addFilter(.blur(radius: len(1.6)))
                for x in [29.0, 71.0] {
                    layer.fill(Path(ellipseIn: CGRect(center: pt(x, 63.5), width: len(9), height: len(5))),
                               with: .color(Color(lunaHex: 0xFF8F9C).opacity(0.34 * pose.cheeks)))
                }
            }
        }

        for x in [39.0, 61.0] {
            let center = pt(x + pose.gaze.dx, 52 + pose.gaze.dy)
            switch pose.eyes {
            case .open where pose.eyeOpen > 0.18:
                let w = len(7.4 * pose.eyeScale), h = len(10.6 * pose.eyeScale * pose.eyeOpen)
                g.fill(Path(ellipseIn: CGRect(center: center, width: w, height: h)), with: .color(ink))
                if pose.eyeOpen > 0.6 {
                    let glint = CGPoint(x: center.x - len(1.4), y: center.y - h * 0.22)
                    g.fill(Path(ellipseIn: CGRect(center: glint, radius: len(1.45 * pose.eyeScale))), with: .color(.white))
                }
            case .open:
                var lid = Path()
                lid.move(to: pt(x - 3.6, 52)); lid.addLine(to: pt(x + 3.6, 52))
                g.stroke(lid, with: .color(ink), style: stroke)
            case .happyClosed:
                var arc = Path()
                arc.move(to: pt(x - 4, 51)); arc.addQuadCurve(to: pt(x + 4, 51), control: pt(x, 56))
                g.stroke(arc, with: .color(ink), style: stroke)
            case .sleepy:
                var lid = Path()
                lid.move(to: pt(x - 4, 54)); lid.addQuadCurve(to: pt(x + 4, 54), control: pt(x, 55.6))
                g.stroke(lid, with: .color(ink.opacity(0.85)), style: stroke)
            }
        }

        var mouth = Path()
        switch pose.mouth {
        case .smile(let amount):
            mouth.move(to: pt(45.2, 63.2))
            mouth.addQuadCurve(to: pt(54.8, 63.2), control: pt(50, 63.2 + 5.6 * amount))
            g.stroke(mouth, with: .color(ink), style: stroke)
        case .open(let amount):
            let rect = CGRect(center: pt(50, 65.5), width: len(5.2 + 2.2 * amount), height: len(2.4 + 5.4 * amount))
            g.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2), with: .color(ink))
            if amount > 0.55 {
                let tongue = CGRect(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.42,
                                    width: rect.width * 0.56, height: rect.height * 0.32)
                g.fill(Path(ellipseIn: tongue), with: .color(Color(lunaHex: 0xFF8A80)))
            }
        case .flat:
            mouth.move(to: pt(46.6, 64.5)); mouth.addLine(to: pt(53.4, 64.5))
            g.stroke(mouth, with: .color(ink), style: stroke)
        case .side:
            mouth.move(to: pt(48.5, 64.8)); mouth.addQuadCurve(to: pt(55.5, 63.2), control: pt(52.5, 65.2))
            g.stroke(mouth, with: .color(ink), style: stroke)
        case .frown:
            mouth.move(to: pt(45.6, 66.6)); mouth.addQuadCurve(to: pt(54.4, 66.6), control: pt(50, 62.4))
            g.stroke(mouth, with: .color(ink), style: stroke)
        }
    }

    private func draw(_ prop: LunaPose.Prop, _ g: inout GraphicsContext) {
        let line = dark ? Color(lunaHex: 0xF6F7EF) : Self.ink
        let k = CGAffineTransform(scaleX: scale, y: scale)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(k) }
        switch prop {
        case .card(let bob):
            // A small approval card held at her side.
            let card = Path(roundedRect: CGRect(x: -11, y: -8, width: 22, height: 16), cornerRadius: 4.5)
            let place = CGAffineTransform(rotationAngle: -0.14).concatenating(CGAffineTransform(translationX: 82, y: 66 + bob)).concatenating(k)
            g.fill(card.applying(place), with: .color(Self.ink))
            g.stroke(card.applying(place), with: .color(.white.opacity(dark ? 0.25 : 0.9)), lineWidth: len(1.2))
            var check = Path()
            check.move(to: CGPoint(x: -4.5, y: 0.2)); check.addLine(to: CGPoint(x: -1.2, y: 3.4)); check.addLine(to: CGPoint(x: 5, y: -3.4))
            g.stroke(check.applying(place), with: .color(Color(lunaHex: 0xD4F53C)),
                     style: StrokeStyle(lineWidth: len(2.2), lineCap: .round, lineJoin: .round))
        case .sparkle(let s):
            // The glasses camera's glint: one four-point star.
            var star = Path()
            let c = CGPoint(x: 82, y: 22), r = 6.5 * s, w = 1.6 * s
            star.move(to: CGPoint(x: c.x, y: c.y - r))
            star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
            star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
            star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
            star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
            g.fill(star.applying(k), with: .color(line.opacity(0.85)))
            g.fill(Path(ellipseIn: CGRect(center: at(91, 31), radius: len(1.4 * s))), with: .color(line.opacity(0.5)))
        case .dots(let count):
            for (i, spot) in [(76.0, 30.0, 1.6), (82.5, 22.0, 2.1), (90.0, 13.0, 2.7)].enumerated() {
                g.fill(Path(ellipseIn: CGRect(center: at(spot.0, spot.1), radius: len(spot.2))),
                       with: .color(line.opacity(i < count ? 0.55 : 0.12)))
            }
        case .sweat(let slide):
            var drop = Path()
            let top = CGPoint(x: 80, y: 27 + slide * 3)
            drop.move(to: top)
            drop.addCurve(to: CGPoint(x: top.x, y: top.y + 10), control1: CGPoint(x: top.x + 5.5, y: top.y + 6), control2: CGPoint(x: top.x + 3.6, y: top.y + 10))
            drop.addCurve(to: top, control1: CGPoint(x: top.x - 3.6, y: top.y + 10), control2: CGPoint(x: top.x - 5.5, y: top.y + 6))
            g.fill(drop.applying(k), with: .color(Color(lunaHex: 0x9FD6FF)))
            g.stroke(drop.applying(k), with: .color(line.opacity(0.35)), lineWidth: len(0.9))
        case .sleep(let phase):
            for (i, z) in [(0.0, 5.0), (0.5, 7.5)].enumerated() {
                let p = (phase + CGFloat(z.0)).truncatingRemainder(dividingBy: 1)
                let point = at(74 + CGFloat(i) * 9 + p * 3, 32 - CGFloat(i) * 9 - p * 6)
                let fade = 1 - abs(p - 0.5) * 1.2
                g.draw(Text("z").font(.system(size: len(CGFloat(z.1) + 3), weight: .heavy, design: .rounded))
                    .foregroundStyle(line.opacity(0.55 * fade)), at: point)
            }
        case .sound(let loud):
            for i in 0..<2 {
                var arc = Path()
                arc.addArc(center: at(80, 50), radius: len(8 + CGFloat(i) * 6), startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                g.stroke(arc, with: .color(line.opacity(Double(loud) * (i == 0 ? 0.6 : 0.35))),
                         style: StrokeStyle(lineWidth: len(2), lineCap: .round))
            }
        }
    }
}

private extension CGRect {
    init(center: CGPoint, radius: CGFloat) {
        self.init(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
    init(center: CGPoint, width: CGFloat, height: CGFloat) {
        self.init(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

extension Color {
    /// A fixed colour from 0xRRGGBB (no appearance switch).
    init(lunaHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
