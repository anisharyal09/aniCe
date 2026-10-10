// SPDX-License-Identifier: GPL-3.0-or-later
// Tests backoff/exclusion bounds and role-specific renewal margins/coalescing.
package io.github.anisharyal09.anice.infrastructure.session

import org.junit.Assert.*
import org.junit.Test

class NearbyRetryTests {
  @Test fun boundedDelaysJitterAndEphemeralExclusions() {
    val policy = NearbyRetry()
    assertEquals(listOf(2000L, 5000L, 15000L, 30000L, 60000L, 90000L, 90000L), List(7) { policy.next(0.0) })
    policy.reset()
    assertEquals(1800L, policy.next(-0.1))
    assertEquals(5500L, policy.next(0.1))
    for (bad in listOf(-0.101, 0.101, Double.NaN)) {
      try { policy.next(bad); fail("Accepted jitter $bad") } catch (_: IllegalArgumentException) {}
    }
    repeat(33) { policy.reject("candidate-$it", 0) }
    assertEquals(32, policy.exclusions(59999).size)
    assertFalse("candidate-0" in policy.exclusions(59999))
    assertTrue(policy.exclusions(60000).isEmpty())
    policy.reject("candidate", 60001); policy.reset()
    assertTrue(policy.exclusions(60002).isEmpty())
    assertEquals(2000L, policy.next(0.0))
  }
  @Test fun positiveJitterCannotExceedNinetySecondsAfterSaturationOrReset() {
    val cases = listOf(-0.1, 0.0, 0.1)
    assertEquals(3, cases.size)
    cases.forEach { jitter ->
      val policy = NearbyRetry()
      val nominal = listOf(2000L, 5000L, 15000L, 30000L, 60000L, 90000L)
      assertEquals(6, nominal.size)
      nominal.forEach { delay ->
        assertEquals(minOf((delay * (1 + jitter)).toLong(), 90000L), policy.next(jitter))
      }
      repeat(16) { assertEquals(if (jitter < 0) 81000L else 90000L, policy.next(jitter)) }
      policy.reset()
      assertEquals((2000 * (1 + jitter)).toLong(), policy.next(jitter))
    }
  }
  @Test fun renewalMarginsCoalescingAndRoleValidation() {
    val threshold = (1uL shl 20) - 1024uL
    assertNull(SecureSession.renewalReason(3299999, threshold - 1u, threshold - 1u))
    assertEquals(1L, SecureSession.renewalReason(3300000, 0u, 0u))
    assertEquals(2L, SecureSession.renewalReason(0, threshold, 0u))
    assertEquals(2L, SecureSession.renewalReason(0, 0u, threshold))
    val c = SessionLiveness(false); val s = SessionLiveness(true)
    c.start(0); s.start(0)
    val hello = requireNotNull(c.pending)
    c.issuing(hello, 0); c.submitted(hello, 0); s.receive(hello, 0)
    val ack = requireNotNull(s.pending)
    s.issuing(ack, 0); s.submitted(ack, 0); c.receive(ack, 0)
    c.requestRenewal(2); s.requestRenewal(1); s.poll(1)
    val request = requireNotNull(s.pending)
    assertEquals(SessionControl(ControlKind.RENEWAL_REQUEST, 1), request)
    c.receive(request, 1); c.receive(request, 2)
    assertEquals(2L, c.renewalReason)
    s.issuing(request, 2); s.submitted(request, 2); s.poll(3)
    assertNull(s.pending)
    c.poll(60000); assertNull(c.pending)
    try { s.receive(request, 3); fail("Responder accepted renewal request") }
    catch (error: SessionException) { assertEquals(SessionFailure.STATE, error.reason) }
  }
}
