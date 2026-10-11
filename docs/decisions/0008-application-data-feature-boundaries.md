# Application DATA feature boundaries

## Context

BLE and LAN authenticate the same trusted peer through independent SessionConnection owners. Media is carried inside the existing bounded DATA payload; native session cryptography, readiness and liveness remain transport responsibilities. Feature dependencies in transport owners couple connection lifecycle to presentation and make subsequent DATA consumers difficult to audit.

## Decision

Keep the Android app module and Mac app target. Connections groups application-scoped BLE/LAN owners, nearby policy and connection feedback. Bluetooth/LAN own native adapters; Session owns authenticated envelopes, crypto, readiness, checks and renewal. Existing Android activity/service component names, association preferences, app identifiers, journal paths and Keychain settings remain stable.

App registers FeatureHandler instances before application DATA delivery. Each SecuredChannel describes one authenticated instance, transport and peer identity/fingerprint. Availability, retirement and capacity events are feature-neutral. DATA handling returns handled, discarded or unrecognized; connection-check fallback remains for unrecognized payloads. Retired instances reject submissions before and after suspension. The 4,000-byte payload limit and transport capacity preflight remain in force.

FeatureDispatch owns no sealed-record queue, cryptographic counter or transfer scheduler. SessionConnection retains readiness/control ordering, liveness priority and nonce ownership. Feature-specific logical queues remain bounded and respond to capacity events.

App assembles application-scoped feature models separately from connection owners. Features own their native bridges and subscription queues; native feature identity remains independent of authenticated channel identity. Navigation types and destination content live outside app assembly.

## Consequences

Transport owners have no playback model or codec dependency. Media v1 and fixture bytes remain unchanged. Source moves update explicit Xcode membership and preserve interchange entry points/compiler inputs. Lightweight structure checks cover dependency direction, documentation targets and missing/duplicate source membership. Hosted test names and explicit physical-player skips survive suite separation.
