import SwiftUI

/// Shows UPnP/DLNA receiver network state and live control endpoints.
public struct ReceiverStatusView: View {
    @ObservedObject var playerService = PlayerService.shared
    @State private var serverIP: String = HTTPServer.shared.localIPAddress
    @State private var isSSDPActive = true

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("DLNA / UPnP Receiver")
                        .font(.headline)
                    Text("Ready to accept media casts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Device Name:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(UPnPDevice.shared.friendlyName)
                        .font(.subheadline.bold())
                }

                GridRow {
                    Text("Local IP:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(verbatim: serverIP)
                        .font(.subheadline.monospaced())
                }

                GridRow {
                    Text("HTTP Port:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("\(HTTPServer.shared.port)")
                        .font(.subheadline.monospaced())
                }

                GridRow {
                    Text("SSDP Address:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("239.255.255.250:1900")
                        .font(.subheadline.monospaced())
                }
            }

            if let current = playerService.session.currentItem {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active Casting Session")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.blue)
                        Text(current.title)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .onAppear {
            serverIP = HTTPServer.shared.localIPAddress
        }
    }
}
