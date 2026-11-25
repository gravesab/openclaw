import SwiftUI

/// Window and navigation title: app name, version, and build.
/// The name prefix is compiled per target; the version and build
/// come from the app's Info.plist.
enum RanchPeopleOSTitle {
    #if RANCHPEOPLEOS_PROD
    static let prefix = "Ranch People OS PROD · Version "
    #else
    static let prefix = "Ranch People OS DEV · Version "
    #endif

    static var full: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(prefix)\(version) · Build \(build)"
    }
}

/// Who is on each ranch. Ranch names are entered once above; assigning a
/// person picks one of those names. The page is opened as the administrator
/// or as one saved person; only the administrator and owners change who has
/// access. Every change is saved to a JSON file. Nothing here calls
/// the server.
struct RanchOSPeopleView: View {
    @Bindable var store: RanchOSPeopleStore
    @State private var showingInvite = false
    @State private var personPendingRemoval: RanchOSPerson?
    @State private var ranchName = ""

    var body: some View {
        List {
            Section {
                Text("Who can open this ranch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Ranch") {
                Picker("Opened as", selection: $store.openedAsPersonID) {
                    Text("Administrator").tag(nil as UUID?)
                    ForEach(store.openedAsOptions) { person in
                        Text("\(person.name) · \(person.privilege) · \(person.ranchName)").tag(person.id as UUID?)
                    }
                }
                if let line = store.openedAsLine {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Ranch name", text: $ranchName)
                Button("Add ranch") {
                    Task {
                        await store.addRanch(name: ranchName)
                        if store.message == nil {
                            ranchName = ""
                        }
                    }
                }
                .accessibilityLabel("Add ranch")
                if let message = store.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(store.ranchSections) { ranch in
                Section(header: Text(ranch.saved ? "\(ranch.name) · Saved" : ranch.name)) {
                    if ranch.saved {
                        RanchSaveView(
                            ranchName: ranch.name,
                            checks: store.isolationChecks(for: ranch.id))
                    }
                    if ranch.people.isEmpty {
                        Text("No one on this ranch yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ranch.people) { person in
                        RanchOSPersonRow(
                            person: person,
                            onRoleChange: { role in
                                Task { await store.changeRole(id: person.id, role: role) }
                            },
                            onRemove: { personPendingRemoval = person })
                    }
                }
            }
        }
        .navigationTitle(RanchPeopleOSTitle.full)
        .toolbar {
            Button("Invite", systemImage: "plus") { showingInvite = true }
                .accessibilityLabel("Invite")
        }
        .sheet(isPresented: $showingInvite) {
            RanchOSInviteView(store: store)
        }
        .alert(
            "Remove \(personPendingRemoval?.name ?? "this person") from this ranch?",
            isPresented: Binding(
                get: { personPendingRemoval != nil },
                set: { if !$0 { personPendingRemoval = nil } }),
            presenting: personPendingRemoval
        ) { person in
            Button("Remove", role: .destructive) {
                personPendingRemoval = nil
                Task { await store.revoke(id: person.id) }
            }
            Button("Cancel", role: .cancel) { personPendingRemoval = nil }
        }
    }
}

private struct RanchOSPersonRow: View {
    let person: RanchOSPerson
    let onRoleChange: (RanchOSPersonRole) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.headline)
                    Text(person.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", role: .destructive, action: onRemove)
                    .accessibilityLabel("Remove \(person.name)")
            }
            Picker("Role", selection: Binding(
                get: { person.role },
                set: { onRoleChange($0) })
            ) {
                ForEach(RanchOSPersonRole.allCases) { role in
                    Text(role.label).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Change role for \(person.name)")
        }
        .padding(.vertical, 4)
    }
}

private struct RanchOSInviteView: View {
    var store: RanchOSPeopleStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var selectedRanchID: UUID?
    @State private var role = RanchOSPersonRole.manager
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    Picker("Ranch", selection: $selectedRanchID) {
                        ForEach(store.ranchSections) { ranch in
                            Text(ranch.name).tag(ranch.id as UUID?)
                        }
                    }
                }

                Section("Role") {
                    Picker("Role", selection: $role) {
                        ForEach(RanchOSPersonRole.allCases) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    Text("Owner can change ranch records and who has access.")
                    Text("Manager can change ranch records.")
                    Text("Viewer can look, not change.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .onAppear {
                if selectedRanchID == nil {
                    selectedRanchID = store.ranchSections.first?.id
                }
            }
            .navigationTitle("Invite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite") {
                        Task {
                            await store.assign(name: name, email: email, role: role, ranchID: selectedRanchID)
                            if store.message == nil {
                                dismiss()
                            } else {
                                errorMessage = store.message
                            }
                        }
                    }
                    .accessibilityLabel("Invite")
                }
            }
        }
    }

}
