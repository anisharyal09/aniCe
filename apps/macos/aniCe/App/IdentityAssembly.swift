// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles the application identity model in the selected Keychain namespace.
import Foundation

@MainActor
enum IdentityAssembly {
    static func makeModel() -> IdentityViewModel {
        let backend = MacIdentityBackend.current
        let suffix = backend == .developmentKeychain ? "development" : "protected"
        let namespace = "io.github.anisharyal09.anice.identity." + suffix
        let storage = MacIdentityStorage(namespace: namespace, backend: backend)
        let service = IdentityService(storage: storage, deviceName: Host.current().localizedName ?? "Mac",
                                      tagPrefix: namespace + ".")
        return IdentityViewModel(service: service)
    }
}
