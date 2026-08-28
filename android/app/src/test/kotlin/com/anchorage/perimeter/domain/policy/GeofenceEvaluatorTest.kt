package com.anchorage.perimeter.domain.policy

import com.anchorage.perimeter.domain.fake.DHAKA_OFFICE
import com.anchorage.perimeter.domain.fake.anchorAt
import com.anchorage.perimeter.domain.fake.fixAt
import com.anchorage.perimeter.domain.geo.DistanceCalculator
import com.google.common.truth.Truth.assertThat
import org.junit.Test

/**
 * Policy tests use a stub calculator that returns an exact distance, so a
 * failure here can only mean the *rule* is wrong - never the trigonometry.
 */
class GeofenceEvaluatorTest {

    private var stubDistance: Double = 0.0
    private val calculator = DistanceCalculator { _, _ -> stubDistance }
    private val policy = GeofencePolicy(
        radiusMeters = 50.0,
        exitHysteresisMeters = 8.0,
        maxTrustedAccuracyMeters = 50f,
        maxAnchorAccuracyMeters = 35f,
    )
    private val evaluator = GeofenceEvaluator(calculator, policy)

    @Test
    fun `inside when strictly within the radius`() {
        stubDistance = 12.0

        val reading = evaluator.evaluate(anchorAt(), fixAt())

        assertThat(reading.status).isEqualTo(ProximityStatus.INSIDE)
        assertThat(reading.allowsCheckIn).isTrue()
    }

    @Test
    fun `exactly on the radius counts as inside`() {
        stubDistance = 50.0

        assertThat(evaluator.evaluate(anchorAt(), fixAt()).status).isEqualTo(ProximityStatus.INSIDE)
    }

    @Test
    fun `outside just beyond the radius`() {
        stubDistance = 50.01

        val reading = evaluator.evaluate(anchorAt(), fixAt())

        assertThat(reading.status).isEqualTo(ProximityStatus.OUTSIDE)
        assertThat(reading.allowsCheckIn).isFalse()
    }

    @Test
    fun `hysteresis keeps an already-inside user inside within the exit band`() {
        stubDistance = 55.0

        val reading = evaluator.evaluate(
            anchor = anchorAt(),
            fix = fixAt(),
            previousStatus = ProximityStatus.INSIDE,
        )

        assertThat(reading.status).isEqualTo(ProximityStatus.INSIDE)
    }

    @Test
    fun `hysteresis does not let an outside user in early`() {
        stubDistance = 55.0

        val reading = evaluator.evaluate(
            anchor = anchorAt(),
            fix = fixAt(),
            previousStatus = ProximityStatus.OUTSIDE,
        )

        assertThat(reading.status).isEqualTo(ProximityStatus.OUTSIDE)
    }

    @Test
    fun `an inside user is finally released past the exit radius`() {
        stubDistance = 58.01

        val reading = evaluator.evaluate(
            anchor = anchorAt(),
            fix = fixAt(),
            previousStatus = ProximityStatus.INSIDE,
        )

        assertThat(reading.status).isEqualTo(ProximityStatus.OUTSIDE)
    }

    @Test
    fun `a fix wider than the fence is reported as not confident`() {
        stubDistance = 10.0

        val reading = evaluator.evaluate(anchorAt(), fixAt(accuracyMeters = 90f))

        assertThat(reading.status).isEqualTo(ProximityStatus.INSIDE)
        assertThat(reading.isConfident).isFalse()
        assertThat(reading.allowsCheckIn).isFalse()
    }

    @Test
    fun `fence progress is clamped between zero and one`() {
        stubDistance = 0.0
        assertThat(evaluator.evaluate(anchorAt(), fixAt()).fenceProgress).isEqualTo(0f)

        stubDistance = 5_000.0
        assertThat(evaluator.evaluate(anchorAt(), fixAt()).fenceProgress).isEqualTo(1f)

        stubDistance = 25.0
        assertThat(evaluator.evaluate(anchorAt(), fixAt()).fenceProgress).isWithin(1e-6f).of(0.5f)
    }

    @Test
    fun `anchor accuracy gate is stricter than the check-in gate`() {
        assertThat(evaluator.isAcceptableAnchorFix(fixAt(accuracyMeters = 35f))).isTrue()
        assertThat(evaluator.isAcceptableAnchorFix(fixAt(accuracyMeters = 35.1f))).isFalse()
    }

    @Test
    fun `reading carries the numbers the UI needs to explain itself`() {
        stubDistance = 120.0

        val reading = evaluator.evaluate(anchorAt(DHAKA_OFFICE), fixAt(accuracyMeters = 8f))

        assertThat(reading.distanceMeters).isEqualTo(120.0)
        assertThat(reading.radiusMeters).isEqualTo(50.0)
        assertThat(reading.accuracyMeters).isEqualTo(8f)
    }
}
