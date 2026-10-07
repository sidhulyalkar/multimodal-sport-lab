import MotionOSAppleCapture
import SwiftUI

struct AthleteProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profiles: AthleteProfileStore

    @State private var newProfileName = ""
    @State private var editedActiveName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            profiles.setActiveProfile(id: profile.id)
                            editedActiveName = profiles.activeProfile.displayName
                        } label: {
                            HStack(spacing: 12) {
                                profileAvatar(profile)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName)
                                        .foregroundStyle(.primary)
                                    if profile.id
                                        == AthleteProfile.legacyDefaultID {
                                        Text("Default local profile")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if profile.id
                                    == profiles.activeProfile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.indigo)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Who is moving?")
                } footer: {
                    Text(
                        "Sessions and progress stay separated by profile. "
                            + "Profiles are stored locally on this device."
                    )
                }

                Section("Active profile") {
                    TextField(
                        "Profile name",
                        text: $editedActiveName
                    )
                    .textInputAutocapitalization(.words)
                    .onSubmit {
                        profiles.renameActiveProfile(
                            to: editedActiveName
                        )
                    }

                    Picker(
                        "Units",
                        selection: Binding(
                            get: {
                                profiles.activeProfile.unitPreference
                            },
                            set: {
                                profiles.setUnitPreference($0)
                            }
                        )
                    ) {
                        Text("Automatic")
                            .tag(MotionOSUnitPreference.automatic)
                        Text("Metric")
                            .tag(MotionOSUnitPreference.metric)
                        Text("Imperial")
                            .tag(MotionOSUnitPreference.imperial)
                    }

                    Button("Save Profile Name") {
                        profiles.renameActiveProfile(
                            to: editedActiveName
                        )
                    }
                    .disabled(
                        editedActiveName
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                    )
                }

                Section("Add another person") {
                    TextField(
                        "Name",
                        text: $newProfileName
                    )
                    .textInputAutocapitalization(.words)

                    Button {
                        if profiles.createProfile(
                            displayName: newProfileName
                        ) != nil {
                            newProfileName = ""
                            editedActiveName =
                                profiles.activeProfile.displayName
                        }
                    } label: {
                        Label(
                            "Create Profile",
                            systemImage: "person.badge.plus"
                        )
                    }
                    .disabled(
                        newProfileName
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                    )
                }

                Section {
                    Text(
                        "Body measurements, health permissions, stance, "
                            + "equipment, and sport-specific details are not "
                            + "required here. MotionOS asks for them only when "
                            + "a supported measurement actually needs them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Why profiles stay lightweight")
                }

                if let error = profiles.errorMessage {
                    Section("Needs attention") {
                        Label(
                            error,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)

                        Button("Dismiss") {
                            profiles.clearError()
                        }
                    }
                }
            }
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                editedActiveName = profiles.activeProfile.displayName
            }
            .onChange(of: profiles.activeProfile.id) { _, _ in
                editedActiveName = profiles.activeProfile.displayName
            }
        }
    }

    private func profileAvatar(
        _ profile: AthleteProfile
    ) -> some View {
        ZStack {
            Circle()
                .fill(Color.indigo.opacity(0.11))
                .frame(width: 38, height: 38)

            Text(initials(profile.displayName))
                .font(.caption.weight(.bold))
                .foregroundStyle(.indigo)
        }
        .accessibilityHidden(true)
    }

    private func initials(
        _ name: String
    ) -> String {
        let pieces = name
            .split(separator: " ")
            .prefix(2)

        let value = pieces.compactMap { $0.first }
        if value.isEmpty {
            return "P"
        }
        return String(value).uppercased()
    }
}
