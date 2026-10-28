import MoireKit
import SwiftUI

/// Which side a "Connect to Server" sheet is for.
struct ConnectRequest: Identifiable {
    let side: SideID
    var id: String { side.name }
}

/// Type a server address, or pick a recent one, for one side of the folder comparison.
struct ConnectSheet: View {
    let model: FolderModel
    let side: SideID
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var endpoint = ""
    @State private var region = ""
    @State private var profile = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var recents = RecentServers.load()

    private var scheme: RemoteLocation.Scheme? {
        let lowered = address.trimmingCharacters(in: .whitespaces).lowercased()
        return RemoteLocation.Scheme.allCases.first { lowered.hasPrefix("\($0.rawValue)://") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect the \(side.name) Side to a Server")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                TextField("sftp://user@host/folder", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(connect)
                Text("sftp://user@host:port/path · ftp:// · ftps:// (implicit TLS) · ftpes:// (AUTH TLS) · s3://bucket/prefix")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch scheme {
            case .sftp:
                note("Signs in with your SSH keys, the agent and ~/.ssh/config, like ssh in Terminal. A host Terminal has never connected to must be trusted there first. Paths start at the root; /~/ starts in your home folder.")
            case .ftp, .ftps, .ftpes:
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("Password (leave empty to use the one in the Keychain)", text: $password)
                        .textFieldStyle(.roundedBorder)
                    note(scheme == .ftp
                        ? "Saved in your Keychain. Plain FTP sends it unencrypted; use ftps:// or ftpes:// when the server supports TLS."
                        : "Saved in your Keychain.")
                }
            case .s3:
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Endpoint").foregroundStyle(.secondary)
                        TextField("AWS, or https://… for R2, MinIO or B2", text: $endpoint)
                    }
                    GridRow {
                        Text("Region").foregroundStyle(.secondary)
                        TextField("From the profile, or us-east-1", text: $region)
                    }
                    GridRow {
                        Text("Profile").foregroundStyle(.secondary)
                        TextField("default", text: $profile)
                    }
                }
                .textFieldStyle(.roundedBorder)
                note("Keys come from the profile in ~/.aws/credentials and ~/.aws/config (credential_process works too), or the AWS_ environment variables. Without keys, requests go out unsigned, which works for public buckets.")
            case nil:
                EmptyView()
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.removed)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !recents.isEmpty {
                Text("Recent Servers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                List(recents, id: \.self) { location in
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack").foregroundStyle(Theme.iris)
                        Text(location.displayName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            RecentServers.remove(location)
                            recents = RecentServers.load()
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.bar)
                            .foregroundStyle(.secondary)
                            .help("Remove from the list")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        fill(location)
                        connect()
                    }
                    .onTapGesture { fill(location) }
                }
                .frame(height: min(CGFloat(recents.count) * 28 + 8, 150))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let current = model.location(side)?.remote { fill(current) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fill(_ location: RemoteLocation) {
        address = location.url
        endpoint = location.s3.endpoint
        region = location.s3.region
        profile = location.s3.profile
        password = ""
        problem = nil
    }

    private func connect() {
        do {
            var (location, typed) = try RemoteLocation.parse(address)
            if location.scheme == .s3 {
                location.s3 = RemoteLocation.S3Options(
                    endpoint: endpoint.trimmingCharacters(in: .whitespaces),
                    region: region.trimmingCharacters(in: .whitespaces),
                    profile: profile.trimmingCharacters(in: .whitespaces)
                )
            }
            // A password in the address or the field goes to the Keychain once a comparison logs in
            // with it; the address is kept without it.
            let secret = location.scheme.isFTP ? typed ?? (password.isEmpty ? nil : password) : nil
            RecentServers.add(location)
            model.set(location, on: side, password: secret)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
