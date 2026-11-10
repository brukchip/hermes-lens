import HermesLensCore
import SwiftUI

/// The live call, drawn on Home under Luna. Everything here reflects real call
/// state: what you said, what Luna is saying, what she is doing (activity chips),
/// what needs your OK, and what went wrong.
struct LunaCallPanel: View {
    let call: any LunaCall
    let isReconnecting: Bool
    let look: () -> Void
    let talkAgain: () -> Void
    let end: () -> Void

    @State private var showsFullCaptions = false
    @State private var editingContact = false

    /// The server denies an unanswered approval after 120 s.
    private static let approvalSeconds: TimeInterval = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !call.tools.isEmpty {
                activityChips
            }
            if let approval = call.approval {
                approvalCard(approval)
            }
            if let draft = call.contactDraft {
                contactCard(draft)
            }
            if !call.state.heard.isEmpty || !call.state.transcript.isEmpty {
                captions
            }
            if let error = call.errorMessage, isOver {
                LunaErrorBanner(message: error)
                    .accessibilityIdentifier("call.error")
            }
            controls
                .padding(.top, 4)
        }
    }

    private var isOver: Bool { [.failed, .ended].contains(call.state.phase) }

    // MARK: Captions

    private var captions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !call.state.heard.isEmpty {
                captionLine(speaker: "You", text: call.state.heard, font: .body, color: LunaColor.secondaryText)
            }
            if !call.state.transcript.isEmpty {
                captionLine(speaker: "Luna", text: call.state.transcript,
                            font: .system(.title3, weight: .semibold), color: LunaColor.text)
            }
            if call.state.interrupted {
                Label("Interrupted", systemImage: "pause.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LunaColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LunaMetrics.cardPadding)
        .lunaCard(radius: 26)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { showsFullCaptions.toggle() } }
        .accessibilityIdentifier("call.captions")
        .accessibilityHint(showsFullCaptions ? "Shows less" : "Shows the full text")
    }

    private func captionLine(speaker: String, text: String, font: Font, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speaker.uppercased())
                .font(.lunaBadge)
                .tracking(0.8)
                .foregroundStyle(LunaColor.secondaryText)
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(showsFullCaptions ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Activity

    private var activityChips: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(call.tools) { tool in
                    let recording = tool.name == "record_video"
                    HStack(spacing: 8) {
                        if recording {
                            Circle().fill(LunaColor.danger).frame(width: 8, height: 8)
                        } else {
                            Image(systemName: tool.systemImage).imageScale(.small)
                        }
                        Text(tool.label).lineLimit(1)
                        Text("\(Int(context.date.timeIntervalSince(tool.startedAt))) s")
                            .monospacedDigit()
                            .foregroundStyle(LunaColor.secondaryText)
                    }
                    .font(.lunaLabel)
                    .foregroundStyle(LunaColor.text)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(recording ? LunaColor.surface : LunaColor.lime.opacity(0.45), in: Capsule())
                    .overlay { if recording { Capsule().stroke(LunaColor.danger.opacity(0.5), lineWidth: 1) } }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("call.tool")
                }
            }
        }
    }

    // MARK: Approval

    private func approvalCard(_ approval: LunaNativeToolResult.Approval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NEEDS YOUR OK")
                    .font(.lunaBadge)
                    .tracking(0.8)
                    .foregroundStyle(LunaColor.onLime)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(LunaColor.lime, in: Capsule())
                Spacer()
                if let shown = call.approvalShownAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(Self.approvalSeconds - context.date.timeIntervalSince(shown)))
                        Text(left > 0 ? String(format: "%d:%02d", left / 60, left % 60) : "Expired")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(left > 20 ? LunaColor.onEmphasisSecondary : LunaColor.warning)
                            .accessibilityLabel(left > 0 ? "\(left) seconds left" : "Expired")
                    }
                }
            }
            Text(approval.summary)
                .font(.system(.title3, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            ApprovalDetail(approval: approval)
            Text("Nothing happens unless you tap Approve or double-tap your glasses.")
                .font(.footnote)
                .foregroundStyle(LunaColor.onEmphasisSecondary)
            HStack(spacing: 10) {
                Button("Decline") { call.decideApproval(false) }
                    .buttonStyle(LunaSecondaryActionStyle(tint: LunaColor.onEmphasis, fill: Color.white.opacity(0.12)))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("call.approval.decline")
                Button(call.approvalBusy ? "Approving…" : "Approve") { call.decideApproval(true) }
                    .buttonStyle(LunaLimeCapsuleStyle())
                    .accessibilityIdentifier("call.approval.approve")
            }
            .disabled(call.approvalBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LunaMetrics.cardPadding)
        .lunaEmphasisCard(radius: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.approval")
    }

    // MARK: Contact

    private func contactCard(_ draft: LunaContactDraft) -> some View {
        let role = [draft.jobTitle, draft.name == nil ? nil : draft.company].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 12) {
            Text("NEW CONTACT")
                .font(.lunaBadge)
                .tracking(0.8)
                .foregroundStyle(LunaColor.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.title).font(.lunaCardTitle)
                ForEach([role, draft.phone ?? "", draft.email ?? ""].filter { !$0.isEmpty }, id: \.self) { line in
                    Text(line).font(.body).foregroundStyle(LunaColor.secondaryText).textSelection(.enabled)
                }
            }
            Text("Check it, then tap Done to save it to Contacts.")
                .font(.footnote)
                .foregroundStyle(LunaColor.secondaryText)
            Button("Review & Save") { editingContact = true }
                .buttonStyle(LunaLimeCapsuleStyle())
                .accessibilityIdentifier("call.contact.review")
            Button("Dismiss") { call.finishContact(saved: false) }
                .font(.lunaLabel)
                .foregroundStyle(LunaColor.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("call.contact.dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LunaMetrics.cardPadding)
        .lunaCard(radius: 28)
        .accessibilityIdentifier("call.contact")
        .sheet(isPresented: $editingContact) {
            ContactEditorSheet(draft: draft) { saved in
                editingContact = false
                call.finishContact(saved: saved)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if isOver && !isReconnecting {
            VStack(spacing: 10) {
                LunaPrimaryButton(title: "Talk again", systemImage: "mic.fill",
                                  identifier: "call.talkAgain", action: talkAgain)
                Button("Close", action: end)
                    .buttonStyle(LunaSecondaryActionStyle())
                    .accessibilityIdentifier("call.close")
            }
        } else {
            HStack(spacing: 0) {
                control(call.state.isMuted ? "Unmute" : "Mute",
                        systemImage: call.state.isMuted ? "mic.slash.fill" : "mic.fill",
                        selected: call.state.isMuted, identifier: "call.mute") { call.toggleMute() }
                    .disabled(![.listening, .responding, .speaking].contains(call.state.phase))
                control("Look", systemImage: "eye", identifier: "call.look", action: look)
                    .disabled(call.state.phase == .idle)
                Button(action: end) {
                    VStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(LunaColor.onEmphasis)
                            .frame(width: 64, height: 64)
                            .background(Color(light: 0xB3261E, dark: 0xC8443C), in: Circle())
                        Text("End").font(.caption.weight(.semibold)).foregroundStyle(LunaColor.text)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LunaPressStyle())
                .accessibilityLabel("End call")
                .accessibilityIdentifier("call.end")
            }
        }
    }

    private func control(_ title: String, systemImage: String, selected: Bool = false,
                         identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? LunaColor.onLime : LunaColor.text)
                    .frame(width: 64, height: 64)
                    .background(selected ? LunaColor.lime : LunaColor.surface, in: Circle())
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(LunaColor.text)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LunaPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// What Hermes will actually run (credentials redacted) and its own risk flag,
/// under the reason on an approval card. Shown on the dark emphasis card.
struct ApprovalDetail: View {
    let approval: LunaNativeToolResult.Approval

    var body: some View {
        if let detail = approval.detail, !detail.isEmpty {
            let text = Text(detail)
                .font(.footnote.monospaced())
                .foregroundStyle(LunaColor.onEmphasisSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The whole action is readable before the tap: short text sits as it is, long text
            // scrolls inside the card instead of being cut off after a few lines.
            ViewThatFits(in: .vertical) {
                text.fixedSize(horizontal: false, vertical: true)
                ScrollView { text }
            }
                .frame(maxHeight: 190)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Action: \(detail)")
                .accessibilityIdentifier("approval.detail")
        }
        if approval.risky {
            Label("Hermes flagged this as risky", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(LunaColor.warning)
                .accessibilityIdentifier("approval.risky")
        }
    }
}
