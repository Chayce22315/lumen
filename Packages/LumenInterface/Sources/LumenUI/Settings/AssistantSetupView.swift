import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenIntelligence

/// Provider keys, model choice, memory and tool approval.
struct AssistantSetupView: View {
    @State private var setup: AssistantSetupViewModel
    @State private var keyProvider: ProviderID?
    @State private var newMemory = ""

    init(services: LumenServices) {
        _setup = State(initialValue: AssistantSetupViewModel(services: services))
    }

    var body: some View {
        Form {
            Section {
                ForEach(setup.providers) { provider in
                    VStack(alignment: .leading, spacing: LumenSpace.s) {
                        HStack {
                            Text(provider.displayName).lumenText(.headline)
                            Spacer()
                            if provider.hasAPIKey {
                                Label("Key saved", systemImage: "key.fill").lumenText(.caption).foregroundStyle(LumenColor.success)
                            }
                        }
                        if keyProvider == provider.id {
                            SecureField("API key", text: $setup.apiKeyDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Save key") {
                                Task {
                                    await setup.saveAPIKey(for: provider.id)
                                    keyProvider = nil
                                }
                            }
                            .buttonStyle(.lumenPrimary)
                        } else {
                            HStack {
                                Button(provider.hasAPIKey ? "Replace key" : "Add key") { keyProvider = provider.id }
                                if provider.hasAPIKey {
                                    Button("Remove", role: .destructive) { Task { await setup.removeAPIKey(for: provider.id) } }
                                    Spacer()
                                    Button("Load models") { Task { await setup.loadModels(for: provider.id) } }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        if let error = setup.modelErrors[provider.id] {
                            Text(error.message).lumenText(.caption).foregroundStyle(LumenColor.danger)
                        }
                        ForEach(setup.models[provider.id] ?? [], id: \.id) { model in
                            Button {
                                Task { await setup.select(model) }
                            } label: {
                                HStack {
                                    Text(model.displayName).foregroundStyle(LumenColor.textPrimary)
                                    Spacer()
                                    if setup.selection == model.selection {
                                        Image(systemName: "checkmark").foregroundStyle(LumenColor.accent)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, LumenSpace.xs)
                }
            } header: {
                Text("Model providers")
            } footer: {
                Text("API keys are stored only in this device's Keychain. Requests go directly from your device to the provider you choose.")
            }
            Section {
                Toggle("Ask before changing my data", isOn: Binding(
                    get: { setup.requiresApproval },
                    set: { value in Task { await setup.setRequiresApproval(value) } }
                ))
            } footer: {
                Text("When on, the assistant asks before it creates or completes tasks, writes notes or runs automations.")
            }
            Section {
                Toggle("Memory", isOn: Binding(
                    get: { setup.memoryEnabled },
                    set: { value in Task { await setup.setMemoryEnabled(value) } }
                ))
                ForEach(setup.memories) { memory in
                    Toggle(memory.content, isOn: Binding(
                        get: { memory.isEnabled },
                        set: { value in Task { await setup.setMemory(memory, enabled: value) } }
                    ))
                    .swipeActions { Button("Delete", role: .destructive) { Task { await setup.deleteMemory(memory) } } }
                }
                HStack {
                    TextField("Add something to remember", text: $newMemory)
                    Button { Task { await setup.addMemory(newMemory); newMemory = "" } } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(newMemory.isEmpty)
                        .accessibilityLabel("Add memory")
                }
                if !setup.memories.isEmpty {
                    Button("Forget everything", role: .destructive) { Task { await setup.clearMemories() } }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Memories are facts the assistant keeps between conversations. You can review, disable or delete each one.")
            }
        }
        .navigationTitle("Assistant")
        .task { await setup.load() }
    }
}
