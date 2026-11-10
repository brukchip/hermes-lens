import SwiftUI

/// The fat 56 pt pill with a round icon puck at its leading edge. Lime for the
/// main action on a screen, near-black for strong secondary actions.
struct LunaPrimaryButton: View {
    enum Style { case lime, dark }

    let title: String
    let systemImage: String
    var style: Style = .lime
    var isDisabled = false
    /// Accessibility identifier for UI tests. Pass a screen-specific value at each call site.
    var identifier = "luna.primary"
    let action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var puck: CGFloat = 42

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(style == .lime ? LunaColor.lime : LunaColor.onLime)
                    .frame(width: puck, height: puck)
                    .background(style == .lime ? LunaColor.onLime : LunaColor.lime, in: Circle())
                Text(title)
                    .font(.lunaButton)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(style == .lime ? LunaColor.onLime : LunaColor.onEmphasis)
            .padding(.leading, 7)
            .padding(.trailing, 20)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: LunaMetrics.pillHeight)
            .background(style == .lime ? LunaColor.lime : LunaColor.emphasis, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(LunaPressStyle())
        .accessibilityIdentifier(identifier)
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
    }
}

/// A gentle press: slight shrink, no colour flash.
struct LunaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A compact capsule button: raised fill, text colour. For secondary actions.
struct LunaSecondaryActionStyle: ButtonStyle {
    var tint: Color = LunaColor.text
    var fill: Color = LunaColor.raised

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lunaLabel)
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A lime capsule for the one action on a card (Approve, Review & Save).
struct LunaLimeCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lunaButton)
            .foregroundStyle(LunaColor.onLime)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(LunaColor.lime, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// An icon in a round puck.
struct LunaPuck: View {
    let systemImage: String
    var size: CGFloat = 44
    var fill: Color = LunaColor.raised
    var tint: Color = LunaColor.text

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Quick action: a 62 pt puck with a short label underneath.
struct LunaQuickActionButton: View {
    let title: String
    let systemImage: String
    let identifier: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .caption) private var puck: CGFloat = 60

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: puck * 0.36, weight: .semibold))
                    .foregroundStyle(LunaColor.text)
                    .frame(width: puck, height: puck)
                    .background(LunaColor.surface, in: Circle())
                    .shadow(color: .black.opacity(0.04), radius: 10, y: 2)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LunaColor.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(LunaPressStyle())
        .accessibilityIdentifier(identifier)
    }
}

/// A small status capsule: icon + text, optional live dot.
struct LunaStatusPill: View {
    let title: String
    let systemImage: String
    var tint: Color = LunaColor.text
    var fill: Color = LunaColor.surface
    var live = false

    var body: some View {
        HStack(spacing: 7) {
            if live {
                Circle().fill(LunaColor.lime).frame(width: 8, height: 8)
                    .overlay { Circle().stroke(LunaColor.onLime.opacity(0.25), lineWidth: 1) }
            }
            Image(systemName: systemImage).imageScale(.small)
            Text(title).lineLimit(1)
        }
        .font(.lunaLabel)
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(fill, in: Capsule())
    }
}

/// A plain problem with its one fix. Text carries the meaning; colour only supports it.
struct LunaErrorBanner: View {
    let message: String
    var systemImage = "exclamationmark.circle.fill"
    var actionTitle: String?
    var identifier = "error.action"
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.lunaSymbol)
                    .foregroundStyle(LunaColor.danger)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.body)
                    .foregroundStyle(LunaColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LunaSecondaryActionStyle())
                    .accessibilityIdentifier(identifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .lunaCard(radius: 24)
    }
}

struct LunaPageIntro: View {
    let eyebrow: String?
    let title: String
    let detail: String?
    let systemImage: String
    var tint: Color = LunaColor.accent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LunaPuck(systemImage: systemImage, size: 48, fill: LunaColor.lime, tint: LunaColor.onLime)
            VStack(alignment: .leading, spacing: 5) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.lunaBadge)
                        .tracking(0.8)
                        .foregroundStyle(LunaColor.secondaryText)
                }
                Text(title)
                    .font(.lunaCardTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(LunaColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(LunaMetrics.cardPadding)
        .lunaCard()
        .accessibilityElement(children: .combine)
    }
}

struct LunaSectionHeader: View {
    let title: String
    var detail: String?
    var actionTitle: String?
    /// Accessibility identifier for the optional action button. Pass a screen-specific value when an action is set.
    var actionIdentifier = "section.action"
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.lunaHeading)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(LunaColor.secondaryText)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.lunaLabel)
                    .foregroundStyle(LunaColor.accent)
                    .accessibilityIdentifier(actionIdentifier)
            }
        }
    }
}

/// Small Luna, one short title, one sentence, one next action.
struct LunaEmptyState: View {
    let title: String
    let message: String
    /// Kept for call sites; the empty state shows Luna instead of a symbol.
    var systemImage: String = ""
    var mood: LunaMood = .ready
    var actionTitle: String?
    /// Accessibility identifier for the optional action button. Pass a screen-specific value when an action is set.
    var actionIdentifier = "empty.action"
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            LunaCharacter(mood: mood, size: 96, animated: false)
            Text(title)
                .font(.lunaHeading)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LunaColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LunaLimeCapsuleStyle())
                    .frame(maxWidth: 240)
                    .padding(.top, 4)
                    .accessibilityIdentifier(actionIdentifier)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}

/// The one pill filter row used by every list. Selected: lime; others: surface.
struct LunaFilterChips<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var systemImage: ((Item) -> String)?
    /// Equal-width chips that fill the row instead of a horizontal scroller.
    var fillsWidth = false
    /// Accessibility identifier prefix: each chip is "<prefix>.<title>".
    let identifier: String

    var body: some View {
        if fillsWidth {
            HStack(spacing: 8) { chips }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { chips }
            }
            .scrollClipDisabled()
        }
    }

    private var chips: some View {
        ForEach(items) { item in
            let selected = item == selection
            Button {
                withAnimation(.snappy) { selection = item }
            } label: {
                Group {
                    if let systemImage {
                        Label(title(item), systemImage: systemImage(item))
                    } else {
                        Text(title(item))
                    }
                }
                .font(.lunaLabel)
                .lineLimit(1)
                .foregroundStyle(selected ? LunaColor.onLime : LunaColor.text)
                .padding(.horizontal, 16)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .background(selected ? LunaColor.lime : LunaColor.surface, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("\(identifier).\(title(item))")
        }
    }
}
