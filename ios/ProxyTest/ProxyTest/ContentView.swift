import SwiftUI

struct ContentView: View {
    @StateObject private var server = TestServer()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: server.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 48))
                        .foregroundColor(server.isRunning ? .green : Color(white: 0.3))
                        .padding(.top, 24)

                    // Summary
                    HStack(spacing: 20) {
                        statBox(title: "Established", value: "\(server.established)/\(server.slotStates.count)")
                        statBox(title: "Free", value: "\(server.free)")
                        statBox(title: "Busy", value: "\(server.established - server.free)")
                    }

                    // Byte counters
                    HStack(spacing: 16) {
                        byteBox(icon: "arrow.up", color: .orange,
                                title: "Sent", value: fmt(server.bytesUp))
                        byteBox(icon: "arrow.down", color: .green,
                                title: "Received", value: fmt(server.bytesDown))
                        byteBox(icon: "sum", color: .cyan,
                                title: "Total", value: fmt(server.bytesTotal))
                    }

                    Button {
                        server.isRunning ? server.stop() : server.start()
                    } label: {
                        Text(server.isRunning ? "Stop" : "Start")
                            .foregroundColor(.black)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(server.isRunning ? Color.red : Color.white)
                            .cornerRadius(24)
                    }

                    // Slot grid
                    if server.isRunning {
                        VStack(spacing: 4) {
                            ForEach(0..<server.slotStates.count, id: \.self) { i in
                                slotRow(index: i, state: server.slotStates[i],
                                        bytes: i < server.perSlotBytes.count ? server.perSlotBytes[i] : 0)
                            }
                        }
                        .padding(10)
                        .background(Color(white: 0.06))
                        .cornerRadius(8)
                        .padding(.horizontal, 16)
                    }

                    // Log — fixed height, scrolls internally, newest at bottom
                    if !server.log.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(server.log.suffix(200).enumerated()), id: \.offset) { idx, line in
                                        Text(line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(
                                                line.contains("✓") ? .green :
                                                line.contains("✗") || line.contains("failed") ? .red :
                                                Color(white: 0.5)
                                            )
                                            .id(idx)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 240)
                            .onChange(of: server.log.count) { _, _ in
                                proxy.scrollTo(min(server.log.count, 200) - 1, anchor: .bottom)
                            }
                        }
                        .padding(10)
                        .background(Color(white: 0.06))
                        .cornerRadius(8)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder
    func statBox(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.5))
        }
        .frame(width: 90, height: 56)
        .background(Color(white: 0.08))
        .cornerRadius(8)
    }

    func fmt(_ b: Int) -> String {
        let kb = Double(b) / 1024
        if kb < 1 { return "\(b) B" }
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    @ViewBuilder
    func byteBox(icon: String, color: Color, title: String, value: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(Color(white: 0.5))
        }
        .frame(width: 100, height: 44)
        .background(Color(white: 0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    func slotRow(index: Int, state: SlotState, bytes: Int) -> some View {
        // "heavy" = this slot's current connection moved a lot of data
        let heavy = bytes > 1_048_576          // > 1 MB
        let medium = bytes > 102_400           // > 100 KB

        HStack(spacing: 6) {
            Text("Slot \(index)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .frame(width: 48, alignment: .leading)

            switch state {
            case .disconnected:
                Text("─ disconnected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                Spacer()
            case .free:
                Text("● FREE")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
                Spacer()
            case .busy(let host):
                Text("→ \(host)")
                    .font(.system(size: 11, weight: heavy ? .bold : .regular, design: .monospaced))
                    .foregroundColor(heavy ? .yellow : medium ? .orange : Color(white: 0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(fmt(bytes))
                    .font(.system(size: 10, weight: heavy ? .bold : .regular, design: .monospaced))
                    .foregroundColor(heavy ? .yellow : medium ? .orange : Color(white: 0.4))
            }
        }
    }
}
