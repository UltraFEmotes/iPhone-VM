import SwiftUI

/// The carrier console as a chat app: pick which number you're "speaking as", pick a conversation, and
/// text back and forth. Custom numbers, VM numbers, and admin broadcasts all live here. Everything is
/// recorded on the Mac (the phone's own GUI can't render a chat under emulation).
struct CarrierConsoleView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var registry: RunnerRegistry
    @EnvironmentObject private var carrier: CarrierStore

    @AppStorage("carrier.speakingAs") private var me: String = ""
    @State private var peer: String?
    @State private var draft = ""
    @State private var newNumber = ""
    @State private var showNumbers = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            conversationPane
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { if me.isEmpty { me = carrier.lines.first?.number ?? "+15550100" } }
        .sheet(isPresented: $showNumbers) { NumbersSheet().environmentObject(store).environmentObject(carrier) }
    }

    // MARK: sidebar — who I am + my conversations

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speaking as").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $me) {
                    ForEach(carrier.allNumbers(), id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                Button("Manage numbers…") { showNumbers = true }.font(.caption)
            }
            .padding(12)
            Divider()

            List(selection: $peer) {
                Section("Conversations") {
                    ForEach(carrier.peers(of: me), id: \.self) { other in
                        conversationRow(other).tag(other)
                    }
                }
            }
            .overlay { if carrier.peers(of: me).isEmpty { Text("No conversations yet.\nStart one below.").multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout) } }

            Divider()
            HStack {
                TextField("New: number", text: $newNumber).textFieldStyle(.roundedBorder)
                Button("Chat") {
                    let n = CarrierStore.normalize(newNumber)
                    if !n.isEmpty, n != me { peer = n; newNumber = "" }
                }.disabled(newNumber.isEmpty)
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 270)
    }

    private func conversationRow(_ other: String) -> some View {
        let last = carrier.conversation(me, other).last
        return VStack(alignment: .leading, spacing: 2) {
            Text(label(other)).font(.headline).lineLimit(1)
            if let last { Text((last.kind == .call ? "📞 " : "") + last.body).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    // MARK: conversation transcript + compose

    @ViewBuilder
    private var conversationPane: some View {
        if let peer {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(label(peer)).font(.headline)
                        Text(peer).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await carrier.placeCall(from: me, to: peer) } } label: { Image(systemName: "phone.fill") }
                        .help("Log a call to \(label(peer))")
                }
                .padding(12)
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(carrier.conversation(me, peer)) { m in bubble(m) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(12)
                    }
                    .onChange(of: carrier.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }

                Divider()
                HStack {
                    TextField("Text \(label(peer)) as \(label(me))", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4).onSubmit(sendText)
                    Button("Send", action: sendText).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView("Pick a conversation", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Choose who you're speaking as, then a conversation — or start a new one."))
        }
    }

    private func bubble(_ m: CarrierStore.Message) -> some View {
        let mine = m.from == CarrierStore.normalize(me)
        let isAdmin = m.kind == .admin
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                Text((m.kind == .call ? "📞 " : "") + (isAdmin ? "📢 " : "") + m.body)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(isAdmin ? Color.orange.opacity(0.25) : (mine ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                    .foregroundStyle(mine && !isAdmin ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                Text(m.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            if !mine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func sendText() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let peer, !body.isEmpty else { return }
        draft = ""
        Task { await carrier.sendText(from: me, to: peer, body: body) }
    }

    private func label(_ number: String) -> String {
        carrier.displayName(number) { id in store.machines.first { $0.id == id }?.name }
    }
}

/// Manage numbers: assign a number to each VM, and add named custom contacts.
private struct NumbersSheet: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var carrier: CarrierStore
    @Environment(\.dismiss) private var dismiss
    @State private var edits: [UUID: String] = [:]
    @State private var contactNumber = ""
    @State private var contactName = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Numbers").font(.title2.bold())

            Text("VMs").font(.headline)
            if store.machines.isEmpty { Text("No VMs.").foregroundStyle(.secondary) }
            ForEach(store.machines) { vm in
                HStack {
                    Text(vm.name).frame(width: 220, alignment: .leading).lineLimit(1)
                    TextField("Number", text: binding(vm)).textFieldStyle(.roundedBorder)
                    Button("Set") { assign(vm) }
                }
            }

            Divider()
            Text("Contacts").font(.headline)
            ForEach(carrier.contacts.sorted(by: { $0.value < $1.value }), id: \.key) { number, name in
                HStack { Text(name); Spacer(); Text(number).foregroundStyle(.secondary)
                    Button(role: .destructive) { carrier.setContact("", for: number) } label: { Image(systemName: "trash") } }
            }
            HStack {
                TextField("Name", text: $contactName).textFieldStyle(.roundedBorder).frame(width: 160)
                TextField("Number", text: $contactNumber).textFieldStyle(.roundedBorder)
                Button("Add") {
                    carrier.setContact(contactName, for: contactNumber); contactName = ""; contactNumber = ""
                }.disabled(contactNumber.isEmpty || contactName.isEmpty)
            }

            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
    }

    private func binding(_ vm: VirtualMachine) -> Binding<String> {
        Binding(get: { edits[vm.id] ?? carrier.number(for: vm.id) ?? "" }, set: { edits[vm.id] = $0 })
    }
    private func assign(_ vm: VirtualMachine) {
        let value = edits[vm.id] ?? carrier.number(for: vm.id) ?? carrier.suggestNumber()
        do { try carrier.assign(value, to: vm.id); edits[vm.id] = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
