// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.session

import io.github.anisharyal09.anice.infrastructure.session.SessionExpiry
import io.github.anisharyal09.anice.infrastructure.session.SessionFailure
import org.junit.Assert.*
import org.junit.Test

class SessionNoticeTests {
  @Test
  fun idleAndPeerCloseNeverClaimTrustChanged() {
    val cases =
      listOf(
        sessionNotice(SessionFailure.EXPIRED, SessionExpiry.IDLE, false, true),
        sessionNotice(SessionFailure.EXPIRED, SessionExpiry.LIFETIME, false, true),
        sessionNotice(SessionFailure.EXPIRED, SessionExpiry.RECORD_LIMIT, false, true),
        sessionNotice(SessionFailure.CONTROL_TIMEOUT, null, false, true),
        sessionNotice(SessionFailure.CANCELLED, null, true, true),
        sessionNotice(SessionFailure.STATE, null, true, true),
        sessionNotice(null, null, true, true),
      )
    assertTrue(cases.size >= 7)
    cases.forEach {
      assertEquals(ConnectionState.DISCONNECTED, it.state)
      assertFalse(it.text.contains("trust", ignoreCase = true))
    }
    assertTrue(cases.first().text.contains("2 minutes"))
    assertEquals("Your Mac ended the session.", cases.last().text)
  }

  @Test
  fun failedAuthenticationAndConfirmationStayDistinctFromRevocation() {
    val readiness = sessionNotice(SessionFailure.EXPIRED, SessionExpiry.READINESS, false, false)
    assertEquals(ConnectionState.FAILED, readiness.state)
    assertTrue(readiness.text.contains("confirm"))
    val revoked = sessionNotice(SessionFailure.UNTRUSTED_PEER, null, false, true)
    assertEquals(ConnectionState.FAILED, revoked.state)
    assertTrue(revoked.text.contains("no longer trusted"))
    val mismatch = sessionNotice(SessionFailure.UNTRUSTED_PEER, null, false, false)
    assertTrue(mismatch.text.contains("did not match"))
    val interrupted = sessionNotice(SessionFailure.AUTHENTICATION, null, false, true)
    assertEquals(ConnectionState.FAILED, interrupted.state)
    assertFalse(interrupted.text.contains("trust"))
  }
}
