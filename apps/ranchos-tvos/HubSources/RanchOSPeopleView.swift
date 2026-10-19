import SwiftUI

/// Who can open this ranch. Owners manage membership; everyone else reads.
struct RanchOSPeopleView: View {
    @Bindable var directory: RanchOSPeopleDirectory
    @State private var showingInvite = false
    @State private var personPendingRemoval: RanchOSPerson?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("Who can open this ranch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("People") {
                if directory.canManage, directory.people.isEmpty {
                    Text("No one else is on this ranch yet.")
                }
                ForEach(directory.people) { person in
                    RanchOSPersonRow(
                        person: person,
                        isSelf: person.id == directory.actorPersonID,
                        canManage: directory.canManage,
                        onRoleChange: { role in
                            do {
                                try directory.changeRole(id: person.id, role: role)
                            } catch {
                                errorMessage = "Could not change that role."
                            }
                        },
                        onRemove: { personPendingRemoval = person })
                }
            }

            if !directory.canManage {
                Text("Only an owner can change who has access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("People")
        .toolbar {
            if directory.canManage {
                Button("Invite", systemImage: "plus") { showingInvite = true }
                    .accessibilityLabel("Invite")
            }
        }
        .sheet(isPresented: $showingInvite) {
            RanchOSInviteView(directory: directory)
        }
        .alert(
            "Remove \(personPendingRemoval?.name ?? "this person") from this ranch?",
            isPresented: Binding(
                get: { personPendingRemoval != nil },
                set: { if !$0 { personPendingRemoval = nil } }),
            presenting: personPendingRemoval
        ) { person in
            Button("Remove", role: .destructive) {
                do {
                    try directory.revoke(id: person.id)
                } catch {
                    errorMessage = "Could not remove that person."
                }
                personPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { personPendingRemoval = nil }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct RanchOSPersonRow: View {
    let person: RanchOSPerson
    let isSelf: Bool
    let canManage: Bool
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
                if canManage, !isSelf {
                    Button("Remove", role: .destructive, action: onRemove)
                        .accessibilityLabel("Remove \(person.name)")
                } else {
                    Text(person.role.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Role: \(person.role.label)")
                }
            }
            if canManage, !isSelf {
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
        }
        .padding(.vertical, 4)
    }
}

private struct RanchOSInviteView: View {
    @Bindable var directory: RanchOSPeopleDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
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
            .navigationTitle("Invite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite") {
                        do {
                            try directory.invite(name: name, email: email, role: role)
                            dismiss()
                        } catch let peopleError as RanchOSPeopleError {
                            errorMessage = friendlyMessage(for: peopleError)
                        } catch {
                            errorMessage = "Could not invite that person."
                        }
                    }
                    .accessibilityLabel("Invite")
                }
            }
        }
    }

    private func friendlyMessage(for error: RanchOSPeopleError) -> String {
        switch error {
        case .notAllowed: "Only an owner can change who has access."
        case .duplicateEmail: "That email is already on this ranch."
        case .lastOwner: "The ranch must keep at least one owner."
        case .unknownPerson: "That person is no longer on this ranch."
        case .invalidName: "Enter a name."
        case .invalidEmail: "Enter a valid email address."
        }
    }
}
