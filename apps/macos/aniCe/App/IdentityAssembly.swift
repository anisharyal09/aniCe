// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Builds the application-scoped identity model without changing storage namespaces.
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
