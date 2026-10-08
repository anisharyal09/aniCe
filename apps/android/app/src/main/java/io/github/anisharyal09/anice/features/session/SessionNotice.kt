// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.session

import io.github.anisharyal09.anice.infrastructure.session.SessionExpiry
import io.github.anisharyal09.anice.infrastructure.session.SessionFailure

internal data class SessionNotice(val state: ConnectionState, val text: String)

internal fun sessionNotice(
  failure: SessionFailure?,
  expiration: SessionExpiry?,
  closedByPeer: Boolean,
  wasSecured: Boolean,
): SessionNotice {
  if (closedByPeer)
    return SessionNotice(ConnectionState.DISCONNECTED, "Your Mac ended the session.")
  if (failure == SessionFailure.EXPIRED)
    return when (expiration) {
      SessionExpiry.IDLE ->
        SessionNotice(
          ConnectionState.DISCONNECTED,
          "Idle for 2 minutes. Reopen Allow connections on your Mac.",
        )
      SessionExpiry.LIFETIME ->
        SessionNotice(
          ConnectionState.DISCONNECTED,
          "The one-hour session ended. Reopen Allow connections on your Mac.",
        )
      SessionExpiry.RECORD_LIMIT ->
        SessionNotice(
          ConnectionState.DISCONNECTED,
          "Session message limit reached. Reopen Allow connections on your Mac.",
        )
      SessionExpiry.READINESS ->
        SessionNotice(ConnectionState.FAILED, "Your Mac did not confirm the connection. Retry.")
      null -> SessionNotice(ConnectionState.FAILED, "Connecting took too long. Retry.")
    }
  if (failure == SessionFailure.CANCELLED)
    return SessionNotice(ConnectionState.DISCONNECTED, "The session ended. Connect again.")
  if (failure == SessionFailure.UNTRUSTED_PEER)
    return SessionNotice(
      ConnectionState.FAILED,
      if (wasSecured) "This device is no longer trusted. Check your trusted devices."
      else
        "The nearby Mac did not match the selected device. Open Allow connections on the correct Mac.",
    )
  return SessionNotice(ConnectionState.FAILED, "The secure connection was interrupted. Retry.")
}
