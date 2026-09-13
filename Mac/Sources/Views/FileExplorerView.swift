import SwiftUI

/// Browse the VM's iOS system files (read-only, while the VM is stopped).
struct FileExplorerView: View {
    let vm: VirtualMachine
    let isRunning: Bool
    @StateObject private var browser: DiskBrowser
    @State private var selection: DiskBrowser.Item.ID?

    init(vm: VirtualMachine, isRunning: Bool) {
        self.vm = vm
        self.isRunning = isRunning
        _browser = StateObject(wrappedValue: DiskBrowser(vm: vm))
    }

    var body: some View {
        Group {
            if !browser.canBrowse {
                ContentUnavailableView("Can't browse this VM's disk",
                                       systemImage: "externaldrive.badge.xmark",
                                       description: Text("Its disk is stored compressed (qcow2). VMs set up in this app use a raw disk and can be browsed."))
            } else if isRunning {
                ContentUnavailableView("Stop the VM to browse its files", systemImage: "stop.circle",
                                       description: Text("The disk is attached read-only on the Mac, which isn't safe while iOS is using it."))
            } else if browser.mountPoint == nil {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(.secondary)
                    Button(browser.busy ? "Opening…" : "Open iOS File System (read-only)") {
                        Task { await browser.attach() }
                    }
                    .disabled(browser.busy)
                    if let error = browser.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                browserBody
            }
        }
        .onDisappear { Task { await browser.detach() } }
        .onChange(of: isRunning) { _, running in if running { Task { await browser.detach() } } }
    }

    private var browserBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button { browser.up() } label: { Image(systemName: "chevron.left") }.disabled(browser.path.isEmpty)
                Text("/" + browser.path.joined(separator: "/")).font(.system(.callout, design: .monospaced)).lineLimit(1)
                Spacer()
                if let item = selected, !item.isDirectory {
                    Button("Copy to Downloads") { Task { await browser.copyOut(item) } }
                }
                if let item = selected {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
                Button("Close") { Task { await browser.detach() } }
            }
            .padding(8)
            if let error = browser.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 8) }
            Table(browser.items, selection: $selection) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                        .onTapGesture(count: 2) { browser.open(item) }
                }
                TableColumn("Size") { item in
                    Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .width(90)
            }
        }
    }

    private var selected: DiskBrowser.Item? { browser.items.first { $0.id == selection } }
}
