import SwiftUI

/// Phase 3 scaffolding: point Comb at a real relay and watch what happens.
///
/// Deliberately plain. Its job is to surface protocol truth, not to look like
/// the product, and it is deleted once real screens exist.
struct DebugConnectionView: View {
    @State private var model = DebugConnectionModel()
    @FocusState private var focus: Field?

    private enum Field { case url, key }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        connectionForm
                        if !model.channels.isEmpty { channelList }
                        if !model.log.isEmpty { logView }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Mark().frame(width: 26, height: 26)
                }
            }
        }
    }

    // MARK: - Form

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Relay") {
                TextField("wss://…", text: $model.relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focus, equals: .url)
            }

            field("Key") {
                SecureField("nsec1… or 64 hex characters", text: $model.secretKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .key)
            }

            Text("Held in memory for this screen only. Never written to disk, never sent anywhere except as a signature to the relay above.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.subtext)

            HStack(spacing: 12) {
                Button {
                    focus = nil
                    Task { await model.connect() }
                } label: {
                    Text(model.status.isBusy ? "Connecting…" : "Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.chartreuse)
                .foregroundStyle(Palette.ink)
                .disabled(model.status.isBusy || model.secretKey.isEmpty)

                Button("Stop") {
                    Task { await model.disconnect() }
                }
                .buttonStyle(.glass)
            }

            statusLine
        }
        .padding(18)
        .glassEffect(in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .disconnected:
            label("Not connected", systemImage: "circle.dashed", tint: Palette.subtext)
        case .connecting:
            label("Connecting", systemImage: "ellipsis.circle", tint: Palette.subtext)
        case .authenticated(let who):
            label("Authenticated as \(who)", systemImage: "checkmark.seal.fill", tint: Palette.success)
        case .failed(let reason):
            label(reason, systemImage: "exclamationmark.triangle.fill", tint: Palette.danger)
        }
    }

    // MARK: - Results

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Channels", detail: "\(model.channels.count)")

            ForEach(Array(model.channels.enumerated()), id: \.element.id) { index, channel in
                HStack(spacing: 10) {
                    Text(channel.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    if let members = channel.memberCount {
                        Text("\(members)")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Palette.subtext)
                    }
                }
                .padding(.vertical, 6)
                .arrival(true, delay: Double(index) * 0.03)

                if channel.id != model.channels.last?.id {
                    Divider().overlay(Palette.border)
                }
            }
        }
        .padding(18)
        .glassEffect(in: .rect(cornerRadius: 10))
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Protocol", detail: "\(model.storedEventCount) stored")

            ForEach(model.log) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.level.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(line.level.tint)
                        .frame(width: 14, alignment: .leading)

                    Text(line.text)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(line.level == .bad ? Palette.danger : Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .glassEffect(in: .rect(cornerRadius: 10))
    }

    // MARK: - Pieces

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Palette.subtext)
            content()
                .font(.system(size: 15).monospaced())
                .foregroundStyle(Palette.text)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Palette.surface.opacity(0.4), in: .rect(cornerRadius: 8))
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer()
            Text(detail)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.subtext)
        }
    }

    private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(tint)
    }
}

private extension DebugConnectionModel.LogLine.Level {
    var glyph: String {
        switch self {
        case .info: "·"
        case .sent: "→"
        case .received: "←"
        case .good: "✓"
        case .bad: "✕"
        }
    }

    var tint: Color {
        switch self {
        case .info: Palette.subtext
        case .sent: Palette.accent
        case .received: Palette.link
        case .good: Palette.success
        case .bad: Palette.danger
        }
    }
}

#Preview {
    DebugConnectionView()
}
