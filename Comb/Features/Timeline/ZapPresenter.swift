import CombCore
import CombStore
import SwiftUI

/// Opens the zap sheet, or explains why it cannot.
///
/// Three screens present a zap and all three used to do it with a bare `if let`
/// over the address and the key, so a profile Comb had never fetched, or a
/// pubkey that would not parse, produced an empty sheet. An empty sheet reads
/// as a crash.
///
/// It also fixes the quieter half of that bug. "We have no kind 0 for this
/// person" and "this person set up no Lightning address" used to render
/// identically, as a missing button, so a member who joined after the opening
/// profile fetch simply could not be zapped and nothing said so. Here the
/// unknown case is worth one request for one key, made because the reader
/// tapped Zap.
struct ZapPresenter: View {
    let session: CommunitySession
    let pubkey: String
    let lightningAddress: String?
    let capability: ProfileSummary.ZapCapability
    let messageID: String?
    let displayName: String

    @Environment(\.dismiss) private var dismiss
    @State private var address: String?
    @State private var explanation: String?

    var body: some View {
        Group {
            if let address, let recipient = PublicKey(hex: pubkey) {
                ZapSheet(
                    session: session,
                    recipient: recipient,
                    lightningAddress: address,
                    messageID: messageID,
                    recipientName: displayName
                )
            } else if let explanation {
                cannot(explanation)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .presentationDetents([.medium])
            }
        }
        .task { await resolve() }
    }

    private func cannot(_ message: String) -> some View {
        NavigationStack {
            VStack(spacing: Space.md) {
                Spacer()
                Image(systemName: "bolt.slash")
                    .font(.system(size: Sizing.stateGlyph))
                    .foregroundStyle(Palette.subtext)
                Text(message)
                    .font(Typography.labelRegular)
                    .foregroundStyle(Palette.subtext)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg)
                Spacer()
                PrimaryButton(title: "Close") { dismiss() }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.xs)
            }
            .navigationTitle("Zap")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func resolve() async {
        guard PublicKey(hex: pubkey) != nil else {
            explanation = "Comb could not read \(displayName)'s key, so it cannot send them a zap."
            return
        }

        if let lightningAddress, !lightningAddress.isEmpty {
            address = lightningAddress
            return
        }

        guard capability == .unknown else {
            explanation = "\(displayName) has not set up a Lightning wallet that accepts zaps."
            return
        }

        await session.fetchProfile(pubkey: pubkey)

        guard let fetched = try? session.store.profile(pubkey: pubkey),
              let found = fetched.lightningAddress, !found.isEmpty
        else {
            // Distinguishing "the relay had nothing" from "they published a
            // profile with no address" would need another sentence for a
            // difference the reader cannot act on either way.
            explanation = "Comb could not find a Lightning address for \(displayName)."
            return
        }
        address = found
    }
}
