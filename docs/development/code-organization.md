# Native app code organization

Keep Android and macOS native, with matching responsibilities rather than identical implementations. Start with packages/folders within the existing application targets. Add build modules or Swift packages only for a concrete reuse, isolation, or build requirement.

## Current code map

Android Kotlin sources currently live under `apps/android/app/src/main/java/io/github/anisharyal09/anice/`. The `java` source-directory name is valid for Kotlin; it does not mean the code is Java. Android Studio's Project view shows the physical tree, while its Android view presents packages and resources.

| Responsibility | Android today | macOS today |
| --- | --- | --- |
| Application startup | `AniCeApplication.kt`, slim `MainActivity.kt` | `App/AniCeApp.swift`, `App/AppDelegate.swift`, `App/IdentityAssembly.swift` |
| Navigation and app shell | `app/AppRoot.kt` | `App/MainWindowView.swift`, `App/CompanionView.swift` |
| Device identity UI/state | `features/deviceidentity/DeviceIdentityScreen.kt`, `DeviceIdentityViewModel.kt` | `Features/DeviceIdentity/IdentityView.swift`, `IdentityViewModel.swift` |
| Identity infrastructure | `infrastructure/identity/` | `Infrastructure/Identity/` |
| Shared presentation | `ui/theme/Theme.kt` | `UI/Theme/AniCePalette.swift`, `UI/Components/EmptyStateView.swift` |

## Structure for growth

Phase 2 now follows these boundaries. BLE/discovery entries below are reserved responsibilities; their directories do not exist yet. Do not create empty folders for speculative features.

| Responsibility | Android package below the base package | macOS folder below `aniCe/` |
| --- | --- | --- |
| Startup, dependency assembly, navigation, window/companion shell | `app` | `App` |
| This-device screen and presentation state | `features.deviceidentity` | `Features/DeviceIdentity` |
| Shared local identity contract, lifecycle, protected storage | `infrastructure.identity` | `Infrastructure/Identity` |
| Future shared BLE discovery and connection implementation | `infrastructure.bluetooth` | `Infrastructure/Bluetooth` |
| Future nearby-device screen and presentation state | `features.discovery` | `Features/Discovery` |
| Reused palette, theme, and proven shared controls | `ui.theme`, `ui.components` | `UI/Theme`, `UI/Components` |

Keep Android entry classes at the base package if moving them would require unnecessary manifest changes. Entry classes should host UI and assemble dependencies, not accumulate feature implementations. Keep Android resources in the standard `res/` tree. Preserve existing identifiers and storage namespaces during structural changes.

## Boundaries

- The app shell chooses destinations and supplies application-scoped services.
- A feature owns its screen, presentation state, and feature-specific interaction. Use a presentation model when asynchronous work and lifecycle state justify it; do not add one for every small view.
- Infrastructure owns shared identity, discovery, trust, and transport capabilities as they become implemented. It does not depend on feature UI. Features use this infrastructure instead of constructing separate security or networking stacks.
- Shared UI contains genuinely reused presentation only. Domain behavior does not belong in theme/components folders.
- Do not have one feature reach into another feature's internals. Coordinate through the app shell or a shared service with a concrete responsibility.
- `protocol/` remains the authority for cross-platform contracts. Native adapters remain in their platform app; runtime code is not duplicated into documentation or shared UI.

Prefer files named after a concrete responsibility, such as `DeviceIdentityScreen`, `DeviceIdentityViewModel`, or `BluetoothDiscoveryService`. Split a file when it mixes responsibilities or makes navigation difficult, not to meet an arbitrary line limit. Closely related small helpers can remain beside their owning view. Avoid generic `Utils`, `Managers`, or catch-all `Common` folders.

## Maintaining the structure

Android entry classes stay in their existing manifest package. The activity creates a lifecycle ViewModel using the application-scoped identity service. `AppRoot` owns navigation and safe insets; the device screen owns copy feedback and reset confirmation. The ViewModel serializes presentation requests and performs storage work off the main thread. Android infrastructure tests mirror the relocated package.

The Mac app assembles one shared model for the window and companion. Views and model are separate files; infrastructure remains independent of SwiftUI. Opening details reuses the model's initial load attempt; explicit Retry performs another storage check. Storage denial does not reset identity. Ad-hoc rebuilds can still require renewed Keychain authorization.

When moving sources, update Xcode file references, imports, test packages, and the interchange compiler/test class paths together. Preserve bundle/application identifiers, storage namespaces, metadata filenames, and key aliases. Verify Android unit tests/lint/assembly, Mac tests/universal build, and actual signature interchange after structural changes. Interaction checks remain manual.

Tests should mirror the responsibility they exercise: Android local tests in `src/test`, native storage tests in `src/androidTest`, and Mac tests under the existing hosted test target. Keep public test private scalars outside production resources.

This standard does not require a separate module per feature or a framework per layer. Introduce those boundaries when measured build needs, independent reuse, or enforcement justify their maintenance cost.
